package yjson

import std.io.*

const JSON_STREAM_BUFFER_CAPACITY: Int64 = 4096
const JSON_STREAM_DIRECT_WRITE_THRESHOLD: Int64 = 2048

public class JsonWriteConfig {
    public let newline: String
    public let indent: String
    public let useSpaceAfterSeparators: Bool
    public let htmlSafe: Bool
    public let includeErrorLocation: Bool
    public let maxDepth: Int64

    public init(
        newline: String,
        indent: String,
        useSpaceAfterSeparators: Bool,
        htmlSafe: Bool,
        includeErrorLocation!: Bool = true,
        maxDepth!: Int64 = 256
    ) {
        if (maxDepth <= 0) {
            throw IllegalArgumentException("maxDepth must be positive")
        }
        this.newline = newline
        this.indent = indent
        this.useSpaceAfterSeparators = useSpaceAfterSeparators
        this.htmlSafe = htmlSafe
        this.includeErrorLocation = includeErrorLocation
        this.maxDepth = maxDepth
    }

    public static let compact: JsonWriteConfig = JsonWriteConfig(
        "",
        "",
        false,
        false
    )

    public static let pretty: JsonWriteConfig = JsonWriteConfig(
        "\n",
        "    ",
        true,
        false
    )
}

public class JsonCodecConfig {
    public let read: JsonReadConfig
    public let write: JsonWriteConfig

    public init(
        read!: JsonReadConfig = JsonReadConfig.defaults,
        write!: JsonWriteConfig = JsonWriteConfig.compact
    ) {
        this.read = read
        this.write = write
    }

    public static let compact: JsonCodecConfig = JsonCodecConfig()
    public static let pretty: JsonCodecConfig = JsonCodecConfig(write: JsonWriteConfig.pretty)
}

abstract class JsonWriterTarget {
    protected func writeText(value: String): Unit

    protected func writeTextRange(value: String, start: Int64, end: Int64): Unit

    protected func finish(): Unit
}

class StringJsonWriterTarget <: JsonWriterTarget {
    private let builder: StringBuilder

    public init() {
        builder = StringBuilder()
    }

    public func writeText(value: String): Unit {
        builder.append(value)
    }

    public func writeTextRange(value: String, start: Int64, end: Int64): Unit {
        if (end <= start) {
            return
        }
        builder.append(value[start..end])
    }

    public func finish(): Unit {}

    public func build(): String {
        builder.toString()
    }
}

class StreamJsonWriterTarget <: JsonWriterTarget {
    private let out: OutputStream
    private let buffer: Array<Byte>
    private var used: Int64

    public init(out: OutputStream) {
        this.out = out
        this.buffer = Array<Byte>(JSON_STREAM_BUFFER_CAPACITY, repeat: 0)
        this.used = 0
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
    }

    private func flushBuffer(): Unit {
        if (used == 0) {
            return
        }
        out.write(buffer[0..used])
        used = 0
    }

    public func finish(): Unit {
        flushBuffer()
        out.flush()
    }
}

class JsonValueStreamWriter {
    private let target: JsonWriterTarget
    private let config: JsonWriteConfig
    private let multiline: Bool

    public init(target: JsonWriterTarget, config: JsonWriteConfig) {
        this.target = target
        this.config = config
        this.multiline = !config.newline.isEmpty()
    }

    public func write(value: JsonNode): Unit {
        writeValue(value, 0)
        target.finish()
    }

    private func writeValue(value: JsonNode, depth: Int64): Unit {
        match (value) {
            case _: JsonNullValue => target.writeText("null")
            case boolValue: JsonBoolValue => target.writeText(boolValue.value.toString())
            case intValue: JsonIntValue => target.writeText(intValue.value.toString())
            case floatValue: JsonFloatValue =>
                ensureFiniteJsonFloat(floatValue.value)
                target.writeText(floatValue.value.toString())
            case numberValue: JsonNumberLiteralValue => target.writeText(numberValue.literal)
            case stringValue: JsonStringValue => writeStringValue(stringValue.value)
            case arrayValue: JsonArrayValue => writeArrayValue(arrayValue, depth)
            case objectValue: JsonObjectValue => writeObjectValue(objectValue, depth)
            case _ => throw JsonException("Unsupported JsonNode implementation")
        }
    }

