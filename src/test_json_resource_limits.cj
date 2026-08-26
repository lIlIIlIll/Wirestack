package yjson

import std.unittest.*
import std.unittest.testmacro.*

private func resourceLimitErrorCode(action: () -> Unit): String {
    try {
        action()
        ""
    } catch (error: JsonException) {
        error.code
    }
}

private func rejectsResourceConfig(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

@Test
class JsonResourceLimitsTest {
    @TestCase
    func zeroMeansUnlimitedAndNegativeLimitsAreRejected(): Unit {
        let config = JsonReadConfig(limits: JsonReadLimits(maxBytes: 0, maxStringBytes: 0,
            maxPolymorphicObjectBytes: 0))
        @Expect(YJson.parse("{\"value\":\"unlimited\"}", config: config).asObject().size(), 1)
        @Expect(JsonDirectReader("{\"value\":\"unlimited\"}").readBoundedValue(0)
            .asObject().size(), 1)
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(limits: JsonReadLimits(maxBytes: -1)) }))
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(limits: JsonReadLimits(maxStringBytes: -1)) }))
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(limits: JsonReadLimits(maxPolymorphicObjectBytes: -1)) }))
        @Expect(rejectsResourceConfig({ =>
            let _ = JsonDirectReader("null").readBoundedValue(-1)
        }))
    }

    @TestCase
    func documentLimitUsesExactInputBytes(): Unit {
        let text = "{\"a\":1}"
        @Expect(YJson.parse(text, config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 7))).asObject().size(), 1)
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse(text, config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 6)))
        }), "document_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = CompactJsonDocument.parse(unsafe { text.rawData() },
                config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 6)))
        }), "document_too_large")
    }

    @TestCase
    func stringLimitCountsDecodedUtf8BytesForValuesAndKeys(): Unit {
        @Expect(YJson.parse("\"abc\"", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 3))).asString().value,
            "abc")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"abc\"", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 2)))
        }), "string_too_large")

        @Expect(YJson.parse("\"\\u4E2D\"", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 3))).asString().value,
            "中")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"\\u4E2D\"", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 2)))
        }), "string_too_large")
        @Expect(YJson.parse("\"🙂\"", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 4))).asString().value,
            "🙂")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("{\"\\u4E2D\":1}", config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 2)))
        }), "string_too_large")
        @Expect(YJson.parse("\"\\uD83D\\uDE42\"",
            config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 4))).asString().value, "🙂")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"\\uD83D\\uDE42\"",
                config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 3)))
        }), "string_too_large")
    }

    @TestCase
    func rootContainerLimitIncludesNestedContentButNotTrailingWhitespace(): Unit {
        let text = "{\"a\":[1,2]}"
        @Expect(YJson.parse(text + "   ",
            config: JsonReadConfig(limits: JsonReadLimits(maxPolymorphicObjectBytes: text.size))).asObject().size(), 1)
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse(text,
                config: JsonReadConfig(limits: JsonReadLimits(maxPolymorphicObjectBytes: text.size - 1)))
        }), "polymorphic_object_too_large")
    }

    @TestCase
    func chunkedStreamEnforcesAllLimitsDuringTypedDecode(): Unit {
        @Expect(YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"中\"", 1),
            config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 5, maxStringBytes: 3))), "中")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"中\"", 1),
                config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 2)))
        }), "string_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"abc\"", 1),
                config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 4)))
        }), "document_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(YJson.arrayCodec<Int64>(Int64Json),
                FixedChunkInputStream("[1,2]", 1),
                config: JsonReadConfig(limits: JsonReadLimits(maxPolymorphicObjectBytes: 4)))
        }), "polymorphic_object_too_large")
    }

    @TestCase
    func disabledErrorLocationKeepsResourceCodeButOmitsOffset(): Unit {
        let error = @AssertThrows[JsonException](YJson.parse("\"abc\"",
            config: JsonReadConfig(includeErrorLocation: false,
                limits: JsonReadLimits(maxStringBytes: 2))))
        @Expect(error.code, "string_too_large")
        @Expect(error.byteOffset, -1)
    }

    @TestCase
    func astDepthCountsContainersOnlyForStringAndBytes(): Unit {
        let one = JsonReadConfig(limits: JsonReadLimits(maxDepth: 1))
        @Expect(YJson.parse("{\"name\":\"alice\"}", config: one).asObject().size(), 1)
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("{\"child\":{}}", config: one)
        }), "max_depth")
        let nestedBytes = unsafe { "[[]]".rawData().clone() }
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse(nestedBytes, config: one)
        }), "max_depth")
        @Expect(resourceLimitErrorCode({ =>
            let _ = parseJsonValueFromStream(FixedChunkInputStream("[[]]", 1), config: one)
        }), "max_depth")
    }

    @TestCase
    func boundedReplayDoesNotChargeScalarChildrenAsDepth(): Unit {
        let reader = JsonDirectReader("{\"name\":\"alice\"}", config: JsonReadConfig(limits: JsonReadLimits(maxDepth: 1)))
        @Expect(reader.readBoundedValue(0).asObject()["name"].asString().value, "alice")
    }

    @TestCase
    func skippedUnknownSubtreeUsesRemainingDepth(): Unit {
        let direct = JsonDirectReader("{\"unknown\":[[]]}", config: JsonReadConfig(limits: JsonReadLimits(maxDepth: 2)))
        direct.startObject()
        @Expect(direct.readName(), "unknown")
        @Expect(resourceLimitErrorCode({ => direct.skipValueWithDepth(1) }), "max_depth")

        let fast = JsonFastReader("[[[]]]")
        @Expect(resourceLimitErrorCode({ => fast.skipRawWithDepth(2) }), "max_depth")
    }

    @TestCase
    func policyAndStreamErrorsCarryStableCodesAndLocations(): Unit {
        let duplicateConfig = JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        let astDuplicate = @AssertThrows[JsonException](
            YJson.parse("{\"a\":1,\"a\":2}", config: duplicateConfig))
        @Expect(astDuplicate.code, "duplicate_key")

        let direct = JsonDirectReader("{\"a\":1,\"a\":2}", config: duplicateConfig)
        direct.startObject(); @Expect(direct.readName(), "a"); @Expect(direct.readInt64(), 1)
        let directDuplicate = @AssertThrows[JsonException](direct.readName())
        @Expect(directDuplicate.code, "duplicate_key")

        let streamError = @AssertThrows[JsonException](parseJsonValueFromStream(
            FixedChunkInputStream("{\n  \"a\": }", 1)))
        @Expect(streamError.code, "parse_error")
        @Expect(streamError.byteOffset >= 0)
        @Expect(streamError.line, 2)
        @Expect(streamError.column > 0)

        let parserNewlineError = @AssertThrows[JsonException](parseJsonValueFromStream(
            FixedChunkInputStream("\"abc\ndef\"", 1)))
        @Expect(parserNewlineError.byteOffset, 4)
        @Expect(parserNewlineError.line, 1)
        @Expect(parserNewlineError.column, 5)

        let directStream = JsonDirectReader(FixedChunkInputStream("\"abc\ndef\"", 1))
        let directNewlineError = @AssertThrows[JsonException](directStream.readString())
        @Expect(directNewlineError.byteOffset, 4)
        @Expect(directNewlineError.line, 1)
        @Expect(directNewlineError.column, 5)
    }
}
