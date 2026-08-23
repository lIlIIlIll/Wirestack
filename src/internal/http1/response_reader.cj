package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.http.*
import wirestack.internal.transport.*

private const HTTP1_READ_BUFFER_SIZE: Int64 = 16 * 1024
private const MAX_INTERIM_RESPONSES: Int64 = 16

public class Http1InterimResponse {
    public let status: UInt16
    public let reason: String
    public let headers: HttpHeaders

    public init(status: UInt16, reason: String, headers: HttpHeaders) {
        this.status = status
        this.reason = reason
        this.headers = headers
    }
}

public class Http1ResponseReadResult {
    public let response: HttpResponse
    private let ownedInterim: Array<Http1InterimResponse>

    public prop interimResponses: Array<Http1InterimResponse> { get() { ownedInterim.clone() } }

    public init(response: HttpResponse, interimResponses: Array<Http1InterimResponse>) {
        this.response = response
        ownedInterim = interimResponses.clone()
    }
}

/** Reads bounded interim heads and one final response, leaving the body fully streaming. */
public func readHttp1Response(
    transport: DuplexTransport,
    requestMethod: HttpMethod,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    observer!: ResponseBodyObserver = InternalNoopBodyObserver()
): Http1ResponseReadResult {
    var input = Array<Byte>()
    let interim = ArrayList<Http1InterimResponse>()
    while (true) {
        let parsed = readOneResponseHead(transport, requestMethod, input, context, limits)
        let head = parsed.head
        input = parsed.remaining
        if (head.status < 200 && head.status != 101) {
            interim.add(Http1InterimResponse(head.status, head.reason, head.headers))
            if (interim.size > MAX_INTERIM_RESPONSES) {
                throw Http1ParseException(Http1ParseErrorCode.HeaderTooLarge, "too many HTTP/1 interim responses")
            }
            continue
        }
        match (head.framing) {
            case Http1BodyFraming.Tunnel =>
                throw Http1ParseException(
                    Http1ParseErrorCode.InvalidStatus,
                    "successful CONNECT requires the explicit HTTP/1 tunnel API"
                )
            case _ => ()
        }
        if (head.status == 101) {
            throw Http1ParseException(
                Http1ParseErrorCode.InvalidStatus,
                "101 Switching Protocols requires the explicit HTTP/1 upgrade API"
            )
        }
        let source = responseBodySource(transport, head.framing, input, context, limits)
        let body = match (source) {
            case Http1ResponseBodySource.Plain(stream) => ResponseBody(stream, observer: observer)
            case Http1ResponseBodySource.Chunked(stream) =>
                ResponseBody(stream, observer: observer, trailerProvider: { => stream.trailer })
        }
        return Http1ResponseReadResult(
            HttpResponse(
                Int64(head.status), head.reason, body,
                version: head.version, headers: head.headers
            ),
            interim.toArray()
        )
    }
    throw Exception("unreachable HTTP/1 response loop exit")
}

private func readOneResponseHead(
    transport: DuplexTransport,
    requestMethod: HttpMethod,
    initial: Array<Byte>,
    context: OperationContext,
    limits: HttpLimits
): Http1ParsedResponseHead {
    let parser = Http1ResponseHeadParser(requestMethod, limits: limits)
    var input = initial
    while (true) {
        if (!input.isEmpty()) {
            if (let Some(parsed) <- parser.feed(input)) { return parsed }
        }
        let buffer = Array<Byte>(HTTP1_READ_BUFFER_SIZE, repeat: 0)
        match (transport.readSome(MutableByteSpan(buffer), context: context)) {
            case ReadResult.Data(count) =>
                if (count <= 0 || count > buffer.size) {
                    throw Exception("transport returned invalid progress while reading HTTP/1 head")
                }
                input = copyResponsePrefix(buffer, count)
            case ReadResult.EndOfStream =>
                throw NetworkException(
                    NetworkErrorCategory.Read,
                    NetworkPhase.HttpHeaders,
                    NetworkErrorCode.UnexpectedEof,
                    "peer closed before completing the HTTP/1 response head",
                    retryability: Retryability.Never
                )
        }
    }
    throw Exception("unreachable HTTP/1 head loop exit")
}

