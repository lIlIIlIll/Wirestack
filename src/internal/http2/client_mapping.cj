package wirestack.internal.http2

import std.collection.ArrayList
import wirestack.internal.http_model.*

private const HTTP2_MAX_INFORMATIONAL_RESPONSES: Int64 = 16

public enum Http2MessageErrorCode {
    | InvalidHeader
    | InvalidPseudoHeader
    | ForbiddenConnectionHeader
    | InvalidContentLength
    | BodyLengthMismatch
    | InvalidMessageSequence
}

/** A local message cannot be represented as one strict HTTP/2 exchange. */
public class Http2MessageException <: Exception {
    public let code: Http2MessageErrorCode

    public init(code: Http2MessageErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "Http2MessageException" }
}

/** Immutable outbound request metadata. Opening the body retains RequestBody's replay rules. */
public class Http2ClientRequestPlan {
    private let ownedInitialHeaders: Array<HpackFieldEncoding>
    private let requestBody: RequestBody
    private let trailer: HttpTrailer
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    public let endStreamOnHeaders: Bool

    public prop initialHeaders: Array<HpackFieldEncoding> { get() { ownedInitialHeaders.clone() } }

    internal init(
        initialHeaders: Array<HpackFieldEncoding>,
        requestBody: RequestBody,
        trailer: HttpTrailer,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        endStreamOnHeaders: Bool
    ) {
        ownedInitialHeaders = initialHeaders.clone()
        this.requestBody = requestBody
        this.trailer = trailer
        this.limits = limits
        this.http2Limits = http2Limits
        this.endStreamOnHeaders = endStreamOnHeaders
    }

    public func openBody(): Http2ClientRequestBody {
        if (endStreamOnHeaders) {
            throw Http2MessageException(
                Http2MessageErrorCode.InvalidMessageSequence,
                "HTTP/2 request ended on its initial HEADERS"
            )
        }
        Http2ClientRequestBody(requestBody.open(), trailer, limits, http2Limits)
    }
}

/**
 * Pull-based outbound DATA source. It never buffers body data, enforces the
 * configured byte bound, and exposes trailers only after a proven EOF.
 */
public class Http2ClientRequestBody <: Resource {
    private let stream: HttpBodyStream
    private let trailer: HttpTrailer
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private var consumed: Int64 = 0
    private var eof = false
    private var closed = false
    private var trailerClaimed = false

    internal init(stream: HttpBodyStream, trailer: HttpTrailer, limits: HttpLimits, http2Limits: Http2Limits) {
        this.stream = stream
        this.trailer = trailer
        this.limits = limits
        this.http2Limits = http2Limits
    }

    public prop contentLength: ?Int64 { get() { stream.contentLength } }
    public prop consumedBytes: Int64 { get() { consumed } }
    public prop isComplete: Bool { get() { eof } }

    public func read(destination: Array<Byte>): Int64 {
        requireRequestBodyOpen(closed)
        if (destination.isEmpty()) { return 0 }
        if (eof) { return 0 }
        let count = stream.read(destination)
        if (count < 0 || count > destination.size) { bodyMismatch("HTTP/2 request body returned invalid progress") }
        if (count == 0) {
            if (let Some(expected) <- contentLength) {
                if (consumed != expected) { bodyMismatch("HTTP/2 request body ended before Content-Length") }
            }
            eof = true
            return 0
        }
        if (count > limits.maxBodyBytes - consumed) {
            bodyMismatch("HTTP/2 request body exceeds the configured limit")
        }
        consumed += count
        if (let Some(expected) <- contentLength) {
            if (consumed > expected) { bodyMismatch("HTTP/2 request body exceeds Content-Length") }
        }
        count
    }

    /** Returns one terminal trailer block. An empty array still means END_STREAM. */
    public func finishTrailers(): Array<HpackFieldEncoding> {
        requireRequestBodyOpen(closed)
        if (!eof || trailerClaimed) {
            throw Http2MessageException(
                Http2MessageErrorCode.InvalidMessageSequence,
                "HTTP/2 request trailers require one proven body EOF"
            )
        }
        trailerClaimed = true
        encodeHttp2TrailerFields(trailer, limits: http2Limits)
    }

    public func close(): Unit {
        if (!closed) { closed = true; stream.close() }
    }

    public func isClosed(): Bool { closed }

    private func bodyMismatch(message: String): Nothing {
        try { close() } catch (_: Exception) {}
        throw Http2MessageException(Http2MessageErrorCode.BodyLengthMismatch, message)
    }
}

