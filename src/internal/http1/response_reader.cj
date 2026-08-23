package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.Mutex
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
    public let reusableCandidate: Bool
    private let ownedInterim: Array<Http1InterimResponse>

    public prop interimResponses: Array<Http1InterimResponse> { get() { ownedInterim.clone() } }

    public init(
        response: HttpResponse,
        interimResponses: Array<Http1InterimResponse>,
        reusableCandidate!: Bool = true
    ) {
        this.response = response
        ownedInterim = interimResponses.clone()
        this.reusableCandidate = reusableCandidate
    }
}

public class Http1Tunnel {
    public let responseHead: Http1ResponseHead
    public let transport: DuplexTransport

    public init(responseHead: Http1ResponseHead, transport: DuplexTransport) {
        this.responseHead = responseHead
        this.transport = transport
    }
}

public enum Http1ConnectExchangeResult {
    | Tunnel(Http1Tunnel)
    | Response(Http1ResponseReadResult)
}

public class Http1Upgrade {
    public let responseHead: Http1ResponseHead
    public let protocol: String
    public let transport: DuplexTransport

    public init(responseHead: Http1ResponseHead, protocol: String, transport: DuplexTransport) {
        this.responseHead = responseHead
        this.protocol = protocol
        this.transport = transport
    }
}

public enum Http1UpgradeExchangeResult {
    | Upgraded(Http1Upgrade)
    | Response(Http1ResponseReadResult)
}

/** Reads bounded interim heads and one final response, leaving the body fully streaming. */
public func readHttp1Response(
    transport: DuplexTransport,
    requestMethod: HttpMethod,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    observer!: ResponseBodyObserver = InternalNoopBodyObserver()
): Http1ResponseReadResult {
    let reader = Http1ResponseSequenceReader(transport, requestMethod, limits)
    let interim = ArrayList<Http1InterimResponse>()
    while (true) {
        let parsed = reader.readNext(context)
        let head = parsed.head
        if (head.status < 200 && head.status != 101) {
            addInterim(interim, head)
            continue
        }
        return finishResponse(transport, head, parsed.remaining, interim, context, limits, observer)
    }
    throw Exception("unreachable HTTP/1 response loop exit")
}

/**
 * Sends a body only after 100 Continue or after the bounded continue wait expires.
 * A final response received first leaves the request body unopened.
 */
public func exchangeHttp1ExpectContinue(
    transport: DuplexTransport,
    request: HttpRequest,
    writer: Http1RequestWriter,
    continueTimeout: Duration,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    observer!: ResponseBodyObserver = InternalNoopBodyObserver()
): Http1ResponseReadResult {
    if (continueTimeout <= Duration.Zero) {
        throw IllegalArgumentException("HTTP/1 continue timeout must be positive")
    }
    writer.writeHead(transport, context: context)
    let continueContext = context.shortenDeadline(continueTimeout)
    let reader = Http1ResponseSequenceReader(transport, request.method, limits)
    let interim = ArrayList<Http1InterimResponse>()
    var bodySent = false
    while (true) {
        let parsed = try {
            reader.readNext(if (bodySent) { context } else { continueContext })
        } catch (error: NetworkException) {
            if (!bodySent && !context.isDeadlineExceeded() && isContinueWaitTimeout(error)) {
                writer.writeBody(transport, context: context)
                bodySent = true
                continue
            }
            throw error
        }
        let head = parsed.head
        if (head.status < 200 && head.status != 101) {
            addInterim(interim, head)
            if (head.status == 100 && !bodySent) {
                writer.writeBody(transport, context: context)
                bodySent = true
            }
            continue
        }
        return finishResponse(transport, head, parsed.remaining, interim, context, limits, observer)
    }
    throw Exception("unreachable HTTP/1 expect-continue loop exit")
}

/** Consumes the input transport and transfers it only after a successful CONNECT response. */
public func performHttp1Connect(
    transport: DuplexTransport,
    target: HttpUrl,
    headers!: HttpHeaders = HttpHeaders(),
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits()
): Http1ConnectExchangeResult {
    let request = HttpRequest(HttpMethod("CONNECT"), target, headers: headers)
    try {
        let _ = writeHttp1Request(transport, request, context: context, limits: limits)
        let reader = Http1ResponseSequenceReader(transport, request.method, limits)
        let interim = ArrayList<Http1InterimResponse>()
        while (true) {
            let parsed = reader.readNext(context)
            let head = parsed.head
            if (head.status < 200 && head.status != 101) {
                addInterim(interim, head)
                continue
            }
            if (head.status >= 200 && head.status < 300) {
                match (head.framing) {
                    case Http1BodyFraming.Tunnel =>
                        return Http1ConnectExchangeResult.Tunnel(
                            Http1Tunnel(head, Http1PrefixedTransport(transport, parsed.remaining))
                        )
                    case _ => throw Http1ParseException(
                        Http1ParseErrorCode.InvalidStatus,
                        "successful CONNECT response did not enter tunnel framing"
                    )
                }
            }
            let observer = Http1ConnectFailureObserver(transport)
            return Http1ConnectExchangeResult.Response(
                finishResponse(transport, head, parsed.remaining, interim, context, limits, observer)
            )
        }
        throw Exception("unreachable HTTP/1 CONNECT loop exit")
    } catch (error: Exception) {
        try { transport.abort(reason: Some(AbortReason.ProtocolFailure)) } catch (_: Exception) {}
        throw error
    }
}

