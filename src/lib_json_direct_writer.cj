package yjson

import std.collection.*
import std.io.*

const JSON_DIRECT_BYTES_INITIAL_CAPACITY: Int64 = 256
const JSON_DIRECT_PRETTY_STRING_INITIAL_CAPACITY: Int64 = 512
const JSON_STREAM_BUFFER_CAPACITY: Int64 = 4096
const JSON_STREAM_DIRECT_WRITE_THRESHOLD: Int64 = 2048
const JSON_DIRECT_INT64_MAP_ENTRY_RESERVE_HINT: Int64 = 8
const JSON_DIRECT_INT64_MAP_RESERVE_LIMIT: Int64 = 4096

private func directStringWriterInitialCapacity(config: JsonWriteConfig): Int64 {
    if (config.newline == "\n" && config.indent == "    " && config.useSpaceAfterSeparators && !config.htmlSafe) {
        return JSON_DIRECT_PRETTY_STRING_INITIAL_CAPACITY
    }
    JSON_DIRECT_BYTES_INITIAL_CAPACITY
}

func jsonRawInt64Size(value: Int64): Int64 {
    if (value < 0) {
        if (value == -0x8000_0000_0000_0000) {
            return 20
        }
        return 1 + jsonRawUInt64Size(UInt64(-value))
    }
    jsonRawUInt64Size(UInt64(value))
}

func jsonRawUInt64Size(value: UInt64): Int64 {
    if (value < 10u64) {
        return 1
    }
    if (value < 100u64) {
        return 2
    }
    if (value < 1000u64) {
        return 3
    }
    if (value < 10000u64) {
        return 4
    }
    if (value < 100000u64) {
        return 5
    }
    var current = value
    var size: Int64 = 0
    while (current != 0u64) {
        current /= 10u64
        size++
    }
    size
}

func jsonRawCompactStringEscapeIndex(value: String): Int64 {
    unsafe {
        let bytes = value.rawData()
        for (index in 0..bytes.size) {
            let byte = Int64(bytes[index])
            if (byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\')) {
                return index
            }
        }
    }
    -1
}

func jsonRawInt64MapReserveHint(prefixSize: Int64, entryCount: Int64): Int64 {
    let entryHint = JSON_DIRECT_INT64_MAP_ENTRY_RESERVE_HINT
    if (prefixSize >= JSON_DIRECT_INT64_MAP_RESERVE_LIMIT - 2) {
        return JSON_DIRECT_INT64_MAP_RESERVE_LIMIT
    }
    let remaining = JSON_DIRECT_INT64_MAP_RESERVE_LIMIT - prefixSize - 2
    if (entryCount > remaining / entryHint) {
        return JSON_DIRECT_INT64_MAP_RESERVE_LIMIT
    }
    prefixSize + 2 + entryCount * entryHint
}

abstract class JsonDirectWriterTarget {
    public func bytesWritten(): Int64

    protected func writeText(value: String): Unit

    protected func writeTextRange(value: String, start: Int64, end: Int64): Unit

    protected func writeByte(value: Byte): Unit

    protected func writeBytes(value: Array<Byte>): Unit

    protected func writeBytesRange(value: Array<Byte>, start: Int64, end: Int64): Unit

    protected func reserveCapacity(additional: Int64): Unit

    protected func tryWriteNativeInt64Array(values: ArrayList<Int64>): Bool

    protected func writeStringLiteralNoEscape(value: String): Unit

    protected func writeStringLiteralNoEscapeName(value: String): Unit

    protected func writeEscapedStringLiteralFromFirstEscape(value: String, firstEscape: Int64, htmlSafe: Bool): Unit

    protected func writeTextStringLiteralNoEscape(prefix: String, value: String): Unit

    protected func writeTextStringLiteralTextNoEscape(prefix: String, value: String, suffix: String): Unit

    protected func writeTextStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit

    protected func writeCompactInt64Map(prefix: String, values: HashMap<String, Int64>): Unit

    protected func writeNewlineAndIndent(newline: String, indent: String, depth: Int64): Unit

