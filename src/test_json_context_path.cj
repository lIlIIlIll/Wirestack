package yjson

import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonContextPathTest {
    @TestCase
    func decodeContextKeepsEmptyPathSemanticsWithoutPushes(): Unit {
        let context = JsonDecodeContext(JsonReadConfig())
        @Expect(context.currentPath(), "$")
        context.popPath()
        @Expect(context.currentPath(), "$")
        context.pushField("value")
        context.popPath()
        @Expect(context.currentPath(), "$")
    }

    @TestCase
    func decodeContextBuildsArrayPathOnlyWhenRequested(): Unit {
        let context = JsonDecodeContext(JsonReadConfig())
        context.pushField("items")
        context.pushIndex(12)
        context.pushField("name")
        @Expect(context.currentPath(), "$.items[12].name")
        context.popPath()
        context.popPath()
        @Expect(context.currentPath(), "$.items")
    }

    @TestCase
    func encodeContextDoesNotMistakeBracketFieldForIndex(): Unit {
        let context = JsonEncodeContext(JsonWriteConfig.compact)
        context.pushField("[literal")
        @Expect(context.currentPath(), "$.[literal")
        context.pushIndex(3)
        @Expect(context.currentPath(), "$.[literal[3]")
    }
}
