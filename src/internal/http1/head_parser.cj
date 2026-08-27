package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.internal.http_model.*

public enum Http1ParseErrorCode {
    | HeaderTooLarge
    | LineTooLong
    | InvalidLineEnding
    | InvalidStartLine
    | InvalidVersion
    | InvalidStatus
    | InvalidRequestTarget
    | InvalidHeader
    | ObsoleteLineFolding
    | MissingOrDuplicateHost
    | ParserAlreadyCompleted
}

public class Http1ParseException <: Exception {
    public let code: Http1ParseErrorCode

    public init(code: Http1ParseErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "Http1ParseException" }
}

public class Http1RequestHead {
    public let method: HttpMethod
    public let target: String
    public let version: HttpVersion
    public let headers: HttpHeaders
    public let framing: Http1BodyFraming

    public init(
        method: HttpMethod,
        target: String,
        version: HttpVersion,
        headers: HttpHeaders,
        framing: Http1BodyFraming
    ) {
        this.method = method
        this.target = target
        this.version = version
        this.headers = headers
        this.framing = framing
    }
}

public class Http1ResponseHead {
    public let version: HttpVersion
    public let status: UInt16
    public let reason: String
    public let headers: HttpHeaders
    public let framing: Http1BodyFraming

    public init(
        version: HttpVersion,
        status: UInt16,
        reason: String,
        headers: HttpHeaders,
        framing: Http1BodyFraming
    ) {
        this.version = version
        this.status = status
        this.reason = reason
        this.headers = headers
        this.framing = framing
    }
}

public struct Http1ParsedRequestHead {
    public let head: Http1RequestHead
    private let ownedRemaining: Array<Byte>

    public prop remaining: Array<Byte> { get() { ownedRemaining.clone() } }

    public init(head: Http1RequestHead, remaining: Array<Byte>) {
        this.head = head
        ownedRemaining = remaining.clone()
    }
}

public struct Http1ParsedResponseHead {
    public let head: Http1ResponseHead
    private let ownedRemaining: Array<Byte>

    public prop remaining: Array<Byte> { get() { ownedRemaining.clone() } }

    public init(head: Http1ResponseHead, remaining: Array<Byte>) {
        this.head = head
        ownedRemaining = remaining.clone()
    }
}

/** Incremental HTTP/1.1 server-side request-head parser. */
public class Http1RequestHeadParser {
    private let limits: HttpLimits
    private let accumulator: Http1HeadAccumulator

    public init(limits!: HttpLimits = HttpLimits()) {
        this.limits = limits
        accumulator = Http1HeadAccumulator(limits)
    }

    public func feed(input: Array<Byte>): ?Http1ParsedRequestHead {
        if (let Some(completed) <- accumulator.feed(input)) {
            let lines = splitHeadLines(completed.head)
            if (lines.size < 2) { invalidStartLine("HTTP request head is incomplete") }
            let start = parseRequestLine(lines[0])
            let headers = parseHeaders(lines, limits)
            validateHostHeader(headers, start.method, start.target)
            let framing = resolveRequestFraming(headers)
            return Some(Http1ParsedRequestHead(
                Http1RequestHead(start.method, start.target, HttpVersion.Http11, headers, framing),
                completed.remaining
            ))
        }
        None<Http1ParsedRequestHead>
    }
}

/** Incremental HTTP/1.1 client-side response-head parser. */
public class Http1ResponseHeadParser {
    private let limits: HttpLimits
    private let requestMethod: HttpMethod
    private let accumulator: Http1HeadAccumulator

    public init(requestMethod: HttpMethod, limits!: HttpLimits = HttpLimits()) {
        this.requestMethod = requestMethod
        this.limits = limits
        accumulator = Http1HeadAccumulator(limits)
    }

    public func feed(input: Array<Byte>): ?Http1ParsedResponseHead {
        if (let Some(completed) <- accumulator.feed(input)) {
            let lines = splitHeadLines(completed.head)
            if (lines.size < 2) { invalidStartLine("HTTP response head is incomplete") }
            let start = parseResponseLine(lines[0])
            let headers = parseHeaders(lines, limits)
            let framing = resolveResponseFraming(headers, start.status, requestMethod)
            return Some(Http1ParsedResponseHead(
                Http1ResponseHead(HttpVersion.Http11, start.status, start.reason, headers, framing),
                completed.remaining
            ))
        }
        None<Http1ParsedResponseHead>
    }
}

private struct CompletedHeadBytes {
    let head: Array<Byte>
    let remaining: Array<Byte>

    init(head: Array<Byte>, remaining: Array<Byte>) {
        this.head = head
        this.remaining = remaining
    }
}

private class Http1HeadAccumulator {
    private let limits: HttpLimits
    private let bytes = ArrayList<Byte>()
    private var lineBytes: Int64 = 0
    private var completed = false

    init(limits: HttpLimits) { this.limits = limits }

