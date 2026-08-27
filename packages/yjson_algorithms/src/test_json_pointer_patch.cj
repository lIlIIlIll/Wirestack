package yjson_algorithms

import yjson.*

import std.unittest.*
import std.unittest.testmacro.*

@Test
class YJsonPointerPatchTest {
    @TestCase
    func pointerRfcEscapesAndRoot(): Unit {
        let root = YJson.parse("{\"\":0,\"a/b\":1,\"m~n\":2,\"items\":[\"x\",\"y\"]}")
        @Expect(JsonPointer.parse("").evaluate(root).equivalentTo(root))
        @Expect(JsonPointer.parse("/").evaluate(root).int64, 0)
        @Expect(JsonPointer.parse("/a~1b").evaluate(root).int64, 1)
        @Expect(JsonPointer.parse("/m~0n").evaluate(root).int64, 2)
        @Expect(JsonPointer.parse("/items/1").evaluate(root).string, "y")
        @Expect(JsonPointer.parseUriFragment("#/a~1b").evaluate(root).int64, 1)
        @AssertThrows[JsonPointerException](JsonPointer.parse("a"))
        @AssertThrows[JsonPointerException](JsonPointer.parse("/~2"))
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
        let original = YJson.parse("{\"name\":\"Alice\",\"items\":[\"a\",\"c\"],\"drop\":true}")
        let result = patch.apply(original)
        @Expect(result.equivalentTo(YJson.parse(
            "{\"copy\":\"a\",\"moved\":\"c\",\"name\":\"Bob\",\"items\":[\"a\",\"b\"]}"
        )))
        @Expect(original["name"].string, "Alice")
    }

    @TestCase
    func patchFailureIsAtomicForCopyAndInPlace(): Unit {
        let patch = JsonPatch.parse("""
        [{"op":"replace","path":"/a","value":2},{"op":"remove","path":"/missing"}]
        """)
        let target = YJson.parse("{\"a\":1}")
        @AssertThrows[JsonPatchException](patch.applyInPlace(target))
        @Expect(target["a"].int64, 1)
    }

    @TestCase
    func mergePatchFollowsRfcObjectAndRootRules(): Unit {
        let target = YJson.parse("{\"a\":\"b\",\"c\":{\"d\":\"e\",\"f\":\"g\"}}")
        let patch = YJson.parse("{\"a\":\"z\",\"c\":{\"f\":null}}");
        let result = JsonMergePatch.apply(target, patch)
        @Expect(YJson.stringify(result), "{\"a\":\"z\",\"c\":{\"d\":\"e\"}}")
        @Expect(JsonMergePatch.apply(target, JsonStringValue("root")).string, "root")
    }

    @TestCase
    func exactNumericEqualityIsUsedByTest(): Unit {
        let patch = JsonPatch.parse("[{\"op\":\"test\",\"path\":\"/n\",\"value\":1.00}]")
        let result = patch.apply(YJson.parse("{\"n\":1e0}"))
        @Expect(result["n"].numberText, "1e0")
    }
}
