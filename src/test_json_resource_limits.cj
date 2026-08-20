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
        let config = JsonReadConfig(maxBytes: 0, maxStringBytes: 0,
            maxPolymorphicObjectBytes: 0)
        @Expect(YJson.parse("{\"value\":\"unlimited\"}", config: config).asObject().size(), 1)
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(maxBytes: -1) }))
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(maxStringBytes: -1) }))
        @Expect(rejectsResourceConfig({ => let _ = JsonReadConfig(maxPolymorphicObjectBytes: -1) }))
    }

    @TestCase
    func documentLimitUsesExactInputBytes(): Unit {
        let text = "{\"a\":1}"
        @Expect(YJson.parse(text, config: JsonReadConfig(maxBytes: 7)).asObject().size(), 1)
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse(text, config: JsonReadConfig(maxBytes: 6))
        }), "document_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = CompactJsonDocument.parse(unsafe { text.rawData() },
                config: JsonReadConfig(maxBytes: 6))
        }), "document_too_large")
    }

    @TestCase
    func stringLimitCountsDecodedUtf8BytesForValuesAndKeys(): Unit {
        @Expect(YJson.parse("\"abc\"", config: JsonReadConfig(maxStringBytes: 3)).asString().value,
            "abc")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"abc\"", config: JsonReadConfig(maxStringBytes: 2))
        }), "string_too_large")

        @Expect(YJson.parse("\"\\u4E2D\"", config: JsonReadConfig(maxStringBytes: 3)).asString().value,
            "中")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"\\u4E2D\"", config: JsonReadConfig(maxStringBytes: 2))
        }), "string_too_large")
        @Expect(YJson.parse("\"🙂\"", config: JsonReadConfig(maxStringBytes: 4)).asString().value,
            "🙂")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("{\"\\u4E2D\":1}", config: JsonReadConfig(maxStringBytes: 2))
        }), "string_too_large")
        @Expect(YJson.parse("\"\\uD83D\\uDE42\"",
            config: JsonReadConfig(maxStringBytes: 4)).asString().value, "🙂")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse("\"\\uD83D\\uDE42\"",
                config: JsonReadConfig(maxStringBytes: 3))
        }), "string_too_large")
    }

    @TestCase
    func rootContainerLimitIncludesNestedContentButNotTrailingWhitespace(): Unit {
        let text = "{\"a\":[1,2]}"
        @Expect(YJson.parse(text + "   ",
            config: JsonReadConfig(maxPolymorphicObjectBytes: text.size)).asObject().size(), 1)
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.parse(text,
                config: JsonReadConfig(maxPolymorphicObjectBytes: text.size - 1))
        }), "polymorphic_object_too_large")
    }

    @TestCase
    func chunkedStreamEnforcesAllLimitsDuringTypedDecode(): Unit {
        @Expect(YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"中\"", 1),
            config: JsonReadConfig(maxBytes: 5, maxStringBytes: 3)), "中")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"中\"", 1),
                config: JsonReadConfig(maxStringBytes: 2))
        }), "string_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(StringJson, FixedChunkInputStream("\"abc\"", 1),
                config: JsonReadConfig(maxBytes: 4))
        }), "document_too_large")
        @Expect(resourceLimitErrorCode({ =>
            let _ = YJson.decodeFromStreamWith(YJson.arrayCodec<Int64>(Int64Json),
                FixedChunkInputStream("[1,2]", 1),
                config: JsonReadConfig(maxPolymorphicObjectBytes: 4))
        }), "polymorphic_object_too_large")
    }

    @TestCase
    func disabledErrorLocationKeepsResourceCodeButOmitsOffset(): Unit {
        let error = @AssertThrows[JsonException](YJson.parse("\"abc\"",
            config: JsonReadConfig(includeErrorLocation: false, maxStringBytes: 2)))
        @Expect(error.code, "string_too_large")
        @Expect(error.byteOffset, -1)
    }
}
