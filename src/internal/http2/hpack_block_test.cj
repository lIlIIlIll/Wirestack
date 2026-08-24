package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HpackBlockTest {
    @TestCase
    func rfcRequestBlocksDecodeWithSharedDynamicState(): Unit {
        let decoder = HpackDecoder()
        let first = decoder.decode(hexBytes("828684410f7777772e6578616d706c652e636f6d"))
        expectRequestPrefix(first)
        expectBlockField(first[3], ":authority", "www.example.com")
        expectBlockField(decoder.dynamicEntry(62u64), ":authority", "www.example.com")

        let second = decoder.decode(hexBytes("828684be58086e6f2d6361636865"))
        expectRequestPrefix(second)
        expectBlockField(second[3], ":authority", "www.example.com")
        expectBlockField(second[4], "cache-control", "no-cache")
        expectBlockField(decoder.dynamicEntry(62u64), "cache-control", "no-cache")
    }

    @TestCase
    func encoderMatchesFirstRfcHuffmanRequestExample(): Unit {
        let encoder = HpackEncoder()
        let block = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":method", "GET")),
            HpackFieldEncoding(HpackHeaderField(":scheme", "http")),
            HpackFieldEncoding(HpackHeaderField(":path", "/")),
            HpackFieldEncoding(HpackHeaderField(":authority", "www.example.com"))
        ])
        @Expect(block, hexBytes("828684418cf1e3c2e5f23a6ba0ab90f4ff"))
    }

    @TestCase
    func literalModesPreserveNeverIndexedAndOnlyIncrementalMutatesTable(): Unit {
        let encoder = HpackEncoder()
        let decoder = HpackDecoder()
        let block = encoder.encode([
            HpackFieldEncoding(HpackHeaderField("x-one", "1"), mode: HpackIndexingMode.WithoutIndexing),
            HpackFieldEncoding(HpackHeaderField("authorization", "secret", sensitive: true)),
            HpackFieldEncoding(HpackHeaderField("x-two", "2"), mode: HpackIndexingMode.Incremental)
        ])
        let decoded = decoder.decode(block)
        @Expect(decoded.size, 3)
        @Expect(!decoded[0].sensitive)
        @Expect(decoded[1].sensitive)
        expectBlockField(decoder.dynamicEntry(62u64), "x-two", "2")
        expectBlockFailure({ => let _ = decoder.dynamicEntry(63u64) })
    }

    @TestCase
    func tableSizeUpdateMustLeadBlockAndRespectAllowedMaximum(): Unit {
        let decoder = HpackDecoder(limits: Http2Limits(maxHeaderTableBytes: 128u32))
        let fields = decoder.decode([0x20, 0x82])
        @Expect(fields.size, 1)
        expectBlockField(fields[0], ":method", "GET")
        expectBlockFailure({ => let _ = decoder.decode([0x82, 0x20]) })
        expectBlockFailure({ => let _ = decoder.decode([0x3f, 0x62]) })
    }

    @TestCase
    func headerCountListAndCompressedLimitsFailClosed(): Unit {
        let countDecoder = HpackDecoder(limits: Http2Limits(maxHeaderFields: 1u32))
        expectBlockFailure({ => let _ = countDecoder.decode([0x82, 0x84]) })

        let listDecoder = HpackDecoder(limits: Http2Limits(maxHeaderListBytes: 33u32))
        expectBlockFailure({ => let _ = listDecoder.decode([0x82]) })

        let compressed = HpackDecoder(limits: Http2Limits(maxHeaderBlockBytes: 16384u32))
        expectBlockFailure({ => let _ = compressed.decode(Array<Byte>(16385, repeat: 0u8)) })
    }

    @TestCase
    func peerCapacityUpdateIsEmittedBeforeHeaders(): Unit {
        let encoder = HpackEncoder(limits: Http2Limits(maxHeaderTableBytes: 128u32))
        encoder.updatePeerTableCapacity(64u64)
        let block = encoder.encode([HpackFieldEncoding(HpackHeaderField(":method", "GET"))])
        @Expect(block, hexBytes("3f2182"))
        let decoder = HpackDecoder(limits: Http2Limits(maxHeaderTableBytes: 128u32))
        let fields = decoder.decode(block)
        expectBlockField(fields[0], ":method", "GET")
    }
}

private func expectRequestPrefix(fields: Array<HpackHeaderField>): Unit {
    @Expect(fields.size >= 4)
    expectBlockField(fields[0], ":method", "GET")
    expectBlockField(fields[1], ":scheme", "http")
    expectBlockField(fields[2], ":path", "/")
}

private func expectBlockField(field: HpackHeaderField, name: String, value: String): Unit {
    @Expect(field.name, name)
    @Expect(field.value, value)
}

private func expectBlockFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: HpackException) { rejected = true }
    @Expect(rejected)
}

private func hexBytes(value: String): Array<Byte> {
    let input = value.toArray()
    let output = Array<Byte>(input.size / 2, repeat: 0u8)
    for (index in 0..output.size) {
        output[index] = (blockNibble(input[index * 2]) << 4) | blockNibble(input[index * 2 + 1])
    }
    output
}

private func blockNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else { throw IllegalArgumentException("invalid hex fixture") }
}
