package yjson

import std.collection.*
import std.convert.Parsable
import std.io.*
import std.math.numeric.*


private class JsonDirectReadContext {
    public let objectContext: Bool
    public let pathDepth: Int64
    public let entryPathPushed: Bool
    public var first: Bool = true
    public var expectingFieldValue: Bool = false
    public var pendingPathPushed: Bool = false
    public var nextArrayIndex: Int64 = 0
    public var seenNames: Option<HashSet<String>>

    public init(objectContext: Bool, trackDuplicateNames: Bool, pathDepth: Int64,
        entryPathPushed: Bool) {
        this.objectContext = objectContext
        this.pathDepth = pathDepth
        this.entryPathPushed = entryPathPushed
        this.seenNames = if (trackDuplicateNames) {
            Some(HashSet<String>())
        } else {
            None<HashSet<String>>
        }
    }
}

class JsonDirectReader <: JsonReader & GeneratedReadStateV1Owner {
    private let source: InputCursor
    private let config: JsonReadOptions
    // Linear duplicate scan for policy-aware unknown-object skips; the
    // window [base..count) holds only the current object level.
    private var skipSeenNames: Array<String> = Array<String>(16, repeat: "")
    private var skipSeenCount: Int64 = 0

    private func ensureSkipSeenCapacity(): Unit {
        if (skipSeenCount < skipSeenNames.size) { return }
        let grown = Array<String>(skipSeenNames.size * 2, repeat: "")
        for (position in 0..skipSeenCount) { grown[position] = skipSeenNames[position] }
        skipSeenNames = grown
    }
    private let streaming: Bool
    private let generatedState: GeneratedReadStateV1
    private let contexts = ArrayList<JsonDirectReadContext>()
    private var valuePrefixReady: Bool = false
    private var valuePrefixPathPushed: Bool = false

    public init(text: String, config!: JsonReadOptions = JsonReadOptions.defaults) {
        source = Utf8Cursor(text, config: config)
        this.config = config
        this.streaming = false
        generatedState = GeneratedReadStateV1(config)
    }

    public init(bytes: Array<Byte>, config!: JsonReadOptions = JsonReadOptions.defaults) {
        source = Utf8Cursor(bytes, config: config)
        this.config = config
        this.streaming = false
        generatedState = GeneratedReadStateV1(config)
    }

    public init(input: InputStream, config!: JsonReadOptions = JsonReadOptions.defaults) {
        source = StreamInputCursor(input, config: config)
        this.config = config
        this.streaming = true
        generatedState = GeneratedReadStateV1(config)
    }

    public func readConfig(): JsonReadOptions {
        config
    }

    public func generatedReadStateV1(): GeneratedReadStateV1 { generatedState }

    public func path(): String { generatedState.currentPath() }

    public func location(): Option<JsonLocation> {
        let offset = source.position()
        Some(JsonLocation(offset, source.lineAt(offset), source.columnAt(offset)))
    }

    public func error(message: String, code: String): JsonException {
        JsonException(message, code: code, path: path(), location: location())
    }

    public func readNode(): JsonNode { readBoundedValue(0) }

    public func readReplayValue(maxBytes: Int64): GeneratedReplayValueV1 {
        JsonNodeReplayValue(readBoundedValue(maxBytes), config)
    }