    func feed(input: Array<Byte>): ?CompletedHeadBytes {
        if (completed) {
            throw Http1ParseException(
                Http1ParseErrorCode.ParserAlreadyCompleted,
                "HTTP/1 head parser cannot be reused after completion"
            )
        }
        for (inputIndex in 0..input.size) {
            let value = input[inputIndex]
            let previous = if (bytes.isEmpty()) { None<Byte> } else { Some(bytes[bytes.size - 1]) }
            if (value == 10u8) {
                if (previous != Some(13u8)) { invalidLineEnding() }
                lineBytes = 0
            } else {
                if (previous == Some(13u8)) { invalidLineEnding() }
                if (value != 13u8) {
                    lineBytes += 1
                    if (lineBytes > limits.maxHeaderLineBytes) {
                        throw Http1ParseException(Http1ParseErrorCode.LineTooLong, "HTTP/1 line exceeds configured limit")
                    }
                }
            }
            bytes.add(value)
            if (bytes.size > limits.maxHeaderBytes) {
                throw Http1ParseException(Http1ParseErrorCode.HeaderTooLarge, "HTTP/1 head exceeds configured limit")
            }
            if (endsHead(bytes)) {
                completed = true
                return Some(CompletedHeadBytes(bytes.toArray(), copyRange(input, inputIndex + 1, input.size)))
            }
        }
        None<CompletedHeadBytes>
    }
}

private struct RequestLineParts {
    let method: HttpMethod
    let target: String
    init(method: HttpMethod, target: String) { this.method = method; this.target = target }
}

private struct ResponseLineParts {
    let status: UInt16
    let reason: String
    init(status: UInt16, reason: String) { this.status = status; this.reason = reason }
}

private func parseRequestLine(line: Array<Byte>): RequestLineParts {
    let first = findInLine(line, b' ', 0)
    let second = if (first < 0) { -1 } else { findInLine(line, b' ', first + 1) }
    if (first <= 0 || second <= first + 1 || second + 1 >= line.size ||
        findInLine(line, b' ', second + 1) >= 0) {
        invalidStartLine("HTTP/1 request line must contain method, target and version")
    }
    let method = try {
        HttpMethod(sliceString(line, 0, first))
    } catch (_: IllegalArgumentException) {
        invalidStartLine("HTTP/1 request method is invalid")
    }
    let target = sliceString(line, first + 1, second)
    validateRequestTarget(method, target)
    if (sliceString(line, second + 1, line.size) != "HTTP/1.1") { invalidVersion() }
    RequestLineParts(method, target)
}

private func parseResponseLine(line: Array<Byte>): ResponseLineParts {
    let first = findInLine(line, b' ', 0)
    let second = if (first < 0) { -1 } else { findInLine(line, b' ', first + 1) }
    if (first <= 0 || second != first + 4 || second >= line.size) {
        invalidStartLine("HTTP/1 response line must contain version, three-digit status and reason")
    }
    if (sliceString(line, 0, first) != "HTTP/1.1") { invalidVersion() }
    let statusBytes = copyRange(line, first + 1, second)
    var status: Int64 = 0
    for (value in statusBytes) {
        if (value < b'0' || value > b'9') { invalidStatus() }
        status = status * 10 + Int64(value - b'0')
    }
    if (status < 100 || status > 999) { invalidStatus() }
    let reason = sliceString(line, second + 1, line.size)
    for (value in reason.toArray()) {
        if ((value < 32u8 && value != 9u8) || value == 127u8) {
            invalidStartLine("HTTP/1 reason phrase contains a control byte")
        }
    }
    ResponseLineParts(UInt16(status), reason)
}

private func parseHeaders(lines: Array<Array<Byte>>, limits: HttpLimits): HttpHeaders {
    let builder = HttpHeaders.builder(limits: limits)
    for (lineIndex in 1..(lines.size - 1)) {
        let line = lines[lineIndex]
        if (line.isEmpty()) {
            throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "unexpected empty HTTP/1 header line")
        }
        if (line[0] == b' ' || line[0] == 9u8) {
            throw Http1ParseException(Http1ParseErrorCode.ObsoleteLineFolding, "HTTP/1 obs-fold is forbidden")
        }
        let colon = findInLine(line, b':', 0)
        if (colon <= 0) {
            throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "HTTP/1 header line has no valid field name")
        }
        let valueStart = trimStart(line, colon + 1, line.size)
        let valueEnd = trimEnd(line, valueStart, line.size)
        try {
            builder.add(sliceString(line, 0, colon), sliceString(line, valueStart, valueEnd))
        } catch (_: IllegalArgumentException) {
            throw Http1ParseException(Http1ParseErrorCode.InvalidHeader, "HTTP/1 header field is invalid")
        }
    }
    builder.build()
}

