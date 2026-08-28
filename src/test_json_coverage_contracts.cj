package yjson

import std.collection.*
import std.math.numeric.*
import std.unittest.*
import std.unittest.testmacro.*

private class CoverageIntValueCodec <: JsonValueCodec<Int64> {
    public func encode(value: Int64): JsonNode { JsonIntValue(value) }
    public func decode(value: JsonNode): Int64 { value.asInt().value }
}

private class CoverageSemanticIntCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {
        let _ = context
        writer.writeInt64(value)
    }

    public func read(reader: JsonCodecReader, context: JsonDecodeContext): Int64 {
        let _ = context
        reader.readInt64()
    }
}

private func coverageRichTape(): Array<Byte> {
    let writer = JsonStreamTapeWriter()
    writer.startObject()
    writer.writeName("null"); writer.writeNull()
    writer.writeName("bool"); writer.writeBool(true)
    writer.writeName("int"); writer.writeInt64(-7)
    writer.writeName("uint"); writer.writeUInt64(UInt64.Max)
    writer.writeName("float"); writer.writeFloat64(1.5)
    writer.writeName("raw"); writer.writeRawNumber("12345678901234567890")
    writer.writeName("text"); writer.writeString("仓颉")
    writer.writeName("array"); writer.startArray(); writer.writeBool(false); writer.writeInt64(2); writer.endArray()
    writer.writeName("object"); writer.startObject(); writer.writeName("x"); writer.writeString("y"); writer.endObject()
    writer.endObject()
    writer.finishTape()
}

private func coverageBytes(text: String): Array<Byte> { unsafe { text.rawData().clone() } }

