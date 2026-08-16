package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func yJsonRegressionCanParse(text: String): Bool {
    try {
        let _ = YJson.parse(text)
        return true
    } catch (_: Exception) {
        return false
    }
}

func yJsonRegressionDirectNameId(candidate: String, text: String): Int64 {
    let reader = JsonDirectReader(text)
    reader.startObject()
    @Assert(reader.hasObjectField())
    let id = reader.readNameId([candidate])
    let _ = reader.readInt64()
    reader.endObject()
    reader.expectEnd()
    id
}

func yJsonRegressionFastNameId(candidate: String, text: String): Int64 {
    let reader = JsonFastReader(text)
    reader.startRawObject()
    @Assert(reader.hasRawObjectField(true))
    let names = unsafe {
        [candidate.rawData()]
    }
    let id = reader.readRawNameIdBytes(true, names)
    let _ = reader.readRawInt64()
    reader.endRawObject()
    reader.expectEnd()
    id
}

func yJsonRegressionThrowsJsonException(action: () -> Unit): Bool {
    try {
        action()
        return false
    } catch (_: JsonException) {
        return true
    }
}

func yJsonRegressionBytes(text: String): Array<Byte> {
    unsafe {
        text.rawData()
    }
}

func isFastCodec<T>(codec: JsonDirectCodec<T>): Bool {
    match (codec) {
        case _: JsonArrayDirectCodec<T> => true
        case _ => false
    }
}

@Test
class YJsonRegressionTest {
    @TestCase
    func parserRejectsLeadingZeroesInNumbers(): Unit {
        @Expect(!yJsonRegressionCanParse("{\"a\":01}"))
        @Expect(!yJsonRegressionCanParse("{\"a\":-01}"))
        @Expect(yJsonRegressionCanParse("{\"a\":0}"))
        @Expect(yJsonRegressionCanParse("{\"a\":0.1}"))
        @Expect(yJsonRegressionCanParse("{\"a\":0e1}"))
    }

    @TestCase
    func parserRejectsUnescapedControlChars(): Unit {
        @Expect(!yJsonRegressionCanParse("{\"a\":\"\u{0001}\"}"))
        @Expect(yJsonRegressionCanParse("{\"a\":\"\\u0001\"}"))
    }

    @TestCase
    func parserDecodesSurrogatePairs(): Unit {
        let value = YJson.parse("{\"a\":\"\\uD834\\uDD1E\"}").asObject().get("a").getOrThrow().asString().value
        @Expect(value, "\u{1D11E}")
        @Expect(!yJsonRegressionCanParse("{\"a\":\"\\uD834\"}"))
        @Expect(!yJsonRegressionCanParse("{\"a\":\"\\uDD1E\"}"))
    }

    @TestCase
    func directReadersMatchNonAsciiFieldNames(): Unit {
        @Expect(yJsonRegressionDirectNameId("名字", "{\"名字\":1}"), 0)
        @Expect(yJsonRegressionFastNameId("名字", "{\"名字\":1}"), 0)
    }

    @TestCase
    func fastReaderMatchesEscapedFieldNames(): Unit {
        @Expect(yJsonRegressionFastNameId("a\"b", "{\"a\\\"b\":1}"), 0)
        @Expect(yJsonRegressionFastNameId("plain", "{\"a\\\"b\":1}"), -1)
    }

