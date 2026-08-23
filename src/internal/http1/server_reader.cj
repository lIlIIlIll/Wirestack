package wirestack.internal.http1

import std.sync.Mutex
import wirestack.http.*
import wirestack.internal.transport.*

private const HTTP1_SERVER_READ_BUFFER_SIZE: Int64 = 16 * 1024

/** Strict incoming request head plus a single-owner streaming body. */
public class Http1ServerRequest {
    public let head: Http1RequestHead
    public let body: ResponseBody

    public init(head: Http1RequestHead, body: ResponseBody) {
        this.head = head
        this.body = body
    }

    public func close(): Unit { body.close() }
}

/** Reads one request without buffering its body or accepting pipelining. */
public func readHttp1ServerRequest(
    transport: DuplexTransport,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    observer!: ResponseBodyObserver = Http1ServerNoopObserver()
): Http1ServerRequest {
    let parser = Http1RequestHeadParser(limits: limits)
    var parsed: ?Http1ParsedRequestHead = None<Http1ParsedRequestHead>
    while (parsed.isNone()) {
        let buffer = Array<Byte>(HTTP1_SERVER_READ_BUFFER_SIZE, repeat: 0)
        match (transport.readSome(MutableByteSpan(buffer), context: context)) {
            case ReadResult.Data(count) =>
                if (count <= 0 || count > buffer.size) {
                    throw NetworkException(
                        NetworkErrorCategory.Read, NetworkPhase.HttpHeaders, NetworkErrorCode.SystemFailure,
                        "transport returned invalid progress while reading HTTP/1 request head",
                        retryability: Retryability.Never
                    )
                }
                parsed = parser.feed(copyServerPrefix(buffer, count))
            case ReadResult.EndOfStream =>
                throw NetworkException(
                    NetworkErrorCategory.Read, NetworkPhase.HttpHeaders, NetworkErrorCode.UnexpectedEof,
                    "peer closed before completing the HTTP/1 request head",
                    retryability: Retryability.Never
                )
        }
    }
    let completed = parsed.getOrThrow()
    let head = completed.head
    let source = match (head.framing) {
        case Http1BodyFraming.Empty =>
            if (!completed.remaining.isEmpty()) {
                throw Http1ParseException(
                    Http1ParseErrorCode.InvalidHeader,
                    "bodyless HTTP/1 request retained unexpected bytes; pipelining is disabled"
                )
            }
            RequestBody.empty().open()
        case Http1BodyFraming.ContentLength(length) =>
            if (completed.remaining.size > length) {
                throw Http1ParseException(
                    Http1ParseErrorCode.InvalidHeader,
                    "HTTP/1 request contains bytes past Content-Length; pipelining is disabled"
                )
            }
            Http1FixedBodyStream(transport, length, completed.remaining, context)
        case Http1BodyFraming.Chunked =>
            Http1ChunkedBodyStream(transport, completed.remaining, context, limits)
        case _ => throw Http1FramingException(
            Http1FramingErrorCode.ForbiddenBodyFraming,
            "HTTP/1 request cannot use close-delimited or tunnel body framing"
        )
    }
    let gated = if (headerContainsToken(head.headers, "expect", "100-continue") &&
        !isEmptyServerFraming(head.framing)) {
        Http1ContinueBodyStream(transport, source, head.method, context, limits)
    } else {
        source
    }
    let body = match (source) {
        case chunked: Http1ChunkedBodyStream =>
            ResponseBody(gated, observer: observer, trailerProvider: { => chunked.trailer })
        case _ => ResponseBody(gated, observer: observer)
    }
    Http1ServerRequest(head, body)
}

private class Http1ContinueBodyStream <: HttpBodyStream {
    private let transport: DuplexTransport
    private let delegate: HttpBodyStream
    private let method: HttpMethod
    private let context: OperationContext
    private let limits: HttpLimits
    private let mutex = Mutex()
    private var sent = false

    init(transport: DuplexTransport, delegate: HttpBodyStream, method: HttpMethod,
        context: OperationContext, limits: HttpLimits) {
        this.transport = transport
        this.delegate = delegate
        this.method = method
        this.context = context
        this.limits = limits
    }

    public prop contentLength: ?Int64 { get() { delegate.contentLength } }
    public func read(destination: Array<Byte>): Int64 {
        if (!destination.isEmpty()) { sendOnce() }
        delegate.read(destination)
    }
    public func close(): Unit { delegate.close() }
    public func isClosed(): Bool { delegate.isClosed() }

    private func sendOnce(): Unit {
        let shouldSend = synchronized(mutex) {
            if (sent) { false } else { sent = true; true }
        }
        if (shouldSend) {
            writeSerializedHead(
                transport,
                serializeResponseHead(100, "Continue", HttpHeaders(), method, limits: limits),
                context: context
            )
        }
    }
}

private class Http1ServerNoopObserver <: ResponseBodyObserver {
    public func completed(): Unit {}
    public func abandoned(): Unit {}
}

private func isEmptyServerFraming(framing: Http1BodyFraming): Bool {
    match (framing) {
        case Http1BodyFraming.Empty => true
        case _ => false
    }
}

private func copyServerPrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let result = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { result[index] = bytes[index] }
    result
}
