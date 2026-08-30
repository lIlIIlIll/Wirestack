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

    @TestCase
    func nativeEscapingUsesExactOutputSizeAndHonorsMaxBytesBeforeWriting(): Unit {
        YJsonNativeAccel.initialize()
        let builder = StringBuilder()
        for (_ in 0..4096) { builder.append("a") }
        builder.append("\n")
        let value = builder.toString()
        let expectedSize = value.size + 3
        let exactConfig = JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxBytes: expectedSize))
        @Expect(YJson.toJson(value, config: exactConfig).size, expectedSize)

        let limitedConfig = JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxBytes: expectedSize - 1))
        let error = @AssertThrows[JsonException](YJson.toJson(value, config: limitedConfig))
        @Expect(error.code, "output_too_large")
    }

    @TestCase
    func bulkInt64ReadWritePreservesSemanticsAndScalarFallback(): Unit {
        YJsonNativeAccel.initialize()
        let values = ArrayList<Int64>()
        for (index in 0..4096) { values.add(index * 17 - 12345) }
        let text = YJson.toJson(values)
        let decoded = YJson.fromJson<ArrayList<Int64>>(text)
        @Expect(decoded.size, values.size)
        @Expect(decoded[0], values[0])
        @Expect(decoded[2048], values[2048])
        @Expect(decoded[4095], values[4095])
        @Expect(String.fromUtf8(YJson.encodeBytesWith(YJson.int64ArrayListCodec(), values)), text)

        let requiresScalarBoundary = "[${Int64.Min},0,${Int64.Max}]"
        let boundary = YJson.fromJson<ArrayList<Int64>>(requiresScalarBoundary)
        @Expect(boundary[0], Int64.Min)
        @Expect(boundary[2], Int64.Max)
    }

    @TestCase
    func structuralScanAndManagedDocumentPathsPreserveSemantics(): Unit {
        YJsonNativeAccel.initialize()
        let objectBuilder = StringBuilder("{")
        for (index in 0..96) {
            if (index > 0) { objectBuilder.append(",") }
            objectBuilder.append("\"field_${index}\":{\"id\":${index},\"text\":\"value_${index}_abcdefghijklmnopqrstuvwxyz\"}")
        }
        objectBuilder.append("}")
        let objectText = objectBuilder.toString()
        let compact = YJson.parseCompact(unsafe { objectText.rawData().clone() })
        @Expect(compact.root().size(), 96)
        @Expect(compact.root().get("field_0").getOrThrow().get("id").getOrThrow().asInt64(), 0)
        @Expect(compact.root().get("field_95").getOrThrow().get("text").getOrThrow().asString(),
            "value_95_abcdefghijklmnopqrstuvwxyz")
        @Expect(compact.materialize().equivalentTo(YJson.parse(objectText)))

        let arrayBuilder = StringBuilder("[")
        for (index in 0..80) {
            if (index > 0) { arrayBuilder.append(",") }
            arrayBuilder.append("{\"id\":${index},\"ok\":${index % 2 == 0},\"items\":[${index},\"x\",null]}")
        }
        arrayBuilder.append("]")
        let arrayText = arrayBuilder.toString()
        let document = YJson.parseDocument(arrayText)
        @Expect(document.root().size(), 80)
        @Expect(document.root().get(79).getOrThrow().get("id").getOrThrow().asInt64(), 79)
        @Expect(document.materialize().equivalentTo(YJson.parse(arrayText)))
        @Expect(YJson.parse(document.toString()).equivalentTo(document.materialize()))
    }

    @TestCase
    func nativeStringScanDecodeAndEscapingCoverLongUtf8Inputs(): Unit {
        YJsonNativeAccel.initialize()
        let plain = StringBuilder()
        for (_ in 0..320) { plain.append("a") }
        plain.append("仓颉🙂")
        let plainValue = plain.toString()
        @Expect(YJson.fromJson<String>(YJson.toJson(plainValue)), plainValue)

        let encoded = "\"" + plain.toString() + "\\n\\t\\\"\\\\\\u4ED3\""
        let expected = plainValue + "\n\t\"\\仓"
        @Expect(YJson.fromJson<String>(encoded), expected)
        let compact = YJson.parseCompact(unsafe { encoded.rawData().clone() })
        @Expect(compact.root().asString(), expected)
        @Expect(compact.toString(), YJson.toJson(expected))

        let htmlSafe = JsonWriteConfig("", "", false, true)
        let htmlValue = plainValue + "<&>\u{2028}\u{2029}"
        let htmlText = YJson.toJson(htmlValue, config: htmlSafe)
        @Expect(htmlText.contains("\\u003c"))
        @Expect(htmlText.contains("\\u0026"))
        @Expect(htmlText.contains("\\u003e"))
        @Expect(YJson.fromJson<String>(htmlText), htmlValue)
    }

    @TestCase
    func nativeScannerFailuresKeepNormalizedParseErrors(): Unit {
        YJsonNativeAccel.initialize()
        let longPrefix = StringBuilder("\"")
        for (_ in 0..320) { longPrefix.append("a") }
        for (suffix in ["\\x\"", "\\uD800\"", "\\u12\"", ""]) {
            let error = @AssertThrows[JsonException](YJson.fromJson<String>(longPrefix.toString() + suffix))
            @Expect(error.code, "parse_error")
            @Expect(error.byteOffset >= 0)
        }
        let malformedObject = StringBuilder("{")
        for (index in 0..80) {
            if (index > 0) { malformedObject.append(",") }
            malformedObject.append("\"field_${index}\":${index}")
        }
        malformedObject.append(",\"broken\":}")
        let error = @AssertThrows[JsonException](YJson.parseCompact(
            unsafe { malformedObject.toString().rawData().clone() }))
        @Expect(error.code, "parse_error")
    }
}
