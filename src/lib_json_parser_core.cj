package yjson

import std.collection.*
import std.convert.Parsable
import std.io.*

abstract class InputCursor {
    private var valueBudgetStart: Int64 = -1
    private var valueBudgetLimit: Int64 = 0
    private var valueBudgetActive: Bool = false

    public func hasMore(): Bool

    public func peek(): Byte

    public func consume(): Byte

    public func position(): Int64

    public func config(): JsonReadConfig

    public func lineAt(offset: Int64): Int64

    public func columnAt(offset: Int64): Int64

    public func beginValueBudget(limit: Int64): Unit {
        valueBudgetStart = position()
        valueBudgetLimit = limit
        valueBudgetActive = limit > 0
    }

    public func endValueBudget(): Unit {
        valueBudgetActive = false
    }

    protected func resetValueBudget(): Unit {
        valueBudgetStart = -1
        valueBudgetLimit = 0
        valueBudgetActive = false
    }

    public func isValueBudgetActive(): Bool {
        valueBudgetActive
    }

    public func consumeJsonByte(): Byte {
        let value = consume()
        if (valueBudgetActive && position() - valueBudgetStart > valueBudgetLimit) {
            throw jsonResourceLimitException(config(),
                "JSON value exceeds ${valueBudgetLimit} bytes",
                "polymorphic_object_too_large", valueBudgetStart + valueBudgetLimit)
        }
        value
    }

    public func skipJsonWhitespace(): Unit {
        match (this) {
            case cursor: Utf8Cursor =>
                if (!valueBudgetActive) {
                    cursor.skipSpacesFast()
                    return
                }
            case _ => ()
        }
        while (hasMore()) {
            match (peek()) {
                case b' ' | b'\n' | b'\r' | b'\t' => consumeJsonByte()
                case _ => return
            }
        }
    }

    public func readJsonNumberLiteral(): String {
        let literal = StringBuilder()
        if (hasMore() && peek() == b'-') {
            literal.append(Rune(consumeJsonByte()))
        }
        readJsonIntegerDigits(literal)
        if (hasMore() && peek() == b'.') {
            literal.append(Rune(consumeJsonByte()))
            requireJsonDigit("Expected fractional digits")
            readJsonDigits(literal)
        }
        if (hasMore() && (peek() == b'e' || peek() == b'E')) {
            literal.append(Rune(consumeJsonByte()))
            if (hasMore() && (peek() == b'+' || peek() == b'-')) {
                literal.append(Rune(consumeJsonByte()))
            }
            requireJsonDigit("Expected exponent digits")
            readJsonDigits(literal)
        }
        literal.toString()
    }

    public func readJsonString(): String {
        match (this) {
            case cursor: Utf8Cursor =>
                if (config().maxStringBytes == 0 && !valueBudgetActive) {
                    if (let Some(value) <- cursor.tryParseSimpleString()) {
                        return value
                    }
                }
            case cursor: StreamInputCursor =>
                if (config().maxStringBytes == 0 && !valueBudgetActive) {
                    if (let Some(value) <- cursor.tryParseSimpleAsciiStringWindow()) {
                        return value
                    }
                }
            case _ => ()
        }
        expectJsonByte(b'"')
        let builder = StringBuilder()
        var decodedBytes: Int64 = 0
        while (hasMore()) {
            let start = position()
            let current = consumeJsonByte()
            match (current) {
                case b'"' => return builder.toString()
                case b'\\' =>
                    if (!hasMore()) { failJson("Unexpected end of escape sequence") }
                    let escaped = consumeJsonByte()
                    match (escaped) {
                        case b'"' => builder.append("\""); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'\\' => builder.append("\\"); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'/' => builder.append("/"); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'b' => builder.append(r'\b'); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'f' => builder.append(r'\f'); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'n' => builder.append(r'\n'); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'r' => builder.append(r'\r'); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b't' => builder.append(r'\t'); decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                        case b'u' =>
                            let (r, size) = readJsonUnicodeEscape()
                            builder.append(r)
                            decodedBytes = addDecodedJsonBytes(decodedBytes, size, start)
                        case _ => failJson("Unsupported escape sequence")
                    }
                case _ =>
                    if (current < 0x80) {
                        if (current < 0x20) {
                            failJsonAt("Unescaped control character in string literal", start)
                        }
                        builder.append(Rune(current))
                        decodedBytes = addDecodedJsonBytes(decodedBytes, 1, start)
                    } else {
                        builder.append(decodeJsonUtf8Rune(current, start))
                        decodedBytes = addDecodedJsonBytes(decodedBytes, position() - start, start)
                    }
            }
        }
        failJson("Unterminated string literal")
    }

