package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 数字边界值测试 - P1 级别
 *
 * 测试内容：
 * 1. 整数边界：UInt64 最大值、溢出值
 * 2. 浮点精度：15-17 位精度边界
 * 3. 科学计数法：极大/极小指数、溢出/下溢
 */
@Test
class NumberBoundaryTest {

    // Helper function to check if parsing throws JsonException
    func throwsJsonException(text: String): Bool {
        try {
            let _ = JsonNode.parse(text)
            return false
        } catch (_: JsonException) {
            return true
        } catch (_: Exception) {
            return false
        }
    }

    // Helper to parse value
    func parseValue(text: String): JsonNode {
        JsonNode.parse(text)
    }

    // ==================== 整数边界测试 ====================

    @TestCase
    func parseUInt64MaxValue(): Unit {
        // UInt64 最大值: 18446744073709551615 (2^64 - 1)
        // 超过 Int64 范围，应解析为 NumberLiteral
        let value = parseValue("18446744073709551615")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "18446744073709551615")
    }

    @TestCase
    func parseUInt64MaxPlusOneAsLiteral(): Unit {
        // UInt64 最大值 + 1: 18446744073709551616
        // 完全超出范围，应解析为 NumberLiteral
        let value = parseValue("18446744073709551616")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "18446744073709551616")
    }

    @TestCase
    func parseInt64MinMinusOneAsLiteral(): Unit {
        // Int64 最小值 - 1: -9223372036854775809
        // 超出 Int64 范围，应解析为 NumberLiteral
        let value = parseValue("-9223372036854775809")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "-9223372036854775809")
    }

    @TestCase
    func parseInt64BoundaryNearbyValues(): Unit {
        // Int64 最大值附近测试
        let maxPlus1 = parseValue("9223372036854775808")  // Int64 max + 1
        @Expect(maxPlus1.kind(), JsonKind.Number)

        let maxMinus1 = parseValue("9223372036854775806")  // Int64 max - 1
        @Expect(maxMinus1.kind(), JsonKind.Number)
        @Expect(maxMinus1.asInt64(), 9223372036854775806)

        // Int64 最小值附近测试
        let minMinus1 = parseValue("-9223372036854775809")  // Int64 min - 1
        @Expect(minMinus1.kind(), JsonKind.Number)

        let minPlus1 = parseValue("-9223372036854775807")  // Int64 min + 1
        @Expect(minPlus1.kind(), JsonKind.Number)
        @Expect(minPlus1.asInt64(), -9223372036854775807)

        // 正边界值测试
        let exactlyMax = parseValue("9223372036854775807")  // Int64 exact max
        @Expect(exactlyMax.kind(), JsonKind.Number)
        @Expect(exactlyMax.asInt64(), 9223372036854775807)

        let exactlyMin = parseValue("-9223372036854775808")  // Int64 exact min
        @Expect(exactlyMin.kind(), JsonKind.Number)
        @Expect(exactlyMin.asInt64(), -9223372036854775808)
    }

    @TestCase
    func parseVeryLargeNumberAsLiteral(): Unit {
        // 测试非常大的数字
        let largeValue = parseValue("999999999999999999999999999999999")
        @Expect(largeValue.kind(), JsonKind.Number)
        @Expect(largeValue.asNumberText(), "999999999999999999999999999999999")

        // 测试带小数点的超大数字
        let largeFloat = parseValue("999999999999999999999999999999999.999")
        @Expect(largeFloat.kind(), JsonKind.Number)
    }

    // ==================== 浮点精度边界测试 ====================

    @TestCase
    func parseFloatPrecision15Digits(): Unit {
        // 15 位小数精度边界（IEEE 754 double 精度）
        let v1 = parseValue("0.123456789012345").asFloat64()
        @Expect(v1, 0.123456789012345)

        // 15 位精度应该能正确保持
        let v2 = parseValue("1.234567890123456").asFloat64()
        @Expect(v2, 1.234567890123456)

        // 边界值测试
        let v3 = parseValue("3.141592653589793").asFloat64()
        @Expect(v3, 3.141592653589793)
    }

    @TestCase
    func parseFloatPrecision17Digits(): Unit {
        // 17 位小数精度边界（超出 IEEE 754 精度）
        let raw1 = parseValue("0.12345678901234567")
        @Expect(raw1.kind(), JsonKind.Number)
        let v1 = raw1.asFloat64()
        // 17 位可能会有精度损失，但应该接受
        @Expect(!v1.isNaN())

        let raw2 = parseValue("1.234567890123456789")
        @Expect(raw2.kind(), JsonKind.Number)
        let v2 = raw2.asFloat64()
        @Expect(!v2.isNaN())
    }

    @TestCase
    func parseFloatVeryClose(): Unit {
        // 测试非常接近的浮点数
        let v1 = parseValue("1.000000000000001").asFloat64()
        @Expect(v1 > 1.0)
        @Expect(v1 < 1.0001)

        let v2 = parseValue("0.999999999999999").asFloat64()
        @Expect(v2 < 1.0)
        @Expect(v2 > 0.9999)

        // 测试非常小的差异
        let raw3 = parseValue("1.0000000000000001")
        @Expect(raw3.kind(), JsonKind.Number)
        let v3 = raw3.asFloat64()
        @Expect(!v3.isNaN())
    }

    @TestCase
    func parseFloatRoundingBoundary(): Unit {
        // 测试浮点数舍入边界
        let v1 = parseValue("0.5").asFloat64()
        @Expect(v1, 0.5)

        let v2 = parseValue("0.49999999999999999").asFloat64()
        // 使用 <= 比较，因为 IEEE 754 舍入可能导致值接近 0.5
        @Expect(v2 <= 0.5)

        // 测试边界附近的舍入
        let v3 = parseValue("0.50000000000000001").asFloat64()
        // 使用 >= 比较
        @Expect(v3 >= 0.5)

        // 测试负数舍入边界
        let v4 = parseValue("-0.5").asFloat64()
        @Expect(v4, -0.5)

        let v5 = parseValue("-0.49999999999999999").asFloat64()
        // 使用 >= 比较（负数的"大于"意味着更接近零）
        @Expect(v5 >= -0.5)
    }

    @TestCase
    func parseFloatZeroBoundary(): Unit {
        // 测试各种零的表示
        let positiveZero = parseValue("0.0").asFloat64()
        @Expect(positiveZero, 0.0)

        let negativeZero = parseValue("-0.0").asFloat64()
        @Expect(negativeZero, -0.0)  // -0.0 在 IEEE 754 中是合法的
        // 符号位必须保留:1/-0.0 = -Inf,1/+0.0 = +Inf
        @Expect(1.0 / positiveZero, Float64.Inf)
        @Expect(1.0 / negativeZero, -Float64.Inf)

        let verySmallPositive = parseValue("0.0000000000000001").asFloat64()
        @Expect(verySmallPositive > 0.0)

        let verySmallNegative = parseValue("-0.0000000000000001").asFloat64()
        @Expect(verySmallNegative < 0.0)
    }

    // ==================== 科学计数法边界测试 ====================

    @TestCase
    func parseExponentLarge308(): Unit {
        // 测试极大指数 (接近 Float64 最大值)
        let raw1 = parseValue("1e308")
        @Expect(raw1.kind(), JsonKind.Number)
        let v1 = raw1.asFloat64()
        @Expect(v1, 1e308)

        let raw2 = parseValue("1.5e308")
        @Expect(raw2.kind(), JsonKind.Number)
        let v2 = raw2.asFloat64()
        @Expect(v2, 1.5e308)

        // 接近最大值的边界
        let raw3 = parseValue("1.7e308")
        @Expect(raw3.kind(), JsonKind.Number)
        let v3 = raw3.asFloat64()
        @Expect(!v3.isNaN())
        @Expect(v3 < Float64.Inf)  // 应小于无穷大
    }

    @TestCase
    func parseExponentSmall308(): Unit {
        // 测试极小指数 (接近 Float64 最小正值)
        let raw1 = parseValue("1e-308")
        @Expect(raw1.kind(), JsonKind.Number)
        let v1 = raw1.asFloat64()
        @Expect(v1, 1e-308)

        let raw2 = parseValue("1e-323")
        @Expect(raw2.kind(), JsonKind.Number)
        let v2 = raw2.asFloat64()
        @Expect(!v2.isNaN())
        @Expect(v2 > 0.0)  // 应大于零

        // 极小值边界
        let raw3 = parseValue("1.5e-308")
        @Expect(raw3.kind(), JsonKind.Number)
        let v3 = raw3.asFloat64()
        @Expect(v3, 1.5e-308)
    }

    @TestCase
    func parseExponentOverflow309(): Unit {
        // parser 对指数语法保留原始字面量，asFloat() 再体现溢出行为
        let raw1 = parseValue("1e309")
        @Expect(raw1.kind(), JsonKind.Number)
        @Expect(raw1.asNumberText(), "1e309")
        @Expect(raw1.asFloat64().isInf())

        let raw2 = parseValue("1.8e308")
        @Expect(raw2.kind(), JsonKind.Number)
        @Expect(raw2.asNumberText(), "1.8e308")
        @Expect(raw2.asFloat64().isInf())

        let raw3 = parseValue("1e1000")
        @Expect(raw3.kind(), JsonKind.Number)
        @Expect(raw3.asNumberText(), "1e1000")
        @Expect(raw3.asFloat64().isInf())

        let raw4 = parseValue("9.9e999")
        @Expect(raw4.kind(), JsonKind.Number)
        @Expect(raw4.asNumberText(), "9.9e999")
        @Expect(raw4.asFloat64().isInf())
    }

    @TestCase
    func parseExponentUnderflow324(): Unit {
        // parser 保留原始字面量，asFloat() 再体现下溢后的数值
        let raw1 = parseValue("1e-324")
        @Expect(raw1.kind(), JsonKind.Number)
        @Expect(raw1.asNumberText(), "1e-324")
        @Expect(raw1.asFloat64(), 0.0)

        let raw2 = parseValue("1e-325")
        @Expect(raw2.kind(), JsonKind.Number)
        @Expect(raw2.asNumberText(), "1e-325")
        @Expect(raw2.asFloat64(), 0.0)

        let raw3 = parseValue("1e-1000")
        @Expect(raw3.kind(), JsonKind.Number)
        @Expect(raw3.asNumberText(), "1e-1000")
        @Expect(raw3.asFloat64(), 0.0)
    }

    @TestCase
    func parseExponentNegativeBoundary(): Unit {
        // 测试负指数边界
        let raw1 = parseValue("-1e308")
        @Expect(raw1.kind(), JsonKind.Number)
        let v1 = raw1.asFloat64()
        @Expect(v1, -1e308)

        let raw2 = parseValue("-1e-308")
        @Expect(raw2.kind(), JsonKind.Number)
        let v2 = raw2.asFloat64()
        @Expect(v2, -1e-308)

        let raw3 = parseValue("-1e309")
        @Expect(raw3.kind(), JsonKind.Number)
        @Expect(raw3.asNumberText(), "-1e309")
        @Expect(raw3.asFloat64().isInf())
        @Expect(raw3.asFloat64() < 0.0)

        let raw4 = parseValue("-1e-324")
        @Expect(raw4.kind(), JsonKind.Number)
        @Expect(raw4.asNumberText(), "-1e-324")
        @Expect(raw4.asFloat64(), 0.0)
    }

    @TestCase
    func parseExponentWithPlusSign(): Unit {
        // 测试指数中的正号
        let v1 = parseValue("1e+10").asFloat64()
        @Expect(v1, 1e10)

        let v2 = parseValue("1.5e+308").asFloat64()
        @Expect(v2, 1.5e308)
    }

    @TestCase
    func rejectExponentWithDoubleSign(): Unit {
        // 测试负指数后跟正号（无效格式）
        @Expect(throwsJsonException("1e-+10"))  // 应拒绝
    }

    @TestCase
    func parseExponentMixedFormats(): Unit {
        // 测试各种指数格式组合
        let v1 = parseValue("1.23e45").asFloat64()
        @Expect(v1, 1.23e45)

        let v2 = parseValue("1.23E45").asFloat64()  // 大写 E
        @Expect(v2, 1.23e45)

        let v3 = parseValue("1.23e+45").asFloat64()
        @Expect(v3, 1.23e45)

        let v4 = parseValue("1.23e-45").asFloat64()
        @Expect(v4, 1.23e-45)

        // 测试整数指数
        let v5 = parseValue("123e10").asFloat64()
        @Expect(v5, 123e10)
    }

    @TestCase
    func parseBoundaryNumberInArray(): Unit {
        // 测试边界值数字在数组中
        let arr = parseValue("[9223372036854775807, 9223372036854775808, -9223372036854775808, -9223372036854775809]").asArray()
        @Expect(arr.size(), 4)
        @Expect(arr[0].kind(), JsonKind.Number)
        @Expect(arr[1].kind(), JsonKind.Number)
        @Expect(arr[2].kind(), JsonKind.Number)
        @Expect(arr[3].kind(), JsonKind.Number)
    }

    @TestCase
    func parseBoundaryNumberInObject(): Unit {
        // 测试边界值数字在对象中
        let obj = parseValue("{\"max\":9223372036854775807,\"overflow\":9223372036854775808,\"min\":-9223372036854775808,\"underflow\":-9223372036854775809}").asObject()
        @Expect(obj.get("max").getOrThrow().kind(), JsonKind.Number)
        @Expect(obj.get("overflow").getOrThrow().kind(), JsonKind.Number)
        @Expect(obj.get("min").getOrThrow().kind(), JsonKind.Number)
        @Expect(obj.get("underflow").getOrThrow().kind(), JsonKind.Number)
    }
}

