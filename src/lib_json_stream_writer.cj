package yjson

import std.io.*

public class JsonWriteLimits {
    public let maxDepth: Int64
    public let maxBytes: Int64

    public init(maxDepth!: Int64 = 256, maxBytes!: Int64 = 0) {
        if (maxDepth <= 0) { throw IllegalArgumentException("maxDepth must be positive") }
        if (maxBytes < 0) { throw IllegalArgumentException("maxBytes must not be negative") }
        this.maxDepth = maxDepth
        this.maxBytes = maxBytes
    }

    public static let defaults: JsonWriteLimits = JsonWriteLimits()
}

public class JsonWriteConfig {
    public let newline: String
    public let indent: String
    public let useSpaceAfterSeparators: Bool
    public let htmlSafe: Bool
    public let includeErrorLocation: Bool
    public let limits: JsonWriteLimits
    public let maxDepth: Int64
    public let maxBytes: Int64

    public init(
        newline: String,
        indent: String,
        useSpaceAfterSeparators: Bool,
        htmlSafe: Bool,
        includeErrorLocation!: Bool = true,
        limits!: JsonWriteLimits = JsonWriteLimits.defaults
    ) {
        this.newline = newline
        this.indent = indent
        this.useSpaceAfterSeparators = useSpaceAfterSeparators
        this.htmlSafe = htmlSafe
        this.includeErrorLocation = includeErrorLocation
        this.limits = limits
        this.maxDepth = limits.maxDepth
        this.maxBytes = limits.maxBytes
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

func writeJsonValueToString(value: JsonNode, config: JsonWriteConfig): String {
    let writer = JsonDirectWriter(config)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finishString()
}

func writeJsonValueToStream(value: JsonNode, out: OutputStream, config: JsonWriteConfig): Unit {
    let writer = JsonDirectWriter(out, config: config)
    writeJsonNodeToCodecWriter(writer, value)
    writer.finish()
}
