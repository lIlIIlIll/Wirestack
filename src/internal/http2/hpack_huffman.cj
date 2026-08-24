package wirestack.internal.http2

import std.collection.ArrayList

// RFC 7541 Appendix B. Entry 256 is EOS and is never valid as decoded data.
private let HPACK_HUFFMAN_CODES: Array<UInt32> = [
    0x1ff8u32,0x7fffd8u32,0xfffffe2u32,0xfffffe3u32,0xfffffe4u32,0xfffffe5u32,0xfffffe6u32,0xfffffe7u32,
    0xfffffe8u32,0xffffeau32,0x3ffffffcu32,0xfffffe9u32,0xfffffeau32,0x3ffffffdu32,0xfffffebu32,0xfffffecu32,
    0xfffffedu32,0xfffffeeu32,0xfffffefu32,0xffffff0u32,0xffffff1u32,0xffffff2u32,0x3ffffffeu32,0xffffff3u32,
    0xffffff4u32,0xffffff5u32,0xffffff6u32,0xffffff7u32,0xffffff8u32,0xffffff9u32,0xffffffau32,0xffffffbu32,
    0x14u32,0x3f8u32,0x3f9u32,0xffau32,0x1ff9u32,0x15u32,0xf8u32,0x7fau32,0x3fau32,0x3fbu32,0xf9u32,
    0x7fbu32,0xfau32,0x16u32,0x17u32,0x18u32,0x0u32,0x1u32,0x2u32,0x19u32,0x1au32,0x1bu32,0x1cu32,
    0x1du32,0x1eu32,0x1fu32,0x5cu32,0xfbu32,0x7ffcu32,0x20u32,0xffbu32,0x3fcu32,0x1ffau32,0x21u32,
    0x5du32,0x5eu32,0x5fu32,0x60u32,0x61u32,0x62u32,0x63u32,0x64u32,0x65u32,0x66u32,0x67u32,0x68u32,
    0x69u32,0x6au32,0x6bu32,0x6cu32,0x6du32,0x6eu32,0x6fu32,0x70u32,0x71u32,0x72u32,0xfcu32,0x73u32,
    0xfdu32,0x1ffbu32,0x7fff0u32,0x1ffcu32,0x3ffcu32,0x22u32,0x7ffdu32,0x3u32,0x23u32,0x4u32,0x24u32,
    0x5u32,0x25u32,0x26u32,0x27u32,0x6u32,0x74u32,0x75u32,0x28u32,0x29u32,0x2au32,0x7u32,0x2bu32,
    0x76u32,0x2cu32,0x8u32,0x9u32,0x2du32,0x77u32,0x78u32,0x79u32,0x7au32,0x7bu32,0x7ffeu32,
    0x7fcu32,0x3ffdu32,0x1ffdu32,0xffffffcu32,0xfffe6u32,0x3fffd2u32,0xfffe7u32,0xfffe8u32,0x3fffd3u32,
    0x3fffd4u32,0x3fffd5u32,0x7fffd9u32,0x3fffd6u32,0x7fffdau32,0x7fffdbu32,0x7fffdcu32,0x7fffddu32,
    0x7fffdeu32,0xffffebu32,0x7fffdfu32,0xffffecu32,0xffffedu32,0x3fffd7u32,0x7fffe0u32,0xffffeeu32,
    0x7fffe1u32,0x7fffe2u32,0x7fffe3u32,0x7fffe4u32,0x1fffdcu32,0x3fffd8u32,0x7fffe5u32,0x3fffd9u32,
    0x7fffe6u32,0x7fffe7u32,0xffffefu32,0x3fffdau32,0x1fffddu32,0xfffe9u32,0x3fffdbu32,0x3fffdcu32,
    0x7fffe8u32,0x7fffe9u32,0x1fffdeu32,0x7fffeau32,0x3fffddu32,0x3fffdeu32,0xfffff0u32,0x1fffdfu32,
    0x3fffdfu32,0x7fffebu32,0x7fffecu32,0x1fffe0u32,0x1fffe1u32,0x3fffe0u32,0x1fffe2u32,0x7fffedu32,
    0x3fffe1u32,0x7fffeeu32,0x7fffefu32,0xfffeau32,0x3fffe2u32,0x3fffe3u32,0x3fffe4u32,0x7ffff0u32,
    0x3fffe5u32,0x3fffe6u32,0x7ffff1u32,0x3ffffe0u32,0x3ffffe1u32,0xfffebu32,0x7fff1u32,0x3fffe7u32,
    0x7ffff2u32,0x3fffe8u32,0x1ffffecu32,0x3ffffe2u32,0x3ffffe3u32,0x3ffffe4u32,0x7ffffdeu32,
    0x7ffffdfu32,0x3ffffe5u32,0xfffff1u32,0x1ffffedu32,0x7fff2u32,0x1fffe3u32,0x3ffffe6u32,
    0x7ffffe0u32,0x7ffffe1u32,0x3ffffe7u32,0x7ffffe2u32,0xfffff2u32,0x1fffe4u32,0x1fffe5u32,
    0x3ffffe8u32,0x3ffffe9u32,0xffffffdu32,0x7ffffe3u32,0x7ffffe4u32,0x7ffffe5u32,0xfffecu32,
    0xfffff3u32,0xfffedu32,0x1fffe6u32,0x3fffe9u32,0x1fffe7u32,0x1fffe8u32,0x7ffff3u32,0x3fffeau32,
    0x3fffebu32,0x1ffffeeu32,0x1ffffefu32,0xfffff4u32,0xfffff5u32,0x3ffffeau32,0x7ffff4u32,
    0x3ffffebu32,0x7ffffe6u32,0x3ffffecu32,0x3ffffedu32,0x7ffffe7u32,0x7ffffe8u32,0x7ffffe9u32,
    0x7ffffeau32,0x7ffffebu32,0xffffffeu32,0x7ffffecu32,0x7ffffedu32,0x7ffffeeu32,0x7ffffefu32,
    0x7fffff0u32,0x3ffffeeu32,0x3fffffffu32
]