/** Consumes the input transport and transfers it only after a matching 101 response. */
public func performHttp1Upgrade(
    transport: DuplexTransport,
    request: HttpRequest,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits()
): Http1UpgradeExchangeResult {
    let requestedProtocol = validateUpgradeRequest(request)
    try {
        let _ = writeHttp1Request(transport, request, context: context, limits: limits)
        let reader = Http1ResponseSequenceReader(transport, request.method, limits)
        let interim = ArrayList<Http1InterimResponse>()
        while (true) {
            let parsed = reader.readNext(context)
            let head = parsed.head
            if (head.status < 200 && head.status != 101) {
                addInterim(interim, head)
                continue
            }
            if (head.status == 101) {
                let responseProtocol = validateUpgradeResponse(head, requestedProtocol)
                return Http1UpgradeExchangeResult.Upgraded(
                    Http1Upgrade(
                        head, responseProtocol,
                        Http1PrefixedTransport(transport, parsed.remaining)
                    )
                )
            }
            let observer = Http1ConnectFailureObserver(transport)
            return Http1UpgradeExchangeResult.Response(
                finishResponse(transport, head, parsed.remaining, interim, context, limits, observer)
            )
        }
        throw Exception("unreachable HTTP/1 Upgrade loop exit")
    } catch (error: Exception) {
        try { transport.abort(reason: Some(AbortReason.ProtocolFailure)) } catch (_: Exception) {}
        throw error
    }
}

private func validateUpgradeRequest(request: HttpRequest): String {
    if (request.method == HttpMethod("CONNECT") || request.body.contentLength != Some(0) ||
        !headerContainsToken(request.headers, "connection", "upgrade")) {
        throw Http1ParseException(
            Http1ParseErrorCode.InvalidHeader,
            "HTTP/1 Upgrade requires a non-CONNECT empty request with Connection: upgrade"
        )
    }
    let values = request.headers.getAll("upgrade")
    if (values.size != 1 || !isUpgradeProtocol(values[0])) {
        throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "HTTP/1 Upgrade requires one protocol token")
    }
    values[0]
}

private func validateUpgradeResponse(head: Http1ResponseHead, requestedProtocol: String): String {
    let values = head.headers.getAll("upgrade")
    if (!headerContainsToken(head.headers, "connection", "upgrade") || values.size != 1 ||
        !isUpgradeProtocol(values[0]) || values[0].toAsciiLower() != requestedProtocol.toAsciiLower()) {
        throw Http1ParseException(
            Http1ParseErrorCode.InvalidHeader,
            "HTTP/1 101 response does not confirm the requested Upgrade protocol"
        )
    }
    values[0]
}

private func isUpgradeProtocol(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty()) { return false }
    var slash: Int64 = -1
    for (index in 0..bytes.size) {
        if (bytes[index] == b'/') {
            if (slash >= 0) { return false }
            slash = index
        } else if (!isUpgradeTokenByte(bytes[index])) {
            return false
        }
    }
    slash != 0 && slash != bytes.size - 1
}

private func isUpgradeTokenByte(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'!' || byte == b'#' || byte == b'$' ||
        byte == b'%' || byte == b'&' || byte == b'\'' || byte == b'*' || byte == b'+' ||
        byte == b'-' || byte == b'.' || byte == b'^' || byte == b'_' || byte == b'`' ||
        byte == b'|' || byte == b'~'
}

private class Http1ConnectFailureObserver <: ResponseBodyObserver {
    private let transport: DuplexTransport
    init(transport: DuplexTransport) { this.transport = transport }
    public func completed(): Unit { closeConnectTransport() }
    public func abandoned(): Unit { closeConnectTransport() }
    private func closeConnectTransport(): Unit {
        try { transport.close(OperationContext.background()) } catch (_: Exception) {}
    }
}

/** Replays bytes read with the CONNECT response before delegating tunnel I/O. */
private class Http1PrefixedTransport <: DuplexTransport {
    private let delegate: DuplexTransport
    private let prefix: Array<Byte>
    private var offset: Int64 = 0
    private let mutex = Mutex()
    private var readActive = false

    init(delegate: DuplexTransport, prefix: Array<Byte>) {
        this.delegate = delegate
        this.prefix = prefix.clone()
    }

