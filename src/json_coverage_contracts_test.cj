package yjson

import std.collection.*
import std.math.numeric.*
import std.unittest.*
import std.unittest.testmacro.*

private class CoverageSemanticIntCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonWriter): Unit {
        writer.writeInt64(value)
    }

    public func read(reader: JsonReader): Int64 {
        reader.readInt64()
    }
}

private class CoverageReifiedValue {
    let value: Int64

    init(value: Int64) { this.value = value }
}

private class CoverageReifiedCodec <: GeneratedCodecV1<CoverageReifiedValue> {
    public func write(value: CoverageReifiedValue, writer: JsonWriter): Unit {
        writer.writeInt64(value.value)
    }

    public func read(reader: JsonReader): CoverageReifiedValue {
        let value = reader.readInt64()
        if (value < 0) {
            throw JsonException("Coverage codec rejected the value",
                code: "coverage_value_rejected")
        }
        CoverageReifiedValue(value)
    }

    public func readFast(reader: GeneratedSupportV1Reader): CoverageReifiedValue {
        let value = reader.readRawInt64()
        if (value < 0) {
            throw JsonException("Coverage codec rejected the value",
                code: "coverage_value_rejected")
        }
        CoverageReifiedValue(value)
    }
}

extend CoverageReifiedValue <: GeneratedCodecProviderV1<CoverageReifiedValue> {
    public static func generatedCodecV1(_: GeneratedCodecTokenV1<CoverageReifiedValue>): JsonCodec<CoverageReifiedValue> {
        CoverageReifiedCodec()
    }
}

private func coverageRichTape(): Array<Byte> {
    let writer = BackendTapeWriterV1()
    writer.startObject()
    writer.writeName("null"); writer.writeNull()
    writer.writeName("bool"); writer.writeBool(true)
    writer.writeName("int"); writer.writeInt64(-7)
    writer.writeName("uint"); writer.writeUInt64(UInt64.Max)
    writer.writeName("float"); writer.writeFloat64(1.5)
    writer.writeName("raw"); writer.writeNumberLiteral("12345678901234567890")
    writer.writeName("text"); writer.writeString("仓颉")
    writer.writeName("array"); writer.startArray(); writer.writeBool(false); writer.writeInt64(2); writer.endArray()
    writer.writeName("object"); writer.startObject(); writer.writeName("x"); writer.writeString("y"); writer.endObject()
    writer.endObject()
    writer.finishTape()
}

private func coverageBytes(text: String): Array<Byte> { unsafe { text.rawData().clone() } }

private func coverageJsonErrorCode(action: () -> Unit): String {
    try {
        action()
        ""
    } catch (error: JsonException) {
        error.code
    }
}

@Test
class JsonCoverageContractsTest {
    @TestCase
    func typedContainerCodecsCoverSemanticDirectFastEmptyAndBulkPaths(): Unit {
        let semantic = CoverageSemanticIntCodec()
        let optionCodec = JsonCodecs.option(semantic)
        let arrayCodec = JsonCodecs.array(semantic)
        let listCodec = JsonCodecs.arrayList(semantic)
        let mapCodec = JsonCodecs.stringMap(semantic)

        // A tape is a non-direct semantic writer and reader. It exercises the
        // backend-neutral codec contract without relying on string parsing.
        let tapeWriter = BackendTapeWriterV1()
        optionCodec.write(Some(1), tapeWriter)
        let tapeReader = BackendTapeReaderV1(tapeWriter.finishTape())
        @Expect(optionCodec.read(tapeReader).getOrThrow(), 1)
        tapeReader.expectEnd()

        let noneWriter = BackendTapeWriterV1()
        optionCodec.write(None<Int64>, noneWriter)
        let noneReader = BackendTapeReaderV1(noneWriter.finishTape())
        @Expect(optionCodec.read(noneReader).isNone())
        noneReader.expectEnd()

        for (values in [Array<Int64>(), [1, 2]]) {
            let writer = BackendTapeWriterV1()
            arrayCodec.write(values, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = arrayCodec.read(reader)
            @Expect(decoded.size, values.size)
            if (!values.isEmpty()) { @Expect(decoded[1], 2) }
            reader.expectEnd()
        }

        for (size in [0, 2]) {
            let values = ArrayList<Int64>()
            for (index in 0..size) { values.add(index + 3) }
            let writer = BackendTapeWriterV1()
            listCodec.write(values, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = listCodec.read(reader)
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded[1], 4) }
            reader.expectEnd()
        }

        for (size in [0, 2]) {
            let values = HashMap<String, Int64>()
            if (size > 0) { values["a"] = 5; values["b"] = 6 }
            let writer = BackendTapeWriterV1()
            mapCodec.write(values, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = mapCodec.read(reader)
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded["b"], 6) }
            reader.expectEnd()
        }

        // Specialized generated codecs must preserve the same semantic-reader
        // contract for both empty/null and populated values.
        let semanticStringOption = JsonCodecs.option(JsonCodecs.string)
        for (value in [None<String>, Some("semantic")]) {
            let writer = BackendTapeWriterV1()
            semanticStringOption.write(value, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = semanticStringOption.read(reader)
            @Expect(decoded, value)
            reader.expectEnd()
        }

        let semanticStrings = JsonCodecs.arrayList(JsonCodecs.string)
        for (size in [0, 2]) {
            let values = ArrayList<String>()
            if (size > 0) { values.add("a"); values.add("b") }
            let writer = BackendTapeWriterV1()
            semanticStrings.write(values, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = semanticStrings.read(reader)
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded[1], "b") }
            reader.expectEnd()
        }