private let HPACK_HUFFMAN_LENGTHS: Array<UInt8> = [
    13u8,23u8,28u8,28u8,28u8,28u8,28u8,28u8,28u8,24u8,30u8,28u8,28u8,30u8,28u8,28u8,28u8,28u8,
    28u8,28u8,28u8,28u8,30u8,28u8,28u8,28u8,28u8,28u8,28u8,28u8,28u8,28u8,6u8,10u8,10u8,12u8,
    13u8,6u8,8u8,11u8,10u8,10u8,8u8,11u8,8u8,6u8,6u8,6u8,5u8,5u8,5u8,6u8,6u8,6u8,6u8,6u8,
    6u8,6u8,7u8,8u8,15u8,6u8,12u8,10u8,13u8,6u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,
    7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,7u8,8u8,7u8,8u8,13u8,19u8,13u8,14u8,6u8,
    15u8,5u8,6u8,5u8,6u8,5u8,6u8,6u8,6u8,5u8,7u8,7u8,6u8,6u8,6u8,5u8,6u8,7u8,6u8,5u8,
    5u8,6u8,7u8,7u8,7u8,7u8,7u8,15u8,11u8,14u8,13u8,28u8,20u8,22u8,20u8,20u8,22u8,22u8,
    22u8,23u8,22u8,23u8,23u8,23u8,23u8,23u8,24u8,23u8,24u8,24u8,22u8,23u8,24u8,23u8,23u8,
    23u8,23u8,21u8,22u8,23u8,22u8,23u8,23u8,24u8,22u8,21u8,20u8,22u8,22u8,23u8,23u8,21u8,
    23u8,22u8,22u8,24u8,21u8,22u8,23u8,23u8,21u8,21u8,22u8,21u8,23u8,22u8,23u8,23u8,20u8,
    22u8,22u8,22u8,23u8,22u8,22u8,23u8,26u8,26u8,20u8,19u8,22u8,23u8,22u8,25u8,26u8,26u8,
    26u8,27u8,27u8,26u8,24u8,25u8,19u8,21u8,26u8,27u8,27u8,26u8,27u8,24u8,21u8,21u8,26u8,
    26u8,28u8,27u8,27u8,27u8,20u8,24u8,20u8,21u8,22u8,21u8,21u8,23u8,22u8,22u8,25u8,25u8,
    24u8,24u8,26u8,23u8,26u8,27u8,26u8,26u8,27u8,27u8,27u8,27u8,27u8,28u8,27u8,27u8,27u8,
    27u8,27u8,26u8,30u8
]

