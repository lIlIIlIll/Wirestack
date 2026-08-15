package yjson

import std.collection.*
import std.io.*

const JSON_DIRECT_BYTES_INITIAL_CAPACITY: Int64 = 256
const JSON_DIRECT_PRETTY_STRING_INITIAL_CAPACITY: Int64 = 512

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

abstract class JsonDirectWriterTarget {
    protected func writeText(value: String): Unit

    protected func writeTextRange(value: String, start: Int64, end: Int64): Unit

    protected func writeByte(value: Byte): Unit

    protected func reserveCapacity(additional: Int64): Unit

    protected func writeStringLiteralNoEscape(value: String): Unit

    protected func writeStringLiteralNoEscapeName(value: String): Unit

    protected func writeEscapedStringLiteralFromFirstEscape(value: String, firstEscape: Int64, htmlSafe: Bool): Unit

    protected func writeTextStringLiteralNoEscape(prefix: String, value: String): Unit

    protected func writeTextStringLiteralTextNoEscape(prefix: String, value: String, suffix: String): Unit

    protected func writeTextStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit

    protected func writeTextInt64MapNoEscape(prefix: String, values: HashMap<String, Int64>, totalNameSize: Int64, totalValueSize: Int64): Unit

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

class DirectStringWriterTarget <: JsonDirectWriterTarget {
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

    public func reserveCapacity(additional: Int64): Unit {
        if (additional > 0) {
            ensureCapacity(used + additional)
        }
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

    public func writeTextInt64MapNoEscape(prefix: String, values: HashMap<String, Int64>, totalNameSize: Int64, totalValueSize: Int64): Unit {
        ensureCapacity(used + prefix.size + totalNameSize + totalValueSize + values.size * 4 + 2)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'{')
        var first = true
        for ((key, item) in values) {
            if (first) {
                first = false
            } else {
                writeRawByteNoEnsure(b',')
            }
            writeRawByteNoEnsure(b'"')
            copyTextNoEnsure(key)
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeInt64NoEnsure(item)
        }
        writeRawByteNoEnsure(b'}')
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


    public func build(): String {
        String.fromUtf8(buffer[0..used])
    }
}

class DirectBytesWriterTarget <: JsonDirectWriterTarget {
    private var buffer = Array<Byte>(JSON_DIRECT_BYTES_INITIAL_CAPACITY, repeat: 0)
    private var used: Int64 = 0

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

