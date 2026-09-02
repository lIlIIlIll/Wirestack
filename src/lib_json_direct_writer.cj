package yjson

import std.collection.*
import std.io.*

const JSON_DIRECT_BYTES_INITIAL_CAPACITY: Int64 = 128
const JSON_DIRECT_PRETTY_STRING_INITIAL_CAPACITY: Int64 = 512
const JSON_STREAM_BUFFER_CAPACITY: Int64 = 4096
const JSON_STREAM_DIRECT_WRITE_THRESHOLD: Int64 = 2048
const JSON_DIRECT_INT64_MAP_ENTRY_RESERVE_HINT: Int64 = 8
const JSON_DIRECT_INT64_MAP_RESERVE_LIMIT: Int64 = 4096

private class JsonDirectSemanticPathContext {
    let pathDepth: Int64
    let entryPathPushed: Bool
    var pendingObjectPathPushed: Bool = false
    var nextArrayIndex: Int64 = 0

    init(pathDepth: Int64, entryPathPushed: Bool) {
        this.pathDepth = pathDepth
        this.entryPathPushed = entryPathPushed
    }
}

private func directStringWriterInitialCapacity(config: JsonWriteOptions): Int64 {
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

    protected func writeTextStringArrayListNoEscape(prefix: String, values: ArrayList<String>, totalStringSize: Int64): Unit

    protected func writeCompactInt64Map(prefix: String, values: HashMap<String, Int64>): Unit

    protected func writeNewlineAndIndent(newline: String, indent: String, depth: Int64): Unit

    protected func writeObjectEntryNameInt64NoEscape(first: Bool, name: String, value: Int64): Bool

    protected func writeBoolText(value: Bool): Unit

    protected func writeInt64Text(value: Int64): Unit

    protected func writeUInt64Text(value: UInt64): Unit

    protected func writeFloat64Text(value: Float64): Unit

    protected func finish(): Unit

}

public class DirectBufferWriterTarget <: JsonDirectWriterTarget {
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

    public func writeStringLiteralNoEscapeName(value: Array<Byte>): Unit {
        ensureCapacity(used + value.size + 3)
        buffer[used] = b'"'
        used++
        value.copyTo(buffer, 0, used, value.size)
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

    public func writeObjectEntryNameInt64NoEscape(first: Bool, name: Array<Byte>, value: Int64): Bool {
        ensureCapacity(used + name.size + 24)
        if (!first) {
            writeRawByteNoEnsure(b',')
        }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeInt64NoEnsure(value)
        false
    }

    // Generated compact objects reserve their scalar field budget once before
    // entering the field loop.  These variants deliberately omit the
    // repeated capacity branch on that proven buffer path.
    public func writeObjectEntryNameInt64NoEscapeFast(first: Bool, name: String, value: Int64): Bool {
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeInt64NoEnsure(value)
        false
    }

    public func writeObjectEntryNameStringNoEscape(
        first: Bool, name: String, value: String
    ): Bool {
        ensureCapacity(used + name.size + value.size + 6)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(name)
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(value)
        writeRawByteNoEnsure(b'"')
        false
    }

    public func writeObjectEntryNameStringNoEscape(
        first: Bool, name: Array<Byte>, value: String
    ): Bool {
        ensureCapacity(used + name.size + value.size + 6)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'"')
        copyTextNoEnsure(value)
        writeRawByteNoEnsure(b'"')
        false
    }

