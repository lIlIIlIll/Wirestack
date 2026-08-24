package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HpackCoreTest {
    @TestCase
    func rfcIntegerVectorsEncodeAndDecodeExactly(): Unit {
        expectIntegerVector(10u64, 5u8, [10])
        expectIntegerVector(1337u64, 5u8, [31, 154, 10])
        expectIntegerVector(42u64, 8u8, [42])

        let withRepresentation = encodeHpackInteger(10u64, 5u8, prefix: 0x40u8)
        let expected: Array<Byte> = [0x4a]
        @Expect(withRepresentation, expected)
    }

    @TestCase
    func integerRejectsTruncationOverflowAndInvalidPrefix(): Unit {
        expectHpackFailure({ => let _ = decodeHpackInteger([31], 0, 5u8) })
        let overflow: Array<Byte> = [31, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1]
        expectHpackFailure({ => let _ = decodeHpackInteger(overflow, 0, 5u8) })
        var invalidPrefix = false
        try { let _ = encodeHpackInteger(1u64, 0u8) } catch (_: IllegalArgumentException) {
            invalidPrefix = true
        }
        @Expect(invalidPrefix)
    }

    @TestCase
    func rawStringRoundTripsAndOwnsItsBytes(): Unit {
        let source = "www.example.com".toArray()
        let encoded = encodeHpackString(source)
        @Expect(encoded[0], 15u8)
        source[0] = b'X'
        let decoded = decodeHpackString(encoded, 0, 15u64)
        @Expect(String.fromUtf8(decoded.bytes), "www.example.com")
        @Expect(decoded.nextOffset, encoded.size)
        let exposed = decoded.bytes
        exposed[0] = b'Y'
        @Expect(String.fromUtf8(decoded.bytes), "www.example.com")
    }

    @TestCase
    func stringLengthLimitAndTruncationFailBeforeCopy(): Unit {
        expectHpackFailure({ => let _ = decodeHpackString([3, 1, 2], 0, 3u64) })
        expectHpackFailure({ => let _ = decodeHpackString([3, 1, 2, 3], 0, 2u64) })
        expectHpackFailure({ => let _ = decodeHpackString([0x80], 0, 1u64) })
    }

    @TestCase
    func staticTableMatchesRfcBoundariesAndRepresentativeEntries(): Unit {
        @Expect(hpackStaticTableSize(), 61u64)
        expectField(hpackStaticTableEntry(1u64), ":authority", "")
        expectField(hpackStaticTableEntry(2u64), ":method", "GET")
        expectField(hpackStaticTableEntry(16u64), "accept-encoding", "gzip, deflate")
        expectField(hpackStaticTableEntry(61u64), "www-authenticate", "")
        expectHpackFailure({ => let _ = hpackStaticTableEntry(0u64) })
        expectHpackFailure({ => let _ = hpackStaticTableEntry(62u64) })
    }

    @TestCase
    func everyStaticEntryHasBoundedRfcAccounting(): Unit {
        for (index in 1u64..62u64) {
            let entry = hpackStaticTableEntry(index)
            @Expect(!entry.name.isEmpty())
            @Expect(entry.tableSize >= 32u64)
            @Expect(entry.tableSize < 128u64)
        }
    }
}

private func expectIntegerVector(value: UInt64, prefixBits: UInt8, expected: Array<Byte>): Unit {
    let encoded = encodeHpackInteger(value, prefixBits)
    @Expect(encoded, expected)
    let decoded = decodeHpackInteger(encoded, 0, prefixBits)
    @Expect(decoded.value, value)
    @Expect(decoded.nextOffset, encoded.size)
}

private func expectHpackFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: HpackException) { rejected = true }
    @Expect(rejected)
}

private func expectField(field: HpackHeaderField, name: String, value: String): Unit {
    @Expect(field.name, name)
    @Expect(field.value, value)
}
