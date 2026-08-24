package wirestack.internal.http2

import std.collection.ArrayList

public class HpackException <: Exception {
    public init(message: String) { super(message) }
    protected override func getClassName(): String { "HpackException" }
}

/** One owned HPACK header field. RFC table accounting adds 32 octets. */
public class HpackHeaderField {
    public let name: String
    public let value: String
    public let sensitive: Bool

    public prop tableSize: UInt64 {
        get() { UInt64(name.toArray().size) + UInt64(value.toArray().size) + 32u64 }
    }

    public init(name: String, value: String, sensitive!: Bool = false) {
        this.name = name
        this.value = value
        this.sensitive = sensitive
    }
}

public struct HpackIntegerResult {
    public let value: UInt64
    public let nextOffset: Int64
    public init(value: UInt64, nextOffset: Int64) { this.value = value; this.nextOffset = nextOffset }
}

public class HpackStringResult {
    private let ownedBytes: Array<Byte>
    public let nextOffset: Int64

    public prop bytes: Array<Byte> { get() { ownedBytes.clone() } }

    public init(bytes: Array<Byte>, nextOffset: Int64) {
        ownedBytes = bytes.clone()
        this.nextOffset = nextOffset
    }
}

/** Encodes an HPACK prefixed integer while retaining caller-supplied high bits. */
public func encodeHpackInteger(value: UInt64, prefixBits: UInt8, prefix!: Byte = 0u8): Array<Byte> {
    let prefixMaximum = hpackPrefixMaximum(prefixBits)
    let lowMask = UInt8(prefixMaximum)
    if ((prefix & lowMask) != 0u8) {
        throw IllegalArgumentException("HPACK integer prefix already uses value bits")
    }
    let output = ArrayList<Byte>()
    if (value < prefixMaximum) {
        output.add(prefix | UInt8(value))
        return output.toArray()
    }
    output.add(prefix | lowMask)
    var remaining = value - prefixMaximum
    while (remaining >= 128u64) {
        output.add(UInt8(remaining & 0x7fu64) | 0x80u8)
        remaining = remaining / 128u64
    }
    output.add(UInt8(remaining))
    output.toArray()
}

/** Decodes an HPACK prefixed integer with truncation and UInt64 overflow checks. */
public func decodeHpackInteger(input: Array<Byte>, offset: Int64, prefixBits: UInt8): HpackIntegerResult {
    if (offset < 0 || offset >= input.size) { throw HpackException("HPACK integer is truncated") }
    let prefixMaximum = hpackPrefixMaximum(prefixBits)
    var value = UInt64(input[offset] & UInt8(prefixMaximum))
    if (value < prefixMaximum) { return HpackIntegerResult(value, offset + 1) }

    var cursor = offset + 1
    var multiplier = 1u64
    var continuationCount: Int64 = 0
    while (cursor < input.size && continuationCount < 10) {
        let octet = input[cursor]
        let digit = UInt64(octet & 0x7fu8)
        if (digit > (UInt64.Max - value) / multiplier) {
            throw HpackException("HPACK integer overflows UInt64")
        }
        value += digit * multiplier
        cursor += 1
        continuationCount += 1
        if ((octet & 0x80u8) == 0u8) { return HpackIntegerResult(value, cursor) }
        if (multiplier > UInt64.Max / 128u64) {
            throw HpackException("HPACK integer continuation is too long")
        }
        multiplier *= 128u64
    }
    if (cursor >= input.size) { throw HpackException("HPACK integer continuation is truncated") }
    throw HpackException("HPACK integer continuation is too long")
}

/** Encodes one bounded HPACK string literal, optionally using RFC Huffman. */
public func encodeHpackString(
    value: Array<Byte>,
    huffman!: Bool = false,
    maxEncodedBytes!: UInt64 = 65536u64
): Array<Byte> {
    let encoded = if (huffman) {
        encodeHpackHuffman(value, maxOutputBytes: maxEncodedBytes)
    } else {
        if (UInt64(value.size) > maxEncodedBytes) {
            throw HpackException("HPACK string exceeds the configured encoded limit")
        }
        value.clone()
    }
    let prefix = encodeHpackInteger(UInt64(encoded.size), 7u8, prefix: if (huffman) { 0x80u8 } else { 0u8 })
    let output = ArrayList<Byte>()
    for (octet in prefix) { output.add(octet) }
    for (octet in encoded) { output.add(octet) }
    output.toArray()
}

/** Decodes one HPACK string with separate encoded and decoded hard limits. */
public func decodeHpackString(
    input: Array<Byte>,
    offset: Int64,
    maxBytes: UInt64,
    maxEncodedBytes!: UInt64 = 65536u64
): HpackStringResult {
    if (offset < 0 || offset >= input.size) { throw HpackException("HPACK string is truncated") }
    let huffman = (input[offset] & 0x80u8) != 0u8
    let length = decodeHpackInteger(input, offset, 7u8)
    if (length.value > maxEncodedBytes || length.value > UInt64(Int64.Max)) {
        throw HpackException("HPACK string exceeds the configured encoded limit")
    }
    let count = Int64(length.value)
    if (length.nextOffset > input.size || count > input.size - length.nextOffset) {
        throw HpackException("HPACK string payload is truncated")
    }
    let encoded = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { encoded[index] = input[length.nextOffset + index] }
    let output = if (huffman) {
        decodeHpackHuffman(encoded, maxOutputBytes: maxBytes)
    } else {
        if (length.value > maxBytes) { throw HpackException("HPACK string exceeds the configured decoded limit") }
        encoded
    }
    HpackStringResult(output, length.nextOffset + count)
}

