package yjson_yyjson

import yjson.*
import std.unittest.*
import std.unittest.testmacro.*

private func yyjsonBytes(text: String): Array<Byte> { unsafe { text.rawData() } }

@Test
class YyjsonCompactTests {
    @TestCase
    func directAndTranscodePreserveSemanticProjection(): Unit {
        let text = "{\"i\":-9223372036854775808,\"n\":1.2300,\"s\":\"普通😀\",\"a\":[true,null]}"
        for (mode in [YyjsonCompactMode.Direct, YyjsonCompactMode.Transcode]) {
            let document = YyjsonCompactJsonDocument.parse(yyjsonBytes(text),
                config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral), mode: mode)
            try {
                @Expect(document.rootSize(), 4)
                @Expect(document.getRootInt("i").getOrThrow(), Int64.Min)
                let parsed = YJson.parse(document.toBytes()).asObject()
                @Expect(parsed.get("n").getOrThrow().asNumberLiteral().literal, "1.2300")
                @Expect(parsed.get("s").getOrThrow().asString().value, "普通😀")
            } finally { document.close() }
        }
    }

    @TestCase
    func escapedEquivalentDuplicateUsesLastWinsOrRejects(): Unit {
        let bytes = yyjsonBytes("{\"a\":1,\"\\u0061\":2}")
        let document = YyjsonCompactJsonDocument.parse(bytes)
        try {
            @Expect(document.getRootInt("a").getOrThrow(), 2)
            @Expect(document.storageStats().customFallback, true)
        } finally { document.close() }
        @AssertThrows[JsonException](YyjsonCompactJsonDocument.parse(bytes,
            config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)))
    }

    @TestCase
    func closeIsIdempotentAndGuardsLaterAccess(): Unit {
        let document = YyjsonCompactJsonDocument.parse(yyjsonBytes("[1,2]"))
        document.close()
        document.close()
        @AssertThrows[IllegalStateException](document.rootSize())
    }

    @TestCase
    func selectiveNumbersAvoidRawStorageForExactInt64(): Unit {
        let integers = YyjsonCompactJsonDocument.parse(yyjsonBytes("[0,-1,9223372036854775807]"),
            numberStrategy: YyjsonNumberStrategy.SelectiveSource)
        try {
            let stats = integers.storageStats()
            @Expect(stats.safeIntNumbers, 3u64)
            @Expect(stats.rawRequiredNumbers, 0u64)
            @Expect(stats.literalEntries, 0u64)
            @Expect(stats.sourceCopyBytes, 0u64)
        } finally { integers.close() }

        let mixed = YyjsonCompactJsonDocument.parse(yyjsonBytes(
            "[9223372036854775808,1.2300,1E-3]"),
            numberStrategy: YyjsonNumberStrategy.SelectiveSource)
        try {
            let stats = mixed.storageStats()
            @Expect(stats.rawRequiredNumbers, 3u64)
            @Expect(stats.literalEntries, 3u64)
            let text = mixed.toString()
            @Expect(text.contains("9223372036854775808"))
            @Expect(text.contains("1.2300"))
            @Expect(text.contains("1E-3"))
        } finally { mixed.close() }

        let hugeExponent = YyjsonCompactJsonDocument.parse(yyjsonBytes("1844674e07370"),
            numberStrategy: YyjsonNumberStrategy.SelectiveSource)
        try { @Expect(hugeExponent.toString(), "1844674e07370") }
        finally { hugeExponent.close() }
    }

    @TestCase
    func retainedAndLazyRootIndexesKeepLookupSemantics(): Unit {
        var text = "{"
        for (index in 0..300) {
            if (index != 0) { text += "," }
            text += "\"k${index}\":${index}"
        }
        text += "}"
        let retained = YyjsonCompactJsonDocument.parse(yyjsonBytes(text),
            lookupIndexMode: YyjsonLookupIndexMode.Retained)
        try {
            @Expect(retained.storageStats().rootIndexBuilds, 1u64)
            @Expect(retained.getRootInt("k299").getOrThrow(), 299)
        } finally { retained.close() }
        let lazy = YyjsonCompactJsonDocument.parse(yyjsonBytes(text),
            lookupIndexMode: YyjsonLookupIndexMode.Lazy)
        try {
            @Expect(lazy.storageStats().rootIndexBuilds, 0u64)
            @Expect(lazy.getRootInt("k150").getOrThrow(), 150)
            @Expect(lazy.storageStats().rootIndexBuilds, 1u64)
        } finally { lazy.close() }
    }

    @TestCase
    func resourceLimitsMatchPortableBackend(): Unit {
        let documentError = @AssertThrows[JsonException](YyjsonCompactJsonDocument.parse(
            yyjsonBytes("{\"a\":1}"), config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 6))))
        @Expect(documentError.code, "document_too_large")
        let stringError = @AssertThrows[JsonException](YyjsonCompactJsonDocument.parse(
            yyjsonBytes("\"\\u4E2D\""), config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 2))))
        @Expect(stringError.code, "string_too_large")
        let valueError = @AssertThrows[JsonException](YyjsonCompactJsonDocument.parse(
            yyjsonBytes("{\"a\":[1,2]}"),
            config: JsonReadConfig(limits: JsonReadLimits(maxPolymorphicObjectBytes: 10))))
        @Expect(valueError.code, "polymorphic_object_too_large")
        let hiddenLocation = @AssertThrows[JsonException](YyjsonCompactJsonDocument.parse(
            yyjsonBytes("\"abc\""),
            config: JsonReadConfig(includeErrorLocation: false,
                limits: JsonReadLimits(maxStringBytes: 2))))
        @Expect(hiddenLocation.code, "string_too_large")
        @Expect(hiddenLocation.byteOffset, -1)
    }
}
