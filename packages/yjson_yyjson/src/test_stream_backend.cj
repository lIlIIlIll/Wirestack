package yjson_yyjson

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_backends.*

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
        let codec = YJson.hashMapCodec(StringJson)
        let value = HashMap<String, String>()
        value["<key>"] = "line\n仓颉"
        for (config in [JsonWriteConfig.compact, JsonWriteConfig.pretty,
            JsonWriteConfig("\r\n", "  ", true, true)]) {
            let pure = YyjsonBackendTestOutput()
            let native = YyjsonBackendTestOutput()
            YJson.encodeToStreamWith(codec, value, pure, config: config)
            YJsonAdvanced.encodeToStreamWithBackend(codec, value, native,
                YyjsonWholeDocumentStreamBackend, config: config)
            @Expect(native.toString(), pure.toString())
        }
    }

    @TestCase
    func decodeSupportsSemanticAndPreservedNumbers(): Unit {
        let codec = YJson.arrayCodec(Float64Json)
        let value = YJsonAdvanced.decodeFromStreamWithBackend(codec,
            YJsonByteArrayInputStream("[1.25,2e2,-0.0]"), YyjsonWholeDocumentStreamBackend)
        @Expect(value.size, 3)
        @Expect(value[0], 1.25)
        @Expect(value[1], 200.0)
        @Expect(value[2], -0.0)
        let typeError = @AssertThrows[JsonException](YJsonAdvanced.decodeFromStreamWithBackend(Int64Json,
            YJsonByteArrayInputStream("1.25"), YyjsonWholeDocumentStreamBackend))
        @Expect(typeError.code, "parse_error")
    }

    @TestCase
    func outputLimitFailsBeforeYyjsonWrites(): Unit {
        let output = YyjsonBackendTestOutput()
        let error = @AssertThrows[JsonException](YJsonAdvanced.encodeToStreamWithBackend(StringJson,
            "too long", output, YyjsonWholeDocumentStreamBackend,
            config: JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxBytes: 4))))
        @Expect(error.code, "output_too_large")
        @Expect(output.toBytes().size, 0)
    }
}
