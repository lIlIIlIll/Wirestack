package yjson

import std.collection.*
import std.convert.Parsable
import std.io.*
import std.math.numeric.*

private abstract class JsonDirectByteSource {
    public func hasMore(): Bool

    public func peek(): Byte

    public func consume(): Byte

    public func position(): Int64

    public func config(): JsonReadConfig

    public func lineAt(offset: Int64): Int64

    public func columnAt(offset: Int64): Int64
}

private class ArrayJsonDirectByteSource <: JsonDirectByteSource {
    private let data: Array<Byte>
    private let size: Int64
    private let readConfig: JsonReadConfig
    private var index: Int64 = 0

    public init(data: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults) {
        this.data = data
        this.size = data.size
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
                code = Int64(current)
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

    public func tryParseSimpleString(): Option<String> {
        let quotePosition = index
        expectByteFast(b'"')
        let start = index
        while (index < size) {
            let current = data[index]
            if (current == b'"') {
                let end = index
                index++
                return try {
                    Some(String.fromUtf8(data[start..end]))
                } catch (_: Exception) {
                    failAt("Invalid UTF-8 byte sequence", start)
                }
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

private class StreamJsonDirectByteSource <: JsonDirectByteSource {
    private let input: InputStream
    private let buffer: Array<Byte>
    private let readConfig: JsonReadConfig
    private var start: Int64 = 0
    private var end: Int64 = 0
    private var offset: Int64 = 0
    private var loadedBytes: Int64 = 0
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

private class JsonDirectReadContext {
    public let objectContext: Bool
    public var first: Bool = true
    public var expectingFieldValue: Bool = false
    public let seenNames = HashSet<String>()

    public init(objectContext: Bool) {
        this.objectContext = objectContext
    }
}

public class JsonDirectReader <: JsonCodecReader {
    private let source: JsonDirectByteSource
    private let config: JsonReadConfig
    private let streaming: Bool
    private let contexts = ArrayList<JsonDirectReadContext>()
    private var valuePrefixReady: Bool = false
    private var rootBudgetStart: Int64 = -1
    private var rootBudgetActive: Bool = false
    private var lastUnicodeEscapeBytes: Int64 = 0

    public init(text: String, config!: JsonReadConfig = JsonReadConfig.defaults) {
        unsafe {
            source = ArrayJsonDirectByteSource(text.rawData(), config: config)
        }
        this.config = config
        this.streaming = false
    }

    public init(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults) {
        source = ArrayJsonDirectByteSource(bytes, config: config)
        this.config = config
        this.streaming = false
    }

    public init(input: InputStream, config!: JsonReadConfig = JsonReadConfig.defaults) {
        source = StreamJsonDirectByteSource(input, config: config)
        this.config = config
        this.streaming = true
    }

    public func readConfig(): JsonReadConfig {
        config
    }

    public func readReplayValue(maxBytes: Int64): JsonReplayValue {
        JsonNodeReplayValue(readBoundedValue(maxBytes), config)
    }

    // Materializes exactly one value while enforcing the byte budget against
    // the original input. Zero disables this local budget, matching
    // JsonReadConfig's public resource-limit semantics. This is reserved for
    // discriminator-based decoding, where the subtype is unknown until part
    // of the object has been read.
    public func readBoundedValue(maxBytes: Int64): JsonNode {
        if (maxBytes < 0) { throw IllegalArgumentException("maxBytes must not be negative") }
        let start = source.position()
        readBoundedValueFrom(start, maxBytes, 0)
    }

    private func ensureValueBudget(start: Int64, maxBytes: Int64): Unit {
        if (maxBytes > 0 && source.position() - start > maxBytes) {
            throw JsonException(
                "Polymorphic JSON object exceeds ${maxBytes} bytes",
                code: "polymorphic_object_too_large"
            )
        }
    }

    private func readBoundedValueFrom(start: Int64, maxBytes: Int64, depth: Int64): JsonNode {
        if (depth >= config.maxDepth) {
            throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
        }
        beforeValue()
        ensureValueBudget(start, maxBytes)
        if (!source.hasMore()) { fail("Unexpected end of input") }
        valuePrefixReady = true
        let current = source.peek()
        let value: JsonNode = match {
            case current == b'n' => readNull(); JsonNullValue()
            case current == b't' || current == b'f' => JsonBoolValue(readBool())
            case current == b'"' => JsonStringValue(readString())
            case current == b'[' =>
                let items = ArrayList<JsonNode>()
                startArray()
                while (hasArrayItem()) {
                    items.add(readBoundedValueFrom(start, maxBytes, depth + 1))
                    ensureValueBudget(start, maxBytes)
                }
                endArray()
                JsonArrayValue(items)
            case current == b'{' =>
                let fields = HashMap<String, JsonNode>()
                startObject()
                while (hasObjectField()) {
                    let name = readName()
                    fields.add(name, readBoundedValueFrom(start, maxBytes, depth + 1))
                    ensureValueBudget(start, maxBytes)
                }
                endObject()
                JsonObjectValue(fields)
            case current == b'-' || (current >= b'0' && current <= b'9') => JsonNumberLiteralValue(readNumberLiteral())
            case _ => fail("Unexpected token")
        }
        ensureValueBudget(start, maxBytes)
        value
    }

    public func expectEnd(): Unit {
        skipSpaces()
        if (source.hasMore()) {
            fail("Unexpected trailing input")
        }
    }

    public func startObject(): Unit {
        beforeValue()
        beginRootBudgetIfNeeded()
        expectByte(b'{')
        contexts.add(JsonDirectReadContext(true))
    }

    public func endObject(): Unit {
        let wasRoot = contexts.size == 1 && rootBudgetActive
        let context = popContext(true)
        if (context.expectingFieldValue) {
            fail("Expected object field value")
        }
        skipSpaces()
        expectByte(b'}')
        if (wasRoot) { rootBudgetActive = false }
    }

    public func hasObjectField(): Bool {
        if (contexts.isEmpty() || !contexts[contexts.size - 1].objectContext) {
            fail("Not reading an object")
        }
        skipSpaces()
        source.hasMore() && source.peek() != b'}'
    }

    public func readName(): String {
        beforeName()
        let name = parseString()
        rejectNameIfConfigured(name)
        afterName()
        name
    }

    public func readNameId(candidates: Array<String>): Int64 {
        beforeName()
        let id = parseNameId(candidates)
        if (id < 0) {
            if (jsonReadConfigRejectsUnknownFields(config)) {
                fail("Unknown JSON field")
            }
        } else {
            rejectNameIfConfigured(candidates[id])
        }
        afterName()
        id
    }

    private func rejectNameIfConfigured(name: String): Unit {
        if (!jsonReadConfigRejectsDuplicateKeys(config)) {
            return
        }
        let context = contexts[contexts.size - 1]
        if (context.seenNames.contains(name)) {
            fail("Duplicate object key '${name}'")
        }
        context.seenNames.add(name)
    }

    private func beforeName(): Unit {
        if (contexts.isEmpty()) {
            fail("Cannot read field name outside object")
        }
        let context = contexts[contexts.size - 1]
        if (!context.objectContext || context.expectingFieldValue) {
            fail("Cannot read field name here")
        }
        skipSpaces()
        if (context.first) {
            context.first = false
        } else {
            expectByte(b',')
            skipSpaces()
        }
    }

    private func afterName(): Unit {
        let context = contexts[contexts.size - 1]
        skipSpaces()
        expectByte(b':')
        context.expectingFieldValue = true
    }

    public func startArray(): Unit {
        beforeValue()
        beginRootBudgetIfNeeded()
        expectByte(b'[')
        contexts.add(JsonDirectReadContext(false))
    }

    public func endArray(): Unit {
        let wasRoot = contexts.size == 1 && rootBudgetActive
        let context = popContext(false)
        skipSpaces()
        expectByte(b']')
        if (wasRoot) { rootBudgetActive = false }
        let _ = context
    }

    public func hasArrayItem(): Bool {
        if (contexts.isEmpty() || contexts[contexts.size - 1].objectContext) {
            fail("Not reading an array")
        }
        skipSpaces()
        source.hasMore() && source.peek() != b']'
    }

    public func tryReadNull(): Bool {
        beforeValue()
        skipSpaces()
        if (!source.hasMore() || source.peek() != b'n') {
            valuePrefixReady = true
            return false
        }
        expectLiteral("null")
        true
    }

    public func readNull(): Unit {
        beforeValue()
        expectLiteral("null")
    }

    public func readBool(): Bool {
        beforeValue()
        if (source.peek() == b't') {
            expectLiteral("true")
            return true
        }
        expectLiteral("false")
        false
    }

    public func readString(): String {
        beforeValue()
        parseString()
    }

    public func skipString(): Unit {
        beforeValue()
        scanRawString()
    }

    public func readInt64(): Int64 {
        beforeValue()
        parseInt64Literal()
    }

    public func readUInt64(): UInt64 {
        beforeValue()
        parseUInt64Literal()
    }

    public func readFloat64(): Float64 {
        Float64.parse(readNumberLiteral())
    }

    public func readBigInt(): BigInt {
        BigInt.parse(readNumberLiteral())
    }

    public func readDecimal(): Decimal {
        Decimal.parse(readNumberLiteral())
    }

    public func readNumberLiteral(): String {
        beforeValue()
        parseNumberLiteral()
    }

    public func skipValue(): Unit {
        beforeValue()
        if (source.hasMore() && (source.peek() == b'[' || source.peek() == b'{')) {
            beginRootBudgetIfNeeded()
        }
        skipRawValue()
        if (contexts.isEmpty()) { rootBudgetActive = false }
    }

    private func beforeValue(): Unit {
        if (valuePrefixReady) {
            valuePrefixReady = false
            return
        }
        if (contexts.isEmpty()) {
            skipSpaces()
            return
        }
        let context = contexts[contexts.size - 1]
        if (context.objectContext) {
            if (!context.expectingFieldValue) {
                fail("Object values must follow a field name")
            }
            context.expectingFieldValue = false
            skipSpaces()
            return
        }
        skipSpaces()
        if (context.first) {
            context.first = false
            return
        }
        expectByte(b',')
        skipSpaces()
    }

    private func beginRootBudgetIfNeeded(): Unit {
        if (streaming && !rootBudgetActive && contexts.isEmpty() &&
            config.maxPolymorphicObjectBytes > 0) {
            rootBudgetStart = source.position()
            rootBudgetActive = true
        }
    }

    private func consumeByte(): Byte {
        let value = source.consume()
        if (rootBudgetActive && source.position() - rootBudgetStart > config.maxPolymorphicObjectBytes) {
            throw jsonResourceLimitException(config,
                "JSON value exceeds ${config.maxPolymorphicObjectBytes} bytes",
                "polymorphic_object_too_large", rootBudgetStart + config.maxPolymorphicObjectBytes)
        }
        value
    }

    private func addDecodedStringBytes(current: Int64, added: Int64, offset: Int64): Int64 {
        let next = current + added
        if (config.maxStringBytes > 0 && next > config.maxStringBytes) {
            throw jsonResourceLimitException(config,
                "JSON string exceeds ${config.maxStringBytes} decoded UTF-8 bytes",
                "string_too_large", offset)
        }
        next
    }

    private func popContext(expectedObject: Bool): JsonDirectReadContext {
        if (contexts.isEmpty()) {
            fail("Unbalanced JSON reader state")
        }
        let index = contexts.size - 1
        let context = contexts[index]
        if (context.objectContext != expectedObject) {
            fail("Unbalanced JSON reader state")
        }
        contexts.remove(at: index)
        context
    }

    private func skipRawValue(): Unit {
        skipSpaces()
        if (!source.hasMore()) {
            fail("Unexpected end of input")
        }
        let current = source.peek()
        match {
            case current == b'n' => expectLiteral("null")
            case current == b't' => expectLiteral("true")
            case current == b'f' => expectLiteral("false")
            case current == b'"' =>
                scanRawString()
            case current == b'[' => skipRawArray()
            case current == b'{' => skipRawObject()
            case current == b'-' || (current >= b'0' && current <= b'9') =>
                skipNumberLiteral()
            case _ => fail("Unexpected token")
        }
    }

    private func skipRawArray(): Unit {
        expectByte(b'[')
        skipSpaces()
        if (source.hasMore() && source.peek() == b']') {
            consumeByte()
            return
        }
        while (true) {
            skipRawValue()
            skipSpaces()
            if (source.hasMore() && source.peek() == b']') {
                consumeByte()
                return
            }
            expectByte(b',')
        }
    }

    private func skipRawObject(): Unit {
        expectByte(b'{')
        skipSpaces()
        if (source.hasMore() && source.peek() == b'}') {
            consumeByte()
            return
        }
        while (true) {
            scanRawString()
            skipSpaces()
            expectByte(b':')
            skipRawValue()
            skipSpaces()
            if (source.hasMore() && source.peek() == b'}') {
                consumeByte()
                return
            }
            expectByte(b',')
        }
    }

    private func skipNumberLiteral(): Unit {
        skipSpaces()
        if (source.hasMore() && source.peek() == b'-') {
            consumeByte()
        }
        skipIntegerDigits()
        if (source.hasMore() && source.peek() == b'.') {
            consumeByte()
            requireDigit("Expected fractional digits")
            skipDigits()
        }
        if (source.hasMore() && (source.peek() == b'e' || source.peek() == b'E')) {
            consumeByte()
            if (source.hasMore() && (source.peek() == b'+' || source.peek() == b'-')) {
                consumeByte()
            }
            requireDigit("Expected exponent digits")
            skipDigits()
        }
    }

    private func skipDigits(): Unit {
        requireDigit("Expected digit")
        while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
            consumeByte()
        }
    }

    private func skipIntegerDigits(): Unit {
        requireDigit("Expected digit")
        if (source.peek() == b'0') {
            consumeByte()
            rejectLeadingZeroFromSource()
            return
        }
        skipDigits()
    }

    private func parseNumberLiteral(): String {
        skipSpaces()
        let literal = StringBuilder()
        if (source.hasMore() && source.peek() == b'-') {
            literal.append(Rune(consumeByte()))
        }
        parseIntegerDigitsInto(literal)
        if (source.hasMore() && source.peek() == b'.') {
            literal.append(Rune(consumeByte()))
            requireDigit("Expected fractional digits")
            parseDigitsInto(literal)
        }
        if (source.hasMore() && (source.peek() == b'e' || source.peek() == b'E')) {
            literal.append(Rune(consumeByte()))
            if (source.hasMore() && (source.peek() == b'+' || source.peek() == b'-')) {
                literal.append(Rune(consumeByte()))
            }
            requireDigit("Expected exponent digits")
            parseDigitsInto(literal)
        }
        literal.toString()
    }

    private func parseInt64Literal(): Int64 {
        match (source) {
            case arraySource: ArrayJsonDirectByteSource => return arraySource.parseInt64LiteralFast()
            case _ => ()
        }
        skipSpaces()
        if (!source.hasMore()) {
            fail("Expected integer")
        }
        if (source.peek() == b'-') {
            consumeByte()
            requireDigit("Expected digit")
            var result: Int64 = 0
            if (source.peek() == b'0') {
                consumeByte()
                rejectLeadingZeroFromSource()
            } else {
                while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
                    let digit = Int64(consumeByte() - b'0')
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
        if (source.peek() == b'0') {
            consumeByte()
            rejectLeadingZeroFromSource()
        } else {
            while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
                let digit = Int64(consumeByte() - b'0')
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
        match (source) {
            case arraySource: ArrayJsonDirectByteSource => return arraySource.parseUInt64LiteralFast()
            case _ => ()
        }
        skipSpaces()
        if (!source.hasMore() || source.peek() == b'-') {
            fail("Expected unsigned integer")
        }
        requireDigit("Expected digit")
        var result: UInt64 = 0
        if (source.peek() == b'0') {
            consumeByte()
            rejectLeadingZeroFromSource()
        } else {
            while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
                let digit = UInt64(consumeByte() - b'0')
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
        if (source.hasMore() && (source.peek() == b'.' || source.peek() == b'e' || source.peek() == b'E')) {
            fail("Expected integer")
        }
    }

    private func rejectLeadingZeroFromSource(): Unit {
        if (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
            fail("Leading zeroes are not allowed in JSON numbers")
        }
    }

    private func parseDigitsInto(buffer: StringBuilder): Unit {
        requireDigit("Expected digit")
        while (source.hasMore() && source.peek() >= b'0' && source.peek() <= b'9') {
            buffer.append(Rune(consumeByte()))
        }
    }

    private func parseIntegerDigitsInto(buffer: StringBuilder): Unit {
        requireDigit("Expected digit")
        if (source.peek() == b'0') {
            buffer.append(Rune(consumeByte()))
            rejectLeadingZeroFromSource()
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
            case arraySource: ArrayJsonDirectByteSource =>
                if (config.maxStringBytes == 0 && !rootBudgetActive) {
                    if (let Some(value) <- arraySource.tryParseSimpleString()) {
                        return value
                    }
                }
            case _ => ()
        }
        expectByte(b'"')
        let builder = StringBuilder()
        var decodedBytes: Int64 = 0
        while (source.hasMore()) {
            let start = source.position()
            let current = consumeByte()
            match (current) {
                case b'"' => return builder.toString()
                case b'\\' =>
                    if (!source.hasMore()) {
                        fail("Unexpected end of escape sequence")
                    }
                    let escaped = consumeByte()
                    match (escaped) {
                        case b'"' => builder.append("\""); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'\\' => builder.append("\\"); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'/' => builder.append("/"); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'b' => builder.append(r'\b'); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'f' => builder.append(r'\f'); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'n' => builder.append(r'\n'); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'r' => builder.append(r'\r'); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b't' => builder.append(r'\t'); decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                        case b'u' =>
                            builder.append(parseUnicodeEscape())
                            decodedBytes = addDecodedStringBytes(decodedBytes, lastUnicodeEscapeBytes, start)
                        case _ => fail("Unsupported escape sequence")
                    }
                case _ =>
                    if (current < 0x80) {
                        if (current < 0x20) {
                            failAt("Unescaped control character in string literal", start)
                        }
                        builder.append(Rune(current))
                        decodedBytes = addDecodedStringBytes(decodedBytes, 1, start)
                    } else {
                        builder.append(decodeUtf8Rune(current, start))
                        decodedBytes = addDecodedStringBytes(decodedBytes, source.position() - start, start)
                    }
            }
        }
        fail("Unterminated string literal")
    }

    private func scanRawString(): Unit {
        if (config.maxStringBytes > 0 || rootBudgetActive) {
            let _ = parseString()
            return
        }
        expectByte(b'"')
        while (source.hasMore()) {
            let start = source.position()
            let current = consumeByte()
            match (current) {
                case b'"' => return
                case b'\\' => skipEscapedStringItem(start)
                case _ =>
                    if (current < 0x20) {
                        failAt("Unescaped control character in string literal", start)
                    }
                    if (current >= 0x80) {
                        let _ = decodeUtf8Rune(current, start)
                    }
            }
        }
        fail("Unterminated string literal")
    }

    private func skipEscapedStringItem(start: Int64): Unit {
        if (!source.hasMore()) {
            fail("Unexpected end of escape sequence")
        }
        let escaped = consumeByte()
        match (escaped) {
            case b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => return
            case b'u' =>
                let _ = parseUnicodeEscape()
                return
            case _ => failAt("Unsupported escape sequence", start)
        }
    }

    private func parseNameId(candidates: Array<String>): Int64 {
        if (config.maxStringBytes > 0 || rootBudgetActive || candidates.size > 63 ||
            !allCandidateNamesAscii(candidates)) {
            let name = parseString()
            for (candidateIndex in 0..candidates.size) {
                if (candidates[candidateIndex] == name) {
                    return candidateIndex
                }
            }
            return -1
        }
        match (source) {
            case arraySource: ArrayJsonDirectByteSource => return arraySource.parseNameIdFast(candidates)
            case _ => ()
        }
        expectByte(b'"')
        var active = initialNameMatchMask(candidates.size)
        var index: Int64 = 0
        while (source.hasMore()) {
            let current = consumeByte()
            if (current == b'"') {
                if (active == 0u64) {
                    return -1
                }
                for (candidateIndex in 0..candidates.size) {
                    if (((active & nameMatchBit(candidateIndex)) != 0u64) && candidates[candidateIndex].size == index) {
                        return candidateIndex
                    }
                }
                return -1
            }
            var code: Int64 = -1
            if (current == b'\\') {
                code = consumeEscapedAsciiForName()
            } else if (current < 0x80) {
                code = Int64(current)
            }
            if (active != 0u64) {
                active = updateActiveNameCandidates(candidates, active, index, code)
            }
            index++
        }
        fail("Unterminated string literal")
    }

    private func allCandidateNamesAscii(candidates: Array<String>): Bool {
        for (candidate in candidates) {
            unsafe {
                for (byte in candidate.rawData()) {
                    if (byte >= 0x80) {
                        return false
                    }
                }
            }
        }
        true
    }

    private func initialNameMatchMask(size: Int64): UInt64 {
        var mask = 0u64
        for (index in 0..size) {
            mask |= nameMatchBit(index)
        }
        mask
    }

    private func nameMatchBit(index: Int64): UInt64 {
        1u64 << index
    }

    private func updateActiveNameCandidates(
        candidates: Array<String>,
        active: UInt64,
        index: Int64,
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
                let data = candidates[candidateIndex].rawData()
                if (index < data.size && data[index] == byte) {
                    next |= bit
                }
            }
        }
        next
    }

    private func consumeEscapedAsciiForName(): Int64 {
        if (!source.hasMore()) {
            fail("Unexpected end of escape sequence")
        }
        let escaped = consumeByte()
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
        let start = source.position()
        let value = parseUnicodeEscapeValue(start)
        if (isJsonHighSurrogate(value)) {
            if (!source.hasMore() || consumeByte() != b'\\' || !source.hasMore() || consumeByte() != b'u') {
                failAt("Invalid unicode surrogate pair", start)
            }
            let lowStart = source.position()
            let low = parseUnicodeEscapeValue(lowStart)
            if (!isJsonLowSurrogate(low)) {
                failAt("Invalid unicode surrogate pair", start)
            }
            lastUnicodeEscapeBytes = 4
            return try {
                Rune(combineJsonSurrogates(value, low))
            } catch (_: Exception) {
                failAt("Invalid unicode escape", start)
            }
        }
        if (isJsonLowSurrogate(value)) {
            failAt("Invalid unicode surrogate pair", start)
        }
        lastUnicodeEscapeBytes = jsonUtf8ByteCount(value)
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
            value = value * 16 + hexValue(consumeByte())
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
            bytes[index] = UInt8(consumeByte())
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
        match (source) {
            case arraySource: ArrayJsonDirectByteSource =>
                arraySource.skipSpacesFast()
                return
            case _ => ()
        }
        while (source.hasMore()) {
            match (source.peek()) {
                case b' ' | b'\n' | b'\r' | b'\t' => consumeByte()
                case _ => return
            }
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
            if (!source.hasMore() || consumeByte() != byte) {
                fail("Expected ${literal}")
            }
        }
    }

    private func expectByte(value: Byte): Unit {
        match (source) {
            case arraySource: ArrayJsonDirectByteSource =>
                arraySource.expectByteFast(value)
                return
            case _ => ()
        }
        if (!source.hasMore() || consumeByte() != value) {
            fail("Unexpected token")
        }
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

private class JsonNodeReplayValue <: JsonReplayValue {
    private let value: JsonNode
    private let config: JsonReadConfig
    private var closed: Bool = false

    init(value: JsonNode, config: JsonReadConfig) {
        this.value = value
        this.config = config
    }

    public func close(): Unit { closed = true }

    public func isClosed(): Bool { closed }

    public func rootStringField(name: String): Option<String> {
        requireOpen()
        match (value.asObject().get(name)) {
            case Some(field) => Some(field.asString().value)
            case None => None<String>
        }
    }

    public func openObjectReaderExcluding(name: String): JsonCodecReader {
        requireOpen()
        let filtered = JsonObjectValue()
        for ((fieldName, fieldValue) in value.asObject().entries()) {
            if (fieldName != name) { filtered.put(fieldName, fieldValue) }
        }
        JsonDirectReader(filtered.toString(), config: config)
    }

    public func materialize(): JsonNode {
        requireOpen()
        value
    }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("JSON replay value is closed") }
    }
}