        let semanticIntMap = JsonCodecs.stringMap(JsonCodecs.int64)
        for (size in [0, 2]) {
            let values = HashMap<String, Int64>()
            if (size > 0) { values["a"] = 13; values["b"] = 14 }
            let writer = BackendTapeWriterV1()
            semanticIntMap.write(values, writer)
            let reader = BackendTapeReaderV1(writer.finishTape())
            let decoded = semanticIntMap.read(reader)
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded["b"], 14) }
            reader.expectEnd()
        }

        // DirectWriter with a semantic-only element codec covers the narrow
        // SPI fallback used by custom codecs, including nested path tracking.
        @Expect(YJson.toJson(Some(7), codec: optionCodec), "7")
        @Expect(YJson.toJson(None<Int64>, codec: optionCodec), "null")
        @Expect(YJson.toJson([8, 9], codec: arrayCodec), "[8,9]")
        let directList = ArrayList<Int64>(); directList.add(10); directList.add(11)
        @Expect(YJson.toJson(directList, codec: listCodec), "[10,11]")
        let directMap = HashMap<String, Int64>(); directMap["x"] = 12
        @Expect(JsonNode.parse(YJson.toJson(directMap, codec: mapCodec)).asObject()["x"].asInt64(), 12)

        // Fast generic containers cover empty, small, and capacity-hinted
        // collection loops. Configured reads force the semantic reader path.
        let fastArray = JsonCodecs.array(JsonCodecs.int64)
        @Expect(YJson.fromJson("[]", codec: fastArray).size, 0)
        @Expect(YJson.fromJson("[1,2,3,4,5,6]", codec: fastArray).size, 6)
        @Expect(YJson.fromJson("[1,2]", codec: fastArray, options: JsonReadOptions(maxDepth: 257))[1], 2)
        let fastList = JsonCodecs.arrayList(JsonCodecs.int64)
        @Expect(YJson.fromJson("[]", codec: fastList).size, 0)
        @Expect(YJson.fromJson("[1,2,3,4,5,6]", codec: fastList).size, 6)
        let fastMap = JsonCodecs.stringMap(JsonCodecs.int64)
        @Expect(YJson.fromJson("{}", codec: fastMap).size, 0)
        @Expect(YJson.fromJson("{\"a\":1,\"b\":2}", codec: fastMap)["b"], 2)

        let stringOption = JsonCodecs.option(JsonCodecs.string)
        @Expect(YJson.fromJson("null", codec: stringOption).isNone())
        @Expect(YJson.fromJson("\"x\"", codec: stringOption).getOrThrow(), "x")
        @Expect(YJson.toJson(None<String>, codec: stringOption), "null")
        @Expect(YJson.toJson(Some("x"), codec: stringOption), "\"x\"")

        let compactInts = JsonCodecs.arrayList(JsonCodecs.int64)
        @Expect(YJson.toJson(directList, codec: compactInts), "[10,11]")
        @Expect(YJson.toJson(directList, codec: compactInts, options: JsonWriteOptions.pretty()).contains("\n"))
        @Expect(YJson.fromJson("[]", codec: compactInts).size, 0)
        @Expect(YJson.fromJson("[10,11]", codec: compactInts)[1], 11)

        let strings = ArrayList<String>(); strings.add("a"); strings.add("b")
        let compactStrings = JsonCodecs.arrayList(JsonCodecs.string)
        @Expect(YJson.toJson(strings, codec: compactStrings), "[\"a\",\"b\"]")
        @Expect(YJson.toJson(strings, codec: compactStrings, options: JsonWriteOptions.pretty()).contains("\n"))
        @Expect(YJson.fromJson("[]", codec: compactStrings).size, 0)
        @Expect(YJson.fromJson("[\"a\",\"b\"]", codec: compactStrings)[1], "b")

        let intsMap = HashMap<String, Int64>(); intsMap["a"] = 13; intsMap["b"] = 14
        let compactMap = JsonCodecs.stringMap(JsonCodecs.int64)
        @Expect(JsonNode.parse(YJson.toJson(intsMap, codec: compactMap)).asObject()["a"].asInt64(), 13)
        @Expect(YJson.toJson(intsMap, codec: compactMap, options: JsonWriteOptions.pretty()).contains("\n"))
        @Expect(YJson.fromJson("{}", codec: compactMap).size, 0)
        @Expect(YJson.fromJson("{\"a\":13,\"b\":14}", codec: compactMap)["b"], 14)
    }

    @TestCase
    func nodeAndTypedFacadesPreserveValues(): Unit {
        @Expect(JsonNode.parse("1").asInt64(), 1)
        @Expect(JsonNode.parse([b'2']).asInt64(), 2)
        @Expect(JsonStringValue("a\n").toJson(), "\"a\\n\"")
        @Expect(JsonNode.parse("{\"a\":1}").toJson(
            options: JsonWriteOptions.pretty(indent: "\t")).contains("\n\t\"a\""))
        @Expect(YJson.toJson(5, codec: JsonCodecs.int64), "5")
        @Expect(YJson.fromJson("6", codec: JsonCodecs.int64), 6)

        let output = YJsonMemoryOutputStream()
        YJson.writeJson(7, output, codec: JsonCodecs.int64)
        @Expect(output.toUtf8String(), "7")
        @Expect(YJson.fromJson(YJsonByteArrayInputStream("8"), codec: JsonCodecs.int64), 8)

        let option = JsonCodecs.option(JsonCodecs.int64)
        @Expect(YJson.toJson(Some(9), codec: option), "9")
        @Expect(YJson.toJson(None<Int64>, codec: option), "null")
        @Expect(YJson.fromJson("null", codec: option).isNone())

        let array = JsonCodecs.array(JsonCodecs.int64)
        @Expect(YJson.fromJson(YJson.toJson([1, 2], codec: array), codec: array)[1], 2)
        let list = ArrayList<Int64>(); list.add(3); list.add(4)
        let listCodec = JsonCodecs.arrayList(JsonCodecs.int64)
        @Expect(YJson.fromJson(YJson.toJson(list, codec: listCodec), codec: listCodec)[0], 3)
        let map = HashMap<String, Int64>(); map.add("a", 11); map.add("b", 12)
        let mapCodec = JsonCodecs.stringMap(JsonCodecs.int64)
        @Expect(YJson.fromJson(YJson.toJson(map, codec: mapCodec), codec: mapCodec)["b"], 12)
    }

    @TestCase
    func nodeCopyAndEquivalenceCoverEveryBuiltInKind(): Unit {
        let original = JsonNode.parse("{\"n\":null,\"b\":true,\"i\":1,\"f\":1.5," +
            "\"number\":9223372036854775808,\"s\":\"x\",\"a\":[1]}")
        let copied = deepCopyJsonNode(original)
        @Expect(jsonNodesEquivalent(original, copied))
        copied.asObject()["s"] = JsonStringValue("changed")
        @Expect(!jsonNodesEquivalent(original, copied))
        @Expect(jsonNodesEquivalent(JsonIntValue(1), JsonFloatValue(1.0)))
        @Expect(jsonNodesEquivalent(JsonIntValue(1), JsonNumberLiteralValue("1")))
        @Expect(!jsonNodesEquivalent(JsonIntValue(1), JsonStringValue("1")))
        @Expect(!jsonNodesEquivalent(JsonNode.parse("[1]"), JsonNode.parse("[]")))
        @Expect(!jsonNodesEquivalent(JsonNode.parse("{\"a\":1}"), JsonNode.parse("{}")))
        @Expect(!jsonNodesEquivalent(JsonNode.parse("{\"a\":1}"), JsonNode.parse("{\"a\":2}")))
    }

    @TestCase
    func tapeReaderWriterRoundtripReplayAndBulkPaths(): Unit {
        let tape = coverageRichTape()
        let reader = BackendTapeReaderV1(tape)
        reader.startObject()
        @Expect(reader.readNameId(["null"]), 0); @Expect(reader.tryReadNull())
        @Expect(reader.readName(), "bool"); @Expect(!reader.tryReadNull()); @Expect(reader.readBool())
        @Expect(reader.readName(), "int"); @Expect(reader.readInt64(), -7)
        @Expect(reader.readName(), "uint"); @Expect(reader.readUInt64(), UInt64.Max)
        @Expect(reader.readName(), "float"); @Expect(reader.readFloat64(), 1.5)
        @Expect(reader.readName(), "raw"); @Expect(reader.readBigInt(), BigInt.parse("12345678901234567890"))
        @Expect(reader.readName(), "text"); reader.skipString()
        @Expect(reader.readName(), "array"); reader.startArray(); @Expect(reader.readBool(), false)
        @Expect(reader.readNumberLiteral(), "2"); reader.endArray()
        @Expect(reader.readName(), "object"); reader.startObject(); @Expect(reader.readName(), "x")
        @Expect(reader.readString(), "y"); reader.endObject(); reader.endObject(); reader.expectEnd()

        let replayReader = BackendTapeReaderV1(tape)
        let replay = replayReader.readReplayValue(0)
        replayReader.expectEnd()
        @Expect(replay.rootStringField("text").getOrThrow(), "仓颉")
        @Expect(replay.rootStringField("missing").isNone())
        let excluding = replay.openObjectReaderExcluding("bool")
        excluding.startObject()
        var sawBool = false
        while (excluding.hasObjectField()) {
            if (excluding.readName() == "bool") { sawBool = true }
            excluding.skipValue()
        }
        excluding.endObject(); GeneratedSupportV1.finishReader(excluding); @Expect(!sawBool)
        @Expect(replay.materialize().asObject()["array"].asArray().size(), 2)
        replay.close(); @Expect(replay.isClosed())
        @AssertThrows[IllegalStateException](replay.materialize())

        let ints = ArrayList<Int64>(); ints.add(-1); ints.add(2)
        let intWriter = BackendTapeWriterV1(); @Expect(intWriter.tryWriteCompactInt64ArrayList(ints))
        @Expect(BackendTapeReaderV1(intWriter.finishTape()).readReplayValue(0).materialize().asArray().size(), 2)
        let strings = ArrayList<String>(); strings.add("a"); strings.add("b")
        let stringWriter = BackendTapeWriterV1(); @Expect(stringWriter.tryWriteCompactStringArrayList(strings))
        @Expect(BackendTapeReaderV1(stringWriter.finishTape()).readReplayValue(0).materialize().asArray()[1].asString(), "b")
        let values = HashMap<String, Int64>(); values.add("k", 3)
        let mapWriter = BackendTapeWriterV1(); @Expect(mapWriter.tryWriteCompactInt64Map(values))
        @Expect(BackendTapeReaderV1(mapWriter.finishTape()).readReplayValue(0).materialize().asObject()["k"].asInt64(), 3)

        let boundedWriter = BackendTapeWriterV1()
        boundedWriter.startArray(); boundedWriter.writeInt64(1); boundedWriter.writeInt64(2)
        boundedWriter.endArray()
        let boundedTape = boundedWriter.finishTape()
        let bounded = BackendTapeReaderV1(boundedTape)
        @Expect(bounded.readNode(3).asArray().size(), 2)
        bounded.expectEnd()
        let budgetError = @AssertThrows[JsonException](
            BackendTapeReaderV1(boundedTape).readNode(2))
        @Expect(budgetError.code, "work_limit_exceeded")
        @AssertThrows[IllegalArgumentException](
            BackendTapeReaderV1(boundedTape).readNode(0))
    }

    @TestCase
    func tapeContractsRejectInvalidOrderTypesDepthAndBounds(): Unit {
        @AssertThrows[JsonException](BackendTapeReaderV1([b'B', b'A', b'D']))
        let writer = BackendTapeWriterV1()
        @AssertThrows[JsonException](writer.writeName("x"))
        writer.startObject(); writer.writeName("x")
        @AssertThrows[JsonException](writer.endObject())
        writer.writeNull(); writer.endObject(); let tape = writer.finishTape()
        @AssertThrows[IllegalStateException](writer.writeNull())
        @AssertThrows[IllegalStateException](writer.finishTape())

        let wrong = BackendTapeReaderV1(tape)
        @AssertThrows[JsonException](wrong.startArray())
        let partial = BackendTapeReaderV1(tape); partial.startObject()
        @AssertThrows[JsonException](partial.endObject())
        @AssertThrows[IllegalArgumentException](BackendTapeReaderV1(tape).readReplayValue(-1))
        @AssertThrows[JsonException](BackendTapeReaderV1(tape).readReplayValue(1))

        let nestedWriter = BackendTapeWriterV1(); nestedWriter.startArray(); nestedWriter.startArray()
        nestedWriter.writeNull(); nestedWriter.endArray(); nestedWriter.endArray()
        let nested = BackendTapeReaderV1(nestedWriter.finishTape())
        @AssertThrows[JsonException](nested.skipValueWithDepth(1))
        @AssertThrows[IllegalArgumentException](BackendTapeReaderV1(tape).skipValueWithDepth(-1))

        let truncated = tape[..tape.size - 1]
        @AssertThrows[JsonException](BackendTapeReaderV1(truncated).skipValue())
    }

    @TestCase
    func tapeAlternatesPreserveNumericTypesAndStateBoundaries(): Unit {
        let empty = BackendTapeWriterV1()
        @AssertThrows[JsonException](empty.finishTape())

        let oneRoot = BackendTapeWriterV1()
        oneRoot.writeNull()
        @AssertThrows[JsonException](oneRoot.writeBool(true))

        let arrayName = BackendTapeWriterV1()
        arrayName.startArray()
        @AssertThrows[JsonException](arrayName.writeName("x"))
        @AssertThrows[JsonException](arrayName.endObject())
        arrayName.endArray()
        let _ = arrayName.finishTape()

        let objectValue = BackendTapeWriterV1()
        objectValue.startObject()
        @AssertThrows[JsonException](objectValue.writeNull())
        objectValue.writeName("x")
        @AssertThrows[JsonException](objectValue.writeName("y"))
        @AssertThrows[JsonException](objectValue.endArray())
        objectValue.writeNull()
        objectValue.endObject()
        let _ = objectValue.finishTape()

        let smallUnsigned = BackendTapeWriterV1()
        smallUnsigned.writeUInt64(7u64)
        let smallUnsignedReader = BackendTapeReaderV1(smallUnsigned.finishTape())
        @Expect(smallUnsignedReader.readUInt64(), 7u64)
        smallUnsignedReader.expectEnd()

        let largeUnsigned = BackendTapeWriterV1()
        largeUnsigned.writeUInt64(UInt64.Max)
        let largeUnsignedReader = BackendTapeReaderV1(largeUnsigned.finishTape())
        @Expect(largeUnsignedReader.readUInt64(), UInt64.Max)
        largeUnsignedReader.expectEnd()

        let numericLiteral = BackendTapeWriterV1()
        numericLiteral.writeNumberLiteral("42")
        let numericLiteralReader = BackendTapeReaderV1(numericLiteral.finishTape())
        @Expect(numericLiteralReader.readInt64(), 42)
        numericLiteralReader.expectEnd()

        let negative = BackendTapeWriterV1()
        negative.writeInt64(-1)
        @AssertThrows[JsonException](BackendTapeReaderV1(negative.finishTape()).readUInt64())

        let fraction = BackendTapeWriterV1()
        fraction.writeNumberLiteral("1.5")
        let fractionTape = fraction.finishTape()
        @AssertThrows[JsonException](BackendTapeReaderV1(fractionTape).readInt64())
        @AssertThrows[JsonException](BackendTapeReaderV1(fractionTape).readUInt64())

        let wrongKind = BackendTapeWriterV1()
        wrongKind.writeBool(false)
        let wrongTape = wrongKind.finishTape()
        @AssertThrows[JsonException](BackendTapeReaderV1(wrongTape).readInt64())
        @AssertThrows[JsonException](BackendTapeReaderV1(wrongTape).readUInt64())
        @AssertThrows[JsonException](BackendTapeReaderV1(wrongTape).readNumberLiteral())

        let nameWriter = BackendTapeWriterV1()
        nameWriter.startObject(); nameWriter.writeName("known"); nameWriter.writeInt64(1); nameWriter.endObject()
        let nameTape = nameWriter.finishTape()
        let matching = BackendTapeReaderV1(nameTape)
        matching.startObject(); @Expect(matching.readNameId(["known"]), 0); @Expect(matching.readInt64(), 1)
        matching.endObject(); matching.expectEnd()
        let unknown = BackendTapeReaderV1(nameTape)
        unknown.startObject(); @Expect(unknown.readNameId(["other"]), -1); unknown.skipValue()
        unknown.endObject(); unknown.expectEnd()
        let rejecting = BackendTapeReaderV1(nameTape,
            config: JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject))
        rejecting.startObject()
        @AssertThrows[JsonException](rejecting.readNameId(["other"]))

        let pendingName = BackendTapeReaderV1(nameTape)
        pendingName.startObject(); let _ = pendingName.readName()
        @AssertThrows[JsonException](pendingName.readName())
        let exhaustedName = BackendTapeReaderV1(nameTape)
        exhaustedName.startObject(); let _ = exhaustedName.readName(); exhaustedName.skipValue()
        @AssertThrows[JsonException](exhaustedName.readName())

        let emptyArrayWriter = BackendTapeWriterV1()
        emptyArrayWriter.startArray(); emptyArrayWriter.endArray()
        let emptyArrayTape = emptyArrayWriter.finishTape()
        let exhaustedArray = BackendTapeReaderV1(emptyArrayTape)
        exhaustedArray.startArray()
        @AssertThrows[JsonException](exhaustedArray.readNull())

        let unfinished = BackendTapeReaderV1(nameTape)
        @AssertThrows[JsonException](unfinished.expectEnd())
        unfinished.startObject()
        @AssertThrows[JsonException](unfinished.expectEnd())

        let trailingBytes = ArrayList<Byte>()
        trailingBytes.add(all: nameTape); trailingBytes.add(0u8)
        let trailingReader = BackendTapeReaderV1(trailingBytes.toArray())
        trailingReader.skipValue()
        @AssertThrows[JsonException](trailingReader.expectEnd())

        let invalidKind: Array<Byte> = [b'Y', b'J', b'T', b'1', 99u8]
        @AssertThrows[JsonException](BackendTapeReaderV1(invalidKind).skipValue())
        let truncatedBool: Array<Byte> = [b'Y', b'J', b'T', b'1', 1u8]
        @AssertThrows[JsonException](BackendTapeReaderV1(truncatedBool).skipValue())

        let replayPrevalidated = BackendTapeReaderV1(nameTape,
            replayBudgetPrevalidated: true)
        @Expect(replayPrevalidated.readReplayValue(1).materialize().asObject()["known"].asInt64(), 1)
        replayPrevalidated.expectEnd()

        let boundedRich = BackendTapeReaderV1(coverageRichTape())
        let richNode = boundedRich.readNode(16).asObject()
        @Expect(richNode["null"].isNull)
        @Expect(richNode["bool"].asBool())
        @Expect(richNode["int"].asInt64(), -7)
        @Expect(richNode["uint"].asUInt64(), UInt64.Max)
        @Expect(richNode["float"].asFloat64(), 1.5)
        @Expect(richNode["text"].asString(), "仓颉")
        boundedRich.expectEnd()

        let twiceWriter = BackendTapeWriterV1(); twiceWriter.writeNull()
        let twice = BackendTapeReaderV1(twiceWriter.finishTape())
        twice.readNull()
        @AssertThrows[JsonException](twice.readNull())
        @AssertThrows[JsonException](BackendTapeReaderV1(emptyArrayTape).endArray())
        let wrongContainer = BackendTapeReaderV1(nameTape)
        wrongContainer.startObject()
        @AssertThrows[JsonException](wrongContainer.hasArrayItem())
        let unnamedValue = BackendTapeReaderV1(nameTape)
        unnamedValue.startObject()
        @AssertThrows[JsonException](unnamedValue.readInt64())
    }

    @TestCase
    func fastReaderCompactProbesAreTransactionalAcrossGrammarShapes(): Unit {
        for (text in ["", " ", "\n", "\r", "\t", "}"]) {
            @Expect(!JsonFastReader(coverageBytes(text)).tryNextRawObjectFieldCompact(true))
        }
        @Expect(JsonFastReader(coverageBytes("\"a\":1")).tryNextRawObjectFieldCompact(true))
        @Expect(!JsonFastReader(coverageBytes("x")).tryNextRawObjectFieldCompact(true))
        @Expect(!JsonFastReader(coverageBytes("x")).tryNextRawObjectFieldCompact(false))
        @Expect(!JsonFastReader(coverageBytes(",")).tryNextRawObjectFieldCompact(false))
        @Expect(!JsonFastReader(coverageBytes(", ")).tryNextRawObjectFieldCompact(false))
        @Expect(JsonFastReader(coverageBytes(",\"a\":1")).tryNextRawObjectFieldCompact(false))

        @Expect(JsonFastReader(coverageBytes(" {")).tryStartRawObjectCompact())
        @Expect(!JsonFastReader(coverageBytes(" [")).tryStartRawObjectCompact())
        @Expect(JsonFastReader(coverageBytes("}")).tryEndRawObject())
        @Expect(!JsonFastReader(coverageBytes("")).tryEndRawObject())
        @Expect(!JsonFastReader(coverageBytes("]")).tryEndRawObject())
        @Expect(JsonFastReader(coverageBytes(" [")).tryStartRawArrayCompact())
        @Expect(!JsonFastReader(coverageBytes(" {")).tryStartRawArrayCompact())
        @Expect(JsonFastReader(coverageBytes("]")).tryEndRawArrayCompact())
        @Expect(!JsonFastReader(coverageBytes("")).tryEndRawArrayCompact())
        @Expect(!JsonFastReader(coverageBytes("}")).tryEndRawArrayCompact())

        for (text in ["", " ", "\n", "\r", "\t", "]"]) {
            @Expect(!JsonFastReader(coverageBytes(text)).tryNextRawArrayItemCompact(true))
        }
        @Expect(JsonFastReader(coverageBytes("1")).tryNextRawArrayItemCompact(true))
        @Expect(!JsonFastReader(coverageBytes("1")).tryNextRawArrayItemCompact(false))
        @Expect(JsonFastReader(coverageBytes(",1")).tryNextRawArrayItemCompact(false))

        @Expect(!JsonFastReader(coverageBytes("]")).nextRawArrayItem(true))
        @Expect(JsonFastReader(coverageBytes("1")).nextRawArrayItem(true))
        @Expect(!JsonFastReader(coverageBytes(" ]")).nextRawArrayItem(true))
        @Expect(JsonFastReader(coverageBytes(",1")).nextRawArrayItem(false))
        @Expect(JsonFastReader(coverageBytes(", 1")).nextRawArrayItem(false))
        @Expect(!JsonFastReader(coverageBytes("]")).nextRawArrayItem(false))
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("1")).nextRawArrayItem(false))

        @Expect(!JsonFastReader(coverageBytes("}")).nextRawObjectField(true))
        @Expect(JsonFastReader(coverageBytes("\"a\":1")).nextRawObjectField(true))
        @Expect(!JsonFastReader(coverageBytes(" }")).nextRawObjectField(true))
        @Expect(JsonFastReader(coverageBytes(",\"a\":1")).nextRawObjectField(false))
        @Expect(JsonFastReader(coverageBytes(", \"a\":1")).nextRawObjectField(false))
        @Expect(!JsonFastReader(coverageBytes("}")).nextRawObjectField(false))
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("\"a\":1")).nextRawObjectField(false))

        let exactName = JsonFastReader(coverageBytes("\"name\":"))
        @Expect(exactName.tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        let commaName = JsonFastReader(coverageBytes(",\"name\":"))
        @Expect(commaName.tryReadRawAsciiNameTokenBytes(coverageBytes("name"), false))
        @Expect(!JsonFastReader(coverageBytes("\"name\":"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), false))
        @Expect(!JsonFastReader(coverageBytes(",\"name\":"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        @Expect(!JsonFastReader(coverageBytes("\"nam\":"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        @Expect(!JsonFastReader(coverageBytes("xname\":"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        @Expect(!JsonFastReader(coverageBytes("\"nXme\":"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        @Expect(!JsonFastReader(coverageBytes("\"nameX:"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
        @Expect(!JsonFastReader(coverageBytes("\"name\"X"))
            .tryReadRawAsciiNameTokenBytes(coverageBytes("name"), true))
    }

    @TestCase
    func fastReaderTokensAndSkipCoverFallbackAndMalformedBoundaries(): Unit {
        for (text in ["", " ", "1"]) {
            @Expect(!JsonFastReader(coverageBytes(text)).tryReadRawAsciiStringToken())
        }
        let ascii = JsonFastReader(coverageBytes("\"abcd\""))
        @Expect(ascii.tryReadRawAsciiStringToken())
        @Expect(ascii.currentRawTokenSize(), 4)
        @Expect(ascii.currentRawTokenAsciiString(), "abcd")
        @Expect(ascii.currentRawTokenDigit(0), -1)

        let escaped = JsonFastReader(coverageBytes("\"a\\nb\""))
        @Expect(!escaped.tryReadRawAsciiStringToken())
        @Expect(escaped.readRawString(), "a\nb")
        let unicode = JsonFastReader(coverageBytes("\"仓\""))
        @Expect(!unicode.tryReadRawAsciiStringToken())
        @Expect(unicode.readRawString(), "仓")
        @AssertThrows[JsonException](JsonFastReader([b'\"', 1u8, b'\"']).tryReadRawAsciiStringToken())
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("\"unterminated"))
            .tryReadRawAsciiStringToken())

        let firstWidth = JsonFastReader(coverageBytes("\"ab\""))
        @Expect(firstWidth.tryReadRawAsciiStringTokenSize2(2, 4))
        let secondWidth = JsonFastReader(coverageBytes("\"abcd\""))
        @Expect(secondWidth.tryReadRawAsciiStringTokenSize2(2, 4))
        @Expect(!JsonFastReader(coverageBytes("x")).tryReadRawAsciiStringTokenSize2(2, 4))
        @Expect(!JsonFastReader(coverageBytes("\"abc\"")).tryReadRawAsciiStringTokenSize2(2, 4))
        @Expect(!JsonFastReader(coverageBytes("\"a\\n\"")).tryReadRawAsciiStringTokenSize2(3, 5))

        for (text in ["", " ", "true", "\"x\""]) {
            @Expect(!JsonFastReader(coverageBytes(text)).tryReadRawNumberToken())
        }
        for (text in ["0", "-1", "12", "1.25", "1e+2", "1E-2"]) {
            let number = JsonFastReader(coverageBytes(text))
            @Expect(number.tryReadRawNumberToken())
            @Expect(number.currentRawTokenSize(), text.size)
        }
        let digits = JsonFastReader(coverageBytes("1234"))
        @Expect(digits.tryReadRawNumberToken())
        @Expect(digits.currentRawTokenDigit(0), 1)
        @Expect(digits.currentRawTokenTwoDigits(1), 23)
        @Expect(digits.currentRawTokenFourDigits(0), 1234)
        let invalidDigits = JsonFastReader(coverageBytes("12x4"))
        @Expect(invalidDigits.tryReadRawNumberToken())
        @Expect(invalidDigits.currentRawTokenTwoDigits(1), -1)
        @Expect(invalidDigits.currentRawTokenFourDigits(0), -1)

        for (text in ["01", "1.", "1e", "1e+"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).tryReadRawNumberToken())
        }
        for (text in ["null", "true", "false", "\"x\"", "0", "-1", "1.25", "1e+2",
            "[]", "[1,true]", "{}", "{\"a\":[null]}"]) {
            let reader = JsonFastReader(coverageBytes(text))
            reader.skipRaw()
            reader.expectEnd()
        }
        for (text in ["", " ", "?", "-", "1.", "1e", "[", "[1", "{", "{\"a\":1"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).skipRaw())
        }
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("[[0]]")).skipRawWithDepth(1))
        let bounded = JsonFastReader(coverageBytes("[0]"))
        bounded.skipRawWithDepth(1)
        bounded.expectEnd()
    }

    @TestCase
    func fastReaderUnicodeAndNumericRangesPreserveStrictBoundaries(): Unit {
        let encoded = [
            "\"\\\"\"", "\"\\\\\"", "\"\\/\"", "\"\\b\"", "\"\\f\"",
            "\"\\n\"", "\"\\r\"", "\"\\t\"", "\"\\u0030\"", "\"\\u00a2\"",
            "\"\\u4ED3\"", "\"\\uD83D\\uDE00\"", "\"¢\"", "\"仓\"", "\"😀\""
        ]
        let decoded = ["\"", "\\", "/", "\b", "\f", "\n", "\r", "\t",
            "0", "¢", "仓", "😀", "¢", "仓", "😀"]
        for (index in 0..encoded.size) {
            let reader = JsonFastReader(coverageBytes(encoded[index]))
            @Expect(reader.readRawString(), decoded[index])
            reader.expectEnd()
        }

        for (text in ["\"\\x\"", "\"\\u12\"", "\"\\u12x4\"", "\"\\uD800\"",
            "\"\\uD800\\u0041\"", "\"\\uDC00\"", "\"unterminated"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).readRawString())
        }
        let invalidUtf8: Array<Array<Byte>> = [
            [b'\"', 0x80u8, b'\"'], [b'\"', 0xC2u8, b'\"'],
            [b'\"', 0xE0u8, 0x9Fu8, 0x80u8, b'\"'],
            [b'\"', 0xEDu8, 0xA0u8, 0x80u8, b'\"'],
            [b'\"', 0xF0u8, 0x8Fu8, 0x80u8, 0x80u8, b'\"'],
            [b'\"', 0xF4u8, 0x90u8, 0x80u8, 0x80u8, b'\"']
        ]
        for (bytes in invalidUtf8) {
            @AssertThrows[JsonException](JsonFastReader(bytes).readRawString())
        }

        for (text in ["-2147483649", "2147483648"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).readRawInt32())
        }
        for (text in ["-32769", "32768"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).readRawInt16())
        }
        for (text in ["-129", "128"]) {
            @AssertThrows[JsonException](JsonFastReader(coverageBytes(text)).readRawInt8())
        }
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("4294967296")).readRawUInt32())
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("65536")).readRawUInt16())
        @AssertThrows[JsonException](JsonFastReader(coverageBytes("256")).readRawUInt8())
        @AssertThrows[IllegalArgumentException](JsonFastReader(coverageBytes("0")).skipRawWithDepth(-1))

        let adopted = JsonFastReader(coverageBytes("1234"))
        adopted.adoptRawNumberToken(0, 4, UInt64(Int64.Max) + 1u64, 7u64 | (2u64 << 8))
        @Expect(adopted.currentRawTokenNumberNegative())
        @Expect(adopted.currentRawTokenNumberHasExponent())
        @Expect(!adopted.currentRawTokenNumberSmallUnscaledValid())
        @Expect(adopted.currentRawTokenNumberScale(), 2)
    }

    @TestCase
    func typedGeneratedProviderAndDirectReplayKeepContractBoundaries(): Unit {
        let semantic = CoverageSemanticIntCodec()
        let tapeWriter = BackendTapeWriterV1()
        semantic.write(7, tapeWriter)
        let tapeReader = BackendTapeReaderV1(tapeWriter.finishTape())
        @Expect(semantic.read(tapeReader), 7)
        tapeReader.expectEnd()
        @Expect(coverageJsonErrorCode({ => let _ = readJsonFastWith(
            semantic, GeneratedSupportV1.newFastReader("1")) }), "codec_contract")

        let typedFast = generatedCodecV1Of<Int64>()
        @Expect(readJsonFastWith(typedFast, GeneratedSupportV1.newFastReader("8")), 8)

        let value = CoverageReifiedValue(9)
        @Expect(YJson.toJson(value), "9")
        @Expect(YJson.fromJson<CoverageReifiedValue>("10").value, 10)
        @Expect(YJson.fromJson<CoverageReifiedValue>(coverageBytes("11")).value, 11)
        @Expect(YJson.fromJson<CoverageReifiedValue>(YJsonByteArrayInputStream("12")).value, 12)
        @Expect(coverageJsonErrorCode({ =>
            let _ = YJson.fromJson<CoverageReifiedValue>("-1")
        }), "coverage_value_rejected")

        let reified = generatedCodecV1Of<CoverageReifiedValue>()
        let fastWrong = GeneratedSupportV1.newFastReader("-2")
        @Expect(coverageJsonErrorCode({ =>
            let _ = GeneratedSupportV1.readWith(reified, fastWrong)
        }), "coverage_value_rejected")
        let fastRight = GeneratedSupportV1.newFastReader("13")
        @Expect(GeneratedSupportV1.readWith(reified, fastRight).value, 13)
        fastRight.expectEnd()

        let direct: JsonReader = JsonDirectReader(
            "{\"kind\":\"cat\",\"keep\":1,\"drop\":2}")
        @Expect(GeneratedSupportV1.readOptions(direct).maxDepth, JsonReadOptions.defaults.maxDepth)
        let replay = GeneratedSupportV1.captureValue(direct, 0)
        GeneratedSupportV1.finishReader(direct)
        @Expect(replay.rootStringField("kind").getOrThrow(), "cat")
        @Expect(replay.rootStringField("missing").isNone())
        let excluding = replay.openObjectReaderExcluding("drop")
        @Expect(excluding.readNode().asObject().get("drop").isNone())
        GeneratedSupportV1.finishReader(excluding)
        @Expect(replay.materialize().asObject()["keep"].asInt64(), 1)
        replay.close(); @Expect(replay.isClosed())
        @AssertThrows[IllegalStateException](replay.rootStringField("kind"))
        @AssertThrows[IllegalStateException](replay.openObjectReaderExcluding("drop"))
        @AssertThrows[IllegalStateException](replay.materialize())
    }

    @TestCase
    func builtInScalarCodecsCoverRangeAndAlternateNumberForms(): Unit {
        @Expect(YJson.fromJson("127", codec: JsonCodecs.int8), 127i8)
        @AssertThrows[JsonException](YJson.fromJson("128", codec: JsonCodecs.int8))
        @Expect(YJson.fromJson("255", codec: JsonCodecs.uint8), 255u8)
        @AssertThrows[JsonException](YJson.fromJson("256", codec: JsonCodecs.uint8))
        @Expect(decodeBigIntLike(JsonStringValue("123")), BigInt.parse("123"))
        @Expect(decodeBigIntLike(JsonNumberLiteralValue("9223372036854775808")),
            BigInt.parse("9223372036854775808"))
        @AssertThrows[JsonException](decodeBigIntLike(JsonBoolValue(true)))
        @Expect(decodeDecimalLike(JsonStringValue("1.25")), Decimal.parse("1.25"))
        @AssertThrows[JsonException](decodeDecimalLike(JsonBoolValue(false)))
        @Expect(decodeRuneText("仓").toString(), "仓")
        @AssertThrows[JsonException](decodeRuneText(""))
    }

    @TestCase
    func builtInProvidersCoverFastAndConfiguredSemanticPaths(): Unit {
        let configured = JsonReadOptions(maxDepth: 257)
        @Expect(YJson.fromJson("true", codec: JsonCodecs.bool, options: configured), true)
        @Expect(YJson.fromJson("-9223372036854775808", codec: JsonCodecs.int64, options: configured), Int64.Min)
        @Expect(YJson.fromJson("2147483647", codec: JsonCodecs.int32, options: configured), Int32.Max)
        @Expect(YJson.fromJson("-32768", codec: JsonCodecs.int16, options: configured), Int16.Min)
        @Expect(YJson.fromJson("-128", codec: JsonCodecs.int8, options: configured), Int8.Min)
        @Expect(YJson.fromJson("18446744073709551615", codec: JsonCodecs.uint64, options: configured), UInt64.Max)
        @Expect(YJson.fromJson("4294967295", codec: JsonCodecs.uint32, options: configured), UInt32.Max)
        @Expect(YJson.fromJson("65535", codec: JsonCodecs.uint16, options: configured), UInt16.Max)
        @Expect(YJson.fromJson("255", codec: JsonCodecs.uint8, options: configured), UInt8.Max)
        @Expect(YJson.fromJson("1.25", codec: JsonCodecs.float64, options: configured), 1.25)
        @Expect(Float64(YJson.fromJson("1.5", codec: JsonCodecs.float32, options: configured)), 1.5)
        @Expect(Float64(YJson.fromJson("2.0", codec: JsonCodecs.float16, options: configured)), 2.0)
        @Expect(YJson.fromJson("\"x\"", codec: JsonCodecs.string, options: configured), "x")
        @Expect(YJson.fromJson("\"仓\"", codec: JsonCodecs.rune, options: configured).toString(), "仓")
        @Expect(YJson.fromJson("9223372036854775808", codec: JsonCodecs.bigInt, options: configured),
            BigInt.parse("9223372036854775808"))
        @Expect(YJson.fromJson("1.25", codec: JsonCodecs.decimal, options: configured), Decimal.parse("1.25"))
        let date = YJson.fromJson("\"2024-01-02T03:04:05Z\"", codec: JsonCodecs.rfc3339DateTime, options: configured)
        @Expect(YJson.toJson(date, codec: JsonCodecs.rfc3339DateTime, options: JsonWriteOptions.pretty()),
            "\"2024-01-02T03:04:05Z\"")

        @Expect(YJson.toJson(1i32), "1")
        @Expect(YJson.fromJson<Int16>("2"), 2i16)
        @Expect(YJson.toJson(3u8), "3")
        @Expect(YJson.fromJson<Float32>("4.5"), 4.5f32)
        @Expect(YJson.toJson("text"), "\"text\"")
        @Expect(YJson.fromJson<Rune>("\"界\"").toString(), "界")

        @AssertThrows[JsonException](YJson.fromJson("2147483648", codec: JsonCodecs.int32, options: configured))
        @AssertThrows[JsonException](YJson.fromJson("32768", codec: JsonCodecs.int16, options: configured))
        @AssertThrows[JsonException](YJson.fromJson("4294967296", codec: JsonCodecs.uint32, options: configured))
        @AssertThrows[JsonException](YJson.fromJson("65536", codec: JsonCodecs.uint16, options: configured))
    }

    @TestCase
    func generatedSupportFactoriesExerciseTheNarrowProtocol(): Unit {
        @Expect(GeneratedSupportV1.protocolVersion(), 1)
        GeneratedSupportV1.requireProtocolVersion(1)
        @AssertThrows[JsonException](GeneratedSupportV1.requireProtocolVersion(2))

        let reader = GeneratedSupportV1.newFastReader(
            "[null,true,\"x\",-8,-16,-32,-64,8,16,32,64,{\"drop\":[1]}]")
        reader.startRawArray()
        var first = true
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.tryReadRawNull()); first = false
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawBool());
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawString(), "x")
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawInt8(), -8i8)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawInt16(), -16i16)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawInt32(), -32i32)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawInt64(), -64)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawUInt8(), 8u8)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawUInt16(), 16u16)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawUInt32(), 32u32)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); @Expect(reader.readRawUInt64(), 64u64)
        @Expect(reader.hasRawArrayItem(first)); reader.beforeRawArrayItem(first); reader.skipRawWithDepth(3)
        @Expect(!reader.hasRawArrayItem(first)); reader.endRawArray(); reader.expectEnd()
        @Expect(reader.suggestRawCollectionCapacity() >= 0)
        @Expect(reader.suggestRawArrayCapacity() >= 0)
        @Expect(reader.suggestRawObjectCapacity() >= 0)

        let mediumCapacityInput = StringBuilder()
        for (_ in 0..3200) { mediumCapacityInput.append("x") }
        @Expect(GeneratedSupportV1.newFastReader(
            mediumCapacityInput.toString()).suggestRawCollectionCapacity(), 51)
        let cappedCapacityInput = StringBuilder()
        for (_ in 0..5000) { cappedCapacityInput.append("x") }
        @Expect(GeneratedSupportV1.newFastReader(
            cappedCapacityInput.toString()).suggestRawCollectionCapacity(), 64)

        let bytes: Array<Byte> = [b'{', b'"', b'a', b'"', b':', b'1', b'}']
        let semantic = GeneratedSupportV1.newSemanticReader(bytes,
            JsonReadOptions(maxDepth: 257))
        semantic.startObject(); @Expect(semantic.readName(), "a"); @Expect(semantic.readInt64(), 1)
        semantic.endObject(); GeneratedSupportV1.finishReader(semantic)
        let semanticText = GeneratedSupportV1.newSemanticReader("[true]",
            JsonReadOptions(maxDepth: 257))
        semanticText.startArray(); @Expect(semanticText.hasArrayItem()); @Expect(semanticText.readBool())
        semanticText.endArray(); GeneratedSupportV1.finishReader(semanticText)

        let writer = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(writer))
        GeneratedSupportV1.writeCompactObjectBegin(writer)
        @Expect(!GeneratedSupportV1.writeCompactEntryString(writer, true, "s", "x"))
        @Expect(!GeneratedSupportV1.writeCompactEntryBool(writer, false, "b", true))
        @Expect(!GeneratedSupportV1.writeCompactEntryInt64(writer, false, "i", 7))
        GeneratedSupportV1.writeCompactObjectEnd(writer)
        @Expect(writer.finishString(), "{\"s\":\"x\",\"b\":true,\"i\":7}")

        let escapedIntWriter = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(escapedIntWriter))
        GeneratedSupportV1.writeCompactObjectBegin(escapedIntWriter)
        @Expect(!GeneratedSupportV1.writeCompactEntryInt64(
            escapedIntWriter, true, "first\nfield", 1))
        @Expect(!GeneratedSupportV1.writeCompactEntryInt64(
            escapedIntWriter, false, "second\tfield", 2))
        GeneratedSupportV1.writeCompactObjectEnd(escapedIntWriter)
        @Expect(escapedIntWriter.finishString(),
            "{\"first\\nfield\":1,\"second\\tfield\":2}")

        let legacyArrayWriter = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(legacyArrayWriter))
        jsonWriteGeneratedCompactArrayBegin(legacyArrayWriter)
        legacyArrayWriter.writeRawNull()
        jsonWriteGeneratedCompactComma(legacyArrayWriter)
        legacyArrayWriter.writeRawNull()
        jsonWriteGeneratedCompactArrayEnd(legacyArrayWriter)
        @Expect(legacyArrayWriter.finishString(), "[null,null]")

        let legacyObjectWriter = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(legacyObjectWriter))
        jsonWriteGeneratedCompactObjectBegin(legacyObjectWriter)
        @Expect(!jsonWriteGeneratedCompactObjectEntryName(legacyObjectWriter, true, "value"))
        legacyObjectWriter.writeRawNull()
        jsonWriteGeneratedCompactObjectEnd(legacyObjectWriter)
        @Expect(legacyObjectWriter.finishString(), "{\"value\":null}")

        let stringValues = ArrayList<String>()
        stringValues.add("a")
        stringValues.add("b")
        let stringListWriter = JsonDirectWriter()
        __yJsonWriteStringArrayList(stringValues, stringListWriter)
        @Expect(stringListWriter.finishString(), "[\"a\",\"b\"]")

        let intValues = HashMap<String, Int64>()
        intValues["value"] = 7
        let intMapWriter = JsonDirectWriter()
        __yJsonWriteInt64HashMap(intValues, intMapWriter)
        @Expect(JsonNode.parse(intMapWriter.finishString()).asObject()["value"].asInt64(), 7)

        let cursorWriter = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(cursorWriter))
        let cursor = GeneratedSupportV1.writeCursor(cursorWriter)
        cursor.reserveRawCollectionCapacity(2)
        cursor.writeRawBeginArray(); cursor.writeRawByte(b'1'); cursor.writeRawByte(b',')
        cursor.writeRawByte(b'n'); cursor.writeRawByte(b'u'); cursor.writeRawByte(b'l'); cursor.writeRawByte(b'l')
        cursor.writeRawEndArray()
        @Expect(cursorWriter.finishString(), "[1,null]")
    }

    @TestCase
    func valueKindsConfigsAndMutableNodeConveniencesCoverAllCases(): Unit {
        let kinds = [JsonKind.Null, JsonKind.Boolean, JsonKind.Number,
            JsonKind.String, JsonKind.Array, JsonKind.Object]
        for (left in 0..kinds.size) {
            for (right in 0..kinds.size) {
                @Expect(kinds[left] == kinds[right], left == right)
                @Expect(kinds[left] != kinds[right], left != right)
            }
        }

        @AssertThrows[IllegalArgumentException](JsonReadOptions(maxDepth: 0))
        @AssertThrows[IllegalArgumentException](JsonReadOptions(maxBufferedValueBytes: -1))
        @AssertThrows[IllegalArgumentException](JsonReadOptions(maxStringBytes: -1))
        @AssertThrows[IllegalArgumentException](JsonReadOptions(maxInputBytes: -1))
        let rejecting = JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject, duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        @Expect(rejecting.rejectsUnknownFields())
        @Expect(rejecting.rejectsDuplicateKeys())
        @Expect(!JsonReadOptions.defaults.rejectsUnknownFields())
        @Expect(JsonReadOptions.defaults.rejectsDuplicateKeys())
        @Expect(!jsonReadOptionsUsesDefaultFastPath(rejecting))

        let locationBytes = coverageBytes("a\nbc\n")
        @Expect(jsonLineFromUtf8Bytes(locationBytes, -1), -1)
        @Expect(jsonColumnFromUtf8Bytes(locationBytes, -1), -1)
        @Expect(jsonLineFromUtf8Bytes(locationBytes, 99), 3)
        @Expect(jsonColumnFromUtf8Bytes(locationBytes, 4), 3)
        let newlines = ArrayList<Int64>(); newlines.add(1); newlines.add(4)
        @Expect(jsonStreamLineAt(newlines, -1), -1)
        @Expect(jsonStreamLineAt(newlines, 4), 2)
        @Expect(jsonStreamColumnAt(newlines, -1), -1)
        @Expect(jsonStreamColumnAt(newlines, 4), 3)
        @Expect(jsonStreamColumnAt(ArrayList<Int64>(), 4), 5)

        let object = JsonObject()
        object["bool"] = true; object["int"] = 2; object["float"] = 3.5
        object["rune"] = r'界'; object["text"] = "x"; object["array"] = [JsonNode.nullValue]
        object["node"] = JsonNode.int64(9)
        @Expect(object.contains("bool")); @Expect(object["bool"].asBool())
        @Expect(object["int"].asInt64(), 2); @Expect(object["float"].asFloat64(), 3.5)
        @Expect(object["rune"].asString(), "界"); @Expect(object["array"].asArray().size(), 1)
        @Expect(object.size(), 7); @Expect(!object.isNull)
        @Expect(object.remove("node").isSome()); @Expect(object.remove("missing").isNone())
        @AssertThrows[JsonException](object["missing"])

        let array = JsonArray([JsonNode.nullValue, JsonNode.nullValue, JsonNode.nullValue, JsonNode.nullValue,
            JsonNode.nullValue, JsonNode.nullValue, JsonNode.nullValue])
        array[0] = JsonNode.boolean(false); array[1] = true; array[2] = 2; array[3] = 3.5
        array[4] = r'仓'; array[5] = "text"; array[6] = [JsonNode.int64(1)]
        @Expect(!array[0].asBool()); @Expect(array[2].asInt64(), 2); @Expect(array[6].asArray().size(), 1)
        array.insert(0, JsonNode.string("first")); @Expect(array.removeAt(0).asString(), "first")
        @Expect(array.size(), 7); @Expect(array.get(99).isNone())
        @AssertThrows[JsonException](array.set(-1, JsonNode.nullValue))
        @AssertThrows[JsonException](array.insert(99, JsonNode.nullValue))
        @AssertThrows[JsonException](array.removeAt(99))
        @AssertThrows[JsonException](array[99])
    }

    @TestCase
    func generatedNameMatchingCoversSpecializedWidthsAndMismatches(): Unit {
        let reader = GeneratedSupportV1.newFastReader(
            "{\"abc\":1,\"abcd\":2,\"abcdef\":3,\"abcdefg\":4,\"abcdefghijk\":5,\"\":6,\"xy\":7}")
        let candidates = [
            [coverageBytes("xbc"), coverageBytes("axc"), coverageBytes("abc")],
            [coverageBytes("xbcd"), coverageBytes("abxd"), coverageBytes("abcd")],
            [coverageBytes("xbcdef"), coverageBytes("abcdxf"), coverageBytes("abcdef")],
            [coverageBytes("xbcdefg"), coverageBytes("abcdefx"), coverageBytes("abcdefg")],
            [coverageBytes("xbcdefghijk"), coverageBytes("abcdefghijx"), coverageBytes("abcdefghijk")],
            [coverageBytes("x"), coverageBytes("")],
            [coverageBytes("x"), coverageBytes("xz"), coverageBytes("xy")]
        ]
        reader.startRawObject(); var first = true
        for (index in 0..candidates.size) {
            @Expect(reader.hasRawObjectField(first))
            let expected = if (index == 5) { -1 } else { candidates[index].size - 1 }
            @Expect(reader.readRawNameIdBytes(first, candidates[index]), expected)
            @Expect(reader.readRawInt64(), index + 1)
            first = false
        }
        @Expect(!reader.hasRawObjectField(first)); reader.endRawObject(); reader.expectEnd()

        let compact = GeneratedSupportV1.newFastReader("{\"name\":1}")
        compact.startRawObject(); @Expect(compact.hasRawObjectField(true))
        @Expect(!compact.tryReadRawCompactNameTokenBytes(true, coverageBytes("miss")))
        @Expect(compact.tryReadRawCompactNameTokenBytes(true, coverageBytes("name")))
        @Expect(compact.readRawInt64(), 1); @Expect(!compact.hasRawObjectField(false))
        compact.endRawObject(); compact.expectEnd()
    }

    @TestCase
    func incrementalDirectReaderCoversSlowNumbersNamesStringsAndBoundedValues(): Unit {
        let signed = ["0", "-0", "7", "-7", "9223372036854775807", "-9223372036854775808"]
        let signedExpected: Array<Int64> = [0, 0, 7, -7, Int64.Max, Int64.Min]
        for (index in 0..signed.size) {
            let reader = JsonDirectReader(YJsonByteArrayInputStream(signed[index]))
            @Expect(reader.readInt64(), signedExpected[index])
            reader.expectEnd()
        }
        for (invalid in ["", "-", "01", "1.0", "1e2", "9223372036854775808", "-9223372036854775809"]) {
            @AssertThrows[JsonException](JsonDirectReader(
                YJsonByteArrayInputStream(invalid)).readInt64())
        }

        let unsigned = ["0", "7", "18446744073709551615"]
        let unsignedExpected: Array<UInt64> = [0u64, 7u64, UInt64.Max]
        for (index in 0..unsigned.size) {
            let reader = JsonDirectReader(YJsonByteArrayInputStream(unsigned[index]))
            @Expect(reader.readUInt64(), unsignedExpected[index])
            reader.expectEnd()
        }
        for (invalid in ["-1", "01", "1.0", "18446744073709551616"]) {
            @AssertThrows[JsonException](JsonDirectReader(
                YJsonByteArrayInputStream(invalid)).readUInt64())
        }

        let manyNames = Array<String>(64, repeat: "")
        for (index in 0..64) { manyNames[index] = "field_${index}" }
        manyNames[63] = "仓"
        let many = JsonDirectReader(YJsonByteArrayInputStream("{\"field_62\":1,\"仓\":2,\"unknown\":3}"))
        many.startObject()
        @Expect(many.readNameId(manyNames), 62); @Expect(many.readInt64(), 1)
        @Expect(many.readNameId(manyNames), 63); @Expect(many.readInt64(), 2)
        @Expect(many.readNameId(manyNames), -1); @Expect(many.readInt64(), 3)
        many.endObject(); many.expectEnd()

        let escapedCandidates = ["quote\"", "slash\\", "line\n", "tab\t", "仓"]
        let escaped = JsonDirectReader(YJsonByteArrayInputStream(
            "{\"quote\\\"\":1,\"slash\\\\\":2,\"line\\n\":3,\"tab\\t\":4,\"\\u4ed3\":5}"))
        escaped.startObject()
        for (index in 0..escapedCandidates.size) {
            @Expect(escaped.readNameId(escapedCandidates), index)
            @Expect(escaped.readInt64(), index + 1)
        }
        escaped.endObject(); escaped.expectEnd()

        // Keep every candidate ASCII so both the incremental and contiguous
        // readers take their mask-based matcher instead of materializing the
        // field name. Exercise every JSON escape and the non-ASCII mismatch.
        let asciiCandidates = ["quote\"", "slash\\", "solidus/", "back\b", "form\f",
            "line\n", "return\r", "tab\t", "unicodeA"]
        let escapedAsciiObject = "{\"quote\\\"\":1,\"slash\\\\\":2,\"solidus\\/\":3," +
            "\"back\\b\":4,\"form\\f\":5,\"line\\n\":6,\"return\\r\":7," +
            "\"tab\\t\":8,\"unicode\\u0041\":9,\"unicode\\u4ed3\":10}"
        let incrementalNames = JsonDirectReader(YJsonByteArrayInputStream(escapedAsciiObject))
        incrementalNames.startObject()
        for (index in 0..asciiCandidates.size) {
            @Expect(incrementalNames.readNameId(asciiCandidates), index)
            @Expect(incrementalNames.readInt64(), index + 1)
        }
        @Expect(incrementalNames.readNameId(asciiCandidates), -1)
        @Expect(incrementalNames.readInt64(), 10)
        incrementalNames.endObject(); incrementalNames.expectEnd()

        let cursorNames = JsonDirectReader(escapedAsciiObject)
        cursorNames.startObject()
        for (index in 0..asciiCandidates.size) {
            @Expect(cursorNames.readNameId(asciiCandidates), index)
            @Expect(cursorNames.readInt64(), index + 1)
        }
        @Expect(cursorNames.readNameId(asciiCandidates), -1)
        @Expect(cursorNames.readInt64(), 10)
        cursorNames.endObject(); cursorNames.expectEnd()

        let asciiCandidateBytes = Array<Array<Byte>>(asciiCandidates.size, repeat: [])
        for (index in 0..asciiCandidates.size) {
            asciiCandidateBytes[index] = coverageBytes(asciiCandidates[index])
        }
        let contiguousNames = JsonFastReader(coverageBytes(escapedAsciiObject))
        contiguousNames.startRawObject(); var firstAsciiName = true
        for (index in 0..asciiCandidates.size) {
            @Expect(contiguousNames.hasRawObjectField(firstAsciiName))
            @Expect(contiguousNames.readRawNameIdBytes(firstAsciiName, asciiCandidateBytes), index)
            @Expect(contiguousNames.readRawInt64(), index + 1)
            firstAsciiName = false
        }
        @Expect(contiguousNames.hasRawObjectField(false))
        @Expect(contiguousNames.readRawNameIdBytes(false, asciiCandidateBytes), -1)
        @Expect(contiguousNames.readRawInt64(), 10)
        @Expect(!contiguousNames.hasRawObjectField(false))
        contiguousNames.endRawObject(); contiguousNames.expectEnd()

        let duplicateConfig = JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        @AssertThrows[JsonException](parseJsonValueFromStream(
            YJsonByteArrayInputStream("{\"a\":1,\"a\":2}"), config: duplicateConfig))

        let limited = JsonDirectReader(YJsonByteArrayInputStream("\"abcd\""),
            config: JsonReadOptions(maxStringBytes: 3))
        @AssertThrows[JsonException](limited.readString())
        for (text in ["null", "false", "\"x\"", "1.25", "[1,true]", "{\"x\":null}"]) {
            let reader = JsonDirectReader(YJsonByteArrayInputStream(text))
            @Expect((reader.readBoundedValue(64)).toJson(), (JsonNode.parse(text)).toJson())
            reader.expectEnd()
        }
        @AssertThrows[JsonException](JsonDirectReader(
            YJsonByteArrayInputStream("[1,2,3]")).readBoundedValue(4))
    }

    @TestCase
    func streamWindowFastPathsPreserveTypedSemanticsAndFallbacks(): Unit {
        let arrayReader = JsonDirectReader(YJsonByteArrayInputStream(
            " \n\r\t [0,-7,9223372036854775807,-9223372036854775808] \t"))
        let expected: Array<Int64> = [0, -7, Int64.Max, Int64.Min]
        arrayReader.startArray()
        for (value in expected) {
            @Expect(arrayReader.hasArrayItem())
            @Expect(arrayReader.readInt64(), value)
        }
        @Expect(!arrayReader.hasArrayItem())
        arrayReader.endArray()
        arrayReader.expectEnd()

        let whitespaceTerminated = ["1 ", "2\n", "3\r", "4\t"]
        for (index in 0..whitespaceTerminated.size) {
            let reader = JsonDirectReader(YJsonByteArrayInputStream(whitespaceTerminated[index]))
            @Expect(reader.readInt64(), index + 1)
            reader.expectEnd()
        }
        for (invalid in ["01,", "9223372036854775808 ",
            "-9223372036854775809 ", "1.0 ", "- "]) {
            @AssertThrows[JsonException](JsonDirectReader(
                YJsonByteArrayInputStream(invalid)).readInt64())
        }

        let simpleString = JsonDirectReader(YJsonByteArrayInputStream("\"plain ascii\""))
        @Expect(simpleString.readString(), "plain ascii")
        simpleString.expectEnd()
        let escapedString = JsonDirectReader(YJsonByteArrayInputStream("\"line\\nfeed\""))
        @Expect(escapedString.readString(), "line\nfeed")
        escapedString.expectEnd()
        let utf8String = JsonDirectReader(YJsonByteArrayInputStream("\"仓颉\""))
        @Expect(utf8String.readString(), "仓颉")
        utf8String.expectEnd()
        let splitString = JsonDirectReader(FixedChunkInputStream("\"chunk boundary\"", 2))
        @Expect(splitString.readString(), "chunk boundary")
        splitString.expectEnd()

        let candidates = ["tiny", "target", "longer"]
        let names = JsonDirectReader(YJsonByteArrayInputStream(
            "{\"target\":1,\"targex\":2,\"unknown\":3,\"tar\\u0067et\":4}"),
            config: JsonReadOptions(duplicateKeyPolicy: LastWins))
        names.startObject()
        @Expect(names.readNameId(candidates), 1); @Expect(names.readInt64(), 1)
        @Expect(names.readNameId(candidates), -1); @Expect(names.readInt64(), 2)
        @Expect(names.readNameId(candidates), -1); @Expect(names.readInt64(), 3)
        @Expect(names.readNameId(candidates), 1); @Expect(names.readInt64(), 4)
        names.endObject(); names.expectEnd()

        let splitName = JsonDirectReader(FixedChunkInputStream("{\"target\":5}", 2))
        splitName.startObject()
        @Expect(splitName.readNameId(candidates), 1)
        @Expect(splitName.readInt64(), 5)
        splitName.endObject(); splitName.expectEnd()

        let defaultDuplicate = JsonDirectReader(YJsonByteArrayInputStream("{\"a\":1,\"a\":2}"))
        defaultDuplicate.startObject()
        @Expect(defaultDuplicate.readName(), "a"); @Expect(defaultDuplicate.readInt64(), 1)
        let defaultError = @AssertThrows[JsonException](defaultDuplicate.readName())
        @Expect(defaultError.code, "duplicate_key")

        let lastWins = JsonDirectReader(YJsonByteArrayInputStream("{\"a\":1,\"a\":2}"),
            config: JsonReadOptions(duplicateKeyPolicy: LastWins))
        lastWins.startObject()
        @Expect(lastWins.readName(), "a"); @Expect(lastWins.readInt64(), 1)
        @Expect(lastWins.readName(), "a"); @Expect(lastWins.readInt64(), 2)
        lastWins.endObject(); lastWins.expectEnd()
    }

    @TestCase
    func resourcePreflightScannerCoversGrammarUnicodeUtf8AndLocationBranches(): Unit {
        let config = JsonReadOptions(maxStringBytes: 1024, maxBufferedValueBytes: 4096)
        let valid = [
            "null", "true", "false", "\"plain\"",
            "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", "\"\\u0030\\u00a2\\u4ED3\\uD83D\\uDE00\"",
            "[]", "[null,true,false,\"x\",-1,0,12,1.25,1e+2,1E-2]",
            "{}", "{\"a\":1,\"b\":[2],\"c\":{}}", "  [ 1 , 2 ]  "
        ]
        for (text in valid) {
            let _ = JsonNode.parse(coverageBytes(text), config: config)
        }

        let invalid = [
            "", " ", "?", "nul", "truX", "fals", "null x",
            "[", "[1", "[1 2]", "[,]", "{", "{1:2}", "{\"a\" 1}", "{\"a\":1 \"b\":2}",
            "\"", "\"\\", "\"\\x\"", "\"\u{0001}\"", "\"\\u12\"", "\"\\u12x4\"",
            "\"\\uD800\"", "\"\\uD800\\u0041\"", "\"\\uDC00\"",
            "-", "01", "1.", "1e", "1e+"
        ]
        for (text in invalid) {
            @AssertThrows[JsonException](JsonNode.parse(coverageBytes(text), config: config))
        }

        let invalidUtf8: Array<Array<Byte>> = [
            [b'"', 0x80u8, b'"'], [b'"', 0xC2u8, b'"'], [b'"', 0xC2u8, 0x20u8, b'"'],
            [b'"', 0xE0u8, 0x9Fu8, 0x80u8, b'"'], [b'"', 0xEDu8, 0xA0u8, 0x80u8, b'"'],
            [b'"', 0xE2u8, 0x82u8, b'"'], [b'"', 0xF0u8, 0x8Fu8, 0x80u8, 0x80u8, b'"'],
            [b'"', 0xF4u8, 0x90u8, 0x80u8, 0x80u8, b'"'], [b'"', 0xF0u8, 0x90u8, 0x80u8, b'"']
        ]
        for (bytes in invalidUtf8) {
            @AssertThrows[JsonException](JsonNode.parse(bytes, config: config))
        }
        let constrained = JsonReadOptions(maxStringBytes: 1)
        let error = @AssertThrows[JsonException](JsonNode.parse(coverageBytes("\"ab\""), config: constrained))
        @Expect(error.location.isSome())
    }

    @TestCase
    func directWriterCoversTargetsConfigsNumberWidthsAndBulkFallbacks(): Unit {
        let signed: Array<Int64> = [Int64.Min, -10000, -1000, -100, -10, -1, 0, 1, 9, 10, 99,
            100, 999, 1000, 9999, 10000, 99999, 100000, Int64.Max]
        let unsigned: Array<UInt64> = [0u64, 9u64, 10u64, 99u64, 100u64, 999u64, 1000u64,
            9999u64, 10000u64, 99999u64, 100000u64, UInt64.Max]
        for (config in [JsonWriteOptions.compact, JsonWriteOptions.pretty(),
            JsonWriteOptions(indent: "  ", htmlSafe: true),
            JsonWriteOptions()]) {
            let stringWriter = JsonDirectWriter(config)
            stringWriter.startArray()
            for (value in signed) { stringWriter.writeInt64(value) }
            for (value in unsigned) { stringWriter.writeUInt64(value) }
            stringWriter.writeString("\"\\\b\f\n\r\t<>&='仓")
            stringWriter.endArray()
            let text = stringWriter.finishString()
            @Expect(JsonNode.parse(text).asArray().size(), signed.size + unsigned.size + 1)

            let bytesWriter = JsonDirectWriter.bytes(config: config)
            bytesWriter.startObject(); bytesWriter.writeName("a"); bytesWriter.writeBool(false)
            bytesWriter.writeName("b"); bytesWriter.writeNull(); bytesWriter.endObject()
            @Expect(JsonNode.parse(String.fromUtf8(bytesWriter.finishBytes())).asObject().size(), 2)

            let output = YJsonMemoryOutputStream()
            let streamWriter = JsonDirectWriter(output, config: config)
            streamWriter.startArray(); streamWriter.writeFloat64(-1.25); streamWriter.endArray()
            streamWriter.finish()
            @Expect(JsonNode.parse(output.toUtf8String()).asArray()[0].asFloat64(), -1.25)
        }

        let ints = ArrayList<Int64>(); let strings = ArrayList<String>(); let map = HashMap<String, Int64>()
        ints.add(1); strings.add("x\n"); map["x\n"] = 2
        for (config in [JsonWriteOptions.pretty(), JsonWriteOptions(htmlSafe: true)]) {
            let writer = JsonDirectWriter(config)
            @Expect(!writer.tryWriteCompactInt64ArrayList(ints))
            writer.startArray(); writer.writeInt64(1); writer.endArray(); let _ = writer.finishString()
            let stringBulk = JsonDirectWriter(config)
            @Expect(!stringBulk.tryWriteCompactStringArrayList(strings))
            stringBulk.startArray(); stringBulk.writeString(strings[0]); stringBulk.endArray()
            let _ = stringBulk.finishString()
            let mapBulk = JsonDirectWriter(config)
            @Expect(!mapBulk.tryWriteCompactInt64Map(map))
            mapBulk.startObject(); mapBulk.writeName("x\n"); mapBulk.writeInt64(2); mapBulk.endObject()
            let _ = mapBulk.finishString()
        }
    }

    @TestCase
    func annotationMetadataConstructorsPreserveTheirPublicContract(): Unit {
        @Expect(JsonName("wire_name").value, "wire_name")
        let _ = JsonIgnore()
        let _ = JsonIncludeNull()
        @Expect(JsonAlias("legacy_name").value, "legacy_name")
        @Expect(JsonUsingMetadata("CustomCodec").expression, "CustomCodec")
        @Expect(JsonPolymorphic().discriminator, "type")
        @Expect(JsonPolymorphic(discriminator: "kind").discriminator, "kind")
        @Expect(JsonSubtypeMetadata("dog,Dog").expression, "dog,Dog")
    }

    @TestCase
    func managedAndNodeViewsSerializeEveryJsonKindAcrossTargets(): Unit {
        let longKey = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-long-key"
        let source = "{\"null\":null,\"bool\":true,\"int\":-7,\"number\":9223372036854775808," +
            "\"float\":1.5,\"text\":\"仓颉\",\"array\":[false,2,\"x\"]," +
            "\"object\":{\"x\":\"y\"},\"${longKey}\":\"long\"}"
        let document = YJson.parseDocument(source)
        let root = document.root()
        @Expect(root.kind(), JsonKind.Object)
        @Expect(root.member(longKey).getOrThrow().asString(), "long")
        @Expect(root.member("missing").isNone())
        @Expect(root.member("array").getOrThrow().element(2).getOrThrow().asString(), "x")
        @Expect(root.member("array").getOrThrow().element(99).isNone())

        let expected = JsonNode.parse(source)
        @Expect(jsonNodesEquivalent(JsonNode.parse(YJson.toJson(root)), expected))
        @Expect(jsonNodesEquivalent(JsonNode.parse(YJson.toJsonBytes(root)), expected))
        let output = YJsonMemoryOutputStream()
        YJson.writeJson(root, output)
        @Expect(jsonNodesEquivalent(JsonNode.parse(output.toUtf8String()), expected))
        @Expect(jsonNodesEquivalent(document.materialize(64), expected))

        let bytesDocument = YJson.parseDocument(coverageBytes(source))
        @Expect(bytesDocument.root().member(longKey).getOrThrow().asString(), "long")
        let nodeView: JsonValueView = expected
        @Expect(jsonNodesEquivalent(JsonNode.parse(YJson.toJson(nodeView)), expected))
    }

    @TestCase
    func genericBuiltInProvidersRoundtripAllNumericWidths(): Unit {
        @Expect(YJson.fromJson<Bool>(YJson.toJson(true)), true)
        @Expect(YJson.fromJson<Int8>(YJson.toJson(-8i8)), -8i8)
        @Expect(YJson.fromJson<Int16>(YJson.toJson(-16i16)), -16i16)
        @Expect(YJson.fromJson<Int32>(YJson.toJson(-32i32)), -32i32)
        @Expect(YJson.fromJson<Int64>(YJson.toJson(Int64.Min)), Int64.Min)
        @Expect(YJson.fromJson<UInt8>(YJson.toJson(8u8)), 8u8)
        @Expect(YJson.fromJson<UInt16>(YJson.toJson(UInt16.Max)), UInt16.Max)
        @Expect(YJson.fromJson<UInt32>(YJson.toJson(UInt32.Max)), UInt32.Max)
        @Expect(YJson.fromJson<UInt64>(YJson.toJson(UInt64.Max)), UInt64.Max)
        @Expect(Float64(YJson.fromJson<Float16>(YJson.toJson(Float16(1.5)))), 1.5)
        @Expect(Float64(YJson.fromJson<Float32>(YJson.toJson(2.5f32))), 2.5)
        @Expect(YJson.fromJson<Float64>(YJson.toJson(3.5)), 3.5)
        @Expect(YJson.fromJson<String>(YJson.toJson("text")), "text")
        @Expect(YJson.fromJson<Rune>(YJson.toJson(r'界')).toString(), "界")

        let big = BigInt.parse("123456789012345678901234567890")
        @Expect(YJson.fromJson<BigInt>(YJson.toJson(big)), big)
        let decimal = Decimal.parse("1234567890.0123456789")
        @Expect(YJson.fromJson<Decimal>(YJson.toJson(decimal)), decimal)
        @Expect(YJson.fromJson<Int8>(YJson.toJsonBytes(-17i8)), -17i8)
    }

    @TestCase
    func directWriterTargetsCoverRangesFlushesAndResultKinds(): Unit {
        let buffer = DirectBufferWriterTarget(capacity: 1)
        buffer.writeBytesRange([b'x'], 0, 0)
        buffer.writeBytesRange([b'a', b'b', b'c', b'd'], 1, 3)
        buffer.writeTextStringLiteralNoEscape(":", "x")
        buffer.writeUInt64Text(10000u64)
        buffer.finish()
        @Expect(buffer.buildString(), "bc:\"x\"10000")

        let largeBuilder = StringBuilder()
        for (_ in 0..3000) { largeBuilder.append("z") }
        let large = largeBuilder.toString()
        let output = YJsonMemoryOutputStream()
        let stream = DirectStreamWriterTarget(output, JsonWriteOptions.defaults)
        stream.writeBytes([])
        stream.writeBytesRange([b'x'], 0, 0)
        stream.writeText("prefix")
        stream.writeBytes([b'a', b'b'])
        stream.writeBytesRange([b'0', b'1', b'2', b'3'], 1, 3)
        stream.writeTextStringLiteralNoEscape(":", "v")
        stream.writeUInt64Text(10000u64)
        @Expect(!stream.tryWriteNativeInt64Array(ArrayList<Int64>()))
        stream.writeText(large)
        stream.finish()
        @Expect(output.toUtf8String(), "prefixab12:\"v\"10000" + large)

        let streamWriter = JsonDirectWriter(YJsonMemoryOutputStream())
        streamWriter.writeNull()
        @AssertThrows[JsonException](streamWriter.finishString())
        let stringWriter = JsonDirectWriter()
        stringWriter.writeNull()
        @AssertThrows[JsonException](stringWriter.finishBytes())

        let raw = JsonDirectWriter()
        @Expect(raw.tryBeginGeneratedCompactRawValue())
        raw.writeRawBeginObject()
        var first = true
        first = raw.writeRawObjectEntryNameBool(first, "a", true)
        first = raw.writeRawObjectEntryNameBool(first, "b", false)
        let _ = first
        raw.writeRawEndObject()
        @Expect(raw.finishString(), "{\"a\":true,\"b\":false}")
    }

    @TestCase
    func arbitraryPrecisionGeneratedBridgesCoverCompactAndFallbackContainers(): Unit {
        let bigCompact = GeneratedSupportV1.newFastReader(
            "[123456789012345678901234567890,-99999999999999999999999999999]")
        let bigs = __yJsonReadFastArrayListBigInt(bigCompact)
        bigCompact.expectEnd()
        @Expect(bigs[0], BigInt.parse("123456789012345678901234567890"))
        @Expect(bigs[1], BigInt.parse("-99999999999999999999999999999"))

        let bigFallback = GeneratedSupportV1.newFastReader("[ 1 , -2 ]")
        @Expect(__yJsonReadFastArrayListBigInt(bigFallback)[1], BigInt(-2))
        bigFallback.expectEnd()
        let bigMap = GeneratedSupportV1.newFastReader(
            "{\"a\":12345678901234567890, \"b\":-2}")
        @Expect(__yJsonReadFastHashMapStringBigInt(bigMap)["b"], BigInt(-2))
        bigMap.expectEnd()

        let decimalCompact = GeneratedSupportV1.newFastReader("[1.25,-2.5,3e2]")
        let decimals = __yJsonReadFastArrayListDecimal(decimalCompact)
        decimalCompact.expectEnd()
        @Expect(decimals[0], Decimal.parse("1.25"))
        @Expect(decimals[2], Decimal.parse("3e2"))
        let decimalFallback = GeneratedSupportV1.newFastReader("[ 0.125 , -4.5 ]")
        @Expect(__yJsonReadFastArrayListDecimal(decimalFallback)[1], Decimal.parse("-4.5"))
        decimalFallback.expectEnd()
        let decimalMap = GeneratedSupportV1.newFastReader("{\"a\":1.25, \"b\":2e3}")
        @Expect(__yJsonReadFastHashMapStringDecimal(decimalMap)["b"], Decimal.parse("2e3"))
        decimalMap.expectEnd()

        let scalarBig = GeneratedSupportV1.newFastReader("123456789012345678901")
        @Expect(jsonFastReadBigInt(scalarBig), BigInt.parse("123456789012345678901"))
        scalarBig.expectEnd()
        let scalarDecimal = GeneratedSupportV1.newFastReader("-1.25e3")
        @Expect(jsonFastReadDecimal(scalarDecimal), Decimal.parse("-1.25e3"))
        scalarDecimal.expectEnd()
    }

    @TestCase
    func nodeFactoriesConversionsViewsAndStreamsCoverPublicSemantics(): Unit {
        @Expect(JsonNode.nullValue.size(), 0)
        @Expect(JsonNode.boolean(true).size(), 0)
        @Expect(JsonNode.int64(1).size(), 0)
        @Expect(JsonNode.uint64(2u64).asInt64(), 2)
        @Expect(JsonNode.float64(1.5).asNumberText(), "1.500000")
        @Expect(JsonNode.number("9223372036854775808").asUInt64(), 9223372036854775808u64)
        @Expect(JsonNode.string("x").asString(), "x")
        @Expect(JsonNode.array().size(), 0)
        @Expect(JsonNode.array([JsonIntValue(1)]).size(), 1)
        @Expect(JsonNode.object().size(), 0)

        @AssertThrows[IllegalArgumentException](JsonException("bad", path: "not-a-pointer"))
        @AssertThrows[JsonException](JsonUIntValue(UInt64.Max).asInt64())
        @AssertThrows[JsonException](JsonIntValue(-1).asUInt64())
        @AssertThrows[JsonException](JsonNumberLiteralValue("1.5").asInt64())
        @AssertThrows[JsonException](JsonNumberLiteralValue("-1").asUInt64())
        @AssertThrows[JsonException](JsonStringValue("x").asUInt64())

        let array = JsonArray()
        array.add(true).add(1).add(2u64).add(3.5).add(r'界').add("text")
        @Expect(array.element(0).getOrThrow().asBool(), true)
        @Expect(array.element(99).isNone())
        let object = JsonObject()
        object.put("array", array).put("value", 7)
        @Expect(object.member("value").getOrThrow().asInt64(), 7)
        @Expect(object.member("missing").isNone())
        @Expect(object.memberName(0), "array")
        @Expect(object.memberValue(1).asInt64(), 7)
        @AssertThrows[JsonException](object.memberName(99))
        @AssertThrows[JsonException](object.memberValue(99))

        let copied = object.materialize(64)
        @Expect(jsonNodesEquivalent(copied, object))
        let output = YJsonMemoryOutputStream()
        object.writeJson(output)
        @Expect(jsonNodesEquivalent(JsonNode.parse(output.toUtf8String()), object))
        @Expect(JsonUIntValue(3u64).toPrettyString("  "), "3")
        @Expect(JsonFloatValue(1.5).toPrettyString("  "), "1.500000")
        @Expect(JsonNumberLiteralValue("1e2").toPrettyString("  "), "1e2")
        @Expect(JsonStringValue("x").toPrettyString("  "), "\"x\"")
    }
}
