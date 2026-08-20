package yjson

private class JsonResourceLimitScanner {
    private let data: Array<Byte>
    private let config: JsonReadConfig
    private let size: Int64
    private var index: Int64 = 0
    private var depth: Int64 = 0

    init(data: Array<Byte>, config: JsonReadConfig) {
        this.data = data
        this.config = config
        this.size = data.size
    }

    func validate(): Unit {
        skipSpaces()
        if (index >= size) { fail("Unexpected end of input", index) }
        let valueStart = index
        let rootIsContainer = data[index] == b'[' || data[index] == b'{'
        parseValue()
        if (rootIsContainer) { ensureRootValueBudget(valueStart) }
        skipSpaces()
        if (index != size) { fail("Unexpected trailing input", index) }
    }

    private func parseValue(): Unit {
        skipSpaces()
        if (index >= size) { fail("Unexpected end of input", index) }
        let current = data[index]
        match {
            case current == b'n' => expectLiteral("null")
            case current == b't' => expectLiteral("true")
            case current == b'f' => expectLiteral("false")
            case current == b'"' => parseString()
            case current == b'[' => parseArray()
            case current == b'{' => parseObject()
            case current == b'-' || (current >= b'0' && current <= b'9') => parseNumber()
            case _ => fail("Unexpected token", index)
        }
    }

    private func parseArray(): Unit {
        enterContainer()
        index++
        skipSpaces()
        if (takeIf(b']')) { leaveContainer(); return }
        while (true) {
            parseValue()
            skipSpaces()
            if (takeIf(b']')) { leaveContainer(); return }
            expectByte(b',')
        }
    }

    private func parseObject(): Unit {
        enterContainer()
        index++
        skipSpaces()
        if (takeIf(b'}')) { leaveContainer(); return }
        while (true) {
            if (index >= size || data[index] != b'"') { fail("Expected object key", index) }
            parseString()
            skipSpaces()
            expectByte(b':')
            parseValue()
            skipSpaces()
            if (takeIf(b'}')) { leaveContainer(); return }
            expectByte(b',')
        }
    }

    private func parseString(): Unit {
        let stringStart = index
        index++
        var decodedBytes: Int64 = 0
        while (index < size) {
            let currentStart = index
            let current = data[index]
            index++
            match (current) {
                case b'"' => return
                case b'\\' =>
                    if (index >= size) { fail("Unexpected end of escape sequence", index) }
                    let escaped = data[index]
                    index++
                    match (escaped) {
                        case b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' =>
                            decodedBytes++
                        case b'u' =>
                            let scalar = parseUnicodeScalar(currentStart)
                            decodedBytes += jsonUtf8ByteCount(scalar)
                        case _ => fail("Unsupported escape sequence", currentStart)
                    }
                case _ =>
                    if (current < 0x20) { fail("Unescaped control character in string literal", currentStart) }
                    if (current < 0x80) {
                        decodedBytes++
                    } else {
                        let width = validateUtf8Sequence(currentStart)
                        index = currentStart + width
                        decodedBytes += width
                    }
            }
            if (config.maxStringBytes > 0 && decodedBytes > config.maxStringBytes) {
                resourceFail("JSON string exceeds ${config.maxStringBytes} decoded UTF-8 bytes",
                    "string_too_large", currentStart)
            }
        }
        fail("Unterminated string literal", stringStart)
    }

    private func parseUnicodeScalar(start: Int64): Int64 {
        let high = parseHex4(start)
        if (high >= 0xD800 && high <= 0xDBFF) {
            if (index + 2 > size || data[index] != b'\\' || data[index + 1] != b'u') {
                fail("Invalid unicode surrogate pair", start)
            }
            index += 2
            let low = parseHex4(start)
            if (low < 0xDC00 || low > 0xDFFF) { fail("Invalid unicode surrogate pair", start) }
            return 0x10000 + ((high - 0xD800) * 0x400) + (low - 0xDC00)
        }
        if (high >= 0xDC00 && high <= 0xDFFF) { fail("Invalid unicode surrogate pair", start) }
        high
    }

    private func parseHex4(start: Int64): Int64 {
        if (index + 4 > size) { fail("Incomplete unicode escape", start) }
        var value: Int64 = 0
        for (_ in 0..4) {
            value = value * 16 + hexValue(data[index], index)
            index++
        }
        value
    }

    private func hexValue(value: Byte, offset: Int64): Int64 {
        match {
            case value >= b'0' && value <= b'9' => Int64(value - b'0')
            case value >= b'a' && value <= b'f' => Int64(value - b'a') + 10
            case value >= b'A' && value <= b'F' => Int64(value - b'A') + 10
            case _ => fail("Invalid unicode escape", offset)
        }
    }