/**
 * Unicode 边界值测试 - P1 级别
 *
 * 测试内容：
 * 1. BOM 处理：UTF-8 BOM 在不同位置
 * 2. Unicode 非字符：U+FFFF, U+FFFE, U+FFFD 等
 * 3. 无效 UTF-8 字节序列
 */
@Test
class UnicodeBoundaryTest {

    func throwsJsonException(text: String): Bool {
        try {
            let _ = JsonNode.parse(text)
            return false
        } catch (_: JsonException) {
            return true
        } catch (_: Exception) {
            return false
        }
    }

    func parseValue(text: String): JsonNode {
        JsonNode.parse(text)
    }

    // ==================== BOM 处理测试 ====================

    @TestCase
    func parseBomAtStart(): Unit {
        // 观测当前实现：首字符 BOM 不会被当作空白跳过，因此会拒绝
        let bomJson = "\u{FEFF}null"
        @Expect(throwsJsonException(bomJson))
    }

    @TestCase
    func parseBomAtStartWithObject(): Unit {
        // 观测当前实现：对象前导 BOM 也会被拒绝
        let bomObject = "\u{FEFF}{\"a\":1}"
        @Expect(throwsJsonException(bomObject))
    }

    @TestCase
    func parseBomAtStartWithArray(): Unit {
        // 观测当前实现：数组前导 BOM 也会被拒绝
        let bomArray = "\u{FEFF}[1,2,3]"
        @Expect(throwsJsonException(bomArray))
    }

