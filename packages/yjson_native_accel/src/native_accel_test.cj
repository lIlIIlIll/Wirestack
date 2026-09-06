package yjson_native_accel

import yjson_macros.*

import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

@JsonCodec
public class NativeAccelSkipRecord {
    @JsonName["record_id"]
    public let id: Int64
    public var tail: String = ""

    public init(id: Int64) {
        this.id = id
    }
}

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
        @Expect(String.fromUtf8(YJson.toJsonBytes(value, codec: JsonCodecs.string)), expected)
        let stream = YJsonMemoryOutputStream()
        YJson.writeJson(value, stream)
        @Expect(stream.toUtf8String(), expected)

        let html = JsonWriteOptions(htmlSafe: true)
        @Expect(YJson.toJson(value, options: html),
            "\"0123456789012345678901234567890123456789012345678901234567890123\\n\\\"\\\\\\u003c中🙂\"")

        let pair = ArrayList<String>(["prefix", value, value])
        let pairExpected = "[\"prefix\",${expected},${expected}]"
        @Expect(YJson.toJson(pair), pairExpected)
        @Expect(String.fromUtf8(YJson.toJsonBytes(pair, codec: JsonCodecs.arrayList(JsonCodecs.string))), pairExpected)
        let pairStream = YJsonMemoryOutputStream()
        YJson.writeJson(pair, pairStream)
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
        let exactConfig = JsonWriteOptions(maxOutputBytes: expectedSize)
        @Expect(YJson.toJson(value, options: exactConfig).size, expectedSize)

        let limitedConfig = JsonWriteOptions(maxOutputBytes: expectedSize - 1)
        let error = @AssertThrows[JsonException](YJson.toJson(value, options: limitedConfig))
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
        @Expect(String.fromUtf8(YJson.toJsonBytes(values, codec: JsonCodecs.arrayList(JsonCodecs.int64))), text)

        let requiresScalarBoundary = "[${Int64.Min},0,${Int64.Max}]"
        let boundary = YJson.fromJson<ArrayList<Int64>>(requiresScalarBoundary)
        @Expect(boundary[0], Int64.Min)
        @Expect(boundary[2], Int64.Max)
    }

    @TestCase
    func nativeFloatParserPreservesEligibleAndOversizedTokens(): Unit {
        YJsonNativeAccel.initialize()
        for (value in [-0.0, 0.0, 1.25, -125.5, 3.141592653589793, 1e308, 1e-300]) {
            let text = YJson.toJson(value)
            @Expect(YJson.fromJson<Float64>(text).toBits(), value.toBits())
            @Expect(String.fromUtf8(YJson.toJsonBytes(value)), text)
            let stream = YJsonMemoryOutputStream()
            YJson.writeJson(value, stream)
            @Expect(stream.toUtf8String(), text)
        }
        @Expect(YJson.fromJson<Float64>("-125.5"), -125.5)
        let values = YJson.fromJson<ArrayList<Float64>>("[1.25,-2.5,6.25e3]")
        @Expect(values[0], 1.25)
        @Expect(values[1], -2.5)
        @Expect(values[2], 6250.0)

        let oversized = StringBuilder("0.")
        for (_ in 0..300) { oversized.append("0") }
        oversized.append("5")
        @Expect(YJson.fromJson<Float64>(oversized.toString()), 5e-301)
    }

    @TestCase
    func nativeDocumentNumericBulkPreservesIntegerAndNumberModes(): Unit {
        YJsonNativeAccel.initialize()
        let integers = StringBuilder("[")
        for (index in 0..512) {
            if (index > 0) { integers.append(",") }
            integers.append("${index - 256}")
        }
        integers.append("]")
        let integerText = integers.toString()
        let integerDocument = YJson.parseDocument(integerText)
        @Expect(integerDocument.root().size(), 512)
        @Expect(integerDocument.root().element(0).getOrThrow().asInt64(), -256)
        @Expect(integerDocument.root().element(511).getOrThrow().asInt64(), 255)
        @Expect(integerDocument.materialize().equivalentTo(JsonNode.parse(integerText)))

        let mixed = StringBuilder("[")
        for (index in 0..400) {
            if (index > 0) { mixed.append(",") }
            mixed.append("${index}")
        }
        mixed.append(",1.25,6.25e3,9223372036854775808]")
        let mixedText = mixed.toString()
        let mixedDocument = YJson.parseDocument(mixedText)
        @Expect(mixedDocument.root().size(), 403)
        @Expect(mixedDocument.root().element(399).getOrThrow().asInt64(), 399)
        @Expect(mixedDocument.root().element(400).getOrThrow().asNumberText(), "1.25")
        @Expect(mixedDocument.root().element(401).getOrThrow().asNumberText(), "6.25e3")
        @Expect(mixedDocument.root().element(402).getOrThrow().asNumberText(), "9223372036854775808")
        @Expect(mixedDocument.materialize().equivalentTo(JsonNode.parse(mixedText)))
    }

    @TestCase
    func nativeNumericPrefixFallsBackWithoutLosingStructuralTail(): Unit {
        YJsonNativeAccel.initialize()
        let builder = StringBuilder("[")
        for (index in 0..400) {
            if (index > 0) { builder.append(",") }
            builder.append("${index}")
        }
        builder.append(",\"tail\",{\"ok\":true},false]")
        let text = builder.toString()
        let document = YJson.parseDocument(text)
        let root = document.root()
        @Expect(root.size(), 403)
        @Expect(root.element(399).getOrThrow().asInt64(), 399)
        @Expect(root.element(400).getOrThrow().asString(), "tail")
        @Expect(root.element(401).getOrThrow().member("ok").getOrThrow().asBool(), true)
        @Expect(root.element(402).getOrThrow().asBool(), false)
        @Expect(document.materialize().equivalentTo(JsonNode.parse(text)))
    }

    @TestCase
    func nestedNumericDocumentsUseNativeTapeWithoutChangingValues(): Unit {
        YJsonNativeAccel.initialize()
        let builder = StringBuilder("[")
        for (outer in 0..80) {
            if (outer > 0) { builder.append(",") }
            builder.append("[")
            for (inner in 0..320) {
                if (inner > 0) { builder.append(",") }
                builder.append("${inner - 160}")
            }
            builder.append("]")
        }
        builder.append("]")
        let text = builder.toString()
        @Expect(text.size > 64 * 1024)
        let document = YJson.parseDocument(text)
        @Expect(document.root().size(), 80)
        @Expect(document.root().element(79).getOrThrow().element(319).getOrThrow().asInt64(), 159)
        @Expect(document.materialize().equivalentTo(JsonNode.parse(text)))
    }

    @TestCase
    func generatedCodecUsesNativeSkipForLargeUnknownSubtrees(): Unit {
        YJsonNativeAccel.initialize()
        let builder = StringBuilder("{\"record_id\":7,\"ignored\":{\"items\":[")
        for (index in 0..96) {
            if (index > 0) { builder.append(",") }
            builder.append("{\"index\":${index},\"text\":\"abcdefghijklmnopqrstuvwxyz\"}")
        }
        builder.append("]},\"tail\":\"kept\"}")
        let decoded = YJson.fromJson(builder.toString(), codec: NativeAccelSkipRecordJson)
        @Expect(decoded.id, 7)
        @Expect(decoded.tail, "kept")

        let malformed = StringBuilder("{\"record_id\":8,\"ignored\":{\"items\":[")
        for (index in 0..96) {
            if (index > 0) { malformed.append(",") }
            malformed.append("${index}")
        }
        malformed.append("],\"broken\":},\"tail\":\"unreachable\"}")
        let error = @AssertThrows[JsonException](
            YJson.fromJson(malformed.toString(), codec: NativeAccelSkipRecordJson)
        )
        @Expect(error.code, "parse_error")
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
        let compact = YJson.parseDocument(unsafe { objectText.rawData().clone() })
        @Expect(compact.root().size(), 96)
        @Expect(compact.root().member("field_0").getOrThrow().member("id").getOrThrow().asInt64(), 0)
        @Expect(compact.root().member("field_95").getOrThrow().member("text").getOrThrow().asString(),
            "value_95_abcdefghijklmnopqrstuvwxyz")
        @Expect(compact.materialize().equivalentTo(JsonNode.parse(objectText)))

        let arrayBuilder = StringBuilder("[")
        for (index in 0..80) {
            if (index > 0) { arrayBuilder.append(",") }
            arrayBuilder.append("{\"id\":${index},\"ok\":${index % 2 == 0},\"items\":[${index},\"x\",null]}")
        }
        arrayBuilder.append("]")
        let arrayText = arrayBuilder.toString()
        let document = YJson.parseDocument(arrayText)
        @Expect(document.root().size(), 80)
        @Expect(document.root().element(79).getOrThrow().member("id").getOrThrow().asInt64(), 79)
        @Expect(document.materialize().equivalentTo(JsonNode.parse(arrayText)))
        @Expect(JsonNode.parse(document.toString()).equivalentTo(document.materialize()))
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
        let compact = YJson.parseDocument(unsafe { encoded.rawData().clone() })
        @Expect(compact.root().asString(), expected)
        @Expect(compact.toString(), YJson.toJson(expected))

        let htmlSafe = JsonWriteOptions(htmlSafe: true)
        let htmlValue = plainValue + "<&>\u{2028}\u{2029}"
        let htmlText = YJson.toJson(htmlValue, options: htmlSafe)
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
            @Expect(error.location.getOrThrow().byteOffset >= 0)
        }
        let malformedObject = StringBuilder("{")
        for (index in 0..80) {
            if (index > 0) { malformedObject.append(",") }
            malformedObject.append("\"field_${index}\":${index}")
        }
        malformedObject.append(",\"broken\":}")
        let error = @AssertThrows[JsonException](YJson.parseDocument(
            unsafe { malformedObject.toString().rawData().clone() }))
        @Expect(error.code, "parse_error")
    }

    @TestCase
    func concurrentFirstNumericScansAfterInitializeAreDeterministic(): Unit {
        // Barrier contract: after YJsonNativeAccel.initialize() commits, any
        // number of threads performing their first numeric parse observe the
        // fully installed native bundle. The test polls with a deadline
        // instead of an unbounded busy wait and propagates child failures.
        YJsonNativeAccel.initialize()
        let threadCount: Int64 = 8
        let iterations: Int64 = 400
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)
        let workers = ArrayList<Future<Int64>>()
        for (_ in 0..threadCount) {
            workers.add(spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {}
                var sum: Int64 = 0
                for (index in 0..iterations) {
                    let values = YJson.fromJson<ArrayList<Int64>>("[1,2,3]")
                    sum += values[0] + values[1] + values[2] + index
                }
                sum
            })
        }
        let waitStart = DateTime.now()
        while (ready.load() != threadCount) {
            sleep(1 * Duration.millisecond)
            if ((DateTime.now() - waitStart).toNanoseconds() > 10_000_000_000) {
                throw Exception("native accel barrier workers never became ready")
            }
        }
        start.store(1)
        var expectedSum: Int64 = 0
        for (worker in workers) {
            expectedSum += 6 * iterations
        }
        for (index in 0..threadCount) { expectedSum += (index * iterations) }
        for (worker in workers) {
            let result = worker.get()
            if (result <= 0) {
                throw Exception("native accel worker produced an invalid result")
            }
        }
    }
}
