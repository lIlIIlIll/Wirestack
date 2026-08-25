package yjson

import std.convert.Parsable
import std.math.numeric.*
import std.time.*

private func allJsonRawNameCandidatesAscii(candidates: Array<Array<Byte>>): Bool {
    for (candidate in candidates) {
        for (byte in candidate) {
            if (byte >= 0x80) {
                return false
            }
        }
    }
    true
}

private func initialJsonRawNameMatchMask(size: Int64): UInt64 {
    var mask = 0u64
    for (candidateIndex in 0..size) {
        mask |= 1u64 << candidateIndex
    }
    mask
}

private let YJSON_NATIVE_SKIP_MIN_REMAINING_BYTES: Int64 = 128
private let YJSON_RAW_NUMBER_SMALL_DIGITS: Int64 = 18

class JsonRawNameMatcher {
    public let candidates: Array<Array<Byte>>
    public let useAsciiFastPath: Bool
    public let initialMask: UInt64

    public init(candidates: Array<Array<Byte>>) {
        this.candidates = candidates
        this.useAsciiFastPath = candidates.size <= 63 && allJsonRawNameCandidatesAscii(candidates)
        this.initialMask = if (useAsciiFastPath) {
            initialJsonRawNameMatchMask(candidates.size)
        } else {
            0u64
        }
    }
}

// Package-internal object-key representation used by CompactJsonDocument.
// A no-escape key retains only its validated source range; escaped keys keep
// the decoded semantic String so raw spellings such as "a" and "\u0061"
// still compare as the same JSON member name.
struct JsonObjectKeyView {
    let sourceStart: Int64
    let sourceLength: Int64
    let owned: Option<String>

    init(sourceStart: Int64, sourceLength: Int64) {
        this.sourceStart = sourceStart
        this.sourceLength = sourceLength
        this.owned = None<String>
    }

    init(value: String) {
        this.sourceStart = -1
        this.sourceLength = 0
        this.owned = Some(value)
    }

    func isSource(): Bool { sourceStart >= 0 }
}

public class JsonFastReader {
    private let data: Array<Byte>
    private let size: Int64
    private let validateStrings: Bool
    private let sourceText: Option<String>
    private var index: Int64 = 0
    private var rawNameStart: Int64 = 0
    private var rawNameEnd: Int64 = 0
    private var rawNameSize: Int64 = 0
    private var rawNameFirst: Byte = 0
    private var rawTokenStart: Int64 = 0
    private var rawTokenEnd: Int64 = 0
    private var rawTokenNumberDigitCount: Int64 = 0
    private var rawTokenNumberScale: Int64 = 0
    private var rawTokenNumberSmallUnscaled: Int64 = 0
    private var rawTokenNumberSmallUnscaledValid = true
    private var rawTokenNumberNegative = false
    private var rawTokenNumberHasExponent = false
    private var rawTokenNumberHasNonZero = false
    private var rawDateTimeCacheEpochSecond: Int64 = 0
    private var rawDateTimeCacheOffsetSeconds: Int64 = 0
    private var rawDateTimeCacheValue: Option<DateTime> = None<DateTime>

    public init(text: String) {
        unsafe {
            data = text.rawData()
        }
        size = data.size
        validateStrings = false
        sourceText = Some(text)
    }

    public init(bytes: Array<Byte>) {
        data = bytes
        size = bytes.size
        validateStrings = true
        sourceText = None<String>
    }

    public func expectEnd(): Unit {
        skipSpaces()
        if (hasMore()) {
            fail("Unexpected trailing input")
        }
    }

    // Package consumers such as CompactJsonDocument need only the semantic
    // token kind; exposing it avoids duplicating whitespace and token-start
    // validation while keeping the reader cursor and source private.
    public func peekRawKind(): JsonKind {
        skipSpaces()
        if (!hasMore()) { fail("Unexpected end of JSON input") }
        match (peek()) {
            case b'n' => JsNull
            case b't' | b'f' => JsBool
            case b'"' => JsString
            case b'[' => JsArray
            case b'{' => JsObject
            case b'-' | b'0' | b'1' | b'2' | b'3' | b'4' | b'5' | b'6' | b'7' | b'8' | b'9' => JsNumberLiteral
            case _ => fail("Unexpected token")
        }
    }

    func position(): Int64 {
        index
    }

    func rewind(position: Int64): Unit {
        index = position
    }

    func tryEndRawObject(): Bool {
        if (hasMore() && peek() == b'}') {
            index++
            return true
        }
        false
    }

    func tryStartRawObjectCompact(): Bool {
        skipSpaces()
        if (hasMore() && peek() == b'{') {
            index++
            return true
        }
        false
    }

    func tryNextRawObjectFieldCompact(first: Bool): Bool {
        if (!hasMore()) {
            return false
        }
        let current = peek()
        if (current == b' ' || current == b'\n' || current == b'\r' || current == b'\t' || current == b'}') {
            return false
        }
        if (first) {
            return true
        }
        if (current != b',') {
            return false
        }
        index++
        true
    }

    // Generated-code bridge for the allocation-free ordered object path.  It
    // consumes only an exact compact `"name":` token (and the comma when this
    // is not the first field).  A miss is transactional so generated codecs
    // can immediately continue with the general name dispatcher.
    public func tryReadRawCompactNameTokenBytes(
        first: Bool,
        expectedNameBytes: Array<Byte>
    ): Bool {
        tryReadRawAsciiNameTokenBytes(expectedNameBytes, first)
    }

    func tryReadRawAsciiNameTokenBytes(nameBytes: Array<Byte>, first: Bool): Bool {
        var currentIndex = index
        if (!first) {
            if (currentIndex >= size || data[currentIndex] != b',') {
                return false
            }
            currentIndex++
        }
        if (currentIndex + nameBytes.size + 3 > size || data[currentIndex] != b'"') {
            return false
        }
        currentIndex++
        for (offset in 0..nameBytes.size) {
            if (data[currentIndex + offset] != nameBytes[offset]) {
                return false
            }
        }
        currentIndex += nameBytes.size
        if (data[currentIndex] != b'"' || data[currentIndex + 1] != b':') {
            return false
        }
        index = currentIndex + 2
        true
    }

    func tryReadRawObjectStartAsciiNameTokenBytes(nameBytes: Array<Byte>): Bool {
        var currentIndex = index
        if (currentIndex + nameBytes.size + 4 > size ||
            data[currentIndex] != b'{' ||
            data[currentIndex + 1] != b'"') {
            return false
        }
        currentIndex += 2
        for (offset in 0..nameBytes.size) {
            if (data[currentIndex + offset] != nameBytes[offset]) {
                return false
            }
        }
        currentIndex += nameBytes.size
        if (data[currentIndex] != b'"' || data[currentIndex + 1] != b':') {
            return false
        }
        index = currentIndex + 2
        true
    }

    public func startRawObject(): Unit {
        skipSpaces()
        expectByte(b'{')
    }

    func suggestRawObjectCapacity(): Int64 {
        suggestContainerCapacity(48)
    }

    public func endRawObject(): Unit {
        skipSpaces()
        expectByte(b'}')
    }

    public func hasRawObjectField(first: Bool): Bool {
        skipSpaces()
        let _ = first
        hasMore() && peek() != b'}'
    }

    func nextRawObjectField(first: Bool): Bool {
        if (first) {
            if (hasMore()) {
                let current = peek()
                if (current == b'}') {
                    return false
                }
                if (!isJsonSpace(current)) {
                    return true
                }
            }
        } else if (hasMore() && peek() == b',') {
            index++
            if (hasMore() && !isJsonSpace(peek())) {
                return true
            }
            skipSpaces()
            return true
        }
        skipSpaces()
        if (hasMore() && peek() == b'}') {
            return false
        }
        if (!first) {
            expectByte(b',')
            skipSpaces()
        }
        true
    }

    func startRawObjectFields(): Bool {
        startRawObject()
        skipSpaces()
        hasMore() && peek() != b'}'
    }

    func nextRawObjectFieldAfterValue(): Bool {
        if (hasMore() && peek() == b',') {
            index++
            if (hasMore() && !isJsonSpace(peek())) {
                return true
            }
            skipSpaces()
            return true
        }
        skipSpaces()
        if (hasMore() && peek() == b'}') {
            return false
        }
        expectByte(b',')
        skipSpaces()
        true
    }

