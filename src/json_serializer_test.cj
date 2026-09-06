package yjson

import std.unittest.*
import std.unittest.testmacro.*

func jsonValuesSemanticallyEqual(left: JsonNode, right: JsonNode): Bool {
    if (left.kind() != right.kind()) {
        return false
    }
    match (left) {
        case _: JsonNullValue => true
        case leftBool: JsonBoolValue => leftBool.value == right.asBool()
        case leftInt: JsonIntValue => leftInt.value == right.asInt64()
        case leftFloat: JsonFloatValue => leftFloat.value == right.asFloat64()
        case leftNumber: JsonNumberLiteralValue => leftNumber.literal == right.asNumberText()
        case leftString: JsonStringValue => leftString.value == right.asString()
        case leftArray: JsonArray => jsonArraysSemanticallyEqual(leftArray, right.asArray())
        case leftObject: JsonObject => jsonObjectsSemanticallyEqual(leftObject, right.asObject())
        case _ => false
    }
}

func jsonArraysSemanticallyEqual(left: JsonArray, right: JsonArray): Bool {
    if (left.size() != right.size()) {
        return false
    }
    for (index in 0..left.size()) {
        if (!jsonValuesSemanticallyEqual(left[index], right[index])) {
            return false
        }
    }
    true
}

func jsonObjectsSemanticallyEqual(left: JsonObject, right: JsonObject): Bool {
    if (left.size() != right.size()) {
        return false
    }
    for ((key, leftValue) in left.entries()) {
        if (!right.contains(key)) {
            return false
        }
        if (!jsonValuesSemanticallyEqual(leftValue, right.get(key).getOrThrow())) {
            return false
        }
    }
    true
}

func jsonRoundtripSemanticsEqual(input: String, output: String): Bool {
    jsonValuesSemanticallyEqual(JsonNode.parse(input), JsonNode.parse(output))
}

@Test
class JsonSerializerComplianceTest {
    @TestCase
    func serializeNull(): Unit {
        let nullValue = JsonNullValue()
        @Expect(nullValue.toString(), "null")
        @Expect(nullValue.toPrettyString(), "null")
    }

    @TestCase
    func serializeTrue(): Unit {
        let trueValue = JsonBoolValue(true)
        @Expect(trueValue.toString(), "true")
        @Expect(trueValue.toPrettyString(), "true")
    }

    @TestCase
    func serializeFalse(): Unit {
        let falseValue = JsonBoolValue(false)
        @Expect(falseValue.toString(), "false")
        @Expect(falseValue.toPrettyString(), "false")
    }

    @TestCase
    func serializeInteger(): Unit {
        let int123 = JsonIntValue(123)
        @Expect(int123.toString(), "123")

        let int0 = JsonIntValue(0)
        @Expect(int0.toString(), "0")

        let intNeg = JsonIntValue(-456)
        @Expect(intNeg.toString(), "-456")
    }

    @TestCase
    func serializeFloat(): Unit {
        let float1_5 = JsonFloatValue(1.5)
        @Expect(float1_5.toString().startsWith("1.5"))

        let float0_0 = JsonFloatValue(0.0)
        @Expect(float0_0.toString().startsWith("0."))

        let floatNeg = JsonFloatValue(-12.34)
        @Expect(floatNeg.toString().startsWith("-12.34"))
    }

