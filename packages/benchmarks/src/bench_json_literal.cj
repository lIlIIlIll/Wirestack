package yjson_benchmarks

import yjson.*
import yjson_macros.*
import std.unittest.*
import std.unittest.testmacro.*

@JsonCodec
class JsonLiteralPayload {
    public let id: Int64
    public let name: String
    public let active: Bool
    public let a: Int64
    public let b: Int64
    public let c: Int64
    public let d: Int64

    public init(id: Int64, name: String, active: Bool, a: Int64, b: Int64, c: Int64, d: Int64) {
        this.id = id
        this.name = name
        this.active = active
        this.a = a
        this.b = b
        this.c = c
        this.d = d
    }
}

@Test
@Configure[
    warmup: Duration.millisecond * 300,
    minDuration: Duration.second * 2,
    minBatches: 16
]
class JsonLiteralPerformance {
    let id: Int64 = 7
    let name = "Alice"
    let dynamicKey = "id"
    let payload = JsonLiteralPayload(7, "Alice", true, 1, 2, 3, 4)
    var stringSink = ""
    var nodeSink: JsonNode = JsonNullValue()

    init() {
        let expected = YJson.encodeStringWith(JsonLiteralPayloadJson, payload)
        if (buildJsonStatic() != expected || buildJsonDynamicKey() != expected || buildManualDirect() != expected) {
            throw Exception("JSON literal String benchmark paths do not produce the same output")
        }
        if (buildJsonValue().toString() != expected || buildManualConcreteAst().toString() != expected ||
            buildManualFluentAst().toString() != expected) {
            throw Exception("JSON literal AST benchmark paths do not produce the same output")
        }
    }

    private func buildJsonStatic(): String {
        @Json({
            "id": $(id), "name": $(name), "active": true,
            "a": 1, "b": 2, "c": 3, "d": 4,
        })
    }

    private func buildJsonDynamicKey(): String {
        @Json({
            $(dynamicKey): $(id), "name": $(name), "active": true,
            "a": 1, "b": 2, "c": 3, "d": 4,
        })
    }

    private func buildManualDirect(): String {
        let writer = JsonDirectWriter()
        writer.startObject()
        writer.writeName("id")
        writer.writeInt64(id)
        writer.writeName("name")
        writer.writeString(name)
        writer.writeName("active")
        writer.writeBool(true)
        writer.writeName("a")
        writer.writeInt64(1)
        writer.writeName("b")
        writer.writeInt64(2)
        writer.writeName("c")
        writer.writeInt64(3)
        writer.writeName("d")
        writer.writeInt64(4)
        writer.endObject()
        writer.finishString()
    }

    private func buildJsonValue(): JsonNode {
        @JsonValue({
            "id": $(id), "name": $(name), "active": true,
            "a": 1, "b": 2, "c": 3, "d": 4,
        })
    }

    private func buildManualConcreteAst(): JsonNode {
        JsonObjectValue()
            .put("id", YJson.value(id))
            .put("name", YJson.value(name))
            .put("active", JsonBoolValue(true))
            .put("a", JsonIntValue(1))
            .put("b", JsonIntValue(2))
            .put("c", JsonIntValue(3))
            .put("d", JsonIntValue(4))
    }

    private func buildManualFluentAst(): JsonNode {
        YJson.object().put("id", id).put("name", name).put("active", true).put("a", 1).put("b", 2).put("c", 3).put("d",
            4)
    }

    @Bench
    func jsonMacroStatic(): Unit {
        stringSink = buildJsonStatic()
    }

    @Bench
    func jsonMacroDynamicKey(): Unit {
        stringSink = buildJsonDynamicKey()
    }

    @Bench
    func generatedCodec(): Unit {
        stringSink = YJson.encodeStringWith(JsonLiteralPayloadJson, payload)
    }

    @Bench
    func manualDirectWriter(): Unit {
        stringSink = buildManualDirect()
    }

    @Bench
    func jsonValueMacroBuildOnly(): Unit {
        nodeSink = buildJsonValue()
    }

    @Bench
    func manualConcreteAstBuildOnly(): Unit {
        nodeSink = buildManualConcreteAst()
    }

    @Bench
    func manualFluentAstBuildOnly(): Unit {
        nodeSink = buildManualFluentAst()
    }

    @Bench
    func jsonValueMacroAndStringify(): Unit {
        nodeSink = buildJsonValue()
        stringSink = nodeSink.toString()
    }

    @Bench
    func manualConcreteAstAndStringify(): Unit {
        nodeSink = buildManualConcreteAst()
        stringSink = nodeSink.toString()
    }
}
