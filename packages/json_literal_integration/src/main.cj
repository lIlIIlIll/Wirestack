package yjson_json_literal_integration

import std.collection.*
import yjson.*
import yjson_macros.*

private func require(condition: Bool, message: String): Unit {
    if (!condition) {
        throw Exception(message)
    }
}

private func recordKey(order: ArrayList<String>, label: String, value: String): String {
    order.add(label)
    value
}

private func recordValue(order: ArrayList<String>, label: String, value: Int64): Int64 {
    order.add(label)
    value
}

private func requireOrder(order: ArrayList<String>): Unit {
    require(order.size == 4, "each interpolation must run exactly once")
    require(
        order[0] == "key-1" && order[1] == "value-1" && order[2] == "key-2" && order[3] == "value-2",
        "interpolations must run from left to right"
    )
}

@JsonCodec
class ExternalLiteralUser {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

main(): Unit {
    let dynamicKey = "user"
    let literalJson = @Json({
        "name": "Alice",
        "values": [1, true, null, 1.25e2,],
        $(dynamicKey): $(ExternalLiteralUser(8, "Bob")),
    })
    require(
        literalJson == "{\"name\":\"Alice\",\"values\":[1,true,null,1.25e2],\"user\":{\"id\":8,\"name\":\"Bob\"}}",
        "unexpected @Json output"
    )

    let stringOrder = ArrayList<String>()
    let lastWinsJson = @Json({
        $(recordKey(stringOrder, "key-1", "same")): $(recordValue(stringOrder, "value-1", 1)),
        $(recordKey(stringOrder, "key-2", "same")): $(recordValue(stringOrder, "value-2", 2)),
    })
    requireOrder(stringOrder)
    require(lastWinsJson == "{\"same\":2}", "@Json dynamic keys must use LastWins")

    let valueOrder = ArrayList<String>()
    let literalValue = @JsonValue({
        "name": "Alice",
        "values": [1, 2,],
        $(recordKey(valueOrder, "key-1", "same")): $(recordValue(valueOrder, "value-1", 1)),
        $(recordKey(valueOrder, "key-2", "same")): $(recordValue(valueOrder, "value-2", 2)),
    })
    requireOrder(valueOrder)
    require(literalValue["same"].int64 == 2, "@JsonValue dynamic keys must use LastWins")
    require(literalValue["name"].string == "Alice", "@JsonValue string access failed")
    require(literalValue["values"][1].int64 == 2, "@JsonValue chained indexing failed")

    literalValue["name"] = "Bob"
    literalValue["values"][0] = 7
    require(literalValue["name"].string == "Bob", "JsonNode object assignment failed")
    require(literalValue["values"][0].int64 == 7, "JsonNode array assignment failed")

    let fluent = YJson.object().put("enabled", true).put("items", YJson.array().add(1).add("two"))
    require(fluent["enabled"].bool, "fluent object builder failed")
    require(fluent["items"][1].string == "two", "fluent array builder failed")

    println("json literal integration checks passed")
}