public func hpackStaticTableSize(): UInt64 { 61u64 }

/** Returns RFC 7541 Appendix A's one-based static-table entry. */
public func hpackStaticTableEntry(index: UInt64): HpackHeaderField {
    match (index) {
        case 1u64 => HpackHeaderField(":authority", "")
        case 2u64 => HpackHeaderField(":method", "GET")
        case 3u64 => HpackHeaderField(":method", "POST")
        case 4u64 => HpackHeaderField(":path", "/")
        case 5u64 => HpackHeaderField(":path", "/index.html")
        case 6u64 => HpackHeaderField(":scheme", "http")
        case 7u64 => HpackHeaderField(":scheme", "https")
        case 8u64 => HpackHeaderField(":status", "200")
        case 9u64 => HpackHeaderField(":status", "204")
        case 10u64 => HpackHeaderField(":status", "206")
        case 11u64 => HpackHeaderField(":status", "304")
        case 12u64 => HpackHeaderField(":status", "400")
        case 13u64 => HpackHeaderField(":status", "404")
        case 14u64 => HpackHeaderField(":status", "500")
        case 15u64 => HpackHeaderField("accept-charset", "")
        case 16u64 => HpackHeaderField("accept-encoding", "gzip, deflate")
        case 17u64 => HpackHeaderField("accept-language", "")
        case 18u64 => HpackHeaderField("accept-ranges", "")
        case 19u64 => HpackHeaderField("accept", "")
        case 20u64 => HpackHeaderField("access-control-allow-origin", "")
        case 21u64 => HpackHeaderField("age", "")
        case 22u64 => HpackHeaderField("allow", "")
        case 23u64 => HpackHeaderField("authorization", "")
        case 24u64 => HpackHeaderField("cache-control", "")
        case 25u64 => HpackHeaderField("content-disposition", "")
        case 26u64 => HpackHeaderField("content-encoding", "")
        case 27u64 => HpackHeaderField("content-language", "")
        case 28u64 => HpackHeaderField("content-length", "")
        case 29u64 => HpackHeaderField("content-location", "")
        case 30u64 => HpackHeaderField("content-range", "")
        case 31u64 => HpackHeaderField("content-type", "")
        case 32u64 => HpackHeaderField("cookie", "")
        case 33u64 => HpackHeaderField("date", "")
        case 34u64 => HpackHeaderField("etag", "")
        case 35u64 => HpackHeaderField("expect", "")
        case 36u64 => HpackHeaderField("expires", "")
        case 37u64 => HpackHeaderField("from", "")
        case 38u64 => HpackHeaderField("host", "")
        case 39u64 => HpackHeaderField("if-match", "")
        case 40u64 => HpackHeaderField("if-modified-since", "")
        case 41u64 => HpackHeaderField("if-none-match", "")
        case 42u64 => HpackHeaderField("if-range", "")
        case 43u64 => HpackHeaderField("if-unmodified-since", "")
        case 44u64 => HpackHeaderField("last-modified", "")
        case 45u64 => HpackHeaderField("link", "")
        case 46u64 => HpackHeaderField("location", "")
        case 47u64 => HpackHeaderField("max-forwards", "")
        case 48u64 => HpackHeaderField("proxy-authenticate", "")
        case 49u64 => HpackHeaderField("proxy-authorization", "")
        case 50u64 => HpackHeaderField("range", "")
        case 51u64 => HpackHeaderField("referer", "")
        case 52u64 => HpackHeaderField("refresh", "")
        case 53u64 => HpackHeaderField("retry-after", "")
        case 54u64 => HpackHeaderField("server", "")
        case 55u64 => HpackHeaderField("set-cookie", "")
        case 56u64 => HpackHeaderField("strict-transport-security", "")
        case 57u64 => HpackHeaderField("transfer-encoding", "")
        case 58u64 => HpackHeaderField("user-agent", "")
        case 59u64 => HpackHeaderField("vary", "")
        case 60u64 => HpackHeaderField("via", "")
        case 61u64 => HpackHeaderField("www-authenticate", "")
        case _ => throw HpackException("HPACK static-table index is outside [1, 61]")
    }
}

private func hpackPrefixMaximum(prefixBits: UInt8): UInt64 {
    if (prefixBits == 0u8 || prefixBits > 8u8) {
        throw IllegalArgumentException("HPACK integer prefix width must be in [1, 8]")
    }
    if (prefixBits == 8u8) { 255u64 } else { (1u64 << UInt64(prefixBits)) - 1u64 }
}
