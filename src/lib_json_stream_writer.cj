package yjson

import std.io.*

/// Immutable options for serializing JSON.
public class JsonWriteOptions {
    public let indent: String
    public let htmlSafe: Bool
    public let maxOutputBytes: Int64
    public let maxDepth: Int64
    let newline: String
    let useSpaceAfterSeparators: Bool

    public init(
        indent!: String = "",
        htmlSafe!: Bool = false,
        maxOutputBytes!: Int64 = 0,
        maxDepth!: Int64 = 256
    ) {
        if (maxDepth <= 0) { throw IllegalArgumentException("maxDepth must be positive") }
        if (maxOutputBytes < 0) { throw IllegalArgumentException("maxOutputBytes must not be negative") }
        validateJsonIndent(indent)
        this.indent = indent
        this.htmlSafe = htmlSafe
        this.maxOutputBytes = maxOutputBytes
        this.maxDepth = maxDepth
        this.newline = if (indent.isEmpty()) { "" } else { "\n" }
        this.useSpaceAfterSeparators = !indent.isEmpty()
    }

    public static let defaults: JsonWriteOptions = JsonWriteOptions()
    public static let compact: JsonWriteOptions = JsonWriteOptions()

    public static func pretty(indent!: String = "  "): JsonWriteOptions {
        JsonWriteOptions(indent: indent)
    }

    public static let htmlSafePreset: JsonWriteOptions = JsonWriteOptions(htmlSafe: true)
}

private func validateJsonIndent(indent: String): Unit {
    for (value in indent.toRuneArray()) {
        if (value != r' ' && value != r'\t') {
            throw IllegalArgumentException("indent may contain only spaces or tabs")
        }
    }
}

func writeJsonValueToString(value: JsonNode, options: JsonWriteOptions): String {
    let writer = JsonDirectWriter(options)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finishString()
}

func writeJsonValueToStream(value: JsonNode, out: OutputStream, options: JsonWriteOptions): Unit {
    let writer = JsonDirectWriter(out, config: options)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finish()
}
