package yjson

import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonPatchCovRound3FastReaderTest {

    @TestCase
    func fastInt64JunkAndOverflowBranches(): Unit {
        // readRawInt64Fast: trailing junk and both overflow magnitudes fall
        // back to the checked parser which throws.
        let junk = GeneratedSupportV1.newFastReader("[-]")
        let junkCursor = GeneratedSupportV1.readCursor(junk)
        junkCursor.startRawArray()
        let junkErr = @AssertThrows[JsonException](junkCursor.readRawInt64Fast())
        @Expect(junkErr.code, "parse_error")

        let overflow = GeneratedSupportV1.newFastReader("[9223372036854775808]")
        let overflowCursor = GeneratedSupportV1.readCursor(overflow)
        overflowCursor.startRawArray()
        @AssertThrows[JsonException](overflowCursor.readRawInt64Fast())

        let negOverflow = GeneratedSupportV1.newFastReader("[-9223372036854775809]")
        let negCursor = GeneratedSupportV1.readCursor(negOverflow)
        negCursor.startRawArray()
        @AssertThrows[JsonException](negCursor.readRawInt64Fast())
    }

    @TestCase
    func fastUInt64FallbackBranches(): Unit {
        // readRawUInt64Fast: leading minus, overflow, and junk all fall back
        // to the checked parser.
        let neg = GeneratedSupportV1.newFastReader("[-5]")
        let negCursor = GeneratedSupportV1.readCursor(neg)
        negCursor.startRawArray()
        let negErr = @AssertThrows[JsonException](negCursor.generatedReaderV1().readRawUInt64Fast())
        @Expect(negErr.code, "parse_error")

        let big = GeneratedSupportV1.newFastReader("[18446744073709551616]")
        let bigCursor = GeneratedSupportV1.readCursor(big)
        bigCursor.startRawArray()
        @AssertThrows[JsonException](bigCursor.generatedReaderV1().readRawUInt64Fast())

        // Junk suffix does not throw in the fast path; it is accepted by the
        // checked parser and the trailing junk is caught by expectEnd.
        let junk = GeneratedSupportV1.newFastReader("[12x]")
        let junkCursor = GeneratedSupportV1.readCursor(junk)
        junkCursor.startRawArray()
        @Expect(junkCursor.generatedReaderV1().readRawUInt64Fast(), 12)
        @AssertThrows[JsonException](junk.expectEnd())
    }

    @TestCase
    func fastScalarAndFloatFallbackBranches(): Unit {
        // readRawBoolFast rejects a non-boolean token.
        let badBool = GeneratedSupportV1.newFastReader("[1]")
        let boolCursor = GeneratedSupportV1.readCursor(badBool)
        boolCursor.startRawArray()
        let boolErr = @AssertThrows[JsonException](boolCursor.readRawBoolFast())
        @Expect(boolErr.code, "parse_error")

        // readRawStringFast: unterminated string falls back and throws.
        let badStr = GeneratedSupportV1.newFastReader("[\"abc]")
        let strCursor = GeneratedSupportV1.readCursor(badStr)
        strCursor.startRawArray()
        let strErr = @AssertThrows[JsonException](strCursor.generatedReaderV1().readRawStringFast())
        @Expect(strErr.code, "parse_error")

        // Escaped string round trips through the fast reader.
        let escStr = GeneratedSupportV1.newFastReader("[\"a\\nb\",\"c\"]")
        let escCursor = GeneratedSupportV1.readCursor(escStr)
        escCursor.startRawArray()
        @Expect(escCursor.generatedReaderV1().readRawStringFast(), "a\nb")
        escCursor.beforeRawArrayItemFast(false)
        @Expect(escCursor.generatedReaderV1().readRawStringFast(), "c")
        escCursor.endRawArray()
        escStr.expectEnd()

        // Exponent number falls back to Float64.parse.
        let exp = GeneratedSupportV1.newFastReader("[1e2,3]")
        let expCursor = GeneratedSupportV1.readCursor(exp)
        expCursor.startRawArray()
        @Expect(expCursor.generatedReaderV1().readRawFloat64Fast(), 100.0)
        expCursor.beforeRawArrayItemFast(false)
        @Expect(expCursor.readRawInt64Fast(), 3)
        expCursor.endRawArray()
        exp.expectEnd()

        // Happy-path Int64 fast traversal with Fast item loops.
        let happy = GeneratedSupportV1.newFastReader("[42,7]")
        let happyCursor = GeneratedSupportV1.readCursor(happy)
        happyCursor.startRawArray()
        @Expect(happyCursor.hasRawArrayItemFast(true), true)
        @Expect(happyCursor.readRawInt64Fast(), 42)
        // hasRawArrayItemFast checks the comma; beforeRawArrayItemFast
        // consumes it, so the item loop checks first and then advances.
        @Expect(happyCursor.hasRawArrayItemFast(false), true)
        happyCursor.beforeRawArrayItemFast(false)
        @Expect(happyCursor.readRawInt64Fast(), 7)
        @Expect(happyCursor.hasRawArrayItemFast(false), false)
        happyCursor.endRawArray()
        happy.expectEnd()
    }

    @TestCase
    func compactBodyMapArrayFallbackBranches(): Unit {
        // tryReadRawInt64MapCompactBody rejection branches fall back to the
        // checked parser: whitespace, escaped names, non-int values, missing
        // colon, unterminated input.
        let spacedMap = GeneratedSupportV1.newFastReader("{ \"a\" : 1}")
        let spacedMapV = GeneratedSupportV1.readCursor(spacedMap).readRawInt64MapFast()
        @Expect(spacedMapV.size, 1)
        spacedMap.expectEnd()

        let escaped = GeneratedSupportV1.newFastReader("{\"a\\u0062\":1}")
        let escapedV = GeneratedSupportV1.readCursor(escaped).readRawInt64MapFast()
        @Expect(escapedV["ab"], 1)
        escaped.expectEnd()

        let nonInt = GeneratedSupportV1.newFastReader("{\"a\":1.5}")
        let nonIntErr = @AssertThrows[JsonException](
            GeneratedSupportV1.readCursor(nonInt).readRawInt64MapFast())
        @Expect(nonIntErr.code, "invalid_value")

        let noColon = GeneratedSupportV1.newFastReader("{\"a\" 1}")
        let noColonErr = @AssertThrows[JsonException](
            GeneratedSupportV1.readCursor(noColon).readRawInt64MapFast())
        @Expect(noColonErr.code, "parse_error")

        let unterminated = GeneratedSupportV1.newFastReader("{\"a\":1")
        let unterErr = @AssertThrows[JsonException](
            GeneratedSupportV1.readCursor(unterminated).readRawInt64MapFast())
        @Expect(unterErr.code, "parse_error")

        // tryReadRawInt64ArrayCompactBody fallback to checked array reads.
        let spacedArr = GeneratedSupportV1.newFastReader("[ 1 ]")
        let spacedArrV = GeneratedSupportV1.readCursor(spacedArr).readRawInt64ArrayFast()
        @Expect(spacedArrV.size, 1)
        spacedArr.expectEnd()

        let badArr = GeneratedSupportV1.newFastReader("[1.5]")
        let badArrErr = @AssertThrows[JsonException](
            GeneratedSupportV1.readCursor(badArr).readRawInt64ArrayFast())
        @Expect(badArrErr.code, "invalid_value")

        // tryReadRawInt64ArrayMapCompactBody fallback to checked array-map
        // reads.
        let spacedAm = GeneratedSupportV1.newFastReader("{ \"a\" : [1] }")
        let spacedAmV = GeneratedSupportV1.readCursor(spacedAm).readRawInt64ArrayMapFast()
        @Expect(spacedAmV.size, 1)
        spacedAm.expectEnd()

        let badAm = GeneratedSupportV1.newFastReader("{\"a\":[1.5]}")
        @AssertThrows[JsonException](
            GeneratedSupportV1.readCursor(badAm).readRawInt64ArrayMapFast())
    }

    @TestCase
    func narrowIntRangeErrorBranches(): Unit {
        // Range checks on the narrow integer readers.
        let r32 = GeneratedSupportV1.newFastReader("[4000000000]")
        let c32 = GeneratedSupportV1.readCursor(r32)
        c32.startRawArray()
        let e32 = @AssertThrows[JsonException](c32.generatedReaderV1().readRawInt32())
        @Expect(e32.code, "number_out_of_range")

        let r16 = GeneratedSupportV1.newFastReader("[40000]")
        let c16 = GeneratedSupportV1.readCursor(r16)
        c16.startRawArray()
        let e16 = @AssertThrows[JsonException](c16.generatedReaderV1().readRawInt16())
        @Expect(e16.code, "number_out_of_range")

        let r8 = GeneratedSupportV1.newFastReader("[200]")
        let c8 = GeneratedSupportV1.readCursor(r8)
        c8.startRawArray()
        let e8 = @AssertThrows[JsonException](c8.generatedReaderV1().readRawInt8())
        @Expect(e8.code, "number_out_of_range")

        let ru32 = GeneratedSupportV1.newFastReader("[4294967296]")
        let cu32 = GeneratedSupportV1.readCursor(ru32)
        cu32.startRawArray()
        let eu32 = @AssertThrows[JsonException](cu32.generatedReaderV1().readRawUInt32())
        @Expect(eu32.code, "number_out_of_range")

        let ru16 = GeneratedSupportV1.newFastReader("[70000]")
        let cu16 = GeneratedSupportV1.readCursor(ru16)
        cu16.startRawArray()
        let eu16 = @AssertThrows[JsonException](cu16.generatedReaderV1().readRawUInt16())
        @Expect(eu16.code, "number_out_of_range")

        let ru8 = GeneratedSupportV1.newFastReader("[300]")
        let cu8 = GeneratedSupportV1.readCursor(ru8)
        cu8.startRawArray()
        let eu8 = @AssertThrows[JsonException](cu8.generatedReaderV1().readRawUInt8())
        @Expect(eu8.code, "number_out_of_range")
    }

    @TestCase
    func objectFieldWhitespaceBranches(): Unit {
        // hasRawObjectFieldFast / readRawNameFast with spaced objects and
        // multiple fields (non-compact whitespace paths).
        let object = GeneratedSupportV1.newFastReader("{ \"a\" : 1, \"b\" : 2 }")
        let cursor = GeneratedSupportV1.readCursor(object)
        cursor.startRawObject()
        @Expect(cursor.hasRawObjectFieldFast(true), true)
        @Expect(cursor.readRawName(true), "a")
        @Expect(cursor.readRawInt64(), 1)
        @Expect(cursor.hasRawObjectFieldFast(false), true)
        @Expect(cursor.readRawName(false), "b")
        @Expect(cursor.readRawInt64(), 2)
        @Expect(cursor.hasRawObjectFieldFast(false), false)
        cursor.endRawObject()
        object.expectEnd()
    }

    @TestCase
    func skipPolicyAwareGrowthBranch(): Unit {
        // skipValue with duplicate-key rejection grows skipSeenNames beyond
        // the initial capacity (17 keys).
        let big = GeneratedSupportV1.newFastReader(
            "{\"k0\":0,\"k1\":1,\"k2\":2,\"k3\":3,\"k4\":4,\"k5\":5,\"k6\":6,\"k7\":7," +
            "\"k8\":8,\"k9\":9,\"k10\":10,\"k11\":11,\"k12\":12,\"k13\":13,\"k14\":14," +
            "\"k15\":15,\"k16\":16}")
        let bigCursor = GeneratedSupportV1.readCursor(big)
        bigCursor.generatedReaderV1().skipValue(64)
        big.expectEnd()
    }
}