    @TestCase
    func parseBomInString(): Unit {
        // BOM 在字符串内部（作为普通字符）
        let value = parseValue("\"test\u{FEFF}value\"").asString()
        @Expect(value.contains("\u{FEFF}"))
        // 字符串中的 BOM 应被视为普通字符
    }

    @TestCase
    func parseMultipleBom(): Unit {
        // 观测当前实现：多个前导 BOM 会被拒绝
        let multiBom = "\u{FEFF}\u{FEFF}null"
        @Expect(throwsJsonException(multiBom))
    }

    @TestCase
    func parseBomAsEscapedUnicode(): Unit {
        // 字符串内部的 \uFEFF 应解码为单个 U+FEFF 字符
        let escapedBom = "\"\\uFEFF\""
        let value = parseValue(escapedBom).asString()
        @Expect(value, "\u{FEFF}")
        @Expect(count(value.runes()), 1)
    }

    // ==================== Unicode 非字符测试 ====================

    @TestCase
    func parseUnicodeNonCharacterFFFF(): Unit {
        let value = parseValue("\"\\uFFFF\"").asString()
        @Expect(value, "\u{FFFF}")
        @Expect(count(value.runes()), 1)
    }

    @TestCase
    func parseUnicodeNonCharacterFFFE(): Unit {
        let value = parseValue("\"\\uFFFE\"").asString()
        @Expect(value, "\u{FFFE}")
        @Expect(count(value.runes()), 1)
    }