    private func writeArrayValue(value: JsonArrayValue, depth: Int64): Unit {
        target.writeText("[")
        if (value.size() == 0) {
            target.writeText("]")
            return
        }
        var first = true
        for (item in value.values()) {
            if (first) {
                writeEntryPrefix(depth + 1)
            } else {
                writeEntrySeparator(depth + 1)
            }
            writeValue(item, depth + 1)
            first = false
        }
        writeClosingPrefix(depth)
        target.writeText("]")
    }

    private func writeObjectValue(value: JsonObjectValue, depth: Int64): Unit {
        target.writeText("{")
        if (value.size() == 0) {
            target.writeText("}")
            return
        }
        var first = true
        for ((key, item) in value.entries()) {
            if (first) {
                writeEntryPrefix(depth + 1)
            } else {
                writeEntrySeparator(depth + 1)
            }
            writeStringValue(key)
            target.writeText(":")
            if (config.useSpaceAfterSeparators) {
                target.writeText(" ")
            }
            writeValue(item, depth + 1)
            first = false
        }
        writeClosingPrefix(depth)
        target.writeText("}")
    }

    private func writeEntryPrefix(depth: Int64): Unit {
        if (multiline) {
            writeNewlineAndIndent(depth)
        }
    }

    private func writeEntrySeparator(depth: Int64): Unit {
        target.writeText(",")
        if (multiline) {
            writeNewlineAndIndent(depth)
            return
        }
        if (config.useSpaceAfterSeparators) {
            target.writeText(" ")
        }
    }

    private func writeClosingPrefix(depth: Int64): Unit {
        if (multiline) {
            writeNewlineAndIndent(depth)
        }
    }

    private func writeNewlineAndIndent(depth: Int64): Unit {
        target.writeText(config.newline)
        for (_ in 0..depth) {
            target.writeText(config.indent)
        }
    }

    private func writeStringValue(value: String): Unit {
        target.writeText("\"")
        var segmentStart = 0
        for (index in 0..value.size) {
            let byte = Int64(value[index])
            if (byte > 127) {
                continue
            }
            if (!shouldEscapeAscii(byte)) {
                continue
            }
            target.writeTextRange(value, segmentStart, index)
            writeAsciiEscape(byte)
            segmentStart = index + 1
        }
        target.writeTextRange(value, segmentStart, value.size)
        target.writeText("\"")
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

    private func writeAsciiEscape(byte: Int64): Unit {
        if (byte == Int64(b'"')) {
            target.writeText("\\\"")
            return
        }
        if (byte == Int64(b'\\')) {
            target.writeText("\\\\")
            return
        }
        if (byte == Int64(b'\b')) {
            target.writeText("\\b")
            return
        }
        if (byte == Int64(b'\f')) {
            target.writeText("\\f")
            return
        }
        if (byte == Int64(b'\n')) {
            target.writeText("\\n")
            return
        }
        if (byte == Int64(b'\r')) {
            target.writeText("\\r")
            return
        }
        if (byte == Int64(b'\t')) {
            target.writeText("\\t")
            return
        }
        target.writeText("\\u00")
        writeHexNibble(byte >> 4)
        writeHexNibble(byte & 0xF)
    }

    private func writeHexNibble(value: Int64): Unit {
        target.writeText(JSON_HEX[value..value + 1])
    }
}

func writeJsonValueToString(value: JsonNode, config: JsonWriteConfig): String {
    if (config.newline.isEmpty() && !config.useSpaceAfterSeparators && !config.htmlSafe) {
        let writer = JsonDirectWriter()
        writeJsonValueCompact(writer, value)
        return writer.finishString()
    }
    if (!config.newline.isEmpty() || (!config.useSpaceAfterSeparators && config.htmlSafe)) {
        let writer = JsonDirectWriter(config)
        writeJsonValueDirect(writer, value)
        return writer.finishString()
    }
    let target = StringJsonWriterTarget()
    JsonValueStreamWriter(target, config).write(value)
    target.build()
}

func writeJsonValueToStream(value: JsonNode, out: OutputStream, config: JsonWriteConfig): Unit {
    JsonValueStreamWriter(StreamJsonWriterTarget(out), config).write(value)
}
