package wirestack

import std.collection.ArrayList

/** Canonical absolute HTTP(S) URL with a DNS-free authority representation. */
public class HttpUrl <: ToString {
    public let scheme: String
    public let host: String
    public let port: UInt16
    public let explicitPort: Bool
    public let authority: String
    public let requestTarget: String
    private let serialized: String

    private init(
        scheme: String,
        host: String,
        port: UInt16,
        explicitPort: Bool,
        authority: String,
        requestTarget: String,
        serialized: String
    ) {
        this.scheme = scheme
        this.host = host
        this.port = port
        this.explicitPort = explicitPort
        this.authority = authority
        this.requestTarget = requestTarget
        this.serialized = serialized
    }

    public static func parse(value: String): HttpUrl {
        let bytes = value.toArray()
        if (bytes.isEmpty() || bytes.size > 8192) {
            throw IllegalArgumentException("HTTP URL must contain 1 to 8192 ASCII bytes")
        }
        validateUrlBytes(bytes)

        let schemeEnd = findSequence(bytes, [b':', b'/', b'/'], 0)
        if (schemeEnd < 0) {
            throw IllegalArgumentException("HTTP URL must be absolute and contain ://")
        }
        let rawScheme = bytesToString(bytes, 0, schemeEnd)
        let scheme = rawScheme.toAsciiLower()
        if (scheme != "http" && scheme != "https") {
            throw IllegalArgumentException("HTTP URL scheme must be http or https")
        }

        let authorityStart = schemeEnd + 3
        let authorityEnd = findAuthorityEnd(bytes, authorityStart)
        if (authorityStart == authorityEnd) {
            throw IllegalArgumentException("HTTP URL authority must not be empty")
        }
        let parsed = parseAuthority(bytes, authorityStart, authorityEnd, scheme)
        let target = parseRequestTarget(bytes, authorityEnd)
        let canonicalAuthority = if (parsed.ipv6) {
            if (parsed.explicitPort) { "[${parsed.host}]:${parsed.port}" } else { "[${parsed.host}]" }
        } else {
            if (parsed.explicitPort) { "${parsed.host}:${parsed.port}" } else { parsed.host }
        }
        let serialized = "${scheme}://${canonicalAuthority}${target}"
        HttpUrl(
            scheme,
            parsed.host,
            UInt16(parsed.port),
            parsed.explicitPort,
            canonicalAuthority,
            target,
            serialized
        )
    }

    public func toString(): String { serialized }
}

private struct ParsedAuthority {
    let host: String
    let port: Int64
    let explicitPort: Bool
    let ipv6: Bool

    init(host: String, port: Int64, explicitPort: Bool, ipv6: Bool) {
        this.host = host
        this.port = port
        this.explicitPort = explicitPort
        this.ipv6 = ipv6
    }
}

private func parseAuthority(bytes: Array<Byte>, start: Int64, end: Int64, scheme: String): ParsedAuthority {
    for (index in start..end) {
        if (bytes[index] == b'@') {
            throw IllegalArgumentException("userinfo is not supported in HTTP URL authority")
        }
    }
    let defaultPort: Int64 = if (scheme == "https") { 443 } else { 80 }
    if (bytes[start] == b'[') {
        let closing = findByte(bytes, b']', start + 1, end)
        if (closing < 0 || closing == start + 1) {
            throw IllegalArgumentException("IPv6 URL host must have matching brackets")
        }
        let host = bytesToString(bytes, start + 1, closing).toAsciiLower()
        validateIpv6Literal(host)
        if (closing + 1 == end) {
            return ParsedAuthority(host, defaultPort, false, true)
        }
        if (bytes[closing + 1] != b':') {
            throw IllegalArgumentException("unexpected bytes after bracketed IPv6 host")
        }
        let port = parsePort(bytes, closing + 2, end)
        return ParsedAuthority(host, port, true, true)
    }

    let colon = findByte(bytes, b':', start, end)
    var hostEnd = end
    var port = defaultPort
    var explicitPort = false
    if (colon >= 0) {
        if (findByte(bytes, b':', colon + 1, end) >= 0) {
            throw IllegalArgumentException("IPv6 URL hosts must use brackets")
        }
        hostEnd = colon
        port = parsePort(bytes, colon + 1, end)
        explicitPort = true
    }
    let host = bytesToString(bytes, start, hostEnd).toAsciiLower()
    validateDnsOrIpv4Host(host)
    ParsedAuthority(host, port, explicitPort, false)
}

private func parseRequestTarget(bytes: Array<Byte>, start: Int64): String {
    if (start == bytes.size) { return "/" }
    if (bytes[start] == b'?') {
        return "/${bytesToString(bytes, start, bytes.size)}"
    }
    if (bytes[start] != b'/') {
        throw IllegalArgumentException("HTTP URL path must start with /")
    }
    bytesToString(bytes, start, bytes.size)
}

private func validateUrlBytes(bytes: Array<Byte>): Unit {
    var index = 0
    while (index < bytes.size) {
        let value = bytes[index]
        if (value <= 32u8 || value >= 127u8 || value == b'\\' || value == b'#') {
            throw IllegalArgumentException("HTTP URL contains an unsafe or non-ASCII byte")
        }
        if (value == b'%') {
            if (index + 2 >= bytes.size || !isHex(bytes[index + 1]) || !isHex(bytes[index + 2])) {
                throw IllegalArgumentException("HTTP URL contains an invalid percent escape")
            }
            index += 2
        }
        index += 1
    }
}