/** Maps one public request to RFC-ordered pseudo-fields plus lowercase regular fields. */
public func mapHttp2ClientRequest(
    request: HttpRequest,
    trailer!: HttpTrailer = HttpTrailer(),
    limits!: HttpLimits = HttpLimits(),
    http2Limits!: Http2Limits = Http2Limits()
): Http2ClientRequestPlan {
    validateKnownBodyBound(request.body.contentLength, limits)
    let fields = ArrayList<HpackFieldEncoding>()
    fields.add(h2Encoding(":method", request.method.value))
    let connect = request.method == HttpMethod("CONNECT")
    let authority = requestAuthority(request)
    if (connect) {
        fields.add(h2Encoding(":authority", authority))
    } else {
        fields.add(h2Encoding(":scheme", request.url.scheme))
        fields.add(h2Encoding(":authority", authority))
        fields.add(h2Encoding(":path", request.url.requestTarget))
    }

    let contentLength = validateOutboundHeaders(request.headers, request.body.contentLength, fields)
    if (contentLength.isNone()) {
        if (let Some(value) <- request.body.contentLength) {
            if (value > 0) { fields.add(h2Encoding("content-length", "${value}")) }
        }
    }
    let initial = fields.toArray()
    validateH2FieldBounds(initial, http2Limits)
    let endOnHeaders = request.body.contentLength == Some(0) && trailer.headers.size == 0
    Http2ClientRequestPlan(initial, request.body, trailer, limits, http2Limits, endOnHeaders)
}

public enum Http2ClientHeaderEventKind {
    | Informational
    | Final
    | Trailer
}

public class Http2ClientResponseHead {
    public let status: Int64
    public let headers: HttpHeaders
    public let endStream: Bool
    public let expectedContentLength: ?Int64

    internal init(status: Int64, headers: HttpHeaders, endStream: Bool, expectedContentLength: ?Int64) {
        this.status = status
        this.headers = headers
        this.endStream = endStream
        this.expectedContentLength = expectedContentLength
    }

    /** Binds protocol-neutral body ownership after the stream integration creates it. */
    public func toResponse(body: ResponseBody): HttpResponse {
        HttpResponse(status, "", body, version: HttpVersion.Http2, headers: headers)
    }
}

public class Http2ClientHeaderEvent {
    public let kind: Http2ClientHeaderEventKind
    public let head: ?Http2ClientResponseHead
    public let trailer: ?HttpTrailer

    internal init(
        kind: Http2ClientHeaderEventKind,
        head!: ?Http2ClientResponseHead = None<Http2ClientResponseHead>,
        trailer!: ?HttpTrailer = None<HttpTrailer>
    ) {
        this.kind = kind
        this.head = head
        this.trailer = trailer
    }
}

/** Strict per-stream response message sequence; DATA itself remains outside this accounting object. */
public class Http2ClientResponseSequence {
    private let streamId: Http2StreamId
    private let requestMethod: HttpMethod
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private var informationalCount: Int64 = 0
    private var finalHeadSeen = false
    private var bodyAllowed = false
    private var expectedContentLength: ?Int64 = None<Int64>
    private var receivedBodyBytes: Int64 = 0
    private var terminal = false
    private var retainedTrailer: ?HttpTrailer = None<HttpTrailer>

    public prop isTerminal: Bool { get() { terminal } }
    public prop bodyBytes: Int64 { get() { receivedBodyBytes } }
    public prop trailer: ?HttpTrailer { get() { retainedTrailer } }

    public init(
        streamId: Http2StreamId,
        requestMethod: HttpMethod,
        limits!: HttpLimits = HttpLimits(),
        http2Limits!: Http2Limits = Http2Limits()
    ) {
        if (!streamId.isStream()) { throw IllegalArgumentException("HTTP/2 response requires a stream id") }
        this.streamId = streamId
        this.requestMethod = requestMethod
        this.limits = limits
        this.http2Limits = http2Limits
    }

