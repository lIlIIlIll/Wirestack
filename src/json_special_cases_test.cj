package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * JSON 特殊场景测试 - P2 级别
 *
 * 测试内容：
 * 1. Unicode 边界测试：零宽字符、方向控制、组合字符、Emoji
 * 2. 实现相关行为测试：NumberLiteral vs Int/Float、HashMap 键顺序、toString 格式
 * 3. 其他边界场景
 */

// ==================== Unicode Boundary Tests ====================

@Test
class UnicodeZeroWidthCharactersTest {

    @TestCase
    func parseZeroWidthSpace(): Unit {
        // U+200B (Zero Width Space)
        let value = JsonNode.parse("{\"a\":\"test\\u200Bend\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "test\u{200B}end")
        @Expect(count(str.runes()), 8)
    }

    @TestCase
    func parseZeroWidthNonJoiner(): Unit {
        // U+200C (Zero Width Non-Joiner)
        let value = JsonNode.parse("{\"a\":\"test\\u200Cend\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "test\u{200C}end")
        @Expect(count(str.runes()), 8)
    }

    @TestCase
    func parseZeroWidthJoiner(): Unit {
        // U+200D (Zero Width Joiner) - used in Emoji sequences
        let value = JsonNode.parse("{\"a\":\"test\\u200Dend\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "test\u{200D}end")
        @Expect(count(str.runes()), 8)
    }

    @TestCase
    func parseZeroWidthNoBreakSpace(): Unit {
        // U+FEFF (Zero Width No-Break Space / BOM character)
        // When inside a string, should be accepted
        let value = JsonNode.parse("{\"a\":\"test\\uFEFFend\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "test\u{FEFF}end")
        @Expect(count(str.runes()), 8)
    }
}

@Test
class UnicodeDirectionControlTest {

    @TestCase
    func parseLeftToRightMark(): Unit {
        // U+200E (Left-to-Right Mark)
        let value = JsonNode.parse("{\"a\":\"text\\u200E\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "text\u{200E}")
        @Expect(count(str.runes()), 5)
    }

    @TestCase
    func parseRightToLeftMark(): Unit {
        // U+200F (Right-to-Left Mark)
        let value = JsonNode.parse("{\"a\":\"text\\u200F\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "text\u{200F}")
        @Expect(count(str.runes()), 5)
    }

    @TestCase
    func parseLeftToRightEmbedding(): Unit {
        // U+202A (Left-to-Right Embedding)
        let value = JsonNode.parse("{\"a\":\"\\u202Atext\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "\u{202A}text")
        @Expect(count(str.runes()), 5)
    }

    @TestCase
    func parseRightToLeftEmbedding(): Unit {
        // U+202B (Right-to-Left Embedding)
        let value = JsonNode.parse("{\"a\":\"\\u202Btext\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "\u{202B}text")
        @Expect(count(str.runes()), 5)
    }

    @TestCase
    func parsePopDirectionalFormat(): Unit {
        // U+202C (Pop Directional Format)
        let value = JsonNode.parse("{\"a\":\"\\u202Atext\\u202C\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        @Expect(str, "\u{202A}text\u{202C}")
        @Expect(count(str.runes()), 6)
    }
}

@Test
class UnicodeNonCharactersTest {

    @TestCase
    func parseUnicodeNonCharacterFFFE(): Unit {
        // U+FFFE is a non-character but JSON parsers typically accept it
        let value = JsonNode.parse("{\"a\":\"\\uFFFE\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // str.size returns UTF-8 byte count, not character count
        // U+FFFE encodes to 3 UTF-8 bytes
        @Expect(count(str.runes()), 1)
    }

    @TestCase
    func parseUnicodeNonCharacterFFFF(): Unit {
        // U+FFFF is a non-character but JSON parsers typically accept it
        let value = JsonNode.parse("{\"a\":\"\\uFFFF\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // U+FFFF encodes to 3 UTF-8 bytes
        @Expect(count(str.runes()), 1)
    }

    @TestCase
    func parseUnicodeReplacementCharacter(): Unit {
        // U+FFFD (Replacement Character)
        let value = JsonNode.parse("{\"a\":\"\\uFFFD\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // U+FFFD encodes to 3 UTF-8 bytes
        @Expect(count(str.runes()), 1)
    }
}

@Test
class UnicodeCombiningCharactersTest {

    @TestCase
    func parseCombiningDiacriticalMarks(): Unit {
        // Combining acute accent (U+0301) after 'e'
        let value = JsonNode.parse("{\"a\":\"e\\u0301\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // Should result in "é" (2 code units, but 2 runes)
        // e = 1 byte, U+0301 = 2 bytes (total 3 UTF-8 bytes)
        @Expect(count(str.runes()), 2)
    }

    @TestCase
    func parseMultipleCombiningMarks(): Unit {
        // Multiple combining marks
        let value = JsonNode.parse("{\"a\":\"a\\u0300\\u0301\\u0302\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // a = 1 byte, U+0300/U+0301/U+0302 each = 2 bytes (total 7 UTF-8 bytes)
        // But 4 runes: 'a' + 3 combining marks
        @Expect(count(str.runes()), 4)
    }
}

@Test
class EmojiSequenceTest {

    @TestCase
    func parseSimpleEmoji(): Unit {
        // Simple emoji like 🙂 (U+1F642) requires surrogate pair
        let value = JsonNode.parse("{\"a\":\"\\uD83D\\uDE42\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // Surrogate pair represents 1 Unicode character (rune)
        // UTF-8 encoding uses 4 bytes for this emoji
        @Expect(count(str.runes()), 1)  // 1 rune, not 2 code units
    }

    @TestCase
    func parseEmojiWithSkinToneModifier(): Unit {
        // 👍 + skin tone modifier (U+1F3FD)
        // 👍 is U+1F44D (surrogate pair D83D DC4D)
        // Skin tone is U+1F3FD (surrogate pair D83C DFFD)
        let value = JsonNode.parse("{\"a\":\"\\uD83D\\uDC4D\\uD83C\\uDFFD\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // Two surrogate pairs = 2 runes (2 Unicode characters)
        // Each emoji encodes to 4 UTF-8 bytes (total 8 bytes)
        @Expect(count(str.runes()), 2)  // 2 runes, not 4 code units
    }

    @TestCase
    func parseEmojiWithZeroWidthJoiner(): Unit {
        // Family emoji: 👨 (U+1F468) + ZWJ (U+200D) + 👩 (U+1F469) + ZWJ + 👧 (U+1F467)
        // This creates a multi-codepoint emoji sequence
        let value = JsonNode.parse("{\"a\":\"\\uD83D\\uDC68\\u200D\\uD83D\\uDC69\\u200D\\uD83D\\uDC67\"}")
        let str = value.asObject().get("a").getOrThrow().asString()
        // Three surrogate pairs + two ZWJs = 5 Unicode characters (runes)
        // UTF-8: 3 emojis (each 4 bytes) + 2 ZWJs (each 3 bytes) = 18 bytes total
        @Expect(count(str.runes()), 5)  // 5 runes, not 8 code units
    }
}

@Test
class UnicodeKeyNamesTest {

    @TestCase
    func parseChineseKeyNames(): Unit {
        let value = JsonNode.parse("{\"名字\":\"测试\",\"年龄\":25}")
        let obj = value.asObject()
        @Expect(obj.contains("名字"))
        @Expect(obj.contains("年龄"))
        @Expect(obj.get("名字").getOrThrow().asString(), "测试")
        @Expect(obj.get("年龄").getOrThrow().asInt64(), 25)
    }

    @TestCase
    func parseEmojiKeyNames(): Unit {
        // Emoji as key name (surrogate pair)
        let value = JsonNode.parse("{\"\\uD83D\\uDE00\":\"happy\"}")
        let obj = value.asObject()
        @Expect(obj.size(), 1)
        @Expect(obj.contains("😀"))
        @Expect(obj.get("😀").getOrThrow().asString(), "happy")
    }

    @TestCase
    func parseMixedUnicodeKeyNames(): Unit {
        let value = JsonNode.parse("{\"English\":\"text\",\"中文\":\"测试\",\"\\u2603\":\"snowman\"}")
        let obj = value.asObject()
        @Expect(obj.size(), 3)
        @Expect(obj.contains("English"))
        @Expect(obj.contains("中文"))
        @Expect(obj.contains("☃"))
        @Expect(obj.get("English").getOrThrow().asString(), "text")
        @Expect(obj.get("中文").getOrThrow().asString(), "测试")
        @Expect(obj.get("☃").getOrThrow().asString(), "snowman")
    }
}

// ==================== Implementation Behavior Tests ====================

@Test
class NumberLiteralChoiceTest {

    @TestCase
    func smallIntegerReturnsInt(): Unit {
        let value = JsonNode.parse("123")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func int64MaxReturnsInt(): Unit {
        let value = JsonNode.parse("9223372036854775807")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asInt64(), 9223372036854775807)
    }

    @TestCase
    func int64OverflowReturnsNumberLiteral(): Unit {
        let value = JsonNode.parse("9223372036854775808")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "9223372036854775808")
    }

    @TestCase
    func largePositiveNumberReturnsNumberLiteral(): Unit {
        let value = JsonNode.parse("99999999999999999999999")
        @Expect(value.kind(), JsonKind.Number)
    }

    @TestCase
    func largeNegativeNumberReturnsNumberLiteral(): Unit {
        let value = JsonNode.parse("-99999999999999999999999")
        @Expect(value.kind(), JsonKind.Number)
    }

    @TestCase
    func smallFloatReturnsFloat(): Unit {
        let value = JsonNode.parse("1.5")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1.5")
        @Expect(value.asFloat64(), 1.5)
    }

    @TestCase
    func floatWithExponentReturnsFloat(): Unit {
        let value = JsonNode.parse("1.5e10")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1.5e10")
        @Expect(value.asFloat64(), 1.5e10)
    }

    @TestCase
    func numberWithDecimalPointButSmallIntegerPartReturnsFloat(): Unit {
        let value = JsonNode.parse("0.123")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "0.123")
        @Expect(value.asFloat64(), 0.123)
    }
}

@Test
class HashMapKeyOrderTest {

    @TestCase
    func parsePreservesKeyPresence(): Unit {
        let value = JsonNode.parse("{\"a\":1,\"b\":2,\"c\":3}")
        let obj = value.asObject()

        // All keys should be present
        @Expect(obj.contains("a"))
        @Expect(obj.contains("b"))
        @Expect(obj.contains("c"))

        // Values should be correct
        @Expect(obj.get("a").getOrThrow().asInt64(), 1)
        @Expect(obj.get("b").getOrThrow().asInt64(), 2)
        @Expect(obj.get("c").getOrThrow().asInt64(), 3)
    }

    @TestCase
    func duplicateKeysRejectByDefaultAndCanSelectLastWins(): Unit {
        @AssertThrows[JsonException](JsonNode.parse("{\"a\":1,\"a\":2,\"a\":3}"))
        let value = JsonNode.parse("{\"a\":1,\"a\":2,\"a\":3}",
            config: JsonReadOptions(duplicateKeyPolicy: LastWins))
        let obj = value.asObject()
        @Expect(obj.size(), 1)
        @Expect(obj.get("a").getOrThrow().asInt64(), 3)
    }

    @TestCase
    func roundtripPreservesKeyPresence(): Unit {
        let json = "{\"first\":1,\"second\":2,\"third\":3}"
        let value = JsonNode.parse(json)
        let output = value.toString()
        let reparsed = JsonNode.parse(output)

        let obj = reparsed.asObject()
        @Expect(obj.contains("first"))
        @Expect(obj.contains("second"))
        @Expect(obj.contains("third"))
    }
}

@Test
class ToStringFormatTest {

    @TestCase
    func toStringProducesCompactFormat(): Unit {
        let value = JsonNode.parse("{\"a\":1,\"b\":2}")
        let output = value.toString()

        // Should produce compact format (no extra spaces)
        @Expect(!output.contains(" : "))
        @Expect(!output.contains(": "))
    }

    @TestCase
    func toStringPreservesArrayElements(): Unit {
        let value = JsonNode.parse("[1,2,3]")
        let output = value.toString()

        @Expect(output, "[1,2,3]")
    }

    @TestCase
    func toStringPreservesNull(): Unit {
        let value = JsonNode.parse("null")
        let output = value.toString()

        @Expect(output, "null")
    }

    @TestCase
    func toStringPreservesBoolean(): Unit {
        let value1 = JsonNode.parse("true")
        let output1 = value1.toString()
        @Expect(output1, "true")

        let value2 = JsonNode.parse("false")
        let output2 = value2.toString()
        @Expect(output2, "false")
    }

    @TestCase
    func toStringEscapesSpecialChars(): Unit {
        let value = JsonNode.parse("{\"a\":\"quote\\\"backslash\\\\newline\\n\"}")
        let output = value.toString()

        // Output should contain escaped sequences
        @Expect(output.contains("\\\""))
        @Expect(output.contains("\\\\"))
        @Expect(output.contains("\\n"))
    }

    @TestCase
    func toStringPreservesUnicode(): Unit {
        let value = JsonNode.parse("{\"a\":\"中文\\u2603\"}")
        let output = value.toString()

        @Expect(output, "{\"a\":\"中文☃\"}")
        @Expect(JsonNode.parse(output).asObject().get("a").getOrThrow().asString(), "中文☃")
    }

    @TestCase
    func toStringPreservesNumberLiteralAsString(): Unit {
        let value = JsonNode.parse("99999999999999999999999")
        let output = value.toString()

        // Should preserve the literal representation
        @Expect(output, "99999999999999999999999")
    }
}

@Test
class EdgeCaseScenariosTest {

    @TestCase
    func parseEmptyKeyInObject(): Unit {
        let value = JsonNode.parse("{\"\":42}")
        let obj = value.asObject()

        // Empty string is a valid key
        @Expect(obj.contains(""))
        @Expect(obj.get("").getOrThrow().asInt64(), 42)
    }

    @TestCase
    func parseKeyWithSpaces(): Unit {
        let value = JsonNode.parse("{\" key with spaces \":42}")
        let obj = value.asObject()

        @Expect(obj.contains(" key with spaces "))
    }

    @TestCase
    func parseKeyWithNewlineEscape(): Unit {
        let value = JsonNode.parse("{\"key\\nwith\\nnewlines\":42}")
        let obj = value.asObject()

        @Expect(obj.size(), 1)
        @Expect(obj.contains("key\nwith\nnewlines"))
        @Expect(obj.get("key\nwith\nnewlines").getOrThrow().asInt64(), 42)
    }

    @TestCase
    func parseObjectWithAllNullValues(): Unit {
        let value = JsonNode.parse("{\"a\":null,\"b\":null,\"c\":null}")
        let obj = value.asObject()

        @Expect(obj.size(), 3)
        @Expect(obj.get("a").getOrThrow().kind(), JsonKind.Null)
        @Expect(obj.get("b").getOrThrow().kind(), JsonKind.Null)
        @Expect(obj.get("c").getOrThrow().kind(), JsonKind.Null)
    }

    @TestCase
    func parseArrayWithAllNulls(): Unit {
        let value = JsonNode.parse("[null,null,null]")
        let arr = value.asArray()

        @Expect(arr.size(), 3)
        @Expect(arr[0].kind(), JsonKind.Null)
        @Expect(arr[1].kind(), JsonKind.Null)
        @Expect(arr[2].kind(), JsonKind.Null)
    }

    @TestCase
    func parseArrayOfArrays(): Unit {
        let value = JsonNode.parse("[[],[],[]]")
        let arr = value.asArray()

        @Expect(arr.size(), 3)
        @Expect(arr[0].asArray().size(), 0)
        @Expect(arr[1].asArray().size(), 0)
        @Expect(arr[2].asArray().size(), 0)
    }

    @TestCase
    func parseArrayOfObjects(): Unit {
        let value = JsonNode.parse("[{},{}]")
        let arr = value.asArray()

        @Expect(arr.size(), 2)
        @Expect(arr[0].asObject().size(), 0)
        @Expect(arr[1].asObject().size(), 0)
    }

    @TestCase
    func parseMixedNullAndValues(): Unit {
        let value = JsonNode.parse("[null,1,null,\"text\",null]")
        let arr = value.asArray()

        @Expect(arr.size(), 5)
        @Expect(arr[0].kind(), JsonKind.Null)
        @Expect(arr[1].asInt64(), 1)
        @Expect(arr[2].kind(), JsonKind.Null)
        @Expect(arr[3].asString(), "text")
        @Expect(arr[4].kind(), JsonKind.Null)
    }
}

@Test
class WhitespaceVariationsTest {

    @TestCase
    func parseWithLeadingNewline(): Unit {
        let value = JsonNode.parse("\n123")
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func parseWithLeadingTab(): Unit {
        let value = JsonNode.parse("\t123")
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func parseWithLeadingCarriageReturn(): Unit {
        let value = JsonNode.parse("\r123")
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func parseWithMixedLeadingWhitespace(): Unit {
        let value = JsonNode.parse("\n\t\r 123")
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func parseWithTrailingWhitespace(): Unit {
        let value = JsonNode.parse("123\n\t ")
        @Expect(value.asInt64(), 123)
    }

    @TestCase
    func parseObjectWithMinimalWhitespace(): Unit {
        let value = JsonNode.parse("{\"a\":1,\"b\":2}")
        let obj = value.asObject()
        @Expect(obj.size(), 2)
    }

    @TestCase
    func parseObjectWithMaximalWhitespace(): Unit {
        let value = JsonNode.parse("{\n\t\"a\"\n:\n\t1\n,\n\t\"b\"\n:\n\t2\n}")
        let obj = value.asObject()
        @Expect(obj.size(), 2)
    }
}

@Test
class SpecialNumberFormatsTest {

    @TestCase
    func parseNegativeZero(): Unit {
        let value = JsonNode.parse("-0")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asInt64(), 0)
    }

    @TestCase
    func parseExponentWithoutSign(): Unit {
        let value = JsonNode.parse("1e5")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1e5")
        @Expect(value.asFloat64(), 1e5)
    }

    @TestCase
    func parseExponentWithPlusSign(): Unit {
        let value = JsonNode.parse("1e+5")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1e+5")
        @Expect(value.asFloat64(), 1e5)
    }

    @TestCase
    func parseExponentWithMinusSign(): Unit {
        let value = JsonNode.parse("1e-5")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1e-5")
        @Expect(value.asFloat64(), 1e-5)
    }

    @TestCase
    func parseUpperCaseExponent(): Unit {
        let value = JsonNode.parse("1E5")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "1E5")
        @Expect(value.asFloat64(), 1e5)
    }

    @TestCase
    func parseFloatWithManyDecimals(): Unit {
        let value = JsonNode.parse("0.123456789012345678")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "0.123456789012345678")
    }

    @TestCase
    func parseNumberStartingWithZeroAndDecimal(): Unit {
        let value = JsonNode.parse("0.123")
        @Expect(value.kind(), JsonKind.Number)
        @Expect(value.asNumberText(), "0.123")
        @Expect(value.asFloat64(), 0.123)
    }
}
