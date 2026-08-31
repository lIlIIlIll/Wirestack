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

    let text = "{\"name\":\"Alice\",\"age\":30,\"tags\":[\"cangjie\",\"json\"]}"
    let limits = JsonReadOptions(maxDepth: 64, maxInputBytes: 1024 * 1024, maxStringBytes: 256 * 1024)
    let value = JsonNode.parse(text, config: limits)
    let object = value.asObject()
    object.put("active", JsonNode.boolean(true))

    println("=== JsonNode AST ===")
    println((object).toJson(options: JsonWriteOptions.pretty()))

    let encoded = YJson.toJson("仓颉 JSON", codec: JsonCodecs.string)
    let decoded = YJson.fromJson(encoded, codec: JsonCodecs.string)
    println("=== Built-in codec roundtrip ===")
    println(decoded)
}
