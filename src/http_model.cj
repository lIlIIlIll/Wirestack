package wirestack

import std.collection.ArrayList

/** An HTTP method token. Extension methods are supported without an enum ABI change. */
public struct HttpMethod <: Equatable<HttpMethod> & Hashable & ToString {
/**
 * Wirestack 公开 API：value。
 */
    public let value: String

/**
 * Wirestack 公开 API：init。
 * @param value 参数 value。
 */
    public init(value: String) {
        validateHttpToken(value, "HTTP method")
        this.value = value
    }

/**
 * Wirestack 公开 API：==。
 * @param other 参数 other。
 */
    public operator func ==(other: HttpMethod): Bool { value == other.value }
/**
 * Wirestack 公开 API：!=。
 * @param other 参数 other。
 */
    public operator func !=(other: HttpMethod): Bool { value != other.value }
/**
 * Wirestack 公开 API：hashCode。
 */
    public func hashCode(): Int64 { value.hashCode() }
/**
 * Wirestack 公开 API：toString。
 */
    public func toString(): String { value }
}

/**
 * Wirestack 公开 API：HttpVersion。
 */
public enum HttpVersion <: Equatable<HttpVersion> {
/**
 * Wirestack 公开 API：Http11。
 */
    | Http11
/**
 * Wirestack 公开 API：Http2。
 */
    | Http2

/**
 * Wirestack 公开 API：==。
 * @param other 参数 other。
 */
    public operator func ==(other: HttpVersion): Bool {
        match ((this, other)) {
            case (HttpVersion.Http11, HttpVersion.Http11) => true
            case (HttpVersion.Http2, HttpVersion.Http2) => true
            case _ => false
        }
    }

/**
 * Wirestack 公开 API：!=。
 * @param other 参数 other。
 */
    public operator func !=(other: HttpVersion): Bool { !(this == other) }
}

/** Parser and serializer bounds shared by the client and server paths. */
public class HttpLimits {
/**
 * Wirestack 公开 API：maxHeaderLineBytes。
 */
    public let maxHeaderLineBytes: Int64
/**
 * Wirestack 公开 API：maxHeaderBytes。
 */
    public let maxHeaderBytes: Int64
/**
 * Wirestack 公开 API：maxHeaderCount。
 */
    public let maxHeaderCount: Int64
/**
 * Wirestack 公开 API：maxChunkLineBytes。
 */
    public let maxChunkLineBytes: Int64
/**
 * Wirestack 公开 API：maxTrailerBytes。
 */
    public let maxTrailerBytes: Int64
/**
 * Wirestack 公开 API：maxTrailerCount。
 */
    public let maxTrailerCount: Int64
/**
 * Wirestack 公开 API：maxBodyBytes。
 */
    public let maxBodyBytes: Int64

/**
 * Wirestack 公开 API：init。
 * @param maxBodyBytes 参数 maxBodyBytes。
 * @param maxChunkLineBytes 参数 maxChunkLineBytes。
 * @param maxHeaderBytes 参数 maxHeaderBytes。
 * @param maxHeaderCount 参数 maxHeaderCount。
 * @param maxHeaderLineBytes 参数 maxHeaderLineBytes。
 * @param maxTrailerBytes 参数 maxTrailerBytes。
 * @param maxTrailerCount 参数 maxTrailerCount。
 */
    public init(
        maxHeaderLineBytes!: Int64 = 8192,
        maxHeaderBytes!: Int64 = 65536,
        maxHeaderCount!: Int64 = 100,
        maxChunkLineBytes!: Int64 = 8192,
        maxTrailerBytes!: Int64 = 16384,
        maxTrailerCount!: Int64 = 32,
        maxBodyBytes!: Int64 = 1073741824
    ) {
        if (maxHeaderLineBytes <= 0 || maxHeaderBytes <= 0 || maxHeaderCount <= 0 ||
            maxChunkLineBytes <= 0 || maxTrailerBytes <= 0 || maxTrailerCount <= 0 ||
            maxBodyBytes < 0) {
            throw IllegalArgumentException("HTTP limits must be positive (body may be zero)")
        }
        if (maxHeaderLineBytes > maxHeaderBytes) {
            throw IllegalArgumentException("header line limit cannot exceed total header limit")
        }
        this.maxHeaderLineBytes = maxHeaderLineBytes
        this.maxHeaderBytes = maxHeaderBytes
        this.maxHeaderCount = maxHeaderCount
        this.maxChunkLineBytes = maxChunkLineBytes
        this.maxTrailerBytes = maxTrailerBytes
        this.maxTrailerCount = maxTrailerCount
        this.maxBodyBytes = maxBodyBytes
    }
}