    public func readJsonUnicodeEscape(): (Rune, Int64) {
        let start = position()
        if (!hasMore()) { failJson("Incomplete unicode escape") }
        let value = readJsonUnicodeEscapeValue(start)
        if (isJsonHighSurrogate(value)) {
            if (!hasMore() || consumeJsonByte() != b'\\' || !hasMore() || consumeJsonByte() != b'u') {
                failJsonAt("Invalid unicode surrogate pair", start)
            }
            let low = readJsonUnicodeEscapeValue(position())
            if (!isJsonLowSurrogate(low)) {
                failJsonAt("Invalid unicode surrogate pair", start)
            }
            return try {
                (Rune(combineJsonSurrogates(value, low)), 4)
            } catch (_: Exception) {
                failJsonAt("Invalid unicode escape", start)
            }
        }
        if (isJsonLowSurrogate(value)) {
            failJsonAt("Invalid unicode surrogate pair", start)
        }
        return try {
            (Rune(UInt32(value)), jsonUtf8ByteCount(value))
        } catch (_: Exception) {
            failJsonAt("Invalid unicode escape", start)
        }
    }

    public func decodeJsonUtf8Rune(first: Byte, start: Int64): Rune {
        let unsigned = UInt8(first)
        let width = match {
            case (unsigned & 0xE0u8) == 0xC0u8 => 2
            case (unsigned & 0xF0u8) == 0xE0u8 => 3
            case (unsigned & 0xF8u8) == 0xF0u8 => 4
            case _ => failJsonAt("Invalid UTF-8 byte sequence", start)
        }
        let bytes = Array<UInt8>(width, repeat: 0u8)
        bytes[0] = UInt8(first)
        for (index in 1..width) {
            if (!hasMore()) { failJsonAt("Invalid UTF-8 byte sequence", start) }
            bytes[index] = UInt8(consumeJsonByte())
        }
        return try {
            let (r, _) = Rune.fromUtf8(bytes, 0)
            r
        } catch (_: Exception) {
            failJsonAt("Invalid UTF-8 byte sequence", start)
        }
    }

    private func readJsonDigits(buffer: StringBuilder): Unit {
        requireJsonDigit("Expected digit")
        while (hasMore() && peek() >= b'0' && peek() <= b'9') {
            buffer.append(Rune(consumeJsonByte()))
        }
    }

    private func readJsonIntegerDigits(buffer: StringBuilder): Unit {
        requireJsonDigit("Expected digit")
        if (peek() == b'0') {
            buffer.append(Rune(consumeJsonByte()))
            if (hasMore() && peek() >= b'0' && peek() <= b'9') {
                failJson("Leading zeroes are not allowed in JSON numbers")
            }
            return
        }
        readJsonDigits(buffer)
    }

    private func requireJsonDigit(message: String): Unit {
        if (!hasMore() || peek() < b'0' || peek() > b'9') { failJson(message) }
    }

    private func expectJsonByte(value: Byte): Unit {
        if (!hasMore() || peek() != value) { failJson("Unexpected token") }
        consumeJsonByte()
    }

    private func readJsonUnicodeEscapeValue(start: Int64): Int64 {
        var value: Int64 = 0
        for (_ in 0..4) {
            if (!hasMore()) { failJsonAt("Incomplete unicode escape", start) }
            value = value * 16 + jsonHexValue(consumeJsonByte())
        }
        value
    }

    private func jsonHexValue(value: Byte): Int64 {
        match {
            case value >= b'0' && value <= b'9' => Int64(value - b'0')
            case value >= b'a' && value <= b'f' => Int64(value - b'a') + 10
            case value >= b'A' && value <= b'F' => Int64(value - b'A') + 10
            case _ => failJson("Invalid unicode escape")
        }
    }

    private func addDecodedJsonBytes(current: Int64, added: Int64, offset: Int64): Int64 {
        let next = current + added
        let limit = config().maxStringBytes
        if (limit > 0 && next > limit) {
            throw jsonResourceLimitException(config(),
                "JSON string exceeds ${limit} decoded UTF-8 bytes", "string_too_large", offset)
        }
        next
    }

    private func failJson(message: String): Nothing {
        failJsonAt(message, position())
    }

    private func failJsonAt(message: String, offset: Int64): Nothing {
        let readConfig = config()
        throw JsonException(message, code: "parse_error",
            byteOffset: if (readConfig.includeErrorLocation) { offset } else { -1 },
            line: lineAt(offset), column: columnAt(offset))
    }
}

class Utf8Cursor <: InputCursor {
    private let data: Array<Byte>
    private let size: Int64
    private let sourceText: Option<String>
    private let readConfig: JsonReadConfig
    private var index: Int64 = 0

