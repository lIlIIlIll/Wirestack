package yjson_native

import yjson.*
import std.unittest.*
import std.unittest.testmacro.*

private func nativeCompactBytes(text: String): Array<Byte> {
    unsafe { text.rawData() }
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
            @Expect(root.kind(), JsonKind.Object)
            @Expect(root.size(), 7)
            @Expect(root.member("bool").getOrThrow().asBool(), true)
            @Expect(root.member("int").getOrThrow().asInt64(), Int64.Min)
            @Expect(root.member("number").getOrThrow().asNumberText(), "1.25e-3")
            @Expect(root.member("text").getOrThrow().asString(), "中😀")
            @Expect(root.member("array").getOrThrow().element(2).getOrThrow().asString(), "x")
            @Expect(root.member("object").getOrThrow().member("nested").getOrThrow().asInt64(), 42)
            @Expect(document.materialize().asObject().get("text").getOrThrow().asString(), "中😀")
            @Expect(document.materializeBulk().asObject().get("text").getOrThrow().asString(), "中😀")
            @Expect(document.materializeBulk().asObject().get("number").getOrThrow().asNumberText(),
                "1.25e-3")
            @Expect(document.materializeViaSerialization().asObject().get("int").getOrThrow().asInt64(),
                Int64.Min)
            let reparsed = JsonNode.parse(document.toString())
            @Expect(reparsed.asObject().get("number").getOrThrow().asNumberText(), "1.25e-3")
        }
    }

    @TestCase
    func duplicateSemanticEqualityMatchesCompactBackend(): Unit {
        let text = "{\"a\":1,\"\\u0061\":2,\"中\":3,\"\\u4e2d\":4}"
        let lastWins = JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins)
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes(text), config: lastWins)) {
            @Expect(document.root().size(), 2)
            @Expect(document.root().member("a").getOrThrow().asInt64(), 2)
            @Expect(document.root().member("中").getOrThrow().asInt64(), 4)
        }
        let error = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes(text), config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)))
        @Expect(error.code, "duplicate_key")
    }

    @TestCase
    func preserveLiteralAndErrorContracts(): Unit {
        try (document = NativeCompactJsonDocument.parse(nativeCompactBytes("[1,-2,3.0]"),
            config: JsonReadOptions())) {
            @Expect(document.root().element(0).getOrThrow().kind(), JsonKind.Number)
            @Expect(document.root().element(0).getOrThrow().asNumberText(), "1")
            @Expect(document.root().element(2).getOrThrow().asNumberText(), "3.0")
        }
        for (invalid in ["01", "1.", "1e", "1e+", "-", "[1,]", "{\"a\" 1}", "\"\\uD800\""]) {
            let error = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(nativeCompactBytes(invalid)))
            @Expect(error.location.getOrThrow().byteOffset >= 0)
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
        let error = @AssertThrows[JsonException](root.kind())
        @Expect(error.code, "resource_closed")
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
        let lastWins = JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins)
        let portable = YJson.parseDocument(bytes, config: lastWins)
        try (native = NativeCompactJsonDocument.parse(bytes, config: lastWins)) {
            @Expect(native.root().size(), portable.root().size())
            @Expect(native.root().member("prefix_0").getOrThrow().asInt64(), 9999)
            @Expect(native.root().member("prefix_2047").getOrThrow().asInt64(), 2047)
            @Expect(JsonNode.parse(native.toString()).asObject().size(), 2048)
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
            @Expect(document.root().member("plain").getOrThrow().asString(), "value")
            @Expect(document.root().member("number").getOrThrow().asNumberText(), "1.5")
            @Expect(document.root().member("escaped").getOrThrow().asString(), "ab")
            @Expect(JsonNode.parse(document.toString()).asObject().size(), 3)
        }
    }

    @TestCase
    func resourceLimitsMatchPortableBackend(): Unit {
        let documentError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("{\"a\":1}"), config: JsonReadOptions(maxInputBytes: 6)))
        @Expect(documentError.code, "document_too_large")
        let stringError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("\"\\u4E2D\""), config: JsonReadOptions(maxStringBytes: 2)))
        @Expect(stringError.code, "string_too_large")
        let valueError = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("{\"a\":[1,2]}"),
            config: JsonReadOptions(maxBufferedValueBytes: 10)))
        @Expect(valueError.code, "buffered_value_too_large")
        let hiddenLocation = @AssertThrows[JsonException](NativeCompactJsonDocument.parse(
            nativeCompactBytes("\"abc\""),
            config: JsonReadOptions(maxStringBytes: 2)))
        @Expect(hiddenLocation.code, "string_too_large")
        @Expect(hiddenLocation.location.isSome())
    }
}