@Test
class JsonCoverageContractsTest {
    @TestCase
    func typedContainerCodecsCoverSemanticDirectFastEmptyAndBulkPaths(): Unit {
        let semantic = CoverageSemanticIntCodec()
        let optionCodec = YJson.optionCodec(semantic)
        let arrayCodec = YJson.arrayCodec(semantic)
        let listCodec = YJson.arrayListCodec(semantic)
        let mapCodec = YJson.hashMapCodec(semantic)

        // A tape is a non-direct semantic writer and reader. It exercises the
        // backend-neutral codec contract without relying on string parsing.
        let tapeWriter = JsonStreamTapeWriter()
        optionCodec.write(Some(1), tapeWriter, JsonEncodeContext(JsonWriteConfig.compact))
        let tapeReader = JsonStreamTapeReader(tapeWriter.finishTape())
        @Expect(optionCodec.read(tapeReader, JsonDecodeContext(JsonReadConfig.defaults)).getOrThrow(), 1)
        tapeReader.expectEnd()

        let noneWriter = JsonStreamTapeWriter()
        optionCodec.write(None<Int64>, noneWriter, JsonEncodeContext(JsonWriteConfig.compact))
        let noneReader = JsonStreamTapeReader(noneWriter.finishTape())
        @Expect(optionCodec.read(noneReader, JsonDecodeContext(JsonReadConfig.defaults)).isNone())
        noneReader.expectEnd()

        for (values in [Array<Int64>(), [1, 2]]) {
            let writer = JsonStreamTapeWriter()
            arrayCodec.write(values, writer, JsonEncodeContext(JsonWriteConfig.compact))
            let reader = JsonStreamTapeReader(writer.finishTape())
            let decoded = arrayCodec.read(reader, JsonDecodeContext(JsonReadConfig.defaults))
            @Expect(decoded.size, values.size)
            if (!values.isEmpty()) { @Expect(decoded[1], 2) }
            reader.expectEnd()
        }

        for (size in [0, 2]) {
            let values = ArrayList<Int64>()
            for (index in 0..size) { values.add(index + 3) }
            let writer = JsonStreamTapeWriter()
            listCodec.write(values, writer, JsonEncodeContext(JsonWriteConfig.compact))
            let reader = JsonStreamTapeReader(writer.finishTape())
            let decoded = listCodec.read(reader, JsonDecodeContext(JsonReadConfig.defaults))
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded[1], 4) }
            reader.expectEnd()
        }

        for (size in [0, 2]) {
            let values = HashMap<String, Int64>()
            if (size > 0) { values["a"] = 5; values["b"] = 6 }
            let writer = JsonStreamTapeWriter()
            mapCodec.write(values, writer, JsonEncodeContext(JsonWriteConfig.compact))
            let reader = JsonStreamTapeReader(writer.finishTape())
            let decoded = mapCodec.read(reader, JsonDecodeContext(JsonReadConfig.defaults))
            @Expect(decoded.size, size)
            if (size > 0) { @Expect(decoded["b"], 6) }
            reader.expectEnd()
        }

        // DirectWriter with a semantic-only element codec covers the narrow
        // SPI fallback used by custom codecs, including nested path tracking.
        @Expect(YJson.encodeStringWith(optionCodec, Some(7)), "7")
        @Expect(YJson.encodeStringWith(optionCodec, None<Int64>), "null")
        @Expect(YJson.encodeStringWith(arrayCodec, [8, 9]), "[8,9]")
        let directList = ArrayList<Int64>(); directList.add(10); directList.add(11)
        @Expect(YJson.encodeStringWith(listCodec, directList), "[10,11]")
        let directMap = HashMap<String, Int64>(); directMap["x"] = 12
        @Expect(YJson.parse(YJson.encodeStringWith(mapCodec, directMap)).asObject()["x"].asInt().value, 12)

        // Fast generic containers cover empty, small, and capacity-hinted
        // collection loops. Configured reads force the semantic reader path.
        let fastArray = YJson.arrayCodec(Int64Json)
        @Expect(YJson.decodeStringWith(fastArray, "[]").size, 0)
        @Expect(YJson.decodeStringWith(fastArray, "[1,2,3,4,5,6]").size, 6)
        @Expect(YJson.decodeStringWith(fastArray, "[1,2]",
            config: JsonReadConfig(limits: JsonReadLimits(maxDepth: 257)))[1], 2)
        let fastList = YJson.arrayListCodec(Int64Json)
        @Expect(YJson.decodeStringWith(fastList, "[]").size, 0)
        @Expect(YJson.decodeStringWith(fastList, "[1,2,3,4,5,6]").size, 6)
        let fastMap = YJson.hashMapCodec(Int64Json)
        @Expect(YJson.decodeStringWith(fastMap, "{}").size, 0)
        @Expect(YJson.decodeStringWith(fastMap, "{\"a\":1,\"b\":2}")["b"], 2)

        let stringOption = YJson.stringOptionCodec()
        @Expect(YJson.decodeStringWith(stringOption, "null").isNone())
        @Expect(YJson.decodeStringWith(stringOption, "\"x\"").getOrThrow(), "x")
        @Expect(YJson.encodeStringWith(stringOption, None<String>), "null")
        @Expect(YJson.encodeStringWith(stringOption, Some("x")), "\"x\"")

        let compactInts = YJson.int64ArrayListCodec()
        @Expect(YJson.encodeStringWith(compactInts, directList), "[10,11]")
        @Expect(YJson.encodeStringWith(compactInts, directList,
            config: JsonWriteConfig.pretty).contains("\n"))
        @Expect(YJson.decodeStringWith(compactInts, "[]").size, 0)
        @Expect(YJson.decodeStringWith(compactInts, "[10,11]")[1], 11)

        let strings = ArrayList<String>(); strings.add("a"); strings.add("b")
        let compactStrings = YJson.stringArrayListCodec()
        @Expect(YJson.encodeStringWith(compactStrings, strings), "[\"a\",\"b\"]")
        @Expect(YJson.encodeStringWith(compactStrings, strings,
            config: JsonWriteConfig.pretty).contains("\n"))
        @Expect(YJson.decodeStringWith(compactStrings, "[]").size, 0)
        @Expect(YJson.decodeStringWith(compactStrings, "[\"a\",\"b\"]")[1], "b")

        let intsMap = HashMap<String, Int64>(); intsMap["a"] = 13; intsMap["b"] = 14
        let compactMap = YJson.int64HashMapCodec()
        @Expect(YJson.parse(YJson.encodeStringWith(compactMap, intsMap)).asObject()["a"].asInt().value, 13)
        @Expect(YJson.encodeStringWith(compactMap, intsMap,
            config: JsonWriteConfig.pretty).contains("\n"))
        @Expect(YJson.decodeStringWith(compactMap, "{}").size, 0)
        @Expect(YJson.decodeStringWith(compactMap, "{\"a\":13,\"b\":14}")["b"], 14)
    }

    @TestCase
    func astFacadeAndContainerCodecsPreserveValues(): Unit {
        let scalar = CoverageIntValueCodec()
        @Expect(YJsonAst.parse("1").asInt().value, 1)
        @Expect(YJsonAst.parse([b'2']).asInt().value, 2)
        @Expect(YJsonAst.stringify(JsonStringValue("a\n")), "\"a\\n\"")
        @Expect(YJsonAst.stringifyPretty(YJsonAst.parse("{\"a\":1}"), indent: "\t").contains("\n\t\"a\""))
        @Expect(YJsonAst.encodeWith(scalar, 3).asInt().value, 3)
        @Expect(YJsonAst.decodeWith(scalar, JsonIntValue(4)), 4)
        @Expect(YJsonAst.encodeStringWith(scalar, 5), "5")
        @Expect(YJsonAst.decodeStringWith(scalar, "6"), 6)

        let output = YJsonMemoryOutputStream()
        YJsonAst.encodeToStreamWith(scalar, 7, output)
        @Expect(output.toUtf8String(), "7")
        @Expect(YJsonAst.decodeFromStreamWith(scalar, YJsonByteArrayInputStream("8")), 8)

        let option = YJsonAst.optionCodec(scalar)
        @Expect(option.encode(Some(9)).asInt().value, 9)
        @Expect(option.encode(None<Int64>) is JsonNullValue)
        @Expect(option.decode(JsonNullValue()).isNone())
        @Expect(option.decode(JsonIntValue(10)).getOrThrow(), 10)

        let array = YJsonAst.arrayCodec(scalar)
        @Expect(array.decode(array.encode([1, 2]))[1], 2)
        let list = ArrayList<Int64>(); list.add(3); list.add(4)
        let listCodec = YJsonAst.arrayListCodec(scalar)
        @Expect(listCodec.decode(listCodec.encode(list))[0], 3)
        let map = HashMap<String, Int64>(); map.add("a", 11); map.add("b", 12)
        let mapCodec = YJsonAst.hashMapCodec(scalar)
        @Expect(mapCodec.decode(mapCodec.encode(map))["b"], 12)
    }

    @TestCase
    func nodeCopyAndEquivalenceCoverEveryBuiltInKind(): Unit {
        let original = YJsonAst.parse("{\"n\":null,\"b\":true,\"i\":1,\"f\":1.5," +
            "\"number\":9223372036854775808,\"s\":\"x\",\"a\":[1]}")
        let copied = deepCopyJsonNode(original)
        @Expect(jsonNodesEquivalent(original, copied))
        copied.asObject()["s"] = JsonStringValue("changed")
        @Expect(!jsonNodesEquivalent(original, copied))
        @Expect(jsonNodesEquivalent(JsonIntValue(1), JsonFloatValue(1.0)))
        @Expect(jsonNodesEquivalent(JsonIntValue(1), JsonNumberLiteralValue("1")))
        @Expect(!jsonNodesEquivalent(JsonIntValue(1), JsonStringValue("1")))
        @Expect(!jsonNodesEquivalent(YJsonAst.parse("[1]"), YJsonAst.parse("[]")))
        @Expect(!jsonNodesEquivalent(YJsonAst.parse("{\"a\":1}"), YJsonAst.parse("{}")))
        @Expect(!jsonNodesEquivalent(YJsonAst.parse("{\"a\":1}"), YJsonAst.parse("{\"a\":2}")))
    }

    @TestCase
    func tapeReaderWriterRoundtripReplayAndBulkPaths(): Unit {
        let tape = coverageRichTape()
        let reader = JsonStreamTapeReader(tape)
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

        let replayReader = JsonStreamTapeReader(tape)
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
        excluding.endObject(); excluding.expectEnd(); @Expect(!sawBool)
        @Expect(replay.materialize().asObject()["array"].asArray().size(), 2)
        replay.close(); @Expect(replay.isClosed())
        @AssertThrows[IllegalStateException](replay.materialize())

        let ints = ArrayList<Int64>(); ints.add(-1); ints.add(2)
        let intWriter = JsonStreamTapeWriter(); @Expect(intWriter.tryWriteCompactInt64ArrayList(ints))
        @Expect(JsonStreamTapeReader(intWriter.finishTape()).readReplayValue(0).materialize().asArray().size(), 2)
        let strings = ArrayList<String>(); strings.add("a"); strings.add("b")
        let stringWriter = JsonStreamTapeWriter(); @Expect(stringWriter.tryWriteCompactStringArrayList(strings))
        @Expect(JsonStreamTapeReader(stringWriter.finishTape()).readReplayValue(0).materialize().asArray()[1].asString().value, "b")
        let values = HashMap<String, Int64>(); values.add("k", 3)
        let mapWriter = JsonStreamTapeWriter(); @Expect(mapWriter.tryWriteCompactInt64Map(values))
        @Expect(JsonStreamTapeReader(mapWriter.finishTape()).readReplayValue(0).materialize().asObject()["k"].asInt().value, 3)
    }

    @TestCase
    func tapeContractsRejectInvalidOrderTypesDepthAndBounds(): Unit {
        @AssertThrows[JsonException](JsonStreamTapeReader([b'B', b'A', b'D']))
        let writer = JsonStreamTapeWriter()
        @AssertThrows[JsonException](writer.writeName("x"))
        writer.startObject(); writer.writeName("x")
        @AssertThrows[JsonException](writer.endObject())
        writer.writeNull(); writer.endObject(); let tape = writer.finishTape()
        @AssertThrows[IllegalStateException](writer.writeNull())
        @AssertThrows[IllegalStateException](writer.finishTape())

        let wrong = JsonStreamTapeReader(tape)
        @AssertThrows[JsonException](wrong.startArray())
        let partial = JsonStreamTapeReader(tape); partial.startObject()
        @AssertThrows[JsonException](partial.endObject())
        @AssertThrows[IllegalArgumentException](JsonStreamTapeReader(tape).readReplayValue(-1))
        @AssertThrows[JsonException](JsonStreamTapeReader(tape).readReplayValue(1))

        let nestedWriter = JsonStreamTapeWriter(); nestedWriter.startArray(); nestedWriter.startArray()
        nestedWriter.writeNull(); nestedWriter.endArray(); nestedWriter.endArray()
        let nested = JsonStreamTapeReader(nestedWriter.finishTape())
        @AssertThrows[JsonException](nested.skipValueWithDepth(1))
        @AssertThrows[IllegalArgumentException](JsonStreamTapeReader(tape).skipValueWithDepth(-1))

        let truncated = tape[..tape.size - 1]
        @AssertThrows[JsonException](JsonStreamTapeReader(truncated).skipValue())
    }

    @TestCase
    func builtInScalarCodecsCoverRangeAndAlternateNumberForms(): Unit {
        @Expect(YJson.decodeStringWith(Int8Json, "127"), 127i8)
        @AssertThrows[JsonException](YJson.decodeStringWith(Int8Json, "128"))
        @Expect(YJson.decodeStringWith(UInt8Json, "255"), 255u8)
        @AssertThrows[JsonException](YJson.decodeStringWith(UInt8Json, "256"))
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
        let configured = JsonReadConfig(limits: JsonReadLimits(maxDepth: 257))
        @Expect(YJson.decodeStringWith(BoolJson, "true", config: configured), true)
        @Expect(YJson.decodeStringWith(Int64Json, "-9223372036854775808", config: configured), Int64.Min)
        @Expect(YJson.decodeStringWith(Int32Json, "2147483647", config: configured), Int32.Max)
        @Expect(YJson.decodeStringWith(Int16Json, "-32768", config: configured), Int16.Min)
        @Expect(YJson.decodeStringWith(Int8Json, "-128", config: configured), Int8.Min)
        @Expect(YJson.decodeStringWith(UInt64Json, "18446744073709551615", config: configured), UInt64.Max)
        @Expect(YJson.decodeStringWith(UInt32Json, "4294967295", config: configured), UInt32.Max)
        @Expect(YJson.decodeStringWith(UInt16Json, "65535", config: configured), UInt16.Max)
        @Expect(YJson.decodeStringWith(UInt8Json, "255", config: configured), UInt8.Max)
        @Expect(YJson.decodeStringWith(Float64Json, "1.25", config: configured), 1.25)
        @Expect(Float64(YJson.decodeStringWith(Float32Json, "1.5", config: configured)), 1.5)
        @Expect(Float64(YJson.decodeStringWith(Float16Json, "2.0", config: configured)), 2.0)
        @Expect(YJson.decodeStringWith(StringJson, "\"x\"", config: configured), "x")
        @Expect(YJson.decodeStringWith(RuneJson, "\"仓\"", config: configured).toString(), "仓")
        @Expect(YJson.decodeStringWith(BigIntJson, "9223372036854775808", config: configured),
            BigInt.parse("9223372036854775808"))
        @Expect(YJson.decodeStringWith(DecimalJson, "1.25", config: configured), Decimal.parse("1.25"))
        let date = YJson.decodeStringWith(DateTimeJson, "\"2024-01-02T03:04:05Z\"", config: configured)
        @Expect(YJson.encodeStringWith(DateTimeJson, date, config: JsonWriteConfig.pretty),
            "\"2024-01-02T03:04:05Z\"")

        @Expect(YJson.toJson(1i32), "1")
        @Expect(YJson.fromJson<Int16>("2"), 2i16)
        @Expect(YJson.toJson(3u8), "3")
        @Expect(YJson.fromJson<Float32>("4.5"), 4.5f32)
        @Expect(YJson.toJson("text"), "\"text\"")
        @Expect(YJson.fromJson<Rune>("\"界\"").toString(), "界")

        @AssertThrows[JsonException](YJson.decodeStringWith(Int32Json, "2147483648", config: configured))
        @AssertThrows[JsonException](YJson.decodeStringWith(Int16Json, "32768", config: configured))
        @AssertThrows[JsonException](YJson.decodeStringWith(UInt32Json, "4294967296", config: configured))
        @AssertThrows[JsonException](YJson.decodeStringWith(UInt16Json, "65536", config: configured))
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

        let bytes: Array<Byte> = [b'{', b'"', b'a', b'"', b':', b'1', b'}']
        let semantic = GeneratedSupportV1.newSemanticReader(bytes,
            JsonReadConfig(limits: JsonReadLimits(maxDepth: 257)))
        semantic.startObject(); @Expect(semantic.readNameId(["a"]), 0); @Expect(semantic.readInt64(), 1)
        semantic.endObject(); semantic.expectEnd()
        let semanticText = GeneratedSupportV1.newSemanticReader("[true]",
            JsonReadConfig(limits: JsonReadLimits(maxDepth: 257)))
        semanticText.startArray(); @Expect(semanticText.hasArrayItem()); @Expect(semanticText.readBool())
        semanticText.endArray(); semanticText.expectEnd()

        let writer = GeneratedSupportV1.newWriter()
        @Expect(GeneratedSupportV1.tryBeginCompactValue(writer))
        GeneratedSupportV1.writeCompactObjectBegin(writer)
        @Expect(!GeneratedSupportV1.writeCompactEntryString(writer, true, "s", "x"))
        @Expect(!GeneratedSupportV1.writeCompactEntryBool(writer, false, "b", true))
        @Expect(!GeneratedSupportV1.writeCompactEntryInt64(writer, false, "i", 7))
        GeneratedSupportV1.writeCompactObjectEnd(writer)
        @Expect(writer.finishString(), "{\"s\":\"x\",\"b\":true,\"i\":7}")

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
        __yJsonWriteStringArrayList(stringValues, stringListWriter,
            JsonEncodeContext(JsonWriteConfig.compact))
        @Expect(stringListWriter.finishString(), "[\"a\",\"b\"]")

        let intValues = HashMap<String, Int64>()
        intValues["value"] = 7
        let intMapWriter = JsonDirectWriter()
        __yJsonWriteInt64HashMap(intValues, intMapWriter,
            JsonEncodeContext(JsonWriteConfig.compact))
        @Expect(YJson.parse(intMapWriter.finishString()).asObject()["value"].asInt().value, 7)

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
        let kinds = [JsNull, JsBool, JsInt, JsFloat, JsNumberLiteral, JsString, JsArray, JsObject]
        for (left in 0..kinds.size) {
            for (right in 0..kinds.size) {
                @Expect(kinds[left] == kinds[right], left == right)
                @Expect(kinds[left] != kinds[right], left != right)
            }
        }

        @AssertThrows[IllegalArgumentException](JsonReadLimits(maxDepth: 0))
        @AssertThrows[IllegalArgumentException](JsonReadLimits(maxPolymorphicObjectBytes: -1))
        @AssertThrows[IllegalArgumentException](JsonReadLimits(maxStringBytes: -1))
        @AssertThrows[IllegalArgumentException](JsonReadLimits(maxBytes: -1))
        let rejecting = JsonReadConfig(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject,
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            numberPolicy: JsonNumberPolicy.PreserveLiteral, includeErrorLocation: false)
        @Expect(rejecting.rejectsUnknownFields())
        @Expect(rejecting.rejectsDuplicateKeys())
        @Expect(!JsonReadConfig.defaults.rejectsUnknownFields())
        @Expect(!JsonReadConfig.defaults.rejectsDuplicateKeys())
        @Expect(jsonReadConfigPreservesNumberLiterals(rejecting))
        @Expect(!jsonReadConfigUsesDefaultFastPath(rejecting))

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

        let object = JsonObjectValue()
        object["bool"] = true; object["int"] = 2; object["float"] = 3.5
        object["rune"] = r'界'; object["text"] = "x"; object["array"] = [JsonNullValue()]
        object["node"] = JsonIntValue(9)
        @Expect(object.contains("bool")); @Expect(object["bool"].bool)
        @Expect(object["int"].int64, 2); @Expect(object["float"].float64, 3.5)
        @Expect(object["rune"].string, "界"); @Expect(object["array"].array.size(), 1)
        @Expect(object.object.size(), 7); @Expect(!object.isNull)
        @Expect(object.remove("node").isSome()); @Expect(object.remove("missing").isNone())
        @AssertThrows[JsonException](object["missing"])

        let array = JsonArrayValue([JsonNullValue(), JsonNullValue(), JsonNullValue(), JsonNullValue(),
            JsonNullValue(), JsonNullValue(), JsonNullValue()])
        array[0] = JsonBoolValue(false); array[1] = true; array[2] = 2; array[3] = 3.5
        array[4] = r'仓'; array[5] = "text"; array[6] = [JsonIntValue(1)]
        @Expect(!array[0].bool); @Expect(array[2].int64, 2); @Expect(array[6].array.size(), 1)
        array.insert(0, JsonStringValue("first")); @Expect(array.removeAt(0).string, "first")
        @Expect(array.values().size, 7); @Expect(array.get(99).isNone())
        @AssertThrows[JsonException](array.set(-1, JsonNullValue()))
        @AssertThrows[JsonException](array.insert(99, JsonNullValue()))
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

        let duplicateConfig = JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        @AssertThrows[JsonException](parseJsonValueFromStream(
            YJsonByteArrayInputStream("{\"a\":1,\"a\":2}"), config: duplicateConfig))

        let limited = JsonDirectReader(YJsonByteArrayInputStream("\"abcd\""),
            config: JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 3)))
        @AssertThrows[JsonException](limited.readString())
        for (text in ["null", "false", "\"x\"", "1.25", "[1,true]", "{\"x\":null}"]) {
            let reader = JsonDirectReader(YJsonByteArrayInputStream(text))
            @Expect(YJson.stringify(reader.readBoundedValue(64)), YJson.stringify(YJson.parse(text)))
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
            "{\"target\":1,\"targex\":2,\"unknown\":3,\"tar\\u0067et\":4}"))
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
        @Expect(defaultDuplicate.readName(), "a"); @Expect(defaultDuplicate.readInt64(), 2)
        defaultDuplicate.endObject(); defaultDuplicate.expectEnd()

        let rejectingDuplicate = JsonDirectReader(YJsonByteArrayInputStream("{\"a\":1,\"a\":2}"),
            config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject))
        rejectingDuplicate.startObject()
        @Expect(rejectingDuplicate.readName(), "a"); @Expect(rejectingDuplicate.readInt64(), 1)
        let duplicate = @AssertThrows[JsonException](rejectingDuplicate.readName())
        @Expect(duplicate.code, "duplicate_key")
    }

    @TestCase
    func resourcePreflightScannerCoversGrammarUnicodeUtf8AndLocationBranches(): Unit {
        let config = JsonReadConfig(limits: JsonReadLimits(maxStringBytes: 1024,
            maxPolymorphicObjectBytes: 4096))
        let valid = [
            "null", "true", "false", "\"plain\"",
            "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", "\"\\u0030\\u00a2\\u4ED3\\uD83D\\uDE00\"",
            "[]", "[null,true,false,\"x\",-1,0,12,1.25,1e+2,1E-2]",
            "{}", "{\"a\":1,\"b\":[2],\"c\":{}}", "  [ 1 , 2 ]  "
        ]
        for (text in valid) {
            let _ = YJson.parse(coverageBytes(text), config: config)
        }

        let invalid = [
            "", " ", "?", "nul", "truX", "fals", "null x",
            "[", "[1", "[1 2]", "[,]", "{", "{1:2}", "{\"a\" 1}", "{\"a\":1 \"b\":2}",
            "\"", "\"\\", "\"\\x\"", "\"\u{0001}\"", "\"\\u12\"", "\"\\u12x4\"",
            "\"\\uD800\"", "\"\\uD800\\u0041\"", "\"\\uDC00\"",
            "-", "01", "1.", "1e", "1e+"
        ]
        for (text in invalid) {
            @AssertThrows[JsonException](YJson.parse(coverageBytes(text), config: config))
        }

        let invalidUtf8: Array<Array<Byte>> = [
            [b'"', 0x80u8, b'"'], [b'"', 0xC2u8, b'"'], [b'"', 0xC2u8, 0x20u8, b'"'],
            [b'"', 0xE0u8, 0x9Fu8, 0x80u8, b'"'], [b'"', 0xEDu8, 0xA0u8, 0x80u8, b'"'],
            [b'"', 0xE2u8, 0x82u8, b'"'], [b'"', 0xF0u8, 0x8Fu8, 0x80u8, 0x80u8, b'"'],
            [b'"', 0xF4u8, 0x90u8, 0x80u8, 0x80u8, b'"'], [b'"', 0xF0u8, 0x90u8, 0x80u8, b'"']
        ]
        for (bytes in invalidUtf8) {
            @AssertThrows[JsonException](YJson.parse(bytes, config: config))
        }
        let noLocation = JsonReadConfig(includeErrorLocation: false,
            limits: JsonReadLimits(maxStringBytes: 1))
        let error = @AssertThrows[JsonException](YJson.parse(coverageBytes("\"ab\""), config: noLocation))
        @Expect(error.byteOffset, -1)
    }

    @TestCase
    func directWriterCoversTargetsConfigsNumberWidthsAndBulkFallbacks(): Unit {
        let signed: Array<Int64> = [Int64.Min, -10000, -1000, -100, -10, -1, 0, 1, 9, 10, 99,
            100, 999, 1000, 9999, 10000, 99999, 100000, Int64.Max]
        let unsigned: Array<UInt64> = [0u64, 9u64, 10u64, 99u64, 100u64, 999u64, 1000u64,
            9999u64, 10000u64, 99999u64, 100000u64, UInt64.Max]
        for (config in [JsonWriteConfig.compact, JsonWriteConfig.pretty,
            JsonWriteConfig("\r\n", "  ", true, true),
            JsonWriteConfig("", "", true, false)]) {
            let stringWriter = JsonDirectWriter(config)
            stringWriter.startArray()
            for (value in signed) { stringWriter.writeInt64(value) }
            for (value in unsigned) { stringWriter.writeUInt64(value) }
            stringWriter.writeString("\"\\\b\f\n\r\t<>&='仓")
            stringWriter.endArray()
            let text = stringWriter.finishString()
            @Expect(YJson.parse(text).asArray().size(), signed.size + unsigned.size + 1)

            let bytesWriter = JsonDirectWriter.bytes(config: config)
            bytesWriter.startObject(); bytesWriter.writeName("a"); bytesWriter.writeBool(false)
            bytesWriter.writeName("b"); bytesWriter.writeNull(); bytesWriter.endObject()
            @Expect(YJson.parse(String.fromUtf8(bytesWriter.finishBytes())).asObject().size(), 2)

            let output = YJsonMemoryOutputStream()
            let streamWriter = JsonDirectWriter(output, config: config)
            streamWriter.startArray(); streamWriter.writeFloat64(-1.25); streamWriter.endArray()
            streamWriter.finish()
            @Expect(YJson.parse(output.toUtf8String()).asArray()[0].asFloat().value, -1.25)
        }

        let ints = ArrayList<Int64>(); let strings = ArrayList<String>(); let map = HashMap<String, Int64>()
        ints.add(1); strings.add("x\n"); map["x\n"] = 2
        for (config in [JsonWriteConfig.pretty, JsonWriteConfig("", "", false, true)]) {
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
}
