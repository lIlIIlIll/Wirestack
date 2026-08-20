package yjson_native

import yjson.*
import std.convert.Parsable
import std.unittest.*
import std.unittest.testmacro.*

private func nativeCompactBytes(text: String): Array<Byte> {
    unsafe { text.rawData() }
}

@Test
class NativeScannerIntegrationTest {
    @BeforeAll
    func installNativeScanner(): Unit {
        enableYJsonNative()
    }

    @TestCase
    func linkedScannerIsInstalledAndDecodesLongEscapedString(): Unit {
        @Expect((nativeScannerCapabilitiesForTesting() & 1u32) != 0u32)
        let builder = StringBuilder()
        builder.append("\"")
        for (_ in 0..32) {
            builder.append("prefix\\n\\t\\\"\\\\")
        }
        builder.append("\\u4ed3\\u9889\\uD834\\uDD1E\"")
        let expected = StringBuilder()
        for (_ in 0..32) {
            expected.append("prefix\n\t\"\\")
        }
        expected.append("仓颉\u{1D11E}")
        @Expect(YJson.decodeBytesWith(StringJson, nativeCompactBytes(builder.toString())),
            expected.toString())
    }

    private func assertNativeFloatMatchesStdlib(text: String): Unit {
        let reader = JsonFastReader(text)
        let actual = jsonFastReadFloat64(reader)
        reader.expectEnd()
        @Expect(actual.toBits(), Float64.parse(text).toBits())
    }

    @TestCase
    func nativeFloatParserKeepsStdlibBitsAndLongTokenFallback(): Unit {
        for (text in ["0", "-0.0", "1.5", "-12.75", "1e308", "1e309",
            "1e-323", "1e-324", "-1e309", "-1e-324",
            "0.12345678901234567", "3.141592653589793"]) {
            assertNativeFloatMatchesStdlib(text)
        }
        var longToken = "0."
        for (_ in 0..300) { longToken += "1" }
        assertNativeFloatMatchesStdlib(longToken)
    }
}