    public func acceptHeaders(fields: Array<HpackHeaderField>, endStream: Bool): Http2ClientHeaderEvent {
        requireResponseOpen()
        validateInboundH2FieldBounds(fields, streamId, http2Limits)
        if (!finalHeadSeen) {
            let parsed = parseResponseHead(fields, endStream)
            if (parsed.status < 200) {
                if (parsed.status == 101) {
                    responseProtocolError(streamId, "HTTP/2 does not use 101 Switching Protocols")
                }
                if (endStream || parsed.expectedContentLength.isSome()) {
                    responseProtocolError(streamId, "HTTP/2 informational response cannot end the stream or carry Content-Length")
                }
                informationalCount += 1
                if (informationalCount > HTTP2_MAX_INFORMATIONAL_RESPONSES) {
                    responseProtocolError(streamId, "HTTP/2 informational response limit exceeded")
                }
                return Http2ClientHeaderEvent(Http2ClientHeaderEventKind.Informational, head: Some(parsed))
            }
            validateFinalHead(parsed)
            finalHeadSeen = true
            expectedContentLength = parsed.expectedContentLength
            terminal = endStream
            return Http2ClientHeaderEvent(Http2ClientHeaderEventKind.Final, head: Some(parsed))
        }

        if (!endStream) { responseProtocolError(streamId, "HTTP/2 trailers must carry END_STREAM") }
        finishBodyLength()
        let decoded = decodeHttp2TrailerFields(fields, streamId, limits: limits)
        retainedTrailer = Some(decoded)
        terminal = true
        Http2ClientHeaderEvent(Http2ClientHeaderEventKind.Trailer, trailer: Some(decoded))
    }

    /** Accounts a DATA payload after flow control has admitted it. */
    public func acceptData(length: Int64, endStream: Bool): Unit {
        requireResponseOpen()
        if (!finalHeadSeen || !bodyAllowed) {
            responseProtocolError(streamId, "HTTP/2 DATA is not valid in the current response state")
        }
        if (length < 0 || length > limits.maxBodyBytes - receivedBodyBytes) {
            responseProtocolError(streamId, "HTTP/2 response body exceeds the configured limit")
        }
        receivedBodyBytes += length
        if (let Some(expected) <- expectedContentLength) {
            if (receivedBodyBytes > expected) {
                responseProtocolError(streamId, "HTTP/2 response body exceeds Content-Length")
            }
        }
        if (endStream) { finishBodyLength(); terminal = true }
    }

    private func parseResponseHead(fields: Array<HpackHeaderField>, endStream: Bool): Http2ClientResponseHead {
        let regular = ArrayList<HttpHeader>()
        var status: ?Int64 = None<Int64>
        var sawRegular = false
        for (field in fields) {
            validateInboundFieldName(field.name, streamId)
            if (field.name.startsWith(":")) {
                if (sawRegular || field.name != ":status" || status.isSome()) {
                    responseProtocolError(streamId, "HTTP/2 response pseudo-header order or set is invalid")
                }
                status = Some(parseStatus(field.value, streamId))
            } else {
                sawRegular = true
                validateInboundRegularField(field, streamId, true)
                try {
                    regular.add(HttpHeader(field.name, field.value))
                } catch (_: IllegalArgumentException) {
                    responseProtocolError(streamId, "HTTP/2 response field value is invalid")
                }
            }
        }
        let resolvedStatus = match (status) {
            case Some(value) => value
            case None => responseProtocolError(streamId, "HTTP/2 response requires exactly one :status")
        }
        let headers = boundedHeaders(regular.toArray(), limits, streamId)
        Http2ClientResponseHead(resolvedStatus, headers, endStream, parseH2ContentLength(headers, streamId))
    }

    private func validateFinalHead(head: Http2ClientResponseHead): Unit {
        let successfulConnect = requestMethod == HttpMethod("CONNECT") && head.status >= 200 && head.status < 300
        if ((head.status == 204 || successfulConnect) && head.expectedContentLength.isSome()) {
            responseProtocolError(streamId, "HTTP/2 response status forbids Content-Length")
        }
        if (head.status == 205) {
            if (let Some(expected) <- head.expectedContentLength) {
                if (expected != 0) {
                    responseProtocolError(streamId, "HTTP/2 205 response Content-Length must be zero")
                }
            }
        }
        bodyAllowed = requestMethod != HttpMethod("HEAD") && head.status != 204 &&
            head.status != 205 && head.status != 304
        if (bodyAllowed) {
            if (let Some(expected) <- head.expectedContentLength) {
                if (expected > limits.maxBodyBytes) {
                    responseProtocolError(streamId, "HTTP/2 response Content-Length exceeds the configured body limit")
                }
            }
        }
        if (!bodyAllowed && !head.endStream) {
            responseProtocolError(streamId, "HTTP/2 bodyless response must end on its final HEADERS")
        }
        if (head.endStream && bodyAllowed) {
            if (let Some(expected) <- head.expectedContentLength) {
                if (expected != 0) {
                    responseProtocolError(streamId, "HTTP/2 response body does not match Content-Length")
                }
            }
        }
    }

