package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func compactBytes(text: String): Array<Byte> { unsafe { text.rawData().clone() } }

@Test
class CompactJsonDocumentTest {
    @TestCase
    func parsesAllJsonKindsAndTraversesWithoutMaterializing(): Unit {
        let document = YJson.parseCompact(compactBytes(
            "{\"null\":null,\"bool\":true,\"int\":-7,\"float\":1.25e2," +
            "\"text\":\"仓颉😀\\n\",\"array\":[1,{\"x\":2}]}"
        ))
        let root = document.root()
        @Expect(root.kind(), JsObject)
        @Expect(root.size(), 6)
        @Expect(root.get("bool").getOrThrow().asBool(), true)
        @Expect(root.get("int").getOrThrow().asInt64(), -7)
        @Expect(root.get("text").getOrThrow().asString(), "仓颉😀\n")
        @Expect(root.get("array").getOrThrow().get(1).getOrThrow().get("x").getOrThrow().asInt64(), 2)
        @Expect(document.materialize().asObject().get("array").getOrThrow().asArray().size(), 2)
        @Expect(YJson.parse(document.toString()).asObject().size(), 6)
    }

    @TestCase
    func preservesLastWinsAndRejectPolicies(): Unit {
        let bytes = compactBytes("{\"x\":1,\"x\":2}")
        @Expect(YJson.parseCompact(bytes).root().get("x").getOrThrow().asInt64(), 2)
        var rejected = false
        try {
            let _ = YJson.parseCompact(bytes, config: JsonReadConfig(duplicateKeyPolicy: Reject))
        } catch (error: JsonException) {
            rejected = error.code == "parse_error"
        }
        @Assert(rejected)
    }

    @TestCase
    func retainsSourceKeyViewsWithoutChangingLookup(): Unit {
        let document = YJson.parseCompact(compactBytes(
            "[{\"id\":1,\"ok\":true},{\"id\":2,\"ok\":false}]"
        ))
        let stats = document.storageStats()
        @Expect(stats.objectFields, 4)
        @Expect(stats.indexedKeys, 0)
        @Expect(stats.slicedKeys, 4)
        @Expect(stats.sourceViewKeys, 4)
        @Expect(stats.ownedKeyViews, 0)
        @Expect(stats.keyRangeRecoveries, 0)
        // The four scalar fields are stored directly in object entries; only
        // the two objects and their containing array require generic nodes.
        @Expect(stats.nodes, 3)
        @Expect(document.root().get(1).getOrThrow().get("id").getOrThrow().asInt64(), 2)
        @Expect(document.root().get(0).getOrThrow().get("ok").getOrThrow().asBool(), true)
    }

    @TestCase
    func ownedInputIsolatedFromCallerMutation(): Unit {
        let bytes = compactBytes("{\"name\":\"Alice\",\"active\":true}")
        let document = YJson.parseCompactOwned(bytes)
        for (index in 0..bytes.size) { bytes[index] = b' ' }

        @Expect(document.root().get("name").getOrThrow().asString(), "Alice")
        @Expect(document.root().get("active").getOrThrow().asBool(), true)
        @Expect(document.toString(), "{\"name\":\"Alice\",\"active\":true}")
    }

    @TestCase
    func preservesInt64BoundariesAndLargeNumberLiterals(): Unit {
        let document = YJson.parseCompact(compactBytes("[-9223372036854775808,9223372036854775807,9223372036854775808]"))
        @Expect(document.root().get(0).getOrThrow().asInt64(), -9223372036854775808)
        @Expect(document.root().get(1).getOrThrow().asInt64(), 9223372036854775807)
        @Expect(document.materialize().asArray()[2].kind(), JsNumberLiteral)
    }

    @TestCase
    func numericArraySinglePassPreservesMixedNumberSemantics(): Unit {
        let text = "[0,-1,9223372036854775807,-9223372036854775808,1.25,1e3,-4.5E-2]"
        let compact = YJson.parseCompact(compactBytes(text)).materialize().asArray()
        let regular = YJson.parse(text).asArray()
        @Expect(compact.size(), regular.size())
        for (index in 0..regular.size()) {
            @Expect(compact[index].kind(), regular[index].kind())
            @Expect(compact[index].toString(), regular[index].toString())
        }
    }

    @TestCase
    func packedSlicedKeysAndLargeDuplicateIndexRetainSemantics(): Unit {
        var text = "{"
        for (index in 0..4200) {
            if (index > 0) { text += "," }
            text += "\"key_${index}\":${index}"
        }
        text += ",\"key_4199\":9001,\"escaped\\u005fkey\":7,\"仓颉\":8}"
        let document = YJson.parseCompact(compactBytes(text))
        @Expect(document.storageStats().slicedKeys > 0)
        @Expect(document.root().get("key_4199").getOrThrow().asInt64(), 9001)
        @Expect(document.root().get("escaped_key").getOrThrow().asInt64(), 7)
        @Expect(document.root().get("仓颉").getOrThrow().asInt64(), 8)
        @Expect(YJson.parse(document.toString()).asObject().size(), 4202)

        let error = @AssertThrows[JsonException](YJson.parseCompact(
            compactBytes(text), config: JsonReadConfig(duplicateKeyPolicy: Reject)))
        @Expect(error.code, "parse_error")
    }

