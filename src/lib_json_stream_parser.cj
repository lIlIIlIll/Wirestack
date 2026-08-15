package yjson

import std.io.*

func parseJsonValueFromStream(
    input: InputStream,
    config!: JsonReadConfig = JsonReadConfig.defaults
): JsonValue {
    parseJsonValueFromInputStream(input, config: config)
}