    public init(data: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults) {
        this.data = data
        this.size = data.size
        this.sourceText = None<String>
        this.readConfig = config
        validateJsonResourceLimits(data, config)
    }

    public init(text: String, config!: JsonReadConfig = JsonReadConfig.defaults) {
        unsafe {
            this.data = text.rawData()
        }
        this.size = data.size
        this.sourceText = Some(text)
        this.readConfig = config
        validateJsonResourceLimits(data, config)
    }

    public func hasMore(): Bool {
        index < size
    }

    public func peek(): Byte {
        data[index]
    }

    public func consume(): Byte {
        let value = data[index]
        index++
        value
    }

    public func position(): Int64 {
        index
    }

    public func config(): JsonReadConfig {
        readConfig
    }

    public func lineAt(offset: Int64): Int64 {
        if (!readConfig.includeErrorLocation) {
            return -1
        }
        jsonLineFromUtf8Bytes(data, offset)
    }

    public func columnAt(offset: Int64): Int64 {
        if (!readConfig.includeErrorLocation) {
            return -1
        }
        jsonColumnFromUtf8Bytes(data, offset)
    }

    public func skipSpacesFast(): Unit {
        while (index < size) {
            match (data[index]) {
                case b' ' | b'\n' | b'\r' | b'\t' => index++
                case _ => return
            }
        }
    }

    public func expectByteFast(value: Byte): Unit {
        if (index >= size || data[index] != value) {
            fail("Unexpected token")
        }
        index++
    }

    public func expectLiteralFast(literal: String): Unit {
        for (byte in unsafe { literal.rawData() }) {
            if (index >= size || data[index] != byte) {
                fail("Expected ${literal}")
            }
            index++
        }
    }

    public func peekByteFast(value: Byte): Bool {
        index < size && data[index] == value
    }