    @TestCase
    func parseUnicodeReplacementFFFD(): Unit {
        let escaped = parseValue("\"\\uFFFD\"").asString()
        @Expect(escaped, "\u{FFFD}")
        @Expect(count(escaped.runes()), 1)

        let direct = parseValue("\"\u{FFFD}\"").asString()
        @Expect(direct, "\u{FFFD}")
        @Expect(count(direct.runes()), 1)
    }

    @TestCase
    func parseUnicodeOtherNonCharacters(): Unit {
        let value1 = parseValue("\"\\uFDD0\"").asString()
        @Expect(value1, "\u{FDD0}")
        @Expect(count(value1.runes()), 1)

        let value2 = parseValue("\"\\uFDEF\"").asString()
        @Expect(value2, "\u{FDEF}")
        @Expect(count(value2.runes()), 1)

        let value3 = parseValue("\"\\uDBFF\\uDFFE\"").asString()
        @Expect(value3, "\u{10FFFE}")
        @Expect(count(value3.runes()), 1)
    }

    @TestCase
    func parseUnicodeNullCharacter(): Unit {
        // U+0000 (null character)
        let escapedNull = "\"\\u0000\""
        let value = parseValue(escapedNull).asString()
        @Expect(value.size, 1)

        // null 字符作为转义应被接受，但作为未转义应被拒绝
        let unescapedNull = "\"\u{0000}\""
        @Expect(throwsJsonException(unescapedNull))
    }

    // ==================== Unicode 边界测试 ====================

    @TestCase
    func parseUnicodeMaxCodePoint(): Unit {
        let value = parseValue("\"\\uDBFF\\uDFFF\"").asString()
        @Expect(value, "\u{10FFFF}")
        @Expect(count(value.runes()), 1)
    }

    @TestCase
    func parseUnicodeSurrogatePairValid(): Unit {
        // 有效代理对测试
        // 𝄞 (U+1D11E) = \uD834\uDD1E
        let musicSymbol = "\"\\uD834\\uDD1E\""
        let value = parseValue(musicSymbol).asString()
        @Expect(value, "\u{1D11E}")

        // 😀 (U+1F600) = \uD83D\uDE00
        let emoji = "\"\\uD83D\\uDE00\""
        let value2 = parseValue(emoji).asString()
        @Expect(value2, "\u{1F600}")
    }

    @TestCase
    func parseUnicodeSurrogatePairInvalid(): Unit {
        // 无效代理对测试

        // 只有高代理，缺少低代理
        let highOnly = "\"\\uD834\""
        @Expect(throwsJsonException(highOnly))

        // 只有低代理
        let lowOnly = "\"\\uDD1E\""
        @Expect(throwsJsonException(lowOnly))

        // 高代理后跟非低代理
        let highBadPair = "\"\\uD834\\u0041\""
        @Expect(throwsJsonException(highBadPair))

        // 低代理后跟低代理
        let lowLowPair = "\"\\uDD1E\\uDD1E\""
        @Expect(throwsJsonException(lowLowPair))
    }

    @TestCase
    func parseUnicodeOutOfRangeSurrogate(): Unit {
        let minPair = parseValue("\"\\uD800\\uDC00\"").asString()
        @Expect(minPair, "\u{10000}")
        @Expect(count(minPair.runes()), 1)

        let maxPair = parseValue("\"\\uDBFF\\uDFFF\"").asString()
        @Expect(maxPair, "\u{10FFFF}")
        @Expect(count(maxPair.runes()), 1)
    }

    @TestCase
    func parseUnicodeMixedString(): Unit {
        // 混合 Unicode 字符的字符串
        let mixed = "\"A\\u4e2d\\uD834\\uDD1E\\u0031\""
        let value = parseValue(mixed).asString()
        @Expect(value.size >= 4)
        @Expect(value.contains("A"))
        @Expect(value.contains("\u{1D11E}"))
    }
}

/**
 * 空白字符完整测试 - P1 级别
 *
 * 测试内容：
 * 1. 各种空白字符组合：Tab, LF, CR, Space
 * 2. 空白在不同位置：值前后、键值对之间
 * 3. 边界情况：只有空白、值中间空白
 * 4. Unicode 空白字符
 */