    public func writeTextInt64StringLiteralInt64Text(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit

    public func writeTextInt64StringLiteralInt64TextNoEnsure(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit

    public func writeTextStringLiteralInt64Text(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit

    public func writeTextStringLiteralInt64TextNoEnsure(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit

    protected func writeObjectEntryNameInt64NoEscape(first: Bool, name: String, value: Int64): Bool

    protected func writeBoolText(value: Bool): Unit

    protected func writeInt64Text(value: Int64): Unit

    protected func writeUInt64Text(value: UInt64): Unit

    protected func writeFloat64Text(value: Float64): Unit

    protected func finish(): Unit

}

class DirectBufferWriterTarget <: JsonDirectWriterTarget {
    private var buffer: Array<Byte>
    private var used: Int64 = 0

    public init(capacity!: Int64 = JSON_DIRECT_BYTES_INITIAL_CAPACITY) {
        buffer = Array<Byte>(capacity, repeat: 0)
    }

    public func writeText(value: String): Unit {
        writeTextRange(value, 0, value.size)
    }

    public func writeTextRange(value: String, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) {
            return
        }
        ensureCapacity(used + size)
        unsafe {
            value.rawData().copyTo(buffer, start, used, size)
        }
        used += size
    }

    public func writeByte(value: Byte): Unit {
        ensureCapacity(used + 1)
        writeRawByteNoEnsure(value)
    }

    public func writeBytes(value: Array<Byte>): Unit {
        if (value.isEmpty()) { return }
        ensureCapacity(used + value.size)
        value.copyTo(buffer, 0, used, value.size)
        used += value.size
    }

    public func writeBytesRange(value: Array<Byte>, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) { return }
        ensureCapacity(used + size)
        value.copyTo(buffer, start, used, size)
        used += size
    }

    public func reserveCapacity(additional: Int64): Unit {
        if (additional > 0) {
            ensureCapacity(used + additional)
        }
    }

    public func tryWriteNativeInt64Array(values: ArrayList<Int64>): Bool {
        if (values.size < YJSON_NATIVE_MIN_WRITER_INT64_COUNT) { return false }
        let required = values.size * 21 + 1
        ensureCapacity(used + required)
        if (let Some(written) <- jsonNativeFormatInt64ArrayInto(values, buffer, used)) {
            used += written
            return true
        }
        false
    }

    public func writeStringLiteralNoEscape(value: String): Unit {
        ensureCapacity(used + value.size + 2)
        buffer[used] = b'"'
        used++
        unsafe {
            value.rawData().copyTo(buffer, 0, used, value.size)
        }
        used += value.size
        buffer[used] = b'"'
        used++
    }

    public func writeStringLiteralNoEscapeName(value: String): Unit {
        ensureCapacity(used + value.size + 3)
        buffer[used] = b'"'
        used++
        unsafe {
            value.rawData().copyTo(buffer, 0, used, value.size)
        }
        used += value.size
        buffer[used] = b'"'
        used++
        buffer[used] = b':'
        used++
    }

    public func writeEscapedStringLiteralFromFirstEscape(value: String, firstEscape: Int64, htmlSafe: Bool): Unit {
        ensureCapacity(used + value.size + 8)
        writeRawByteNoEnsure(b'"')
        var segmentStart: Int64 = 0
        if (!htmlSafe) {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !(byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\'))) {
                    continue
                }
                ensureCapacity(used + (index - segmentStart) + 6 + (value.size - index) + 1)
                copyTextRangeNoEnsure(value, segmentStart, index)
                writeAsciiEscapeNoEnsure(byte)
                segmentStart = index + 1
            }
            ensureCapacity(used + (value.size - segmentStart) + 1)
            copyTextRangeNoEnsure(value, segmentStart, value.size)
            writeRawByteNoEnsure(b'"')
            return
        }
        for (index in firstEscape..value.size) {
            let byte = Int64(value[index])
            if (byte > 127 || !shouldEscapeAsciiForConfig(byte, htmlSafe)) {
                continue
            }
            ensureCapacity(used + (index - segmentStart) + 6 + (value.size - index) + 1)
            copyTextRangeNoEnsure(value, segmentStart, index)
            writeAsciiEscapeNoEnsure(byte)
            segmentStart = index + 1
        }
        ensureCapacity(used + (value.size - segmentStart) + 1)
        copyTextRangeNoEnsure(value, segmentStart, value.size)
        writeRawByteNoEnsure(b'"')
    }

    public func writeTextStringLiteralNoEscape(prefix: String, value: String): Unit {
        ensureCapacity(used + prefix.size + value.size + 2)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(value)
        writeRawByteNoEnsure(b'"')
    }

    public func writeTextStringLiteralTextNoEscape(prefix: String, value: String, suffix: String): Unit {
        ensureCapacity(used + prefix.size + value.size + suffix.size + 2)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(value)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(suffix)
    }

    public func writeTextStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit {
        ensureCapacity(used + prefix.size + totalStringSize + values.size * 3 + 2)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'[')
        if (values.size != 0) {
            writeRawByteNoEnsure(b'"')
            copyTextNoEnsure(values[0])
            writeRawByteNoEnsure(b'"')
            for (index in 1..values.size) {
                writeRawByteNoEnsure(b',')
                writeRawByteNoEnsure(b'"')
                copyTextNoEnsure(values[index])
                writeRawByteNoEnsure(b'"')
            }
        }
        writeRawByteNoEnsure(b']')
    }