    private func finishBodyLength(): Unit {
        if (let Some(expected) <- expectedContentLength) {
            if (receivedBodyBytes != expected) {
                responseProtocolError(streamId, "HTTP/2 response body does not match Content-Length")
            }
        }
    }

    private func requireResponseOpen(): Unit {
        if (terminal) { responseProtocolError(streamId, "HTTP/2 response stream is already terminal") }
    }
}

/** Trailers are regular lowercase fields and never carry routing or framing metadata. */
public func encodeHttp2TrailerFields(
    trailer: HttpTrailer,
    limits!: Http2Limits = Http2Limits()
): Array<HpackFieldEncoding> {
    let output = ArrayList<HpackFieldEncoding>()
    for (entry in trailer.headers.entries) {
        let name = entry.name.toAsciiLower()
        if (isForbiddenH2ConnectionField(name) || name == "te") {
            throw Http2MessageException(Http2MessageErrorCode.ForbiddenConnectionHeader, "invalid HTTP/2 trailer field")
        }
        output.add(h2Encoding(name, entry.value, sensitive: isSensitiveH2Field(name)))
    }
    let fields = output.toArray()
    validateH2FieldBounds(fields, limits)
    fields
}

public func decodeHttp2TrailerFields(
    fields: Array<HpackHeaderField>,
    streamId: Http2StreamId,
    limits!: HttpLimits = HttpLimits()
): HttpTrailer {
    let regular = ArrayList<HttpHeader>()
    for (field in fields) {
        validateInboundFieldName(field.name, streamId)
        if (field.name.startsWith(":")) { responseProtocolError(streamId, "HTTP/2 trailers cannot contain pseudo-headers") }
        validateInboundRegularField(field, streamId, true)
        try { regular.add(HttpHeader(field.name, field.value)) }
        catch (_: IllegalArgumentException) { responseProtocolError(streamId, "HTTP/2 trailer field is invalid") }
    }
    try { HttpTrailer(headers: boundedHeaders(regular.toArray(), limits, streamId)) }
    catch (_: IllegalArgumentException) { responseProtocolError(streamId, "HTTP/2 trailer contains forbidden metadata") }
}

private func validateOutboundHeaders(
    headers: HttpHeaders,
    declaredBodyLength: ?Int64,
    output: ArrayList<HpackFieldEncoding>
): ?Int64 {
    var contentLength: ?Int64 = None<Int64>
    for (entry in headers.entries) {
        let name = entry.name.toAsciiLower()
        if (name == "host") {
            continue
        }
        if (isForbiddenH2ConnectionField(name)) {
            throw Http2MessageException(
                Http2MessageErrorCode.ForbiddenConnectionHeader,
                "HTTP/2 request contains a connection-specific field"
            )
        }
        if (name == "te" && !isTrailersValue(entry.value)) {
            throw Http2MessageException(Http2MessageErrorCode.InvalidHeader, "HTTP/2 TE field may contain only trailers")
        }
        if (name == "content-length") {
            let parsed = parseLocalContentLength(entry.value)
            if (let Some(existing) <- contentLength) {
                if (existing != parsed) { localContentLengthError() }
            } else { contentLength = Some(parsed) }
            continue
        }
        if (name == "trailer") { validateLocalTrailerDeclaration(entry.value) }
        output.add(h2Encoding(name, entry.value, sensitive: isSensitiveH2Field(name)))
    }
    if (let Some(value) <- contentLength) {
        if (declaredBodyLength != Some(value)) { localContentLengthError() }
        output.add(h2Encoding("content-length", "${value}"))
    }
    contentLength
}

private func requestAuthority(request: HttpRequest): String {
    let hosts = request.headers.getAll("host")
    if (hosts.size > 1) { localHeaderError("HTTP/2 request contains duplicate Host fields") }
    if (hosts.isEmpty()) { return request.url.authority }
    let authority = hosts[0]
    let parsed = try { HttpUrl.parse("${request.url.scheme}://${authority}/") }
    catch (_: Exception) { localHeaderError("HTTP/2 Host field is not a valid authority") }
    if (parsed.host.toAsciiLower() != request.url.host.toAsciiLower() || parsed.port != request.url.port) {
        localHeaderError("HTTP/2 Host field and request URL authority differ")
    }
    authority
}

private func validateKnownBodyBound(length: ?Int64, limits: HttpLimits): Unit {
    if (let Some(value) <- length) {
        if (value > limits.maxBodyBytes) {
            throw Http2MessageException(Http2MessageErrorCode.BodyLengthMismatch, "HTTP/2 request body exceeds limit")
        }
    }
}