@Test
class WhitespaceBoundaryTest {

    func throwsJsonException(text: String): Bool {
        try {
            let _ = JsonNode.parse(text)
            return false
        } catch (_: JsonException) {
            return true
        } catch (_: Exception) {
            return false
        }
    }

    func parseValue(text: String): JsonNode {
        JsonNode.parse(text)
    }

    // ==================== 组合空白测试 ====================

    @TestCase
    func parseAllWhitespaceTypes(): Unit {
        // 测试所有 JSON 兄许的空白字符
        // Space (0x20), Tab (0x09), LF (0x0A), CR (0x0D)

        // Space
        let space = " null"
        let v1 = parseValue(space)
        @Expect(v1.kind(), JsonKind.Null)

        // Tab
        let tab = "\tnull"
        let v2 = parseValue(tab)
        @Expect(v2.kind(), JsonKind.Null)

        // LF (newline)
        let lf = "\nnull"
        let v3 = parseValue(lf)
        @Expect(v3.kind(), JsonKind.Null)

        // CR (carriage return)
        let cr = "\rnull"
        let v4 = parseValue(cr)
        @Expect(v4.kind(), JsonKind.Null)

        // 组合空白
        let combined = "\n\t \rnull"
        let v5 = parseValue(combined)
        @Expect(v5.kind(), JsonKind.Null)
    }

    @TestCase
    func parseWhitespaceBeforeValue(): Unit {
        // 值前的各种空白组合

        // null 前多空白
        let nullValue = parseValue("   \n\t  null")
        @Expect(nullValue.kind(), JsonKind.Null)

        // 数字前多空白
        let numValue = parseValue("   \n\t  123")
        @Expect(numValue.asInt64(), 123)

        // 字符串前多空白
        let strValue = parseValue("   \n\t  \"hello\"")
        @Expect(strValue.asString(), "hello")

        // 数组前多空白
        let arrValue = parseValue("   \n\t  [1,2]")
        @Expect(arrValue.asArray().size(), 2)

        // 对象前多空白
        let objValue = parseValue("   \n\t  {\"a\":1}")
        @Expect(objValue.asObject().contains("a"))
    }

    @TestCase
    func parseWhitespaceAfterValue(): Unit {
        // 值后的各种空白组合

        // null 后多空白
        let nullValue = parseValue("null   \n\t  ")
        @Expect(nullValue.kind(), JsonKind.Null)

        // 数字后多空白
        let numValue = parseValue("123   \n\t  ")
        @Expect(numValue.asInt64(), 123)

        // 字符串后多空白
        let strValue = parseValue("\"hello\"   \n\t  ")
        @Expect(strValue.asString(), "hello")

        // 数组后多空白
        let arrValue = parseValue("[1,2]   \n\t  ")
        @Expect(arrValue.asArray().size(), 2)

        // 对象后多空白
        let objValue = parseValue("{\"a\":1}   \n\t  ")
        @Expect(objValue.asObject().contains("a"))
    }

    @TestCase
    func parseWhitespaceBetweenKeyValues(): Unit {
        // 键值对之间的空白

        // 冒号前空白
        let v1 = parseValue("{\"a\" :1}")
        @Expect(v1.asObject().get("a").getOrThrow().asInt64(), 1)

        // 冒号后空白
        let v2 = parseValue("{\"a\": 1}")
        @Expect(v2.asObject().get("a").getOrThrow().asInt64(), 1)

        // 冠号前后空白
        let v3 = parseValue("{\"a\" : 1}")
        @Expect(v3.asObject().get("a").getOrThrow().asInt64(), 1)

        // 多空白
        let v4 = parseValue("{\"a\"  :  1}")
        @Expect(v4.asObject().get("a").getOrThrow().asInt64(), 1)

        // 带换行的空白
        let v5 = parseValue("{\"a\"\n:\n1}")
        @Expect(v5.asObject().get("a").getOrThrow().asInt64(), 1)

        // 字段间空白
        let v6 = parseValue("{\"a\":1 , \"b\":2}")
        @Expect(v6.asObject().size(), 2)

        // 多字段间空白
        let v7 = parseValue("{\"a\":1  ,  \"b\":2}")
        @Expect(v7.asObject().size(), 2)
    }

    @TestCase
    func parseWhitespaceInArray(): Unit {
        // 数组中的空白

        // 元素间空白
        let v1 = parseValue("[1 , 2 , 3]")
        @Expect(v1.asArray().size(), 3)

        // 元素前空白
        let v2 = parseValue("[ 1, 2, 3]")
        @Expect(v2.asArray().size(), 3)

        // 元素后空白
        let v3 = parseValue("[1, 2, 3 ]")
        @Expect(v3.asArray().size(), 3)

        // 所有位置空白
        let v4 = parseValue("[ 1 , 2 , 3 ]")
        @Expect(v4.asArray().size(), 3)

        // 多空白和换行
        let v5 = parseValue("[\n  1,\n  2,\n  3\n]")
        @Expect(v5.asArray().size(), 3)

        // 复杂空白格式
        let v6 = parseValue("[\n\t1,\n\t2\n]")
        @Expect(v6.asArray().size(), 2)
    }