    @TestCase
    func duplicateIndexPreservesSemanticsAcrossLargeGrowth(): Unit {
        var text = "{"
        for (index in 0..12000) {
            if (index > 0) { text += "," }
            text += "\"region_key_${index}\":${index}"
        }
        // The first key is repeated after many table growth steps; the escaped
        // spelling must compare as the same decoded semantic key.
        text += ",\"region_key_0\":77,\"region\\u005fkey_0\":88}"
        let document = YJson.parseCompact(compactBytes(text))
        @Expect(document.root().get("region_key_0").getOrThrow().asInt64(), 88)
        @Expect(document.root().size(), 12000)

        let error = @AssertThrows[JsonException](YJson.parseCompact(
            compactBytes(text), config: JsonReadConfig(duplicateKeyPolicy: Reject)))
        @Expect(error.code, "parse_error")
    }

    @TestCase
    func sourceAndEscapedKeyViewsPreserveSemanticEquality(): Unit {
        let sourceThenEscaped = YJson.parseCompact(compactBytes(
            "{\"a\":1,\"\\u0061\":2,\"仓颉😀\":3,\"\":4}"))
        @Expect(sourceThenEscaped.root().size(), 3)
        @Expect(sourceThenEscaped.root().get("a").getOrThrow().asInt64(), 2)
        @Expect(sourceThenEscaped.root().get("仓颉😀").getOrThrow().asInt64(), 3)
        @Expect(sourceThenEscaped.root().get("").getOrThrow().asInt64(), 4)
        @Expect(sourceThenEscaped.storageStats().sourceViewKeys, 3)
        @Expect(sourceThenEscaped.storageStats().ownedKeyViews, 1)
        @Expect(YJson.parse(sourceThenEscaped.toString()).asObject().size(), 3)
        @Expect(sourceThenEscaped.materialize().asObject().get("a").getOrThrow().asInt().value, 2)

        let escapedThenSource = YJson.parseCompact(compactBytes("{\"\\u0061\":1,\"a\":2}"))
        @Expect(escapedThenSource.root().size(), 1)
        @Expect(escapedThenSource.root().get("a").getOrThrow().asInt64(), 2)

        for (text in ["{\"a\":1,\"\\u0061\":2}", "{\"\\u0061\":1,\"a\":2}"]) {
            let error = @AssertThrows[JsonException](YJson.parseCompact(
                compactBytes(text), config: JsonReadConfig(duplicateKeyPolicy: Reject)))
            @Expect(error.code, "parse_error")
        }
    }

    @TestCase
    func sourceKeyViewRejectsInvalidUtf8WithoutMaterializing(): Unit {
        let invalid: Array<Byte> = [b'{', b'"', 0xEDu8, 0xA0u8, 0x80u8, b'"', b':', b'1', b'}']
        let error = @AssertThrows[JsonException](YJson.parseCompact(invalid))
        @Expect(error.code, "parse_error")
    }

    @TestCase
    func staticGeneratedObjectContainersRetainSemantics(): Unit {
        let person = samplePerson()
        let values = ArrayList<Person>()
        values.add(person)
        let arrayText = YJson.encodeStringWith(PersonStaticArrayListJson, values)
        @Expect(YJson.decodeStringWith(PersonStaticArrayListJson, arrayText)[0].address.zipcode, person.address.zipcode)
        let valuesByName = HashMap<String, Person>()
        valuesByName["owner"] = person
        let mapText = YJson.encodeStringWith(PersonStaticHashMapJson, valuesByName)
        @Expect(YJson.decodeStringWith(PersonStaticHashMapJson, mapText)["owner"].address.street, person.address.street)
    }

    @TestCase
    func rejectsMalformedAndInvalidUtf8(): Unit {
        for (text in ["[1,]", "{\"x\":}", "\"\\uD800\"", "01"]) {
            var rejected = false
            try { let _ = YJson.parseCompact(compactBytes(text)) } catch (_: JsonException) { rejected = true }
            @Assert(rejected)
        }
        let invalid: Array<Byte> = [b'"', 0xC0u8, 0xAFu8, b'"']
        var rejectedUtf8 = false
        try { let _ = YJson.parseCompact(invalid) } catch (_: JsonException) { rejectedUtf8 = true }
        @Assert(rejectedUtf8)
    }
}
