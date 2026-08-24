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
        let codec = YJson.hashMapCodec(StringJson)
        let value = HashMap<String, String>()
        value["<key>"] = "line\n仓颉"
        for (config in [JsonWriteConfig.compact, JsonWriteConfig.pretty,
            JsonWriteConfig("\r\n", "  ", true, true)]) {
            let pure = NativeBackendTestOutput()
            let native = NativeBackendTestOutput()
            YJson.encodeToStreamWith(codec, value, pure, config: config)
            YJson.encodeToStreamWith(codec, value, native,
                backend: NativeCompactStreamBackend, config: config)
            @Expect(native.toString(), pure.toString())
        }
    }

    @TestCase
    func decodeUsesTypedCodecAndEnforcesInputLimit(): Unit {
        let codec = YJson.arrayCodec(Int64Json)
        let value = YJson.decodeFromStreamWith(codec, YJsonByteArrayInputStream("[1,2,3]"),
            backend: NativeCompactStreamBackend)
        @Expect(value.size, 3)
        @Expect(value[2], 3)
        let typeError = @AssertThrows[JsonException](YJson.decodeFromStreamWith(Int64Json,
            YJsonByteArrayInputStream("1.25"), backend: NativeCompactStreamBackend))
        @Expect(typeError.code, "parse_error")
        let error = @AssertThrows[JsonException](YJson.decodeFromStreamWith(codec,
            YJsonByteArrayInputStream("[1,2,3]"), backend: NativeCompactStreamBackend,
            config: JsonReadConfig(maxBytes: 4)))
        @Expect(error.code, "document_too_large")
    }

    @TestCase
    func outputLimitFailsBeforeNativeWrites(): Unit {
        let output = NativeBackendTestOutput()
        let error = @AssertThrows[JsonException](YJson.encodeToStreamWith(StringJson,
            "too long", output, backend: NativeCompactStreamBackend,
            config: JsonWriteConfig("", "", false, false, maxBytes: 4)))
        @Expect(error.code, "output_too_large")
        @Expect(output.toBytes().size, 0)
    }
}