private func validateDnsOrIpv4Host(host: String): Unit {
    if (host.isEmpty() || host.size > 253) {
        throw IllegalArgumentException("HTTP URL host must contain 1 to 253 bytes")
    }
    var numeric = true
    for (value in host.toArray()) {
        if ((value < b'0' || value > b'9') && value != b'.') { numeric = false }
    }
    if (numeric) {
        validateIpv4Literal(host)
        return
    }
    let labels = host.split(".")
    for (label in labels) {
        let bytes = label.toArray()
        if (bytes.isEmpty() || bytes.size > 63 || !isAlphaNumeric(bytes[0]) ||
            !isAlphaNumeric(bytes[bytes.size - 1])) {
            throw IllegalArgumentException("HTTP URL contains an invalid DNS label")
        }
        for (value in bytes) {
            if (!isAlphaNumeric(value) && value != b'-') {
                throw IllegalArgumentException("HTTP URL host must be an ASCII DNS name or IP literal")
            }
        }
    }
}

private func validateIpv6Literal(host: String): Unit {
    let bytes = host.toArray()
    var index = 0
    var groups = 0
    var compressed = false
    if (bytes[0] == b':') {
        if (bytes.size < 2 || bytes[1] != b':') { invalidIpv6() }
        compressed = true
        index = 2
    }
    while (index < bytes.size) {
        let groupStart = index
        var hasDot = false
        while (index < bytes.size && bytes[index] != b':') {
            if (bytes[index] == b'.') { hasDot = true }
            else if (!isHex(bytes[index])) { invalidIpv6() }
            index += 1
        }
        let length = index - groupStart
        if (hasDot) {
            if (index != bytes.size) { invalidIpv6() }
            validateIpv4Literal(bytesToString(bytes, groupStart, index))
            groups += 2
        } else {
            if (length <= 0 || length > 4) { invalidIpv6() }
            groups += 1
        }
        if (index == bytes.size) { break }
        if (index + 1 < bytes.size && bytes[index + 1] == b':') {
            if (compressed) { invalidIpv6() }
            compressed = true
            index += 2
        } else {
            index += 1
            if (index == bytes.size) { invalidIpv6() }
        }
    }
    if ((compressed && groups >= 8) || (!compressed && groups != 8)) {
        invalidIpv6()
    }
}

private func invalidIpv6(): Nothing {
    throw IllegalArgumentException("bracketed HTTP URL host is not an IPv6 literal")
}

private func validateIpv4Literal(host: String): Unit {
    let bytes = host.toArray()
    var groups = 0
    var index = 0
    while (index < bytes.size) {
        let start = index
        var value: Int64 = 0
        while (index < bytes.size && bytes[index] != b'.') {
            let digit = bytes[index]
            if (digit < b'0' || digit > b'9') {
                throw IllegalArgumentException("HTTP URL host is not a valid IPv4 literal")
            }
            value = value * 10 + Int64(digit - b'0')
            index += 1
        }
        let length = index - start
        if (length == 0 || length > 3 || value > 255 ||
            (length > 1 && bytes[start] == b'0')) {
            throw IllegalArgumentException("HTTP URL host is not a valid IPv4 literal")
        }
        groups += 1
        if (index < bytes.size) { index += 1 }
    }
    if (groups != 4) {
        throw IllegalArgumentException("HTTP URL host is not a valid IPv4 literal")
    }
}

private func parsePort(bytes: Array<Byte>, start: Int64, end: Int64): Int64 {
    if (start >= end || end - start > 5) {
        throw IllegalArgumentException("HTTP URL port must contain 1 to 5 digits")
    }
    var port: Int64 = 0
    for (index in start..end) {
        let value = bytes[index]
        if (value < b'0' || value > b'9') {
            throw IllegalArgumentException("HTTP URL port must be decimal")
        }
        port = port * 10 + Int64(value - b'0')
    }
    if (port <= 0 || port > 65535) {
        throw IllegalArgumentException("HTTP URL port must be in 1..65535")
    }
    port
}

private func findAuthorityEnd(bytes: Array<Byte>, start: Int64): Int64 {
    for (index in start..bytes.size) {
        if (bytes[index] == b'/' || bytes[index] == b'?') { return index }
    }
    bytes.size
}

private func findByte(bytes: Array<Byte>, needle: Byte, start: Int64, end: Int64): Int64 {
    for (index in start..end) {
        if (bytes[index] == needle) { return index }
    }
    -1
}

private func findSequence(bytes: Array<Byte>, needle: Array<Byte>, start: Int64): Int64 {
    if (needle.isEmpty() || bytes.size < needle.size) { return -1 }
    for (index in start..(bytes.size - needle.size + 1)) {
        var matches = true
        for (offset in 0..needle.size) {
            if (bytes[index + offset] != needle[offset]) { matches = false; break }
        }
        if (matches) { return index }
    }
    -1
}

private func bytesToString(bytes: Array<Byte>, start: Int64, end: Int64): String {
    let result = ArrayList<Byte>()
    for (index in start..end) { result.add(bytes[index]) }
    String.fromUtf8(result.toArray())
}

private func isAlphaNumeric(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9')
}

private func isHex(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}