    @TestCase
    func parseWhitespaceInNestedStructures(): Unit {
        // 嵌套结构中的空白

        // 嵌套数组
        let v1 = parseValue("[ [1] , [2] ]")
        @Expect(v1.asArray().size(), 2)

        // 嵌套对象
        let v2 = parseValue("{\"a\": {\"b\": 2} , \"c\": 3}")
        @Expect(v2.asObject().size(), 2)

        // 深嵌套
        let v3 = parseValue("{\"arr\": [ {\"obj\": {\"x\": 1} } ] }")
        @Expect(v3.asObject().contains("arr"))

        // 格式化的复杂结构
        let v4 = parseValue("{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {\n    \"x\": 3\n  }\n}")
        @Expect(v4.asObject().size(), 2)
    }

    // ==================== 边界情况测试 ====================

    @TestCase
    func parseOnlyWhitespaceRejected(): Unit {
        // 只有空白的输入应被拒绝
        @Expect(throwsJsonException(""))
        @Expect(throwsJsonException(" "))
        @Expect(throwsJsonException("  "))
        @Expect(throwsJsonException("\t"))
        @Expect(throwsJsonException("\n"))
        @Expect(throwsJsonException("\r"))
        @Expect(throwsJsonException(" \t\n\r "))
        @Expect(throwsJsonException("\n\t\r\n\t"))
    }

    @TestCase
    func rejectWhitespaceInValueMiddle(): Unit {
        // 值中间不应有空白

        // 数字中间空白（应拒绝）
        @Expect(throwsJsonException("1 23"))
        @Expect(throwsJsonException("1\t23"))
        @Expect(throwsJsonException("1\n23"))

        // null 中间空白（应拒绝）
        @Expect(throwsJsonException("n u l l"))
        @Expect(throwsJsonException("nul l"))

        // true 中间空白（应拒绝）
        @Expect(throwsJsonException("t r u e"))
        @Expect(throwsJsonException("tru e"))

        // false 中间空白（应拒绝）
        @Expect(throwsJsonException("f a l s e"))
        @Expect(throwsJsonException("fals e"))

        // 浮点数中间空白（应拒绝）
        @Expect(throwsJsonException("1. 5"))
        @Expect(throwsJsonException("1 .5"))
        @Expect(throwsJsonException("1e 10"))
        @Expect(throwsJsonException("1e+ 10"))
    }

    @TestCase
    func parseUnicodeWhitespace(): Unit {
        // 测试 Unicode 空白字符
        // 注：JSON 规范只允许 Space, Tab, LF, CR
        // 其他 Unicode 空白字符应该被拒绝

        // No-Break Space (U+00A0) - 应拒绝
        @Expect(throwsJsonException("\u{00A0}null"))

        // En Space (U+2002) - 应拒绝
        @Expect(throwsJsonException("\u{2002}null"))

        // Em Space (U+2003) - 应拒绝
        @Expect(throwsJsonException("\u{2003}null"))

        // Thin Space (U+2009) - 应拒绝
        @Expect(throwsJsonException("\u{2009}null"))

        // Zero Width Space (U+200B) - 应拒绝
        @Expect(throwsJsonException("\u{200B}null"))

        // Non-breaking space 在字符串内部（应接受）
        let str = parseValue("\"test\u{00A0}value\"")
        @Expect(str.asString().contains("\u{00A0}"))
    }

    @TestCase
    func parseWhitespaceEdgeCases(): Unit {
        // 边缘空白情况

        // 大量空白
        let lotsOfSpaces = "                                                    null"
        let v1 = parseValue(lotsOfSpaces)
        @Expect(v1.kind(), JsonKind.Null)

        // CRLF 组合
        let crlf = "\r\nnull\r\n"
        let v2 = parseValue(crlf)
        @Expect(v2.kind(), JsonKind.Null)

        // 多个 CRLF
        let multiCrlf = "\r\n\r\n\r\nnull\r\n\r\n\r\n"
        let v3 = parseValue(multiCrlf)
        @Expect(v3.kind(), JsonKind.Null)

        // 空对象前后空白
        let emptyObj = "   {}   "
        let v4 = parseValue(emptyObj)
        @Expect(v4.asObject().size(), 0)

        // 空数组前后空白
        let emptyArr = "   []   "
        let v5 = parseValue(emptyArr)
        @Expect(v5.asArray().size(), 0)
    }

    @TestCase
    func parseWhitespaceWithAllTypes(): Unit {
        // 包含所有空白类型的 JSON

        let complexWhitespace =
            "\n\t\r \n{\n\t\r \"key\"\n\t\r :\n\t\r \"value\"\n\t\r ,\n\t\r \"num\"\n\t\r :\n\t\r 123\n\t\r }\n\t\r "

        let obj = parseValue(complexWhitespace).asObject()
        @Expect(obj.size(), 2)
        @Expect(obj.get("key").getOrThrow().asString(), "value")
        @Expect(obj.get("num").getOrThrow().asInt64(), 123)
    }
}

/**
 * 深层嵌套边界测试 - P1 级别
 *
 * 测试内容：
 * 1. 50 层嵌套数组/对象
 * 2. 混合嵌套结构
 * 3. 栈限制和性能测试
 */
@Test
class DeepNestingBoundaryTest {