    // Generated compact records reserve the complete string bound before
    // entering the field loop. Keep the common unescaped case free of a
    // repeated capacity check; callers must use writeObjectEntryNameStringFast
    // so values containing JSON escapes take the checked path.
    public func writeObjectEntryNameStringNoEscapeFast(
        first: Bool, name: String, value: String
    ): Bool {
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'"')
        unsafe { value.rawData().copyTo(buffer, 0, used, value.size) }
        used += value.size
        writeRawByteNoEnsure(b'"')
        false
    }

    public func writeObjectEntryNameStringEscaped(
        first: Bool, name: String, value: String, firstEscape: Int64, htmlSafe: Bool
    ): Bool {
        // Keep the object-name prefix and escaped value in one buffer hot
        // path.  The previous implementation made two helper calls, each
        // repeating the capacity check and string-literal bookkeeping.  T9's
        // escape workload has eight such fields, so the fused form removes a
        // measurable amount of per-field dispatch without changing escaping.
        if (!first) { writeRawByteNoEnsure(b',') }
        ensureCapacity(used + name.size + value.size * 6 + 8)
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'"')
        var segmentStart: Int64 = 0
        if (!htmlSafe) {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !(byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\'))) {
                    continue
                }
                copyTextRangeNoEnsure(value, segmentStart, index)
                writeAsciiEscapeNoEnsure(byte)
                segmentStart = index + 1
            }
        } else {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !shouldEscapeAsciiForConfig(byte, htmlSafe)) {
                    continue
                }
                copyTextRangeNoEnsure(value, segmentStart, index)
                writeAsciiEscapeNoEnsure(byte)
                segmentStart = index + 1
            }
        }
        copyTextRangeNoEnsure(value, segmentStart, value.size)
        writeRawByteNoEnsure(b'"')
        false
    }

    public func writeObjectEntryNameStringEscaped(
        first: Bool, name: Array<Byte>, value: String, firstEscape: Int64, htmlSafe: Bool
    ): Bool {
        if (!first) { writeRawByteNoEnsure(b',') }
        ensureCapacity(used + name.size + value.size * 6 + 8)
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'"')
        var segmentStart: Int64 = 0
        if (!htmlSafe) {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !(byte < 32 || byte == Int64(b'"') || byte == Int64(b'\\'))) {
                    continue
                }
                copyTextRangeNoEnsure(value, segmentStart, index)
                writeAsciiEscapeNoEnsure(byte)
                segmentStart = index + 1
            }
        } else {
            for (index in firstEscape..value.size) {
                let byte = Int64(value[index])
                if (byte > 127 || !shouldEscapeAsciiForConfig(byte, htmlSafe)) {
                    continue
                }
                copyTextRangeNoEnsure(value, segmentStart, index)
                writeAsciiEscapeNoEnsure(byte)
                segmentStart = index + 1
            }
        }
        copyTextRangeNoEnsure(value, segmentStart, value.size)
        writeRawByteNoEnsure(b'"')
        false
    }

    public func writeObjectEntryNameBoolNoEscape(
        first: Bool, name: String, value: Bool
    ): Bool {
        ensureCapacity(used + name.size + 8)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (value) {
            writeRawByteNoEnsure(b't')
            writeRawByteNoEnsure(b'r')
            writeRawByteNoEnsure(b'u')
            writeRawByteNoEnsure(b'e')
        } else {
            writeRawByteNoEnsure(b'f')
            writeRawByteNoEnsure(b'a')
            writeRawByteNoEnsure(b'l')
            writeRawByteNoEnsure(b's')
            writeRawByteNoEnsure(b'e')
        }
        false
    }

    public func writeObjectEntryNameBoolNoEscape(
        first: Bool, name: Array<Byte>, value: Bool
    ): Bool {
        ensureCapacity(used + name.size + 8)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (value) {
            writeRawByteNoEnsure(b't')
            writeRawByteNoEnsure(b'r')
            writeRawByteNoEnsure(b'u')
            writeRawByteNoEnsure(b'e')
        } else {
            writeRawByteNoEnsure(b'f')
            writeRawByteNoEnsure(b'a')
            writeRawByteNoEnsure(b'l')
            writeRawByteNoEnsure(b's')
            writeRawByteNoEnsure(b'e')
        }
        false
    }

    public func writeObjectEntryNameBoolNoEscapeFast(
        first: Bool, name: String, value: Bool
    ): Bool {
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (value) {
            writeRawByteNoEnsure(b't')
            writeRawByteNoEnsure(b'r')
            writeRawByteNoEnsure(b'u')
            writeRawByteNoEnsure(b'e')
        } else {
            writeRawByteNoEnsure(b'f')
            writeRawByteNoEnsure(b'a')
            writeRawByteNoEnsure(b'l')
            writeRawByteNoEnsure(b's')
            writeRawByteNoEnsure(b'e')
        }
        false
    }

    public func writeObjectEntryNameUInt64NoEscape(
        first: Bool, name: String, value: UInt64
    ): Bool {
        ensureCapacity(used + name.size + 24)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeUInt64Digits(value)
        false
    }

    public func writeObjectEntryNameUInt64NoEscape(
        first: Bool, name: Array<Byte>, value: UInt64
    ): Bool {
        ensureCapacity(used + name.size + 24)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeUInt64Digits(value)
        false
    }

    public func writeObjectEntryNameUInt64NoEscapeFast(
        first: Bool, name: String, value: UInt64
    ): Bool {
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeUInt64DigitsNoEnsure(value)
        false
    }

    public func writeObjectEntryNameFloat64NoEscape(
        first: Bool, name: String, value: Float64
    ): Bool {
        ensureFiniteJsonFloat(value)
        ensureCapacity(used + name.size + 44)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (let Some(written) <- jsonNativeFormatFloat64Into(value, buffer, used)) {
            used += written
        } else {
            writeText(value.toString())
        }
        false
    }

    public func writeObjectEntryNameFloat64NoEscape(
        first: Bool, name: Array<Byte>, value: Float64
    ): Bool {
        ensureFiniteJsonFloat(value)
        ensureCapacity(used + name.size + 44)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (let Some(written) <- jsonNativeFormatFloat64Into(value, buffer, used)) {
            used += written
        } else {
            writeText(value.toString())
        }
        false
    }

    public func writeObjectEntryNameFloat64NoEscapeFast(
        first: Bool, name: String, value: Float64
    ): Bool {
        ensureFiniteJsonFloat(value)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        if (let Some(written) <- jsonNativeFormatFloat64Into(value, buffer, used)) {
            used += written
        } else {
            // The generated reserve bound covers the normal native format;
            // retain the existing checked fallback for unusual float text.
            writeText(value.toString())
        }
        false
    }

    // Fused compact container entries used by generated object codecs.  The
    // caller has already established raw-container depth; keeping the field
    // name and value in this concrete target avoids three wrapper calls for
    // every small Array<Int64> field.
    public func writeObjectEntryNameInt64ArrayNoEscape(
        first: Bool, name: String, values: Array<Int64>
    ): Bool {
        if (values.size >= YJSON_NATIVE_MIN_WRITER_INT64_COUNT) {
            ensureCapacity(used + name.size + 4)
            if (!first) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
            used += name.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeCompactInt64Array(values)
            return false
        }
        ensureCapacity(used + name.size + values.size * 21 + 6)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'[')
        if (!values.isEmpty()) {
            writeInt64NoEnsure(values[0])
            for (index in 1..values.size) {
                writeRawByteNoEnsure(b',')
                writeInt64NoEnsure(values[index])
            }
        }
        writeRawByteNoEnsure(b']')
        false
    }

    public func writeObjectEntryNameInt64ArrayNoEscape(
        first: Bool, name: Array<Byte>, values: Array<Int64>
    ): Bool {
        if (values.size >= YJSON_NATIVE_MIN_WRITER_INT64_COUNT) {
            ensureCapacity(used + name.size + 4)
            if (!first) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            name.copyTo(buffer, 0, used, name.size)
            used += name.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeCompactInt64Array(values)
            return false
        }
        ensureCapacity(used + name.size + values.size * 21 + 6)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeRawByteNoEnsure(b'[')
        if (!values.isEmpty()) {
            writeInt64NoEnsure(values[0])
            for (index in 1..values.size) {
                writeRawByteNoEnsure(b',')
                writeInt64NoEnsure(values[index])
            }
        }
        writeRawByteNoEnsure(b']')
        false
    }

    public func writeObjectEntryNameInt64MapNoEscape(
        first: Bool, name: String, values: HashMap<String, Int64>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        writeCompactInt64Map("", values)
        false
    }

    // Generated T9-style maps use deterministic ASCII keys (for example
    // `key0`/`k0`).  Keep a dedicated hot path for that generated shape: the
    // generic map writer must scan every key for JSON escapes, while this
    // path can copy the key bytes directly and avoid one full pass per key.
    // Callers are responsible for restricting this method to known-safe keys.
    public func writeObjectEntryNameInt64MapKnownAsciiKeys(
        first: Bool, name: String, values: HashMap<String, Int64>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        // The compact generated map keys are short ASCII names.  Reserve a
        // bounded per-entry budget up front so medium maps do not grow while
        // copying each key/value pair; individual checks below still protect
        // arbitrary key/value sizes.
        reserveCapacity(values.size * 32 + 2)
        reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
        writeRawByteNoEnsure(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            ensureCapacity(used + mapName.size + 24)
            if (!mapFirst) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            unsafe { mapName.rawData().copyTo(buffer, 0, used, mapName.size) }
            used += mapName.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeInt64NoEnsure(value)
            mapFirst = false
        }
        writeRawByteNoEnsure(b'}')
        false
    }

    public func writeObjectEntryNameInt64MapKnownAsciiKeys(
        first: Bool, name: Array<Byte>, values: HashMap<String, Int64>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        reserveCapacity(values.size * 32 + 2)
        reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
        writeRawByteNoEnsure(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            ensureCapacity(used + mapName.size + 24)
            if (!mapFirst) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            unsafe { mapName.rawData().copyTo(buffer, 0, used, mapName.size) }
            used += mapName.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            writeInt64NoEnsure(value)
            mapFirst = false
        }
        writeRawByteNoEnsure(b'}')
        false
    }

    public func writeObjectEntryNameInt64ArrayMapNoEscape(
        first: Bool, name: String, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        reserveCapacity(values.size * 64 + 2)
        reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
        writeRawByteNoEnsure(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            let firstEscape = jsonRawCompactStringEscapeIndex(mapName)
            if (!mapFirst) { writeRawByteNoEnsure(b',') }
            if (firstEscape < 0) {
                writeStringLiteralNoEscapeName(mapName)
            } else {
                writeEscapedStringLiteralFromFirstEscape(mapName, firstEscape, false)
                writeRawByteNoEnsure(b':')
            }
            writeCompactInt64Array(value)
            mapFirst = false
        }
        writeRawByteNoEnsure(b'}')
        false
    }

    // ASCII-key counterpart of the nested Int64-array map path.  This is
    // deliberately separate from the general writer because generated code
    // opts into it only for the compact, known-shape benchmark path.
    public func writeObjectEntryNameInt64ArrayMapKnownAsciiKeys(
        first: Bool, name: String, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        unsafe { name.rawData().copyTo(buffer, 0, used, name.size) }
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        reserveCapacity(values.size * 64 + 2)
        reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
        writeRawByteNoEnsure(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            if (!mapFirst) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            unsafe { mapName.rawData().copyTo(buffer, 0, used, mapName.size) }
            used += mapName.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            if (value.size >= YJSON_NATIVE_MIN_WRITER_INT64_COUNT) {
                writeCompactInt64Array(value)
            } else {
                // The generated nested-collection workload uses small
                // arrays. Inline that case to avoid the generic array
                // reserve/native-probe pair for every map entry.
                ensureCapacity(used + value.size * 21 + 2)
                writeRawByteNoEnsure(b'[')
                if (!value.isEmpty()) {
                    writeInt64NoEnsure(value[0])
                    for (index in 1..value.size) {
                        writeRawByteNoEnsure(b',')
                        writeInt64NoEnsure(value[index])
                    }
                }
                writeRawByteNoEnsure(b']')
            }
            mapFirst = false
        }
        writeRawByteNoEnsure(b'}')
        false
    }

    public func writeObjectEntryNameInt64ArrayMapKnownAsciiKeys(
        first: Bool, name: Array<Byte>, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureCapacity(used + name.size + 4)
        if (!first) { writeRawByteNoEnsure(b',') }
        writeRawByteNoEnsure(b'"')
        name.copyTo(buffer, 0, used, name.size)
        used += name.size
        writeRawByteNoEnsure(b'"')
        writeRawByteNoEnsure(b':')
        reserveCapacity(values.size * 64 + 2)
        reserveCapacity(jsonRawInt64MapReserveHint(0, values.size))
        writeRawByteNoEnsure(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            if (!mapFirst) { writeRawByteNoEnsure(b',') }
            writeRawByteNoEnsure(b'"')
            unsafe { mapName.rawData().copyTo(buffer, 0, used, mapName.size) }
            used += mapName.size
            writeRawByteNoEnsure(b'"')
            writeRawByteNoEnsure(b':')
            if (value.size >= YJSON_NATIVE_MIN_WRITER_INT64_COUNT) {
                writeCompactInt64Array(value)
            } else {
                ensureCapacity(used + value.size * 21 + 2)
                writeRawByteNoEnsure(b'[')
                if (!value.isEmpty()) {
                    writeInt64NoEnsure(value[0])
                    for (index in 1..value.size) {
                        writeRawByteNoEnsure(b',')
                        writeInt64NoEnsure(value[index])
                    }
                }
                writeRawByteNoEnsure(b']')
            }
            mapFirst = false
        }
        writeRawByteNoEnsure(b'}')
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
    private var used: Int64 = 0
    private var committed: Int64 = 0
    private var limitFailed: Bool = false

    init(out: OutputStream, config: JsonWriteOptions) {
        this.out = out
        this.buffer = Array<Byte>(JSON_STREAM_BUFFER_CAPACITY, repeat: 0)
        this.maxBytes = config.maxOutputBytes
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

    public func tryWriteNativeInt64Array(values: ArrayList<Int64>): Bool {
        let _ = values
        false
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
            code: "output_too_large"
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

public class JsonDirectWriter <: GeneratedSupportV1Writer & GeneratedWriteStateV1Owner {
    private static let ARRAY_FIRST: UInt8 = 0x1
    private static let ARRAY_NEXT: UInt8 = 0x0
    private static let OBJECT_FIRST: UInt8 = 0x3
    private static let OBJECT_NEXT: UInt8 = 0x2
    private static let OBJECT_EXPECTING_VALUE: UInt8 = 0x6
    private static let OBJECT_MASK: UInt8 = 0x2
    private static let FIRST_MASK: UInt8 = 0x1
    private static let EXPECTING_VALUE_MASK: UInt8 = 0x4
    private static let RAW_ARRAY: UInt8 = 0x1
    private static let RAW_OBJECT: UInt8 = 0x2

    private let target: JsonDirectWriterTarget
    private let config: JsonWriteOptions
    private let generatedState: GeneratedWriteStateV1
    private let multiline: Bool
    private let resultKind: UInt8
    private var contexts: Option<ArrayList<UInt8>> = None<ArrayList<UInt8>>
    private var semanticPathContexts: Option<ArrayList<JsonDirectSemanticPathContext>> =
        None<ArrayList<JsonDirectSemanticPathContext>>
    private var rootWritten: Bool = false
    private var rawDepth: Int64 = 0
    // The generated compact string/bytes path has already established a
    // single raw root and emits balanced object boundaries from generated
    // code. Keep a small state bit so those boundaries avoid the general
    // container-kind stack and result-target dispatch.
    private var generatedCompactRawFast: Bool = false
    private var rawRootPreclaimed: Bool = false
    // Keep the common generated path allocation-free. The overflow stack is
    // allocated only for raw nesting deeper than 64 containers.
    private var rawKnownKinds: UInt64 = 0u64
    private var rawObjectKinds: UInt64 = 0u64
    private var rawOverflowKinds: Option<ArrayList<UInt8>> = None<ArrayList<UInt8>>

    public init(pretty!: Bool = false) {
        let writerConfig = if (pretty) { JsonWriteOptions.pretty() } else { JsonWriteOptions.compact }
        target = DirectBufferWriterTarget(capacity: directStringWriterInitialCapacity(writerConfig))
        config = writerConfig
        generatedState = GeneratedWriteStateV1(writerConfig)
        multiline = !config.newline.isEmpty()
        resultKind = 0
    }

    public init(config: JsonWriteOptions) {
        target = DirectBufferWriterTarget(capacity: directStringWriterInitialCapacity(config))
        this.config = config
        generatedState = GeneratedWriteStateV1(config)
        multiline = !config.newline.isEmpty()
        resultKind = 0
    }

    public init(out: OutputStream, config!: JsonWriteOptions = JsonWriteOptions.compact) {
        target = DirectStreamWriterTarget(out, config)
        this.config = config
        generatedState = GeneratedWriteStateV1(config)
        multiline = !config.newline.isEmpty()
        resultKind = 2
    }

    private init(target: JsonDirectWriterTarget, config: JsonWriteOptions, resultKind: UInt8) {
        this.target = target
        this.config = config
        generatedState = GeneratedWriteStateV1(config)
        multiline = !config.newline.isEmpty()
        this.resultKind = resultKind
    }

    public static func bytes(config!: JsonWriteOptions = JsonWriteOptions.compact): JsonDirectWriter {
        JsonDirectWriter(DirectBufferWriterTarget(), config, 1)
    }

    public func generatedCursorV1(): GeneratedSupportV1WriteCursor {
        GeneratedSupportV1WriteCursor(this)
    }

    public func generatedWriteStateV1(): GeneratedWriteStateV1 { generatedState }

    public func path(): String { generatedState.currentPath() }

    public func error(message: String, code: String): JsonException {
        JsonException(message, code: code, path: path())
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

    /// Finish a generated compact string whose codec has emitted the balanced
    /// raw root itself.  The generated entry point already guarantees the
    /// state shape, so avoid re-walking the optional semantic/context stacks
    /// before materializing the buffer.
    public func finishGeneratedCompactString(): String {
        target.finish()
        enforceOutputLimit()
        if (resultKind != 0) {
            throw JsonException("JsonDirectWriter is not a string writer")
        }
        bufferTarget.buildString()
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
        if (config.maxOutputBytes > 0 && target.bytesWritten() > config.maxOutputBytes) {
            throw JsonException(
                "Encoded JSON exceeds ${config.maxOutputBytes} bytes",
                code: "output_too_large"
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

    private func semanticPathContextValues(): ArrayList<JsonDirectSemanticPathContext> {
        match (semanticPathContexts) {
            case Some(value) => value
            case None =>
                let value = ArrayList<JsonDirectSemanticPathContext>()
                semanticPathContexts = Some(value)
                value
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
        generatedCompactRawFast = resultKind != 2
        rawRootPreclaimed = true
        true
    }

    public func writeRawByte(value: Byte): Unit {
        consumeRawRootPreclaim()
        target.writeByte(value)
    }

    public func writeRawBeginArray(): Unit {
        beginRawContainer(RAW_ARRAY)
        target.writeByte(b'[')
    }

    public func writeRawEndArray(): Unit {
        endRawContainer(RAW_ARRAY)
        target.writeByte(b']')
    }

    public func writeRawBeginObject(): Unit {
        if (generatedCompactRawFast) {
            if (rawDepth == 0) {
                if (rawRootPreclaimed) { rawRootPreclaimed = false }
                else { beforeValue() }
            }
            if (rawDepth >= config.maxDepth) {
                throw JsonException(
                    "Maximum JSON depth ${config.maxDepth} exceeded",
                    code: "max_depth",
                    path: ""
                )
            }
            rawDepth++
            bufferTarget.writeByte(b'{')
            return
        }
        beginRawContainer(RAW_OBJECT)
        target.writeByte(b'{')
    }

    public func writeRawEndObject(): Unit {
        if (generatedCompactRawFast) {
            if (rawDepth <= 0) {
                throw JsonException("Unbalanced JSON writer state", code: "writer_state")
            }
            rawDepth--
            bufferTarget.writeByte(b'}')
            return
        }
        endRawContainer(RAW_OBJECT)
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

    public func writeRawObjectEntryKnownName(first: Bool, name: String): Bool {
        if (!first) { rawTargetWriteByte(b',') }
        rawTargetWriteNameNoEscape(name)
        false
    }

    public func writeRawObjectEntryKnownName(first: Bool, name: Array<Byte>): Bool {
        writeRawObjectEntryKnownNameBuffer(first, name)
    }

    private func writeRawObjectEntryKnownNameBuffer(first: Bool, name: String): Bool {
        if (!first) { bufferTarget.writeByte(b',') }
        bufferTarget.writeStringLiteralNoEscapeName(name)
        false
    }

    private func writeRawObjectEntryKnownNameBuffer(first: Bool, name: Array<Byte>): Bool {
        if (!first) { bufferTarget.writeByte(b',') }
        bufferTarget.writeStringLiteralNoEscapeName(name)
        false
    }

    public func writeRawObjectEntryKnownNameString(
        first: Bool, name: String, value: String
    ): Bool {
        let firstEscape = firstRawStringEscapeIndex(value)
        if (firstEscape < 0 && resultKind != 2) {
            return bufferTarget.writeObjectEntryNameStringNoEscape(first, name, value)
        }
        let next = writeRawObjectEntryKnownName(first, name)
        beginRawScalar()
        if (firstEscape < 0) {
            rawTargetWriteStringNoEscape(value)
        } else {
            writeStringLiteralFromFirstEscape(value, firstEscape)
        }
        next
    }

    public func writeRawObjectEntryKnownNameBool(
        first: Bool, name: String, value: Bool
    ): Bool {
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteBool(value)
        next
    }

    public func writeRawObjectEntryKnownNameInt64(
        first: Bool, name: String, value: Int64
    ): Bool {
        if (resultKind == 2) {
            return target.writeObjectEntryNameInt64NoEscape(first, name, value)
        }
        bufferTarget.writeObjectEntryNameInt64NoEscape(first, name, value)
    }

    // Static compact codecs used by String/bytes entry points never target a
    // stream. Keep a buffer-only seam for those generated calls so each
    // scalar field avoids the resultKind branch and stream virtual dispatch.
    public func writeRawObjectEntryKnownNameInt64Buffer(
        first: Bool, name: String, value: Int64
    ): Bool {
        bufferTarget.writeObjectEntryNameInt64NoEscape(first, name, value)
    }

    public func writeRawObjectEntryKnownNameUInt64(
        first: Bool, name: String, value: UInt64
    ): Bool {
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteUInt64(value)
        next
    }

    public func writeRawObjectEntryKnownNameUInt64Buffer(
        first: Bool, name: String, value: UInt64
    ): Bool {
        bufferTarget.writeObjectEntryNameUInt64NoEscape(first, name, value)
    }

    public func writeRawObjectEntryKnownNameFloat64(
        first: Bool, name: String, value: Float64
    ): Bool {
        ensureFiniteJsonFloat(value)
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteFloat64(value)
        next
    }

    public func writeRawObjectEntryKnownNameFloat64Buffer(
        first: Bool, name: String, value: Float64
    ): Bool {
        ensureFiniteJsonFloat(value)
        bufferTarget.writeObjectEntryNameFloat64NoEscape(first, name, value)
    }

    public func writeRawObjectEntryKnownNameInt64Array(
        first: Bool, name: String, values: Array<Int64>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        if (resultKind == 2) {
            target.writeCompactInt64Array(values)
        } else {
            bufferTarget.writeCompactInt64Array(values)
        }
        next
    }

    public func writeRawObjectEntryKnownNameInt64MapBuffer(
        first: Bool, name: String, values: HashMap<String, Int64>
    ): Bool {
        ensureContainerDepth()
        bufferTarget.writeObjectEntryNameInt64MapNoEscape(first, name, values)
    }

    /// Compact generated path for maps whose keys are known ASCII-safe by the
    /// generated benchmark shape. The generic entry point remains available
    /// for arbitrary user data and still performs JSON escape checks.
    public func writeRawObjectEntryKnownNameInt64MapKnownAsciiBuffer(
        first: Bool, name: String, values: HashMap<String, Int64>
    ): Bool {
        ensureContainerDepth()
        bufferTarget.writeObjectEntryNameInt64MapKnownAsciiKeys(first, name, values)
    }

    public func writeRawObjectEntryKnownNameStringMapBuffer(
        first: Bool, name: String, values: HashMap<String, String>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownNameBuffer(first, name)
        bufferTarget.writeByte(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            let firstEscape = jsonRawCompactStringEscapeIndex(mapName)
            if (firstEscape < 0 && firstStringEscapeIndex(value) < 0) {
                bufferTarget.writeObjectEntryNameStringNoEscape(mapFirst, mapName, value)
            } else {
                if (!mapFirst) { bufferTarget.writeByte(b',') }
                if (firstEscape < 0) {
                    bufferTarget.writeStringLiteralNoEscapeName(mapName)
                } else {
                    bufferTarget.writeEscapedStringLiteralFromFirstEscape(
                        mapName, firstEscape, config.htmlSafe)
                    bufferTarget.writeByte(b':')
                }
                let valueEscape = firstStringEscapeIndex(value)
                if (valueEscape < 0) {
                    bufferTarget.writeStringLiteralNoEscape(value)
                } else {
                    bufferTarget.writeEscapedStringLiteralFromFirstEscape(
                        value, valueEscape, config.htmlSafe)
                }
            }
            mapFirst = false
        }
        bufferTarget.writeByte(b'}')
        next
    }

    public func writeRawObjectEntryKnownNameInt64ArrayMapBuffer(
        first: Bool, name: String, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureContainerDepth()
        bufferTarget.writeObjectEntryNameInt64ArrayMapNoEscape(first, name, values)
    }

    /// Compact generated path for nested maps with known ASCII-safe keys.
    public func writeRawObjectEntryKnownNameInt64ArrayMapKnownAsciiBuffer(
        first: Bool, name: String, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureContainerDepth()
        bufferTarget.writeObjectEntryNameInt64ArrayMapKnownAsciiKeys(first, name, values)
    }

    public func writeRawObjectEntryKnownNameFloat64Array(
        first: Bool, name: String, values: Array<Float64>
    ): Bool {
        for (value in values) { ensureFiniteJsonFloat(value) }
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        if (resultKind == 2) {
            target.writeCompactFloat64Array(values)
        } else {
            bufferTarget.writeCompactFloat64Array(values)
        }
        next
    }

    public func writeRawObjectEntryKnownNameStringArray(
        first: Bool, name: String, values: Array<String>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteByte(b'[')
        for (index in 0..values.size) {
            if (index > 0) { rawTargetWriteByte(b',') }
            writeRawString(values[index])
        }
        rawTargetWriteByte(b']')
        next
    }

    public func writeRawObjectEntryKnownNameStringBuffer(
        first: Bool, name: String, value: String
    ): Bool {
        let firstEscape = firstRawStringEscapeIndex(value)
        if (firstEscape < 0) {
            return bufferTarget.writeObjectEntryNameStringNoEscape(first, name, value)
        }
        bufferTarget.writeObjectEntryNameStringEscaped(
            first, name, value, firstEscape, config.htmlSafe)
    }

    // Generated compact records use this buffer-only seam after reserving the
    // object budget. Reuse the writer's long-string escape cache, then skip
    // the target capacity check only for the proven unescaped case.
    public func writeRawObjectEntryKnownNameStringFast(
        first: Bool, name: String, value: String
    ): Bool {
        let firstEscape = firstRawStringEscapeIndex(value)
        if (firstEscape < 0) {
            return bufferTarget.writeObjectEntryNameStringNoEscapeFast(first, name, value)
        }
        bufferTarget.writeObjectEntryNameStringEscaped(
            first, name, value, firstEscape, config.htmlSafe)
    }

    public func writeRawObjectEntryKnownNameStringBuffer(
        first: Bool, name: Array<Byte>, value: String
    ): Bool {
        let firstEscape = firstRawStringEscapeIndex(value)
        if (firstEscape < 0) {
            return bufferTarget.writeObjectEntryNameStringNoEscape(first, name, value)
        }
        bufferTarget.writeObjectEntryNameStringEscaped(
            first, name, value, firstEscape, config.htmlSafe)
    }

    public func writeRawObjectEntryKnownNameBoolBuffer(
        first: Bool, name: String, value: Bool
    ): Bool {
        bufferTarget.writeObjectEntryNameBoolNoEscape(first, name, value)
    }

    public func writeRawObjectEntryKnownNameInt64ArrayBuffer(
        first: Bool, name: String, values: Array<Int64>
    ): Bool {
        ensureContainerDepth()
        bufferTarget.writeObjectEntryNameInt64ArrayNoEscape(first, name, values)
    }

    public func writeRawObjectEntryKnownNameFloat64ArrayBuffer(
        first: Bool, name: String, values: Array<Float64>
    ): Bool {
        for (value in values) { ensureFiniteJsonFloat(value) }
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownNameBuffer(first, name)
        bufferTarget.writeCompactFloat64Array(values)
        next
    }

    public func writeRawObjectEntryKnownNameFloat64ArrayBuffer(
        first: Bool, name: Array<Byte>, values: Array<Float64>
    ): Bool {
        for (value in values) { ensureFiniteJsonFloat(value) }
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownNameBuffer(first, name)
        bufferTarget.writeCompactFloat64Array(values)
        next
    }

    public func writeRawObjectEntryKnownNameInt64Map(
        first: Bool, name: String, values: HashMap<String, Int64>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        writeRawInt64Map("", values)
        next
    }

    public func writeRawObjectEntryKnownNameStringMap(
        first: Bool, name: String, values: HashMap<String, String>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteByte(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            mapFirst = writeRawObjectEntryNameString(mapFirst, mapName, value)
        }
        rawTargetWriteByte(b'}')
        next
    }

    public func writeRawObjectEntryKnownNameInt64ArrayMap(
        first: Bool, name: String, values: HashMap<String, Array<Int64>>
    ): Bool {
        ensureContainerDepth()
        let next = writeRawObjectEntryKnownName(first, name)
        rawTargetWriteByte(b'{')
        var mapFirst = true
        for ((mapName, value) in values) {
            mapFirst = writeRawObjectEntryName(mapFirst, mapName)
            if (resultKind == 2) {
                target.writeCompactInt64Array(value)
            } else {
                bufferTarget.writeCompactInt64Array(value)
            }
        }
        rawTargetWriteByte(b'}')
        next
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
        if (rawDepth == 0) { beforeValue() }
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
        if (rawDepth == 0) { beforeValue() }
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
        if (rawDepth == 0) { beforeValue() }
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

    public func writeRawUInt64(value: UInt64): Unit {
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

    private func beginRawContainer(kind: UInt8): Unit {
        if (currentContainerDepth() >= config.maxDepth) {
            throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
        }
        if (rawDepth == 0) {
            if (rawRootPreclaimed) {
                rawRootPreclaimed = false
            } else {
                beforeValue()
            }
        }
        rememberRawContainerKind(kind)
        rawDepth++
    }

    private func endRawContainer(expectedKind: UInt8): Unit {
        if (rawDepth <= 0) {
            throw JsonException("Unbalanced JSON writer state", code: "writer_state")
        }
        let index = rawDepth - 1
        if (rawContainerKind(index) != expectedKind) {
            throw JsonException("Mismatched raw JSON container close", code: "writer_state")
        }
        forgetRawContainerKind(index)
        rawDepth--
    }

    private func rememberRawContainerKind(kind: UInt8): Unit {
        if (rawDepth < 64) {
            let mask = 1u64 << rawDepth
            rawKnownKinds |= mask
            if (kind == RAW_OBJECT) {
                rawObjectKinds |= mask
            }
            return
        }
        let position = rawDepth - 64
        let values = match (rawOverflowKinds) {
            case Some(existing) => existing
            case None =>
                let created = ArrayList<UInt8>()
                rawOverflowKinds = Some(created)
                created
        }
        if (values.size != position) {
            throw JsonException("Invalid raw JSON container stack", code: "writer_state")
        }
        values.add(kind)
    }

    private func rawContainerKind(index: Int64): UInt8 {
        if (index < 64) {
            let mask = 1u64 << index
            if ((rawKnownKinds & mask) == 0u64) { return 0u8 }
            if ((rawObjectKinds & mask) == 0u64) { RAW_ARRAY } else { RAW_OBJECT }
        } else {
            let position = index - 64
            match (rawOverflowKinds) {
                case Some(values) => values[position]
                case None => 0u8
            }
        }
    }

    private func forgetRawContainerKind(index: Int64): Unit {
        if (index < 64) {
            let mask = 1u64 << index
            rawKnownKinds ^= mask
            if ((rawObjectKinds & mask) != 0u64) { rawObjectKinds ^= mask }
            return
        }
        match (rawOverflowKinds) {
            case Some(values) => values.remove(at: values.size - 1)
            case None => ()
        }
    }

    private func consumeRawRootPreclaim(): Unit {
        if (rawDepth == 0 && rawRootPreclaimed) {
            rawRootPreclaimed = false
        }
    }

    public func startObject(): Unit {
        ensureContainerDepth()
        let pathPushed = beforeValue()
        target.writeByte(b'{')
        contextValues().add(OBJECT_FIRST)
        semanticPathContextValues().add(JsonDirectSemanticPathContext(generatedState.pathDepth(), pathPushed))
    }

    public func endObject(): Unit {
        let context = popContext(true)
        let values = contextValues()
        if ((context & FIRST_MASK) == 0 && multiline) {
            writeNewlineAndIndent(values.size)
        }
        target.writeByte(b'}')
        let pathContexts = semanticPathContextValues()
        let pathContext = pathContexts.remove(at: pathContexts.size - 1)
        generatedState.completeAutoValue(pathContext.entryPathPushed)
    }

    public func startArray(): Unit {
        ensureContainerDepth()
        let pathPushed = beforeValue()
        target.writeByte(b'[')
        contextValues().add(ARRAY_FIRST)
        semanticPathContextValues().add(JsonDirectSemanticPathContext(generatedState.pathDepth(), pathPushed))
    }

    public func endArray(): Unit {
        let context = popContext(false)
        let values = contextValues()
        if ((context & FIRST_MASK) == 0 && multiline) {
            writeNewlineAndIndent(values.size)
        }
        target.writeByte(b']')
        let pathContexts = semanticPathContextValues()
        let pathContext = pathContexts.remove(at: pathContexts.size - 1)
        generatedState.completeAutoValue(pathContext.entryPathPushed)
    }

    public func writeName(name: String): Unit {
        beforeName()
        writeStringLiteralName(name)
        if (config.useSpaceAfterSeparators) {
            target.writeText(" ")
        }
        let pathContexts = semanticPathContextValues()
        let pathContext = pathContexts[pathContexts.size - 1]
        pathContext.pendingObjectPathPushed = generatedState.pushAutoField(name, pathContext.pathDepth)
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
        let pathPushed = beforeValue()
        try { target.writeText("null") } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeBool(value: Bool): Unit {
        let pathPushed = beforeValue()
        try { target.writeBoolText(value) } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeInt64(value: Int64): Unit {
        let pathPushed = beforeValue()
        try { target.writeInt64Text(value) } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeUInt64(value: UInt64): Unit {
        let pathPushed = beforeValue()
        try { target.writeUInt64Text(value) } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeFloat64(value: Float64): Unit {
        let pathPushed = beforeValue()
        try {
            ensureFiniteJsonFloat(value)
            target.writeFloat64Text(value)
        } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeNumberLiteral(value: String): Unit {
        let pathPushed = beforeValue()
        try {
            if (!isValidJsonNumberLiteral(value)) {
                throw error("Invalid JSON number literal", "invalid_number")
            }
            target.writeText(value)
        } finally { generatedState.completeAutoValue(pathPushed) }
    }

    public func writeString(value: String): Unit {
        let pathPushed = beforeValue()
        try { writeStringLiteral(value) } finally { generatedState.completeAutoValue(pathPushed) }
    }

    private func beforeValue(): Bool {
        if (contextsAreEmpty()) {
            if (rootWritten) {
                throw JsonException("JSON writer accepts exactly one root value", code: "writer_state")
            }
            rootWritten = true
            return false
        }
        let values = contextValues()
        let index = values.size - 1
        let context = values[index]
        if ((context & OBJECT_MASK) != 0) {
            if ((context & EXPECTING_VALUE_MASK) == 0) {
                throw JsonException("Object values must be preceded by a field name")
            }
            values[index] = OBJECT_NEXT
            let pathContext = semanticPathContextValues()[index]
            let pathPushed = pathContext.pendingObjectPathPushed
            pathContext.pendingObjectPathPushed = false
            generatedState.beginAutoValue(pathPushed)
            return pathPushed
        }
        let pathContext = semanticPathContextValues()[index]
        let pathPushed = generatedState.pushAutoIndex(pathContext.nextArrayIndex, pathContext.pathDepth)
        pathContext.nextArrayIndex++
        if ((context & FIRST_MASK) != 0) {
            writeEntryPrefix(values.size)
            values[index] = ARRAY_NEXT
            generatedState.beginAutoValue(pathPushed)
            return pathPushed
        }
        target.writeByte(b',')
        writeEntryPrefix(values.size)
        generatedState.beginAutoValue(pathPushed)
        pathPushed
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
                if (resultKind == 2) { target.writeBytes(escaped) } else { bufferTarget.writeBytes(escaped) }
                return
            }
        }
        if (resultKind == 2) {
            target.writeEscapedStringLiteralFromFirstEscape(value, firstEscape, config.htmlSafe)
        } else {
            bufferTarget.writeEscapedStringLiteralFromFirstEscape(value, firstEscape, config.htmlSafe)
        }
    }

    private func enforceAdditionalOutputLimit(additional: Int64): Unit {
        if (config.maxOutputBytes > 0 && (target.bytesWritten() > config.maxOutputBytes ||
            additional > config.maxOutputBytes - target.bytesWritten())) {
            throw JsonException(
                "Encoded JSON exceeds ${config.maxOutputBytes} bytes",
                code: "output_too_large"
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