    public func writeCompactInt64Map(prefix: String, values: HashMap<String, Int64>): Unit {
        reserveCapacity(jsonRawInt64MapReserveHint(prefix.size, values.size))
        ensureCapacity(used + prefix.size + 1)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'{')
        var first = true
        for ((key, item) in values) {
            let firstEscape = jsonRawCompactStringEscapeIndex(key)
            if (firstEscape < 0) {
                ensureCapacity(used + key.size + 24)
                if (!first) {
                    writeRawByteNoEnsure(b',')
                }
                writeRawByteNoEnsure(b'"')
                copyTextNoEnsure(key)
                writeRawByteNoEnsure(b'"')
                writeRawByteNoEnsure(b':')
                writeInt64NoEnsure(item)
            } else {
                if (!first) {
                    writeByte(b',')
                }
                writeEscapedStringLiteralFromFirstEscape(key, firstEscape, false)
                ensureCapacity(used + 21)
                writeRawByteNoEnsure(b':')
                writeInt64NoEnsure(item)
            }
            first = false
        }
        writeByte(b'}')
    }

    public func writeNewlineAndIndent(newline: String, indent: String, depth: Int64): Unit {
        ensureCapacity(used + newline.size + indent.size * depth)
        copyTextNoEnsure(newline)
        for (_ in 0..depth) {
            copyTextNoEnsure(indent)
        }
    }

    public func writeTextInt64StringLiteralInt64Text(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        ensureCapacity(used + prefix.size + stringPrefix.size + stringValue.size + intPrefix.size + suffix.size + 44)
        copyTextNoEnsure(prefix)
        writeInt64NoEnsure(firstValue)
        copyTextNoEnsure(stringPrefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(stringValue)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(intPrefix)
        writeInt64NoEnsure(intValue)
        copyTextNoEnsure(suffix)
    }

    public func writeTextInt64StringLiteralInt64TextNoEnsure(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        copyTextNoEnsure(prefix)
        writeInt64NoEnsure(firstValue)
        copyTextNoEnsure(stringPrefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(stringValue)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(intPrefix)
        writeInt64NoEnsure(intValue)
        copyTextNoEnsure(suffix)
    }

    public func writeTextStringLiteralInt64Text(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        ensureCapacity(used + prefix.size + stringValue.size + intPrefix.size + suffix.size + 24)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(stringValue)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(intPrefix)
        writeInt64NoEnsure(intValue)
        copyTextNoEnsure(suffix)
    }

    public func writeTextStringLiteralInt64TextNoEnsure(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(stringValue)
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(intPrefix)
        writeInt64NoEnsure(intValue)
        copyTextNoEnsure(suffix)
    }

    public func writeObjectEntryNameInt64NoEscape(first: Bool, name: String, value: Int64): Bool {
        ensureCapacity(used + name.size + 24)
        if (!first) {
            writeRawByteNoEnsure(b',')
        }
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(name)
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeInt64NoEnsure(value)
        false
    }

    public func writeBoolText(value: Bool): Unit {
        if (value) {
            writeText("true")
        } else {
            writeText("false")
        }
    }

    public func writeInt64Text(value: Int64): Unit {
        ensureCapacity(used + 21)
        writeInt64NoEnsure(value)
    }

    public func writeUInt64Text(value: UInt64): Unit {
        writeUInt64Digits(value)
    }

    public func writeFloat64Text(value: Float64): Unit {
        writeText(value.toString())
    }

    private func ensureCapacity(required: Int64): Unit {
        if (required <= buffer.size) {
            return
        }
        var newCapacity = buffer.size * 2
        while (newCapacity < required) {
            newCapacity *= 2
        }
        let newBuffer = Array<Byte>(newCapacity, repeat: 0)
        buffer.copyTo(newBuffer, 0, 0, used)
        buffer = newBuffer
    }

    private func writeRawByteNoEnsure(value: Byte): Unit {
        buffer[used] = value
        used++
    }

    private func writeUInt64Digits(value: UInt64): Unit {
        ensureCapacity(used + 20)
        writeUInt64DigitsNoEnsure(value)
    }

    private func writeInt64NoEnsure(value: Int64): Unit {
        if (value < 0) {
            if (value == -0x8000_0000_0000_0000) {
                copyTextNoEnsure("-9223372036854775808")
                return
            }
            writeRawByteNoEnsure(b'-')
            writeUInt64DigitsNoEnsure(UInt64(-value))
            return
        }
        writeUInt64DigitsNoEnsure(UInt64(value))
    }

    private func writeUInt64DigitsNoEnsure(value: UInt64): Unit {
        if (value == 0u64) {
            writeRawByteNoEnsure(b'0')
            return
        }
        if (value < 10u64) {
            writeRawByteNoEnsure(UInt8(48u64 + value))
            return
        }
        if (value < 100u64) {
            writeRawByteNoEnsure(UInt8(48u64 + value / 10u64))
            writeRawByteNoEnsure(UInt8(48u64 + value % 10u64))
            return
        }
        if (value < 1000u64) {
            writeRawByteNoEnsure(UInt8(48u64 + value / 100u64))
            let rest = value % 100u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 10u64))
            writeRawByteNoEnsure(UInt8(48u64 + rest % 10u64))
            return
        }
        if (value < 10000u64) {
            writeRawByteNoEnsure(UInt8(48u64 + value / 1000u64))
            var rest = value % 1000u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 100u64))
            rest %= 100u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 10u64))
            writeRawByteNoEnsure(UInt8(48u64 + rest % 10u64))
            return
        }
        if (value < 100000u64) {
            writeRawByteNoEnsure(UInt8(48u64 + value / 10000u64))
            var rest = value % 10000u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 1000u64))
            rest %= 1000u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 100u64))
            rest %= 100u64
            writeRawByteNoEnsure(UInt8(48u64 + rest / 10u64))
            writeRawByteNoEnsure(UInt8(48u64 + rest % 10u64))
            return
        }
        var current = value
        let end = used + 20
        var cursor = end
        while (current != 0u64) {
            let digit = current % 10u64
            cursor--
            buffer[cursor] = UInt8(48u64 + digit)
            current /= 10u64
        }
        let size = end - cursor
        buffer.copyTo(buffer, cursor, used, size)
        used += size
    }

    private func copyTextNoEnsure(value: String): Unit {
        unsafe {
            value.rawData().copyTo(buffer, 0, used, value.size)
        }
        used += value.size
    }

    private func copyTextRangeNoEnsure(value: String, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) {
            return
        }
        unsafe {
            value.rawData().copyTo(buffer, start, used, size)
        }
        used += size
    }

    private func shouldEscapeAsciiForConfig(byte: Int64, htmlSafe: Bool): Bool {
        if (byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\')) {
            return true
        }
        if (!htmlSafe) {
            return false
        }
        byte == Int64(b'<') ||
            byte == Int64(b'>') ||
            byte == Int64(b'&') ||
            byte == Int64(b'=') ||
            byte == Int64(b'\'')
    }

    private func writeAsciiEscapeNoEnsure(byte: Int64): Unit {
        if (byte == Int64(b'"')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'"')
            return
        }
        if (byte == Int64(b'\\')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'\\')
            return
        }
        if (byte == Int64(b'\b')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'b')
            return
        }
        if (byte == Int64(b'\f')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'f')
            return
        }
        if (byte == Int64(b'\n')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'n')
            return
        }
        if (byte == Int64(b'\r')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b'r')
            return
        }
        if (byte == Int64(b'\t')) {
            writeRawByteNoEnsure(b'\\')
            writeRawByteNoEnsure(b't')
            return
        }
        writeRawByteNoEnsure(b'\\')
        writeRawByteNoEnsure(b'u')
        writeRawByteNoEnsure(b'0')
        writeRawByteNoEnsure(b'0')
        writeRawByteNoEnsure(hexNibbleByte(byte >> 4))
        writeRawByteNoEnsure(hexNibbleByte(byte & 0xF))
    }

    private func hexNibbleByte(value: Int64): Byte {
        if (value < 10) {
            return UInt8(48 + value)
        }
        UInt8(87 + value)
    }

    public func finish(): Unit {}

    public func bytesWritten(): Int64 { used }


    public func buildString(): String {
        String.fromUtf8(buffer[0..used])
    }

    public func buildBytes(): Array<Byte> {
        buffer[0..used]
    }
}


class DirectStreamWriterTarget <: JsonDirectWriterTarget {
    private let out: OutputStream
    private let buffer: Array<Byte>
    private let maxBytes: Int64
    private let includeErrorLocation: Bool
    private var used: Int64 = 0
    private var committed: Int64 = 0
    private var limitFailed: Bool = false