internal func validateHostHeader(headers: HttpHeaders, method: HttpMethod, target: String): Unit {
    let hosts = headers.getAll("host")
    if (hosts.size != 1) {
        throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "HTTP/1.1 request requires exactly one Host field")
    }
    let lowerTarget = target.toAsciiLower()
    if (lowerTarget.startsWith("http://") || lowerTarget.startsWith("https://")) {
        let targetUrl = HttpUrl.parse(target)
        let hostUrl = parseHostAuthority(hosts[0], targetUrl.scheme)
        if (!asciiEqual(targetUrl.host, hostUrl.host) || targetUrl.port != hostUrl.port) {
            throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "absolute-form target and Host authority differ")
        }
    } else if (method == HttpMethod("CONNECT")) {
        let targetUrl = HttpUrl.parse("http://${target}/")
        let hostUrl = parseHostAuthority(hosts[0], "http")
        if (!asciiEqual(targetUrl.host, hostUrl.host) || targetUrl.port != hostUrl.port) {
            throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "CONNECT target and Host authority differ")
        }
    } else {
        let _ = parseHostAuthority(hosts[0], "http")
    }
}

private func parseHostAuthority(value: String, scheme: String): HttpUrl {
    try {
        HttpUrl.parse("${scheme}://${value}/")
    } catch (_: IllegalArgumentException) {
        throw Http1ParseException(Http1ParseErrorCode.MissingOrDuplicateHost, "HTTP/1.1 Host field is invalid")
    }
}

internal func validateRequestTarget(method: HttpMethod, target: String): Unit {
    if (target == "*") {
        if (method != HttpMethod("OPTIONS")) { invalidTarget() }
        return
    }
    if (method == HttpMethod("CONNECT")) {
        if (target.contains("/") || target.contains("?") || target.contains("#")) { invalidTarget() }
        let url = try { HttpUrl.parse("http://${target}/") } catch (_: IllegalArgumentException) { invalidTarget() }
        if (!url.explicitPort) { invalidTarget() }
        return
    }
    let lowerTarget = target.toAsciiLower()
    if (lowerTarget.startsWith("http://") || lowerTarget.startsWith("https://")) {
        let _ = try { HttpUrl.parse(target) } catch (_: IllegalArgumentException) { invalidTarget() }
        return
    }
    let bytes = target.toArray()
    if (bytes.isEmpty() || bytes[0] != b'/') { invalidTarget() }
    var index = 0
    while (index < bytes.size) {
        let value = bytes[index]
        if (value <= 32u8 || value >= 127u8 || value == b'\\' || value == b'#') { invalidTarget() }
        if (value == b'%') {
            if (index + 2 >= bytes.size || !isHexTarget(bytes[index + 1]) || !isHexTarget(bytes[index + 2])) {
                invalidTarget()
            }
            index += 2
        }
        index += 1
    }
}

private func splitHeadLines(head: Array<Byte>): Array<Array<Byte>> {
    let lines = ArrayList<Array<Byte>>()
    var start = 0
    var index = 0
    while (index + 1 < head.size) {
        if (head[index] == 13u8 && head[index + 1] == 10u8) {
            lines.add(copyRange(head, start, index))
            start = index + 2
            index += 2
        } else {
            index += 1
        }
    }
    lines.toArray()
}

private func endsHead(bytes: ArrayList<Byte>): Bool {
    let size = bytes.size
    size >= 4 && bytes[size - 4] == 13u8 && bytes[size - 3] == 10u8 &&
        bytes[size - 2] == 13u8 && bytes[size - 1] == 10u8
}

private func findInLine(line: Array<Byte>, needle: Byte, start: Int64): Int64 {
    for (index in start..line.size) { if (line[index] == needle) { return index } }
    -1
}

private func trimStart(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var result = start
    while (result < end && (bytes[result] == b' ' || bytes[result] == 9u8)) { result += 1 }
    result
}

private func trimEnd(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var result = end
    while (result > start && (bytes[result - 1] == b' ' || bytes[result - 1] == 9u8)) { result -= 1 }
    result
}

private func copyRange(bytes: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    for (index in start..end) { output.add(bytes[index]) }
    output.toArray()
}

private func sliceString(bytes: Array<Byte>, start: Int64, end: Int64): String {
    String.fromUtf8(copyRange(bytes, start, end))
}

private func asciiEqual(left: String, right: String): Bool {
    left.toAsciiLower() == right.toAsciiLower()
}

private func isHexTarget(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}

private func invalidLineEnding(): Nothing {
    throw Http1ParseException(Http1ParseErrorCode.InvalidLineEnding, "HTTP/1 requires exact CRLF line endings")
}

private func invalidStartLine(message: String): Nothing {
    throw Http1ParseException(Http1ParseErrorCode.InvalidStartLine, message)
}

private func invalidVersion(): Nothing {
    throw Http1ParseException(Http1ParseErrorCode.InvalidVersion, "only HTTP/1.1 is accepted by the HTTP/1 parser")
}

private func invalidStatus(): Nothing {
    throw Http1ParseException(Http1ParseErrorCode.InvalidStatus, "HTTP/1 response status must contain three decimal digits")
}

private func invalidTarget(): Nothing {
    throw Http1ParseException(Http1ParseErrorCode.InvalidRequestTarget, "HTTP/1 request target is invalid or ambiguous")
}
