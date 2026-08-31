package yjson_algorithms

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class YJsonPointerPatchTest {
    @TestCase
    func pointerRfcEscapesAndRoot(): Unit {
        let root = JsonNode.parse("{\"\":0,\"a/b\":1,\"m~n\":2,\"items\":[\"x\",\"y\"]}")
        @Expect(jsonNodesEquivalent(JsonPointer.parse("").evaluate(root), root))
        @Expect(JsonPointer.parse("/").evaluate(root).asInt64(), 0)
        @Expect(JsonPointer.parse("/a~1b").evaluate(root).asInt64(), 1)
        @Expect(JsonPointer.parse("/m~0n").evaluate(root).asInt64(), 2)
        @Expect(JsonPointer.parse("/items/1").evaluate(root).asString(), "y")
        @Expect(JsonPointer.parseUriFragment("#/a~1b").evaluate(root).asInt64(), 1)
        @Expect(@AssertThrows[JsonException](JsonPointer.parse("a")).code,
            "invalid_json_pointer")
        @Expect(@AssertThrows[JsonException](JsonPointer.parse("/~2")).code,
            "invalid_json_pointer")
    }

    @TestCase
    func patchSupportsAllRfcOperations(): Unit {
        let patch = JsonPatch.parse("""
        [
          {"op":"add","path":"/items/1","value":"b"},
          {"op":"replace","path":"/name","value":"Bob"},
          {"op":"copy","from":"/items/0","path":"/copy"},
          {"op":"move","from":"/items/2","path":"/moved"},
          {"op":"test","path":"/copy","value":"a"},
          {"op":"remove","path":"/drop"}
        ]
        """)
        let original = JsonNode.parse("{\"name\":\"Alice\",\"items\":[\"a\",\"c\"],\"drop\":true}")
        let result = patch.apply(original)
        @Expect(result.equivalentTo(JsonNode.parse(
            "{\"copy\":\"a\",\"moved\":\"c\",\"name\":\"Bob\",\"items\":[\"a\",\"b\"]}"
        )))
        @Expect(original["name"].asString(), "Alice")
    }

    @TestCase
    func patchFailureIsAtomicForCopyAndInPlace(): Unit {
        let patch = JsonPatch.parse("""
        [{"op":"replace","path":"/a","value":2},{"op":"remove","path":"/missing"}]
        """)
        let target = JsonNode.parse("{\"a\":1}")
        @Expect(@AssertThrows[JsonException](patch.applyInPlace(target)).code, "json_patch_path")
        @Expect(target["a"].asInt64(), 1)
    }

    @TestCase
    func mergePatchFollowsRfcObjectAndRootRules(): Unit {
        let target = JsonNode.parse("{\"a\":\"b\",\"c\":{\"d\":\"e\",\"f\":\"g\"}}")
        let patch = JsonNode.parse("{\"a\":\"z\",\"c\":{\"f\":null}}");
        let result = JsonMergePatch.apply(target, patch)
        @Expect((result).toJson(), "{\"a\":\"z\",\"c\":{\"d\":\"e\"}}")
        @Expect(JsonMergePatch.apply(target, JsonNode.string("root")).asString(), "root")
    }

    @TestCase
    func exactNumericEqualityIsUsedByTest(): Unit {
        let patch = JsonPatch.parse("[{\"op\":\"test\",\"path\":\"/n\",\"value\":1.00}]")
        let result = patch.apply(JsonNode.parse("{\"n\":1e0}"))
        @Expect(result["n"].asNumberText(), "1e0")
    }
}