    public prop info: TransportInfo { get() { delegate.info } }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        if (context.isCancellationRequested()) {
            throw NetworkException(
                NetworkErrorCategory.Cancelled, NetworkPhase.TcpRead, NetworkErrorCode.Cancelled,
                "CONNECT tunnel read cancelled", retryability: Retryability.Never
            )
        }
        if (context.isDeadlineExceeded()) {
            throw NetworkException(
                NetworkErrorCategory.DeadlineExceeded, NetworkPhase.TcpRead, NetworkErrorCode.TimedOut,
                "CONNECT tunnel read deadline exceeded", retryability: Retryability.Temporary
            )
        }
        synchronized(mutex) {
            if (readActive) {
                throw NetworkException(
                    NetworkErrorCategory.Read, NetworkPhase.TcpRead, NetworkErrorCode.ConcurrentOperation,
                    "CONNECT tunnel already has an active reader", retryability: Retryability.Never
                )
            }
            readActive = true
        }
        try {
            if (destination.isEmpty()) { return ReadResult.Data(0) }
            let count = synchronized(mutex) {
                let available = prefix.size - offset
                let copied = min(destination.length, available)
                for (index in 0..copied) {
                    destination.bytes[destination.offset + index] = prefix[offset + index]
                }
                offset += copied
                copied
            }
            if (count > 0) { ReadResult.Data(count) }
            else { delegate.readSome(destination, context: context) }
        } finally {
            synchronized(mutex) { readActive = false }
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 { delegate.writeSome(source, context: context) }

    public func shutdown(direction: ShutdownDirection): Unit { delegate.shutdown(direction) }
    public func close(context: OperationContext): Unit { delegate.close(context) }
    public func close(): Unit { delegate.close() }
    public func isClosed(): Bool { delegate.isClosed() }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { delegate.abort(reason: reason) }
}

private func addInterim(interim: ArrayList<Http1InterimResponse>, head: Http1ResponseHead): Unit {
    interim.add(Http1InterimResponse(head.status, head.reason, head.headers))
    if (interim.size > MAX_INTERIM_RESPONSES) {
        throw Http1ParseException(Http1ParseErrorCode.HeaderTooLarge, "too many HTTP/1 interim responses")
    }
}

private func finishResponse(
    transport: DuplexTransport,
    head: Http1ResponseHead,
    input: Array<Byte>,
    interim: ArrayList<Http1InterimResponse>,
    context: OperationContext,
    limits: HttpLimits,
    observer: ResponseBodyObserver
): Http1ResponseReadResult {
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
    Http1ResponseReadResult(
        HttpResponse(Int64(head.status), head.reason, body, version: head.version, headers: head.headers),
        interim.toArray(), reusableCandidate: responseCanReuse(head)
    )
}

private func isContinueWaitTimeout(error: NetworkException): Bool {
    match (error.code) {
        case NetworkErrorCode.TimedOut => true
        case _ => false
    }
}

private func responseCanReuse(head: Http1ResponseHead): Bool {
    match (head.framing) {
        case Http1BodyFraming.CloseDelimited | Http1BodyFraming.Tunnel => return false
        case _ => ()
    }
    !headerContainsToken(head.headers, "connection", "close")
}

internal func headerContainsToken(headers: HttpHeaders, name: String, token: String): Bool {
    for (field in headers.getAll(name)) {
        let bytes = field.toArray()
        var start = 0
        while (start <= bytes.size) {
            var end = start
            while (end < bytes.size && bytes[end] != b',') { end += 1 }
            var left = start
            var right = end
            while (left < right && (bytes[left] == b' ' || bytes[left] == 9u8)) { left += 1 }
            while (right > left && (bytes[right - 1] == b' ' || bytes[right - 1] == 9u8)) { right -= 1 }
            if (String.fromUtf8(copyResponseRange(bytes, left, right)).toAsciiLower() == token.toAsciiLower()) {
                return true
            }
            if (end == bytes.size) { break }
            start = end + 1
        }
    }
    false
}

private class Http1ResponseSequenceReader {
    private let transport: DuplexTransport
    private let requestMethod: HttpMethod
    private let limits: HttpLimits
    private var parser: Http1ResponseHeadParser
    private var input = Array<Byte>()

    init(transport: DuplexTransport, requestMethod: HttpMethod, limits: HttpLimits) {
        this.transport = transport
        this.requestMethod = requestMethod
        this.limits = limits
        parser = Http1ResponseHeadParser(requestMethod, limits: limits)
    }

    func readNext(context: OperationContext): Http1ParsedResponseHead {
        while (true) {
            if (!input.isEmpty()) {
                let current = input
                input = Array<Byte>()
                if (let Some(parsed) <- parser.feed(current)) {
                    input = parsed.remaining
                    parser = Http1ResponseHeadParser(requestMethod, limits: limits)
                    return Http1ParsedResponseHead(parsed.head, input)
                }
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

private func copyResponseRange(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let result = Array<Byte>(end - start, repeat: 0)
    for (index in start..end) { result[index - start] = bytes[index] }
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