/** One ordered header field. Names retain spelling while lookup is ASCII-insensitive. */
public struct HttpHeader <: Equatable<HttpHeader> {
/**
 * Wirestack 公开 API：name。
 */
    public let name: String
/**
 * Wirestack 公开 API：value。
 */
    public let value: String

/**
 * Wirestack 公开 API：init。
 * @param name 参数 name。
 * @param value 参数 value。
 */
    public init(name: String, value: String) {
        validateHttpToken(name, "header name")
        validateHeaderValue(value)
        this.name = name
        this.value = value
    }

/**
 * Wirestack 公开 API：==。
 * @param other 参数 other。
 */
    public operator func ==(other: HttpHeader): Bool {
        name == other.name && value == other.value
    }
/**
 * Wirestack 公开 API：!=。
 * @param other 参数 other。
 */
    public operator func !=(other: HttpHeader): Bool { !(this == other) }
}

/** Immutable, insertion-ordered, multi-value HTTP headers. */
public class HttpHeaders {
    private let ownedEntries: Array<HttpHeader>

/**
 * Wirestack 公开 API：size。
 */
    public prop size: Int64 { get() { ownedEntries.size } }
/**
 * Wirestack 公开 API：entries。
 */
    public prop entries: Array<HttpHeader> { get() { ownedEntries.clone() } }

/**
 * Wirestack 公开 API：init。
 * @param entries 参数 entries。
 * @param limits 参数 limits。
 */
    public init(entries!: Array<HttpHeader> = Array<HttpHeader>(), limits!: HttpLimits = HttpLimits()) {
        validateHeaderCollection(entries, limits)
        ownedEntries = entries.clone()
    }

/**
 * Wirestack 公开 API：contains。
 * @param name 参数 name。
 */
    public func contains(name: String): Bool {
        validateHttpToken(name, "header name")
        for (entry in ownedEntries) {
            if (asciiCaseEqual(entry.name, name)) { return true }
        }
        false
    }

/**
 * Wirestack 公开 API：getFirst。
 * @param name 参数 name。
 */
    public func getFirst(name: String): ?String {
        validateHttpToken(name, "header name")
        for (entry in ownedEntries) {
            if (asciiCaseEqual(entry.name, name)) { return Some(entry.value) }
        }
        None<String>
    }

/**
 * Wirestack 公开 API：getAll。
 * @param name 参数 name。
 */
    public func getAll(name: String): Array<String> {
        validateHttpToken(name, "header name")
        let values = ArrayList<String>()
        for (entry in ownedEntries) {
            if (asciiCaseEqual(entry.name, name)) { values.add(entry.value) }
        }
        values.toArray()
    }

/**
 * Wirestack 公开 API：builder。
 * @param limits 参数 limits。
 */
    public static func builder(limits!: HttpLimits = HttpLimits()): HttpHeadersBuilder {
        HttpHeadersBuilder(limits: limits)
    }
}

/**
 * Wirestack 公开 API：HttpHeadersBuilder。
 */