@Test
class NativeCompactDocumentTest {
    @TestCase
    func parsesAllKindsAndMaterializes(): Unit {
        let text = "{\"null\":null,\"bool\":true,\"int\":-9223372036854775808," +
            "\"number\":1.25e-3,\"text\":\"中😀\",\"array\":[1,false,\"x\"]," +
            "\"object\":{\"nested\":42}}"
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes(text))) {
            let root = document.root()
            @Expect(root.kind(), JsonKind.JsObject)
            @Expect(root.size(), 7)
            @Expect(root.get("bool").getOrThrow().asBool(), true)
            @Expect(root.get("int").getOrThrow().asInt64(), Int64.Min)
            @Expect(root.get("number").getOrThrow().asNumberLiteral(), "1.25e-3")
            @Expect(root.get("text").getOrThrow().asString(), "中😀")
            @Expect(root.get("array").getOrThrow().get(2).getOrThrow().asString(), "x")
            @Expect(root.get("object").getOrThrow().get("nested").getOrThrow().asInt64(), 42)
            @Expect(document.materialize().asObject().get("text").getOrThrow().asString().value, "中😀")
            @Expect(document.materializeBulk().asObject().get("text").getOrThrow().asString().value, "中😀")
            @Expect(document.materializeBulk().asObject().get("number").getOrThrow().asNumberLiteral().literal,
                "1.25e-3")
            @Expect(document.materializeViaSerialization().asObject().get("int").getOrThrow().asInt().value,
                Int64.Min)
            let reparsed = YJson.parse(document.toString())
            @Expect(reparsed.asObject().get("number").getOrThrow().asNumberLiteral().literal, "1.25e-3")
        }
    }

    @TestCase
    func duplicateSemanticEqualityMatchesCompactBackend(): Unit {
        let text = "{\"a\":1,\"\\u0061\":2,\"中\":3,\"\\u4e2d\":4}"
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes(text))) {
            @Expect(document.root().size(), 2)
            @Expect(document.root().get("a").getOrThrow().asInt64(), 2)
            @Expect(document.root().get("中").getOrThrow().asInt64(), 4)
        }
        let error = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes(text), config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)))
        @Expect(error.code, "parse_error")
    }

    @TestCase
    func preserveLiteralAndErrorContracts(): Unit {
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes("[1,-2,3.0]"),
            config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral))) {
            @Expect(document.root().get(0).getOrThrow().kind(), JsonKind.JsNumberLiteral)
            @Expect(document.root().get(0).getOrThrow().asNumberLiteral(), "1")
            @Expect(document.root().get(2).getOrThrow().asNumberLiteral(), "3.0")
        }
        for (invalid in ["01", "1.", "1e", "1e+", "-", "[1,]", "{\"a\" 1}", "\"\\uD800\""]) {
            let error = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(nativeCompactBytes(invalid)))
            @Expect(error.byteOffset >= 0)
        }
        let badUtf8: Array<Byte> = [b'"', 0xC0u8, 0xAFu8, b'"']
        @AssertThrows[JsonException](NativeCompactJsonDocument.parse(badUtf8))
    }

    @TestCase
    func closeInvalidatesViewsAndIsIdempotent(): Unit {
        let document = NativeCompactJsonDocument.parse(nativeCompactBytes("{\"a\":1}"))
        let root = document.root()
        document.close()
        document.close()
        @Expect(document.isClosed(), true)
        @AssertThrows[IllegalStateException](root.kind())
    }

    @TestCase
    func deterministicWideObjectDifferential(): Unit {
        var text = "{"
        for (index in 0..2048) {
            if (index != 0) { text += "," }
            text += "\"prefix_${index}\":${index}"
        }
        text += ",\"prefix_0\":9999}"
        let bytes = nativeCompactBytes(text)
        let portable = YJson.parseCompact(bytes)
        try (native = NativeCompactJsonDocument.parse(bytes)) {
            @Expect(native.root().size(), portable.root().size())
            @Expect(native.root().get("prefix_0").getOrThrow().asInt64(), 9999)
            @Expect(native.root().get("prefix_2047").getOrThrow().asInt64(), 2047)
            @Expect(YJson.parse(native.toString()).asObject().size(), 2048)
            let stats = native.storageStats()
            @Expect(stats.scratchCurrent, 0u64)
            @Expect(stats.objectFields, 2048u64)
            @Expect(stats.duplicateScratchPeak > 0u64)
        }
    }


    @TestCase
    func materializedSourceOwnsEveryRetainedSlice(): Unit {
        let text = "{\"plain\":\"value\",\"number\":1.5,\"escaped\":\"a\\u0062\"}"
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes(text),
            sourceOwnership: NativeCompactSourceOwnership.MaterializeSlices)) {
            @Expect(document.storageStats().sourceBytes, 0u64)
            @Expect(document.root().get("plain").getOrThrow().asString(), "value")
            @Expect(document.root().get("number").getOrThrow().asNumberLiteral(), "1.5")
            @Expect(document.root().get("escaped").getOrThrow().asString(), "ab")
            @Expect(YJson.parse(document.toString()).asObject().size(), 3)
        }
    }

    @TestCase
    func resourceLimitsMatchPortableBackend(): Unit {
        let documentError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("{\"a\":1}"), config: JsonReadConfig(maxBytes: 6)))
        @Expect(documentError.code, "document_too_large")
        let stringError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("\"\\u4E2D\""), config: JsonReadConfig(maxStringBytes: 2)))
        @Expect(stringError.code, "string_too_large")
        let valueError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("{\"a\":[1,2]}"),
            config: JsonReadConfig(maxPolymorphicObjectBytes: 10)))
        @Expect(valueError.code, "polymorphic_object_too_large")
        let hiddenLocation = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("\"abc\""),
            config: JsonReadConfig(includeErrorLocation: false, maxStringBytes: 2)))
        @Expect(hiddenLocation.code, "string_too_large")
        @Expect(hiddenLocation.byteOffset, -1)
    }
}
