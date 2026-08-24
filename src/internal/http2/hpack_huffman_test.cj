package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HpackHuffmanTest {
    @TestCase
    func rfcRequestExamplesEncodeAndDecodeExactly(): Unit {
        expectHuffmanVector("www.example.com", "f1e3c2e5f23a6ba0ab90f4ff")
        expectHuffmanVector("no-cache", "a8eb10649cbf")
        expectHuffmanVector("custom-key", "25a849e95ba97d7f")
        expectHuffmanVector("custom-value", "25a849e95bb8e8b4bf")
    }

    @TestCase
    func everyOctetRoundTripsWithinAnExplicitBound(): Unit {
        let input = Array<Byte>(256, repeat: 0u8)
        for (index in 0..256) { input[index] = UInt8(index) }
        let encoded = encodeHpackHuffman(input, maxOutputBytes: 1024u64)
        @Expect(encoded.size <= 1024)
        @Expect(decodeHpackHuffman(encoded, maxOutputBytes: 256u64), input)
    }

    @TestCase
    func huffmanStringLiteralUsesFlagAndSharedBounds(): Unit {
        let encoded = encodeHpackString("www.example.com".toArray(), huffman: true)
        @Expect((encoded[0] & 0x80u8) != 0u8)
        let decoded = decodeHpackString(encoded, 0, 15u64)
        @Expect(String.fromUtf8(decoded.bytes), "www.example.com")
        @Expect(decoded.nextOffset, encoded.size)
    }

    @TestCase
    func eosInvalidPaddingAndTruncatedPrefixFailClosed(): Unit {
        expectHuffmanFailure([0xff, 0xff, 0xff, 0xfc], 64u64)
        expectHuffmanFailure([0xff], 64u64)
        let valid = encodeHpackHuffman("a".toArray())
        valid[valid.size - 1] &= 0xfeu8
        expectHuffmanFailure(valid, 64u64)
    }

    @TestCase
    func decodedAndEncodedOutputLimitsApplyBeforeGrowth(): Unit {
        let encoded = encodeHpackHuffman("www.example.com".toArray())
        expectHuffmanFailure(encoded, 14u64)
        var encodeRejected = false
        try {
            let _ = encodeHpackHuffman("www.example.com".toArray(), maxOutputBytes: 11u64)
        } catch (_: HpackException) { encodeRejected = true }
        @Expect(encodeRejected)
    }
}

private func expectHuffmanVector(text: String, hexadecimal: String): Unit {
    let expected = decodeHex(hexadecimal)
    @Expect(encodeHpackHuffman(text.toArray()), expected)
    @Expect(String.fromUtf8(decodeHpackHuffman(expected)), text)
}

private func expectHuffmanFailure(input: Array<Byte>, maximum: UInt64): Unit {
    var rejected = false
    try { let _ = decodeHpackHuffman(input, maxOutputBytes: maximum) } catch (_: HpackException) {
        rejected = true
    }
    @Expect(rejected)
}

private func decodeHex(value: String): Array<Byte> {
    let input = value.toArray()
    if (input.size % 2 != 0) { throw IllegalArgumentException("hex fixture must have even length") }
    let output = Array<Byte>(input.size / 2, repeat: 0u8)
    for (index in 0..output.size) {
        output[index] = (hexNibble(input[index * 2]) << 4) | hexNibble(input[index * 2 + 1])
    }
    output
}

private func hexNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else { throw IllegalArgumentException("invalid hex fixture") }
}
