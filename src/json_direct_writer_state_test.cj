package yjson

import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonDirectWriterStateTest {
    @TestCase
    func packedStatePreservesCompactAndPrettyNesting(): Unit {
        let compact = JsonDirectWriter()
        compact.startObject()
        compact.writeName("items")
        compact.startArray()
        compact.writeInt64(1)
        compact.startObject()
        compact.writeName("ok")
        compact.writeBool(true)
        compact.endObject()
        compact.endArray()
        compact.endObject()
        @Expect(compact.finishString(), "{\"items\":[1,{\"ok\":true}]}")

        let pretty = JsonDirectWriter(pretty: true)
        pretty.startObject()
        pretty.writeName("items")
        pretty.startArray()
        pretty.writeInt64(1)
        pretty.startObject()
        pretty.writeName("ok")
        pretty.writeBool(true)
        pretty.endObject()
        pretty.endArray()
        pretty.endObject()
        @Expect(
            pretty.finishString(),
            "{\n  \"items\": [\n    1,\n    {\n      \"ok\": true\n    }\n  ]\n}"
        )
    }

    @TestCase
    func packedStateRejectsIllegalCallOrder(): Unit {
        let outside = JsonDirectWriter()
        let _ = @AssertThrows[JsonException](outside.writeName("value"))

        let array = JsonDirectWriter()
        array.startArray()
        let _ = @AssertThrows[JsonException](array.writeName("value"))
        let _ = @AssertThrows[JsonException](array.endObject())

        let object = JsonDirectWriter()
        object.startObject()
        let _ = @AssertThrows[JsonException](object.writeInt64(1))
    }

    @TestCase
    func packedStateRejectsMissingAndUnclosedValues(): Unit {
        let missingValue = JsonDirectWriter()
        missingValue.startObject()
        missingValue.writeName("value")
        let _ = @AssertThrows[JsonException](missingValue.endObject())

        let unclosedArray = JsonDirectWriter()
        unclosedArray.startArray()
        unclosedArray.writeInt64(1)
        let _ = @AssertThrows[JsonException](unclosedArray.finishString())

        let unclosedObject = JsonDirectWriter.bytes()
        unclosedObject.startObject()
        let _ = @AssertThrows[JsonException](unclosedObject.finishBytes())
    }
}