    init(out: OutputStream, config: JsonWriteConfig) {
        this.out = out
        this.buffer = Array<Byte>(JSON_STREAM_BUFFER_CAPACITY, repeat: 0)
        this.maxBytes = config.maxBytes
        this.includeErrorLocation = config.includeErrorLocation
    }

    public func writeText(value: String): Unit {
        writeTextRange(value, 0, value.size)
    }

    public func writeTextRange(value: String, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) {
            return
        }
        ensureAdditionalOutput(size)
        if (size >= JSON_STREAM_DIRECT_WRITE_THRESHOLD) {
            flushBuffer()
            unsafe {
                out.write(value.rawData()[start..end])
            }
            committed += size
            return
        }
        if (used + size > buffer.size) {
            flushBuffer()
        }
        unsafe {
            value.rawData().copyTo(buffer, start, used, size)
        }
        used += size
        if (used == buffer.size) {
            flushBuffer()
        }
    }

    public func writeByte(value: Byte): Unit {
        writeRawByte(value)
    }

    public func writeBytes(value: Array<Byte>): Unit {
        if (value.isEmpty()) { return }
        ensureAdditionalOutput(value.size)
        if (value.size >= JSON_STREAM_DIRECT_WRITE_THRESHOLD) {
            flushBuffer()
            out.write(value)
            committed += value.size
            return
        }
        if (used + value.size > buffer.size) { flushBuffer() }
        value.copyTo(buffer, 0, used, value.size)
        used += value.size
    }

    public func writeBytesRange(value: Array<Byte>, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) { return }
        ensureAdditionalOutput(size)
        if (size >= JSON_STREAM_DIRECT_WRITE_THRESHOLD) {
            flushBuffer()
            out.write(value[start..end])
            committed += size
            return
        }
        if (used + size > buffer.size) { flushBuffer() }
        value.copyTo(buffer, start, used, size)
        used += size
    }

    public func reserveCapacity(additional: Int64): Unit {
        if (additional > 0 && additional < buffer.size) {
            ensureBufferedCapacity(additional)
        }
    }

    public func tryWriteNativeInt64Array(_values: ArrayList<Int64>): Bool { false }

    public func writeStringLiteralNoEscape(value: String): Unit {
        writeRawByte(b'"')
        writeText(value)
        writeRawByte(b'"')
    }

    public func writeStringLiteralNoEscapeName(value: String): Unit {
        writeRawByte(b'"')
        writeText(value)
        writeRawByte(b'"')
        writeRawByte(b':')
    }

    public func writeEscapedStringLiteralFromFirstEscape(value: String, firstEscape: Int64, htmlSafe: Bool): Unit {
        writeRawByte(b'"')
        var segmentStart: Int64 = 0
        if (!htmlSafe) {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !(byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\'))) {
                    continue
                }
                writeTextRange(value, segmentStart, index)
                writeAsciiEscape(byte)
                segmentStart = index + 1
            }
            writeTextRange(value, segmentStart, value.size)
            writeRawByte(b'"')
            return
        }
        for (index in firstEscape..value.size) {
            let byte = Int64(value[index])
            if (byte > 127 || !shouldEscapeAsciiForConfig(byte, htmlSafe)) {
                continue
            }
            writeTextRange(value, segmentStart, index)
            writeAsciiEscape(byte)
            segmentStart = index + 1
        }
        writeTextRange(value, segmentStart, value.size)
        writeRawByte(b'"')
    }

    public func writeTextStringLiteralNoEscape(prefix: String, value: String): Unit {
        writeText(prefix)
        writeRawByte(b'"')
        writeText(value)
        writeRawByte(b'"')
    }

    public func writeTextStringLiteralTextNoEscape(prefix: String, value: String, suffix: String): Unit {
        writeText(prefix)
        writeRawByte(b'"')
        writeText(value)
        writeRawByte(b'"')
        writeText(suffix)
    }

    public func writeTextStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit {
        reserveCapacity(prefix.size + totalStringSize + values.size * 3 + 2)
        writeText(prefix)
        writeRawByte(b'[')
        if (values.size != 0) {
            writeStringLiteralNoEscape(values[0])
            for (index in 1..values.size) {
                writeRawByte(b',')
                writeStringLiteralNoEscape(values[index])
            }
        }
        writeRawByte(b']')
    }

    public func writeCompactInt64Map(prefix: String, values: HashMap<String, Int64>): Unit {
        reserveCapacity(jsonRawInt64MapReserveHint(prefix.size, values.size))
        writeText(prefix)
        writeRawByte(b'{')
        var first = true
        for ((key, item) in values) {
            let firstEscape = jsonRawCompactStringEscapeIndex(key)
            if (firstEscape < 0) {
                first = writeObjectEntryNameInt64NoEscape(first, key, item)
            } else {
                if (!first) {
                    writeRawByte(b',')
                }
                writeEscapedStringLiteralFromFirstEscape(key, firstEscape, false)
                writeRawByte(b':')
                writeInt64Text(item)
                first = false
            }
        }
        writeRawByte(b'}')
    }

    public func writeNewlineAndIndent(newline: String, indent: String, depth: Int64): Unit {
        writeText(newline)
        for (_ in 0..depth) {
            writeText(indent)
        }
    }

    public func writeTextInt64StringLiteralInt64Text(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        writeText(prefix)
        writeInt64Text(firstValue)
        writeTextStringLiteralNoEscape(stringPrefix, stringValue)
        writeText(intPrefix)
        writeInt64Text(intValue)
        writeText(suffix)
    }

    public func writeTextInt64StringLiteralInt64TextNoEnsure(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        writeTextInt64StringLiteralInt64Text(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, suffix)
    }

    public func writeTextStringLiteralInt64Text(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        writeTextStringLiteralNoEscape(prefix, stringValue)
        writeText(intPrefix)
        writeInt64Text(intValue)
        writeText(suffix)
    }

    public func writeTextStringLiteralInt64TextNoEnsure(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        writeTextStringLiteralInt64Text(prefix, stringValue, intPrefix, intValue, suffix)
    }

    public func writeObjectEntryNameInt64NoEscape(first: Bool, name: String, value: Int64): Bool {
        if (!first) {
            writeRawByte(b',')
        }
        writeStringLiteralNoEscapeName(name)
        writeInt64Text(value)
        false
    }

    public func writeBoolText(value: Bool): Unit {
        if (value) {
            writeText("true")
        } else {
            writeText("false")
        }
    }

    public func writeInt64Text(value: Int64): Unit {
        if (value < 0) {
            if (value == -0x8000_0000_0000_0000) {
                writeText("-9223372036854775808")
                return
            }
            writeRawByte(b'-')
            writeUInt64Digits(UInt64(-value))
            return
        }
        writeUInt64Digits(UInt64(value))
    }

    public func writeUInt64Text(value: UInt64): Unit {
        writeUInt64Digits(value)
    }

    public func writeFloat64Text(value: Float64): Unit {
        writeText(value.toString())
    }

    private func flushBuffer(): Unit {
        if (used == 0) {
            return
        }
        if (used == buffer.size) {
            out.write(buffer)
        } else {
            out.write(buffer[0..used])
        }
        committed += used
        used = 0
    }

    private func ensureBufferedCapacity(additional: Int64): Unit {
        if (used + additional > buffer.size) {
            flushBuffer()
        }
    }

    private func writeRawByte(value: Byte): Unit {
        ensureAdditionalOutput(1)
        ensureBufferedCapacity(1)
        buffer[used] = value
        used++
        if (used == buffer.size) {
            flushBuffer()
        }
    }

    private func writeUInt64Digits(value: UInt64): Unit {
        ensureAdditionalOutput(jsonRawUInt64Size(value))
        if (value == 0u64) {
            writeRawByteNoLimit(b'0')
            return
        }
        if (value < 10u64) {
            writeRawByteNoLimit(UInt8(48u64 + value))
            return
        }
        if (value < 100u64) {
            ensureBufferedCapacity(2)
            buffer[used] = UInt8(48u64 + value / 10u64)
            buffer[used + 1] = UInt8(48u64 + value % 10u64)
            used += 2
            return
        }
        if (value < 1000u64) {
            ensureBufferedCapacity(3)
            buffer[used] = UInt8(48u64 + value / 100u64)
            let rest = value % 100u64
            buffer[used + 1] = UInt8(48u64 + rest / 10u64)
            buffer[used + 2] = UInt8(48u64 + rest % 10u64)
            used += 3
            return
        }
        if (value < 10000u64) {
            ensureBufferedCapacity(4)
            buffer[used] = UInt8(48u64 + value / 1000u64)
            var rest = value % 1000u64
            buffer[used + 1] = UInt8(48u64 + rest / 100u64)
            rest %= 100u64
            buffer[used + 2] = UInt8(48u64 + rest / 10u64)
            buffer[used + 3] = UInt8(48u64 + rest % 10u64)
            used += 4
            return
        }
        if (value < 100000u64) {
            ensureBufferedCapacity(5)
            buffer[used] = UInt8(48u64 + value / 10000u64)
            var rest = value % 10000u64
            buffer[used + 1] = UInt8(48u64 + rest / 1000u64)
            rest %= 1000u64
            buffer[used + 2] = UInt8(48u64 + rest / 100u64)
            rest %= 100u64
            buffer[used + 3] = UInt8(48u64 + rest / 10u64)
            buffer[used + 4] = UInt8(48u64 + rest % 10u64)
            used += 5
            return
        }
        ensureBufferedCapacity(20)
        var current = value
        let end = used + 20
        var cursor = end
        while (current != 0u64) {
            let digit = current % 10u64
            cursor--
            buffer[cursor] = UInt8(48u64 + digit)
            current /= 10u64
        }
        let size = end - cursor
        buffer.copyTo(buffer, cursor, used, size)
        used += size
    }

    private func writeRawByteNoLimit(value: Byte): Unit {
        ensureBufferedCapacity(1)
        buffer[used] = value
        used++
        if (used == buffer.size) {
            flushBuffer()
        }
    }

    private func ensureAdditionalOutput(additional: Int64): Unit {
        if (limitFailed) {
            throwOutputLimit()
        }
        let written = bytesWritten()
        if (maxBytes > 0 && (written > maxBytes || additional > maxBytes - written)) {
            limitFailed = true
            throwOutputLimit()
        }
    }

    private func throwOutputLimit(): Nothing {
        throw JsonException(
            "Encoded JSON exceeds ${maxBytes} bytes",
            code: "output_too_large",
            byteOffset: if (includeErrorLocation) { maxBytes } else { -1 }
        )
    }

    private func shouldEscapeAsciiForConfig(byte: Int64, htmlSafe: Bool): Bool {
        if (byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\')) {
            return true
        }
        if (!htmlSafe) {
            return false
        }
        byte == Int64(b'<') ||
            byte == Int64(b'>') ||
            byte == Int64(b'&') ||
            byte == Int64(b'=') ||
            byte == Int64(b'\'')
    }

    private func writeAsciiEscape(byte: Int64): Unit {
        if (byte == Int64(b'"')) {
            writeRawByte(b'\\')
            writeRawByte(b'"')
            return
        }
        if (byte == Int64(b'\\')) {
            writeRawByte(b'\\')
            writeRawByte(b'\\')
            return
        }
        if (byte == Int64(b'\b')) {
            writeRawByte(b'\\')
            writeRawByte(b'b')
            return
        }
        if (byte == Int64(b'\f')) {
            writeRawByte(b'\\')
            writeRawByte(b'f')
            return
        }
        if (byte == Int64(b'\n')) {
            writeRawByte(b'\\')
            writeRawByte(b'n')
            return
        }
        if (byte == Int64(b'\r')) {
            writeRawByte(b'\\')
            writeRawByte(b'r')
            return
        }
        if (byte == Int64(b'\t')) {
            writeRawByte(b'\\')
            writeRawByte(b't')
            return
        }
        writeRawByte(b'\\')
        writeRawByte(b'u')
        writeRawByte(b'0')
        writeRawByte(b'0')
        writeRawByte(hexNibbleByte(byte >> 4))
        writeRawByte(hexNibbleByte(byte & 0xF))
    }

    private func hexNibbleByte(value: Int64): Byte {
        if (value < 10) {
            return UInt8(48 + value)
        }
        UInt8(87 + value)
    }

    public func finish(): Unit {
        if (limitFailed) {
            throwOutputLimit()
        }
        flushBuffer()
        out.flush()
    }

    public func bytesWritten(): Int64 { committed + used }

}

