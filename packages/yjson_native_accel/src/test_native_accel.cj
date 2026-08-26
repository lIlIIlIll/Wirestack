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
}
