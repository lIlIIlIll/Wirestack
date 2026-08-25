package yjson_schema_formats

import std.collection.*
import yjson.*

// The native seam is deliberately a Boolean validator; no libidn2-owned
// allocation crosses into managed Cangjie code.
@FastNative
foreign func YJ_Schema_IdnaValidate(input: CPointer<UInt8>, length: Int64, asciiOnly: Int32): Int32

/// Installs the internationalized hostname, email, URI, IRI, and URI Template formats.
/// The hostname validators use the system libidn2 implementation of IDNA2008,
/// including Punycode round-trip, Bidi, and ContextJ checks.
public class StandardInternationalFormats <: JsonSchemaFormatProvider {
    public func installInto(registry: JsonSchemaFormatRegistry): Unit {
        registry.register("hostname", InternationalSchemaFormat("hostname"))
        registry.register("idn-hostname", InternationalSchemaFormat("idn-hostname"))
        registry.register("idn-email", InternationalSchemaFormat("idn-email"))
        registry.register("uri", InternationalSchemaFormat("uri"))
        registry.register("uri-reference", InternationalSchemaFormat("uri-reference"))
        registry.register("iri", InternationalSchemaFormat("iri"))
        registry.register("iri-reference", InternationalSchemaFormat("iri-reference"))
        registry.register("uri-template", InternationalSchemaFormat("uri-template"))
    }
}

private class InternationalSchemaFormat <: JsonSchemaFormat {
    private let name: String
    init(name: String) { this.name = name }

    public func validate(value: String): Bool {
        match (name) {
            case "hostname" => schemaIdnaHostname(value, true)
            case "idn-hostname" => schemaIdnaHostname(value, false)
            case "idn-email" => schemaIdnEmail(value)
            case "uri" => schemaUriReference(value, true, false)
            case "uri-reference" => schemaUriReference(value, false, false)
            case "iri" => schemaUriReference(value, true, true)
            case "iri-reference" => schemaUriReference(value, false, true)
            case "uri-template" => schemaUriTemplate(value)
            case _ => false
        }
    }
}

private func schemaIdnaHostname(value: String, asciiOnly: Bool): Bool {
    if (value.isEmpty() || value.startsWith(".") || value.endsWith(".")) { return false }
    let bytes = unsafe { value.rawData() }
    unsafe {
        let handle = acquireArrayRawData(bytes)
        try { YJ_Schema_IdnaValidate(handle.pointer, bytes.size, if (asciiOnly) { 1 } else { 0 }) == 1 }
        finally { releaseArrayRawData(handle) }
    }
}

private func schemaIdnEmail(value: String): Bool {
    if (value.isEmpty() || value.contains("\r") || value.contains("\n") || value.contains("\t") ||
        value.startsWith(" ") || value.endsWith(" ")) { return false }
    var at: Int64 = -1
    var quoted = false
    var escaped = false
    for (index in 0..value.size) {
        let byte = value[index]
        if (quoted) {
            if (!escaped && byte == b'\"') { quoted = false }
            if (!escaped && byte == b'\\') { escaped = true } else { escaped = false }
        } else if (byte == b'\"') { quoted = true
        } else if (byte == b'@') { if (at >= 0) { return false }; at = index }
    }
    if (quoted || at <= 0 || at >= value.size - 1) { return false }
    let local = value[0..at]
    let domain = value[at + 1..value.size]
    if (local.startsWith("\"") != local.endsWith("\"")) { return false }
    if (!local.startsWith("\"") && (local.startsWith(".") || local.endsWith(".") || local.contains("..") ||
        local.contains(" ") || local.contains("\\") || local.contains("\"") || local.contains(",") ||
        local.contains(";") || local.contains(":") || local.contains("(") || local.contains(")") ||
        local.contains("["))) { return false }
    if (domain.startsWith("[") && domain.endsWith("]")) {
        let address = domain[1..domain.size - 1]
        if (address.startsWith("IPv6:") || address.startsWith("ipv6:")) {
            return schemaIpv6(address[5..address.size])
        }
        return schemaIpv4(address)
    }
    schemaIdnaHostname(domain, false)
}

