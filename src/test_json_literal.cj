package yjson

import yjson_macros.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private var jsonLiteralTrackedWrites: Int64 = 0

private class JsonLiteralTracked {
    let value: Int64

    init(value: Int64) {
        this.value = value
    }
}

private class JsonLiteralTrackedCodec <: JsonDirectCodec<JsonLiteralTracked> {
    public func write(
        value: JsonLiteralTracked,
        writer: JsonDirectWriter,
        context: JsonEncodeContext
    ): Unit {
        let _ = context
        jsonLiteralTrackedWrites++
        writer.writeInt64(value.value)
    }

    public func read(reader: JsonDirectReader, context: JsonDecodeContext): JsonLiteralTracked {
        let _ = context
        JsonLiteralTracked(reader.readInt64())
    }
}

private let JsonLiteralTrackedJson: JsonDirectCodec<JsonLiteralTracked> = JsonLiteralTrackedCodec()

extend JsonLiteralTracked <: JsonCodecProvider {
    public static func jsonCodec(): JsonAnyCodec {
        eraseJsonCodec(JsonLiteralTrackedJson)
    }
}

private func jsonLiteralRecordKey(order: ArrayList<String>, label: String, value: String): String {
    order.add(label)
    value
}

private func jsonLiteralRecordValue(order: ArrayList<String>, label: String, value: Int64): Int64 {
    order.add(label)
    value
}

private func jsonLiteralOrderIsLeftToRight(order: ArrayList<String>): Bool {
    order.size == 4 && order[0] == "key-1" && order[1] == "value-1" && order[2] == "key-2" && order[3] == "value-2"
}

@Test
class JsonLiteralSyntaxTest {
    @TestCase
    func jsonBuildsCompactStringWithNestedLiteralsAndInterpolation(): Unit {
        let name = "Alice"
        let score: Int64 = 7
        let actual = @Json({
            "name": $(name),
            "active": true,
            "score": $(score),
            "nested": {"items": [null, -2, 1.25e2,],},
        })
        @Expect(actual, "{\"name\":\"Alice\",\"active\":true,\"score\":7,\"nested\":{\"items\":[null,-2,1.25e2]}}")
    }

    @TestCase
    func dynamicKeysAreLastWinsAndInterpolationsRunOnceLeftToRight(): Unit {
        let order = ArrayList<String>()
        let actual = @Json({
            $(jsonLiteralRecordKey(order, "key-1", "same")): $(jsonLiteralRecordValue(order, "value-1", 1)),
            $(jsonLiteralRecordKey(order, "key-2", "same")): $(jsonLiteralRecordValue(order, "value-2", 2)),
        })
        @Expect(actual, "{\"same\":2}")
        @Expect(jsonLiteralOrderIsLeftToRight(order))
    }

    @TestCase
    func overwrittenFieldsDoNotInvokeTheirCodec(): Unit {
        jsonLiteralTrackedWrites = 0
        let firstKey = "same"
        let secondKey = "same"
        let actual = @Json({
            $(firstKey): $(JsonLiteralTracked(1)),
            $(secondKey): $(JsonLiteralTracked(2)),
        })
        @Expect(actual, "{\"same\":2}")
        @Expect(jsonLiteralTrackedWrites, 1)

        jsonLiteralTrackedWrites = 0
        let tree = @JsonValue({
            $(firstKey): $(JsonLiteralTracked(1)),
            $(secondKey): $(JsonLiteralTracked(2)),
        })
        @Expect(tree["same"].int64, 2)
        @Expect(jsonLiteralTrackedWrites, 1)
    }

    @TestCase
    func jsonValueBuildsAndMutatesTreeWithShortAccessors(): Unit {
        let dynamicKey = "enabled"
        let tree = @JsonValue({"name": "Alice", "items": [1, 2,], $(dynamicKey): true})
        @Expect(tree["name"].string, "Alice")
        @Expect(tree["items"][1].int64, 2)
        @Expect(tree["enabled"].bool)

        tree["name"] = "Bob"
        tree["items"][0] = 9
        @Expect(tree["name"].string, "Bob")
        @Expect(tree["items"][0].int64, 9)
    }

    @TestCase
    func fluentFactoriesBuildMutableJsonNodes(): Unit {
        let root = YJson
            .object()
            .put("nothing", YJson.nullValue())
            .put("items", YJson.array().add(1).add("two").set(0, 3))
        @Expect(root["nothing"].isNull)
        @Expect(root["items"][0].int64, 3)
        @Expect(root["items"][1].string, "two")
    }
}