    public func reserveCapacity(additional: Int64): Unit {
        if (additional > 0) {
            ensureCapacity(used + additional)
        }
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

    public func writeTextInt64MapNoEscape(prefix: String, values: HashMap<String, Int64>, totalNameSize: Int64, totalValueSize: Int64): Unit {
        ensureCapacity(used + prefix.size + totalNameSize + totalValueSize + values.size * 4 + 2)
        copyTextNoEnsure(prefix)
        writeRawByteNoEnsure(b'{')
        var first = true
        for ((key, item) in values) {
            if (first) {
                first = false
            } else {
                writeRawByteNoEnsure(b',')
            }
            writeRawByteNoEnsure(b'"')
            copyTextNoEnsure(key)
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeInt64NoEnsure(item)
        }
        writeRawByteNoEnsure(b'}')
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


    public func build(): Array<Byte> {
        buffer[0..used]
    }
}

class DirectStreamWriterTarget <: JsonDirectWriterTarget {
    private let out: OutputStream
    private let buffer: Array<Byte>
    private var used: Int64 = 0

    public init(out: OutputStream) {
        this.out = out
        this.buffer = Array<Byte>(JSON_STREAM_BUFFER_CAPACITY, repeat: 0)
    }

    public func writeText(value: String): Unit {
        writeTextRange(value, 0, value.size)
    }

    public func writeTextRange(value: String, start: Int64, end: Int64): Unit {
        let size = end - start
        if (size <= 0) {
            return
        }
        if (size >= JSON_STREAM_DIRECT_WRITE_THRESHOLD) {
            flushBuffer()
            unsafe {
                out.write(value.rawData()[start..end])
            }
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

    public func reserveCapacity(additional: Int64): Unit {
        if (additional > 0 && additional < buffer.size) {
            ensureBufferedCapacity(additional)
        }
    }

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

    public func writeTextInt64MapNoEscape(prefix: String, values: HashMap<String, Int64>, totalNameSize: Int64, totalValueSize: Int64): Unit {
        reserveCapacity(prefix.size + totalNameSize + totalValueSize + values.size * 4 + 2)
        writeText(prefix)
        writeRawByte(b'{')
        var first = true
        for ((key, item) in values) {
            if (first) {
                first = false
            } else {
                writeRawByte(b',')
            }
            writeStringLiteralNoEscapeName(key)
            writeInt64Text(item)
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
        used = 0
    }

    private func ensureBufferedCapacity(additional: Int64): Unit {
        if (used + additional > buffer.size) {
            flushBuffer()
        }
    }

    private func writeRawByte(value: Byte): Unit {
        ensureBufferedCapacity(1)
        buffer[used] = value
        used++
        if (used == buffer.size) {
            flushBuffer()
        }
    }

    private func writeUInt64Digits(value: UInt64): Unit {
        if (value == 0u64) {
            writeRawByte(b'0')
            return
        }
        if (value < 10u64) {
            writeRawByte(UInt8(48u64 + value))
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
        flushBuffer()
        out.flush()
    }

}

private class JsonDirectWriteContext {
    public let objectContext: Bool
    public var first: Bool = true
    public var expectingFieldValue: Bool = false

    public init(objectContext: Bool) {
        this.objectContext = objectContext
    }
}

public class JsonDirectWriter {
    private let target: JsonDirectWriterTarget
    private let config: JsonWriteConfig
    private let multiline: Bool
    private let contexts = ArrayList<JsonDirectWriteContext>()

    public init(pretty!: Bool = false) {
        let writerConfig = if (pretty) { JsonWriteConfig.pretty } else { JsonWriteConfig.compact }
        target = DirectStringWriterTarget(capacity: directStringWriterInitialCapacity(writerConfig))
        config = writerConfig
        multiline = !config.newline.isEmpty()
    }

    public init(config: JsonWriteConfig) {
        target = DirectStringWriterTarget(capacity: directStringWriterInitialCapacity(config))
        this.config = config
        multiline = !config.newline.isEmpty()
    }

    public init(out: OutputStream, config!: JsonWriteConfig = JsonWriteConfig.compact) {
        target = DirectStreamWriterTarget(out)
        this.config = config
        multiline = !config.newline.isEmpty()
    }

    private init(target: JsonDirectWriterTarget, config: JsonWriteConfig) {
        this.target = target
        this.config = config
        multiline = !config.newline.isEmpty()
    }

    public static func bytes(config!: JsonWriteConfig = JsonWriteConfig.compact): JsonDirectWriter {
        JsonDirectWriter(DirectBytesWriterTarget(), config)
    }

    public func finish(): Unit {
        target.finish()
    }

    public func finishString(): String {
        target.finish()
        match (target) {
            case stringTarget: DirectStringWriterTarget => stringTarget.build()
            case _ => throw JsonException("JsonDirectWriter is not a string writer")
        }
    }

    public func finishBytes(): Array<Byte> {
        target.finish()
        match (target) {
            case bytesTarget: DirectBytesWriterTarget => bytesTarget.build()
            case _ => throw JsonException("JsonDirectWriter is not a bytes writer")
        }
    }

    func canWriteRawCompactValue(): Bool {
        contexts.isEmpty() && !multiline && !config.useSpaceAfterSeparators && !config.htmlSafe
    }

    func canWriteRawDefaultPrettyValue(): Bool {
        contexts.isEmpty() &&
            config.newline == "\n" &&
            config.indent == "    " &&
            config.useSpaceAfterSeparators &&
            !config.htmlSafe
    }

    func writeRawText(value: String): Unit {
        target.writeText(value)
    }

    func writeRawByte(value: Byte): Unit {
        target.writeByte(value)
    }

    func writeRawBeginArray(): Unit {
        target.writeByte(b'[')
    }

    func writeRawEndArray(): Unit {
        target.writeByte(b']')
    }

    func writeRawBeginObject(): Unit {
        target.writeByte(b'{')
    }

    func writeRawEndObject(): Unit {
        target.writeByte(b'}')
    }

    func reserveRawCapacity(additional: Int64): Unit {
        target.reserveCapacity(additional)
    }

    func rawTargetForGenerated(): JsonDirectWriterTarget {
        target
    }

    func writeRawCommaIfNeeded(first: Bool): Unit {
        if (!first) {
            target.writeByte(b',')
        }
    }

    func writeRawObjectEntryName(first: Bool, value: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(value)
        false
    }

    func writeRawObjectEntryNameString(first: Bool, name: String, value: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeStringLiteralName(name)
        writeRawString(value)
        false
    }

    func writeRawObjectEntryNameInt64(first: Bool, name: String, value: Int64): Bool {
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

    func writeRawObjectEntryNameBool(first: Bool, name: String, value: Bool): Bool {
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

    func writeRawStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit {
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
        var totalNameSize: Int64 = 0
        var totalValueSize: Int64 = 0
        for ((key, item) in values) {
            if (firstStringEscapeIndex(key) >= 0) {
                writeRawInt64MapFallback(prefix, values)
                return
            }
            totalNameSize += key.size
            totalValueSize += jsonRawInt64Size(item)
        }
        target.writeTextInt64MapNoEscape(prefix, values, totalNameSize, totalValueSize)
    }

    func writeRawInt64MapNoEscape(prefix: String, values: HashMap<String, Int64>, totalNameSize: Int64, totalValueSize: Int64): Unit {
        target.writeTextInt64MapNoEscape(prefix, values, totalNameSize, totalValueSize)
    }

    func tryWriteCompactInt64ArrayList(values: ArrayList<Int64>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        beforeValue()
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
        true
    }

    public func tryWriteCompactStringArrayList(values: ArrayList<String>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        beforeValue()
        writeRawStringArrayList("", values)
        true
    }

    public func tryWriteCompactInt64Map(values: HashMap<String, Int64>): Bool {
        if (multiline || config.useSpaceAfterSeparators || config.htmlSafe) {
            return false
        }
        beforeValue()
        writeRawInt64Map("", values)
        true
    }

    private func writeRawInt64MapFallback(prefix: String, values: HashMap<String, Int64>): Unit {
        target.writeText(prefix)
        target.writeByte(b'{')
        var first = true
        for ((key, item) in values) {
            first = writeRawObjectEntryNameInt64(first, key, item)
        }
        target.writeByte(b'}')
    }

    func writeRawDefaultPrettyStringArrayList(prefix: String, values: ArrayList<String>, itemDepth: Int64, closeDepth: Int64): Unit {
        target.writeText(prefix)
        if (values.size == 0) {
            target.writeText("[]")
            return
        }
        target.writeByte(b'[')
        writeRawDefaultPrettyNewlineIndent(itemDepth)
        writeRawString(values[0])
        for (index in 1..values.size) {
            target.writeByte(b',')
            writeRawDefaultPrettyNewlineIndent(itemDepth)
            writeRawString(values[index])
        }
        writeRawDefaultPrettyNewlineIndent(closeDepth)
        target.writeByte(b']')
    }

    func writeRawDefaultPrettyInt64Map(prefix: String, values: HashMap<String, Int64>, itemDepth: Int64, closeDepth: Int64): Unit {
        target.writeText(prefix)
        target.writeByte(b'{')
        var first = true
        for ((key, item) in values) {
            first = writeRawDefaultPrettyObjectEntryName(first, itemDepth, key)
            target.writeInt64Text(item)
        }
        if (!first) {
            writeRawDefaultPrettyNewlineIndent(closeDepth)
        }
        target.writeByte(b'}')
    }

    func writeRawFieldPrefix(first: Bool, firstPrefix: String, nextPrefix: String): Unit {
        if (first) {
            target.writeText(firstPrefix)
        } else {
            target.writeText(nextPrefix)
        }
    }

    func writeRawDefaultPrettyNewlineIndent(depth: Int64): Unit {
        target.writeNewlineAndIndent("\n", "    ", depth)
    }

    func writeRawDefaultPrettyAsciiFieldPrefix(first: Bool, depth: Int64, nameToken: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeRawDefaultPrettyNewlineIndent(depth)
        target.writeText(nameToken)
        false
    }

    func writeRawDefaultPrettyFieldPrefix(first: Bool, depth: Int64, name: String): Bool {
        if (!first) {
            target.writeByte(b',')
        }
        writeRawDefaultPrettyNewlineIndent(depth)
        writeStringLiteralName(name)
        target.writeText(" ")
        false
    }

    func writeRawDefaultPrettyObjectEntryName(first: Bool, depth: Int64, name: String): Bool {
        writeRawDefaultPrettyFieldPrefix(first, depth, name)
    }

    func writeRawString(value: String): Unit {
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeStringLiteralNoEscape(value)
            return
        }
        writeStringLiteralFromFirstEscape(value, firstEscape)
    }

    func canWriteRawStringNoEscape(value: String): Bool {
        firstStringEscapeIndex(value) < 0
    }

    func writeRawName(value: String): Unit {
        writeStringLiteralName(value)
    }

    func writeRawNull(): Unit {
        target.writeText("null")
    }

    func writeRawBool(value: Bool): Unit {
        target.writeBoolText(value)
    }

    func writeRawInt64(value: Int64): Unit {
        target.writeInt64Text(value)
    }

    func writeRawUInt64(value: UInt64): Unit {
        target.writeUInt64Text(value)
    }

    func writeRawNumberValue(value: String): Unit {
        target.writeText(value)
    }

    func writeRawTextString(prefix: String, value: String): Unit {
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeTextStringLiteralNoEscape(prefix, value)
            return
        }
        target.writeText(prefix)
        writeStringLiteralFromFirstEscape(value, firstEscape)
    }

    func writeRawTextStringNoEscape(prefix: String, value: String): Unit {
        target.writeTextStringLiteralNoEscape(prefix, value)
    }

    func writeRawTextStringText(prefix: String, value: String, suffix: String): Unit {
        let firstEscape = firstStringEscapeIndex(value)
        if (firstEscape < 0) {
            target.writeTextStringLiteralTextNoEscape(prefix, value, suffix)
            return
        }
        target.writeText(prefix)
        writeStringLiteralFromFirstEscape(value, firstEscape)
        target.writeText(suffix)
    }

    func writeRawTextBool(prefix: String, value: Bool): Unit {
        target.writeText(prefix)
        target.writeBoolText(value)
    }

    func writeRawTextInt64(prefix: String, value: Int64): Unit {
        target.writeText(prefix)
        target.writeInt64Text(value)
    }

    func writeRawTextUInt64(prefix: String, value: UInt64): Unit {
        target.writeText(prefix)
        target.writeUInt64Text(value)
    }

    func writeRawTextFloat64(prefix: String, value: Float64): Unit {
        ensureFiniteJsonFloat(value)
        target.writeText(prefix)
        target.writeFloat64Text(value)
    }

    func writeRawTextNumberValue(prefix: String, value: String): Unit {
        target.writeText(prefix)
        target.writeText(value)
    }

    func writeRawTextNull(prefix: String): Unit {
        target.writeText(prefix)
        target.writeText("null")
    }

    func writeRawTextNullText(prefix: String, suffix: String): Unit {
        target.writeText(prefix)
        target.writeText("null")
        target.writeText(suffix)
    }

    func writeRawTextInt64StringInt64Object(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64
    ): Unit {
        writeRawTextInt64StringInt64Text(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, "}")
    }

    func writeRawTextInt64StringInt64ObjectNoEscape(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64
    ): Unit {
        writeRawTextInt64StringInt64TextNoEscape(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, "}")
    }

    func writeRawTextInt64StringInt64Text(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        let firstEscape = firstStringEscapeIndex(stringValue)
        if (firstEscape < 0) {
            target.writeTextInt64StringLiteralInt64Text(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, suffix)
            return
        }
        target.writeText(prefix)
        target.writeInt64Text(firstValue)
        target.writeText(stringPrefix)
        writeStringLiteralFromFirstEscape(stringValue, firstEscape)
        target.writeText(intPrefix)
        target.writeInt64Text(intValue)
        target.writeText(suffix)
    }

    func writeRawTextInt64StringInt64TextNoEscape(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        target.writeTextInt64StringLiteralInt64Text(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, suffix)
    }

    func writeRawTextInt64StringInt64TextFromFirstEscape(
        prefix: String,
        firstValue: Int64,
        stringPrefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        firstEscape: Int64,
        suffix: String
    ): Unit {
        if (firstEscape < 0) {
            target.writeTextInt64StringLiteralInt64Text(prefix, firstValue, stringPrefix, stringValue, intPrefix, intValue, suffix)
            return
        }
        target.writeText(prefix)
        target.writeInt64Text(firstValue)
        target.writeText(stringPrefix)
        writeStringLiteralFromFirstEscape(stringValue, firstEscape)
        target.writeText(intPrefix)
        target.writeInt64Text(intValue)
        target.writeText(suffix)
    }

    func writeRawTextStringInt64Object(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64
    ): Unit {
        writeRawTextStringInt64Text(prefix, stringValue, intPrefix, intValue, "}")
    }

    func writeRawTextStringInt64ObjectNoEscape(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64
    ): Unit {
        writeRawTextStringInt64TextNoEscape(prefix, stringValue, intPrefix, intValue, "}")
    }

    func writeRawTextStringInt64Text(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        let firstEscape = firstStringEscapeIndex(stringValue)
        if (firstEscape < 0) {
            target.writeTextStringLiteralInt64Text(prefix, stringValue, intPrefix, intValue, suffix)
            return
        }
        target.writeText(prefix)
        writeStringLiteralFromFirstEscape(stringValue, firstEscape)
        target.writeText(intPrefix)
        target.writeInt64Text(intValue)
        target.writeText(suffix)
    }

    func writeRawTextStringInt64TextNoEscape(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        suffix: String
    ): Unit {
        target.writeTextStringLiteralInt64Text(prefix, stringValue, intPrefix, intValue, suffix)
    }

    func writeRawTextStringInt64TextFromFirstEscape(
        prefix: String,
        stringValue: String,
        intPrefix: String,
        intValue: Int64,
        firstEscape: Int64,
        suffix: String
    ): Unit {
        if (firstEscape < 0) {
            target.writeTextStringLiteralInt64Text(prefix, stringValue, intPrefix, intValue, suffix)
            return
        }
        target.writeText(prefix)
        writeStringLiteralFromFirstEscape(stringValue, firstEscape)
        target.writeText(intPrefix)
        target.writeInt64Text(intValue)
        target.writeText(suffix)
    }

    public func startObject(): Unit {
        beforeValue()
        target.writeByte(b'{')
        contexts.add(JsonDirectWriteContext(true))
    }

    public func endObject(): Unit {
        let context = popContext(true)
        if (!context.first && multiline) {
            writeNewlineAndIndent(contexts.size)
        }
        target.writeByte(b'}')
    }

    public func startArray(): Unit {
        beforeValue()
        target.writeByte(b'[')
        contexts.add(JsonDirectWriteContext(false))
    }

    public func endArray(): Unit {
        let context = popContext(false)
        if (!context.first && multiline) {
            writeNewlineAndIndent(contexts.size)
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

    func writeAsciiName(name: String): Unit {
        beforeName()
        target.writeStringLiteralNoEscapeName(name)
        if (config.useSpaceAfterSeparators) {
            target.writeText(" ")
        }
    }

    private func beforeName(): Unit {
        if (contexts.isEmpty()) {
            throw JsonException("Cannot write a field name outside object")
        }
        let context = contexts[contexts.size - 1]
        if (!context.objectContext || context.expectingFieldValue) {
            throw JsonException("Cannot write a field name here")
        }
        if (context.first) {
            writeEntryPrefix(contexts.size)
            context.first = false
        } else {
            target.writeByte(b',')
            writeEntryPrefix(contexts.size)
        }
        context.expectingFieldValue = true
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
        if (contexts.isEmpty()) {
            return
        }
        let context = contexts[contexts.size - 1]
        if (context.objectContext) {
            if (!context.expectingFieldValue) {
                throw JsonException("Object values must be preceded by a field name")
            }
            context.expectingFieldValue = false
            return
        }
        if (context.first) {
            writeEntryPrefix(contexts.size)
            context.first = false
            return
        }
        target.writeByte(b',')
        writeEntryPrefix(contexts.size)
    }

    private func popContext(expectedObject: Bool): JsonDirectWriteContext {
        if (contexts.isEmpty()) {
            throw JsonException("Unbalanced JSON writer state")
        }
        let index = contexts.size - 1
        let context = contexts[index]
        if (context.objectContext != expectedObject || context.expectingFieldValue) {
            throw JsonException("Unbalanced JSON writer state")
        }
        contexts.remove(at: index)
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
        target.writeEscapedStringLiteralFromFirstEscape(value, firstEscape, config.htmlSafe)
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