    public func tryParseSimpleString(): Option<String> {
        let quotePosition = index
        expectByteFast(b'"')
        let start = index
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                let end = index
                index++
                return Some(stringFromUtf8Range(start, end))
            }
            if (current == b'\\') {
                index = quotePosition
                return None<String>
            }
            if (current < 0x20) {
                failAt("Unescaped control character in string literal", index)
            }
            index++
        }
        fail("Unterminated string literal")
    }

    public func parseNumberFast(): JsonNode {
        let start = index
        var overflow = false
        if (data[index] == b'-') {
            index++
            requireDigit("Expected digit")
            var result: Int64 = 0
            if (data[index] == b'0') {
                index++
                rejectLeadingZero()
            } else {
                while (index < size && data[index] >= b'0' && data[index] <= b'9') {
                    let digit = Int64(data[index] - b'0')
                    if (!overflow && result < ((-0x8000_0000_0000_0000 + digit) / 10)) {
                        overflow = true
                    }
                    if (!overflow) {
                        result = result * 10 - digit
                    }
                    index++
                }
            }
            if (consumeFractionalOrExponentIfPresent()) {
                return JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
            }
            if (jsonReadConfigPreservesNumberLiterals(readConfig)) {
                return JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
            }
            return if (overflow) {
                JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
            } else {
                JsonIntValue(result)
            }
        }
        requireDigit("Expected digit")
        var result: Int64 = 0
        if (data[index] == b'0') {
            index++
            rejectLeadingZero()
        } else {
            while (index < size && data[index] >= b'0' && data[index] <= b'9') {
                let digit = Int64(data[index] - b'0')
                if (!overflow && result > ((0x7FFF_FFFF_FFFF_FFFF - digit) / 10)) {
                    overflow = true
                }
                if (!overflow) {
                    result = result * 10 + digit
                }
                index++
            }
        }
        if (consumeFractionalOrExponentIfPresent()) {
            return JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
        }
        if (jsonReadConfigPreservesNumberLiterals(readConfig)) {
            return JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
        }
        if (overflow) {
            return JsonNumberLiteralValue.fromParsedLiteral(asciiStringFromRange(start, index))
        }
        JsonIntValue(result)
    }

    private func consumeFractionalOrExponentIfPresent(): Bool {
        var hasFractionalSyntax = false
        if (index < size && data[index] == b'.') {
            hasFractionalSyntax = true
            index++
            requireDigit("Expected fractional digits")
            consumeDigits()
        }
        if (index < size && (data[index] == b'e' || data[index] == b'E')) {
            hasFractionalSyntax = true
            index++
            if (index < size && (data[index] == b'+' || data[index] == b'-')) {
                index++
            }
            requireDigit("Expected exponent digits")
            consumeDigits()
        }
        hasFractionalSyntax
    }

    private func consumeDigits(): Unit {
        requireDigit("Expected digit")
        while (index < size && data[index] >= b'0' && data[index] <= b'9') {
            index++
        }
    }

    private func rejectLeadingZero(): Unit {
        if (index < size && data[index] >= b'0' && data[index] <= b'9') {
            fail("Leading zeroes are not allowed in JSON numbers")
        }
    }

    private func requireDigit(message: String): Unit {
        if (index >= size || data[index] < b'0' || data[index] > b'9') {
            fail(message)
        }
    }

    public func parseNameIdFast(candidates: Array<String>): Int64 {
        expectByteFast(b'"')
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
            } else {
                index += validatedUtf8WidthAt(index - 1) - 1
            }
            if (active != 0u64) {
                active = updateActiveNameCandidates(candidates, active, nameIndex, code)
            }
            nameIndex++
        }
        fail("Unterminated string literal")
    }

    public func parseInt64LiteralFast(): Int64 {
        skipSpacesFast()
        if (index >= size) {
            fail("Expected integer")
        }
        if (data[index] == b'-') {
            index++
            requireDigit("Expected digit")
            var result: Int64 = 0
            if (data[index] == b'0') {
                index++
                rejectLeadingZero()
            } else {
                while (index < size && data[index] >= b'0' && data[index] <= b'9') {
                    let digit = Int64(data[index] - b'0')
                    if (result < ((-0x8000_0000_0000_0000 + digit) / 10)) {
                        fail("Integer literal out of Int64 range")
                    }
                    result = result * 10 - digit
                    index++
                }
            }
            rejectFractionalOrExponentForInteger()
            return result
        }
        requireDigit("Expected digit")
        var result: Int64 = 0
        if (data[index] == b'0') {
            index++
            rejectLeadingZero()
        } else {
            while (index < size && data[index] >= b'0' && data[index] <= b'9') {
                let digit = Int64(data[index] - b'0')
                if (result > ((0x7FFF_FFFF_FFFF_FFFF - digit) / 10)) {
                    fail("Integer literal out of Int64 range")
                }
                result = result * 10 + digit
                index++
            }
        }
        rejectFractionalOrExponentForInteger()
        result
    }

    public func parseUInt64LiteralFast(): UInt64 {
        skipSpacesFast()
        if (index >= size || data[index] == b'-') {
            fail("Expected unsigned integer")
        }
        requireDigit("Expected digit")
        var result: UInt64 = 0
        if (data[index] == b'0') {
            index++
            rejectLeadingZero()
        } else {
            while (index < size && data[index] >= b'0' && data[index] <= b'9') {
                let digit = UInt64(data[index] - b'0')
                if (result > ((UInt64.Max - digit) / 10)) {
                    fail("Integer literal out of UInt64 range")
                }
                result = result * 10 + digit
                index++
            }
        }
        rejectFractionalOrExponentForInteger()
        result
    }
    private func updateActiveNameCandidates(
        candidates: Array<String>,
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
            unsafe {
                let candidate = candidates[candidateIndex].rawData()
                if (nameIndex < candidate.size && candidate[nameIndex] == byte) {
                    next |= bit
                }
            }
        }
        next
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
            case b'u' => return parseUnicodeAsciiEscape()
            case _ => fail("Unsupported escape sequence")
        }
    }

    private func validatedUtf8WidthAt(start: Int64): Int64 {
        let first = UInt8(data[start])
        if (first >= 0xC2u8 && first <= 0xDFu8) {
            requireUtf8Continuation(start + 1, 0x80u8, 0xBFu8, start)
            return 2
        }
        if (first >= 0xE0u8 && first <= 0xEFu8) {
            requireUtf8Continuation(start + 1,
                if (first == 0xE0u8) { 0xA0u8 } else { 0x80u8 },
                if (first == 0xEDu8) { 0x9Fu8 } else { 0xBFu8 }, start)
            requireUtf8Continuation(start + 2, 0x80u8, 0xBFu8, start)
            return 3
        }
        if (first >= 0xF0u8 && first <= 0xF4u8) {
            requireUtf8Continuation(start + 1,
                if (first == 0xF0u8) { 0x90u8 } else { 0x80u8 },
                if (first == 0xF4u8) { 0x8Fu8 } else { 0xBFu8 }, start)
            requireUtf8Continuation(start + 2, 0x80u8, 0xBFu8, start)
            requireUtf8Continuation(start + 3, 0x80u8, 0xBFu8, start)
            return 4
        }
        failAt("Invalid UTF-8 byte sequence", start)
    }

    private func requireUtf8Continuation(position: Int64, minimum: UInt8,
        maximum: UInt8, errorPosition: Int64): Unit {
        if (position >= size) { failAt("Invalid UTF-8 byte sequence", errorPosition) }
        let value = UInt8(data[position])
        if (value < minimum || value > maximum) {
            failAt("Invalid UTF-8 byte sequence", errorPosition)
        }
    }

    private func parseUnicodeAsciiEscape(): Int64 {
        let start = index
        var value: Int64 = 0
        for (_ in 0..4) {
            if (index >= size) {
                failAt("Incomplete unicode escape", start)
            }
            value = value * 16 + hexValue(data[index])
            index++
        }
        if (isJsonHighSurrogate(value)) {
            if (index + 2 > size || data[index] != b'\\' || data[index + 1] != b'u') {
                failAt("Invalid unicode surrogate pair", start)
            }
            index += 2
            let lowStart = index
            var low: Int64 = 0
            for (_ in 0..4) {
                if (index >= size) { failAt("Incomplete unicode escape", lowStart) }
                low = low * 16 + hexValue(data[index])
                index++
            }
            if (!isJsonLowSurrogate(low)) {
                failAt("Invalid unicode surrogate pair", start)
            }
            return -1
        }
        if (isJsonLowSurrogate(value)) {
            failAt("Invalid unicode surrogate pair", start)
        }
        if (value <= 0x7F) {
            return value
        }
        return -1
    }

    private func hexValue(value: Byte): Int64 {
        match {
            case value >= b'0' && value <= b'9' => Int64(value - b'0')
            case value >= b'a' && value <= b'f' => Int64(value - b'a') + 10
            case value >= b'A' && value <= b'F' => Int64(value - b'A') + 10
            case _ => fail("Invalid unicode escape")
        }
    }

    private func rejectFractionalOrExponentForInteger(): Unit {
        if (index < size && (data[index] == b'.' || data[index] == b'e' || data[index] == b'E')) {
            fail("Expected integer")
        }
    }

    private func stringFromUtf8Range(start: Int64, end: Int64): String {
        if (let Some(text) <- sourceText) {
            return try {
                text[start..end]
            } catch (_: Exception) {
                failAt("Invalid UTF-8 byte boundary", start)
            }
        }
        return try {
            String.fromUtf8(data[start..end])
        } catch (_: Exception) {
            failAt("Invalid UTF-8 byte sequence", start)
        }
    }

    private func asciiStringFromRange(start: Int64, end: Int64): String {
        if (let Some(text) <- sourceText) {
            return text[start..end]
        }
        unsafe {
            String.fromUtf8Unchecked(data[start..end])
        }
    }

    private func fail(message: String): Nothing {
        failAt(message, index)
    }

    private func failAt(message: String, offset: Int64): Nothing {
        throw JsonException(
            message,
            code: "parse_error",
            byteOffset: if (readConfig.includeErrorLocation) { offset } else { -1 },
            line: lineAt(offset),
            column: columnAt(offset)
        )
    }
}

