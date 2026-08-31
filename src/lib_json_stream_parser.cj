package yjson

import std.io.*

func parseJsonValueFromStream(
    input: InputStream,
    config!: JsonReadOptions = JsonReadOptions.defaults
): JsonNode {
    parseJsonValueFromInputStream(input, config: config)
}
