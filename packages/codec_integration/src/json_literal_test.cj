package yjson_codec_integration

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@Test
class JsonLiteralConsumerTest {
    @TestCase
    func expressionMacroBuildsMutableJsonNode(): Unit {
        let dynamicKey = "user"
        let tree = @Json({
            $(dynamicKey): "Ada",
            "items": [1, true],
        })

        @Expect(YJson.toJson(tree), "{\"user\":\"Ada\",\"items\":[1,true]}")

        tree.asObject().put("active", JsonNode.boolean(true))
        @Expect(tree.asObject().get("active").getOrThrow().asBool(), true)
        @Expect(YJson.toJson(tree), "{\"user\":\"Ada\",\"items\":[1,true],\"active\":true}")
    }
}