private enum Http1ResponseBodySource {
    | Plain(HttpBodyStream)
    | Chunked(Http1ChunkedBodyStream)
}

private func responseBodySource(
    transport: DuplexTransport,
    framing: Http1BodyFraming,
    initial: Array<Byte>,
    context: OperationContext,
    limits: HttpLimits
): Http1ResponseBodySource {
    match (framing) {
        case Http1BodyFraming.Empty =>
            if (!initial.isEmpty()) {
                throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "bodyless HTTP/1 response retained unexpected bytes")
            }
            Http1ResponseBodySource.Plain(RequestBody.empty().open())
        case Http1BodyFraming.ContentLength(length) =>
            if (initial.size > length) {
                throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "HTTP/1 response contains bytes past Content-Length")
            }
            Http1ResponseBodySource.Plain(Http1FixedBodyStream(transport, length, initial, context))
        case Http1BodyFraming.Chunked =>
            Http1ResponseBodySource.Chunked(Http1ChunkedBodyStream(transport, initial, context, limits))
        case Http1BodyFraming.CloseDelimited =>
            Http1ResponseBodySource.Plain(Http1CloseBodyStream(transport, initial, context, limits.maxBodyBytes))
        case Http1BodyFraming.Tunnel => throw Exception("tunnel framing was not intercepted")
    }
}

private class Http1FixedBodyStream <: HttpBodyStream {
    private let transport: DuplexTransport
    private let context: OperationContext
    private let initial: Array<Byte>
    private let length: Int64
    private var initialOffset: Int64 = 0
    private var consumed: Int64 = 0
    private var closed = false

    init(transport: DuplexTransport, length: Int64, initial: Array<Byte>, context: OperationContext) {
        this.transport = transport
        this.length = length
        this.initial = initial.clone()
        this.context = context
    }