public class HttpHeadersBuilder {
    private let limits: HttpLimits
    private var values = ArrayList<HttpHeader>()

/**
 * Wirestack 公开 API：init。
 * @param limits 参数 limits。
 */
    public init(limits!: HttpLimits = HttpLimits()) { this.limits = limits }

/**
 * Wirestack 公开 API：add。
 * @param name 参数 name。
 * @param value 参数 value。
 */
    public func add(name: String, value: String): HttpHeadersBuilder {
        let candidate = HttpHeader(name, value)
        let checked = ArrayList<HttpHeader>()
        for (entry in values) { checked.add(entry) }
        checked.add(candidate)
        validateHeaderCollection(checked.toArray(), limits)
        values.add(candidate)
        this
    }

/**
 * Wirestack 公开 API：set。
 * @param name 参数 name。
 * @param value 参数 value。
 */
    public func set(name: String, value: String): HttpHeadersBuilder {
        validateHttpToken(name, "header name")
        let replacement = HttpHeader(name, value)
        let updated = ArrayList<HttpHeader>()
        var inserted = false
        for (entry in values) {
            if (asciiCaseEqual(entry.name, name)) {
                if (!inserted) {
                    updated.add(replacement)
                    inserted = true
                }
            } else {
                updated.add(entry)
            }
        }
        if (!inserted) { updated.add(replacement) }
        validateHeaderCollection(updated.toArray(), limits)
        values = updated
        this
    }

/**
 * Wirestack 公开 API：remove。
 * @param name 参数 name。
 */
    public func remove(name: String): HttpHeadersBuilder {
        validateHttpToken(name, "header name")
        let retained = ArrayList<HttpHeader>()
        for (entry in values) {
            if (!asciiCaseEqual(entry.name, name)) { retained.add(entry) }
        }
        values = retained
        this
    }

/**
 * Wirestack 公开 API：build。
 */
    public func build(): HttpHeaders { HttpHeaders(entries: values.toArray(), limits: limits) }
}

/** Immutable trailer fields; routing and framing fields are never representable here. */
public class HttpTrailer {
/**
 * Wirestack 公开 API：headers。
 */
    public let headers: HttpHeaders

/**
 * Wirestack 公开 API：init。
 * @param headers 参数 headers。
 */
    public init(headers!: HttpHeaders = HttpHeaders()) {
        for (name in [
            "content-length", "transfer-encoding", "host", "connection",
            "trailer", "upgrade", "proxy-connection", "keep-alive"
        ]) {
            if (headers.contains(name)) {
                throw IllegalArgumentException("HTTP trailer contains a forbidden routing or framing field")
            }
        }
        this.headers = headers
    }
}

private func validateHeaderCollection(entries: Array<HttpHeader>, limits: HttpLimits): Unit {
    if (entries.size > limits.maxHeaderCount) {
        throw IllegalArgumentException("HTTP header count exceeds configured limit")
    }
    var total = 0
    for (entry in entries) {
        let lineSize = entry.name.toArray().size + entry.value.toArray().size + 4
        if (lineSize > limits.maxHeaderLineBytes) {
            throw IllegalArgumentException("HTTP header line exceeds configured limit")
        }
        total += lineSize
        if (total > limits.maxHeaderBytes) {
            throw IllegalArgumentException("HTTP headers exceed configured total limit")
        }
    }
}

private func validateHeaderValue(value: String): Unit {
    for (byte in value.toArray()) {
        if (byte == 0u8 || byte == 10u8 || byte == 13u8) {
            throw IllegalArgumentException("header value contains NUL, CR, or LF")
        }
        if ((byte < 32u8 && byte != 9u8) || byte == 127u8) {
            throw IllegalArgumentException("header value contains a control character")
        }
    }
}

private func validateHttpToken(value: String, kind: String): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty()) { throw IllegalArgumentException("${kind} must not be empty") }
    for (byte in bytes) {
        if (!isHttpTokenByte(byte)) {
            throw IllegalArgumentException("${kind} contains an invalid byte")
        }
    }
}

private func isHttpTokenByte(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'A' && value <= b'Z') ||
        (value >= b'a' && value <= b'z') || value == b'!' || value == b'#' ||
        value == b'$' || value == b'%' || value == b'&' || value == b'\'' ||
        value == b'*' || value == b'+' || value == b'-' || value == b'.' ||
        value == b'^' || value == b'_' || value == b'`' || value == b'|' || value == b'~'
}

private func asciiCaseEqual(left: String, right: String): Bool {
    let a = left.toArray()
    let b = right.toArray()
    if (a.size != b.size) { return false }
    for (index in 0..a.size) {
        if (asciiLower(a[index]) != asciiLower(b[index])) { return false }
    }
    true
}

private func asciiLower(value: Byte): Byte {
    if (value >= b'A' && value <= b'Z') { value + 32u8 } else { value }
}
