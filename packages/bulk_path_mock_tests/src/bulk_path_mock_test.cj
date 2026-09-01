package yjson_bulk_path_mock_tests

import yjson.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import std.unittest.mock.*
import std.unittest.mock.mockmacro.*

private interface BulkHookWriter <: GeneratedSupportV1Writer {}

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
}
