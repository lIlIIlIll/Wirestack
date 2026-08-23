package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.internal.http_model.*

public enum Http1BodyFraming {
    | Empty
    | ContentLength(Int64)
    | Chunked
    | CloseDelimited
    | Tunnel
}

public enum Http1FramingErrorCode {
    | ConflictingContentLength
    | InvalidContentLength
    | ContentLengthWithTransferEncoding
    | AmbiguousTransferEncoding
    | ForbiddenBodyFraming
}

public class Http1FramingException <: Exception {
    public let code: Http1FramingErrorCode

    public init(code: Http1FramingErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "Http1FramingException" }
}

/** Shared request framing decision used by both parser and serializer. */
public func resolveRequestFraming(headers: HttpHeaders): Http1BodyFraming {
    let contentLength = parseContentLength(headers)
    let chunked = parseTransferEncoding(headers)
    rejectClTeCombination(contentLength, chunked)
    if (chunked) { return Http1BodyFraming.Chunked }
    match (contentLength) {
        case Some(value) => if (value == 0) { Http1BodyFraming.Empty } else { Http1BodyFraming.ContentLength(value) }
        case None => Http1BodyFraming.Empty
    }
}

/** Shared response framing decision, including HEAD, CONNECT and bodyless statuses. */
public func resolveResponseFraming(
    headers: HttpHeaders,
    status: UInt16,
    requestMethod: HttpMethod
): Http1BodyFraming {
    if (status < 100 || status > 999) {
        throw IllegalArgumentException("HTTP response status must contain three digits")
    }
    let contentLength = parseContentLength(headers)
    let chunked = parseTransferEncoding(headers)
    rejectClTeCombination(contentLength, chunked)

    if (status < 200 || status == 204) {
        if (contentLength.isSome() || chunked) { forbiddenBodyFraming() }
        return Http1BodyFraming.Empty
    }
    if (requestMethod == HttpMethod("CONNECT") && status >= 200 && status < 300) {
        if (contentLength.isSome() || chunked) { forbiddenBodyFraming() }
        return Http1BodyFraming.Tunnel
    }
    if (requestMethod == HttpMethod("HEAD") || status == 304) {
        return Http1BodyFraming.Empty
    }
    if (chunked) { return Http1BodyFraming.Chunked }
    match (contentLength) {
        case Some(value) => if (value == 0) { Http1BodyFraming.Empty } else { Http1BodyFraming.ContentLength(value) }
        case None => Http1BodyFraming.CloseDelimited
    }
}

private func rejectClTeCombination(contentLength: ?Int64, chunked: Bool): Unit {
    if (chunked && contentLength.isSome()) {
        throw Http1FramingException(
            Http1FramingErrorCode.ContentLengthWithTransferEncoding,
            "Content-Length and Transfer-Encoding cannot frame the same HTTP/1 message"
        )
    }
}

private func parseContentLength(headers: HttpHeaders): ?Int64 {
    let fields = headers.getAll("content-length")
    var resolved: ?Int64 = None<Int64>
    for (field in fields) {
        let bytes = field.toArray()
        var start = 0
        while (start <= bytes.size) {
            var end = start
            while (end < bytes.size && bytes[end] != b',') { end += 1 }
            let value = parseDecimal(bytes, trimOwsStart(bytes, start, end), trimOwsEnd(bytes, start, end))
            if (let Some(existing) <- resolved) {
                if (existing != value) {
                    throw Http1FramingException(
                        Http1FramingErrorCode.ConflictingContentLength,
                        "HTTP/1 message contains conflicting Content-Length values"
                    )
                }
            } else {
                resolved = Some(value)
            }
            if (end == bytes.size) { break }
            start = end + 1
        }
    }
    resolved
}

private func parseTransferEncoding(headers: HttpHeaders): Bool {
    let codings = ArrayList<String>()
    for (field in headers.getAll("transfer-encoding")) {
        let bytes = field.toArray()
        var start = 0
        while (start <= bytes.size) {
            var end = start
            while (end < bytes.size && bytes[end] != b',') { end += 1 }
            let left = trimOwsStart(bytes, start, end)
            let right = trimOwsEnd(bytes, left, end)
            if (left == right) { ambiguousTransferEncoding() }
            codings.add(asciiSliceLower(bytes, left, right))
            if (end == bytes.size) { break }
            start = end + 1
        }
    }
    if (codings.isEmpty()) { return false }
    if (codings[codings.size - 1] != "chunked") { ambiguousTransferEncoding() }
    var chunkedCount = 0
    for (coding in codings) {
        if (coding == "chunked") { chunkedCount += 1 }
        else {
            // Unsupported transfer codings are rejected instead of being forwarded ambiguously.
            ambiguousTransferEncoding()
        }
    }
    if (chunkedCount != 1) { ambiguousTransferEncoding() }
    true
}

private func parseDecimal(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    if (start >= end || end - start > 19) {
        invalidContentLength()
    }
    var value: Int64 = 0
    for (index in start..end) {
        let digit = bytes[index]
        if (digit < b'0' || digit > b'9') { invalidContentLength() }
        let numeric = Int64(digit - b'0')
        if (value > (Int64.Max - numeric) / 10) { invalidContentLength() }
        value = value * 10 + numeric
    }
    value
}

private func invalidContentLength(): Nothing {
    throw Http1FramingException(
        Http1FramingErrorCode.InvalidContentLength,
        "HTTP/1 Content-Length must be one bounded non-negative decimal value"
    )
}

private func ambiguousTransferEncoding(): Nothing {
    throw Http1FramingException(
        Http1FramingErrorCode.AmbiguousTransferEncoding,
        "HTTP/1 Transfer-Encoding must be exactly one final chunked coding"
    )
}

private func forbiddenBodyFraming(): Nothing {
    throw Http1FramingException(
        Http1FramingErrorCode.ForbiddenBodyFraming,
        "HTTP/1 status or successful CONNECT forbids body framing fields"
    )
}

private func trimOwsStart(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var result = start
    while (result < end && (bytes[result] == b' ' || bytes[result] == 9u8)) { result += 1 }
    result
}

private func trimOwsEnd(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    var result = end
    while (result > start && (bytes[result - 1] == b' ' || bytes[result - 1] == 9u8)) { result -= 1 }
    result
}

private func asciiSliceLower(bytes: Array<Byte>, start: Int64, end: Int64): String {
    let output = ArrayList<Byte>()
    for (index in start..end) {
        let value = bytes[index]
        output.add(if (value >= b'A' && value <= b'Z') { value + 32u8 } else { value })
    }
    String.fromUtf8(output.toArray())
}