    private func validateUtf8Sequence(start: Int64): Int64 {
        let first = UInt8(data[start])
        if (first >= 0xC2u8 && first <= 0xDFu8) {
            requireContinuation(start + 1, 0x80u8, 0xBFu8, start)
            return 2
        }
        if (first >= 0xE0u8 && first <= 0xEFu8) {
            requireContinuation(start + 1, if (first == 0xE0u8) { 0xA0u8 } else { 0x80u8 },
                if (first == 0xEDu8) { 0x9Fu8 } else { 0xBFu8 }, start)
            requireContinuation(start + 2, 0x80u8, 0xBFu8, start)
            return 3
        }
        if (first >= 0xF0u8 && first <= 0xF4u8) {
            requireContinuation(start + 1, if (first == 0xF0u8) { 0x90u8 } else { 0x80u8 },
                if (first == 0xF4u8) { 0x8Fu8 } else { 0xBFu8 }, start)
            requireContinuation(start + 2, 0x80u8, 0xBFu8, start)
            requireContinuation(start + 3, 0x80u8, 0xBFu8, start)
            return 4
        }
        fail("Invalid UTF-8 byte sequence", start)
    }

    private func requireContinuation(position: Int64, minimum: UInt8, maximum: UInt8,
        errorPosition: Int64): Unit {
        if (position >= size) { fail("Invalid UTF-8 byte sequence", errorPosition) }
        let value = UInt8(data[position])
        if (value < minimum || value > maximum) { fail("Invalid UTF-8 byte sequence", errorPosition) }
    }

    private func parseNumber(): Unit {
        if (takeIf(b'-') && index >= size) { fail("Expected digit", index) }
        requireDigit()
        if (data[index] == b'0') {
            index++
            if (index < size && isDigit(data[index])) { fail("Leading zeroes are not allowed", index) }
        } else {
            while (index < size && isDigit(data[index])) { index++ }
        }
        if (takeIf(b'.')) {
            requireDigit()
            while (index < size && isDigit(data[index])) { index++ }
        }
        if (index < size && (data[index] == b'e' || data[index] == b'E')) {
            index++
            if (index < size && (data[index] == b'+' || data[index] == b'-')) { index++ }
            requireDigit()
            while (index < size && isDigit(data[index])) { index++ }
        }
    }

    private func requireDigit(): Unit {
        if (index >= size || !isDigit(data[index])) { fail("Expected digit", index) }
    }

    private func isDigit(value: Byte): Bool { value >= b'0' && value <= b'9' }

    private func expectLiteral(literal: String): Unit {
        let start = index
        unsafe {
            for (byte in literal.rawData()) {
                if (index >= size || data[index] != byte) { fail("Expected ${literal}", start) }
                index++
            }
        }
    }

    private func expectByte(value: Byte): Unit {
        skipSpaces()
        if (index >= size || data[index] != value) { fail("Unexpected token", index) }
        index++
        skipSpaces()
    }

    private func takeIf(value: Byte): Bool {
        if (index < size && data[index] == value) { index++; return true }
        false
    }

    private func skipSpaces(): Unit {
        while (index < size) {
            match (data[index]) {
                case b' ' | b'\n' | b'\r' | b'\t' => index++
                case _ => return
            }
        }
    }

    private func enterContainer(): Unit {
        if (depth >= config.maxDepth) {
            resourceFail("Maximum JSON depth ${config.maxDepth} exceeded", "max_depth", index)
        }
        depth++
    }

    private func leaveContainer(): Unit { depth-- }

    private func ensureRootValueBudget(start: Int64): Unit {
        if (config.maxPolymorphicObjectBytes > 0 && index - start > config.maxPolymorphicObjectBytes) {
            resourceFail("JSON value exceeds ${config.maxPolymorphicObjectBytes} bytes",
                "polymorphic_object_too_large", start + config.maxPolymorphicObjectBytes)
        }
    }

    private func fail(message: String, offset: Int64): Nothing {
        throw jsonResourceLimitException(data, config, message, "parse_error", offset)
    }

    private func resourceFail(message: String, code: String, offset: Int64): Nothing {
        throw jsonResourceLimitException(data, config, message, code, offset)
    }
}

func jsonUtf8ByteCount(scalar: Int64): Int64 {
    if (scalar <= 0x7F) { 1 }
    else if (scalar <= 0x7FF) { 2 }
    else if (scalar <= 0xFFFF) { 3 }
    else { 4 }
}

func jsonReadConfigHasResourceLimits(config: JsonReadConfig): Bool {
    config.maxBytes > 0 || config.maxStringBytes > 0 || config.maxPolymorphicObjectBytes > 0
}

func jsonResourceLimitException(data: Array<Byte>, config: JsonReadConfig, message: String,
    code: String, offset: Int64): JsonException {
    if (!config.includeErrorLocation) { return JsonException(message, code: code) }
    JsonException(message, code: code, byteOffset: offset,
        line: jsonLineFromUtf8Bytes(data, offset), column: jsonColumnFromUtf8Bytes(data, offset))
}

func jsonResourceLimitException(config: JsonReadConfig, message: String, code: String,
    offset: Int64): JsonException {
    JsonException(message, code: code,
        byteOffset: if (config.includeErrorLocation) { offset } else { -1 })
}

func validateJsonResourceLimits(data: Array<Byte>, config: JsonReadConfig): Unit {
    if (config.maxBytes > 0 && data.size > config.maxBytes) {
        throw jsonResourceLimitException(data, config,
            "JSON document exceeds ${config.maxBytes} bytes", "document_too_large", config.maxBytes)
    }
    if (config.maxStringBytes > 0 || config.maxPolymorphicObjectBytes > 0) {
        JsonResourceLimitScanner(data, config).validate()
    }
}
