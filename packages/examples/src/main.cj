package yjson_examples

import yjson.*
import yjson_macros.*

@JsonCodec
class ExampleUser {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

main(): Unit {
    let userText = YJson.toJson(ExampleUser(7, "Alice"))
    let user = YJson.fromJson<ExampleUser>(userText)
    println("=== Generated typed codec ===")
    println(user.name)

    let literal = @Json({"ok": true, "user": $(user)})
    println("=== JSON literal ===")
    println(literal)

    let text = "{\"name\":\"Alice\",\"age\":30,\"tags\":[\"cangjie\",\"json\"]}"
    let limits = JsonReadConfig(limits: JsonReadLimits(
        maxDepth: 64, maxBytes: 1024 * 1024, maxStringBytes: 256 * 1024))
    let value = YJson.parse(text, config: limits)
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
