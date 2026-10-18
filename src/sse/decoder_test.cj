package wirestack.sse

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SseDecoderTests {
    @TestCase
    func bomAndLineEndingsHaveIndependentExpectedEvents(): Unit {
        let decoder = SseDecoder()
        let bytes = "\u{feff}data: €😀\r\nid: first\r\n\r\ndata: second\r\rdata: third\n\n".toArray()
        let first = decoder.decode(bytes)
        @Expect(first.event.getOrThrow().data, "€😀")
        @Expect(first.event.getOrThrow().lastEventId, "first")
        let second = decoder.decode(bytes, offset: first.consumed)
        @Expect(second.event.getOrThrow().data, "second")
        let third = decoder.decode(bytes, offset: first.consumed + second.consumed)
        @Expect(third.event.getOrThrow().data, "third")
        decoder.close()
        let doubled = SseDecoder()
        @Expect(doubled.decode("\u{feff}\u{feff}data: ignored\n\n".toArray()).event.isNone())
        @Expect(doubled.decode("data: kept\n\n".toArray()).event.getOrThrow().data, "kept")
        doubled.close()
    }
    @TestCase
    func incompleteUtf8PrefixReplacesOnceAtLineEndAndEofNeverDispatches(): Unit {
        for (prefix in [[226u8], [226u8, 130u8], [240u8, 144u8, 128u8]]) {
            let decoder = SseDecoder()
            let _ = decoder.decode("data:".toArray())
            let _ = decoder.decode(prefix)
            @Expect(decoder.decode([10u8, 10u8]).event.getOrThrow().data, "\u{fffd}")
            decoder.close()
        }
        let incomplete = SseDecoder()
        @Expect(incomplete.decode("data: x\n".toArray()).event.isNone())
        incomplete.finish()
        @Expect(incomplete.lastEventId, "")
        incomplete.close()
        @Expect(incomplete.retainedBytes, 0u64)
    }
    @TestCase
    func multilineEmptyDataAndOpaquePayload(): Unit {
        let decoder = SseDecoder()
        let input = "data: first\ndata:  second\nevent: custom\nid: cursor\n\ndata:\n\ndata: [DONE]\n\n".toArray()
        let first = decoder.decode(input)
        let event = first.event.getOrThrow()
        @Expect(event.data, "first\n second")
        @Expect(event.eventType, "custom")
        @Expect(event.lastEventId, "cursor")
        @Expect(first.consumed < input.size)
        let second = decoder.decode(input, offset: first.consumed)
        @Expect(second.event.getOrThrow().data, "")
        @Expect(second.event.getOrThrow().eventType, "message")
        @Expect(second.event.getOrThrow().lastEventId, "cursor")
        let third = decoder.decode(input, offset: first.consumed + second.consumed)
        @Expect(third.event.getOrThrow().data, "[DONE]")
        decoder.close()
    }
    @TestCase
    func idLineCommitsCursorImmediatelyAndEofKeepsItWithoutDispatch(): Unit {
        let decoder = SseDecoder(lastEventId: "old")
        let _ = decoder.decode("id: next\n".toArray())
        @Expect(decoder.lastEventId, "next")
        @Expect(decoder.decode("\n".toArray()).event.isNone())
        @Expect(decoder.lastEventId, "next")
        let _ = decoder.decode("id: unfinished\ndata: pending\n".toArray())
        @Expect(decoder.lastEventId, "unfinished")
        decoder.finish()
        @Expect(decoder.lastEventId, "unfinished")
        @Expect(@AssertThrows[SseException](decoder.decode(Array<Byte>())).code == SseErrorCode.Closed)
        decoder.close()
    }
    @TestCase
    func retryIsImmediateDigitOnlyClampedWithoutOverflow(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumRetryMilliseconds: 123u64))
        let _ = decoder.decode("retry: 42\n".toArray())
        @Expect(decoder.retryMilliseconds.getOrThrow(), 42u64)
        for (value in ["", "-1", "+2", " 3", "4 ", "١", "999999999999999999999x"]) {
            let _ = decoder.decode(("retry: " + value + "\n").toArray())
            @Expect(decoder.retryMilliseconds.getOrThrow(), 42u64)
        }
        let _ = decoder.decode("retry: 999999999999999999999999999999999999999999\n".toArray())
        @Expect(decoder.retryMilliseconds.getOrThrow(), 123u64)
        let _ = decoder.decode("retry: 00000\n".toArray())
        @Expect(decoder.retryMilliseconds.getOrThrow(), 0u64)
        decoder.close()
    }
    @TestCase
    func zeroRetryCapIgnoresHintsAcrossEveryChunkBoundary(): Unit {
        for (value in ["0", "00000", "42", "999999999999999999999999999999999999999999"]) {
            let bytes = ("retry: " + value + "\r\n").toArray()
            for (cut in 0..=bytes.size) {
                let decoder = SseDecoder(limits: SseLimits(maximumRetryMilliseconds: 0u64))
                let _ = decoder.decode(bytes, length: Some(cut))
                @Expect(decoder.retryMilliseconds.isNone())
                let _ = decoder.decode(bytes, offset: cut)
                @Expect(decoder.retryMilliseconds.isNone())
                decoder.close()
            }
        }
        let zero = "retry:0\r\n".toArray()
        for (cut in 0..=zero.size) {
            let decoder = SseDecoder(limits: SseLimits(maximumRetryMilliseconds: 1u64))
            let _ = decoder.decode("retry:1\n".toArray())
            let _ = decoder.decode(zero, length: Some(cut))
            let _ = decoder.decode(zero, offset: cut)
            @Expect(decoder.retryMilliseconds, Some(0u64))
            decoder.close()
        }
    }
    @TestCase
    func nullIdIsIgnoredAndEmptyIdClearsCursor(): Unit {
        let decoder = SseDecoder(lastEventId: "previous")
        let first = decoder.decode("id: bad\u{0000}value\ndata: x\n\n".toArray()).event.getOrThrow()
        @Expect(first.lastEventId, "previous")
        let second = decoder.decode("id\ndata: y\n\n".toArray()).event.getOrThrow()
        @Expect(second.lastEventId, "")
        @Expect(decoder.lastEventId, "")
        decoder.close()
    }
    @TestCase
    func blankBlocksResetEventTypeAndFieldsNotNoProgress(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumFieldsPerEvent: 2))
        let _ = decoder.decode("event: discarded\n\n: comment\nunknown: ignored\n\n".toArray())
        let event = decoder.decode("Event: case-sensitive\ndata: kept\n\n".toArray()).event.getOrThrow()
        @Expect(event.eventType, "message")
        @Expect(event.data, "kept")
        decoder.close()
    }
    @TestCase
    func malformedUtf8UsesEncodingStandardReplacement(): Unit {
        let prefix = "data: ".toArray()
        let malformed = [194u8, 65u8, 224u8, 128u8, 128u8, 237u8, 160u8, 128u8,
            240u8, 144u8, 128u8, 244u8, 144u8, 128u8, 128u8, 255u8]
        let bytes = Array<Byte>(prefix.size + malformed.size + 2, repeat: 10u8)
        prefix.copyTo(bytes)
        malformed.copyTo(bytes, 0, prefix.size, malformed.size)
        let decoder = SseDecoder()
        let event = decoder.decode(bytes).event.getOrThrow()
        @Expect(event.data, "\u{fffd}A\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}")
        decoder.close()
    }
    @TestCase
    func lineBoundChecksBeforeGrowthAndFailureReleasesStorage(): Unit {
        let limits = SseLimits(maximumLineBytes: 7)
        let decoder = SseDecoder(limits: limits)
        @Expect(decoder.decode("data: x\n\n".toArray()).event.getOrThrow().data, "x")
        let error = @AssertThrows[SseException](decoder.decode("data: xx".toArray()))
        @Expect(error.code == SseErrorCode.LineLimit)
        @Expect(decoder.retainedBytes, 0u64)
        @Expect(@AssertThrows[SseException](decoder.decode(Array<Byte>())).code == SseErrorCode.Closed)
    }
    @TestCase
    func eventByteBoundIncludesIgnoredFieldsAndBlankDelimiter(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumEventBytes: 8))
        @Expect(decoder.decode("data:x\n\n".toArray()).event.getOrThrow().data, "x")
        let error = @AssertThrows[SseException](decoder.decode("x:1234567".toArray()))
        @Expect(error.code == SseErrorCode.EventLimit)
        @Expect(decoder.retainedBytes, 0u64)
    }
    @TestCase
    func fieldsIncludeCommentsAndUnknownNames(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumFieldsPerEvent: 2))
        let error = @AssertThrows[SseException](decoder.decode(":a\nunknown\n:b\n".toArray()))
        @Expect(error.code == SseErrorCode.FieldLimit)
        @Expect(decoder.retainedBytes, 0u64)
    }
    @TestCase
    func noProgressIsNotResetByHeartbeatOrCursorOnlyBlocks(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumBytesWithoutEvent: 8))
        let _ = decoder.decode(":\n\nid\n\n\n".toArray())
        let error = @AssertThrows[SseException](decoder.decode("\n".toArray()))
        @Expect(error.code == SseErrorCode.NoProgress)
        @Expect(decoder.retainedBytes, 0u64)
        let progressing = SseDecoder(limits: SseLimits(maximumBytesWithoutEvent: 8))
        for (_ in 0..10) {
            @Expect(progressing.decode("data:x\n\n".toArray()).event.getOrThrow().data, "x")
        }
        progressing.close()
    }
    @TestCase
    func decodedIdBoundIncludesReplacementExpansion(): Unit {
        let decoder = SseDecoder(limits: SseLimits(maximumIdBytes: 3))
        let first = decoder.decode([105u8, 100u8, 58u8, 255u8, 10u8, 10u8])
        @Expect(first.event.isNone())
        @Expect(decoder.lastEventId, "\u{fffd}")
        let error = @AssertThrows[SseException](decoder.decode([105u8, 100u8, 58u8, 255u8, 255u8, 10u8]))
        @Expect(error.code == SseErrorCode.IdLimit)
        @Expect(decoder.retainedBytes, 0u64)
    }
    @TestCase
    func windowsLifecycleAndHardCeilings(): Unit {
        let decoder = SseDecoder()
        @Expect(decoder.decode(Array<Byte>()).consumed, 0)
        @AssertThrows[IllegalArgumentException](decoder.decode([0u8], offset: -1))
        @AssertThrows[IllegalArgumentException](decoder.decode([0u8], length: Int64.Max))
        @Expect(decoder.decode("xxdata:x\n\nyy".toArray(), offset: 2, length: 8).event.getOrThrow().data, "x")
        @Expect(decoder.retainedBytes <= SseLimits().maximumRetainedBytes)
        decoder.close()
        decoder.close()
        decoder.finish()
        @Expect(decoder.retainedBytes, 0u64)
        @AssertThrows[IllegalArgumentException](SseLimits(maximumLineBytes: 0))
        @AssertThrows[IllegalArgumentException](SseLimits(maximumEventBytes: 16 * 1024 * 1024 + 1))
        @AssertThrows[IllegalArgumentException](SseLimits(maximumFieldsPerEvent: 65537))
        @AssertThrows[IllegalArgumentException](SseLimits(maximumBytesWithoutEvent: 64 * 1024 * 1024 + 1))
        @AssertThrows[IllegalArgumentException](SseLimits(maximumIdBytes: 65537))
        @AssertThrows[IllegalArgumentException](SseLimits(maximumRetryMilliseconds: 86400001u64))
        @Expect(@AssertThrows[SseException](SseDecoder(lastEventId: "bad\n")).code == SseErrorCode.InvalidMetadata)
        @Expect(@AssertThrows[SseException](SseDecoder(limits: SseLimits(maximumIdBytes: 1), lastEventId: "xx")).code == SseErrorCode.IdLimit)
    }
}