private func validateH2FieldBounds(fields: Array<HpackFieldEncoding>, limits: Http2Limits): Unit {
    if (UInt64(fields.size) > UInt64(limits.maxHeaderFields)) {
        localHeaderError("HTTP/2 request header count exceeds limit")
    }
    var bytes = 0u64
    for (field in fields) {
        let size = field.field.tableSize
        if (size > UInt64(limits.maxHeaderListBytes) - min(bytes, UInt64(limits.maxHeaderListBytes))) {
            localHeaderError("HTTP/2 request header list exceeds limit")
        }
        bytes += size
    }
}

private func validateInboundFieldName(name: String, streamId: Http2StreamId): Unit {
    let bytes = name.toArray()
    if (bytes.isEmpty()) { responseProtocolError(streamId, "HTTP/2 field name is empty") }
    for (byte in bytes) {
        if (byte >= b'A' && byte <= b'Z') { responseProtocolError(streamId, "HTTP/2 field name contains uppercase") }
    }
}

private func validateInboundRegularField(field: HpackHeaderField, streamId: Http2StreamId, response: Bool): Unit {
    if (isForbiddenH2ConnectionField(field.name) || (response && field.name == "te")) {
        responseProtocolError(streamId, "HTTP/2 message contains a forbidden connection field")
    }
    if (!response && field.name == "te" && !isTrailersValue(field.value)) {
        responseProtocolError(streamId, "HTTP/2 TE field may contain only trailers")
    }
    if (field.name == "trailer") { validateInboundTrailerDeclaration(field.value, streamId) }
}

private func validateInboundH2FieldBounds(
    fields: Array<HpackHeaderField>, streamId: Http2StreamId, limits: Http2Limits
): Unit {
    if (UInt64(fields.size) > UInt64(limits.maxHeaderFields)) {
        responseProtocolError(streamId, "HTTP/2 field count exceeds the configured limit")
    }
    var bytes = 0u64
    for (field in fields) {
        let size = field.tableSize
        if (size > UInt64(limits.maxHeaderListBytes) - min(bytes, UInt64(limits.maxHeaderListBytes))) {
            responseProtocolError(streamId, "HTTP/2 field list exceeds the configured limit")
        }
        bytes += size
    }
}

private func boundedHeaders(entries: Array<HttpHeader>, limits: HttpLimits, streamId: Http2StreamId): HttpHeaders {
    try { HttpHeaders(entries: entries, limits: limits) }
    catch (_: IllegalArgumentException) { responseProtocolError(streamId, "HTTP/2 header collection exceeds limits") }
}

private func parseH2ContentLength(headers: HttpHeaders, streamId: Http2StreamId): ?Int64 {
    var resolved: ?Int64 = None<Int64>
    for (field in headers.getAll("content-length")) {
        let values = splitCommaValues(field, streamId)
        for (value in values) {
            let parsed = parseInboundDecimal(value, streamId)
            if (let Some(existing) <- resolved) {
                if (existing != parsed) { responseProtocolError(streamId, "HTTP/2 Content-Length values conflict") }
            } else { resolved = Some(parsed) }
        }
    }
    resolved
}

private func splitCommaValues(value: String, streamId: Http2StreamId): Array<String> {
    let bytes = value.toArray()
    let output = ArrayList<String>()
    var start: Int64 = 0
    while (start <= bytes.size) {
        var end = start
        while (end < bytes.size && bytes[end] != b',') { end += 1 }
        var left = start
        var right = end
        while (left < right && (bytes[left] == b' ' || bytes[left] == 9u8)) { left += 1 }
        while (right > left && (bytes[right - 1] == b' ' || bytes[right - 1] == 9u8)) { right -= 1 }
        if (left == right) { responseProtocolError(streamId, "HTTP/2 Content-Length contains an empty value") }
        let slice = Array<Byte>(right - left, repeat: 0)
        for (index in 0..slice.size) { slice[index] = bytes[left + index] }
        output.add(String.fromUtf8(slice))
        if (end == bytes.size) { break }
        start = end + 1
    }
    output.toArray()
}

private func parseStatus(value: String, streamId: Http2StreamId): Int64 {
    let bytes = value.toArray()
    if (bytes.size != 3) { responseProtocolError(streamId, "HTTP/2 :status must contain three digits") }
    var status: Int64 = 0
    for (byte in bytes) {
        if (byte < b'0' || byte > b'9') { responseProtocolError(streamId, "HTTP/2 :status is not decimal") }
        status = status * 10 + Int64(byte - b'0')
    }
    if (status < 100 || status > 599) { responseProtocolError(streamId, "HTTP/2 :status is outside 100..599") }
    status
}