class StreamInputCursor <: InputCursor {
    private let input: InputStream
    private let buffer: Array<Byte>
    private let readConfig: JsonReadConfig
    private var start: Int64 = 0
    private var end: Int64 = 0
    private var offset: Int64 = 0
    private var loadedBytes: Int64 = 0
    private var reachedEnd: Bool = false
    private let newlineOffsets = ArrayList<Int64>()

    public init(
        input: InputStream,
        bufferSize!: Int64 = 4096,
        config!: JsonReadConfig = JsonReadConfig.defaults
    ) {
        this.input = input
        this.buffer = Array<Byte>(bufferSize, repeat: 0)
        this.readConfig = config
    }

    public func hasMore(): Bool {
        ensureAvailable()
    }

    public func peek(): Byte {
        buffer[start]
    }

    public func consume(): Byte {
        let value = buffer[start]
        start++
        if (value == b'\n') { newlineOffsets.add(offset) }
        offset++
        value
    }

    public func position(): Int64 {
        offset
    }

    public func config(): JsonReadConfig {
        readConfig
    }

    public func lineAt(offset: Int64): Int64 {
        if (!readConfig.includeErrorLocation) { return -1 }
        jsonStreamLineAt(newlineOffsets, offset)
    }

    public func columnAt(offset: Int64): Int64 {
        if (!readConfig.includeErrorLocation) { return -1 }
        jsonStreamColumnAt(newlineOffsets, offset)
    }

    public func skipSpacesFast(): Unit {
        while (ensureAvailable()) {
            match (buffer[start]) {
                case b' ' | b'\n' | b'\r' | b'\t' => let _ = consume()
                case _ => return
            }
        }
    }

    public func consumeExpectedByteFast(value: Byte): Bool {
        if (!ensureAvailable() || buffer[start] != value) { return false }
        let _ = consume()
        true
    }