    @TestCase
    func rejectSerializeNaN(): Unit {
        var caughtException = false
        try {
            let _ = JsonFloatValue(Float64.NaN).toString()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func rejectSerializePositiveInfinity(): Unit {
        var caughtException = false
        try {
            let _ = JsonFloatValue(Float64.Inf).toString()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func rejectSerializeNegativeInfinity(): Unit {
        var caughtException = false
        try {
            let _ = JsonFloatValue(-Float64.Inf).toString()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    /// NaN/+Inf/-Inf 在 AST 与 typed String/bytes/stream 目标上都必须被拒绝。
    @TestCase
    func rejectNonFiniteAcrossAstAndTypedTargets(): Unit {
        for (value in [Float64.NaN, Float64.Inf, -Float64.Inf]) {
            @AssertThrows[JsonException](JsonFloatValue(value).toString())
            @AssertThrows[JsonException](JsonFloatValue(value).toJson())
            @AssertThrows[JsonException](YJson.toJson(value, codec: JsonCodecs.float64))
            @AssertThrows[JsonException](YJson.toJsonBytes(value, codec: JsonCodecs.float64))
            let output = MemoryOutputStream()
            @AssertThrows[JsonException](
                YJson.writeJson(value, output, codec: JsonCodecs.float64))
            // 非有限值不允许进入容器写入。
            @AssertThrows[JsonException](JsonArray().add(JsonFloatValue(value)).toJson())
        }
    }

    @TestCase
    func serializeNumberLiteral(): Unit {
        let literal = JsonNumberLiteralValue("12345678901234567890")
        @Expect(literal.toString(), "12345678901234567890")
    }

    @TestCase
    func rejectInvalidPublicNumberLiterals(): Unit {
        for (literal in ["NaN", "01", "1.", "null", ""]) {
            let _ = @AssertThrows[IllegalArgumentException](JsonNumberLiteralValue(literal))
        }
    }

    @TestCase
    func serializeEmptyString(): Unit {
        let empty = JsonStringValue("")
        @Expect(empty.toString(), "\"\"")
    }

    @TestCase
    func serializePlainString(): Unit {
        let hello = JsonStringValue("hello")
        @Expect(hello.toString(), "\"hello\"")
    }

    @TestCase
    func serializeStringWithQuote(): Unit {
        let quoted = JsonStringValue("a\"b")
        @Expect(quoted.toString(), "\"a\\\"b\"")
    }

    @TestCase
    func serializeStringWithBackslash(): Unit {
        let backslash = JsonStringValue("a\\b")
        @Expect(backslash.toString(), "\"a\\\\b\"")
    }

    @TestCase
    func serializeStringWithNewline(): Unit {
        let newline = JsonStringValue("a\nb")
        @Expect(newline.toString(), "\"a\\nb\"")
    }

    @TestCase
    func serializeStringWithTab(): Unit {
        let tab = JsonStringValue("a\tb")
        @Expect(tab.toString(), "\"a\\tb\"")
    }

    @TestCase
    func serializeStringWithBackspace(): Unit {
        let backspace = JsonStringValue("a\bb")
        @Expect(backspace.toString(), "\"a\\bb\"")
    }

    @TestCase
    func serializeStringWithFormFeed(): Unit {
        let formFeed = JsonStringValue("a\fb")
        @Expect(formFeed.toString(), "\"a\\fb\"")
    }

    @TestCase
    func serializeStringWithCarriageReturn(): Unit {
        let cr = JsonStringValue("a\rb")
        @Expect(cr.toString(), "\"a\\rb\"")
    }

    @TestCase
    func serializeStringWithAllSpecialChars(): Unit {
        let special = JsonStringValue("\"\\\b\f\n\r\t")
        @Expect(special.toString(), "\"\\\"\\\\\\b\\f\\n\\r\\t\"")
    }

    @TestCase
    func serializeStringWithUnicode(): Unit {
        let chinese = JsonStringValue("你好")
        @Expect(chinese.toString(), "\"你好\"")

        let mixed = JsonStringValue("A中")
        @Expect(mixed.toString(), "\"A中\"")
    }

    @TestCase
    func serializeEmptyArray(): Unit {
        let emptyArr = JsonArray()
        @Expect(emptyArr.toString(), "[]")
        @Expect(emptyArr.toPrettyString(), "[]")
    }

    @TestCase
    func serializeSingleElementArray(): Unit {
        let arr = JsonArray().add(JsonIntValue(1))
        @Expect(arr.toString(), "[1]")
    }

    @TestCase
    func serializeMultipleElementArray(): Unit {
        let arr = JsonArray().add(JsonIntValue(1)).add(JsonIntValue(2)).add(JsonIntValue(3))
        @Expect(arr.toString(), "[1,2,3]")
    }

    @TestCase
    func serializeMixedTypeArray(): Unit {
        let arr = JsonArray()
            .add(JsonNullValue())
            .add(JsonBoolValue(true))
            .add(JsonIntValue(1))
            .add(JsonStringValue("a"))
            .add(JsonArray())
        @Expect(arr.toString(), "[null,true,1,\"a\",[]]")
    }

    @TestCase
    func serializeNestedArray(): Unit {
        let inner = JsonArray().add(JsonIntValue(1)).add(JsonIntValue(2))
        let outer = JsonArray().add(inner).add(JsonIntValue(3))
        @Expect(outer.toString(), "[[1,2],3]")
    }

    @TestCase
    func serializeEmptyObject(): Unit {
        let emptyObj = JsonObject()
        @Expect(emptyObj.toString(), "{}")
        @Expect(emptyObj.toPrettyString(), "{}")
    }

    @TestCase
    func serializeSingleFieldObject(): Unit {
        let obj = JsonObject()
        obj.put("a", JsonIntValue(1))
        @Expect(obj.toString(), "{\"a\":1}")
    }

    @TestCase
    func serializeMultipleFieldObject(): Unit {
        let obj = JsonObject()
        obj.put("a", JsonIntValue(1))
        obj.put("b", JsonIntValue(2))
        obj.put("c", JsonIntValue(3))
        // Note: HashMap doesn't preserve order, so we just check structure
        let output = obj.toString()
        @Expect(output.startsWith("{"))
        @Expect(output.endsWith("}"))
        @Expect(output.contains("\"a\":1"))
        @Expect(output.contains("\"b\":2"))
        @Expect(output.contains("\"c\":3"))
    }

    @TestCase
    func serializeNestedObject(): Unit {
        let inner = JsonObject()
        inner.put("b", JsonIntValue(2))
        let outer = JsonObject()
        outer.put("a", inner)
        @Expect(outer.toString(), "{\"a\":{\"b\":2}}")
    }

    @TestCase
    func serializeObjectWithSpecialKey(): Unit {
        let obj = JsonObject()
        obj.put("a\"b", JsonIntValue(1))
        @Expect(obj.toString(), "{\"a\\\"b\":1}")
    }

    @TestCase
    func serializeObjectWithChineseKey(): Unit {
        let obj = JsonObject()
        obj.put("名字", JsonIntValue(1))
        @Expect(obj.toString(), "{\"名字\":1}")
    }

    @TestCase
    func roundtripNull(): Unit {
        let input = "null"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripTrue(): Unit {
        let input = "true"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripFalse(): Unit {
        let input = "false"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripInteger(): Unit {
        let input = "123"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripFloat(): Unit {
        let input = "1.5"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripString(): Unit {
        let input = "\"hello\""
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripEmptyArray(): Unit {
        let input = "[]"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripArray(): Unit {
        let input = "[1,2,3]"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripEmptyObject(): Unit {
        let input = "{}"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripSimpleObject(): Unit {
        let input = "{\"a\":1}"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripNestedStructure(): Unit {
        let input = "{\"arr\":[1,2],\"obj\":{\"x\":3}}"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(jsonRoundtripSemanticsEqual(input, output))
    }

    @TestCase
    func roundtripComplexStructure(): Unit {
        let input = "{\"null\":null,\"bool\":true,\"int\":123,\"float\":1.5,\"str\":\"hello\",\"arr\":[1,\"a\"],\"obj\":{\"x\":1}}"
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(jsonRoundtripSemanticsEqual(input, output))
    }

    @TestCase
    func roundtripEscapedString(): Unit {
        let input = "\"a\\\"b\\\\c\\n\\t\""
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(output, input)
    }

    @TestCase
    func roundtripUnicodeString(): Unit {
        let input = "\"\\u0041\\u4e2d\""
        let parsed = JsonNode.parse(input)
        let output = parsed.toString()
        @Expect(parsed.asString(), "A中")
        @Expect(jsonRoundtripSemanticsEqual(input, output))
    }

    @TestCase
    func toPrettyStringNull(): Unit {
        let nullValue = JsonNullValue()
        @Expect(nullValue.toPrettyString("  "), "null")
    }

    @TestCase
    func toPrettyStringArray(): Unit {
        let arr = JsonArray().add(JsonIntValue(1)).add(JsonIntValue(2))
        let pretty = arr.toPrettyString("  ")
        @Expect(pretty.contains("\n"))
        @Expect(pretty.contains("  1"))
        @Expect(pretty.contains("  2"))
    }

    @TestCase
    func toPrettyStringObject(): Unit {
        let obj = JsonObject()
        obj.put("a", JsonIntValue(1))
        obj.put("b", JsonIntValue(2))
        let pretty = obj.toPrettyString("  ")
        @Expect(pretty.contains("\n"))
        @Expect(pretty.contains("  \"a\""))
        @Expect(pretty.contains("  \"b\""))
    }
}

@Test
class JsonValueConversionTest {
    @TestCase
    func asNullConversion(): Unit {
        let value = JsonNode.parse("null")
        @Expect(value.kind(), JsonKind.Null)
        @Expect(value.isNull)
    }

    @TestCase
    func nullCheckRejectsNonNull(): Unit {
        let value = JsonNode.parse("true")
        @Expect(value.kind(), JsonKind.Boolean)
        @Expect(!value.isNull)
    }

    @TestCase
    func asBoolConversion(): Unit {
        let trueValue = JsonNode.parse("true").asBool()
        @Expect(trueValue, true)

        let falseValue = JsonNode.parse("false").asBool()
        @Expect(falseValue, false)
    }

    @TestCase
    func asBoolRejectsNonBool(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("null").asBool()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asIntConversion(): Unit {
        let intValue = JsonNode.parse("123").asInt64()
        @Expect(intValue, 123)
    }

    @TestCase
    func asIntRejectsNonInt(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("\"hello\"").asInt64()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asFloatFromInt(): Unit {
        // Int can be converted to Float
        let floatValue = JsonNode.parse("123").asFloat64()
        @Expect(floatValue, 123.0)
    }

    @TestCase
    func asFloatFromFloat(): Unit {
        let floatValue = JsonNode.parse("1.5").asFloat64()
        @Expect(floatValue, 1.5)
    }

    @TestCase
    func asFloatRejectsNonNumeric(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("true").asFloat64()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asStringConversion(): Unit {
        let stringValue = JsonNode.parse("\"hello\"").asString()
        @Expect(stringValue, "hello")
    }

    @TestCase
    func asStringRejectsNonString(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("123").asString()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asArrayConversion(): Unit {
        let arrValue = JsonNode.parse("[1,2,3]").asArray()
        @Expect(arrValue.size(), 3)
    }

    @TestCase
    func asArrayRejectsNonArray(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("{}").asArray()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asObjectConversion(): Unit {
        let objValue = JsonNode.parse("{\"a\":1}").asObject()
        @Expect(objValue.contains("a"))
    }

    @TestCase
    func asObjectRejectsNonObject(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("[1]").asObject()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    @TestCase
    func asNumberLiteralFromInt(): Unit {
        let literal = JsonNode.parse("123").asNumberText()
        @Expect(literal, "123")
    }

    @TestCase
    func asNumberLiteralFromFloat(): Unit {
        let literal = JsonNode.parse("1.5").asNumberText()
        @Expect(literal, "1.5")
    }

    @TestCase
    func asNumberLiteralFromOverflow(): Unit {
        // Overflow number should already be NumberLiteral
        let literal = JsonNode.parse("9223372036854775808").asNumberText()
        @Expect(literal, "9223372036854775808")
    }

    @TestCase
    func asNumberLiteralRejectsNonNumeric(): Unit {
        var caughtException = false
        try {
            let _ = JsonNode.parse("true").asNumberText()
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }
}
