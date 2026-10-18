package wirestack.sse

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SseEncoderTest {
    @TestCase
    func representableEventsRoundtripAcrossEveryCut(): Unit {
        for (event in [SseEvent(""), SseEvent("first\n\nlast\n", eventType: " update", lastEventId: " 42"),
            SseEvent("雪🙂\0", eventType: "custom", lastEventId: "cursor")]) {
            let encoder = SseEncoder()
            let bytes = encoder.encode(event, retryMilliseconds: Some(999999u64))
            for (cut in 0..=bytes.size) {
                let decoder = SseDecoder(lastEventId: "old")
                let first = decoder.decode(bytes, length: Some(cut))
                let decoded = if (first.event.isSome()) { first.event.getOrThrow() }
                    else { decoder.decode(bytes, offset: cut).event.getOrThrow() }
                @Expect(decoded.data, event.data)
                @Expect(decoded.eventType, event.eventType)
                @Expect(decoded.lastEventId, event.lastEventId)
                @Expect(decoder.lastEventId, event.lastEventId)
                @Expect(decoder.retryMilliseconds, Some(60000u64))
                decoder.close()
            }
        }
    }

    @TestCase
    func commentsDoNotDispatchAndPreserveFollowingEvent(): Unit {
        let encoder = SseEncoder()
        let decoder = SseDecoder(lastEventId: "retained")
        @Expect(decoder.decode(encoder.comment("keepalive\n雪\n")).event.isNone())
        @Expect(decoder.lastEventId, "retained")
        let event = decoder.decode(encoder.encode(SseEvent("next"))).event.getOrThrow()
        @Expect(event.data, "next")
        @Expect(event.lastEventId, "")
        decoder.close()
    }

    @TestCase
    func metadataAndCommentInjectionAreRejected(): Unit {
        let encoder = SseEncoder()
        for (value in ["x\ny", "x\ry", "x\0y"]) {
            @Expect(encoderFailure({ => encoder.encode(SseEvent("data", eventType: value)) }), SseErrorCode.InvalidMetadata)
            @Expect(encoderFailure({ => encoder.encode(SseEvent("data", lastEventId: value)) }), SseErrorCode.InvalidMetadata)
        }
        @Expect(encoderFailure({ => encoder.encode(SseEvent("x\ry")) }), SseErrorCode.InvalidMetadata)
        @Expect(encoderFailure({ => encoder.encode(SseEvent("x", eventType: "")) }), SseErrorCode.InvalidMetadata)
        @Expect(encoderFailure({ => encoder.comment("x\ry") }), SseErrorCode.InvalidMetadata)
        @Expect(encoderFailure({ => encoder.comment("x\0y") }), SseErrorCode.InvalidMetadata)
    }

    @TestCase
    func serializedBoundsIncludePrefixesAndDelimiters(): Unit {
        let event = SseEvent("a", eventType: "m", lastEventId: "i")
        let bytes = SseEncoder().encode(event)
        @Expect(bytes.size, 24)
        let exact = SseLimits(maximumLineBytes: 8, maximumEventBytes: 24, maximumFieldsPerEvent: 3,
            maximumBytesWithoutEvent: 24, maximumIdBytes: 1)
        @Expect(SseEncoder(limits: exact).encode(event).size, 24)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumEventBytes: 23)).encode(event) }), SseErrorCode.EventLimit)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumLineBytes: 7)).encode(event) }), SseErrorCode.LineLimit)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumFieldsPerEvent: 2)).encode(event) }), SseErrorCode.FieldLimit)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumIdBytes: 1)).encode(SseEvent("", lastEventId: "雪")) }), SseErrorCode.IdLimit)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumBytesWithoutEvent: 23)).encode(event) }), SseErrorCode.NoProgress)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumLineBytes: 3)).comment("aa") }), SseErrorCode.LineLimit)
        @Expect(encoderFailure({ => SseEncoder(limits: SseLimits(maximumFieldsPerEvent: 1)).comment("a\nb") }), SseErrorCode.FieldLimit)
    }
}

private func encoderFailure(operation: () -> Array<Byte>): SseErrorCode {
    try { operation(); throw Exception("expected encoder rejection") }
    catch (error: SseException) { error.code }
}
