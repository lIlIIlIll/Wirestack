package yjson

import std.unittest.*
import std.unittest.testmacro.*

/**
 * FastReader 和 DirectReader 测试 - P1 级别
 *
 * 测试内容：
 * 1. FastReader：字节级构造、边界值数字、字段名匹配
 * 2. DirectReader：缺失字段、多余字段、类型不匹配、嵌套结构、空值处理
 */

// Helper functions - specific action wrappers for reader tests
func fastReaderReadInt64OverflowThrows(): Bool {
    try {
        let reader = JsonFastReader("9223372036854775808")
        let _ = reader.readRawInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func fastReaderReadInt64UnderflowThrows(): Bool {
    try {
        let reader = JsonFastReader("-9223372036854775809")
        let _ = reader.readRawInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func fastReaderReadUInt64OverflowThrows(): Bool {
    try {
        let reader = JsonFastReader("18446744073709551616")
        let _ = reader.readRawUInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func fastReaderReadUInt64NegativeThrows(): Bool {
    try {
        let reader = JsonFastReader("-1")
        let _ = reader.readRawUInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func fastReaderReadInt32OverflowThrows(): Bool {
    try {
        let reader = JsonFastReader("2147483648")
        let _ = reader.readRawInt32()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

// DirectReader helper functions
func directReaderReadStringExpectedNumberThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":\"text\"}")
        reader.startObject()
        reader.readName()
        let _ = reader.readInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadNumberExpectedStringThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":123}")
        reader.startObject()
        reader.readName()
        let _ = reader.readString()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadBoolExpectedNumberThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":true}")
        reader.startObject()
        reader.readName()
        let _ = reader.readInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadObjectExpectedStringThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":{}}")
        reader.startObject()
        reader.readName()
        let _ = reader.readString()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadArrayExpectedIntThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":[]}")
        reader.startObject()
        reader.readName()
        let _ = reader.readInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderMissingCommaThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":1 \"b\":2}")
        reader.startObject()
        reader.readName()
        reader.readInt64()
        reader.readName()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderMissingColonThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\"1}")
        reader.startObject()
        reader.readName()
        reader.readInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderTrailingCommaThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":1,}")
        reader.startObject()
        reader.readName()
        reader.readInt64()
        if (reader.hasObjectField()) {
            // Trailing comma: hasObjectField returns true but readName will fail
            reader.readName()  // This should throw because there's no name after comma
        }
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderUnbalancedObjectThrows(): Bool {
    try {
        let reader = JsonDirectReader("{\"a\":1")
        reader.startObject()
        reader.readName()
        reader.readInt64()
        reader.endObject()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadFieldOutsideObjectThrows(): Bool {
    try {
        let reader = JsonDirectReader("123")
        let _ = reader.readName()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadInt64OverflowThrows(): Bool {
    try {
        let reader = JsonDirectReader("9223372036854775808")
        let _ = reader.readInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func directReaderReadUInt64NegativeThrows(): Bool {
    try {
        let reader = JsonDirectReader("-1")
        let _ = reader.readUInt64()
        return false
    } catch (_: JsonException) {
        return true
    } catch (_: Exception) {
        return false
    }
}

func makeBytes(text: String): Array<Byte> {
    unsafe {
        text.rawData()
    }
}

// ==================== FastReader Tests ====================

@Test
class FastReaderConstructionTest {

    @TestCase
    func constructFromString(): Unit {
        // Test construction with empty object
        let reader = JsonFastReader("{}")
        reader.startRawObject()
        @Assert(!reader.hasRawObjectField(true))  // No fields in empty object
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func constructFromBytes(): Unit {
        // Test construction with empty object from bytes
        let bytes = makeBytes("{}")
        let reader = JsonFastReader(bytes)
        reader.startRawObject()
        @Assert(!reader.hasRawObjectField(true))
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func byteConstructorValidatesUtf8(): Unit {
        // Valid UTF-8 should work with empty object
        let validBytes = [b'{', b'}']
        let reader = JsonFastReader(validBytes)
        reader.startRawObject()
        @Assert(!reader.hasRawObjectField(true))
        reader.endRawObject()
        reader.expectEnd()
    }
}

@Test
class FastReaderBoundaryNumbersTest {

    @TestCase
    func readMaxInt64(): Unit {
        let reader = JsonFastReader("9223372036854775807")
        let value = reader.readRawInt64()
        @Expect(value, 9223372036854775807)
        reader.expectEnd()
    }

    @TestCase
    func readMinInt64(): Unit {
        let reader = JsonFastReader("-9223372036854775808")
        let value = reader.readRawInt64()
        @Expect(value, -9223372036854775808)
        reader.expectEnd()
    }

    @TestCase
    func readInt64OverflowThrows(): Unit {
        @Expect(fastReaderReadInt64OverflowThrows())
    }

    @TestCase
    func readInt64UnderflowThrows(): Unit {
        @Expect(fastReaderReadInt64UnderflowThrows())
    }

    @TestCase
    func readMaxUInt64(): Unit {
        let reader = JsonFastReader("18446744073709551615")
        let value = reader.readRawUInt64()
        @Expect(value, 18446744073709551615u64)
        reader.expectEnd()
    }

    @TestCase
    func readUInt64OverflowThrows(): Unit {
        @Expect(fastReaderReadUInt64OverflowThrows())
    }

    @TestCase
    func readUInt64NegativeThrows(): Unit {
        @Expect(fastReaderReadUInt64NegativeThrows())
    }

    @TestCase
    func readLargeNumberAsNumberLiteral(): Unit {
        let reader = JsonFastReader("999999999999999999999999999999")
        let literal = reader.readRawNumberLiteral()
        @Expect(literal, "999999999999999999999999999999")
        reader.expectEnd()
    }

    @TestCase
    func readSmallInt32(): Unit {
        let reader = JsonFastReader("2147483647")
        let value = reader.readRawInt32()
        @Expect(value, 2147483647)
        reader.expectEnd()
    }

    @TestCase
    func readMinInt32(): Unit {
        let reader = JsonFastReader("-2147483648")
        let value = reader.readRawInt32()
        @Expect(value, -2147483648)
        reader.expectEnd()
    }

    @TestCase
    func readInt32OverflowThrows(): Unit {
        @Expect(fastReaderReadInt32OverflowThrows())
    }
}

@Test
class FastReaderStringTest {

    @TestCase
    func readSimpleString(): Unit {
        let reader = JsonFastReader("\"hello\"")
        let value = reader.readRawString()
        @Expect(value, "hello")
        reader.expectEnd()
    }

    @TestCase
    func readStringWithEscapes(): Unit {
        let reader = JsonFastReader("\"a\\\"b\\\\c\\n\\t\"")
        let value = reader.readRawString()
        @Expect(value, "a\"b\\c\n\t")
        reader.expectEnd()
    }

    @TestCase
    func readStringWithUnicodeEscape(): Unit {
        let reader = JsonFastReader("\"\\u0041\\u4e2d\"")
        let value = reader.readRawString()
        @Expect(value, "A中")
        reader.expectEnd()
    }

    @TestCase
    func readEmptyString(): Unit {
        let reader = JsonFastReader("\"\"")
        let value = reader.readRawString()
        @Expect(value, "")
        reader.expectEnd()
    }

    @TestCase
    func skipRawString(): Unit {
        // Test skipping a string value in an object
        let reader = JsonFastReader("{\"a\":\"ignored\"}")
        reader.startRawObject()
        @Assert(reader.hasRawObjectField(true))
        // Read the field name (this also handles the colon)
        let name = reader.readRawName(true)
        @Expect(name, "a")
        // Skip the string value
        reader.skipRawString()  // Skip the value "ignored"
        @Assert(!reader.hasRawObjectField(false))
        reader.endRawObject()
        reader.expectEnd()
    }
}

@Test
class FastReaderFieldMatchingTest {

    @TestCase
    func unknownNamesStillValidateJsonStringGrammar(): Unit {
        let control: Array<Byte> = [b'{', b'"', 0x01u8, b'"', b':', b'1', b'}']
        let controlReader = JsonFastReader(control)
        controlReader.startRawObject()
        let controlError = @AssertThrows[JsonException](
            controlReader.readRawNameIdBytes(true, unsafe { [makeBytes("known")] }))
        @Expect(controlError.code, "parse_error")
        @Expect(controlError.location.getOrThrow().byteOffset >= 0)

        let invalidUtf8: Array<Byte> = [b'{', b'"', 0xC3u8, b'(', b'"', b':', b'1', b'}']
        let utf8Reader = JsonFastReader(invalidUtf8)
        utf8Reader.startRawObject()
        let utf8Error = @AssertThrows[JsonException](
            utf8Reader.readRawNameIdBytes(true, unsafe { [makeBytes("known")] }))
        @Expect(utf8Error.code, "parse_error")
        @Expect(utf8Error.location.getOrThrow().byteOffset >= 0)
    }

    @TestCase
    func readRawNameIdBytesMatch(): Unit {
        let reader = JsonFastReader("{\"field\":1}")
        reader.startRawObject()
        @Assert(reader.hasRawObjectField(true))
        let candidates = unsafe { [makeBytes("field")] }
        let id = reader.readRawNameIdBytes(true, candidates)
        @Expect(id, 0)
        let value = reader.readRawInt64()
        @Expect(value, 1)
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func readRawNameIdBytesNoMatch(): Unit {
        let reader = JsonFastReader("{\"other\":1}")
        reader.startRawObject()
        @Assert(reader.hasRawObjectField(true))
        let candidates = unsafe { [makeBytes("field")] }
        let id = reader.readRawNameIdBytes(true, candidates)
        @Expect(id, -1)
        // When no match, must skip the value
        reader.skipRaw()  // Skip the value
        @Assert(!reader.hasRawObjectField(false))
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func readRawNameIdBytesMultipleCandidates(): Unit {
        let reader = JsonFastReader("{\"second\":1}")
        reader.startRawObject()
        @Assert(reader.hasRawObjectField(true))
        let candidates = unsafe {
            [makeBytes("first"), makeBytes("second"), makeBytes("third")]
        }
        let id = reader.readRawNameIdBytes(true, candidates)
        @Expect(id, 1)
        let value = reader.readRawInt64()
        @Expect(value, 1)
        @Assert(!reader.hasRawObjectField(false))
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func currentRawNameEquals(): Unit {
        let reader = JsonFastReader("{\"test\":1}")
        reader.startRawObject()
        @Assert(reader.hasRawObjectField(true))
        let name = reader.readRawName(true)
        @Expect(name, "test")
        // Must read the value after reading name
        let value = reader.readRawInt64()
        @Expect(value, 1)
        @Assert(!reader.hasRawObjectField(false))
        reader.endRawObject()
        reader.expectEnd()
    }
}

@Test
class FastReaderArrayTest {

    @TestCase
    func readEmptyArray(): Unit {
        let reader = JsonFastReader("[]")
        reader.startRawArray()
        @Expect(!reader.hasRawArrayItem(true))
        reader.endRawArray()
        reader.expectEnd()
    }

    @TestCase
    func readSingleItemArray(): Unit {
        let reader = JsonFastReader("[1]")
        reader.startRawArray()
        @Assert(reader.hasRawArrayItem(true))
        let value = reader.readRawInt64()
        @Expect(value, 1)
        @Expect(!reader.hasRawArrayItem(false))
        reader.endRawArray()
        reader.expectEnd()
    }

    @TestCase
    func readMultipleItemArray(): Unit {
        let reader = JsonFastReader("[1,2,3]")
        reader.startRawArray()
        reader.beforeRawArrayItem(true)  // Prepare for first item
        let first = reader.readRawInt64()
        @Expect(first, 1)
        reader.beforeRawArrayItem(false)  // Prepare for second item (expect comma)
        let second = reader.readRawInt64()
        @Expect(second, 2)
        reader.beforeRawArrayItem(false)  // Prepare for third item
        let third = reader.readRawInt64()
        @Expect(third, 3)
        @Expect(!reader.hasRawArrayItem(false))
        reader.endRawArray()
        reader.expectEnd()
    }

    @TestCase
    func readMixedTypeArray(): Unit {
        let reader = JsonFastReader("[1,\"text\",true,null]")
        reader.startRawArray()
        reader.beforeRawArrayItem(true)
        let num = reader.readRawInt64()
        @Expect(num, 1)
        reader.beforeRawArrayItem(false)
        let str = reader.readRawString()
        @Expect(str, "text")
        reader.beforeRawArrayItem(false)
        let bool = reader.readRawBool()
        @Expect(bool, true)
        reader.beforeRawArrayItem(false)
        @Assert(reader.tryReadRawNull())
        @Expect(!reader.hasRawArrayItem(false))
        reader.endRawArray()
        reader.expectEnd()
    }
}

// ==================== DirectReader Tests ====================

@Test
class DirectReaderObjectStructureTest {

    @TestCase
    func readEmptyObject(): Unit {
        let reader = JsonDirectReader("{}")
        reader.startObject()
        @Expect(!reader.hasObjectField())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readSingleFieldObject(): Unit {
        let reader = JsonDirectReader("{\"a\":1}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        let name = reader.readName()
        @Expect(name, "a")
        let value = reader.readInt64()
        @Expect(value, 1)
        @Expect(!reader.hasObjectField())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readMultipleFieldObject(): Unit {
        let reader = JsonDirectReader("{\"a\":1,\"b\":2,\"c\":3}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "a")
        @Expect(reader.readInt64(), 1)
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "b")
        @Expect(reader.readInt64(), 2)
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "c")
        @Expect(reader.readInt64(), 3)
        @Expect(!reader.hasObjectField())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readNameIdMatch(): Unit {
        let reader = JsonDirectReader("{\"target\":42}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        let id = reader.readNameId(["first", "target", "third"])
        @Expect(id, 1)
        let value = reader.readInt64()
        @Expect(value, 42)
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readNameIdNoMatch(): Unit {
        let reader = JsonDirectReader("{\"unknown\":42}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        let id = reader.readNameId(["first", "target", "third"])
        @Expect(id, -1)
        reader.skipValue()
        reader.endObject()
        reader.expectEnd()
    }
}

@Test
class DirectReaderArrayStructureTest {

    @TestCase
    func readEmptyArray(): Unit {
        let reader = JsonDirectReader("[]")
        reader.startArray()
        @Expect(!reader.hasArrayItem())
        reader.endArray()
        reader.expectEnd()
    }

    @TestCase
    func readSingleItemArray(): Unit {
        let reader = JsonDirectReader("[1]")
        reader.startArray()
        @Assert(reader.hasArrayItem())
        let value = reader.readInt64()
        @Expect(value, 1)
        @Expect(!reader.hasArrayItem())
        reader.endArray()
        reader.expectEnd()
    }

    @TestCase
    func readMultipleItemArray(): Unit {
        let reader = JsonDirectReader("[1,2,3]")
        reader.startArray()
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 1)
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 2)
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 3)
        @Expect(!reader.hasArrayItem())
        reader.endArray()
        reader.expectEnd()
    }
}

@Test
class DirectReaderTypeMismatchTest {

    @TestCase
    func stringExpectedNumberThrows(): Unit {
        @Expect(directReaderReadStringExpectedNumberThrows())
    }

    @TestCase
    func numberExpectedStringThrows(): Unit {
        @Expect(directReaderReadNumberExpectedStringThrows())
    }

    @TestCase
    func boolExpectedNumberThrows(): Unit {
        @Expect(directReaderReadBoolExpectedNumberThrows())
    }

    @TestCase
    func objectExpectedStringThrows(): Unit {
        @Expect(directReaderReadObjectExpectedStringThrows())
    }

    @TestCase
    func arrayExpectedIntThrows(): Unit {
        @Expect(directReaderReadArrayExpectedIntThrows())
    }
}

@Test
class DirectReaderNullHandlingTest {

    @TestCase
    func readNull(): Unit {
        let reader = JsonDirectReader("{\"a\":null}")
        reader.startObject()
        reader.readName()
        reader.readNull()
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func tryReadNullReturnsTrue(): Unit {
        let reader = JsonDirectReader("{\"a\":null}")
        reader.startObject()
        reader.readName()
        @Assert(reader.tryReadNull())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func tryReadNullReturnsFalseForValue(): Unit {
        let reader = JsonDirectReader("{\"a\":123}")
        reader.startObject()
        reader.readName()
        @Expect(!reader.tryReadNull())
        let value = reader.readInt64()
        @Expect(value, 123)
        reader.endObject()
        reader.expectEnd()
    }
}

@Test
class DirectReaderNestedStructureTest {

    @TestCase
    func readNestedObject(): Unit {
        let reader = JsonDirectReader("{\"outer\":{\"inner\":42}}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "outer")
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "inner")
        @Expect(reader.readInt64(), 42)
        @Expect(!reader.hasObjectField())
        reader.endObject()
        @Expect(!reader.hasObjectField())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readNestedArray(): Unit {
        let reader = JsonDirectReader("{\"items\":[1,2,3]}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "items")
        reader.startArray()
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 1)
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 2)
        @Assert(reader.hasArrayItem())
        @Expect(reader.readInt64(), 3)
        @Expect(!reader.hasArrayItem())
        reader.endArray()
        @Expect(!reader.hasObjectField())
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func readArrayOfObjects(): Unit {
        let reader = JsonDirectReader("[{\"a\":1},{\"b\":2}]")
        reader.startArray()
        @Assert(reader.hasArrayItem())
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "a")
        @Expect(reader.readInt64(), 1)
        @Expect(!reader.hasObjectField())
        reader.endObject()
        @Assert(reader.hasArrayItem())
        reader.startObject()
        @Assert(reader.hasObjectField())
        @Expect(reader.readName(), "b")
        @Expect(reader.readInt64(), 2)
        @Expect(!reader.hasObjectField())
        reader.endObject()
        @Expect(!reader.hasArrayItem())
        reader.endArray()
        reader.expectEnd()
    }

    @TestCase
    func readDeepNesting(): Unit {
        // 5 levels of nesting
        let reader = JsonDirectReader("{\"l1\":{\"l2\":{\"l3\":{\"l4\":{\"l5\":42}}}}}")
        reader.startObject()
        reader.readName()
        reader.startObject()
        reader.readName()
        reader.startObject()
        reader.readName()
        reader.startObject()
        reader.readName()
        reader.startObject()
        reader.readName()
        @Expect(reader.readInt64(), 42)
        reader.endObject()
        reader.endObject()
        reader.endObject()
        reader.endObject()
        reader.endObject()
        reader.expectEnd()
    }
}

@Test
class DirectReaderSkipValueTest {

    @TestCase
    func skipStringValue(): Unit {
        let reader = JsonDirectReader("{\"a\":\"ignored\",\"b\":2}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readInt64(), 2)
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipNumberValue(): Unit {
        let reader = JsonDirectReader("{\"a\":123,\"b\":\"text\"}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readString(), "text")
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipObjectValue(): Unit {
        let reader = JsonDirectReader("{\"a\":{\"nested\":1},\"b\":2}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readInt64(), 2)
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipArrayValue(): Unit {
        let reader = JsonDirectReader("{\"a\":[1,2,3],\"b\":4}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readInt64(), 4)
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipNullValue(): Unit {
        let reader = JsonDirectReader("{\"a\":null,\"b\":5}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readInt64(), 5)
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipBoolValue(): Unit {
        let reader = JsonDirectReader("{\"a\":true,\"b\":false}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func skipComplexNestedValue(): Unit {
        let reader = JsonDirectReader("{\"a\":{\"x\":1,\"y\":{\"z\":2}},\"b\":3}")
        reader.startObject()
        @Assert(reader.hasObjectField())
        reader.readName()
        reader.skipValue()
        @Assert(reader.hasObjectField())
        reader.readName()
        @Expect(reader.readInt64(), 3)
        reader.endObject()
        reader.expectEnd()
    }
}

@Test
class DirectReaderErrorHandlingTest {

    @TestCase
    func missingCommaBetweenFieldsThrows(): Unit {
        @Expect(directReaderMissingCommaThrows())
    }

    @TestCase
    func missingColonThrows(): Unit {
        @Expect(directReaderMissingColonThrows())
    }

    @TestCase
    func trailingCommaThrows(): Unit {
        @Expect(directReaderTrailingCommaThrows())
    }

    @TestCase
    func unbalancedObjectThrows(): Unit {
        @Expect(directReaderUnbalancedObjectThrows())
    }

    @TestCase
    func readFieldOutsideObjectThrows(): Unit {
        @Expect(directReaderReadFieldOutsideObjectThrows())
    }

    @TestCase
    func readInt64OverflowThrows(): Unit {
        @Expect(directReaderReadInt64OverflowThrows())
    }

    @TestCase
    func readUInt64NegativeThrows(): Unit {
        @Expect(directReaderReadUInt64NegativeThrows())
    }
}
