package wirestack.sse

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SseDeterministicFuzzTests {
    @TestCase
    func normativeCorpusAtEveryCutBytewiseAndRandomMulticuts(): Unit {
        let corpus = [
            "\u{feff}data: €😀\r\nid: a\r\nretry: 15\r\nevent: named\r\n\r\ndata:\r\rdata: tail\n\n".toArray(),
            "id: a\n\nevent: discard\n\n:heartbeat\runknown\r\ndata:  spaced\ndata\nid: bad\u{0000}id\n\nid\n\nretry: 999999999999999999999999999999\n".toArray(),
            "data: first\n\ndata: second\n\ndata: incomplete\nid: uncommitted\n".toArray(),
            "\u{feff}\u{feff}data: ignored\n\ndata: retained\n\n".toArray(),
            [239u8, 187u8, 100u8, 97u8, 116u8, 97u8, 58u8, 120u8, 10u8, 10u8],
            [100u8, 97u8, 116u8, 97u8, 58u8, 194u8, 65u8, 224u8, 128u8, 128u8,
                237u8, 160u8, 128u8, 240u8, 144u8, 128u8, 255u8, 13u8, 10u8, 13u8, 10u8],
            [100u8, 97u8, 116u8, 97u8, 58u8, 226u8, 130u8],
            Array<Byte>()
        ]
        var executions: Int64 = 0
        for (bytes in corpus) {
            let expected = sseFuzzTrace(bytes, [bytes.size])
            for (cut in 0..=bytes.size) {
                @Assert(sseFuzzTrace(bytes, [cut, bytes.size]), expected)
                executions++
            }
            @Assert(sseFuzzTrace(bytes, Array<Int64>(bytes.size, { index => index + 1 })), expected)
            executions++
            let random = SseFuzzPrng(11001u64)
            for (_ in 0..32) {
                let cuts = Array<Int64>(bytes.size, repeat: bytes.size)
                var end: Int64 = 0
                for (index in 0..cuts.size) {
                    end = min(bytes.size, end + Int64(random.next() % 11u64) + 1)
                    cuts[index] = end
                }
                @Assert(sseFuzzTrace(bytes, cuts), expected)
                executions++
            }
        }
        @Expect(executions > 500)
        println("M11001_FUZZ target=sse-cuts seed=11001 iterations=${executions} decision=PASS")
    }
    @TestCase
    func deterministicMalformedMutationsStayBoundedAndChunkIndependent(): Unit {
        let seeds = ["data: €😀\r\nid: cursor\r\nevent: e\r\nretry: 123\r\n\r\n".toArray(),
            ": ignored\nunknown: value\n\nid\n\ndata:\n\n".toArray()]
        let random = SseFuzzPrng(178u64)
        var executions: Int64 = 0
        for (seed in seeds) {
            for (_ in 0..256) {
                let mutated = seed.clone()
                let count = Int64(random.next() % 5u64) + 1
                for (_ in 0..count) {
                    mutated[Int64(random.next() % UInt64(mutated.size))] = UInt8(random.next() % 256u64)
                }
                let expected = sseFuzzTrace(mutated, [mutated.size])
                @Assert(sseFuzzTrace(mutated, Array<Int64>(mutated.size, { index => index + 1 })), expected)
                let cut = Int64(random.next() % UInt64(mutated.size + 1))
                @Assert(sseFuzzTrace(mutated, [cut, mutated.size]), expected)
                executions += 3
            }
        }
        @Expect(executions, 1536)
        println("M11001_FUZZ target=sse-mutations seed=178 iterations=${executions} decision=PASS")
    }
    @TestCase
    func boundedFailureCorpusIsIndependentOfCuts(): Unit {
        let cases = [
            ("data:12345678901234567".toArray(), SseLimits(maximumLineBytes: 16), "error:line"),
            (":a\nunknown\n:b\n".toArray(), SseLimits(maximumFieldsPerEvent: 2), "error:field"),
            ("\n\n\n\n\n".toArray(), SseLimits(maximumBytesWithoutEvent: 4), "error:progress"),
            ("x:1234567".toArray(), SseLimits(maximumEventBytes: 8), "error:event"),
            ([105u8, 100u8, 58u8, 255u8, 255u8, 10u8], SseLimits(maximumIdBytes: 3), "error:id")
        ]
        for ((bytes, limits, expected) in cases) {
            @Assert(sseFuzzTrace(bytes, [bytes.size], limits: limits), expected)
            for (cut in 0..=bytes.size) {
                @Assert(sseFuzzTrace(bytes, [cut, bytes.size], limits: limits), expected)
            }
            @Assert(sseFuzzTrace(bytes, Array<Int64>(bytes.size, { index => index + 1 }), limits: limits), expected)
        }
    }
}

private class SseFuzzPrng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    // xorshift64, with no overflow arithmetic or external random dependency.
    func next(): UInt64 {
        state ^= state << 13u64
        state ^= state >> 7u64
        state ^= state << 17u64
        state
    }
}

private func sseFuzzTrace(bytes: Array<Byte>, ends: Array<Int64>, limits!: SseLimits = SseLimits(maximumLineBytes: 1024, maximumEventBytes: 4096, maximumIdBytes: 256, maximumBytesWithoutEvent: 4096)): String {
    let decoder = SseDecoder(limits: limits)
    var trace = ""
    var offset: Int64 = 0
    try {
        for (end in ends) {
            while (offset < end) {
                let result = decoder.decode(bytes, offset: offset, length: end - offset)
                if (result.consumed <= 0 || result.consumed > end - offset) {
                    throw IllegalStateException("decoder consumed outside its input window")
                }
                offset += result.consumed
                match (result.event) {
                    case Some(event) => trace += "${event.data.size}:${event.data}${event.eventType.size}:${event.eventType}${event.lastEventId.size}:${event.lastEventId};"
                    case None => ()
                }
                if (decoder.retainedBytes > limits.maximumRetainedBytes) {
                    throw IllegalStateException("decoder retained more than its reservation")
                }
            }
        }
        if (offset != bytes.size) { throw IllegalStateException("test did not consume full corpus") }
        decoder.finish()
        trace += "cursor=${decoder.lastEventId};retry="
        match (decoder.retryMilliseconds) {
            case Some(value) => trace += "${value}"
            case None => trace += "none"
        }
    } catch (error: SseException) {
        if (decoder.retainedBytes != 0u64) { throw IllegalStateException("failure retained decoder storage") }
        trace = "error:" + match (error.code) {
            case SseErrorCode.LineLimit => "line"
            case SseErrorCode.EventLimit => "event"
            case SseErrorCode.FieldLimit => "field"
            case SseErrorCode.NoProgress => "progress"
            case SseErrorCode.IdLimit => "id"
            case _ => throw IllegalStateException("unexpected decoder failure")
        }
    } finally { decoder.close() }
    if (decoder.retainedBytes != 0u64) { throw IllegalStateException("close retained decoder storage") }
    trace
}
