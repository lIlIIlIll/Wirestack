package yjson_bulk_path_mock_tests

import yjson.*
import yjson_macros.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import std.unittest.mock.*
import std.unittest.mock.mockmacro.*

private interface BulkHookWriter <: GeneratedSupportV1Writer {}

@JsonCodec
class MockGeneratedCursorEnvelope {
    public var arrayInt32: Array<Int32> = Array<Int32>()
    public var listUInt16: ArrayList<UInt16> = ArrayList<UInt16>()
    public var mapFloat32: HashMap<String, Float32> = HashMap<String, Float32>()
    public var mapArrayBool: HashMap<String, Array<Bool>> = HashMap<String, Array<Bool>>()
    public var mapListString: HashMap<String, ArrayList<String>> =
        HashMap<String, ArrayList<String>>()
    public init() {}
}

@Test
class GeneratedBulkHookMockTest {
    @TestCase
    func directArrayUsesInt64ArrayHook(): Unit {
        let writer = mock<BulkHookWriter>(ReturnsDefaults)
        @On(writer.tryWriteCompactInt64Array(_)).returns(true)

        JsonCodecs.array(JsonCodecs.int64).write([1, 2, 3], writer)

        Verify.that(@Called(writer.tryWriteCompactInt64Array(_)).once())
    }

    @TestCase
    func nestedArrayMapUsesWholeMapHook(): Unit {
        let values = HashMap<String, Array<Int64>>()
        values.add("items", [4, 5, 6])
        let writer = mock<BulkHookWriter>(ReturnsDefaults)
        @On(writer.tryWriteCompactInt64ArrayMap(_)).returns(true)

        JsonCodecs.stringMap(JsonCodecs.array(JsonCodecs.int64)).write(values, writer)

        Verify.that(@Called(writer.tryWriteCompactInt64ArrayMap(_)).once())
        Verify.that(@Called(writer.tryWriteCompactInt64Array(_)).never())
    }

    @TestCase
    func generatedPrimitiveFamiliesAcquireOneCursorAndAvoidSemanticWriter(): Unit {
        let value = MockGeneratedCursorEnvelope()
        value.arrayInt32 = [-3i32, Int32.Max]
        value.listUInt16.add(7u16)
        value.mapFloat32.add("ratio", 1.5f32)
        value.mapArrayBool.add("flags", [true, false])
        let names = ArrayList<String>(["仓颉", "quote\""])
        value.mapListString.add("names", names)

        let backing = GeneratedSupportV1.newWriter()
        let writer = mock<BulkHookWriter>(ReturnsDefaults)
        @On(writer.tryBeginGeneratedCompactRawValue()).returns(true)
        @On(writer.generatedCursorV1()).returns(backing.generatedCursorV1())
        @On(writer.generatedWriteStateV1()).returns(backing.generatedWriteStateV1())

        MockGeneratedCursorEnvelopeJson.write(value, writer)

        @Expect(backing.finishString(),
            "{\"arrayInt32\":[-3,2147483647],\"listUInt16\":[7]," +
            "\"mapFloat32\":{\"ratio\":1.500000},\"mapArrayBool\":{\"flags\":[true,false]}," +
            "\"mapListString\":{\"names\":[\"仓颉\",\"quote\\\"\"]}}")
        Verify.that(@Called(writer.tryBeginGeneratedCompactRawValue()).once())
        Verify.that(@Called(writer.generatedCursorV1()).once())
        Verify.that(@Called(writer.startObject()).never())
    }
}
