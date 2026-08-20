package yjson_examples

import yjson.*

main(): Unit {
    let text = "{\"name\":\"Alice\",\"age\":30,\"tags\":[\"cangjie\",\"json\"]}"
    let value = YJson.parse(text)
    let object = value.asObject()
    object.put("active", JsonBoolValue(true))

    println("=== JsonNode AST ===")
    println(YJson.stringifyPretty(object))

    let compact = YJson.parseCompact(unsafe { text.rawData() })
    println("=== Pure Cangjie Compact query ===")
    println(compact.root().get("name").getOrThrow().asString())

    let encoded = YJson.encodeStringWith(StringJson, "仓颉 JSON")
    let decoded = YJson.decodeStringWith(StringJson, encoded)
    println("=== Built-in codec roundtrip ===")
    println(decoded)
}