private func schemaUriReference(value: String, absolute: Bool, international: Bool): Bool {
    for (byte in unsafe { value.rawData() }) {
        if (byte <= 0x20u8 || byte == 0x7Fu8 || (!international && byte >= 0x80u8)) { return false }
    }
    var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == b'%') {
            if (index + 2 >= value.size || !schemaHex(value[index + 1]) || !schemaHex(value[index + 2])) {
                return false
            }
            index += 3
        } else { index++ }
    }
    for (forbidden in ["\"", "<", ">", "{", "}", "^", "`", "|", "\\"]) {
        if (value.contains(forbidden)) { return false }
    }
    let hasScheme = schemaUriHasScheme(value)
    if (absolute && !hasScheme) { return false }
    if (!hasScheme && !value.startsWith("/") && !value.startsWith("?") && !value.startsWith("#")) {
        let firstEnd = match (value.indexOf("/")) { case Some(found) => found; case None => value.size }
        if (value[0..firstEnd].contains(":")) { return false }
    }
    let authorityOffset = if (hasScheme) {
        let colon = value.indexOf(":").getOrThrow()
        if (colon + 2 < value.size && value[colon + 1..colon + 3] == "//") { colon + 3 } else { -1 }
    } else if (value.startsWith("//")) { 2 } else { -1 }
    if (authorityOffset >= 0) {
        let tail = value[authorityOffset..value.size]
        var end = tail.size
        for (separator in ["/", "?", "#"]) {
            match (tail.indexOf(separator)) { case Some(found) => if (found < end) { end = found }; case None => () }
        }
        if (!schemaAuthority(tail[0..end], international)) { return false }
    } else if (value.contains("[") || value.contains("]")) { return false }
    true
}

private func schemaAuthority(authority: String, international: Bool): Bool {
    var ats: Int64 = 0
    for (byte in unsafe { authority.rawData() }) { if (byte == b'@') { ats++ } }
    if (ats > 1) { return false }
    let hostPort = match (authority.lastIndexOf("@")) {
        case Some(found) =>
            let userInfo = authority[0..found]
            if (userInfo.contains("[") || userInfo.contains("]")) { return false }
            authority[found + 1..authority.size]
        case None => authority
    }
    if (hostPort.startsWith("[")) {
        let close = hostPort.indexOf("]")
        if (close.isNone()) { return false }
        let address = hostPort[1..close.getOrThrow()]
        if (!schemaIpv6(address) && !schemaIpvFuture(address)) { return false }
        let after = hostPort[close.getOrThrow() + 1..hostPort.size]
        return after.isEmpty() || (after.startsWith(":") && schemaAsciiDigits(after[1..after.size]))
    }
    if (hostPort.contains("[") || hostPort.contains("]")) { return false }
    var host = hostPort
    match (hostPort.lastIndexOf(":")) {
        case Some(colon) =>
            if (!schemaAsciiDigits(hostPort[colon + 1..hostPort.size])) { return false }
            host = hostPort[0..colon]
        case None => ()
    }
    if (host.contains(":")) { return false }
    if (host.isEmpty()) { return true }
    let parts = splitAscii(host, b'.')
    var numeric = parts.size == 4
    if (numeric) { for (part in parts) { if (!schemaAsciiDigits(part)) { numeric = false } } }
    if (numeric && schemaIpv4(host)) { return true }
    if (international) { return schemaIdnaHostname(host, false) }
    for (byte in unsafe { host.rawData() }) {
        if (!((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'.' || byte == b'_' || byte == b'~' ||
            byte == b'%' || byte == b'!')) { return false }
    }
    true
}

private func schemaUriTemplate(value: String): Bool {
    let plain = StringBuilder()
    var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == b'}') { return false }
        if (value[index] != b'{') { plain.append(Rune(value[index])); index++; continue }
        let closeRelative = value[index + 1..value.size].indexOf("}")
        if (closeRelative.isNone()) { return false }
        let close = index + 1 + closeRelative.getOrThrow()
        if (!schemaUriTemplateExpression(value[index + 1..close])) { return false }
        plain.append("x")
        index = close + 1
    }
    schemaUriReference(plain.toString(), false, true)
}

private func schemaUriTemplateExpression(expression: String): Bool {
    if (expression.isEmpty() || expression.contains("{") || expression.contains(" ") || expression.contains("\\")) {
        return false
    }
    let start: Int64 = if ("+#./;?&".contains(expression[0..1])) { 1 } else { 0 }
    if (start == expression.size) { return false }
    for (spec in splitAscii(expression[start..expression.size], b',')) {
        if (spec.isEmpty()) { return false }
        var name = spec
        if (spec.endsWith("*")) { name = spec[0..spec.size - 1] }
        else { match (spec.lastIndexOf(":")) {
            case Some(colon) =>
                let prefix = spec[colon + 1..spec.size]
                if (prefix.isEmpty() || prefix.size > 4 || !schemaAsciiDigits(prefix) || prefix.startsWith("0")) {
                    return false
                }
                name = spec[0..colon]
            case None => ()
        } }
        if (!schemaTemplateVariableName(name)) { return false }
    }
    true
}