private func parseLocalContentLength(value: String): Int64 {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 19) { localContentLengthError() }
    var result: Int64 = 0
    for (byte in bytes) {
        if (byte < b'0' || byte > b'9') { localContentLengthError() }
        let digit = Int64(byte - b'0')
        if (result > (Int64.Max - digit) / 10) { localContentLengthError() }
        result = result * 10 + digit
    }
    result
}

private func parseInboundDecimal(value: String, streamId: Http2StreamId): Int64 {
    try { parseLocalContentLength(value) }
    catch (_: Http2MessageException) { responseProtocolError(streamId, "HTTP/2 Content-Length is invalid") }
}

private func h2Encoding(name: String, value: String, sensitive!: Bool = false): HpackFieldEncoding {
    HpackFieldEncoding(HpackHeaderField(name, value, sensitive: sensitive))
}

private func isSensitiveH2Field(name: String): Bool {
    name == "authorization" || name == "proxy-authorization" || name == "cookie" || name == "set-cookie"
}

private func isForbiddenH2ConnectionField(name: String): Bool {
    name == "connection" || name == "proxy-connection" || name == "keep-alive" ||
        name == "transfer-encoding" || name == "upgrade"
}

private func isTrailersValue(value: String): Bool {
    value.toAsciiLower().trimAscii() == "trailers"
}

private func validateLocalTrailerDeclaration(value: String): Unit {
    let names = localCommaTokens(value)
    for (name in names) {
        let lowered = name.toAsciiLower()
        try { let _ = HttpHeader(lowered, "") }
        catch (_: IllegalArgumentException) { localHeaderError("HTTP/2 Trailer declaration contains an invalid name") }
        if (isForbiddenTrailerName(lowered)) {
            localHeaderError("HTTP/2 Trailer declaration contains a forbidden name")
        }
    }
}

private func validateInboundTrailerDeclaration(value: String, streamId: Http2StreamId): Unit {
    let names = try { localCommaTokens(value) }
    catch (_: Http2MessageException) { responseProtocolError(streamId, "HTTP/2 Trailer declaration is invalid") }
    for (name in names) {
        let lowered = name.toAsciiLower()
        try { let _ = HttpHeader(lowered, "") }
        catch (_: IllegalArgumentException) { responseProtocolError(streamId, "HTTP/2 Trailer declaration is invalid") }
        if (isForbiddenTrailerName(lowered)) {
            responseProtocolError(streamId, "HTTP/2 Trailer declaration contains a forbidden name")
        }
    }
}

private func localCommaTokens(value: String): Array<String> {
    let bytes = value.toArray()
    let output = ArrayList<String>()
    var start: Int64 = 0
    while (start <= bytes.size) {
        var end = start
        while (end < bytes.size && bytes[end] != b',') { end += 1 }
        var left = start
        var right = end
        while (left < right && (bytes[left] == b' ' || bytes[left] == 9u8)) { left += 1 }
        while (right > left && (bytes[right - 1] == b' ' || bytes[right - 1] == 9u8)) { right -= 1 }
        if (left == right) { localHeaderError("HTTP/2 comma-separated field contains an empty token") }
        let slice = Array<Byte>(right - left, repeat: 0)
        for (index in 0..slice.size) { slice[index] = bytes[left + index] }
        output.add(String.fromUtf8(slice))
        if (end == bytes.size) { break }
        start = end + 1
    }
    output.toArray()
}

private func isForbiddenTrailerName(name: String): Bool {
    isForbiddenH2ConnectionField(name) || name == "content-length" || name == "host" ||
        name == "trailer" || name == "te"
}

private func requireRequestBodyOpen(closed: Bool): Unit {
    if (closed) {
        throw Http2MessageException(Http2MessageErrorCode.InvalidMessageSequence, "HTTP/2 request body is closed")
    }
}

private func localHeaderError(message: String): Nothing {
    throw Http2MessageException(Http2MessageErrorCode.InvalidHeader, message)
}

private func localContentLengthError(): Nothing {
    throw Http2MessageException(Http2MessageErrorCode.InvalidContentLength, "HTTP/2 Content-Length is invalid")
}

private func responseProtocolError(streamId: Http2StreamId, message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(streamId), message)
}