    // Materializes exactly one value while enforcing the byte budget against
    // the original input. Zero disables this local budget, matching
    // JsonReadOptions's public resource-limit semantics. This is reserved for
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
                code: "buffered_value_too_large"
            )
        }
    }

    private func readBoundedValueFrom(start: Int64, maxBytes: Int64): JsonNode {
        let pathPushed = beforeValue()
        ensureValueBudget(start, maxBytes)
        if (!source.hasMore()) { fail("Unexpected end of input") }
        valuePrefixReady = true
        valuePrefixPathPushed = pathPushed
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
                JsonArray(items)
            case current == b'{' =>
                let fields = HashMap<String, JsonNode>()
                startObject()
                while (hasObjectField()) {
                    let name = readName()
                    fields.add(name, readBoundedValueFrom(start, maxBytes))
                    ensureValueBudget(start, maxBytes)
                }
                endObject()
                JsonObject(fields)
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
        let pathPushed = beforeValue()
        requireContainerDepth(source.position())
        beginRootBudgetIfNeeded()
        expectByte(b'{')
        contexts.add(JsonDirectReadContext(true, jsonReadOptionsRejectsDuplicateKeys(config),
            generatedState.pathDepth(), pathPushed))
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
        generatedState.completeAutoValue(context.entryPathPushed)
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
        let context = contexts[contexts.size - 1]
        context.pendingPathPushed = generatedState.pushAutoField(name, context.pathDepth)
        name
    }

    public func readNameId(candidates: Array<String>): Int64 {
        beforeName()
        let id = parseNameId(candidates)
        if (id < 0) {
            if (jsonReadOptionsRejectsUnknownFields(config)) {
                policyFail("Unknown JSON field", "unknown_field")
            }
        } else {
            rejectNameIfConfigured(candidates[id])
        }
        afterName()
        if (id >= 0) {
            let context = contexts[contexts.size - 1]
            context.pendingPathPushed = generatedState.pushAutoField(candidates[id], context.pathDepth)
        }
        id
    }

    private func rejectNameIfConfigured(name: String): Unit {
        if (!jsonReadOptionsRejectsDuplicateKeys(config)) {
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
        let pathPushed = beforeValue()
        requireContainerDepth(source.position())
        beginRootBudgetIfNeeded()
        expectByte(b'[')
        contexts.add(JsonDirectReadContext(false, false, generatedState.pathDepth(), pathPushed))
    }

    public func endArray(): Unit {
        let wasRoot = contexts.size == 1 && source.isValueBudgetActive()
        let context = popContext(false)
        skipSpaces()
        expectByte(b']')
        if (wasRoot) { source.endValueBudget() }
        generatedState.completeAutoValue(context.entryPathPushed)
    }

    public func hasArrayItem(): Bool {
        if (contexts.isEmpty() || contexts[contexts.size - 1].objectContext) {
            fail("Not reading an array")
        }
        skipSpaces()
        source.hasMore() && source.peek() != b']'
    }

    public func tryReadNull(): Bool {
        let pathPushed = beforeValue()
        skipSpaces()
        if (!source.hasMore() || source.peek() != b'n') {
            valuePrefixReady = true
            valuePrefixPathPushed = pathPushed
            return false
        }
        expectLiteral("null")
        generatedState.completeAutoValue(pathPushed)
        true
    }

    public func readNull(): Unit {
        let pathPushed = beforeValue()
        try { expectLiteral("null") }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func readBool(): Bool {
        let pathPushed = beforeValue()
        try {
            if (source.peek() == b't') {
                expectLiteral("true")
                return true
            }
            expectLiteral("false")
            false
        } catch (error: JsonException) {
            throw errorWithCurrentPath(error)
        } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func readString(): String {
        let pathPushed = beforeValue()
        try { parseString() }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func skipString(): Unit {
        let pathPushed = beforeValue()
        try { scanRawString() }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func readInt64(): Int64 {
        let pathPushed = beforeValue()
        try { parseInt64Literal() }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func readUInt64(): UInt64 {
        let pathPushed = beforeValue()
        try { parseUInt64Literal() }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
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
        let pathPushed = beforeValue()
        try { parseNumberLiteral() }
        catch (error: JsonException) { throw errorWithCurrentPath(error) }
        finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func skipValue(): Unit {
        skipValueWithDepth(config.maxDepth - contexts.size)
    }

    public func skipValueWithDepth(maxDepth: Int64): Unit {
        if (maxDepth < 0) { throw IllegalArgumentException("maxDepth must not be negative") }
        let pathPushed = beforeValue()
        try {
            if (source.hasMore() && (source.peek() == b'[' || source.peek() == b'{')) {
                beginRootBudgetIfNeeded()
            }
            skipRawValuePolicyAware(0, maxDepth)
            if (contexts.isEmpty()) { source.endValueBudget() }
        } finally { generatedState.completeAutoValue(pathPushed) }
    }

    private func requireContainerDepth(offset: Int64): Unit {
        if (contexts.size >= config.maxDepth) {
            throw jsonResourceLimitException(config,
                "Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", offset)
        }
    }

    private func beforeValue(): Bool {
        if (valuePrefixReady) {
            valuePrefixReady = false
            let pathPushed = valuePrefixPathPushed
            valuePrefixPathPushed = false
            return pathPushed
        }
        if (contexts.isEmpty()) {
            skipSpaces()
            return false
        }
        let context = contexts[contexts.size - 1]
        if (context.objectContext) {
            if (!context.expectingFieldValue) {
                fail("Object values must follow a field name")
            }
            context.expectingFieldValue = false
            skipSpaces()
            let pathPushed = context.pendingPathPushed
            context.pendingPathPushed = false
            generatedState.beginAutoValue(pathPushed)
            return pathPushed
        }
        let pathPushed = generatedState.pushAutoIndex(context.nextArrayIndex, context.pathDepth)
        context.nextArrayIndex++
        skipSpaces()
        if (context.first) {
            context.first = false
            generatedState.beginAutoValue(pathPushed)
            return pathPushed
        }
        expectByte(b',')
        skipSpaces()
        generatedState.beginAutoValue(pathPushed)
        pathPushed
    }

    private func beginRootBudgetIfNeeded(): Unit {
        if (streaming && !source.isValueBudgetActive() && contexts.isEmpty() &&
            config.maxBufferedValueBytes > 0) {
            source.beginValueBudget(config.maxBufferedValueBytes)
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

    private func skipRawValuePolicyAware(depth: Int64, maxDepth: Int64): Unit {
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
            case current == b'[' => skipRawArrayPolicyAware(depth, maxDepth)
            case current == b'{' => skipRawObjectPolicyAware(depth, maxDepth)
            case current == b'-' || (current >= b'0' && current <= b'9') =>
                skipNumberLiteral()
            case _ => fail("Unexpected token")
        }
    }

    private func skipRawArrayPolicyAware(depth: Int64, maxDepth: Int64): Unit {
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
            skipRawValuePolicyAware(depth + 1, maxDepth)
            skipSpaces()
            if (source.hasMore() && source.peek() == b']') {
                consumeByte()
                return
            }
            expectByte(b',')
        }
    }

    private func skipRawObjectPolicyAware(depth: Int64, maxDepth: Int64): Unit {
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
        let seenBase = if (jsonReadOptionsRejectsDuplicateKeys(config)) {
            skipSeenCount
        } else {
            -1
        }
        while (true) {
            let name = parseString()
            if (seenBase >= 0) {
                var duplicate = false
                for (position in seenBase..skipSeenCount) {
                    if (skipSeenNames[position] == name) { duplicate = true; break }
                }
                if (duplicate) { policyFail("Duplicate object key '${name}'", "duplicate_key") }
                ensureSkipSeenCapacity()
                skipSeenNames[skipSeenCount] = name
                skipSeenCount++
            }
            skipSpaces()
            expectByte(b':')
            skipRawValuePolicyAware(depth + 1, maxDepth)
            skipSpaces()
            if (source.hasMore() && source.peek() == b'}') {
                consumeByte()
                if (seenBase >= 0) { skipSeenCount = seenBase }
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
        source.readJsonString()
    }

    private func scanRawString(): Unit {
        match (source) {
            case _: Utf8Cursor => ()
            case _ =>
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
        if (candidates.size <= 63 && allCandidateNamesAscii(candidates)) {
            match (source) {
                case arraySource: Utf8Cursor => return arraySource.parseNameIdFast(candidates)
                case _ => ()
            }
        }
        let name = parseString()
        for (candidateIndex in 0..candidates.size) {
            if (candidates[candidateIndex] == name) { return candidateIndex }
        }
        -1
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

    private func skipSpaces(): Unit {
        match (source) {
            case streamSource: StreamInputCursor =>
                if (!source.isValueBudgetActive()) {
                    streamSource.skipSpacesFast()
                    return
                }
            case _ => ()
        }
        source.skipJsonWhitespace()
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
            path: generatedState.currentPath(),
            location: Some(JsonLocation(offset, source.lineAt(offset), source.columnAt(offset)))
        )
    }

    private func failAt(message: String, offset: Int64): Nothing {
        throw JsonException(
            message,
            code: "parse_error",
            path: generatedState.currentPath(),
            location: Some(JsonLocation(offset, source.lineAt(offset), source.columnAt(offset)))
        )
    }

    private func errorWithCurrentPath(error: JsonException): JsonException {
        let current = generatedState.currentPath()
        if (!error.path.isEmpty() || current.isEmpty()) { return error }
        JsonException(error.message, error, code: error.code,
            path: current, location: error.location)
    }
}

class JsonNodeReplayValue <: GeneratedReplayValueV1 {
    private let value: JsonNode
    private let config: JsonReadOptions
    private var closed: Bool = false

    init(value: JsonNode, config: JsonReadOptions) {
        this.value = value
        this.config = config
    }

    public func close(): Unit { closed = true }

    public func isClosed(): Bool { closed }

    public func rootStringField(name: String): Option<String> {
        requireOpen()
        match (value.asObject().get(name)) {
            case Some(field) => Some(field.asString())
            case None => None<String>
        }
    }

    public func openObjectReaderExcluding(name: String): JsonReader {
        requireOpen()
        let filtered = JsonObject()
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
