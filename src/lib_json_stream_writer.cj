package yjson

import std.io.*

/**
 * Immutable formatting and resource limits for JSON serialization.
 *
 * Compact output is the default. Pretty output uses a nonempty indentation string containing only spaces or tabs. A zero output-byte limit means unlimited; the depth limit must always be positive.
 */
public class JsonWriteOptions {
    /**
     * Indentation per nesting level; an empty string selects compact output.
     */
    public let indent: String
    /**
     * Whether HTML-sensitive characters receive additional escaping.
     */
    public let htmlSafe: Bool
    /**
     * Maximum output size in bytes; zero disables this limit.
     */
    public let maxOutputBytes: Int64
    /**
     * Maximum permitted nesting depth; must be positive.
     */
    public let maxDepth: Int64
    let newline: String
    let useSpaceAfterSeparators: Bool

    /**
     * Creates JsonWriteOptions with the supplied values.
     *
     * @param indent Indentation containing only spaces or tabs; empty means compact output.
     * @param htmlSafe Whether to apply the writer's HTML-sensitive character escaping.
     * @param maxOutputBytes Output byte limit; zero means unlimited and negative values are invalid.
     * @param maxDepth Positive nesting-depth limit; defaults to 256.
     * @throws IllegalArgumentException Depth is nonpositive, output size is negative, or indentation contains a character other than space or tab.
     */
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

    /**
     * Shared immutable default configuration.
     */
    public static let defaults: JsonWriteOptions = JsonWriteOptions()
    /**
     * Compact output preset with the default limits.
     */
    public static let compact: JsonWriteOptions = JsonWriteOptions()

    /**
     * Creates pretty-printing options with the supplied indentation.
     *
     * @param indent Indentation containing only spaces or tabs; empty means compact output.
     * @return Pretty-printing options with the other default limits.
     * @throws IllegalArgumentException Indentation contains a character other than space or tab.
     */
    public static func pretty(indent!: String = "  "): JsonWriteOptions {
        JsonWriteOptions(indent: indent)
    }

    /**
     * Compact output preset with HTML-sensitive character escaping enabled.
     */
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
    freezeYJsonRuntime()
    let writer = JsonDirectWriter(options)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finishString()
}

func writeJsonValueToStream(value: JsonNode, out: OutputStream, options: JsonWriteOptions): Unit {
    freezeYJsonRuntime()
    let writer = JsonDirectWriter(out, config: options)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finish()
}