public class JsonDirectWriter <: GeneratedSupportV1Writer {
    private static let ARRAY_FIRST: UInt8 = 0x1
    private static let ARRAY_NEXT: UInt8 = 0x0
    private static let OBJECT_FIRST: UInt8 = 0x3
    private static let OBJECT_NEXT: UInt8 = 0x2
    private static let OBJECT_EXPECTING_VALUE: UInt8 = 0x6
    private static let OBJECT_MASK: UInt8 = 0x2
    private static let FIRST_MASK: UInt8 = 0x1
    private static let EXPECTING_VALUE_MASK: UInt8 = 0x4

    private let target: JsonDirectWriterTarget
    private let config: JsonWriteConfig
    private let multiline: Bool
    private let resultKind: UInt8
    private var contexts: Option<ArrayList<UInt8>> = None<ArrayList<UInt8>>
    private var rootWritten: Bool = false
    private var rawDepth: Int64 = 0
    private var rawRootPreclaimed: Bool = false

    public init(pretty!: Bool = false) {
        let writerConfig = if (pretty) { JsonWriteConfig.pretty } else { JsonWriteConfig.compact }
        target = DirectBufferWriterTarget(capacity: directStringWriterInitialCapacity(writerConfig))
        config = writerConfig
        multiline = !config.newline.isEmpty()
        resultKind = 0
    }

