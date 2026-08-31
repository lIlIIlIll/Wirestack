package yjson

import std.unittest.*
import std.unittest.testmacro.*

/**
 * JSON 大输入功能测试 - P2 级别
 *
 * 这些用例验证较大输入下的功能正确性，不作为稳定性能门槛。
 */

func generateLargeArray(count: Int64): String {
    let builder = StringBuilder()
    builder.append("[")
    for (i in 0..count) {
        if (i > 0) { builder.append(",") }
        builder.append("${i}")
    }
    builder.append("]")
    builder.toString()
}

func generateLargeString(size: Int64): String {
    let builder = StringBuilder()
    builder.append("\"")
    for (_ in 0..size) { builder.append("a") }
    builder.append("\"")
    builder.toString()
}

func generateWideObject(fieldCount: Int64): String {
    let builder = StringBuilder()
    builder.append("{")
    for (i in 0..fieldCount) {
        if (i > 0) { builder.append(",") }
        builder.append("\"field_${i}\":${i}")
    }
    builder.append("}")
    builder.toString()
}

@Test
class LargeArrayFunctionalityTest {
    @TestCase
    func parse10KArrayElements(): Unit {
        let json = generateLargeArray(10000)
        let value = JsonNode.parse(json)
        let arr = value.asArray()
        @Expect(arr.size() == 10000)
        @Expect(arr[0].asInt64() == 0)
        @Expect(arr[9999].asInt64() == 9999)
    }

    @TestCase
    func parse5KArrayElements(): Unit {
        let json = generateLargeArray(5000)
        let value = JsonNode.parse(json)
        @Expect(value.asArray().size() == 5000)
    }

    @TestCase
    func parse2KArrayElements(): Unit {
        let json = generateLargeArray(2000)
        let value = JsonNode.parse(json)
        @Expect(value.asArray().size() == 2000)
    }
}

@Test
class LargeStringFunctionalityTest {
    @TestCase
    func parse1KBString(): Unit {
        let json = generateLargeString(1024)
        let value = JsonNode.parse(json)
        @Expect(value.asString().size == 1024)
    }

    @TestCase
    func parse64KBString(): Unit {
        let json = generateLargeString(65536)
        let value = JsonNode.parse(json)
        @Expect(value.asString().size == 65536)
    }
}

@Test
class WideObjectFunctionalityTest {
    @TestCase
    func parse100FieldObject(): Unit {
        let json = generateWideObject(100)
        let value = JsonNode.parse(json)
        let obj = value.asObject()
        @Expect(obj.size() == 100)
        @Expect(obj.contains("field_0"))
        @Expect(obj.contains("field_99"))
    }

    @TestCase
    func parse1000FieldObject(): Unit {
        let json = generateWideObject(1000)
        let value = JsonNode.parse(json)
        @Expect(value.asObject().size() == 1000)
    }
}

@Test
class RoundtripLargeInputFunctionalityTest {
    @TestCase
    func roundtripSmallStructure(): Unit {
        let json = "{\"a\":1,\"b\":\"text\",\"c\":true}"
        let value = JsonNode.parse(json)
        let output = value.toString()
        let reparsed = JsonNode.parse(output)
        let obj = reparsed.asObject()
        @Expect(obj.size() == 3)
        @Expect(obj.get("a").getOrThrow().asInt64() == 1)
        @Expect(obj.get("b").getOrThrow().asString() == "text")
        @Expect(obj.get("c").getOrThrow().asBool())
    }

    @TestCase
    func roundtripLargeArray(): Unit {
        let json = generateLargeArray(1000)
        let value = JsonNode.parse(json)
        let output = value.toString()
        let reparsed = JsonNode.parse(output)
        let arr = reparsed.asArray()
        @Expect(arr.size() == 1000)
        @Expect(arr[0].asInt64() == 0)
        @Expect(arr[999].asInt64() == 999)
    }

    @TestCase
    func roundtripWideObject(): Unit {
        let json = generateWideObject(200)
        let value = JsonNode.parse(json)
        let output = value.toString()
        let reparsed = JsonNode.parse(output)
        let obj = reparsed.asObject()
        @Expect(obj.size() == 200)
        @Expect(obj.get("field_0").getOrThrow().asInt64() == 0)
        @Expect(obj.get("field_199").getOrThrow().asInt64() == 199)
    }

    @TestCase
    func multipleRoundtripsPreserveSemantics(): Unit {
        let json = "{\"a\":1,\"b\":\"text\",\"c\":[1,2,3]}"
        var value = JsonNode.parse(json)
        for (_ in 0..10) {
            value = JsonNode.parse(value.toString())
        }
        let obj = value.asObject()
        @Expect(obj.size() == 3)
        @Expect(obj.get("a").getOrThrow().asInt64() == 1)
        @Expect(obj.get("b").getOrThrow().asString() == "text")
        let arr = obj.get("c").getOrThrow().asArray()
        @Expect(arr.size() == 3)
        @Expect(arr[0].asInt64() == 1)
        @Expect(arr[1].asInt64() == 2)
        @Expect(arr[2].asInt64() == 3)
    }
}

@Test
class DirectReaderLargeInputFunctionalityTest {
    @TestCase
    func directReadLargeArray(): Unit {
        let json = generateLargeArray(5000)
        let reader = JsonDirectReader(json)
        reader.startArray()
        var count: Int64 = 0
        while (reader.hasArrayItem()) {
            let _ = reader.readInt64()
            count++
        }
        reader.endArray()
        reader.expectEnd()
        @Expect(count == 5000)
    }

    @TestCase
    func directReadWideObject(): Unit {
        let json = generateWideObject(500)
        let reader = JsonDirectReader(json)
        reader.startObject()
        var count: Int64 = 0
        while (reader.hasObjectField()) {
            let _ = reader.readName()
            let _ = reader.readInt64()
            count++
        }
        reader.endObject()
        reader.expectEnd()
        @Expect(count == 500)
    }
}

@Test
class FastReaderLargeInputFunctionalityTest {
    @TestCase
    func fastReadLargeArray(): Unit {
        let json = generateLargeArray(5000)
        let reader = JsonFastReader(json)
        reader.startRawArray()
        var count: Int64 = 0
        var first = true
        while (reader.hasRawArrayItem(first)) {
            reader.beforeRawArrayItem(first)  // Properly handle comma separator
            let _ = reader.readRawInt64()
            count++
            first = false
        }
        reader.endRawArray()
        reader.expectEnd()
        @Expect(count == 5000)
    }

    @TestCase
    func fastReadWideObject(): Unit {
        let json = generateWideObject(500)
        let reader = JsonFastReader(json)
        reader.startRawObject()
        var count: Int64 = 0
        var first = true
        while (reader.hasRawObjectField(first)) {
            let _ = reader.readRawName(first)
            let _ = reader.readRawInt64()
            count++
            first = false
        }
        reader.endRawObject()
        reader.expectEnd()
        @Expect(count == 500)
    }
}