    @TestCase
    func generatedFastReaderHandlesWhitespaceAfterFieldColon(): Unit {
        let decoded = YJson.decodeStringWith(
            PersonJson,
            "{\"user_id\": 42, \"name\": \"Lin\", \"age\": 28, \"tags\": [\"cangjie\", \"json\"], \"scores\": {\"math\": 95}, \"address\": {\"street_name\": \"Nanshan Road\", \"zipcode\": 518000}, \"nick\": null}"
        )
        @Expect(decoded.id, 42)
        @Expect(decoded.name, "Lin")
        @Expect(decoded.scores["math"], 95)
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func directDecodeUsesPublicMemoryStreamFastPath(): Unit {
        let encoded = YJson.encodeBytesWith(PersonJson, samplePerson())
        let decoded = YJson.decodeFromStreamWith(PersonJson, YJsonByteArrayInputStream(encoded))
        @Expect(decoded.id, 42)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func directDecodeKeepsIncrementalFallbackForChunkedStreams(): Unit {
        let encoded = YJson.encodeStringWith(PersonJson, samplePerson())
        let decoded = YJson.decodeFromStreamWith(PersonJson, FixedChunkInputStream(encoded, 1))
        @Expect(decoded.id, 42)
        @Expect(decoded.scores["english"], 88)
        @Expect(decoded.address.street, "Nanshan Road")
    }

    @TestCase
    func generatedDefaultPrettyWriterMatchesGenericPrettyOutput(): Unit {
        let person = samplePerson()
        let fastPretty = YJson.encodeStringWith(PersonJson, person, config: JsonWriteConfig.pretty)
        let genericPrettyOut = MemoryOutputStream()
        YJson.encodeToStreamWith(
            PersonJson,
            person,
            genericPrettyOut,
            config: JsonWriteConfig("\n", "    ", true, false)
        )
        @Expect(fastPretty, genericPrettyOut.toUtf8String())
        @Expect(fastPretty.contains("\n    \"user_id\": 42"))
        @Expect(fastPretty.contains("\n    \"tags\": [\n        \"cangjie\",\n        \"json\",\n        \"reflect\"\n    ]"))
        @Expect(fastPretty.contains("\n        \"math\": 95"))
        @Expect(fastPretty.contains("\n        \"english\": 88"))
        @Expect(fastPretty.contains("\n    \"address\": {\n        \"street_name\": \"Nanshan Road\",\n        \"zipcode\": 518000\n    }"))
        @Expect(fastPretty.contains("\n    \"nick\": null"))
        let decoded = YJson.decodeStringWith(PersonJson, fastPretty)
        @Expect(decoded.address.zipcode, person.address.zipcode)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.scores["english"], 88)
        match (decoded.nick) {
            case Some(_) => @Expect(false)
            case None => @Expect(true)
        }
    }

    @TestCase
    func astDefaultPrettyPersonStringifyRoundtrips(): Unit {
        let person = samplePerson()
        let personAst = YJson.parse(YJson.encodeStringWith(PersonJson, person))
        let pretty = YJson.stringify(personAst, config: JsonWriteConfig.pretty)
        @Expect(pretty.contains("\n    \"user_id\": 42"))
        @Expect(pretty.contains("\n    \"tags\": [\n        \"cangjie\",\n        \"json\",\n        \"reflect\"\n    ]"))
        @Expect(pretty.contains("\n    \"address\": {\n        \"street_name\": \"Nanshan Road\",\n        \"zipcode\": 518000\n    }"))
        let decoded = YJson.decodeStringWith(PersonJson, pretty)
        @Expect(decoded.id, person.id)
        @Expect(decoded.name, person.name)
        @Expect(decoded.address.zipcode, person.address.zipcode)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.scores["english"], 88)
    }

    @TestCase
    func genericCollectionCodecsPreserveFastReaderPath(): Unit {
        let profileListCodec = YJson.arrayListCodec(ProfileRecordJson)
        let int64MapCodec = YJson.hashMapCodec(Int64Json)
        let nestedCodec = nestedProfilesJson()
        let optionCodec = YJson.optionCodec(ProfileRecordJson)

        @Expect(isFastCodec<ArrayList<ProfileRecord>>(profileListCodec))
        @Expect(isFastCodec<HashMap<String, Int64>>(int64MapCodec))
        @Expect(isFastCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>(nestedCodec))
        @Expect(isFastCodec<Option<ProfileRecord>>(optionCodec))

        let profiles = sampleLargeProfileRecords(count: 3)
        let decodedProfiles = YJson.decodeStringWith(
            profileListCodec,
            YJson.encodeStringWith(profileListCodec, profiles)
        )
        @Expect(decodedProfiles.size, 3)
        @Expect(decodedProfiles[2].alias, "alias-2-json-escape")

        let values = sampleLargeInt64Map(count: 3)
        let decodedValues = YJson.decodeStringWith(
            int64MapCodec,
            YJson.encodeStringWith(int64MapCodec, values)
        )
        @Expect(decodedValues["metric_2"], 37)

        let nested = sampleDeepNestedProfiles(groupCount: 2, recordCount: 2)
        let decodedNested = YJson.decodeStringWith(
            nestedCodec,
            YJson.encodeStringWith(nestedCodec, nested)
        )
        @Expect(decodedNested[1]["group_1"][1].id, 101)
    }