    // Consume only a complete simple ASCII string from this window. The
    // general semantic path handles escapes, UTF-8, and chunk boundaries.
    public func tryParseSimpleAsciiStringWindow(): Option<String> {
        if (!ensureAvailable() || buffer[start] != b'"') { return None<String> }
        let contentStart = start + 1
        var cursor = contentStart
        while (cursor < end) {
            let current = buffer[cursor]
            if (current == b'"') {
                let value = unsafe { String.fromUtf8Unchecked(buffer[contentStart..cursor]) }
                advanceWindow(cursor - start + 1)
                return Some(value)
            }
            if (current == b'\\' || current < 0x20 || current >= 0x80) {
                return None<String>
            }
            cursor++
        }
        None<String>
    }

    // Some(-1) means a complete unknown name. None leaves the cursor intact
    // for the escape-aware and cross-window matcher.
    public func tryParseNameIdWindow(candidates: Array<String>): Option<Int64> {
        if (!ensureAvailable() || buffer[start] != b'"') { return None<Int64> }
        let contentStart = start + 1
        var cursor = contentStart
        while (cursor < end) {
            let current = buffer[cursor]
            if (current == b'"') {
                let length = cursor - contentStart
                var result: Int64 = -1
                for (candidateIndex in 0..candidates.size) {
                    unsafe {
                        let bytes = candidates[candidateIndex].rawData()
                        if (bytes.size != length) { continue }
                        var matches = true
                        for (index in 0..length) {
                            if (bytes[index] != buffer[contentStart + index]) {
                                matches = false
                                break
                            }
                        }
                        if (matches) {
                            result = candidateIndex
                            break
                        }
                    }
                }
                advanceWindow(cursor - start + 1)
                return Some(result)
            }
            if (current == b'\\' || current < 0x20 || current >= 0x80) {
                return None<Int64>
            }
            cursor++
        }
        None<Int64>
    }

    // Parse only a complete valid Int64 token visible in this window. Invalid
    // or boundary-spanning tokens stay untouched for the shared parser.
    public func tryParseInt64Window(): Option<Int64> {
        if (!ensureAvailable()) { return None<Int64> }
        var cursor = start
        let negative = buffer[cursor] == b'-'
        if (negative) {
            cursor++
            if (cursor >= end) { return None<Int64> }
        }
        if (buffer[cursor] < b'0' || buffer[cursor] > b'9') { return None<Int64> }
        if (buffer[cursor] == b'0' && cursor + 1 < end &&
            buffer[cursor + 1] >= b'0' && buffer[cursor + 1] <= b'9') {
            return None<Int64>
        }
        var result: Int64 = 0
        while (cursor < end && buffer[cursor] >= b'0' && buffer[cursor] <= b'9') {
            let digit = Int64(buffer[cursor] - b'0')
            if (negative) {
                if (result < ((-0x8000_0000_0000_0000 + digit) / 10)) {
                    return None<Int64>
                }
                result = result * 10 - digit
            } else {
                if (result > ((0x7FFF_FFFF_FFFF_FFFF - digit) / 10)) {
                    return None<Int64>
                }
                result = result * 10 + digit
            }
            cursor++
        }
        if (cursor == end) { return None<Int64> }
        match (buffer[cursor]) {
            case b',' | b']' | b'}' | b' ' | b'\n' | b'\r' | b'\t' => ()
            case _ => return None<Int64>
        }
        advanceWindow(cursor - start)
        Some(result)
    }

    private func advanceWindow(count: Int64): Unit {
        for (_ in 0..count) { let _ = consume() }
    }

    private func ensureAvailable(): Bool {
        if (start < end) {
            return true
        }
        if (reachedEnd) {
            return false
        }
        let read = input.read(buffer)
        if (read == 0) {
            reachedEnd = true
            return false
        }
        if (readConfig.maxBytes > 0 && loadedBytes + read > readConfig.maxBytes) {
            throw jsonResourceLimitException(readConfig,
                "JSON document exceeds ${readConfig.maxBytes} bytes", "document_too_large",
                readConfig.maxBytes)
        }
        loadedBytes += read
        start = 0
        end = read
        true
    }
}

private class JsonParserCore {
    private let source: InputCursor
    private let config: JsonReadConfig
    private var containerDepth: Int64 = 0

    public init(source: InputCursor) {
        this.source = source
        this.config = source.config()
    }

    public func parse(): JsonNode {
        match (source) {
            case arraySource: Utf8Cursor =>
                if (config.maxStringBytes == 0 && config.maxPolymorphicObjectBytes == 0) {
                    return parseFast(arraySource)
                }
            case _ => ()
        }
        skipSpaces()
        if (config.maxPolymorphicObjectBytes > 0 && source.hasMore() &&
            (source.peek() == b'[' || source.peek() == b'{')) {
            source.beginValueBudget(config.maxPolymorphicObjectBytes)
        }
        let value = parseValue()
        source.endValueBudget()
        skipSpaces()
        if (source.hasMore()) {
            fail("Unexpected trailing input")
        }
        value
    }