    func canParse(text: String): Bool {
        try {
            let _ = JsonNode.parse(text)
            return true
        } catch (_: Exception) {
            return false
        }
    }

    func throwsJsonException(text: String): Bool {
        try {
            let _ = JsonNode.parse(text)
            return false
        } catch (_: JsonException) {
            return true
        } catch (_: Exception) {
            return false
        }
    }

    func parseValue(text: String): JsonNode {
        JsonNode.parse(text)
    }

    func dropLastBytes(text: String, count: Int64): String {
        text[0..(text.size - count)]
    }

    // Helper to generate deep nested array JSON
    func generateDeepNestedArray(depth: Int64): String {
        var result = ""
        for (_ in 0..depth) {
            result = result + "["
        }
        result = result + "1"
        for (_ in 0..depth) {
            result = result + "]"
        }
        result
    }

    // Helper to generate deep nested object JSON
    func generateDeepNestedObject(depth: Int64): String {
        var result = ""
        var key = "a"
        for (i in 0..depth) {
            result = result + "{\"" + key + "\":"
            key = key + (i + 1).toString()
        }
        result = result + "1"
        for (_ in 0..depth) {
            result = result + "}"
        }
        result
    }

    // Helper to generate mixed nested structure
    func generateMixedNesting(depth: Int64): String {
        var result = ""
        for (i in 0..depth) {
            if (i % 2 == 0) {
                result = result + "["
            } else {
                result = result + "{\"a\":"
            }
        }
        result = result + "1"
        for (i in 0..depth) {
            if ((depth - i - 1) % 2 == 0) {
                result = result + "]"
            } else {
                result = result + "}"
            }
        }
        result
    }

    // Helper to navigate deep nested array
    func navigateDeepArray(arr: JsonArray, depth: Int64): Int64 {
        if (depth <= 0) {
            return arr[0].asInt64()
        }
        return navigateDeepArray(arr[0].asArray(), depth - 1)
    }

    // Helper to navigate deep nested object
    func navigateDeepObject(obj: JsonObject, key: String, depth: Int64): Int64 {
        if (depth <= 0) {
            return obj.get(key).getOrThrow().asInt64()
        }
        return navigateDeepObject(obj.get(key).getOrThrow().asObject(), key, depth - 1)
    }

    // ==================== 嵌套深度测试 ====================

    @TestCase
    func parseDeepNestedArray10(): Unit {
        // 10 层嵌套数组（基础测试）
        let json = generateDeepNestedArray(10)
        let value = parseValue(json)
        @Expect(value.kind(), JsonKind.Array)
        let result = navigateDeepArray(value.asArray(), 9)
        @Expect(result, 1)
    }

    @TestCase
    func parseDeepNestedArray20(): Unit {
        // 20 层嵌套数组
        let json = generateDeepNestedArray(20)
        let value = parseValue(json)
        @Expect(value.kind(), JsonKind.Array)
        let result = navigateDeepArray(value.asArray(), 19)
        @Expect(result, 1)
    }

    @TestCase
    func parseDeepNestedArray50(): Unit {
        // 50 层嵌套数组
        let json = generateDeepNestedArray(50)
        let canParseResult = canParse(json)
        @Expect(canParseResult)  // 应能解析

        if (canParseResult) {
            let value = parseValue(json)
            @Expect(value.kind(), JsonKind.Array)
            let result = navigateDeepArray(value.asArray(), 49)
            @Expect(result, 1)
        }
    }

    @TestCase
    func parseDeepNestedObject10(): Unit {
        // 10 层嵌套对象（基础测试）
        let json = generateDeepNestedObject(10)
        let value = parseValue(json)
        @Expect(value.kind(), JsonKind.Object)
    }

    @TestCase
    func parseDeepNestedObject20(): Unit {
        // 20 层嵌套对象
        let json = generateDeepNestedObject(20)
        let value = parseValue(json)
        @Expect(value.kind(), JsonKind.Object)
    }

    @TestCase
    func parseDeepNestedObject50(): Unit {
        // 50 层嵌套对象
        let json = generateDeepNestedObject(50)
        let canParseResult = canParse(json)
        @Expect(canParseResult)  // 应能解析

        if (canParseResult) {
            let value = parseValue(json)
            @Expect(value.kind(), JsonKind.Object)
        }
    }

    @TestCase
    func parseMixedDeepNesting10(): Unit {
        // 10 层混合嵌套（对象包含数组包含对象...）
        let json = generateMixedNesting(10)
        let value = parseValue(json)
        @Expect(value.kind() == JsonKind.Array || value.kind() == JsonKind.Object)
    }

    @TestCase
    func parseMixedDeepNesting20(): Unit {
        // 20 层混合嵌套
        let json = generateMixedNesting(20)
        let value = parseValue(json)
        @Expect(value.kind() == JsonKind.Array || value.kind() == JsonKind.Object)
    }

    @TestCase
    func parseMixedDeepNesting50(): Unit {
        // 50 层混合嵌套
        let json = generateMixedNesting(50)
        let canParseResult = canParse(json)
        @Expect(canParseResult)  // 应能解析

        if (canParseResult) {
            let value = parseValue(json)
            @Expect(value.kind() == JsonKind.Array || value.kind() == JsonKind.Object)
        }
    }