    @TestCase
    func specializedScalarCollectionCodecsPreservePublicSemantics(): Unit {
        let integers = ArrayList<Int64>()
        integers.add(-1)
        integers.add(0)
        integers.add(Int64.Max)
        let intCodec = YJson.int64ArrayListCodec()
        let decodedIntegers = YJson.decodeStringWith(intCodec, YJson.encodeStringWith(intCodec, integers))
        @Expect(decodedIntegers.size, 3)
        @Expect(decodedIntegers[0], -1)
        @Expect(decodedIntegers[2], Int64.Max)

        let strings = ArrayList<String>()
        strings.add("ASCII")
        strings.add("仓颉")
        strings.add("quote\"slash\\line\n")
        let stringCodec = YJson.stringArrayListCodec()
        let decodedStrings = YJson.decodeStringWith(stringCodec, YJson.encodeStringWith(stringCodec, strings))
        @Expect(decodedStrings.size, 3)
        @Expect(decodedStrings[1], "仓颉")
        @Expect(decodedStrings[2], "quote\"slash\\line\n")

        let values = HashMap<String, Int64>()
        values["short"] = -7
        values["escaped\"key"] = Int64.Max
        let mapCodec = YJson.int64HashMapCodec()
        let decodedValues = YJson.decodeStringWith(mapCodec, YJson.encodeStringWith(mapCodec, values))
        @Expect(decodedValues["short"], -7)
        @Expect(decodedValues["escaped\"key"], Int64.Max)

        let optionCodec = YJson.stringOptionCodec()
        @Expect(YJson.decodeStringWith(optionCodec, "null").isNone())
        @Expect(YJson.decodeStringWith(optionCodec, "\"仓颉\"").getOrThrow(), "仓颉")
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.decodeStringWith(intCodec, "[1,\"not-an-integer\"]")
        }))
    }

    @TestCase
    func byteNativeAstMatchesStringAstAndRejectsInvalidUtf8(): Unit {
        let text = "{\"ascii\":\"value\",\"cjk\":\"仓颉\",\"emoji\":\"😀\",\"escaped\":\"line\\n\\u4ed3\",\"number\":-9223372036854775808}"
        let fromText = YJson.parse(text)
        let fromBytes = YJson.parse(unsafe { text.rawData() })
        @Expect(fromBytes.toString(), fromText.toString())
        @Expect(fromBytes.asObject().get("cjk").getOrThrow().asString().value, "仓颉")
        let invalid: Array<Byte> = [b'{', b'"', b'x', b'"', b':', b'"', 0xC3u8, 0x28u8, b'"', b'}']
        let error = @AssertThrows[JsonException](YJson.parse(invalid))
        @Expect(error.code, "parse_error")
        @Expect(error.byteOffset >= 6)
        let duplicate = unsafe { "{\"a\":1,\"a\":2}".rawData() }
        @Expect(YJson.parse(duplicate).asObject().get("a").getOrThrow().asInt().value, 2)
        let duplicateError = @AssertThrows[JsonException](YJson.parse(
            duplicate,
            config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        ))
        let stringDuplicateError = @AssertThrows[JsonException](YJson.parse(
            "{\"a\":1,\"a\":2}",
            config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        ))
        @Expect(duplicateError.code, stringDuplicateError.code)
        @AssertThrows[JsonException](YJson.parse(unsafe { "{\"a\":\"unterminated".rawData() }))
        @AssertThrows[JsonException](YJson.parse(unsafe { "\"\\x\"".rawData() }))
    }

    @TestCase
    func generatedArrayListFastReaderFallsBackForWhitespaceArrays(): Unit {
        let profileListCodec = YJson.arrayListCodec(ProfileRecordJson)
        let decoded = YJson.decodeStringWith(
            profileListCodec,
            "[\n" +
                "  {\"profile_id\":1,\"alias\":\"one\",\"level\":7},\n" +
                "  {\"profile_id\":2,\"alias\":\"two\",\"level\":8}\n" +
            "]"
        )
        @Expect(decoded.size, 2)
        @Expect(decoded[1].alias, "two")
    }

    @TestCase
    func orderedFastReaderKeepsDuplicateTrailingFieldSemantics(): Unit {
        let decoded = YJson.decodeStringWith(
            ProfileRecordJson,
            "{\"profile_id\":1,\"alias\":\"first\",\"level\":7,\"alias\":\"second\"}"
        )
        @Expect(decoded.alias, "second")
    }

    @TestCase
    func generatedPersonFastReaderKeepsReorderedAndUnknownSemantics(): Unit {
        let reversedWithDuplicateTail = "{" +
            "\"nick\":null," +
            "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
            "\"scores\":{\"english\":88,\"math\":95}," +
            "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
            "\"age\":28," +
            "\"name\":\"Lin\"," +
            "\"user_id\":42," +
            "\"name\":\"Last\"}"
        let decodedDuplicate = YJson.decodeStringWith(PersonJson, reversedWithDuplicateTail)
        @Expect(decodedDuplicate.id, 42)
        @Expect(decodedDuplicate.name, "Last")
        @Expect(decodedDuplicate.scores["english"], 88)

        let unknownGaps = "{" +
            "\"user_id\":42," +
            "\"unknownObject\":{\"left\":[1,{\"deep\":\"x\\\"y\"}],\"right\":{\"enabled\":true}}," +
            "\"name\":\"Lin\"," +
            "\"age\":28," +
            "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
            "\"scores\":{\"math\":95,\"english\":88}," +
            "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000,\"ignored\":true}," +
            "\"unknownArray\":[{\"x\":1},null,false]," +
            "\"unknownString\":\"left\\\"mid\\\\tail\"," +
            "\"nick\":null}"
        let decodedUnknown = YJson.decodeStringWith(PersonJson, unknownGaps)
        @Expect(decodedUnknown.id, 42)
        @Expect(decodedUnknown.name, "Lin")
        @Expect(decodedUnknown.tags[2], "reflect")
        @Expect(decodedUnknown.address.zipcode, 518000)
        match (decodedUnknown.nick) {
            case Some(_) => @Expect(false)
            case None => @Expect(true)
        }

        let partiallyOrdered = YJson.decodeStringWith(
            PersonJson,
            "{" +
                "\"user_id\":42," +
                "\"scores\":{\"english\":88,\"math\":95}," +
                "\"name\":\"Lin\"," +
                "\"nick\":null," +
                "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
                "\"age\":28," +
                "\"tags\":[\"cangjie\",\"json\",\"reflect\"]" +
            "}"
        )
        @Expect(partiallyOrdered.id, 42)
        @Expect(partiallyOrdered.name, "Lin")
        @Expect(partiallyOrdered.tags[2], "reflect")
        @Expect(partiallyOrdered.address.zipcode, 518000)

        let mixedOrder = YJson.decodeStringWith(
            PersonJson,
            "{" +
                "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
                "\"age\":28," +
                "\"user_id\":42," +
                "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
                "\"nick\":null," +
                "\"name\":\"Lin\"," +
                "\"scores\":{\"english\":88,\"math\":95}" +
            "}"
        )
        @Expect(mixedOrder.id, 42)
        @Expect(mixedOrder.name, "Lin")
        @Expect(mixedOrder.scores["math"], 95)
        @Expect(mixedOrder.address.street, "Nanshan Road")
    }

    @TestCase
    func generatedPersonFieldIdDispatchKeepsFallbackSemanticsForStringAndBytes(): Unit {
        let escapedAndUnicodeUnknown = "{" +
            "\"user_\\u0069d\":42," +
            "\"名字\":{\"nested\":[1,true,null]}," +
            "\"name\":\"Lin\"," +
            "\"age\":28," +
            "\"tags\":[\"cangjie\",\"json\"]," +
            "\"scores\":{\"math\":95}," +
            "\"address\":{\"zipcode\":518000,\"street_\\u006eame\":\"Nanshan Road\"}," +
            "\"nick\":null" +
            "}"

        let fromString = YJson.decodeStringWith(PersonJson, escapedAndUnicodeUnknown)
        let fromBytes = YJson.decodeBytesWith(PersonJson, yJsonRegressionBytes(escapedAndUnicodeUnknown))
        @Expect(fromString.id, 42)
        @Expect(fromString.address.street, "Nanshan Road")
        @Expect(fromBytes.id, fromString.id)
        @Expect(fromBytes.name, fromString.name)
        @Expect(fromBytes.address.street, fromString.address.street)
        @Expect(fromBytes.scores["math"], 95)
    }

    @TestCase
    func fastReaderSkipsUnknownEscapedStringsWithoutAllocatingValues(): Unit {
        let decoded = YJson.decodeStringWith(
            PersonJson,
            "{" +
                "\"user_id\":42," +
                "\"ignored\":{\"escaped\":\"a\\\"b\\\\c\\n\\t\\uD834\\uDD1E\",\"array\":[\"x\",{\"y\":\"z\"}]}," +
                "\"name\":\"Lin\"," +
                "\"age\":28," +
                "\"tags\":[\"cangjie\",\"json\"]," +
                "\"scores\":{\"math\":95}," +
                "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000}," +
                "\"nick\":null" +
            "}"
        )
        @Expect(decoded.id, 42)
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func fastReaderBytesEscapedAsciiDecodeKeepsValidationFallbacks(): Unit {
        let escapedAscii = JsonFastReader(yJsonRegressionBytes("\"a\\\"b\\\\c\\n\\t\\uD834\\uDD1E\""))
        @Expect(escapedAscii.readRawString(), "a\"b\\c\n\t\u{1D11E}")
        escapedAscii.expectEnd()

        let rawUtf8 = JsonFastReader(yJsonRegressionBytes("\"é\\n\""))
        @Expect(rawUtf8.readRawString(), "é\n")
        rawUtf8.expectEnd()

        let mixedRawUtf8 = yJsonRegressionBytes("\"Cangjie JSON \\\"escape\\\" \\\\ slash / line\\n tab\\t raw 仓颉 Δ ✓ unicode \\u4ed3\\u9889 \\u0394 \\u2713\"")
        @Expect(
            YJson.decodeBytesWith(StringJson, mixedRawUtf8),
            "Cangjie JSON \"escape\" \\ slash / line\n tab\t raw 仓颉 Δ ✓ unicode 仓颉 Δ ✓"
        )
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let invalidUtf8: Array<Byte> = [b'"', 0xE4u8, 0xB8u8, b'\\', b'n', b'"']
            let _ = YJson.decodeBytesWith(StringJson, invalidUtf8)
        }))
    }

    @TestCase
    func nativeStringDecodeFallsBackForRawUtf8WhenValidatingBytes(): Unit {
        let text = "\"仓颉\\n\""
        let bytes = yJsonRegressionBytes(text)
        match (jsonNativeDecodeString(bytes, bytes.size, 0, true)) {
            case Some(_) => throw JsonException("native scanner should leave raw UTF-8 validation to fallback")
            case None => ()
        }
        @Expect(YJson.decodeStringWith(StringJson, text), "仓颉\n")
    }

    @TestCase
    func nativeObjectScannerFallsBackForEscapedFieldNames(): Unit {
        let text = "{\"a\\u0062\":1,\"padding_key\":\"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\"}"
        let bytes = yJsonRegressionBytes(text)
        match (jsonNativeScanObjectFields(bytes, bytes.size, 0, false)) {
            case Some(_) => throw JsonException("native scanner should leave escaped field names to fallback")
            case None => ()
        }
    }

    @TestCase
    func fastReaderDecodesEscapedStringChunks(): Unit {
        @Expect(
            YJson.decodeStringWith(StringJson, "\"left\\\"mid\\\\line\\n\\t\\u4ed3\\u9889\\uD834\\uDD1Eright\""),
            "left\"mid\\line\n\t仓颉\u{1D11E}right"
        )
    }

    @TestCase
    func fastReaderEscapedStringPreservesByteValidationFallback(): Unit {
        let text = "\"仓颉\\n\\u2713\""
        @Expect(YJson.decodeBytesWith(StringJson, yJsonRegressionBytes(text)), "仓颉\n✓")
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.decodeBytesWith(StringJson, yJsonRegressionBytes("\"\\uD834\""))
        }))
    }

    @TestCase
    func floatWritersRejectNonFiniteValues(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.encodeStringWith(Float64Json, Float64.NaN)
        }))
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.encodeStringWith(Float64Json, Float64.Inf)
        }))
    }

    @TestCase
    func jsonExceptionCarriesStructuredParseLocation(): Unit {
        try {
            let _ = YJson.parse("{\n\"a\":01}")
            throw JsonException("expected parse failure")
        } catch (error: JsonException) {
            @Expect(error.message, "Leading zeroes are not allowed in JSON numbers")
            @Expect(error.code, "parse_error")
            @Expect(error.byteOffset, 7)
            @Expect(error.line, 2)
            @Expect(error.column, 6)
            @Expect(error.path, "")
        }
    }

    @TestCase
    func jsonReadConfigCanDisableErrorLocation(): Unit {
        try {
            let _ = YJson.parse(
                "{\n\"a\":01}",
                config: JsonReadConfig(includeErrorLocation: false)
            )
            throw JsonException("expected parse failure")
        } catch (error: JsonException) {
            @Expect(error.byteOffset, -1)
            @Expect(error.line, -1)
            @Expect(error.column, -1)
        }
    }

    @TestCase
    func jsonReadConfigCanRejectDuplicateKeys(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.parse(
                "{\"a\":1,\"a\":2}",
                config: JsonReadConfig(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
            )
        }))
    }

    @TestCase
    func jsonReadConfigCanPreserveIntegerNumberLiterals(): Unit {
        let value = YJson.parse("42", config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral))
        match (value) {
            case literal: JsonNumberLiteralValue => @Expect(literal.literal, "42")
            case _ => throw JsonException("expected number literal")
        }
    }

    @TestCase
    func jsonCodecConfigCanRejectUnknownDirectFields(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.decodeStringWith(
                ProfileRecordJson,
                "{\"profile_id\":1,\"alias\":\"one\",\"level\":7,\"extra\":true}",
                config: JsonReadConfig(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)
            )
        }))
    }

    @TestCase
    func jsonConfigDefaultsKeepExistingCompactBehavior(): Unit {
        @Expect(jsonReadConfigUsesDefaultFastPath(JsonReadConfig.defaults))
        @Expect(JsonWriteConfig.compact.newline, "")
        @Expect(JsonWriteConfig.compact.indent, "")
        @Expect(!JsonWriteConfig.compact.useSpaceAfterSeparators)
        @Expect(!JsonWriteConfig.compact.htmlSafe)
        @Expect(JsonWriteConfig.compact.includeErrorLocation)
        @Expect(YJson.encodeStringWith(StringJson, "<tag>"), "\"<tag>\"")
        @Expect(YJson.encodeStringWith(StringJson, "<tag>", config: JsonWriteConfig(
            "",
            "",
            false,
            true
        )), "\"\\u003ctag\\u003e\"")
    }
}
