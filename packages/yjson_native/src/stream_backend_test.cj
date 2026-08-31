package yjson_native

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private class NativeBackendTestOutput <: OutputStream {
    private let bytes = ArrayList<Byte>()
    public func write(value: Array<Byte>): Unit { bytes.add(all: value) }
    public func flush(): Unit {}
    func toBytes(): Array<Byte> { bytes.toArray() }
    func toString(): String { String.fromUtf8(toBytes()) }
}

@Test
class NativeStreamBackendTest {
    @TestCase
    func encodeIsByteIdenticalToPureForWriteConfigs(): Unit {
        let codec = JsonCodecs.stringMap(JsonCodecs.string)
        let value = HashMap<String, String>()
        value["<key>"] = "line\n仓颉"
        let json = NativeBackends.customNative
        for (config in [JsonWriteOptions.compact, JsonWriteOptions.pretty(),
            JsonWriteOptions(indent: "  ", htmlSafe: true)]) {
            let pure = NativeBackendTestOutput()
            let native = NativeBackendTestOutput()
            YJson.writeJson(value, pure, codec: codec, options: config)
            json.writeJson(value, native, codec: codec, options: config)
            @Expect(native.toString(), pure.toString())
        }
    }

    @TestCase
    func decodeUsesTypedCodecAndEnforcesInputLimit(): Unit {
        let codec = JsonCodecs.array(JsonCodecs.int64)
        let json = NativeBackends.customNative
        let value = json.fromJson(YJsonByteArrayInputStream("[1,2,3]"), codec: codec)
        @Expect(value.size, 3)
        @Expect(value[2], 3)
        let typeError = @AssertThrows[JsonException](json.fromJson(
            YJsonByteArrayInputStream("1.25"), codec: JsonCodecs.int64))
        @Expect(typeError.code, "parse_error")
        let error = @AssertThrows[JsonException](json.fromJson(
            YJsonByteArrayInputStream("[1,2,3]"), codec: codec,
            options: JsonReadOptions(maxInputBytes: 4)))
        @Expect(error.code, "document_too_large")
    }

    @TestCase
    func outputLimitFailsBeforeNativeWrites(): Unit {
        let output = NativeBackendTestOutput()
        let error = @AssertThrows[JsonException](NativeBackends.customNative.writeJson(
            "too long", output, codec: JsonCodecs.string,
            options: JsonWriteOptions(maxOutputBytes: 4)))
        @Expect(error.code, "output_too_large")
        @Expect(output.toBytes().size, 0)
    }
}