    private func consumeByte(): Byte {
        source.consumeJsonByte()
    }

    private func parseFast(arraySource: Utf8Cursor): JsonNode {
        arraySource.skipSpacesFast()
        let value = parseValueFast(arraySource)
        arraySource.skipSpacesFast()
        if (arraySource.hasMore()) {
            failAt("Unexpected trailing input", arraySource.position())
        }
        value
    }

    private func parseValueFast(arraySource: Utf8Cursor): JsonNode {
        if (!arraySource.hasMore()) {
            failAt("Unexpected end of input", arraySource.position())
        }
        let start = arraySource.peek()
        match {
            case start == b'n' =>
                arraySource.expectLiteralFast("null")
                JsonNullValue()
            case start == b't' =>
                arraySource.expectLiteralFast("true")
                JsonBoolValue(true)
            case start == b'f' =>
                arraySource.expectLiteralFast("false")
                JsonBoolValue(false)
            case start == b'"' => JsonStringValue(parseStringFast(arraySource))
            case start == b'[' => parseArrayFast(arraySource)
            case start == b'{' => parseObjectFast(arraySource)
            case start == b'-' || (start >= b'0' && start <= b'9') => arraySource.parseNumberFast()
            case _ => failAt("Unexpected token", arraySource.position())
        }
    }

    private func parseValue(): JsonNode {
        if (!source.hasMore()) {
            fail("Unexpected end of input")
        }
        let start = source.peek()
        match {
            case start == b'n' => parseNull()
            case start == b't' || start == b'f' => parseBool()
            case start == b'"' => JsonStringValue(parseString())
            case start == b'[' => parseArray()
            case start == b'{' => parseObject()
            case start == b'-' || (start >= b'0' && start <= b'9') => parseNumber()
            case _ => fail("Unexpected token")
        }
    }

    private func parseNull(): JsonNode {
        expectLiteral("null")
        JsonNullValue()
    }

    private func parseBool(): JsonNode {
        if (source.peek() == b't') {
            expectLiteral("true")
            return JsonBoolValue(true)
        }
        expectLiteral("false")
        JsonBoolValue(false)
    }

    private func parseNumber(): JsonNode {
        match (source) {
            case arraySource: Utf8Cursor =>
                if (!source.isValueBudgetActive()) { return arraySource.parseNumberFast() }
            case _ => ()
        }
        let literalText = source.readJsonNumberLiteral()
        let hasFractionalSyntax = literalText.contains(".") || literalText.contains("e") || literalText.contains("E")
        buildParsedNumberValue(literalText, hasFractionalSyntax)
    }

    private func buildParsedNumberValue(literal: String, hasFractionalSyntax: Bool): JsonNode {
        if (jsonReadConfigPreservesNumberLiterals(config)) {
            return JsonNumberLiteralValue.fromParsedLiteral(literal)
        }
        if (hasFractionalSyntax) {
            return JsonNumberLiteralValue.fromParsedLiteral(literal)
        }
        return try {
            JsonIntValue(Int64.parse(literal))
        } catch (_: Exception) {
            JsonNumberLiteralValue.fromParsedLiteral(literal)
        }
    }

    private func parseString(): String {
        source.readJsonString()
    }

    private func parseStringFast(arraySource: Utf8Cursor): String {
        if (let Some(value) <- arraySource.tryParseSimpleString()) {
            return value
        }
        parseString()
    }

    private func parseArrayFast(arraySource: Utf8Cursor): JsonNode {
        enterContainer(arraySource.position())
        try {
        arraySource.expectByteFast(b'[')
        arraySource.skipSpacesFast()
        let items = ArrayList<JsonNode>(4)
        if (arraySource.peekByteFast(b']')) {
            arraySource.consume()
            return JsonArrayValue(items)
        }
        while (true) {
            items.add(parseValueFast(arraySource))
            arraySource.skipSpacesFast()
            if (arraySource.peekByteFast(b']')) {
                arraySource.consume()
                break
            }
            arraySource.expectByteFast(b',')
            arraySource.skipSpacesFast()
        }
        JsonArrayValue(items)
        } finally {
            leaveContainer()
        }
    }

    private func parseArray(): JsonNode {
        enterContainer(source.position())
        try {
        expectByte(b'[')
        skipSpaces()
        let items = ArrayList<JsonNode>()
        if (peekByte(b']')) {
            consumeByte()
            return JsonArrayValue(items)
        }
        while (true) {
            items.add(parseValue())
            skipSpaces()
            if (peekByte(b']')) {
                consumeByte()
                break
            }
            expectByte(b',')
            skipSpaces()
        }
        JsonArrayValue(items)
        } finally {
            leaveContainer()
        }
    }