/** Encodes with a hard output ceiling and RFC EOS-prefix padding. */
public func encodeHpackHuffman(input: Array<Byte>, maxOutputBytes!: UInt64 = 65536u64): Array<Byte> {
    let output = ArrayList<Byte>()
    var accumulator = 0u64
    var bitCount: UInt64 = 0u64
    for (octet in input) {
        let index = Int64(octet)
        let length = UInt64(HPACK_HUFFMAN_LENGTHS[index])
        accumulator = (accumulator << length) | UInt64(HPACK_HUFFMAN_CODES[index])
        bitCount += length
        while (bitCount >= 8u64) {
            bitCount -= 8u64
            appendHuffmanByte(output, UInt8((accumulator >> bitCount) & 0xffu64), maxOutputBytes)
            accumulator &= if (bitCount == 0u64) { 0u64 } else { (1u64 << bitCount) - 1u64 }
        }
    }
    if (bitCount > 0u64) {
        let padding = 8u64 - bitCount
        appendHuffmanByte(
            output,
            UInt8(((accumulator << padding) | ((1u64 << padding) - 1u64)) & 0xffu64),
            maxOutputBytes
        )
    }
    output.toArray()
}

/** Decodes bit-by-bit with strict EOS, prefix, padding and output limits. */
public func decodeHpackHuffman(input: Array<Byte>, maxOutputBytes!: UInt64 = 65536u64): Array<Byte> {
    let output = ArrayList<Byte>()
    var code = 0u64
    var codeLength: UInt64 = 0u64
    for (octet in input) {
        for (bitIndex in 0u64..8u64) {
            code = (code << 1u64) | ((UInt64(octet) >> (7u64 - bitIndex)) & 1u64)
            codeLength += 1u64
            let symbol = huffmanExactSymbol(code, codeLength)
            if (symbol >= 0) {
                if (symbol == 256) { throw HpackException("HPACK Huffman EOS symbol is forbidden in data") }
                appendHuffmanByte(output, UInt8(symbol), maxOutputBytes)
                code = 0u64
                codeLength = 0u64
            } else if (!huffmanPrefixExists(code, codeLength)) {
                throw HpackException("HPACK Huffman stream contains an invalid code prefix")
            }
        }
    }
    if (codeLength > 7u64) { throw HpackException("HPACK Huffman padding exceeds seven bits") }
    if (codeLength > 0u64 && code != (1u64 << codeLength) - 1u64) {
        throw HpackException("HPACK Huffman padding is not an EOS prefix")
    }
    output.toArray()
}

private func huffmanExactSymbol(code: UInt64, length: UInt64): Int64 {
    for (index in 0..HPACK_HUFFMAN_CODES.size) {
        if (UInt64(HPACK_HUFFMAN_LENGTHS[index]) == length && UInt64(HPACK_HUFFMAN_CODES[index]) == code) {
            return index
        }
    }
    -1
}

private func huffmanPrefixExists(code: UInt64, length: UInt64): Bool {
    if (length > 30u64) { return false }
    for (index in 0..HPACK_HUFFMAN_CODES.size) {
        let symbolLength = UInt64(HPACK_HUFFMAN_LENGTHS[index])
        if (symbolLength >= length &&
            (UInt64(HPACK_HUFFMAN_CODES[index]) >> (symbolLength - length)) == code) {
            return true
        }
    }
    false
}

private func appendHuffmanByte(output: ArrayList<Byte>, value: Byte, maximum: UInt64): Unit {
    if (UInt64(output.size) >= maximum) { throw HpackException("HPACK Huffman output exceeds the configured limit") }
    output.add(value)
}