private func schemaTemplateVariableName(name: String): Bool {
    if (name.isEmpty() || name.startsWith(".") || name.endsWith(".") || name.contains("..")) { return false }
    var index: Int64 = 0
    while (index < name.size) {
        let byte = name[index]
        if ((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'.') { index++
        } else if (byte == b'%' && index + 2 < name.size && schemaHex(name[index + 1]) && schemaHex(name[index + 2])) {
            index += 3
        } else { return false }
    }
    true
}

private func schemaIpv4(value: String): Bool {
    let parts = splitAscii(value, b'.')
    if (parts.size != 4) { return false }
    for (part in parts) {
        if (part.isEmpty() || (part.size > 1 && part.startsWith("0")) || part.size > 3) { return false }
        var number: Int64 = 0
        for (byte in unsafe { part.rawData() }) {
            if (byte < b'0' || byte > b'9') { return false }
            number = number * 10 + Int64(byte - b'0')
        }
        if (number > 255) { return false }
    }
    true
}

private func schemaIpv6(value: String): Bool {
    if (value.isEmpty() || value.contains(":::")) { return false }
    let compression = value.indexOf("::")
    if (compression.isSome() && value[compression.getOrThrow() + 2..value.size].contains("::")) { return false }
    let left = if (compression.isSome()) { value[0..compression.getOrThrow()] } else { value }
    let right = if (compression.isSome()) { value[compression.getOrThrow() + 2..value.size] } else { "" }
    let leftCount = schemaIpv6Units(left, right.isEmpty())
    if (leftCount < 0) { return false }
    let rightCount = if (compression.isSome()) { schemaIpv6Units(right, true) } else { 0 }
    if (rightCount < 0) { return false }
    if (compression.isSome()) { leftCount + rightCount < 8 } else { leftCount == 8 }
}

private func schemaIpv6Units(value: String, allowIpv4: Bool): Int64 {
    if (value.isEmpty()) { return 0 }
    let parts = splitAscii(value, b':')
    var units: Int64 = 0
    for (index in 0..parts.size) {
        let part = parts[index]
        if (part.isEmpty()) { return -1 }
        if (part.contains(".")) {
            if (!allowIpv4 || index != parts.size - 1 || !schemaIpv4(part)) { return -1 }
            units += 2
        } else {
            if (part.size > 4) { return -1 }
            for (byte in unsafe { part.rawData() }) { if (!schemaHex(byte)) { return -1 } }
            units++
        }
    }
    units
}

private func schemaIpvFuture(value: String): Bool {
    if (value.size < 4 || (value[0] != b'v' && value[0] != b'V')) { return false }
    let dot = value.indexOf(".")
    if (dot.isNone() || dot.getOrThrow() == 1 || dot.getOrThrow() == value.size - 1) { return false }
    for (index in 1..dot.getOrThrow()) { if (!schemaHex(value[index])) { return false } }
    true
}

private func schemaUriHasScheme(value: String): Bool {
    match (value.indexOf(":")) {
        case Some(index) =>
            if (index == 0 || !schemaAsciiAlpha(value[0])) { return false }
            for (position in 1..index) {
                let byte = value[position]
                if (!(schemaAsciiAlpha(byte) || (byte >= b'0' && byte <= b'9') || byte == b'+' || byte == b'-' || byte == b'.')) {
                    return false
                }
            }
            true
        case None => false
    }
}

private func schemaAsciiAlpha(byte: Byte): Bool {
    (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z')
}

private func schemaAsciiDigits(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in unsafe { value.rawData() }) { if (byte < b'0' || byte > b'9') { return false } }
    true
}

private func schemaHex(byte: Byte): Bool {
    (byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f') || (byte >= b'A' && byte <= b'F')
}

private func splitAscii(value: String, separator: Byte): ArrayList<String> {
    let result = ArrayList<String>()
    var start: Int64 = 0
    var index: Int64 = 0
    while (index < value.size) {
        if (value[index] == separator) { result.add(value[start..index]); start = index + 1 }
        index++
    }
    result.add(value[start..value.size])
    result
}