    // ==================== 栈限制测试 ====================

    @TestCase
    func parseDeepNestedBoundary100Smoke(): Unit {
        // 100 层嵌套的功能性 smoke：验证成功且结构可遍历
        let json = generateDeepNestedArray(100)
        let value = parseValue(json)
        var current = value
        for (_ in 0..100) {
            let arr = current.asArray()
            @Expect(arr.size(), 1)
            current = arr[0]
        }
        @Expect(current.kind(), JsonKind.Number)
        @Expect(current.asInt64(), 1)
    }

    @TestCase
    func parseDeepNestedBoundary200Smoke(): Unit {
        // 200 层嵌套的功能性 smoke：验证成功且结构可遍历
        let json = generateDeepNestedArray(200)
        let value = parseValue(json)
        var current = value
        for (_ in 0..200) {
            let arr = current.asArray()
            @Expect(arr.size(), 1)
            current = arr[0]
        }
        @Expect(current.kind(), JsonKind.Number)
        @Expect(current.asInt64(), 1)
    }

    // ==================== 性能测试 ====================

    @TestCase
    func parseLargeNestedPerformance(): Unit {
        // 大型嵌套结构性能测试
        // 生成一个包含多个嵌套元素的结构

        var jsonBuilder = StringBuilder()
        jsonBuilder.append("[")

        for (i in 0..10) {
            if (i > 0) {
                jsonBuilder.append(",")
            }
            jsonBuilder.append(generateDeepNestedArray(10))
        }

        jsonBuilder.append("]")
        let json = jsonBuilder.toString()

        let value = parseValue(json)
        @Expect(value.kind(), JsonKind.Array)
        @Expect(value.asArray().size(), 10)

        // 应在合理时间内完成，不超时
    }

    @TestCase
    func parseDeepNestedWithValues(): Unit {
        // 嵌套结构包含实际值

        // 嵌套数组包含多个值
        let deepArray = "[[[[1,2],[3,4]],[[5,6],[7,8]]]]"
        let v1 = parseValue(deepArray).asArray()
        @Expect(v1[0].asArray()[0].asArray()[0].asArray()[0].asInt64(), 1)
        @Expect(v1[0].asArray()[1].asArray()[1].asArray()[1].asInt64(), 8)

        // 嵌套对象包含多个字段
        let deepObject = "{\"a\":{\"b\":{\"c\":{\"d\":1}}}}"
        let v2 = parseValue(deepObject).asObject()
        @Expect(v2.get("a").getOrThrow().asObject().get("b").getOrThrow().asObject().get("c").getOrThrow().asObject().get("d").getOrThrow().asInt64(), 1)
    }

    @TestCase
    func parseDeepNestedWithError(): Unit {
        // 深嵌套结构中的错误

        // 深嵌套但未闭合
        @Expect(throwsJsonException(dropLastBytes(generateDeepNestedArray(10), 1)))
        @Expect(throwsJsonException(dropLastBytes(generateDeepNestedObject(10), 1)))

        // 深嵌套但多余的闭合
        @Expect(throwsJsonException(generateDeepNestedArray(10) + "]"))
        @Expect(throwsJsonException(generateDeepNestedObject(10) + "}"))

        // 深嵌套中结构错误
        let mismatched1 = "[[[[{}]]]]"  // 数组嵌套对象
        let v1 = parseValue(mismatched1)
        @Expect(v1.kind(), JsonKind.Array)

        let mismatched2 = "{\"a\":{\"b\":{\"c\":[]}}}"  // 对象嵌套数组
        let v2 = parseValue(mismatched2)
        @Expect(v2.kind(), JsonKind.Object)
    }

    @TestCase
    func parseDeepNestedArrayWithManyElements(): Unit {
        // 深嵌套且每层有多个元素
        var jsonBuilder = StringBuilder()
        jsonBuilder.append("[")

        for (i in 0..5) {
            if (i > 0) {
                jsonBuilder.append(",")
            }
            jsonBuilder.append("[")
            for (j in 0..10) {
                if (j > 0) {
                    jsonBuilder.append(",")
                }
                jsonBuilder.append(j.toString())
            }
            jsonBuilder.append("]")
        }

        jsonBuilder.append("]")
        let json = jsonBuilder.toString()

        let value = parseValue(json)
        @Expect(value.asArray().size(), 5)
        @Expect(value.asArray()[0].asArray().size(), 10)
    }

    @TestCase
    func parseDeepNestedObjectWithManyFields(): Unit {
        // 深嵌套且每层有多个字段
        var jsonBuilder = StringBuilder()
        jsonBuilder.append("{")

        for (i in 0..3) {
            if (i > 0) {
                jsonBuilder.append(",")
            }
            jsonBuilder.append("\"level" + i.toString() + "\":{")
            for (j in 0..5) {
                if (j > 0) {
                    jsonBuilder.append(",")
                }
                jsonBuilder.append("\"key" + j.toString() + "\":")
                jsonBuilder.append(j.toString())
            }
            jsonBuilder.append("}")
        }

        jsonBuilder.append("}")
        let json = jsonBuilder.toString()

        let value = parseValue(json)
        @Expect(value.asObject().size(), 3)
        @Expect(value.asObject().get("level0").getOrThrow().asObject().size(), 5)
    }
}