    public init(config: JsonWriteConfig) {
        target = DirectBufferWriterTarget(capacity: directStringWriterInitialCapacity(config))
        this.config = config
        multiline = !config.newline.isEmpty()
        resultKind = 0
    }

    public init(out: OutputStream, config!: JsonWriteConfig = JsonWriteConfig.compact) {
        target = DirectStreamWriterTarget(out, config)
        this.config = config
        multiline = !config.newline.isEmpty()
        resultKind = 2
    }

    private init(target: JsonDirectWriterTarget, config: JsonWriteConfig, resultKind: UInt8) {
        this.target = target
        this.config = config
        multiline = !config.newline.isEmpty()
        this.resultKind = resultKind
    }

    public static func bytes(config!: JsonWriteConfig = JsonWriteConfig.compact): JsonDirectWriter {
        JsonDirectWriter(DirectBufferWriterTarget(), config, 1)
    }

    public func generatedCursorV1(): GeneratedSupportV1WriteCursor {
        GeneratedSupportV1WriteCursor(this)
    }

    public func finish(): Unit {
        ensureCompleteWriterState()
        target.finish()
        enforceOutputLimit()
    }

    public func finishString(): String {
        ensureCompleteWriterState()
        target.finish()
        enforceOutputLimit()
        if (resultKind != 0) {
            throw JsonException("JsonDirectWriter is not a string writer")
        }
        match (target) {
            case stringTarget: DirectBufferWriterTarget => stringTarget.buildString()
            case _ => throw JsonException("JsonDirectWriter is not a string writer")
        }
    }

    public func finishBytes(): Array<Byte> {
        ensureCompleteWriterState()
        target.finish()
        enforceOutputLimit()
        if (resultKind != 1) {
            throw JsonException("JsonDirectWriter is not a bytes writer")
        }
        match (target) {
            case bytesTarget: DirectBufferWriterTarget => bytesTarget.buildBytes()
            case _ => throw JsonException("JsonDirectWriter is not a bytes writer")
        }
    }

    private func enforceOutputLimit(): Unit {
        if (config.maxBytes > 0 && target.bytesWritten() > config.maxBytes) {
            throw JsonException(
                "Encoded JSON exceeds ${config.maxBytes} bytes",
                code: "output_too_large",
                byteOffset: if (config.includeErrorLocation) { config.maxBytes } else { -1 }
            )
        }
    }

    private func ensureCompleteWriterState(): Unit {
        if (!rootWritten || !contextsAreEmpty() || rawDepth != 0 || rawRootPreclaimed) {
            throw JsonException("JSON writer requires exactly one complete root value", code: "writer_state")
        }
    }

    private func contextValues(): ArrayList<UInt8> {
        match (contexts) {
            case Some(value) => value
            case None =>
                let value = ArrayList<UInt8>()
                contexts = Some(value)
                value
        }
    }

    private func contextsAreEmpty(): Bool {
        match (contexts) {
            case Some(value) => value.isEmpty()
            case None => true
        }
    }

    func canWriteRawCompactValue(): Bool {
        contextsAreEmpty() && !rootWritten && !multiline && !config.useSpaceAfterSeparators && !config.htmlSafe
    }

