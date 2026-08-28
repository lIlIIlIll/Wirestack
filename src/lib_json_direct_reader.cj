package yjson

import std.collection.*
import std.convert.Parsable
import std.io.*
import std.math.numeric.*


private class JsonDirectReadContext {
    public let objectContext: Bool
    public var first: Bool = true
    public var expectingFieldValue: Bool = false
    public var seenNames: Option<HashSet<String>>

    public init(objectContext: Bool, trackDuplicateNames: Bool) {
        this.objectContext = objectContext
        this.seenNames = if (trackDuplicateNames) {
            Some(HashSet<String>())
        } else {
            None<HashSet<String>>
        }
    }
}

public class JsonDirectReader <: JsonCodecReader {
    private let source: InputCursor
    private let config: JsonReadConfig
    private let streaming: Bool
    private let contexts = ArrayList<JsonDirectReadContext>()
    private var valuePrefixReady: Bool = false

    public init(text: String, config!: JsonReadConfig = JsonReadConfig.defaults) {
        source = Utf8Cursor(text, config: config)
        this.config = config
        this.streaming = false
    }

    public init(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults) {
        source = Utf8Cursor(bytes, config: config)
        this.config = config
        this.streaming = false
    }

    public init(input: InputStream, config!: JsonReadConfig = JsonReadConfig.defaults) {
        source = StreamInputCursor(input, config: config)
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
        readBoundedValueFrom(start, maxBytes)
    }

    private func ensureValueBudget(start: Int64, maxBytes: Int64): Unit {
        if (maxBytes > 0 && source.position() - start > maxBytes) {
            throw JsonException(
                "Polymorphic JSON object exceeds ${maxBytes} bytes",
                code: "polymorphic_object_too_large"
            )
        }
    }

