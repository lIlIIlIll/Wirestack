package yjson

import std.io.*

func parseJsonValueFromStream(
    input: InputStream,
    config!: JsonReadConfig = JsonReadConfig.defaults
): JsonNode {
    parseJsonValueFromInputStream(input, config: config)
}
