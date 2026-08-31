package yjson

import std.unittest.*
import std.unittest.testmacro.*

private class HandwrittenCursorFailureCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonWriter): Unit {
        let _ = value
        writer.startObject()
        writer.writeName("items/~")
        writer.startArray()
        writer.writeNumberLiteral("01")
        writer.endArray()
        writer.endObject()
    }

    public func read(reader: JsonReader): Int64 {
        reader.startObject()
        let _ = reader.readName()
        reader.startArray()
        let value = reader.readInt64()
        reader.endArray()
        reader.endObject()
        value
    }
}

@Test
class JsonContextPathTest {
    @TestCase
    func semanticCursorsOwnPendingAndCompletedPaths(): Unit {
        let writer = JsonDirectWriter()
        writer.startObject()
        writer.writeName("items/~")
        @Expect(writer.path(), "/items~1~0")
        writer.startArray()
        @Expect(writer.path(), "/items~1~0")
        writer.writeInt64(1)
        @Expect(writer.path(), "/items~1~0")
        writer.endArray()
        @Expect(writer.path(), "")
        writer.endObject()
        @Expect(writer.finishString(), "{\"items/~\":[1]}")

        let reader = JsonDirectReader("{\"items/~\":[1]}")
        reader.startObject()
        @Expect(reader.readName(), "items/~")
        @Expect(reader.path(), "/items~1~0")
        reader.startArray()
        @Expect(reader.path(), "/items~1~0")
        @Expect(reader.readInt64(), 1)
        @Expect(reader.path(), "/items~1~0")
        reader.endArray()
        @Expect(reader.path(), "")
        reader.endObject()
        reader.expectEnd()
    }

    @TestCase
    func handwrittenCodecGetsAutomaticNestedFailurePaths(): Unit {
        let codec = HandwrittenCursorFailureCodec()
        let directWriteError = @AssertThrows[JsonException](YJson.toJson(0, codec: codec))
        @Expect(directWriteError.code, "invalid_number")
        @Expect(directWriteError.path, "/items~1~0/0")

        let tapeWriter = BackendTapeWriterV1()
        let tapeWriteError = @AssertThrows[JsonException](codec.write(0, tapeWriter))
        @Expect(tapeWriteError.code, "invalid_number")
        @Expect(tapeWriteError.path, "/items~1~0/0")

        let directReadError = @AssertThrows[JsonException](
            YJson.fromJson("{\"items/~\":[\"bad\"]}", codec: codec)
        )
        @Expect(directReadError.code, "parse_error")
        @Expect(directReadError.path, "/items~1~0/0")
        @Expect(directReadError.location.isSome())

        let validTape = BackendTapeWriterV1()
        validTape.startObject()
        validTape.writeName("items/~")
        validTape.startArray()
        validTape.writeString("bad")
        validTape.endArray()
        validTape.endObject()
        let tapeReadError = @AssertThrows[JsonException](
            codec.read(BackendTapeReaderV1(validTape.finishTape()))
        )
        @Expect(tapeReadError.code, "parse_error")
        @Expect(tapeReadError.path, "/items~1~0/0")
        @Expect(tapeReadError.location.isNone())
    }

    @TestCase
    func decodeContextKeepsEmptyPathSemanticsWithoutPushes(): Unit {
        let context = GeneratedReadStateV1(JsonReadOptions())
        @Expect(context.currentPath(), "")
        context.popPath()
        @Expect(context.currentPath(), "")
        context.pushField("value")
        context.popPath()
        @Expect(context.currentPath(), "")
    }

    @TestCase
    func decodeContextBuildsArrayPathOnlyWhenRequested(): Unit {
        let context = GeneratedReadStateV1(JsonReadOptions())
        context.pushField("items")
        context.pushIndex(12)
        context.pushField("name")
        @Expect(context.currentPath(), "/items/12/name")
        context.popPath()
        context.popPath()
        @Expect(context.currentPath(), "/items")
    }

    @TestCase
    func encodeContextDoesNotMistakeBracketFieldForIndex(): Unit {
        let context = GeneratedWriteStateV1(JsonWriteOptions.compact)
        context.pushField("[literal")
        @Expect(context.currentPath(), "/[literal")
        context.pushIndex(3)
        @Expect(context.currentPath(), "/[literal/3")
    }

    @TestCase
    func encodeContextUpdatesReusablePathFrames(): Unit {
        let context = GeneratedWriteStateV1(JsonWriteOptions.compact)
        @Expect(context.currentPath(), "")
        context.updateLastField("ignored")
        context.updateLastIndex(99)
        @Expect(context.currentPath(), "")

        context.pushField("groups")
        context.pushIndex(0)
        context.updateLastIndex(63)
        @Expect(context.currentPath(), "/groups/63")
        context.popPath()
        context.updateLastField("featured")
        @Expect(context.currentPath(), "/featured")
        context.popPath()
        @Expect(context.currentPath(), "")
    }
}
