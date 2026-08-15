package yjson

import std.collection.*
import std.convert.Parsable
import std.io.*

private abstract class JsonByteSource {
    public func hasMore(): Bool

    public func peek(): Byte

    public func consume(): Byte

    public func position(): Int64

    public func config(): JsonReadConfig

    public func lineAt(offset: Int64): Int64

    public func columnAt(offset: Int64): Int64
}

private class ArrayJsonByteSource <: JsonByteSource {
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
    }

    public init(text: String, config!: JsonReadConfig = JsonReadConfig.defaults) {
        unsafe {
            this.data = text.rawData()
        }
        this.size = data.size
        this.sourceText = Some(text)
        this.readConfig = config
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

    public func parseNumberFast(): JsonValue {
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
                return JsonNumberLiteralValue(asciiStringFromRange(start, index))
            }
            if (jsonReadConfigPreservesNumberLiterals(readConfig)) {
                return JsonNumberLiteralValue(asciiStringFromRange(start, index))
            }
            return if (overflow) {
                JsonNumberLiteralValue(asciiStringFromRange(start, index))
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
            return JsonNumberLiteralValue(asciiStringFromRange(start, index))
        }
        if (jsonReadConfigPreservesNumberLiterals(readConfig)) {
            return JsonNumberLiteralValue(asciiStringFromRange(start, index))
        }
        if (overflow) {
            return JsonNumberLiteralValue(asciiStringFromRange(start, index))
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

private class StreamJsonByteSource <: JsonByteSource {
    private let input: InputStream
    private let buffer: Array<Byte>
    private let readConfig: JsonReadConfig
    private var start: Int64 = 0
    private var end: Int64 = 0
    private var offset: Int64 = 0
    private var reachedEnd: Bool = false

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
        let _ = offset
        -1
    }

    public func columnAt(offset: Int64): Int64 {
        let _ = offset
        -1
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
        start = 0
        end = read
        true
    }
}

private class JsonParserCore {
    private let source: JsonByteSource
    private let config: JsonReadConfig

    public init(source: JsonByteSource) {
        this.source = source
        this.config = source.config()
    }

    public func parse(): JsonValue {
        match (source) {
            case arraySource: ArrayJsonByteSource => return parseFast(arraySource)
            case _ => ()
        }
        skipSpaces()
        let value = parseValue()
        skipSpaces()
        if (source.hasMore()) {
            fail("Unexpected trailing input")
        }
        value
    }

    private func parseFast(arraySource: ArrayJsonByteSource): JsonValue {
        arraySource.skipSpacesFast()
        let value = parseValueFast(arraySource)
        arraySource.skipSpacesFast()
        if (arraySource.hasMore()) {
            failAt("Unexpected trailing input", arraySource.position())
        }
        value
    }

    private func parseValueFast(arraySource: ArrayJsonByteSource): JsonValue {
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

    private func parseValue(): JsonValue {
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

    private func parseNull(): JsonValue {
        expectLiteral("null")
        JsonNullValue()
    }

    private func parseBool(): JsonValue {
        if (source.peek() == b't') {
            expectLiteral("true")
            return JsonBoolValue(true)
        }
        expectLiteral("false")
        JsonBoolValue(false)
    }

    private func parseNumber(): JsonValue {
        match (source) {
            case arraySource: ArrayJsonByteSource => return arraySource.parseNumberFast()
            case _ => ()
        }
        let literal = StringBuilder()
        var hasFractionalSyntax = false
        if (source.peek() == b'-') {
            literal.append(Rune(source.consume()))
        }
        parseIntegerDigitsInto(literal)
        if (source.hasMore() && source.peek() == b'.') {
            hasFractionalSyntax = true
            literal.append(Rune(source.consume()))
            requireDigit("Expected fractional digits")
            parseDigitsInto(literal)
        }
        if (source.hasMore() && (source.peek() == b'e' || source.peek() == b'E')) {
            hasFractionalSyntax = true
            literal.append(Rune(source.consume()))
            if (source.hasMore() && (source.peek() == b'+' || source.peek() == b'-')) {
                literal.append(Rune(source.consume()))
            }
            requireDigit("Expected exponent digits")
            parseDigitsInto(literal)
        }
        let literalText = literal.toString()
        buildParsedNumberValue(literalText, hasFractionalSyntax)
    }

    private func buildParsedNumberValue(literal: String, hasFractionalSyntax: Bool): JsonValue {
        if (jsonReadConfigPreservesNumberLiterals(config)) {
            return JsonNumberLiteralValue(literal)
        }
        if (hasFractionalSyntax) {
            return JsonNumberLiteralValue(literal)
        }
        return try {
            JsonIntValue(Int64.parse(literal))
        } catch (_: Exception) {
            JsonNumberLiteralValue(literal)
        }
    }

    private func parseDigitsInto(buffer: StringBuilder): Unit {
        requireDigit("Expected digit")
        while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
            buffer.append(Rune(source.consume()))
        }
    }

    private func parseIntegerDigitsInto(buffer: StringBuilder): Unit {
        requireDigit("Expected digit")
        if (source.peek() == b'0') {
            buffer.append(Rune(source.consume()))
            if (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
                fail("Leading zeroes are not allowed in JSON numbers")
            }
            return
        }
        parseDigitsInto(buffer)
    }

    private func requireDigit(message: String): Unit {
        if (!source.hasMore() || source.peek() < b'0' || source.peek() > b'9') {
            fail(message)
        }
    }

    private func parseString(): String {
        match (source) {
            case arraySource: ArrayJsonByteSource =>
                if (let Some(value) <- arraySource.tryParseSimpleString()) {
                    return value
                }
            case _ => ()
        }
        expectByte(b'"')
        let builder = StringBuilder()
        while (source.hasMore()) {
            let start = source.position()
            let current = source.consume()
            match (current) {
                case b'"' => return builder.toString()
                case b'\\' =>
                    if (!source.hasMore()) {
                        fail("Unexpected end of escape sequence")
                    }
                    let escaped = source.consume()
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
                case _ =>
                    if (current < 0x80) {
                        if (current < 0x20) {
                            failAt("Unescaped control character in string literal", start)
                        }
                        builder.append(Rune(current))
                    } else {
                        builder.append(decodeUtf8Rune(current, start))
                    }
            }
        }
        fail("Unterminated string literal")
    }

    private func parseStringFast(arraySource: ArrayJsonByteSource): String {
        if (let Some(value) <- arraySource.tryParseSimpleString()) {
            return value
        }
        parseString()
    }

    private func parseUnicodeEscape(): Rune {
        let start = source.position()
        if (!source.hasMore()) {
            fail("Incomplete unicode escape")
        }
        let value = parseUnicodeEscapeValue(start)
        if (isJsonHighSurrogate(value)) {
            if (!source.hasMore() || source.consume() != b'\\' || !source.hasMore() || source.consume() != b'u') {
                failAt("Invalid unicode surrogate pair", start)
            }
            let lowStart = source.position()
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
        var value: Int64 = 0
        for (_ in 0..4) {
            if (!source.hasMore()) {
                failAt("Incomplete unicode escape", start)
            }
            value = value * 16 + hexValue(source.consume())
        }
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
        for (index in 1..width) {
            if (!source.hasMore()) {
                failAt("Invalid UTF-8 byte sequence", start)
            }
            bytes[index] = UInt8(source.consume())
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

    private func parseArrayFast(arraySource: ArrayJsonByteSource): JsonValue {
        arraySource.expectByteFast(b'[')
        arraySource.skipSpacesFast()
        let items = ArrayList<JsonValue>(4)
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
    }

    private func parseArray(): JsonValue {
        expectByte(b'[')
        skipSpaces()
        let items = ArrayList<JsonValue>()
        if (peekByte(b']')) {
            source.consume()
            return JsonArrayValue(items)
        }
        while (true) {
            items.add(parseValue())
            skipSpaces()
            if (peekByte(b']')) {
                source.consume()
                break
            }
            expectByte(b',')
            skipSpaces()
        }
        JsonArrayValue(items)
    }

    private func parseObjectFast(arraySource: ArrayJsonByteSource): JsonValue {
        arraySource.expectByteFast(b'{')
        arraySource.skipSpacesFast()
        let fields = HashMap<String, JsonValue>(8)
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
                failAt("Duplicate object key '${key}'", arraySource.position())
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
    }

    private func parseObject(): JsonValue {
        expectByte(b'{')
        skipSpaces()
        let fields = HashMap<String, JsonValue>()
        if (peekByte(b'}')) {
            source.consume()
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
                fail("Duplicate object key '${key}'")
            }
            fields.add(key, parseValue())
            skipSpaces()
            if (peekByte(b'}')) {
                source.consume()
                break
            }
            expectByte(b',')
            skipSpaces()
        }
        JsonObjectValue(fields)
    }

    private func skipSpaces(): Unit {
        match (source) {
            case arraySource: ArrayJsonByteSource =>
                arraySource.skipSpacesFast()
                return
            case _ => ()
        }
        while (source.hasMore()) {
            match (source.peek()) {
                case b' ' | b'\n' | b'\r' | b'\t' => source.consume()
                case _ => return
            }
        }
    }

    private func expectLiteral(literal: String): Unit {
        for (byte in unsafe { literal.rawData() }) {
            if (!source.hasMore() || source.consume() != byte) {
                fail("Expected ${literal}")
            }
        }
    }

    private func expectByte(value: Byte): Unit {
        match (source) {
            case arraySource: ArrayJsonByteSource =>
                arraySource.expectByteFast(value)
                return
            case _ => ()
        }
        if (!source.hasMore() || source.consume() != value) {
            fail("Unexpected token")
        }
    }

    private func peekByte(value: Byte): Bool {
        match (source) {
            case arraySource: ArrayJsonByteSource => return arraySource.peekByteFast(value)
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

func parseJsonValueFromText(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonValue {
    JsonParserCore(ArrayJsonByteSource(text, config: config)).parse()
}

func parseJsonValueFromBytes(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonValue {
    JsonParserCore(ArrayJsonByteSource(bytes, config: config)).parse()
}

func parseJsonValueFromInputStream(
    input: InputStream,
    config!: JsonReadConfig = JsonReadConfig.defaults
): JsonValue {
    JsonParserCore(StreamJsonByteSource(input, config: config)).parse()
}
