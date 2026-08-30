package yjson

import std.unittest.*
import std.unittest.testmacro.*

// Helper function to check if parsing succeeds
func canParse(text: String): Bool {
    try {
        let _ = YJson.parse(text)
        return true
    } catch (_: Exception) {
        return false
    }
}

// Helper function to check if parsing throws JsonException
func throwsJsonException(text: String): Bool {
    try {
        let _ = YJson.parse(text)
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

// Helper function to parse and get value
func parseValue(text: String): JsonNode {
    YJson.parse(text)
}

@Test
class JsonNullComplianceTest {
    @TestCase
    func parseValidNull(): Unit {
        let value = parseValue("null")
        @Expect(value.kind(), JsNull)
        @Expect(value.asNull().toString(), "null")
    }

    @TestCase
    func parseNullWithLeadingSpaces(): Unit {
        let value = parseValue("  null")
        @Expect(value.kind(), JsNull)
    }

    @TestCase
    func parseNullWithTrailingSpaces(): Unit {
        let value = parseValue("null  ")
        @Expect(value.kind(), JsNull)
    }

    @TestCase
    func parseNullWithNewlines(): Unit {
        let value = parseValue("\nnull\t")
        @Expect(value.kind(), JsNull)
    }

    @TestCase
    func parseNullInObject(): Unit {
        let obj = parseValue("{\"a\":null}").asObject()
        @Expect(obj.contains("a"))
        @Expect(obj.get("a").getOrThrow().kind(), JsNull)
    }

    @TestCase
    func parseNullInArray(): Unit {
        let arr = parseValue("[null, 1, null]").asArray()
        @Expect(arr.size(), 3)
        @Expect(arr[0].kind(), JsNull)
        @Expect(arr[2].kind(), JsNull)
    }

    @TestCase
    func rejectNullWithInvalidCaseNull(): Unit {
        @Expect(throwsJsonException("Null"))
    }

    @TestCase
    func rejectNullWithInvalidCaseNULL(): Unit {
        @Expect(throwsJsonException("NULL"))
    }

    @TestCase
    func rejectNullWithInvalidCaseNul(): Unit {
        @Expect(throwsJsonException("nul"))
    }

    @TestCase
    func rejectNullWithExtraChar(): Unit {
        @Expect(throwsJsonException("nullx"))
    }
}

@Test
class JsonBooleanComplianceTest {
    @TestCase
    func parseValidTrue(): Unit {
        let value = parseValue("true").asBool()
        @Expect(value.value, true)
        @Expect(value.toString(), "true")
    }

    @TestCase
    func parseValidFalse(): Unit {
        let value = parseValue("false").asBool()
        @Expect(value.value, false)
        @Expect(value.toString(), "false")
    }

    @TestCase
    func parseTrueWithSpaces(): Unit {
        let value = parseValue("  true  ").asBool()
        @Expect(value.value, true)
    }

    @TestCase
    func parseFalseWithSpaces(): Unit {
        let value = parseValue("\tfalse\n").asBool()
        @Expect(value.value, false)
    }

    @TestCase
    func rejectTrueInvalidCaseTrue(): Unit {
        @Expect(throwsJsonException("True"))
    }

    @TestCase
    func rejectTrueInvalidCaseTRUE(): Unit {
        @Expect(throwsJsonException("TRUE"))
    }

    @TestCase
    func rejectTrueInvalidCaseTru(): Unit {
        @Expect(throwsJsonException("tru"))
    }

    @TestCase
    func rejectFalseInvalidCaseFalse(): Unit {
        @Expect(throwsJsonException("False"))
    }

    @TestCase
    func rejectFalseInvalidCaseFALSE(): Unit {
        @Expect(throwsJsonException("FALSE"))
    }

    @TestCase
    func rejectFalseInvalidCaseFals(): Unit {
        @Expect(throwsJsonException("fals"))
    }
}

@Test
class JsonNumberComplianceTest {
    @TestCase
    func parsePositiveIntegers(): Unit {
        let v0 = parseValue("0").asInt()
        @Expect(v0.value, 0)

        let v123 = parseValue("123").asInt()
        @Expect(v123.value, 123)

        let vMax = parseValue("9223372036854775807").asInt()
        @Expect(vMax.value, 9223372036854775807)
    }

    @TestCase
    func parseNegativeIntegers(): Unit {
        let vNeg0 = parseValue("-0").asInt()
        @Expect(vNeg0.value, 0)

        let vNeg123 = parseValue("-123").asInt()
        @Expect(vNeg123.value, -123)

        let vMin = parseValue("-9223372036854775808").asInt()
        @Expect(vMin.value, -9223372036854775808)
    }

    @TestCase
    func parseIntOverflowAsLiteral(): Unit {
        // Int64 max + 1 should be parsed as NumberLiteral
        let overflow = parseValue("9223372036854775808")
        @Expect(overflow.kind(), JsNumberLiteral)
        @Expect(overflow.asNumberLiteral().literal, "9223372036854775808")
    }

    @TestCase
    func parseNegativeIntOverflowAsLiteral(): Unit {
        // Int64 min - 1 should be parsed as NumberLiteral
        let overflow = parseValue("-9223372036854775809")
        @Expect(overflow.kind(), JsNumberLiteral)
        @Expect(overflow.asNumberLiteral().literal, "-9223372036854775809")
    }

    @TestCase
    func parseBasicFloats(): Unit {
        let v1_5 = parseValue("1.5").asFloat()
        @Expect(v1_5.value, 1.5)

        let v0_0 = parseValue("0.0").asFloat()
        @Expect(v0_0.value, 0.0)

        let vNeg = parseValue("-12.34").asFloat()
        @Expect(vNeg.value, -12.34)
    }

    @TestCase
    func parseFloatPrecision(): Unit {
        let v = parseValue("0.123456789012345").asFloat()
        @Expect(v.value, 0.123456789012345)
    }

    @TestCase
    func parseExponentFormat(): Unit {
        let v1e10 = parseValue("1e10").asFloat()
        @Expect(v1e10.value, 1e10)

        let v1E_5 = parseValue("1E-5").asFloat()
        @Expect(v1E_5.value, 1e-5)

        let v1_2e3 = parseValue("1.2e+3").asFloat()
        @Expect(v1_2e3.value, 1200.0)
    }

    @TestCase
    func rejectNumberWithLeadingZero(): Unit {
        @Expect(throwsJsonException("01"))
        @Expect(throwsJsonException("-01"))
    }

    @TestCase
    func acceptNumberWithZeroOnly(): Unit {
        @Expect(canParse("0"))
        @Expect(canParse("0.1"))
        @Expect(canParse("0e1"))
    }

    @TestCase
    func rejectNumberMissingFractionalDigit(): Unit {
        @Expect(throwsJsonException("1."))
        @Expect(throwsJsonException("1.e2"))
    }

    @TestCase
    func rejectNumberMissingExponentDigit(): Unit {
        @Expect(throwsJsonException("1e"))
        @Expect(throwsJsonException("1e+"))
        @Expect(throwsJsonException("1e-"))
    }

    @TestCase
    func rejectNumberDoubleMinus(): Unit {
        @Expect(throwsJsonException("--1"))
    }

    @TestCase
    func rejectNumberPlusSign(): Unit {
        @Expect(throwsJsonException("+1"))
    }

    @TestCase
    func rejectNumberMinusOnly(): Unit {
        @Expect(throwsJsonException("-."))
    }
}

@Test
class JsonStringComplianceTest {
    @TestCase
    func parseEmptyString(): Unit {
        let value = parseValue("\"\"").asString()
        @Expect(value.value, "")
        @Expect(value.toString(), "\"\"")
    }

    @TestCase
    func parsePlainAsciiString(): Unit {
        let value = parseValue("\"hello\"").asString()
        @Expect(value.value, "hello")
    }

    @TestCase
    func parseStringWithEscapeQuote(): Unit {
        let value = parseValue("\"a\\\"b\"").asString()
        @Expect(value.value, "a\"b")
    }

    @TestCase
    func parseStringWithEscapeBackslash(): Unit {
        let value = parseValue("\"a\\\\b\"").asString()
        @Expect(value.value, "a\\b")
    }

    @TestCase
    func parseStringWithEscapeBackspace(): Unit {
        let value = parseValue("\"\\b\"").asString()
        @Expect(value.value, "\b")
    }

    @TestCase
    func parseStringWithEscapeFormFeed(): Unit {
        let value = parseValue("\"\\f\"").asString()
        @Expect(value.value, "\f")
    }

    @TestCase
    func parseStringWithEscapeNewline(): Unit {
        let value = parseValue("\"\\n\"").asString()
        @Expect(value.value, "\n")
    }

    @TestCase
    func parseStringWithEscapeCarriageReturn(): Unit {
        let value = parseValue("\"\\r\"").asString()
        @Expect(value.value, "\r")
    }

    @TestCase
    func parseStringWithEscapeTab(): Unit {
        let value = parseValue("\"\\t\"").asString()
        @Expect(value.value, "\t")
    }

    @TestCase
    func parseStringWithAllEscapes(): Unit {
        let value = parseValue("\"\\\"\\\\\\b\\f\\n\\r\\t\"").asString()
        @Expect(value.value, "\"\\\b\f\n\r\t")
    }

    @TestCase
    func parseStringWithUnicodeBasic(): Unit {
        let value = parseValue("\"\\u0041\\u4e2d\"").asString()
        @Expect(value.value, "A中")
    }

    @TestCase
    func parseStringWithUnicodeFourDigit(): Unit {
        let value = parseValue("\"\\u0000\"").asString()
        @Expect(value.value.size, 1)
    }

    @TestCase
    func rejectStringWithUnescapedControlChar(): Unit {
        // Control characters (U+0001 through U+001F) must be escaped
        @Expect(throwsJsonException("{\"a\":\"\u{0001}\"}"))
    }

    @TestCase
    func acceptStringWithEscapedControlChar(): Unit {
        let value = parseValue("\"\\u0001\"").asString()
        @Expect(value.value.size, 1)
    }

    @TestCase
    func rejectStringUnterminated(): Unit {
        @Expect(throwsJsonException("\"hello"))
        @Expect(throwsJsonException("\"hello\\\""))
    }

    @TestCase
    func rejectStringInvalidEscapeX(): Unit {
        @Expect(throwsJsonException("\"\\x\""))
    }

    @TestCase
    func rejectStringInvalidEscapeQ(): Unit {
        @Expect(throwsJsonException("\"\\q\""))
    }

    @TestCase
    func rejectStringInvalidUnicode(): Unit {
        @Expect(throwsJsonException("\"\\u00\""))
        @Expect(throwsJsonException("\"\\u0\""))
        @Expect(throwsJsonException("\"\\u\""))
    }

    @TestCase
    func parseStringWithChinese(): Unit {
        let value = parseValue("\"你好世界\"").asString()
        @Expect(value.value, "你好世界")
    }

    @TestCase
    func parseStringWithEmoji(): Unit {
        let value = parseValue("\"🎉\"").asString()
        @Expect(value.value, "🎉")
    }
}

@Test
class JsonArrayComplianceTest {
    @TestCase
    func parseEmptyArray(): Unit {
        let arr = parseValue("[]").asArray()
        @Expect(arr.size(), 0)
        @Expect(arr.toString(), "[]")
    }

    @TestCase
    func parseSingleElementArray(): Unit {
        let arr = parseValue("[1]").asArray()
        @Expect(arr.size(), 1)
        @Expect(arr[0].asInt().value, 1)
    }

    @TestCase
    func parseMultipleElementArray(): Unit {
        let arr = parseValue("[1, 2, 3]").asArray()
        @Expect(arr.size(), 3)
        @Expect(arr[0].asInt().value, 1)
        @Expect(arr[1].asInt().value, 2)
        @Expect(arr[2].asInt().value, 3)
    }

    @TestCase
    func parseMixedTypeArray(): Unit {
        let arr = parseValue("[null, true, 1, \"a\", []]").asArray()
        @Expect(arr.size(), 5)
        @Expect(arr[0].kind(), JsNull)
        @Expect(arr[1].kind(), JsBool)
        @Expect(arr[2].kind(), JsInt)
        @Expect(arr[3].kind(), JsString)
        @Expect(arr[4].kind(), JsArray)
    }

    @TestCase
    func parseNestedArray(): Unit {
        let arr = parseValue("[[1, 2], [3, 4]]").asArray()
        @Expect(arr.size(), 2)
        @Expect(arr[0].asArray().size(), 2)
        @Expect(arr[0].asArray()[0].asInt().value, 1)
        @Expect(arr[1].asArray()[1].asInt().value, 4)
    }

    @TestCase
    func parseDeeplyNestedArray(): Unit {
        let arr = parseValue("[[[[1]]]]").asArray()
        @Expect(arr[0].asArray()[0].asArray()[0].asArray()[0].asInt().value, 1)
    }

    @TestCase
    func parseArrayWithSpaces(): Unit {
        let arr = parseValue("[ 1 , 2 , 3 ]").asArray()
        @Expect(arr.size(), 3)
    }

    @TestCase
    func rejectArrayMissingComma(): Unit {
        @Expect(throwsJsonException("[1 2]"))
    }

    @TestCase
    func rejectArrayTrailingComma(): Unit {
        @Expect(throwsJsonException("[1,]"))
        @Expect(throwsJsonException("[1, 2,]"))
    }

    @TestCase
    func rejectArrayExtraComma(): Unit {
        @Expect(throwsJsonException("[1,,2]"))
    }

    @TestCase
    func rejectArrayUnterminated(): Unit {
        @Expect(throwsJsonException("[1, 2"))
        @Expect(throwsJsonException("["))
    }

    @TestCase
    func rejectArrayEmptyComma(): Unit {
        @Expect(throwsJsonException("[,]"))
    }
}

@Test
class JsonObjectComplianceTest {
    @TestCase
    func parseEmptyObject(): Unit {
        let obj = parseValue("{}").asObject()
        @Expect(obj.size(), 0)
        @Expect(obj.toString(), "{}")
    }

    @TestCase
    func parseSingleFieldObject(): Unit {
        let obj = parseValue("{\"a\":1}").asObject()
        @Expect(obj.size(), 1)
        @Expect(obj.contains("a"))
        @Expect(obj.get("a").getOrThrow().asInt().value, 1)
    }

    @TestCase
    func parseMultipleFieldObject(): Unit {
        let obj = parseValue("{\"a\":1, \"b\":2, \"c\":3}").asObject()
        @Expect(obj.size(), 3)
        @Expect(obj.get("a").getOrThrow().asInt().value, 1)
        @Expect(obj.get("b").getOrThrow().asInt().value, 2)
        @Expect(obj.get("c").getOrThrow().asInt().value, 3)
    }

    @TestCase
    func parseNestedObject(): Unit {
        let obj = parseValue("{\"a\":{\"b\":2}}").asObject()
        @Expect(obj.get("a").getOrThrow().asObject().get("b").getOrThrow().asInt().value, 2)
    }

    @TestCase
    func parseObjectWithDifferentValueTypes(): Unit {
        let obj = parseValue("{\"null\":null, \"bool\":true, \"int\":1, \"str\":\"a\", \"arr\":[], \"obj\":{}}").asObject()
        @Expect(obj.get("null").getOrThrow().kind(), JsNull)
        @Expect(obj.get("bool").getOrThrow().kind(), JsBool)
        @Expect(obj.get("int").getOrThrow().kind(), JsInt)
        @Expect(obj.get("str").getOrThrow().kind(), JsString)
        @Expect(obj.get("arr").getOrThrow().kind(), JsArray)
        @Expect(obj.get("obj").getOrThrow().kind(), JsObject)
    }

    @TestCase
    func parseObjectWithSpaces(): Unit {
        let obj = parseValue("{ \"a\" : 1 , \"b\" : 2 }").asObject()
        @Expect(obj.size(), 2)
    }

    @TestCase
    func parseObjectDuplicateKeyCurrentImplementationLastWins(): Unit {
        // 当前实现保留最后一个值；这里验证实现行为，不把它当作 JSON 规范契约
        let obj = parseValue("{\"a\":1, \"a\":2}").asObject()
        @Expect(obj.get("a").getOrThrow().asInt().value, 2)
    }

    @TestCase
    func parseObjectNonAsciiKey(): Unit {
        let obj = parseValue("{\"名字\":1}").asObject()
        @Expect(obj.contains("名字"))
        @Expect(obj.get("名字").getOrThrow().asInt().value, 1)
    }

    @TestCase
    func rejectObjectMissingColon(): Unit {
        @Expect(throwsJsonException("{\"a\"1}"))
    }

    @TestCase
    func rejectObjectMissingComma(): Unit {
        @Expect(throwsJsonException("{\"a\":1 \"b\":2}"))
    }

    @TestCase
    func rejectObjectTrailingComma(): Unit {
        @Expect(throwsJsonException("{\"a\":1,}"))
        @Expect(throwsJsonException("{\"a\":1, \"b\":2,}"))
    }

    @TestCase
    func rejectObjectUnquotedKey(): Unit {
        @Expect(throwsJsonException("{a:1}"))
    }

    @TestCase
    func rejectObjectSingleQuotedKey(): Unit {
        @Expect(throwsJsonException("{'a':1}"))
    }

    @TestCase
    func rejectObjectUnterminated(): Unit {
        @Expect(throwsJsonException("{\"a\":1"))
        @Expect(throwsJsonException("{\"a\":"))
        @Expect(throwsJsonException("{"))
    }

    @TestCase
    func rejectObjectEmptyValue(): Unit {
        @Expect(throwsJsonException("{\"a\":}"))
    }

    @TestCase
    func rejectObjectEmptyKey(): Unit {
        @Expect(throwsJsonException("{:1}"))
    }
}

@Test
class JsonErrorPathTest {
    @TestCase
    func rejectEmptyInput(): Unit {
        @Expect(throwsJsonException(""))
    }

    @TestCase
    func rejectOnlyWhitespace(): Unit {
        @Expect(throwsJsonException("  "))
        @Expect(throwsJsonException("\n\t"))
    }

    @TestCase
    func rejectInvalidTokens(): Unit {
        @Expect(throwsJsonException("@"))
        @Expect(throwsJsonException("#"))
        @Expect(throwsJsonException("!"))
        @Expect(throwsJsonException("<"))
        @Expect(throwsJsonException(">"))
    }

    @TestCase
    func rejectMultipleValues(): Unit {
        // Parser should reject trailing input after first value
        @Expect(throwsJsonException("123 456"))
        @Expect(throwsJsonException("null true"))
    }

    @TestCase
    func rejectComment(): Unit {
        // JSON does not support comments
        @Expect(throwsJsonException("/* comment */"))
        @Expect(throwsJsonException("// comment"))
    }

    @TestCase
    func rejectSingleQuotedString(): Unit {
        @Expect(throwsJsonException("'hello'"))
    }

    @TestCase
    func rejectIncompleteLiteral(): Unit {
        @Expect(throwsJsonException("nul"))
        @Expect(throwsJsonException("tru"))
        @Expect(throwsJsonException("fals"))
    }
}