    public prop contentLength: ?Int64 { get() { Some(length) } }
    public func read(destination: Array<Byte>): Int64 {
        ensureResponseStreamOpen(closed)
        if (destination.isEmpty() || consumed == length) { return 0 }
        let fromInitial = copyResponseBytes(initial, initialOffset, destination, length - consumed)
        if (fromInitial > 0) {
            initialOffset += fromInitial
            consumed += fromInitial
            return fromInitial
        }
        let wanted = min(destination.size, length - consumed)
        match (transport.readSome(MutableByteSpan(destination, length: wanted), context: context)) {
            case ReadResult.Data(count) =>
                if (count <= 0 || count > wanted) { invalidResponseProgress() }
                consumed += count
                count
            case ReadResult.EndOfStream => prematureResponseEof()
        }
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class Http1CloseBodyStream <: HttpBodyStream {
    private let transport: DuplexTransport
    private let context: OperationContext
    private let initial: Array<Byte>
    private let maximum: Int64
    private var initialOffset: Int64 = 0
    private var consumed: Int64 = 0
    private var eof = false
    private var closed = false

    init(transport: DuplexTransport, initial: Array<Byte>, context: OperationContext, maximum: Int64) {
        if (initial.size > maximum) { responseBodyTooLarge() }
        this.transport = transport
        this.initial = initial.clone()
        this.context = context
        this.maximum = maximum
    }

    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(destination: Array<Byte>): Int64 {
        ensureResponseStreamOpen(closed)
        if (destination.isEmpty() || eof) { return 0 }
        let fromInitial = copyResponseBytes(initial, initialOffset, destination, maximum - consumed)
        if (fromInitial > 0) {
            initialOffset += fromInitial
            consumed += fromInitial
            return fromInitial
        }
        if (consumed == maximum) {
            let probe = Array<Byte>(1, repeat: 0)
            return match (transport.readSome(MutableByteSpan(probe), context: context)) {
                case ReadResult.Data(_) => responseBodyTooLarge()
                case ReadResult.EndOfStream => eof = true; 0
            }
        }
        let wanted = min(destination.size, maximum - consumed)
        match (transport.readSome(MutableByteSpan(destination, length: wanted), context: context)) {
            case ReadResult.Data(count) =>
                if (count <= 0 || count > wanted) { invalidResponseProgress() }
                consumed += count
                count
            case ReadResult.EndOfStream => eof = true; 0
        }
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class Http1ChunkedBodyStream <: HttpBodyStream {
    private let transport: DuplexTransport
    private let context: OperationContext
    private let decoder: Http1ChunkedDecoder
    private var raw: Array<Byte>
    private var pending = Array<Byte>()
    private var pendingOffset: Int64 = 0
    private var complete = false
    private var closed = false
    private var completedTrailer: ?HttpTrailer = None<HttpTrailer>

    prop trailer: ?HttpTrailer { get() { completedTrailer } }
    public prop contentLength: ?Int64 { get() { None<Int64> } }

    init(transport: DuplexTransport, initial: Array<Byte>, context: OperationContext, limits: HttpLimits) {
        this.transport = transport
        raw = initial.clone()
        this.context = context
        decoder = Http1ChunkedDecoder(limits: limits)
    }

    public func read(destination: Array<Byte>): Int64 {
        ensureResponseStreamOpen(closed)
        if (destination.isEmpty()) { return 0 }
        while (true) {
            let copied = copyResponseBytes(pending, pendingOffset, destination, destination.size)
            if (copied > 0) { pendingOffset += copied; return copied }
            if (complete) { return 0 }
            let input = if (!raw.isEmpty()) {
                let value = raw
                raw = Array<Byte>()
                value
            } else {
                let buffer = Array<Byte>(HTTP1_READ_BUFFER_SIZE, repeat: 0)
                match (transport.readSome(MutableByteSpan(buffer), context: context)) {
                    case ReadResult.Data(count) =>
                        if (count <= 0 || count > buffer.size) { invalidResponseProgress() }
                        copyResponsePrefix(buffer, count)
                    case ReadResult.EndOfStream => decoder.finish(); complete = true; return 0
                }
            }
            let batch = decoder.feed(input)
            if (!batch.remaining.isEmpty()) {
                throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "chunked response retained unexpected post-body bytes")
            }
            pending = batch.data
            pendingOffset = 0
            if (batch.complete) {
                complete = true
                completedTrailer = batch.trailer
            }
        }
        throw Exception("unreachable chunked body loop exit")
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class InternalNoopBodyObserver <: ResponseBodyObserver {
    public func completed(): Unit {}
    public func abandoned(): Unit {}
}

private func copyResponseBytes(
    source: Array<Byte>,
    sourceOffset: Int64,
    destination: Array<Byte>,
    maximum: Int64
): Int64 {
    let count = min(min(source.size - sourceOffset, destination.size), maximum)
    for (index in 0..count) { destination[index] = source[sourceOffset + index] }
    count
}

private func copyResponsePrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let result = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { result[index] = bytes[index] }
    result
}

private func ensureResponseStreamOpen(closed: Bool): Unit {
    if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "HTTP/1 response body stream is closed") }
}

private func invalidResponseProgress(): Nothing {
    throw Exception("transport returned invalid progress while reading HTTP/1 body")
}

private func prematureResponseEof(): Nothing {
    throw NetworkException(
        NetworkErrorCategory.Read,
        NetworkPhase.HttpBody,
        NetworkErrorCode.UnexpectedEof,
        "peer closed before completing the HTTP/1 Content-Length body",
        retryability: Retryability.Never
    )
}

private func responseBodyTooLarge(): Nothing {
    throw Http1ChunkException(Http1ChunkErrorCode.BodyTooLarge, "HTTP/1 response body exceeds configured limit")
}