    private func readBoundedValueFrom(start: Int64, maxBytes: Int64): JsonNode {
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
                    items.add(readBoundedValueFrom(start, maxBytes))
                    ensureValueBudget(start, maxBytes)
                }
                endArray()
                JsonArrayValue(items)
            case current == b'{' =>
                let fields = HashMap<String, JsonNode>()
                startObject()
                while (hasObjectField()) {
                    let name = readName()
                    fields.add(name, readBoundedValueFrom(start, maxBytes))
                    ensureValueBudget(start, maxBytes)
                }
                endObject()
                JsonObjectValue(fields)
            case current == b'-' || (current >= b'0' && current <= b'9') =>
                JsonNumberLiteralValue.fromParsedLiteral(readNumberLiteral())
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
        requireContainerDepth(source.position())
        beginRootBudgetIfNeeded()
        expectByte(b'{')
        contexts.add(JsonDirectReadContext(true, jsonReadConfigRejectsDuplicateKeys(config)))
    }

    public func endObject(): Unit {
        let wasRoot = contexts.size == 1 && source.isValueBudgetActive()
        let context = popContext(true)
        if (context.expectingFieldValue) {
            fail("Expected object field value")
        }
        skipSpaces()
        expectByte(b'}')
        if (wasRoot) { source.endValueBudget() }
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
                policyFail("Unknown JSON field", "unknown_field")
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
        let seenNames = match (context.seenNames) {
            case Some(value) => value
            case None => return
        }
        if (seenNames.contains(name)) {
            policyFail("Duplicate object key '${name}'", "duplicate_key")
        }
        seenNames.add(name)
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
        requireContainerDepth(source.position())
        beginRootBudgetIfNeeded()
        expectByte(b'[')
        contexts.add(JsonDirectReadContext(false, false))
    }

    public func endArray(): Unit {
        let wasRoot = contexts.size == 1 && source.isValueBudgetActive()
        let _ = popContext(false)
        skipSpaces()
        expectByte(b']')
        if (wasRoot) { source.endValueBudget() }
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
        skipValueWithDepth(config.maxDepth - contexts.size)
    }

    public func skipValueWithDepth(maxDepth: Int64): Unit {
        if (maxDepth < 0) { throw IllegalArgumentException("maxDepth must not be negative") }
        beforeValue()
        if (source.hasMore() && (source.peek() == b'[' || source.peek() == b'{')) {
            beginRootBudgetIfNeeded()
        }
        skipRawValueBounded(0, maxDepth)
        if (contexts.isEmpty()) { source.endValueBudget() }
    }

    private func requireContainerDepth(offset: Int64): Unit {
        if (contexts.size >= config.maxDepth) {
            throw jsonResourceLimitException(config,
                "Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", offset)
        }
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
        if (streaming && !source.isValueBudgetActive() && contexts.isEmpty() &&
            config.maxPolymorphicObjectBytes > 0) {
            source.beginValueBudget(config.maxPolymorphicObjectBytes)
        }
    }

    private func consumeByte(): Byte {
        source.consumeJsonByte()
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

    private func skipRawValueBounded(depth: Int64, maxDepth: Int64): Unit {
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
            case current == b'[' => skipRawArrayBounded(depth, maxDepth)
            case current == b'{' => skipRawObjectBounded(depth, maxDepth)
            case current == b'-' || (current >= b'0' && current <= b'9') =>
                skipNumberLiteral()
            case _ => fail("Unexpected token")
        }
    }

    private func skipRawArrayBounded(depth: Int64, maxDepth: Int64): Unit {
        if (depth >= maxDepth) {
            throw jsonResourceLimitException(config,
                "Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", source.position())
        }
        expectByte(b'[')
        skipSpaces()
        if (source.hasMore() && source.peek() == b']') {
            consumeByte()
            return
        }
        while (true) {
            skipRawValueBounded(depth + 1, maxDepth)
            skipSpaces()
            if (source.hasMore() && source.peek() == b']') {
                consumeByte()
                return
            }
            expectByte(b',')
        }
    }

    private func skipRawObjectBounded(depth: Int64, maxDepth: Int64): Unit {
        if (depth >= maxDepth) {
            throw jsonResourceLimitException(config,
                "Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", source.position())
        }
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
            skipRawValueBounded(depth + 1, maxDepth)
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
        let _ = source.readJsonNumberLiteral()
    }

    private func parseNumberLiteral(): String {
        skipSpaces()
        source.readJsonNumberLiteral()
    }

    private func parseInt64Literal(): Int64 {
        match (source) {
            case arraySource: Utf8Cursor =>
                if (!source.isValueBudgetActive()) { return arraySource.parseInt64LiteralFast() }
            case streamSource: StreamInputCursor =>
                if (!source.isValueBudgetActive()) {
                    skipSpaces()
                    if (let Some(value) <- streamSource.tryParseInt64Window()) { return value }
                }
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
            case arraySource: Utf8Cursor =>
                if (!source.isValueBudgetActive()) { return arraySource.parseUInt64LiteralFast() }
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

    private func requireDigit(message: String): Unit {
        if (!source.hasMore() || source.peek() < b'0' || source.peek() > b'9') {
            fail(message)
        }
    }

    private func parseString(): String {
        match (source) {
            case streamSource: StreamInputCursor =>
                if (config.maxStringBytes == 0 && !source.isValueBudgetActive()) {
                    if (let Some(value) <- streamSource.tryParseSimpleAsciiStringWindow()) {
                        return value
                    }
                }
            case _ => ()
        }
        source.readJsonString()
    }

    private func scanRawString(): Unit {
        if (config.maxStringBytes > 0 || source.isValueBudgetActive()) {
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
                        let _ = source.decodeJsonUtf8Rune(current, start)
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
                let _ = source.readJsonUnicodeEscape()
                return
            case _ => failAt("Unsupported escape sequence", start)
        }
    }

    private func parseNameId(candidates: Array<String>): Int64 {
        if (config.maxStringBytes > 0 || source.isValueBudgetActive() || candidates.size > 63 ||
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
            case arraySource: Utf8Cursor => return arraySource.parseNameIdFast(candidates)
            case streamSource: StreamInputCursor =>
                if (let Some(value) <- streamSource.tryParseNameIdWindow(candidates)) {
                    return value
                }
            case _ => ()
        }
        expectByte(b'"')
        var active = initialNameMatchMask(candidates.size)
        var index: Int64 = 0
        while (source.hasMore()) {
            let start = source.position()
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
                if (current < 0x20) {
                    failAt("Unescaped control character in string literal", start)
                }
                code = Int64(current)
            } else {
                let _ = source.decodeJsonUtf8Rune(current, start)
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
                let (r, _) = source.readJsonUnicodeEscape()
                let code = UInt32(r)
                return if (code <= 0x7Fu32) {
                    Int64(code)
                } else {
                    -1
                }
            case _ => fail("Unsupported escape sequence")
        }
    }

    private func skipSpaces(): Unit {
        match (source) {
            case streamSource: StreamInputCursor => streamSource.skipSpacesFast()
            case _ => source.skipJsonWhitespace()
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
            case streamSource: StreamInputCursor =>
                if (!source.isValueBudgetActive() && streamSource.consumeExpectedByteFast(value)) {
                    return
                }
            case _ => ()
        }
        if (!source.hasMore() || source.peek() != value) {
            fail("Unexpected token")
        }
        consumeByte()
    }

    private func fail(message: String): Nothing {
        failAt(message, source.position())
    }

    private func policyFail(message: String, code: String): Nothing {
        let offset = source.position()
        throw JsonException(
            message,
            code: code,
            byteOffset: if (config.includeErrorLocation) { offset } else { -1 },
            line: source.lineAt(offset),
            column: source.columnAt(offset)
        )
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
