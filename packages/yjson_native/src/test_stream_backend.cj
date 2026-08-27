package yjson_native

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_backends.*

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
            YJsonAdvanced.encodeToStreamWithBackend(codec, value, native,
                NativeCompactWholeDocumentStreamBackend, config: config)
            @Expect(native.toString(), pure.toString())
        }
    }

    @TestCase
    func decodeUsesTypedCodecAndEnforcesInputLimit(): Unit {
        let codec = YJson.arrayCodec(Int64Json)
        let value = YJsonAdvanced.decodeFromStreamWithBackend(codec, YJsonByteArrayInputStream("[1,2,3]"),
            NativeCompactWholeDocumentStreamBackend)
        @Expect(value.size, 3)
        @Expect(value[2], 3)
        let typeError = @AssertThrows[JsonException](YJsonAdvanced.decodeFromStreamWithBackend(Int64Json,
            YJsonByteArrayInputStream("1.25"), NativeCompactWholeDocumentStreamBackend))
        @Expect(typeError.code, "parse_error")
        let error = @AssertThrows[JsonException](YJsonAdvanced.decodeFromStreamWithBackend(codec,
            YJsonByteArrayInputStream("[1,2,3]"), NativeCompactWholeDocumentStreamBackend,
            config: JsonReadConfig(limits: JsonReadLimits(maxBytes: 4))))
        @Expect(error.code, "document_too_large")
    }

    @TestCase
    func outputLimitFailsBeforeNativeWrites(): Unit {
        let output = NativeBackendTestOutput()
        let error = @AssertThrows[JsonException](YJsonAdvanced.encodeToStreamWithBackend(StringJson,
            "too long", output, NativeCompactWholeDocumentStreamBackend,
            config: JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxBytes: 4))))
        @Expect(error.code, "output_too_large")
        @Expect(output.toBytes().size, 0)
    }
}
