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

    @TestCase
    func exercisesEveryPackedValueViewAndLookupOutcome(): Unit {
        let cases = [
            "null", "false", "true", "-9", "1.25e2", "\"text\"",
            "[]", "[1,2]", "[\"a\",\"b\"]", "[1,2.5,9223372036854775808]",
            "[null,false,3,4.5,\"x\",{},[]]",
            "{\"n\":null,\"b\":false,\"i\":7,\"d\":2.5,\"s\":\"v\",\"a\":[1],\"o\":{}}"
        ]
        for (text in cases) {
            let document = YJson.parseCompact(compactBytes(text),
                config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral))
            let root = document.root()
            @Expect(root.materialize().toString(), YJson.parse(text,
                config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral)).toString())
            @Expect(YJson.parse(document.toString()).toString(), YJson.parse(text).toString())
            @Expect(document.nodeCount() > 0, true)
            @Expect(document.sourceSize(), compactBytes(text).size)
            @Expect(document.storageStats().nodes, document.nodeCount())
            @Expect(document.traversalChecksum() >= 0, true)
        }

        let ints = YJson.parseCompact(compactBytes("[1,2]")).root()
        @Expect(ints.get(-1).isNone(), true)
        @Expect(ints.get(2).isNone(), true)
        @Expect(ints.get(0).getOrThrow().kind(), JsInt)
        @Expect(ints.get(0).getOrThrow().size(), 0)
        @Expect(ints.get(0).getOrThrow().get(0).isNone(), true)
        @Expect(ints.get(0).getOrThrow().get("x").isNone(), true)

        let strings = YJson.parseCompact(compactBytes("[\"a\",\"b\"]")).root()
        @Expect(strings.get(1).getOrThrow().kind(), JsString)
        @Expect(strings.get(1).getOrThrow().asString(), "b")

        let numbers = YJson.parseCompact(compactBytes("[1,2.5,9223372036854775808]")).root()
        @Expect(numbers.get(0).getOrThrow().kind(), JsInt)
        @Expect(numbers.get(1).getOrThrow().kind(), JsNumberLiteral)
        @Expect(numbers.get(2).getOrThrow().kind(), JsNumberLiteral)
        @Expect(numbers.get(1).getOrThrow().materialize().toString(), "2.5")

        let scalar = YJson.parseCompact(compactBytes("true")).root()
        @Expect(scalar.get(0).isNone(), true)
        @Expect(scalar.get("x").isNone(), true)
        @AssertThrows[JsonException](scalar.asString())
        @AssertThrows[JsonException](scalar.asInt64())

        var objectText = "{"
        for (index in 0..20) {
            if (index > 0) { objectText += "," }
            objectText += "\"key_${index}\":${index}"
        }
        objectText += "}"
        let object = YJson.parseCompact(compactBytes(objectText)).root()
        @Expect(object.get("key_19").getOrThrow().asInt64(), 19)
        @Expect(object.get("key_19").getOrThrow().asInt64(), 19)
        @Expect(object.get("missing").isNone(), true)
        @Expect(object.get("missing").isNone(), true)
        @Expect(object.get(0).isNone(), true)
        @AssertThrows[JsonException](object.asBool())
    }
}
