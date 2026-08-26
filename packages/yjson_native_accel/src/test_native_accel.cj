package yjson_native_accel

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

@Test
class NativeAccelPublicContractTest {
    @TestCase
    func initializeIsIdempotentAndKeepsYJsonApi(): Unit {
        YJsonNativeAccel.initialize()
        YJsonNativeAccel.initialize()
        @Expect(YJson.fromJson<ArrayList<Int64>>("[1,2,3]")[2], 3)
        @Expect(YJson.toJson(ArrayList<Int64>([1, 2, 3])), "[1,2,3]")
    }

    @TestCase
    func nativeEscapingKeepsStringBytesAndStreamTargetsIdentical(): Unit {
        YJsonNativeAccel.initialize()
        let value = "0123456789012345678901234567890123456789012345678901234567890123\n\"\\<中🙂"
        let expected = "\"0123456789012345678901234567890123456789012345678901234567890123\\n\\\"\\\\<中🙂\""
        @Expect(YJson.toJson(value), expected)
        @Expect(String.fromUtf8(YJson.encodeBytesWith(StringJson, value)), expected)
        let stream = YJsonMemoryOutputStream()
        YJson.toStream(value, stream)
        @Expect(stream.toUtf8String(), expected)

        let html = JsonWriteConfig("", "", false, true)
        @Expect(YJson.toJson(value, config: html),
            "\"0123456789012345678901234567890123456789012345678901234567890123\\n\\\"\\\\\\u003c中🙂\"")

        let pair = ArrayList<String>(["prefix", value, value])
        let pairExpected = "[\"prefix\",${expected},${expected}]"
        @Expect(YJson.toJson(pair), pairExpected)
        @Expect(String.fromUtf8(YJson.encodeBytesWith(YJson.arrayListCodec(StringJson), pair)), pairExpected)
        let pairStream = YJsonMemoryOutputStream()
        YJson.toStream(pair, pairStream)
        @Expect(pairStream.toUtf8String(), pairExpected)
    }
}
