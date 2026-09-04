package yjson_yyjson

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private class YyjsonBackendTestOutput <: OutputStream {
    private let bytes = ArrayList<Byte>()
    public func write(value: Array<Byte>): Unit { bytes.add(all: value) }
    public func flush(): Unit {}
    func toBytes(): Array<Byte> { bytes.toArray() }
    func toString(): String { String.fromUtf8(toBytes()) }
}

@Test
class YyjsonStreamBackendTest {
    @TestCase
    func encodeIsByteIdenticalToPureForWriteConfigs(): Unit {
        let codec = JsonCodecs.stringMap(JsonCodecs.string)
        let value = HashMap<String, String>()
        value["<key>"] = "line\n仓颉"
        let json = YyjsonBackends.yyjson
        for (config in [JsonWriteOptions.compact, JsonWriteOptions.pretty(),
            JsonWriteOptions(indent: "  ", htmlSafe: true)]) {
            let pure = YyjsonBackendTestOutput()
            let native = YyjsonBackendTestOutput()
            YJson.writeJson(value, pure, codec: codec, options: config)
            json.writeJson(value, native, codec: codec, options: config)
            @Expect(native.toString(), pure.toString())
        }
    }

    @TestCase
    func decodeSupportsSemanticAndPreservedNumbers(): Unit {
        let codec = JsonCodecs.array(JsonCodecs.float64)
        let json = YyjsonBackends.yyjson
        let value = json.fromJson(YJsonByteArrayInputStream("[1.25,2e2,-0.0]"),
            codec: codec)
        @Expect(value.size, 3)
        @Expect(value[0], 1.25)
        @Expect(value[1], 200.0)
        @Expect(value[2], -0.0)
        let typeError = @AssertThrows[JsonException](json.fromJson(
            YJsonByteArrayInputStream("1.25"), codec: JsonCodecs.int64))
        @Expect(typeError.code, "parse_error")
    }

    @TestCase
    func outputLimitFailsBeforeYyjsonWrites(): Unit {
        let output = YyjsonBackendTestOutput()
        let error = @AssertThrows[JsonException](YyjsonBackends.yyjson.writeJson(
            "too long", output, codec: JsonCodecs.string,
            options: JsonWriteOptions(maxOutputBytes: 4)))
        @Expect(error.code, "output_too_large")
        @Expect(output.toBytes().size, 0)
    }

    @TestCase
    func invalidSemanticVectorsFailWithPureErrorClass(): Unit {
        // Reuses the invalid vectors from src/json_semantic_vectors_test.cj
        // (package boundary prevents importing the root test; embedded here).
        // The yyjson stream backend must classify failures with the same
        // stable error code as the portable path.
        let mapCodec = JsonCodecs.stringMap(JsonCodecs.int64)
        let vectors = [
            "\"unterminated",
            "\"bad\\xescape\"",
            "\"\\uD83Dvalue\"",
            "01",
            "[1,]",
            "{\"a\" 1}",
            "{\"a\":true} trailing",
            "\"\\uD800\"",
            "{\"a\":1,\"a\":2}"
        ]
        for (text in vectors) {
            let pureError = @AssertThrows[JsonException](
                YJson.fromJson(YJsonByteArrayInputStream(text), codec: mapCodec))
            let nativeError = @AssertThrows[JsonException](
                YyjsonBackends.yyjson.fromJson(YJsonByteArrayInputStream(text),
                    codec: mapCodec))
            @Expect(nativeError.code, pureError.code)
        }
    }
}