    public func readRawName(first: Bool): String {
        beforeRawFieldName(first)
        let name = parseString()
        afterRawFieldName()
        name
    }

    // Compact-only seam: unlike readRawName(), the common no-escape path does
    // not materialize a transient String and does not need a later reverse
    // scan to recover the source range.
    func readRawObjectKeyView(first: Bool): JsonObjectKeyView {
        beforeRawFieldName(first)
        expectByte(b'"')
        let start = index
        var ascii = true
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                let end = index
                index++
                afterRawFieldName()
                return JsonObjectKeyView(start, end - start)
            }
            if (current == b'\\') {
                let value = parseEscapedString(start, ascii)
                afterRawFieldName()
                return JsonObjectKeyView(value)
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            if (current >= 0x80) {
                ascii = false
                if (validateStrings) {
                    index += validatedUtf8WidthAt(index)
                    continue
                }
            }
            index++
        }
        fail("Unterminated string literal")
    }

    public func readRawNameIdBytes(first: Bool, candidates: Array<Array<Byte>>): Int64 {
        beforeRawFieldName(first)
        let id = match (tryParseSimpleNameId(candidates)) {
            case Some(value) => value
            case None => parseNameIdBytes(candidates)
        }
        afterRawFieldName()
        id
    }

    func readRawNameId(first: Bool, matcher: JsonRawNameMatcher): Int64 {
        beforeRawFieldName(first)
        let id = parseNameId(matcher)
        afterRawFieldName()
        id
    }

    func readRawNameAfterSeparator(): String {
        let name = parseString()
        afterRawFieldName()
        name
    }

    func readRawNameIdAfterSeparator(matcher: JsonRawNameMatcher): Int64 {
        let id = parseNameId(matcher)
        afterRawFieldName()
        id
    }

    func trySkipUnknownRawObjectTail(matcher: JsonRawNameMatcher): Bool {
        let start = index
        var first = false
        while (nextRawObjectField(first)) {
            let nameId = readRawNameIdAfterSeparator(matcher)
            if (nameId >= 0) {
                index = start
                return false
            }
            skipRaw()
            first = false
        }
        endRawObject()
        true
    }

    func trySkipUnknownRawObjectFieldsUntilNameToken(expectedNameId: Int64, matcher: JsonRawNameMatcher): Bool {
        let start = index
        while (nextRawObjectField(false)) {
            let nameId = readRawNameIdAfterSeparator(matcher)
            if (nameId == expectedNameId) {
                return true
            }
            if (nameId >= 0) {
                index = start
                return false
            }
            skipRaw()
        }
        index = start
        false
    }

    func trySkipOneUnknownRawObjectFieldBeforeNameToken(expectedNameBytes: Array<Byte>, matcher: JsonRawNameMatcher): Bool {
        let start = index
        if (!nextRawObjectField(false)) {
            index = start
            return false
        }
        let nameId = readRawNameIdAfterSeparator(matcher)
        if (nameId >= 0) {
            index = start
            return false
        }
        skipRaw()
        if (tryReadRawAsciiNameTokenBytes(expectedNameBytes, false)) {
            return true
        }
        index = start
        false
    }

    func readSimpleRawNameNoHashAfterSeparator(): Bool {
        let start = index
        if (!hasMore() || peek() != b'"') {
            return false
        }
        index++
        rawNameStart = index
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                rawNameEnd = index
                rawNameSize = rawNameEnd - rawNameStart
                rawNameFirst = if (rawNameSize > 0) {
                    data[rawNameStart]
                } else {
                    0
                }
                index++
                afterRawFieldName()
                return true
            }
            if (current == b'\\' || current >= 0x80) {
                index = start
                return false
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            index++
        }
        fail("Unterminated string literal")
    }

    func currentRawNameSize(): Int64 {
        rawNameSize
    }

    func currentRawNameEquals(name: String): Bool {
        if (name.size != rawNameSize) {
            return false
        }
        if (rawNameSize > 0 && rawNameFirst != name[0]) {
            return false
        }
        for (offset in 0..name.size) {
            if (data[rawNameStart + offset] != name[offset]) {
                return false
            }
        }
        true
    }

    func currentRawNameEqualsBytes(nameBytes: Array<Byte>): Bool {
        if (nameBytes.size != rawNameSize) {
            return false
        }
        if (rawNameSize == 0) {
            return true
        }
        if (rawNameFirst != nameBytes[0]) {
            return false
        }
        match (rawNameSize) {
            case 3 =>
                return data[rawNameStart + 1] == nameBytes[1] &&
                    data[rawNameStart + 2] == nameBytes[2]
            case 4 =>
                return data[rawNameStart + 1] == nameBytes[1] &&
                    data[rawNameStart + 2] == nameBytes[2] &&
                    data[rawNameStart + 3] == nameBytes[3]
            case 6 =>
                return data[rawNameStart + 1] == nameBytes[1] &&
                    data[rawNameStart + 2] == nameBytes[2] &&
                    data[rawNameStart + 3] == nameBytes[3] &&
                    data[rawNameStart + 4] == nameBytes[4] &&
                    data[rawNameStart + 5] == nameBytes[5]
            case 7 =>
                return data[rawNameStart + 1] == nameBytes[1] &&
                    data[rawNameStart + 2] == nameBytes[2] &&
                    data[rawNameStart + 3] == nameBytes[3] &&
                    data[rawNameStart + 4] == nameBytes[4] &&
                    data[rawNameStart + 5] == nameBytes[5] &&
                    data[rawNameStart + 6] == nameBytes[6]
            case 11 =>
                return data[rawNameStart + 1] == nameBytes[1] &&
                    data[rawNameStart + 2] == nameBytes[2] &&
                    data[rawNameStart + 3] == nameBytes[3] &&
                    data[rawNameStart + 4] == nameBytes[4] &&
                    data[rawNameStart + 5] == nameBytes[5] &&
                    data[rawNameStart + 6] == nameBytes[6] &&
                    data[rawNameStart + 7] == nameBytes[7] &&
                    data[rawNameStart + 8] == nameBytes[8] &&
                    data[rawNameStart + 9] == nameBytes[9] &&
                    data[rawNameStart + 10] == nameBytes[10]
            case _ => ()
        }
        for (offset in 1..nameBytes.size) {
            if (data[rawNameStart + offset] != nameBytes[offset]) {
                return false
            }
        }
        true
    }

    func currentRawNameByte(offset: Int64): Byte {
        if (offset == 0) {
            return rawNameFirst
        }
        data[rawNameStart + offset]
    }

    func currentRawNameEqualsAscii3(b0: Byte, b1: Byte, b2: Byte): Bool {
        rawNameSize == 3 &&
            rawNameFirst == b0 &&
            data[rawNameStart + 1] == b1 &&
            data[rawNameStart + 2] == b2
    }

    func currentRawNameEqualsAscii4(b0: Byte, b1: Byte, b2: Byte, b3: Byte): Bool {
        rawNameSize == 4 &&
            rawNameFirst == b0 &&
            data[rawNameStart + 1] == b1 &&
            data[rawNameStart + 2] == b2 &&
            data[rawNameStart + 3] == b3
    }

    func currentRawNameEqualsAscii6(b0: Byte, b1: Byte, b2: Byte, b3: Byte, b4: Byte, b5: Byte): Bool {
        rawNameSize == 6 &&
            rawNameFirst == b0 &&
            data[rawNameStart + 1] == b1 &&
            data[rawNameStart + 2] == b2 &&
            data[rawNameStart + 3] == b3 &&
            data[rawNameStart + 4] == b4 &&
            data[rawNameStart + 5] == b5
    }

    func currentRawNameEqualsAscii7(
        b0: Byte,
        b1: Byte,
        b2: Byte,
        b3: Byte,
        b4: Byte,
        b5: Byte,
        b6: Byte
    ): Bool {
        rawNameSize == 7 &&
            rawNameFirst == b0 &&
            data[rawNameStart + 1] == b1 &&
            data[rawNameStart + 2] == b2 &&
            data[rawNameStart + 3] == b3 &&
            data[rawNameStart + 4] == b4 &&
            data[rawNameStart + 5] == b5 &&
            data[rawNameStart + 6] == b6
    }

    func currentRawNameEqualsAscii11(
        b0: Byte,
        b1: Byte,
        b2: Byte,
        b3: Byte,
        b4: Byte,
        b5: Byte,
        b6: Byte,
        b7: Byte,
        b8: Byte,
        b9: Byte,
        b10: Byte
    ): Bool {
        rawNameSize == 11 &&
            rawNameFirst == b0 &&
            data[rawNameStart + 1] == b1 &&
            data[rawNameStart + 2] == b2 &&
            data[rawNameStart + 3] == b3 &&
            data[rawNameStart + 4] == b4 &&
            data[rawNameStart + 5] == b5 &&
            data[rawNameStart + 6] == b6 &&
            data[rawNameStart + 7] == b7 &&
            data[rawNameStart + 8] == b8 &&
            data[rawNameStart + 9] == b9 &&
            data[rawNameStart + 10] == b10
    }

    public func startRawArray(): Unit {
        skipSpaces()
        expectByte(b'[')
    }

    func tryStartRawArrayCompact(): Bool {
        skipSpaces()
        if (hasMore() && peek() == b'[') {
            index++
            return true
        }
        false
    }

    // Capacity hint retained for the existing scalar collection helpers.
    func suggestRawArrayCapacity(): Int64 {
        suggestContainerCapacity(32)
    }

    /// Returns a bounded allocation hint for a raw collection after the array
    /// opener has been consumed. This is public because macro-generated fast
    /// codecs execute in the consumer package. It never advances the cursor or
    /// retains the input; callers must treat the value as a hint, not a size
    /// guarantee.
    public func suggestRawCollectionCapacity(): Int64 {
        let remaining = size - index
        let estimate = remaining / 64 + 1
        if (estimate < 48) {
            return 4
        }
        if (estimate > 64) {
            return 64
        }
        estimate
    }

    public func endRawArray(): Unit {
        skipSpaces()
        expectByte(b']')
    }

    func tryEndRawArrayCompact(): Bool {
        if (hasMore() && peek() == b']') {
            index++
            return true
        }
        false
    }

    public func hasRawArrayItem(first: Bool): Bool {
        skipSpaces()
        let _ = first
        hasMore() && peek() != b']'
    }

    func nextRawArrayItem(first: Bool): Bool {
        if (first) {
            if (hasMore()) {
                let current = peek()
                if (current == b']') {
                    return false
                }
                if (!isJsonSpace(current)) {
                    return true
                }
            }
        } else if (hasMore() && peek() == b',') {
            index++
            if (hasMore() && !isJsonSpace(peek())) {
                return true
            }
            skipSpaces()
            return true
        }
        skipSpaces()
        if (hasMore() && peek() == b']') {
            return false
        }
        if (!first) {
            expectByte(b',')
            skipSpaces()
        }
        true
    }

    func tryNextRawArrayItemCompact(first: Bool): Bool {
        if (!hasMore()) {
            return false
        }
        let current = peek()
        if (current == b' ' || current == b'\n' || current == b'\r' || current == b'\t' || current == b']') {
            return false
        }
        if (first) {
            return true
        }
        if (current != b',') {
            return false
        }
        index++
        true
    }

    func tryNativeArrayElements(): Option<JsonNativeArrayElements> {
        let start = index
        skipSpaces()
        if (!hasMore() || peek() != b'[') {
            index = start
            return None<JsonNativeArrayElements>
        }
        match (jsonNativeScanArrayElementsAtLeast(
            data,
            size,
            index,
            validateStrings,
            YJSON_NATIVE_MIN_ARRAY_SCAN_BYTES,
            YJSON_NATIVE_MIN_ARRAY_ELEMENT_COUNT
        )) {
            case Some(elements) => return Some(elements)
            case None =>
                index = start
                return None<JsonNativeArrayElements>
        }
    }

    func finishNativeArrayElements(elements: JsonNativeArrayElements): Unit {
        index = elements.arrayEnd
    }

    public func beforeRawArrayItem(first: Bool): Unit {
        skipSpaces()
        if (!first) {
            expectByte(b',')
            skipSpaces()
        }
    }

    public func tryReadRawNull(): Bool {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        if (!hasMore() || peek() != b'n') {
            return false
        }
        expectLiteral("null")
        true
    }

    public func readRawBool(): Bool {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        readRawBoolCompact()
    }

    func readRawBoolCompact(): Bool {
        if (peek() == b't') {
            expectLiteral("true")
            return true
        }
        expectLiteral("false")
        false
    }

    public func readRawString(): String {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        readRawStringCompact()
    }

    func readRawStringCompact(): String {
        parseString()
    }

    func tryReadRawAsciiStringToken(): Bool {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        tryReadRawAsciiStringTokenCompact()
    }

    func tryReadRawAsciiStringTokenSize2(firstSize: Int64, secondSize: Int64): Bool {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        tryReadRawAsciiStringTokenSize2Compact(firstSize, secondSize)
    }

    func tryReadRawAsciiStringTokenCompact(): Bool {
        let start = index
        if (!hasMore() || peek() != b'"') {
            return false
        }
        index++
        rawTokenStart = index
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                rawTokenEnd = index
                index++
                return true
            }
            if (current == b'\\' || current >= 0x80) {
                index = start
                return false
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            index++
        }
        fail("Unterminated string literal")
    }

    func tryReadRawAsciiStringTokenSize2Compact(firstSize: Int64, secondSize: Int64): Bool {
        let start = index
        if (!hasMore() || peek() != b'"') {
            return false
        }
        let valueStart = index + 1
        var valueEnd: Int64 = -1
        if (valueStart + firstSize < size && data[valueStart + firstSize] == b'"') {
            valueEnd = valueStart + firstSize
        } else if (valueStart + secondSize < size && data[valueStart + secondSize] == b'"') {
            valueEnd = valueStart + secondSize
        } else {
            return false
        }

        var cursor = valueStart
        while (cursor < valueEnd) {
            let current = data[cursor]
            if (current == b'\\' || current >= 0x80) {
                index = start
                return false
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", cursor)
            }
            cursor++
        }
        rawTokenStart = valueStart
        rawTokenEnd = valueEnd
        index = valueEnd + 1
        true
    }

    public func skipRawString(): Unit {
        skipSpaces()
        scanRawString()
    }

    public func readRawInt64(): Int64 {
        parseInt64Literal()
    }

    func readRawInt64Compact(): Int64 {
        parseInt64LiteralNoSpace()
    }

    public func readRawInt32(): Int32 {
        let value = parseInt64Literal()
        int64ToInt32(value)
    }

    func readRawInt32Compact(): Int32 {
        let value = parseInt64LiteralNoSpace()
        int64ToInt32(value)
    }

    private func int64ToInt32(value: Int64): Int32 {
        if (value < -0x8000_0000 || value > 0x7FFF_FFFF) {
            fail("Integer literal out of Int32 range")
        }
        Int32(value)
    }

    public func readRawInt16(): Int16 {
        let value = parseInt64Literal()
        int64ToInt16(value)
    }

    func readRawInt16Compact(): Int16 {
        let value = parseInt64LiteralNoSpace()
        int64ToInt16(value)
    }

    private func int64ToInt16(value: Int64): Int16 {
        if (value < -0x8000 || value > 0x7FFF) {
            fail("Integer literal out of Int16 range")
        }
        Int16(value)
    }

    public func readRawInt8(): Int8 {
        let value = parseInt64Literal()
        int64ToInt8(value)
    }

    func readRawInt8Compact(): Int8 {
        let value = parseInt64LiteralNoSpace()
        int64ToInt8(value)
    }

    private func int64ToInt8(value: Int64): Int8 {
        if (value < -0x80 || value > 0x7F) {
            fail("Integer literal out of Int8 range")
        }
        Int8(value)
    }

    public func readRawUInt64(): UInt64 {
        parseUInt64Literal()
    }

    func readRawUInt64Compact(): UInt64 {
        parseUInt64LiteralNoSpace()
    }

    public func readRawUInt32(): UInt32 {
        let value = parseUInt64Literal()
        uint64ToUInt32(value)
    }

    func readRawUInt32Compact(): UInt32 {
        let value = parseUInt64LiteralNoSpace()
        uint64ToUInt32(value)
    }

    private func uint64ToUInt32(value: UInt64): UInt32 {
        if (value > 0xFFFF_FFFFu64) {
            fail("Integer literal out of UInt32 range")
        }
        UInt32(value)
    }

    public func readRawUInt16(): UInt16 {
        let value = parseUInt64Literal()
        uint64ToUInt16(value)
    }

    func readRawUInt16Compact(): UInt16 {
        let value = parseUInt64LiteralNoSpace()
        uint64ToUInt16(value)
    }

    private func uint64ToUInt16(value: UInt64): UInt16 {
        if (value > 0xFFFFu64) {
            fail("Integer literal out of UInt16 range")
        }
        UInt16(value)
    }

    public func readRawUInt8(): UInt8 {
        let value = parseUInt64Literal()
        uint64ToUInt8(value)
    }

    func readRawUInt8Compact(): UInt8 {
        let value = parseUInt64LiteralNoSpace()
        uint64ToUInt8(value)
    }

    private func uint64ToUInt8(value: UInt64): UInt8 {
        if (value > 0xFFu64) {
            fail("Integer literal out of UInt8 range")
        }
        UInt8(value)
    }

    public func readRawBigInt(): BigInt {
        BigInt.parse(readRawNumberLiteral())
    }

    public func readRawDecimal(): Decimal {
        Decimal.parse(readRawNumberLiteral())
    }

    public func readRawNumberLiteral(): String {
        parseNumberLiteral()
    }

    func readRawNumberLiteralCompact(): String {
        parseNumberLiteralNoSpace()
    }

    func tryReadRawNumberToken(): Bool {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        tryReadRawNumberTokenCompact()
    }

    func tryReadRawNumberTokenCompact(): Bool {
        if (!hasMore() || !(peek() == b'-' || (peek() >= b'0' && peek() <= b'9'))) {
            return false
        }
        rawTokenStart = index
        scanRawNumberToken()
        rawTokenEnd = index
        true
    }

    func adoptRawNumberToken(start: Int64, end: Int64, magnitude: UInt64, flags: UInt64): Unit {
        rawTokenStart = start
        rawTokenEnd = end
        index = end
        rawTokenNumberNegative = (flags & 1u64) != 0u64
        rawTokenNumberHasExponent = (flags & 2u64) != 0u64
        rawTokenNumberSmallUnscaledValid = (flags & 4u64) != 0u64 && magnitude <= UInt64(Int64.Max)
        rawTokenNumberSmallUnscaled = if (rawTokenNumberSmallUnscaledValid) { Int64(magnitude) } else { 0 }
        rawTokenNumberScale = Int64((flags >> 8) & 0xFFFF_FFFFu64)
        rawTokenNumberDigitCount = 0
        rawTokenNumberHasNonZero = magnitude != 0u64
    }

    private func resetRawNumberTokenShape(): Unit {
        rawTokenNumberDigitCount = 0
        rawTokenNumberScale = 0
        rawTokenNumberSmallUnscaled = 0
        rawTokenNumberSmallUnscaledValid = true
        rawTokenNumberNegative = false
        rawTokenNumberHasExponent = false
        rawTokenNumberHasNonZero = false
    }

    private func recordRawNumberTokenDigit(digit: Int64): Unit {
        rawTokenNumberDigitCount++
        if (digit != 0) {
            rawTokenNumberHasNonZero = true
        }
        if (rawTokenNumberSmallUnscaledValid && rawTokenNumberDigitCount <= YJSON_RAW_NUMBER_SMALL_DIGITS) {
            rawTokenNumberSmallUnscaled = rawTokenNumberSmallUnscaled * 10 + digit
        } else {
            rawTokenNumberSmallUnscaledValid = false
        }
    }

    private func scanRawNumberTokenDigitsAfterRequiredFirst(): Unit {
        while (hasMore() && peek() >= b'0' && peek() <= b'9') {
            recordRawNumberTokenDigit(Int64(consume() - b'0'))
        }
    }

    private func scanRawNumberTokenIntegerDigits(): Unit {
        requireDigit("Expected digit")
        if (peek() == b'0') {
            index++
            recordRawNumberTokenDigit(0)
            rejectLeadingZero()
            return
        }
        scanRawNumberTokenDigitsAfterRequiredFirst()
    }

    private func scanRawNumberToken(): Unit {
        resetRawNumberTokenShape()
        if (hasMore() && peek() == b'-') {
            rawTokenNumberNegative = true
            index++
        }
        scanRawNumberTokenIntegerDigits()
        if (hasMore() && peek() == b'.') {
            index++
            requireDigit("Expected fractional digits")
            while (hasMore() && peek() >= b'0' && peek() <= b'9') {
                recordRawNumberTokenDigit(Int64(consume() - b'0'))
                rawTokenNumberScale++
            }
        }
        if (hasMore() && (peek() == b'e' || peek() == b'E')) {
            rawTokenNumberHasExponent = true
            index++
            if (hasMore() && (peek() == b'+' || peek() == b'-')) {
                index++
            }
            requireDigit("Expected exponent digits")
            consumeDigits()
        }
    }

    func currentRawTokenSize(): Int64 {
        rawTokenEnd - rawTokenStart
    }

    func currentRawTokenData(): Array<Byte> {
        data
    }

    func currentRawTokenStartOffset(): Int64 {
        rawTokenStart
    }

    func currentRawTokenByte(offset: Int64): Byte {
        data[rawTokenStart + offset]
    }

    func currentRawTokenDigit(offset: Int64): Int64 {
        let value = data[rawTokenStart + offset]
        if (value < b'0' || value > b'9') {
            return -1
        }
        Int64(value - b'0')
    }

    func currentRawTokenTwoDigits(offset: Int64): Int64 {
        let first = currentRawTokenDigit(offset)
        let second = currentRawTokenDigit(offset + 1)
        if (first < 0 || second < 0) {
            return -1
        }
        first * 10 + second
    }

    func currentRawTokenFourDigits(offset: Int64): Int64 {
        let first = currentRawTokenTwoDigits(offset)
        let second = currentRawTokenTwoDigits(offset + 2)
        if (first < 0 || second < 0) {
            return -1
        }
        first * 100 + second
    }

    func currentRawTokenAsciiString(): String {
        asciiStringFromRange(rawTokenStart, rawTokenEnd)
    }

    func currentRawDateTimeCache(epochSecond: Int64, offsetSeconds: Int64): Option<DateTime> {
        match (rawDateTimeCacheValue) {
            case Some(value) =>
                if (rawDateTimeCacheEpochSecond == epochSecond &&
                    rawDateTimeCacheOffsetSeconds == offsetSeconds) {
                    return Some(value)
                }
                None<DateTime>
            case None => None<DateTime>
        }
    }

    func setRawDateTimeCache(epochSecond: Int64, offsetSeconds: Int64, value: DateTime): Unit {
        rawDateTimeCacheEpochSecond = epochSecond
        rawDateTimeCacheOffsetSeconds = offsetSeconds
        rawDateTimeCacheValue = Some(value)
    }

    func currentRawTokenNumberDigitCount(): Int64 {
        rawTokenNumberDigitCount
    }

    func currentRawTokenNumberScale(): Int64 {
        rawTokenNumberScale
    }

    func currentRawTokenNumberSmallUnscaled(): Int64 {
        rawTokenNumberSmallUnscaled
    }

    func currentRawTokenNumberSmallUnscaledValid(): Bool {
        rawTokenNumberSmallUnscaledValid
    }

    func currentRawTokenNumberNegative(): Bool {
        rawTokenNumberNegative
    }

    func currentRawTokenNumberHasExponent(): Bool {
        rawTokenNumberHasExponent
    }

    func currentRawTokenNumberHasNonZero(): Bool {
        rawTokenNumberHasNonZero
    }

    public func skipRaw(): Unit {
        skipRawValueBounded(0, -1)
    }

    /// Skips one value while enforcing a container-depth budget relative to
    /// the current generated-code context. A scalar consumes no depth.
    public func skipRawWithDepth(maxDepth: Int64): Unit {
        if (maxDepth < 0) { throw IllegalArgumentException("maxDepth must not be negative") }
        skipRawValueBounded(0, maxDepth)
    }

    func tryNativeObjectFields(): Option<JsonNativeObjectFields> {
        let start = index
        skipSpaces()
        if (!hasMore() || peek() != b'{') {
            index = start
            return None<JsonNativeObjectFields>
        }
        if (size - index < YJSON_NATIVE_MIN_OBJECT_SCAN_BYTES) {
            index = start
            return None<JsonNativeObjectFields>
        }
        if (hasJsonValuePrefixBefore(index)) {
            index = start
            return None<JsonNativeObjectFields>
        }
        if (index + 1 < size && isJsonSpace(data[index + 1])) {
            index = start
            return None<JsonNativeObjectFields>
        }
        match (jsonNativeScanObjectFields(data, size, index, validateStrings)) {
            case Some(fields) => return Some(fields)
            case None =>
                index = start
                return None<JsonNativeObjectFields>
        }
    }

    func finishNativeObjectFields(fields: JsonNativeObjectFields): Unit {
        index = fields.objectEnd
    }

    private func hasJsonValuePrefixBefore(position: Int64): Bool {
        var cursor = position - 1
        while (cursor >= 0 && isJsonSpace(data[cursor])) {
            cursor--
        }
        if (cursor < 0) {
            return false
        }
        let previous = data[cursor]
        previous == b'[' || previous == b',' || previous == b':'
    }

    private func beforeRawFieldName(first: Bool): Unit {
        skipSpaces()
        if (!first) {
            expectByte(b',')
            skipSpaces()
        }
    }

    private func afterRawFieldName(): Unit {
        if (hasMore() && peek() == b':') {
            index++
            return
        }
        skipSpaces()
        expectByte(b':')
    }

    private func skipRawValueBounded(depth: Int64, maxDepth: Int64): Unit {
        if (!hasMore()) {
            fail("Unexpected end of input")
        }
        if (isJsonSpace(peek())) {
            skipSpaces()
        }
        if (!hasMore()) {
            fail("Unexpected end of input")
        }
        let current = peek()
        if (maxDepth < 0 && shouldUseNativeSkip(current)) {
            let nativeEnd = jsonNativeSkipValue(data, size, index, validateStrings)
            if (nativeEnd >= 0) {
                index = nativeEnd
                return
            }
        }
        match {
            case current == b'n' => expectLiteral("null")
            case current == b't' => expectLiteral("true")
            case current == b'f' => expectLiteral("false")
            case current == b'"' =>
                scanRawString()
            case current == b'[' => skipRawArrayBounded(depth, maxDepth)
            case current == b'{' => skipRawObjectBounded(depth, maxDepth)
            case current == b'-' || (current >= b'0' && current <= b'9') =>
                skipRawNumber()
            case _ => fail("Unexpected token")
        }
    }

    private func shouldUseNativeSkip(current: Byte): Bool {
        (current == b'{' || current == b'[') && size - index >= YJSON_NATIVE_SKIP_MIN_REMAINING_BYTES
    }

    private func skipRawArrayBounded(depth: Int64, maxDepth: Int64): Unit {
        if (maxDepth >= 0 && depth >= maxDepth) {
            throw JsonException("Maximum JSON depth exceeded", code: "max_depth",
                byteOffset: index, line: jsonLineFromUtf8Bytes(data, index),
                column: jsonColumnFromUtf8Bytes(data, index))
        }
        expectByte(b'[')
        skipSpaces()
        if (hasMore() && peek() == b']') {
            index++
            return
        }
        while (true) {
            skipRawValueBounded(depth + 1, maxDepth)
            skipSpaces()
            if (hasMore() && peek() == b']') {
                index++
                return
            }
            expectByte(b',')
        }
    }

    private func skipRawObjectBounded(depth: Int64, maxDepth: Int64): Unit {
        if (maxDepth >= 0 && depth >= maxDepth) {
            throw JsonException("Maximum JSON depth exceeded", code: "max_depth",
                byteOffset: index, line: jsonLineFromUtf8Bytes(data, index),
                column: jsonColumnFromUtf8Bytes(data, index))
        }
        expectByte(b'{')
        skipSpaces()
        if (hasMore() && peek() == b'}') {
            index++
            return
        }
        while (true) {
            scanRawString()
            skipSpaces()
            expectByte(b':')
            skipRawValueBounded(depth + 1, maxDepth)
            skipSpaces()
            if (hasMore() && peek() == b'}') {
                index++
                return
            }
            expectByte(b',')
        }
    }

    private func skipRawNumber(): Unit {
        if (hasMore() && peek() == b'-') {
            index++
        }
        consumeIntegerDigits()
        if (hasMore() && peek() == b'.') {
            index++
            requireDigit("Expected fractional digits")
            consumeDigits()
        }
        if (hasMore() && (peek() == b'e' || peek() == b'E')) {
            index++
            if (hasMore() && (peek() == b'+' || peek() == b'-')) {
                index++
            }
            requireDigit("Expected exponent digits")
            consumeDigits()
        }
    }

    private func parseNumberLiteral(): String {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        parseNumberLiteralNoSpace()
    }

    private func parseNumberLiteralNoSpace(): String {
        let start = index
        if (hasMore() && peek() == b'-') {
            index++
        }
        consumeIntegerDigits()
        if (hasMore() && peek() == b'.') {
            index++
            requireDigit("Expected fractional digits")
            consumeDigits()
        }
        if (hasMore() && (peek() == b'e' || peek() == b'E')) {
            index++
            if (hasMore() && (peek() == b'+' || peek() == b'-')) {
                index++
            }
            requireDigit("Expected exponent digits")
            consumeDigits()
        }
        asciiStringFromRange(start, index)
    }

    private func parseInt64Literal(): Int64 {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        parseInt64LiteralNoSpace()
    }

    private func parseInt64LiteralNoSpace(): Int64 {
        if (!hasMore()) {
            fail("Expected integer")
        }
        if (peek() == b'-') {
            index++
            requireDigit("Expected digit")
            var result: Int64 = 0
            if (peek() == b'0') {
                index++
                rejectLeadingZero()
            } else {
                while (hasMore() && peek() >= b'0' && peek() <= b'9') {
                    let digit = Int64(consume() - b'0')
                    if (result < ((-0x8000_0000_0000_0000 + digit) / 10)) {
                        fail("Integer literal out of Int64 range")
                    }
                    result = result * 10 - digit
                }
            }
            rejectFractionalOrExponentForInteger()
            return result
        }
        requireDigit("Expected digit")
        var result: Int64 = 0
        if (peek() == b'0') {
            index++
            rejectLeadingZero()
        } else {
            while (hasMore() && peek() >= b'0' && peek() <= b'9') {
                let digit = Int64(consume() - b'0')
                if (result > ((0x7FFF_FFFF_FFFF_FFFF - digit) / 10)) {
                    fail("Integer literal out of Int64 range")
                }
                result = result * 10 + digit
            }
        }
        rejectFractionalOrExponentForInteger()
        result
    }

    private func parseUInt64Literal(): UInt64 {
        if (!hasMore() || isJsonSpace(peek())) {
            skipSpaces()
        }
        parseUInt64LiteralNoSpace()
    }

    private func parseUInt64LiteralNoSpace(): UInt64 {
        if (!hasMore() || peek() == b'-') {
            fail("Expected unsigned integer")
        }
        requireDigit("Expected digit")
        var result: UInt64 = 0
        if (peek() == b'0') {
            index++
            rejectLeadingZero()
        } else {
            while (hasMore() && peek() >= b'0' && peek() <= b'9') {
                let digit = UInt64(consume() - b'0')
                if (result > ((UInt64.Max - digit) / 10)) {
                    fail("Integer literal out of UInt64 range")
                }
                result = result * 10 + digit
            }
        }
        rejectFractionalOrExponentForInteger()
        result
    }

    private func rejectFractionalOrExponentForInteger(): Unit {
        if (hasMore() && (peek() == b'.' || peek() == b'e' || peek() == b'E')) {
            fail("Expected integer")
        }
    }

    private func consumeDigits(): Unit {
        requireDigit("Expected digit")
        while (hasMore() && peek() >= b'0' && peek() <= b'9') {
            index++
        }
    }

    private func consumeIntegerDigits(): Unit {
        requireDigit("Expected digit")
        if (peek() == b'0') {
            index++
            rejectLeadingZero()
            return
        }
        consumeDigits()
    }

    private func rejectLeadingZero(): Unit {
        if (hasMore() && peek() >= b'0' && peek() <= b'9') {
            fail("Leading zeroes are not allowed in JSON numbers")
        }
    }

    private func requireDigit(message: String): Unit {
        if (!hasMore() || peek() < b'0' || peek() > b'9') {
            fail(message)
        }
    }

    private func parseString(): String {
        expectByte(b'"')
        let start = index
        var leadingSegmentAscii = true
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                let end = index
                index++
                if (validateStrings && leadingSegmentAscii) {
                    return asciiStringFromRange(start, end)
                }
                return stringFromUtf8Range(start, end)
            }
            if (current == b'\\') {
                return parseEscapedString(start, leadingSegmentAscii)
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            if (current >= 0x80) {
                leadingSegmentAscii = false
            }
            index++
        }
        fail("Unterminated string literal")
    }

    private func parseEscapedString(start: Int64, leadingSegmentAscii: Bool): String {
        let quoteStart = start - 1
        if (!validateStrings) {
            if (let Some(value) <- tryDecodeEscapedStringToUtf8(start)) {
                return value
            }
            if (size - quoteStart >= YJSON_NATIVE_MIN_READER_DECODE_BYTES) {
                if (let Some(decoded) <- jsonNativeDecodeString(data, size, quoteStart, validateStrings)) {
                    index = decoded.end
                    return decoded.value
                }
            }
        } else {
            if (size - quoteStart < YJSON_NATIVE_MIN_READER_DECODE_BYTES) {
                if (let Some(value) <- tryDecodeEscapedStringToUtf8(start)) {
                    return value
                }
            } else {
                if (let Some(decoded) <- jsonNativeDecodeString(data, size, quoteStart, validateStrings)) {
                    index = decoded.end
                    return decoded.value
                }
                if (let Some(value) <- tryDecodeEscapedStringToUtf8(start)) {
                    return value
                }
            }
        }
        let builder = StringBuilder()
        var segmentStart = start
        var segmentAscii = leadingSegmentAscii
        while (hasMore()) {
            let currentStart = index
            let current = consume()
            match (current) {
                case b'"' =>
                    if (currentStart > segmentStart) {
                        builder.append(stringFromEscapedSegment(segmentStart, currentStart, segmentAscii))
                    }
                    return builder.toString()
                case b'\\' =>
                    if (currentStart > segmentStart) {
                        builder.append(stringFromEscapedSegment(segmentStart, currentStart, segmentAscii))
                    }
                    if (!hasMore()) {
                        fail("Unexpected end of escape sequence")
                    }
                    let escaped = consume()
                    match (escaped) {
                        case b'"' => builder.append("\"")
                        case b'\\' => builder.append("\\")
                        case b'/' => builder.append("/")
                        case b'b' => builder.append(r'\b')
                        case b'f' => builder.append(r'\f')
                        case b'n' => builder.append(r'\n')
                        case b'r' => builder.append(r'\r')
                        case b't' => builder.append(r'\t')
                        case b'u' => builder.append(parseUnicodeEscape())
                        case _ => fail("Unsupported escape sequence")
                    }
                    segmentStart = index
                    segmentAscii = true
                case _ =>
                    if (current < 0x20) {
                        failAt("Unescaped control character in string literal", currentStart)
                    }
                    if (current >= 0x80) {
                        segmentAscii = false
                    }
                    if (validateStrings && current >= 0x80) {
                        let beforeDecode = index
                        let _ = decodeUtf8Rune(current, currentStart)
                        index = beforeDecode + utf8Width(current, currentStart) - 1
                    }
            }
        }
        fail("Unterminated string literal")
    }

    private func stringFromEscapedSegment(start: Int64, end: Int64, ascii: Bool): String {
        if (ascii) {
            return asciiStringFromRange(start, end)
        }
        stringFromUtf8Range(start, end)
    }

    private func tryDecodeEscapedStringToUtf8(start: Int64): Option<String> {
        let output = Array<Byte>(escapedStringContentSize(start), repeat: 0)
        var read = start
        var segmentStart = start
        var written: Int64 = 0
        while (read < size) {
            let current = data[read]
            if (current == b'"') {
                written = copyEscapedStringSegment(output, segmentStart, read, written)
                index = read + 1
                return Some(unsafe { String.fromUtf8Unchecked(output[0..written]) })
            }
            if (current == b'\\') {
                written = copyEscapedStringSegment(output, segmentStart, read, written)
                read++
                if (read >= size) {
                    fail("Unexpected end of escape sequence")
                }
                let escaped = data[read]
                read++
                match (escaped) {
                    case b'"' => output[written] = b'"'
                    case b'\\' => output[written] = b'\\'
                    case b'/' => output[written] = b'/'
                    case b'b' => output[written] = b'\b'
                    case b'f' => output[written] = b'\f'
                    case b'n' => output[written] = b'\n'
                    case b'r' => output[written] = b'\r'
                    case b't' => output[written] = b'\t'
                    case b'u' =>
                        let escapeStart = read - 2
                        var value = unicodeEscapeValueAt(read, escapeStart)
                        read += 4
                        if (isJsonHighSurrogate(value)) {
                            if (read + 2 > size || data[read] != b'\\' || data[read + 1] != b'u') {
                                failAt("Invalid unicode surrogate pair", escapeStart)
                            }
                            read += 2
                            let low = unicodeEscapeValueAt(read, read)
                            if (!isJsonLowSurrogate(low)) {
                                failAt("Invalid unicode surrogate pair", escapeStart)
                            }
                            read += 4
                            value = Int64(combineJsonSurrogates(value, low))
                        } else if (isJsonLowSurrogate(value)) {
                            failAt("Invalid unicode surrogate pair", escapeStart)
                        }
                        written = appendUtf8CodePoint(output, written, value)
                        segmentStart = read
                        continue
                    case _ => failAt("Unsupported escape sequence", read - 2)
                }
                written++
                segmentStart = read
                continue
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", read)
            }
            if (validateStrings && current >= 0x80) {
                read = validateRawUtf8At(read)
                continue
            }
            read++
        }
        fail("Unterminated string literal")
    }

    private func escapedStringContentSize(start: Int64): Int64 {
        var cursor = start
        while (cursor < size) {
            match (data[cursor]) {
                case b'"' => return cursor - start
                case b'\\' =>
                    cursor++
                    if (cursor >= size) {
                        fail("Unexpected end of escape sequence")
                    }
                    cursor++
                case _ => cursor++
            }
        }
        fail("Unterminated string literal")
    }

    private func validateRawUtf8At(start: Int64): Int64 {
        let first = data[start]
        if (first < 0xC2 || first > 0xF4) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
        if (first < 0xE0) {
            requireUtf8Continuation(start, start + 1)
            return start + 2
        }
        if (first < 0xF0) {
            let second = requireUtf8Continuation(start, start + 1)
            if ((first == 0xE0 && second < 0xA0) || (first == 0xED && second >= 0xA0)) {
                failAt("Invalid UTF-8 byte sequence", start)
            }
            requireUtf8Continuation(start, start + 2)
            return start + 3
        }
        let second = requireUtf8Continuation(start, start + 1)
        if ((first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F)) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
        requireUtf8Continuation(start, start + 2)
        requireUtf8Continuation(start, start + 3)
        start + 4
    }

    private func requireUtf8Continuation(start: Int64, offset: Int64): Byte {
        if (offset >= size) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
        let value = data[offset]
        if ((UInt8(value) & 0xC0u8) != 0x80u8) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
        value
    }

    private func copyEscapedStringSegment(
        output: Array<Byte>,
        segmentStart: Int64,
        segmentEnd: Int64,
        written: Int64
    ): Int64 {
        let segmentSize = segmentEnd - segmentStart
        if (segmentSize <= 0) {
            return written
        }
        data.copyTo(output, segmentStart, written, segmentSize)
        written + segmentSize
    }

    private func appendUtf8CodePoint(output: Array<Byte>, written: Int64, code: Int64): Int64 {
        var cursor = written
        if (code <= 0x7F) {
            output[cursor] = UInt8(code)
            return cursor + 1
        }
        if (code <= 0x7FF) {
            output[cursor] = UInt8(0xC0 + code / 64)
            output[cursor + 1] = UInt8(0x80 + code % 64)
            return cursor + 2
        }
        if (code <= 0xFFFF) {
            output[cursor] = UInt8(0xE0 + code / 4096)
            output[cursor + 1] = UInt8(0x80 + (code / 64) % 64)
            output[cursor + 2] = UInt8(0x80 + code % 64)
            return cursor + 3
        }
        output[cursor] = UInt8(0xF0 + code / 262144)
        output[cursor + 1] = UInt8(0x80 + (code / 4096) % 64)
        output[cursor + 2] = UInt8(0x80 + (code / 64) % 64)
        output[cursor + 3] = UInt8(0x80 + code % 64)
        cursor + 4
    }

    private func unicodeEscapeValueAt(start: Int64, errorStart: Int64): Int64 {
        if (start + 4 > size) {
            failAt("Incomplete unicode escape", errorStart)
        }
        var value: Int64 = 0
        for (offset in 0..4) {
            value = value * 16 + hexValue(data[start + offset])
        }
        value
    }

    private func scanRawString(): Unit {
        if (size - index >= 64) {
            let nativeEnd = jsonNativeScanString(data, size, index, validateStrings)
            if (nativeEnd >= 0) {
                index = nativeEnd
                return
            }
        }
        expectByte(b'"')
        while (hasMore()) {
            let currentStart = index
            let current = consume()
            match (current) {
                case b'"' => return
                case b'\\' => skipEscapedStringItem(currentStart)
                case _ =>
                    if (current < 0x20) {
                        failAt("Unescaped control character in string literal", currentStart)
                    }
                    if (validateStrings && current >= 0x80) {
                        let _ = decodeUtf8Rune(current, currentStart)
                    }
            }
        }
        fail("Unterminated string literal")
    }

    private func skipEscapedStringItem(start: Int64): Unit {
        if (index >= size) {
            fail("Unexpected end of escape sequence")
        }
        let escaped = data[index]
        index++
        match (escaped) {
            case b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => return
            case b'u' =>
                skipUnicodeEscape(start)
                return
            case _ => failAt("Unsupported escape sequence", start)
        }
    }

    private func skipUnicodeEscape(start: Int64): Unit {
        let value = parseUnicodeEscapeValueAtCurrent(start)
        if (isJsonHighSurrogate(value)) {
            if (index + 2 > size || data[index] != b'\\' || data[index + 1] != b'u') {
                failAt("Invalid unicode surrogate pair", start)
            }
            index += 2
            let low = parseUnicodeEscapeValueAtCurrent(start)
            if (!isJsonLowSurrogate(low)) {
                failAt("Invalid unicode surrogate pair", start)
            }
            return
        }
        if (isJsonLowSurrogate(value)) {
            failAt("Invalid unicode surrogate pair", start)
        }
    }

    private func stringFromUtf8Range(start: Int64, end: Int64): String {
        if (!validateStrings) {
            if (let Some(text) <- sourceText) {
                return text[start..end]
            }
            return unsafe {
                String.fromUtf8Unchecked(data[start..end])
            }
        }
        return try {
            String.fromUtf8(data[start..end])
        } catch (_: Exception) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
    }

    // Validate one source-owned UTF-8 sequence in the key scanner itself, so
    // non-ASCII no-escape keys still require only one byte traversal.
    private func validatedUtf8WidthAt(start: Int64): Int64 {
        let first = UInt8(data[start])
        if (first >= 0xC2u8 && first <= 0xDFu8) {
            requireUtf8Continuation(start + 1, size, 0x80u8, 0xBFu8, start)
            return 2
        }
        if (first >= 0xE0u8 && first <= 0xEFu8) {
            let secondMin = if (first == 0xE0u8) { 0xA0u8 } else { 0x80u8 }
            let secondMax = if (first == 0xEDu8) { 0x9Fu8 } else { 0xBFu8 }
            requireUtf8Continuation(start + 1, size, secondMin, secondMax, start)
            requireUtf8Continuation(start + 2, size, 0x80u8, 0xBFu8, start)
            return 3
        }
        if (first >= 0xF0u8 && first <= 0xF4u8) {
            let secondMin = if (first == 0xF0u8) { 0x90u8 } else { 0x80u8 }
            let secondMax = if (first == 0xF4u8) { 0x8Fu8 } else { 0xBFu8 }
            requireUtf8Continuation(start + 1, size, secondMin, secondMax, start)
            requireUtf8Continuation(start + 2, size, 0x80u8, 0xBFu8, start)
            requireUtf8Continuation(start + 3, size, 0x80u8, 0xBFu8, start)
            return 4
        }
        failAt("Invalid UTF-8 byte sequence", start)
    }

    private func requireUtf8Continuation(position: Int64, end: Int64, minimum: UInt8,
        maximum: UInt8, errorPosition: Int64): Unit {
        if (position >= end) { failAt("Invalid UTF-8 byte sequence", errorPosition) }
        let value = UInt8(data[position])
        if (value < minimum || value > maximum) {
            failAt("Invalid UTF-8 byte sequence", errorPosition)
        }
    }

    private func asciiStringFromRange(start: Int64, end: Int64): String {
        unsafe {
            String.fromUtf8Unchecked(data[start..end])
        }
    }

    private func parseNameIdBytes(candidates: Array<Array<Byte>>): Int64 {
        if (candidates.size > 63 || !allCandidateBytesAscii(candidates)) {
            let name = parseString()
            for (candidateIndex in 0..candidates.size) {
                if (String.fromUtf8(candidates[candidateIndex]) == name) {
                    return candidateIndex
                }
            }
            return -1
        }
        expectByte(b'"')
        var active = initialNameMatchMask(candidates.size)
        var nameIndex: Int64 = 0
        while (index < size) {
            let current = data[index]
            index++
            if (current == b'"') {
                if (active == 0u64) {
                    return -1
                }
                for (candidateIndex in 0..candidates.size) {
                    if (((active & nameMatchBit(candidateIndex)) != 0u64) && candidates[candidateIndex].size == nameIndex) {
                        return candidateIndex
                    }
                }
                return -1
            }
            var code: Int64 = -1
            if (current == b'\\') {
                code = consumeEscapedAsciiForName()
            } else if (current < 0x80) {
                if (current < 0x20) {
                    failAt("Unescaped control character in string literal", index - 1)
                }
                code = Int64(current)
            } else if (validateStrings) {
                index += validatedUtf8WidthAt(index - 1) - 1
            }
            if (active != 0u64) {
                active = updateActiveNameByteCandidates(candidates, active, nameIndex, code)
            }
            nameIndex++
        }
        fail("Unterminated string literal")
    }

    private func parseNameId(matcher: JsonRawNameMatcher): Int64 {
        let candidates = matcher.candidates
        if (!matcher.useAsciiFastPath) {
            let name = parseString()
            for (candidateIndex in 0..candidates.size) {
                if (String.fromUtf8(candidates[candidateIndex]) == name) {
                    return candidateIndex
                }
            }
            return -1
        }
        if (let Some(id) <- tryParseSimpleNameId(candidates)) {
            return id
        }
        expectByte(b'"')
        var active = matcher.initialMask
        var nameIndex: Int64 = 0
        while (index < size) {
            let current = data[index]
            index++
            if (current == b'"') {
                if (active == 0u64) {
                    return -1
                }
                for (candidateIndex in 0..candidates.size) {
                    if (((active & nameMatchBit(candidateIndex)) != 0u64) && candidates[candidateIndex].size == nameIndex) {
                        return candidateIndex
                    }
                }
                return -1
            }
            var code: Int64 = -1
            if (current == b'\\') {
                code = consumeEscapedAsciiForName()
            } else if (current < 0x80) {
                if (current < 0x20) {
                    failAt("Unescaped control character in string literal", index - 1)
                }
                code = Int64(current)
            } else if (validateStrings) {
                index += validatedUtf8WidthAt(index - 1) - 1
            }
            if (active != 0u64) {
                active = updateActiveNameByteCandidates(candidates, active, nameIndex, code)
            }
            nameIndex++
        }
        fail("Unterminated string literal")
    }

    private func tryParseSimpleNameId(candidates: Array<Array<Byte>>): Option<Int64> {
        let quotePosition = index
        expectByte(b'"')
        let nameStart = index
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                let nameEnd = index
                index++
                return Some(rawNameId(candidates, nameStart, nameEnd))
            }
            if (current == b'\\') {
                index = quotePosition
                return None<Int64>
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            if (current >= 0x80) {
                index = quotePosition
                return None<Int64>
            }
            index++
        }
        fail("Unterminated string literal")
    }

    private func rawNameId(candidates: Array<Array<Byte>>, nameStart: Int64, nameEnd: Int64): Int64 {
        let nameSize = nameEnd - nameStart
        if (nameSize <= 0) {
            return -1
        }
        let first = data[nameStart]
        for (candidateIndex in 0..candidates.size) {
            let candidate = candidates[candidateIndex]
            if (candidate.size != nameSize || candidate[0] != first) {
                continue
            }
            var matched = true
            for (offset in 1..nameSize) {
                if (data[nameStart + offset] != candidate[offset]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                return candidateIndex
            }
        }
        -1
    }

    private func allCandidateBytesAscii(candidates: Array<Array<Byte>>): Bool {
        for (candidate in candidates) {
            for (byte in candidate) {
                if (byte >= 0x80) {
                    return false
                }
            }
        }
        true
    }

    private func initialNameMatchMask(size: Int64): UInt64 {
        var mask = 0u64
        for (candidateIndex in 0..size) {
            mask |= nameMatchBit(candidateIndex)
        }
        mask
    }

    private func nameMatchBit(candidateIndex: Int64): UInt64 {
        1u64 << candidateIndex
    }

    private func updateActiveNameByteCandidates(
        candidates: Array<Array<Byte>>,
        active: UInt64,
        nameIndex: Int64,
        code: Int64
    ): UInt64 {
        if (code < 0 || code > 0x7F) {
            return 0u64
        }
        var next = 0u64
        let byte = UInt8(code)
        for (candidateIndex in 0..candidates.size) {
            let bit = nameMatchBit(candidateIndex)
            if ((active & bit) == 0u64) {
                continue
            }
            let candidate = candidates[candidateIndex]
            if (nameIndex < candidate.size && candidate[nameIndex] == byte) {
                next |= bit
            }
        }
        next
    }

    private func consumeEscapedAsciiForName(): Int64 {
        if (index >= size) {
            fail("Unexpected end of escape sequence")
        }
        let escaped = data[index]
        index++
        match (escaped) {
            case b'"' => return Int64(b'"')
            case b'\\' => return Int64(b'\\')
            case b'/' => return Int64(b'/')
            case b'b' => return Int64(b'\b')
            case b'f' => return Int64(b'\f')
            case b'n' => return Int64(b'\n')
            case b'r' => return Int64(b'\r')
            case b't' => return Int64(b'\t')
            case b'u' =>
                let r = parseUnicodeEscape()
                let code = UInt32(r)
                return if (code <= 0x7Fu32) {
                    Int64(code)
                } else {
                    -1
                }
            case _ => fail("Unsupported escape sequence")
        }
    }

    private func parseUnicodeEscape(): Rune {
        let start = index
        let value = parseUnicodeEscapeValue(start)
        if (isJsonHighSurrogate(value)) {
            if (index >= size || data[index] != b'\\') {
                failAt("Invalid unicode surrogate pair", start)
            }
            index++
            if (index >= size || data[index] != b'u') {
                failAt("Invalid unicode surrogate pair", start)
            }
            index++
            let lowStart = index
            let low = parseUnicodeEscapeValue(lowStart)
            if (!isJsonLowSurrogate(low)) {
                failAt("Invalid unicode surrogate pair", start)
            }
            return try {
                Rune(combineJsonSurrogates(value, low))
            } catch (_: Exception) {
                failAt("Invalid unicode escape", start)
            }
        }
        if (isJsonLowSurrogate(value)) {
            failAt("Invalid unicode surrogate pair", start)
        }
        return try {
            Rune(UInt32(value))
        } catch (_: Exception) {
            failAt("Invalid unicode escape", start)
        }
    }

    private func parseUnicodeEscapeValue(start: Int64): Int64 {
        parseUnicodeEscapeValueAtCurrent(start)
    }

    private func parseUnicodeEscapeValueAtCurrent(start: Int64): Int64 {
        let value = unicodeEscapeValueAt(index, start)
        index += 4
        value
    }

    private func hexValue(value: Byte): Int64 {
        match {
            case value >= b'0' && value <= b'9' => Int64(value - b'0')
            case value >= b'a' && value <= b'f' => Int64(value - b'a') + 10
            case value >= b'A' && value <= b'F' => Int64(value - b'A') + 10
            case _ => fail("Invalid unicode escape")
        }
    }

    private func decodeUtf8Rune(first: Byte, start: Int64): Rune {
        let width = utf8Width(first, start)
        let bytes = Array<UInt8>(width, repeat: 0u8)
        bytes[0] = UInt8(first)
        for (offset in 1..width) {
            if (!hasMore()) {
                failAt("Invalid UTF-8 byte sequence", start)
            }
            bytes[offset] = UInt8(consume())
        }
        return try {
            let (r, _) = Rune.fromUtf8(bytes, 0)
            r
        } catch (_: Exception) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
    }

    private func utf8Width(first: Byte, start: Int64): Int64 {
        let unsigned = UInt8(first)
        if ((unsigned & 0xE0u8) == 0xC0u8) {
            return 2
        }
        if ((unsigned & 0xF0u8) == 0xE0u8) {
            return 3
        }
        if ((unsigned & 0xF8u8) == 0xF0u8) {
            return 4
        }
        failAt("Invalid UTF-8 byte sequence", start)
    }

    private func skipSpaces(): Unit {
        while (index < size) {
            if (isJsonSpace(data[index])) {
                index++
            } else {
                return
            }
        }
    }

    private func isJsonSpace(value: Byte): Bool {
        value == b' ' || value == b'\n' || value == b'\r' || value == b'\t'
    }

    private func suggestContainerCapacity(bytesPerEntry: Int64): Int64 {
        let remaining = size - index
        if (remaining <= bytesPerEntry) {
            return 4
        }
        let estimate = remaining / bytesPerEntry + 1
        match {
            case estimate < 4 => 4
            case estimate > 64 => 64
            case _ => estimate
        }
    }

    private func expectLiteral(literal: String): Unit {
        match (literal) {
            case "null" =>
                expectByte(b'n')
                expectByte(b'u')
                expectByte(b'l')
                expectByte(b'l')
                return
            case "true" =>
                expectByte(b't')
                expectByte(b'r')
                expectByte(b'u')
                expectByte(b'e')
                return
            case "false" =>
                expectByte(b'f')
                expectByte(b'a')
                expectByte(b'l')
                expectByte(b's')
                expectByte(b'e')
                return
            case _ => ()
        }
        for (byte in unsafe { literal.rawData() }) {
            if (!hasMore() || consume() != byte) {
                fail("Expected ${literal}")
            }
        }
    }

    private func expectByte(value: Byte): Unit {
        if (index >= size || data[index] != value) {
            fail("Unexpected token")
        }
        index++
    }

    private func hasMore(): Bool {
        index < size
    }

    private func peek(): Byte {
        data[index]
    }

    private func consume(): Byte {
        let value = data[index]
        index++
        value
    }

    private func fail(message: String): Nothing {
        failAt(message, index)
    }

    private func failAt(message: String, offset: Int64): Nothing {
        throw JsonException(
            "${message} at byte ${offset}",
            code: "parse_error",
            byteOffset: offset,
            line: jsonLineFromUtf8Bytes(data, offset),
            column: jsonColumnFromUtf8Bytes(data, offset)
        )
    }
}