    public func tryBeginGeneratedCompactRawValue(): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        beforeValue()
        rawRootPreclaimed = true
        true
    }

    public func writeRawByte(value: Byte): Unit {
        consumeRawRootPreclaim()
        target.writeByte(value)
    }

    public func writeRawBeginArray(): Unit {
        beginRawContainer()
        target.writeByte(b'[')
    }

    public func writeRawEndArray(): Unit {
        endRawContainer()
        target.writeByte(b']')
    }

    public func writeRawBeginObject(): Unit {
        beginRawContainer()
        target.writeByte(b'{')
    }

    public func writeRawEndObject(): Unit {
        endRawContainer()
        target.writeByte(b'}')
    }

    func reserveRawCollectionCapacity(count: Int64): Unit {
        if (count < 4) { return }
        var hint = count * 64 + 2
        if (hint > 4096) { hint = 4096 }
        target.reserveCapacity(hint)
    }

    public func writeRawObjectEntryName(first: Bool, value: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(value)
        false
    }

    public func writeRawObjectEntryNameString(first: Bool, name: String, value: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        writeRawString(value)
        false
    }

    public func writeRawObjectEntryNameInt64(first: Bool, name: String, value: Int64): Bool {
        let firstEscape = firstStringEscapeIndex(name)
        if (firstEscape < 0) {
            return target.writeObjectEntryNameInt64NoEscape(first, name, value)
        }
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        target.writeInt64Text(value)
        false
    }

    public func writeRawObjectEntryNameBool(first: Bool, name: String, value: Bool): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        target.writeBoolText(value)
        false
    }

    func writeRawObjectEntryNameNumberValue(first: Bool, name: String, value: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        target.writeText(value)
        false
    }

    func writeRawObjectEntryNameNull(first: Bool, name: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        target.writeText("null")
        false
    }

    func writeRawStringArrayList(prefix: String, values: ArrayList<String>): Unit {
        var totalStringSize: Int64 = 0
        for (value in values) {
            if (firstStringEscapeIndex(value) >= 0) {
                writeRawStringArrayListFallback(prefix, values)
                return
            }
            totalStringSize += value.size
        }
        target.writeTextStringArrayListNoEscape(prefix, values, totalStringSize)
    }

    private func writeRawStringArrayListFallback(prefix: String, values: ArrayList<String>): Unit {
        target.writeText(prefix)
        if (values.size == 0) {
            target.writeText("[]")
            return
        }
        target.writeByte(b'[')
        writeRawString(values[0])
        for (index in 1..values.size) {
            target.writeByte(b',')
            writeRawString(values[index])
        }
        target.writeByte(b']')
    }

    func writeRawInt64Map(prefix: String, values: HashMap<String, Int64>): Unit {
        target.writeCompactInt64Map(prefix, values)
    }

    func tryWriteCompactRawMap<T>(values: HashMap<String, T>, codec: JsonRawWriteCodec<T>): Bool {
        if (!canWriteRawCompactValue()) {
            return false
        }
        ensureContainerDepth()
        beforeValue()
        rawDepth++
        try {
            target.reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
            target.writeByte(b'{')
            var first = true
            for ((name, item) in values) {
                if (first) {
                    first = false
                } else {
                    target.writeByte(b',')
                }
                let firstEscape = jsonRawCompactStringEscapeIndex(name)
                if (firstEscape < 0) {
                    target.writeStringLiteralNoEscapeName(name)
                } else {
                    target.writeEscapedStringLiteralFromFirstEscape(name, firstEscape, false)
                    target.writeByte(b':')
                }
                codec.writeRaw(item, this)
            }
            target.writeByte(b'}')
        } finally {
            rawDepth--
        }
        true
    }

    public func tryWriteCompactInt64ArrayList(values: ArrayList<Int64>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        ensureContainerDepth()
        beforeValue()
        rawDepth++
        try {
            if (target.tryWriteNativeInt64Array(values)) { return true }
            var totalValueSize: Int64 = 0
            for (item in values) {
                totalValueSize += jsonRawInt64Size(item)
            }
            target.reserveCapacity(totalValueSize + values.size + 1)
            target.writeByte(b'[')
            if (!values.isEmpty()) {
                target.writeInt64Text(values[0])
                for (index in 1..values.size) {
                    target.writeByte(b',')
                    target.writeInt64Text(values[index])
                }
            }
            target.writeByte(b']')
        } finally {
            rawDepth--
        }
        true
    }

    public func tryWriteCompactStringArrayList(values: ArrayList<String>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        ensureContainerDepth()
        beforeValue()
        rawDepth++
        try {
            writeRawStringArrayList("", values)
        } finally {
            rawDepth--
        }
        true
    }

    public func tryWriteCompactInt64Map(values: HashMap<String, Int64>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        ensureContainerDepth()
        beforeValue()
        rawDepth++
        try {
            writeRawInt64Map("", values)
        } finally {
            rawDepth--
        }
        true
    }

    func writeRawString(value: String): Unit {
        beginRawScalar()
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeStringLiteralNoEscape(value)
            return
        }
        writeStringLiteralFromFirstEscape(value, firstEscape)
    }

    public func writeRawNull(): Unit {
        beginRawScalar()
        target.writeText("null")
    }

    func writeRawBool(value: Bool): Unit {
        beginRawScalar()
        target.writeBoolText(value)
    }

    func writeRawInt64(value: Int64): Unit {
        beginRawScalar()
        target.writeInt64Text(value)
    }

    func writeRawUInt64(value: UInt64): Unit {
        beginRawScalar()
        target.writeUInt64Text(value)
    }

    func writeRawNumberValue(value: String): Unit {
        beginRawScalar()
        target.writeText(value)
    }

    private func beginRawScalar(): Unit {
        if (rawDepth != 0) { return }
        if (rawRootPreclaimed) {
            rawRootPreclaimed = false
            return
        }
        beforeValue()
    }

    private func beginRawContainer(): Unit {
        if (rawDepth == 0) {
            if (rawRootPreclaimed) {
                rawRootPreclaimed = false
            } else {
                beforeValue()
            }
        }
        if (currentContainerDepth() >= config.maxDepth) {
            throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
        }
        rawDepth++
    }

    private func endRawContainer(): Unit {
        if (rawDepth <= 0) {
            throw JsonException("Unbalanced JSON writer state", code: "writer_state")
        }
        rawDepth--
    }

    private func consumeRawRootPreclaim(): Unit {
        if (rawDepth == 0 && rawRootPreclaimed) {
            rawRootPreclaimed = false
        }
    }

    public func startObject(): Unit {
        ensureContainerDepth()
        beforeValue()
        target.writeByte(b'{')
        contextValues().add(OBJECT_FIRST)
    }

    public func endObject(): Unit {
        let context = popContext(true)
        let values = contextValues()
        if ((context & FIRST_MASK) == 0 && multiline) {
            writeNewlineAndIndent(values.size)
        }
        target.writeByte(b'}')
    }

    public func startArray(): Unit {
        ensureContainerDepth()
        beforeValue()
        target.writeByte(b'[')
        contextValues().add(ARRAY_FIRST)
    }

    public func endArray(): Unit {
        let context = popContext(false)
        let values = contextValues()
        if ((context & FIRST_MASK) == 0 && multiline) {
            writeNewlineAndIndent(values.size)
        }
        target.writeByte(b']')
    }

    public func writeName(name: String): Unit {
        beforeName()
        writeStringLiteralName(name)
        if (config.useSpaceAfterSeparators) {
            target.writeText(" ")
        }
    }

    private func beforeName(): Unit {
        if (contextsAreEmpty()) {
            throw JsonException("Cannot write a field name outside object")
        }
        let values = contextValues()
        let index = values.size - 1
        let context = values[index]
        if ((context & OBJECT_MASK) == 0 || (context & EXPECTING_VALUE_MASK) != 0) {
            throw JsonException("Cannot write a field name here")
        }
        if ((context & FIRST_MASK) != 0) {
            writeEntryPrefix(values.size)
        } else {
            target.writeByte(b',')
            writeEntryPrefix(values.size)
        }
        values[index] = OBJECT_EXPECTING_VALUE
    }

    public func writeNull(): Unit {
        beforeValue()
        target.writeText("null")
    }

    public func writeBool(value: Bool): Unit {
        beforeValue()
        target.writeBoolText(value)
    }

    public func writeInt64(value: Int64): Unit {
        beforeValue()
        target.writeInt64Text(value)
    }

    public func writeUInt64(value: UInt64): Unit {
        beforeValue()
        target.writeUInt64Text(value)
    }

    public func writeFloat64(value: Float64): Unit {
        ensureFiniteJsonFloat(value)
        beforeValue()
        target.writeFloat64Text(value)
    }

    public func writeRawNumber(value: String): Unit {
        beforeValue()
        target.writeText(value)
    }

    public func writeString(value: String): Unit {
        beforeValue()
        writeStringLiteral(value)
    }

    private func beforeValue(): Unit {
        if (contextsAreEmpty()) {
            if (rootWritten) {
                throw JsonException("JSON writer accepts exactly one root value", code: "writer_state")
            }
            rootWritten = true
            return
        }
        let values = contextValues()
        let index = values.size - 1
        let context = values[index]
        if ((context & OBJECT_MASK) != 0) {
            if ((context & EXPECTING_VALUE_MASK) == 0) {
                throw JsonException("Object values must be preceded by a field name")
            }
            values[index] = OBJECT_NEXT
            return
        }
        if ((context & FIRST_MASK) != 0) {
            writeEntryPrefix(values.size)
            values[index] = ARRAY_NEXT
            return
        }
        target.writeByte(b',')
        writeEntryPrefix(values.size)
    }

    private func ensureContainerDepth(): Unit {
        if (currentContainerDepth() >= config.maxDepth) {
            throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
        }
    }

    private func currentContainerDepth(): Int64 {
        let semanticDepth = match (contexts) {
            case Some(value) => value.size
            case None => 0
        }
        semanticDepth + rawDepth
    }

    private func popContext(expectedObject: Bool): UInt8 {
        if (contextsAreEmpty()) {
            throw JsonException("Unbalanced JSON writer state")
        }
        let values = contextValues()
        let index = values.size - 1
        let context = values[index]
        let objectContext = (context & OBJECT_MASK) != 0
        let expectingFieldValue = (context & EXPECTING_VALUE_MASK) != 0
        if (objectContext != expectedObject || expectingFieldValue) {
            throw JsonException("Unbalanced JSON writer state")
        }
        values.remove(at: index)
        context
    }

    private func writeEntryPrefix(depth: Int64): Unit {
        if (multiline) {
            writeNewlineAndIndent(depth)
        }
    }

    private func writeNewlineAndIndent(depth: Int64): Unit {
        target.writeNewlineAndIndent(config.newline, config.indent, depth)
    }

    private func writeStringLiteral(value: String): Unit {
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeStringLiteralNoEscape(value)
            return
        }
        writeStringLiteralFromFirstEscape(value, firstEscape)
    }

    private func writeStringLiteralName(value: String): Unit {
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeStringLiteralNoEscapeName(value)
            return
        }
        writeStringLiteralFromFirstEscape(value, firstEscape)
        target.writeByte(b':')
    }

    private func writeStringLiteralFromFirstEscape(value: String, firstEscape: Int64): Unit {
        if (let Some(required) <- jsonNativeEscapedStringSize(value, config.htmlSafe)) {
            enforceAdditionalOutputLimit(required)
            if (let Some(escaped) <- jsonNativeEscapeString(value, config.htmlSafe, required)) {
                target.writeBytes(escaped)
                return
            }
        }
        target.writeEscapedStringLiteralFromFirstEscape(value, firstEscape, config.htmlSafe)
    }

    private func enforceAdditionalOutputLimit(additional: Int64): Unit {
        if (config.maxBytes > 0 && (target.bytesWritten() > config.maxBytes ||
            additional > config.maxBytes - target.bytesWritten())) {
            throw JsonException(
                "Encoded JSON exceeds ${config.maxBytes} bytes",
                code: "output_too_large",
                byteOffset: if (config.includeErrorLocation) { config.maxBytes } else { -1 }
            )
        }
    }

    private func firstStringEscapeIndex(value: String): Int64 {
        unsafe {
            let bytes = value.rawData()
            for (index in 0..bytes.size) {
                let byte = Int64(bytes[index])
                if (byte <= 127 && shouldEscapeAscii(byte)) {
                    return index
                }
            }
        }
        -1
    }

    private func shouldEscapeAscii(byte: Int64): Bool {
        if (byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\')) {
            return true
        }
        if (!config.htmlSafe) {
            return false
        }
        byte == Int64(b'<') ||
            byte == Int64(b'>') ||
            byte == Int64(b'&') ||
            byte == Int64(b'=') ||
            byte == Int64(b'\'')
    }

}