    private func parseObjectFast(arraySource: Utf8Cursor): JsonNode {
        enterContainer(arraySource.position())
        try {
        arraySource.expectByteFast(b'{')
        arraySource.skipSpacesFast()
        let fields = HashMap<String, JsonNode>(8)
        if (arraySource.peekByteFast(b'}')) {
            arraySource.consume()
            return JsonObjectValue(fields)
        }
        while (true) {
            if (!arraySource.peekByteFast(b'"')) {
                failAt("Expected object key", arraySource.position())
            }
            let key = parseStringFast(arraySource)
            arraySource.skipSpacesFast()
            arraySource.expectByteFast(b':')
            arraySource.skipSpacesFast()
            if (jsonReadConfigRejectsDuplicateKeys(config) && fields.contains(key)) {
                policyFailAt("Duplicate object key '${key}'", "duplicate_key", arraySource.position())
            }
            fields.add(key, parseValueFast(arraySource))
            arraySource.skipSpacesFast()
            if (arraySource.peekByteFast(b'}')) {
                arraySource.consume()
                break
            }
            arraySource.expectByteFast(b',')
            arraySource.skipSpacesFast()
        }
        JsonObjectValue(fields)
        } finally {
            leaveContainer()
        }
    }

    private func parseObject(): JsonNode {
        enterContainer(source.position())
        try {
        expectByte(b'{')
        skipSpaces()
        let fields = HashMap<String, JsonNode>()
        if (peekByte(b'}')) {
            consumeByte()
            return JsonObjectValue(fields)
        }
        while (true) {
            if (!peekByte(b'"')) {
                fail("Expected object key")
            }
            let key = parseString()
            skipSpaces()
            expectByte(b':')
            skipSpaces()
            if (jsonReadConfigRejectsDuplicateKeys(config) && fields.contains(key)) {
                policyFailAt("Duplicate object key '${key}'", "duplicate_key", source.position())
            }
            fields.add(key, parseValue())
            skipSpaces()
            if (peekByte(b'}')) {
                consumeByte()
                break
            }
            expectByte(b',')
            skipSpaces()
        }
        JsonObjectValue(fields)
        } finally {
            leaveContainer()
        }
    }

    private func enterContainer(offset: Int64): Unit {
        if (containerDepth >= config.maxDepth) {
            throw jsonResourceLimitException(config,
                "Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", offset)
        }
        containerDepth++
    }

    private func leaveContainer(): Unit {
        if (containerDepth > 0) { containerDepth-- }
    }

    private func policyFailAt(message: String, code: String, offset: Int64): Nothing {
        throw JsonException(
            message,
            code: code,
            byteOffset: if (config.includeErrorLocation) { offset } else { -1 },
            line: source.lineAt(offset),
            column: source.columnAt(offset)
        )
    }

    private func skipSpaces(): Unit {
        source.skipJsonWhitespace()
    }

    private func expectLiteral(literal: String): Unit {
        for (byte in unsafe { literal.rawData() }) {
            if (!source.hasMore() || source.peek() != byte) {
                fail("Expected ${literal}")
            }
            consumeByte()
        }
    }

    private func expectByte(value: Byte): Unit {
        match (source) {
            case arraySource: Utf8Cursor =>
                if (!source.isValueBudgetActive()) {
                    arraySource.expectByteFast(value)
                    return
                }
            case _ => ()
        }
        if (!source.hasMore() || source.peek() != value) {
            fail("Unexpected token")
        }
        consumeByte()
    }

    private func peekByte(value: Byte): Bool {
        match (source) {
            case arraySource: Utf8Cursor => return arraySource.peekByteFast(value)
            case _ => ()
        }
        source.hasMore() && source.peek() == value
    }

    private func fail(message: String): Nothing {
        failAt(message, source.position())
    }

    private func failAt(message: String, offset: Int64): Nothing {
        throw JsonException(
            message,
            code: "parse_error",
            byteOffset: if (config.includeErrorLocation) { offset } else { -1 },
            line: source.lineAt(offset),
            column: source.columnAt(offset)
        )
    }
}

func parseJsonValueFromText(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
    JsonParserCore(Utf8Cursor(text, config: config)).parse()
}

func parseJsonValueFromBytes(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
    JsonParserCore(Utf8Cursor(bytes, config: config)).parse()
}

func parseJsonValueFromInputStream(
    input: InputStream,
    config!: JsonReadConfig = JsonReadConfig.defaults
): JsonNode {
    JsonParserCore(StreamInputCursor(input, config: config)).parse()
}
