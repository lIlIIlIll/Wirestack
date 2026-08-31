package yjson

import yjson_macros.*

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private class RegressionNonFastIntCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonWriter): Unit {
        writer.writeInt64(value)
    }

    public func read(reader: JsonReader): Int64 {
        reader.readInt64()
    }
}

private class RegressionPathFailingIntCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonWriter): Unit {
        if (value == 2) {
            throw writer.error("intentional encode failure", "test_failure")
        }
        writer.writeInt64(value)
    }

    public func read(reader: JsonReader): Int64 {
        reader.readInt64()
    }
}

private class RegressionReentrantStreamCodec <: JsonCodec<Int64> {
    public func write(value: Int64, writer: JsonWriter): Unit {
        let nested = MemoryOutputStream()
        YJson.writeJson(value + 1, nested, codec: JsonCodecs.int64)
        @Expect(nested.toUtf8String(), (value + 1).toString())
        writer.writeInt64(value)
    }

    public func read(reader: JsonReader): Int64 {
        let nested = YJson.fromJson(YJsonByteArrayInputStream("41"), codec: JsonCodecs.int64)
        @Expect(nested, 41)
        reader.readInt64()
    }
}

private let RegressionReentrantStreamJson: JsonCodec<Int64> = RegressionReentrantStreamCodec()

func yJsonRegressionCanParse(text: String): Bool {
    try {
        let _ = JsonNode.parse(text)
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

func yJsonRegressionDirectNameIdBytes(candidate: String, text: String): Int64 {
    let bytes = unsafe { text.rawData().clone() }
    let reader = JsonDirectReader(bytes)
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

func isFastCodec<T>(codec: JsonCodec<T>): Bool {
    match (codec) {
        case _: GeneratedCodecV1<T> => true
        case _ => false
    }
}

@JsonCodec
public class ScalarScratchDefaults {
    public var enabled: Bool = true
    public var i8: Int8 = Int8(7)
    public var i16: Int16 = Int16(7)
    public var i32: Int32 = Int32(7)
    public var i64: Int64 = Int64(7)
    public var u8: UInt8 = UInt8(7)
    public var u16: UInt16 = UInt16(7)
    public var u32: UInt32 = UInt32(7)
    public var u64: UInt64 = UInt64(7)
    public var f16: Float16 = Float16(7)
    public var f32: Float32 = Float32(7)
    public var f64: Float64 = Float64(7)

    public init() {}
}

@JsonCodec
public class AliasRecord {
    @JsonAlias["legacy_id"]
    public let id: Int64
    public var label: String = ""

    public init(id: Int64) {
        this.id = id
    }
}

@Test
class YJsonRegressionTest {
    @TestCase
    func escapedStringSizeCoversNativePreflightCategories(): Unit {
        @Expect(jsonEscapedStringLiteralSize("plain", false), 7)
        @Expect(jsonEscapedStringLiteralSize("\"\\\b\f\n\r\t\u{001F}", false), 22)
        @Expect(jsonEscapedStringLiteralSize("<>&='", false), 7)
        @Expect(jsonEscapedStringLiteralSize("<>&='", true), 32)
        @Expect(jsonEscapedStringLiteralSize("仓颉", false), 8)
    }

    @TestCase
    func generatedFastDecodeRejectsMalformedUnknownKeys(): Unit {
        let control: Array<Byte> = [b'{', b'"', 0x01u8, b'"', b':', b'0', b'}']
        let controlError = @AssertThrows[JsonException](YJson.fromJson(control, codec: PersonJson))
        @Expect(controlError.code, "parse_error")
        @Expect(controlError.location.getOrThrow().byteOffset >= 0)

        let invalidUtf8: Array<Byte> = [b'{', b'"', 0xC3u8, b'(', b'"', b':', b'0', b'}']
        let utf8Error = @AssertThrows[JsonException](YJson.fromJson(invalidUtf8, codec: PersonJson))
        @Expect(utf8Error.code, "parse_error")
        @Expect(utf8Error.location.getOrThrow().byteOffset >= 0)
    }

    @TestCase
    func generatedUnknownFieldSkipCannotBypassDepthBudget(): Unit {
        let semanticError = @AssertThrows[JsonException](YJson.fromJson("{\"unknown\":[[]]}", codec: PersonJson, options: JsonReadOptions(maxDepth: 2)))
        @Expect(semanticError.code, "max_depth")

        let text = StringBuilder("{\"unknown\":")
        for (_ in 0..256) { text.append("[") }
        text.append("0")
        for (_ in 0..256) { text.append("]") }
        text.append("}")
        let fastError = @AssertThrows[JsonException](
            YJson.fromJson(text.toString(), codec: PersonJson))
        @Expect(fastError.code, "max_depth")
    }
    @TestCase
    func typedFacadePreservesStringBytesAndOptionsSemantics(): Unit {
        let compact = "{\"profile_id\":7,\"alias\":\"fast\",\"level\":3}"
        let fromString = YJson.fromJson(compact, codec: ProfileRecordJson)
        let fromBytes = YJson.fromJson(yJsonRegressionBytes(compact), codec: ProfileRecordJson)
        @Expect(fromString.id, 7)
        @Expect(fromString.alias, "fast")
        @Expect(fromString.level, Int32(3))
        @Expect(fromBytes.id, 7)
        @Expect(fromBytes.alias, "fast")
        @Expect(fromBytes.level, Int32(3))

        let unknownError = @AssertThrows[JsonException](YJson.fromJson(
            "{\"profile_id\":7,\"alias\":\"fast\",\"level\":3,\"extra\":1}",
            codec: ProfileRecordJson,
            options: JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)
        ))
        @Expect(unknownError.code, "unknown_field")
    }

    @TestCase
    func typedFacadeFallsBackToSemanticCodec(): Unit {
        @Expect(YJson.fromJson("41", codec: RegressionNonFastIntCodec()), 41)
    }

    @TestCase
    func compactNameProbeMissKeepsGeneralDispatcherCursor(): Unit {
        let reader = JsonFastReader("{\"first\":1,\"second\":2}")
        let names = unsafe { ["first".rawData(), "second".rawData()] }
        let missing = unsafe { "missing".rawData() }
        reader.startRawObject()
        @Expect(reader.tryReadRawCompactNameTokenBytes(true, names[0]))
        @Expect(reader.readRawInt64(), 1)
        @Expect(!reader.tryReadRawCompactNameTokenBytes(false, missing))
        @Expect(reader.readRawNameIdBytes(false, names), 1)
        @Expect(reader.readRawInt64(), 2)
        reader.endRawObject()
        reader.expectEnd()
    }

    @TestCase
    func generatedOrderedFastReaderFallsBackForAliasesAndEscapedNames(): Unit {
        let aliasText = "{\"legacy_id\":7,\"label\":\"legacy\"}"
        let escapedText = "{\"\\u0069d\":8,\"label\":\"escaped\"}"
        let fromAlias = YJson.fromJson(aliasText, codec: AliasRecordJson)
        let fromEscapedBytes = YJson.fromJson(yJsonRegressionBytes(escapedText), codec: AliasRecordJson)
        @Expect(fromAlias.id, 7)
        @Expect(fromAlias.label, "legacy")
        @Expect(fromEscapedBytes.id, 8)
        @Expect(fromEscapedBytes.label, "escaped")
    }

    @TestCase
    func generatedScalarScratchKeepsDefaultsAndBothInputKinds(): Unit {
        let defaults = YJson.fromJson("{}", codec: ScalarScratchDefaultsJson)
        @Expect(defaults.enabled)
        @Expect(defaults.i64, 7)
        @Expect(defaults.u64, UInt64(7))
        @Expect(defaults.f64, Float64(7))

        let text = "{" +
            "\"enabled\":false,\"i8\":-8,\"i16\":-16,\"i32\":-32,\"i64\":-64," +
            "\"u8\":8,\"u16\":16,\"u32\":32,\"u64\":64," +
            "\"f16\":1.5,\"f32\":2.5,\"f64\":3.5}"
        let fromString = YJson.fromJson(text, codec: ScalarScratchDefaultsJson)
        let fromBytes = YJson.fromJson(yJsonRegressionBytes(text), codec: ScalarScratchDefaultsJson)
        @Expect(!fromString.enabled)
        @Expect(fromString.i8, Int8(-8))
        @Expect(fromString.i16, Int16(-16))
        @Expect(fromString.i32, Int32(-32))
        @Expect(fromString.i64, Int64(-64))
        @Expect(fromString.u8, UInt8(8))
        @Expect(fromString.u16, UInt16(16))
        @Expect(fromString.u32, UInt32(32))
        @Expect(fromString.u64, UInt64(64))
        @Expect(fromString.f16, Float16(1.5))
        @Expect(fromString.f32, Float32(2.5))
        @Expect(fromString.f64, Float64(3.5))
        @Expect(fromBytes.i64, fromString.i64)
        @Expect(fromBytes.u64, fromString.u64)
        @Expect(fromBytes.f64, fromString.f64)

        let duplicate = YJson.fromJson("{\"i64\":1,\"i64\":2}", codec: ScalarScratchDefaultsJson,
            options: JsonReadOptions(duplicateKeyPolicy: LastWins))
        @Expect(duplicate.i64, 2)
        @AssertThrows[JsonException](YJson.fromJson("{\"i64\":1,\"i64\":2}", codec: ScalarScratchDefaultsJson, options: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)))
    }

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
        let value = JsonNode.parse("{\"a\":\"\\uD834\\uDD1E\"}").asObject().get("a").getOrThrow().asString()
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
    func directNameIdValidatesEscapedSurrogates(): Unit {
        for (text in ["{\"\\uD800\":1}", "{\"\\uDC00\":1}"]) {
            let stringError = @AssertThrows[JsonException](
                yJsonRegressionDirectNameId("plain", text))
            @Expect(stringError.code, "parse_error")
            let bytesError = @AssertThrows[JsonException](
                yJsonRegressionDirectNameIdBytes("plain", text))
            @Expect(bytesError.code, "parse_error")
        }
        @Expect(yJsonRegressionDirectNameId("plain", "{\"\\uD834\\uDD1E\":1}"), -1)
        @Expect(yJsonRegressionDirectNameIdBytes("plain", "{\"\\uD834\\uDD1E\":1}"), -1)
    }

    @TestCase
    func fastReaderMatchesEscapedFieldNames(): Unit {
        @Expect(yJsonRegressionFastNameId("a\"b", "{\"a\\\"b\":1}"), 0)
        @Expect(yJsonRegressionFastNameId("plain", "{\"a\\\"b\":1}"), -1)
    }

    @TestCase
    func generatedFastReaderHandlesWhitespaceAfterFieldColon(): Unit {
        let decoded = YJson.fromJson("{\"user_id\": 42, \"name\": \"Lin\", \"age\": 28, \"tags\": [\"cangjie\", \"json\"], \"scores\": {\"math\": 95}, \"address\": {\"street_name\": \"Nanshan Road\", \"zipcode\": 518000}, \"nick\": null}", codec: PersonJson)
        @Expect(decoded.id, 42)
        @Expect(decoded.name, "Lin")
        @Expect(decoded.scores["math"], 95)
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func directDecodeUsesPublicMemoryStreamFastPath(): Unit {
        let encoded = YJson.toJsonBytes(samplePerson(), codec: PersonJson)
        let decoded = YJson.fromJson(YJsonByteArrayInputStream(encoded), codec: PersonJson)
        @Expect(decoded.id, 42)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func directDecodeKeepsIncrementalFallbackForChunkedStreams(): Unit {
        let encoded = YJson.toJson(samplePerson(), codec: PersonJson)
        let decoded = YJson.fromJson(FixedChunkInputStream(encoded, 1), codec: PersonJson)
        @Expect(decoded.id, 42)
        @Expect(decoded.scores["english"], 88)
        @Expect(decoded.address.street, "Nanshan Road")
    }

    @TestCase
    func providerStreamConveniencesUsePureBackendByDefault(): Unit {
        let output = MemoryOutputStream()
        YJson.writeJson(samplePerson(), output)
        let decoded = YJson.fromJson<Person>(YJsonByteArrayInputStream(output.toByteArray()))
        @Expect(decoded.id, 42)
        @Expect(decoded.address.zipcode, 518000)
    }

    @TestCase
    func streamCallsIsolateConfigFailureAndPathState(): Unit {
        let limited = JsonReadOptions(maxStringBytes: 2)
        let error = @AssertThrows[JsonException](YJson.fromJson(FixedChunkInputStream("\"abcd\"", 1), codec: JsonCodecs.string, options: limited))
        @Expect(error.code, "string_too_large")

        @Expect(YJson.fromJson(FixedChunkInputStream("\"ok after failure\"", 1), codec: JsonCodecs.string), "ok after failure")

        let rejectUnknown = JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)
        let withUnknown = "{" +
            "\"unknown\":1,\"user_id\":42,\"name\":\"Lin\",\"age\":28," +
            "\"tags\":[\"cangjie\"],\"scores\":{\"math\":95}," +
            "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000}," +
            "\"nick\":null}"
        @AssertThrows[JsonException](YJson.fromJson(YJsonByteArrayInputStream(withUnknown), codec: PersonJson, options: rejectUnknown))
        @Expect(YJson.fromJson(YJsonByteArrayInputStream(withUnknown), codec: PersonJson).id, 42)
    }

    @TestCase
    func streamCallsSupportSameThreadReentry(): Unit {
        @Expect(YJson.fromJson(YJsonByteArrayInputStream("7"), codec: RegressionReentrantStreamJson), 7)
        let output = MemoryOutputStream()
        YJson.writeJson(9, output, codec: RegressionReentrantStreamJson)
        @Expect(output.toUtf8String(), "9")
    }

    @TestCase
    func streamWriterCallsIsolateFailureAndConfigState(): Unit {
        let limited = JsonWriteOptions(maxOutputBytes: 3)
        @AssertThrows[JsonException](YJson.writeJson("long", MemoryOutputStream(), codec: JsonCodecs.string, options: limited))

        let compact = MemoryOutputStream()
        YJson.writeJson("safe", compact, codec: JsonCodecs.string)
        @Expect(compact.toUtf8String(), "\"safe\"")

        let pretty = MemoryOutputStream()
        YJson.writeJson([1, 2], pretty, codec: JsonCodecs.array(JsonCodecs.int64), options: JsonWriteOptions.pretty())
        @Expect(pretty.toUtf8String().contains("\n"))

        let compactAgain = MemoryOutputStream()
        YJson.writeJson([1, 2], compactAgain, codec: JsonCodecs.array(JsonCodecs.int64))
        @Expect(compactAgain.toUtf8String(), "[1,2]")
    }

    @TestCase
    func writeByteLimitAppliesToAllPureTargets(): Unit {
        @AssertThrows[IllegalArgumentException](JsonWriteOptions(maxOutputBytes: -1))
        let config = JsonWriteOptions(maxOutputBytes: 3)
        let stringError = @AssertThrows[JsonException](YJson.toJson("long", codec: JsonCodecs.string, options: config))
        @Expect(stringError.code, "output_too_large")
        let bytesError = @AssertThrows[JsonException](YJson.toJsonBytes("long", codec: JsonCodecs.string, options: config))
        @Expect(bytesError.code, "output_too_large")
        let streamError = @AssertThrows[JsonException](YJson.writeJson("long", MemoryOutputStream(), codec: JsonCodecs.string, options: config))
        @Expect(streamError.code, "output_too_large")
    }

    @TestCase
    func publicWriterTargetsAreByteIdenticalForEveryOutputProfile(): Unit {
        let codec = JsonCodecs.arrayList(ProfileRecordJson)
        let values = ArrayList<ProfileRecord>()
        values.add(makeProfileRecord(-7, "quote\"slash\\line\n<tag>", -3))
        values.add(makeProfileRecord(9, "仓颉😀", 11))
        let configs = [
            JsonWriteOptions.compact,
            JsonWriteOptions.pretty(),
            JsonWriteOptions(indent: "\t"),
            JsonWriteOptions(htmlSafe: true)
        ]
        for (config in configs) {
            let stringOutput = YJson.toJson(values, codec: codec, options: config)
            let byteOutput = String.fromUtf8(YJson.toJsonBytes(values, codec: codec, options: config))
            let stream = MemoryOutputStream()
            YJson.writeJson(values, stream, codec: codec, options: config)
            @Expect(byteOutput, stringOutput)
            @Expect(stream.toUtf8String(), stringOutput)
            @Expect(YJson.fromJson(stringOutput, codec: codec)[1].alias, "仓颉😀")
        }
    }

    @TestCase
    func streamWriterRejectsIllegalStructuralOrder(): Unit {
        let writer = JsonDirectWriter(MemoryOutputStream(), config: JsonWriteOptions.compact)
        @AssertThrows[JsonException](writer.writeName("orphan"))
        writer.startArray()
        writer.writeNull()
        writer.endArray()
        writer.finish()
    }

    @TestCase
    func generatedDefaultPrettyWriterMatchesGenericPrettyOutput(): Unit {
        let person = samplePerson()
        let fastPretty = YJson.toJson(person, codec: PersonJson, options: JsonWriteOptions.pretty())
        let genericPrettyOut = MemoryOutputStream()
        YJson.writeJson(person, genericPrettyOut, codec: PersonJson, options: JsonWriteOptions.pretty())
        @Expect(fastPretty, genericPrettyOut.toUtf8String())
        @Expect(fastPretty.contains("\n  \"user_id\": 42"))
        @Expect(fastPretty.contains("\n  \"tags\": [\n    \"cangjie\",\n    \"json\",\n    \"reflect\"\n  ]"))
        @Expect(fastPretty.contains("\n    \"math\": 95"))
        @Expect(fastPretty.contains("\n    \"english\": 88"))
        @Expect(fastPretty.contains("\n  \"address\": {\n    \"street_name\": \"Nanshan Road\",\n    \"zipcode\": 518000\n  }"))
        @Expect(fastPretty.contains("\n  \"nick\": null"))
        let decoded = YJson.fromJson(fastPretty, codec: PersonJson)
        @Expect(decoded.address.zipcode, person.address.zipcode)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.scores["english"], 88)
        match (decoded.nick) {
            case Some(_) => @Expect(false)
            case None => @Expect(true)
        }
    }

    @TestCase
    func generatedCompactRawRecordPreservesTargetsConfigAndDepthPath(): Unit {
        let profile = makeProfileRecord(-7, "quote\"slash\\line\n<tag>", -3)
        let expected = "{\"profile_id\":-7,\"alias\":\"quote\\\"slash\\\\line\\n<tag>\",\"level\":-3}"
        @Expect(YJson.toJson(profile, codec: ProfileRecordJson), expected)
        @Expect(String.fromUtf8(YJson.toJsonBytes(profile, codec: ProfileRecordJson)), expected)
        let output = MemoryOutputStream()
        YJson.writeJson(profile, output, codec: ProfileRecordJson)
        @Expect(output.toUtf8String(), expected)

        let pretty = YJson.toJson(profile, codec: ProfileRecordJson, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"profile_id\": -7"))
        @Expect(YJson.fromJson(pretty, codec: ProfileRecordJson).alias, profile.alias)
        let htmlSafe = YJson.toJson(profile, codec: ProfileRecordJson, options: JsonWriteOptions(htmlSafe: true))
        @Expect(htmlSafe.contains("\\u003ctag\\u003e"))
        let custom = YJson.toJson(profile, codec: ProfileRecordJson, options: JsonWriteOptions(indent: "\t"))
        @Expect(custom.contains("\n\t\"alias\": "))
        @Expect(YJson.fromJson(custom, codec: ProfileRecordJson).alias, profile.alias)

        let profiles = ArrayList<ProfileRecord>()
        profiles.add(profile)
        let codec = JsonCodecs.arrayList(ProfileRecordJson)
        let depthError = @AssertThrows[JsonException](YJson.toJson(profiles, codec: codec, options: JsonWriteOptions(maxDepth: 1)))
        @Expect(depthError.code, "max_depth")
        @Expect(depthError.path, "/0")
        @Expect(YJson.fromJson(YJson.toJson(profiles, codec: codec, options: JsonWriteOptions(maxDepth: 2)), codec: codec)[0].alias, profile.alias)

        let profilesByName = HashMap<String, ArrayList<ProfileRecord>>()
        profilesByName["group"] = profiles
        let nested = ArrayList<HashMap<String, ArrayList<ProfileRecord>>>()
        nested.add(profilesByName)
        let nestedCodec = JsonCodecs.arrayList(JsonCodecs.stringMap(JsonCodecs.arrayList(ProfileRecordJson)))
        let nestedExpected = "[{\"group\":[${expected}]}]"
        @Expect(YJson.toJson(nested, codec: nestedCodec), nestedExpected)
        @Expect(String.fromUtf8(YJson.toJsonBytes(nested, codec: nestedCodec)), nestedExpected)
        let nestedOutput = MemoryOutputStream()
        YJson.writeJson(nested, nestedOutput, codec: nestedCodec)
        @Expect(nestedOutput.toUtf8String(), nestedExpected)
        let nestedPretty = YJson.toJson(nested, codec: nestedCodec, options: JsonWriteOptions.pretty())
        @Expect(YJson.fromJson(nestedPretty, codec: nestedCodec)[0]["group"][0].alias, profile.alias)
        let nestedDepthError = @AssertThrows[JsonException](YJson.toJson(nested, codec: nestedCodec, options: JsonWriteOptions(maxDepth: 3)))
        @Expect(nestedDepthError.code, "max_depth")
        @Expect(nestedDepthError.path, "/0/group/0")
        @Expect(YJson.fromJson(YJson.toJson(nested, codec: nestedCodec, options: JsonWriteOptions(maxDepth: 4)), codec: nestedCodec)[0]["group"][0].id, profile.id)

        let profileArrayCodec = JsonCodecs.array(ProfileRecordJson)
        @Expect(YJson.toJson(profiles.toArray(), codec: profileArrayCodec), "[${expected}]")
        let profileOptionCodec = JsonCodecs.option(ProfileRecordJson)
        @Expect(YJson.toJson(Some(profile), codec: profileOptionCodec), expected)
        @Expect(YJson.toJson(None<ProfileRecord>, codec: profileOptionCodec), "null")
    }

    @TestCase
    func astDefaultPrettyPersonStringifyRoundtrips(): Unit {
        let person = samplePerson()
        let personAst = JsonNode.parse(YJson.toJson(person, codec: PersonJson))
        let pretty = (personAst).toJson(options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"user_id\": 42"))
        @Expect(pretty.contains("\n  \"tags\": [\n    \"cangjie\",\n    \"json\",\n    \"reflect\"\n  ]"))
        @Expect(pretty.contains("\n  \"address\": {\n    \"street_name\": \"Nanshan Road\",\n    \"zipcode\": 518000\n  }"))
        let decoded = YJson.fromJson(pretty, codec: PersonJson)
        @Expect(decoded.id, person.id)
        @Expect(decoded.name, person.name)
        @Expect(decoded.address.zipcode, person.address.zipcode)
        @Expect(decoded.tags[2], "reflect")
        @Expect(decoded.scores["english"], 88)
    }

    @TestCase
    func genericCollectionCodecsPreserveFastReaderPath(): Unit {
        let profileArrayCodec = JsonCodecs.array(ProfileRecordJson)
        let profileListCodec = JsonCodecs.arrayList(ProfileRecordJson)
        let int64MapCodec = JsonCodecs.stringMap(JsonCodecs.int64)
        let profileMapCodec = JsonCodecs.stringMap(ProfileRecordJson)
        let nestedCodec = nestedProfilesJson()
        let optionCodec = JsonCodecs.option(ProfileRecordJson)

        @Expect(isFastCodec<Array<ProfileRecord>>(profileArrayCodec))
        @Expect(isFastCodec<ArrayList<ProfileRecord>>(profileListCodec))
        @Expect(isFastCodec<HashMap<String, Int64>>(int64MapCodec))
        @Expect(isFastCodec<HashMap<String, ProfileRecord>>(profileMapCodec))
        @Expect(isFastCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>(nestedCodec))
        @Expect(isFastCodec<Option<ProfileRecord>>(optionCodec))

        let emptyProfiles = YJson.fromJson("[ ]", codec: profileListCodec)
        let emptyProfilesAgain = YJson.fromJson(yJsonRegressionBytes("[]"), codec: profileListCodec)
        emptyProfiles.add(makeProfileRecord(1, "fresh", 1))
        @Expect(emptyProfilesAgain.isEmpty())
        @Expect(YJson.fromJson("[ ]", codec: profileArrayCodec).size, 0)
        @Expect(YJson.fromJson(yJsonRegressionBytes("[]"), codec: profileArrayCodec).size, 0)

        let emptyProfilesByName = YJson.fromJson("{ }", codec: profileMapCodec)
        let emptyProfilesByNameAgain = YJson.fromJson(yJsonRegressionBytes("{}"), codec: profileMapCodec)
        emptyProfilesByName["fresh"] = makeProfileRecord(1, "fresh", 1)
        @Expect(emptyProfilesByNameAgain.isEmpty())

        let profiles = sampleLargeProfileRecords(count: 3)
        let encodedProfiles = YJson.toJson(profiles, codec: profileListCodec)
        let decodedProfiles = YJson.fromJson(encodedProfiles, codec: profileListCodec)
        let decodedProfileBytes = YJson.fromJson(yJsonRegressionBytes(encodedProfiles), codec: profileListCodec)
        @Expect(decodedProfiles.size, 3)
        @Expect(decodedProfiles[2].alias, "alias-2-json-escape")
        @Expect(decodedProfileBytes[1].id, profiles[1].id)

        let profileArray = profiles.toArray()
        let encodedProfileArray = YJson.toJson(profileArray, codec: profileArrayCodec)
        let decodedProfileArray = YJson.fromJson(yJsonRegressionBytes(encodedProfileArray), codec: profileArrayCodec)
        @Expect(decodedProfileArray.size, 3)
        @Expect(decodedProfileArray[2].alias, "alias-2-json-escape")

        let profilesByName = HashMap<String, ProfileRecord>()
        profilesByName["ascii"] = profiles[0]
        profilesByName["仓颉\"key"] = profiles[1]
        let encodedProfilesByName = YJson.toJson(profilesByName, codec: profileMapCodec)
        let decodedProfilesByName = YJson.fromJson(yJsonRegressionBytes(encodedProfilesByName), codec: profileMapCodec)
        @Expect(decodedProfilesByName["ascii"].id, profiles[0].id)
        @Expect(decodedProfilesByName["仓颉\"key"].alias, profiles[1].alias)

        try {
            let _ = YJson.fromJson("[{\"profile_id\":1,\"alias\":\"ok\",\"level\":1},{}]", codec: profileListCodec)
            throw JsonException("expected generic array item failure")
        } catch (error: JsonException) {
            @Expect(error.code, "missing_field")
            @Expect(error.path, "/1")
        }

        try {
            let _ = YJson.fromJson(yJsonRegressionBytes("{\"ok\":{\"profile_id\":1,\"alias\":\"ok\",\"level\":1},\"broken\":{}}"), codec: profileMapCodec)
            throw JsonException("expected generic map value failure")
        } catch (error: JsonException) {
            @Expect(error.code, "missing_field")
            @Expect(error.path, "/broken")
        }

        let values = sampleLargeInt64Map(count: 3)
        let decodedValues = YJson.fromJson(YJson.toJson(values, codec: int64MapCodec), codec: int64MapCodec)
        @Expect(decodedValues["metric_2"], 37)

        let nested = sampleDeepNestedProfiles(groupCount: 2, recordCount: 2)
        let encodedNested = YJson.toJson(nested, codec: nestedCodec)
        let decodedNested = YJson.fromJson(encodedNested, codec: nestedCodec)
        let decodedNestedBytes = YJson.fromJson(yJsonRegressionBytes(encodedNested), codec: nestedCodec)
        @Expect(decodedNested[1]["group_1"][1].id, 101)
        @Expect(decodedNestedBytes[1]["group_1"][1].id, 101)
    }

    @TestCase
    func rootCollectionCapacitySamplingPreservesEveryJsonShape(): Unit {
        let stringJson = StringBuilder("[")
        for (index in 0..96) {
            if (index > 0) { stringJson.append(",") }
            stringJson.append("\"segment-${index},\\\\nvalue-with-a-long-tail\"")
        }
        stringJson.append("]")
        let strings = YJson.fromJson(stringJson.toString(), codec: JsonCodecs.arrayList(JsonCodecs.string))
        @Expect(strings.size, 96)
        @Expect(strings[95].contains("segment-95,"))

        let nestedJson = StringBuilder("[")
        for (index in 0..7000) {
            if (index > 0) { nestedJson.append(",") }
            nestedJson.append("[${index},${index + 1}]")
        }
        nestedJson.append("]")
        let nestedCodec = JsonCodecs.arrayList(JsonCodecs.arrayList(JsonCodecs.int64))
        let nested = YJson.fromJson(nestedJson.toString(), codec: nestedCodec)
        @Expect(nested.size, 7000)
        @Expect(nested[6999][1], 7000)

        let intListCodec = JsonCodecs.arrayList(JsonCodecs.int64)
        let dense = YJson.fromJson(generateLargeArray(5000), codec: intListCodec)
        @Expect(dense.size, 5000)

        let profiles = sampleLargeProfileRecords(count: 96)
        let profileListCodec = JsonCodecs.arrayList(ProfileRecordJson)
        let decodedProfiles = YJson.fromJson(YJson.toJson(profiles, codec: profileListCodec), codec: profileListCodec)
        @Expect(decodedProfiles.size, 96)
        @Expect(decodedProfiles[95].id, profiles[95].id)

        let oneLargeString = StringBuilder("[\"")
        for (_ in 0..3200) { oneLargeString.append("a") }
        oneLargeString.append("\"]")
        @Expect(YJson.fromJson(oneLargeString.toString(), codec: JsonCodecs.arrayList(JsonCodecs.string))[0].size, 3200)

        let oneHugeString = StringBuilder("[\"")
        for (_ in 0..70000) { oneHugeString.append("b") }
        oneHugeString.append("\"]")
        @Expect(YJson.fromJson(oneHugeString.toString(), codec: JsonCodecs.arrayList(JsonCodecs.string))[0].size, 70000)

        let trailingSpace = StringBuilder("[1]")
        for (_ in 0..3200) { trailingSpace.append(" ") }
        let single = YJson.fromJson(trailingSpace.toString(), codec: intListCodec)
        @Expect(single.size, 1)
        @Expect(single[0], 1)

        let fourWithTrailingSpace = StringBuilder("[1,2,3,4]")
        for (_ in 0..3200) { fourWithTrailingSpace.append(" ") }
        @Expect(YJson.fromJson(fourWithTrailingSpace.toString(), codec: intListCodec).size, 4)

        let invalidClose = StringBuilder("[}")
        for (_ in 0..3200) { invalidClose.append(" ") }
        @AssertThrows[JsonException](YJson.fromJson(invalidClose.toString(), codec: intListCodec))

        @Expect(YJson.fromJson("[1,2]", codec: intListCodec).size, 2)
    }

    @TestCase
    func genericCollectionEncodeFrameReusePreservesFailurePaths(): Unit {
        let itemCodec = RegressionPathFailingIntCodec()
        let values = ArrayList<Int64>()
        values.add(1)
        values.add(2)
        let arrayError = @AssertThrows[JsonException](
            YJson.toJson(values, codec: JsonCodecs.arrayList(itemCodec))
        )
        @Expect(arrayError.code, "test_failure")
        @Expect(arrayError.path, "/1")

        let entries = HashMap<String, Int64>()
        entries["ok"] = 1
        entries["broken"] = 2
        let mapError = @AssertThrows[JsonException](
            YJson.toJson(entries, codec: JsonCodecs.stringMap(itemCodec))
        )
        @Expect(mapError.code, "test_failure")
        @Expect(mapError.path, "/broken")
    }

    @TestCase
    func specializedScalarCollectionCodecsPreservePublicSemantics(): Unit {
        let integers = ArrayList<Int64>()
        integers.add(-1)
        integers.add(0)
        integers.add(Int64.Max)
        let intCodec = JsonCodecs.arrayList(JsonCodecs.int64)
        @Expect(YJson.fromJson("[ ]", codec: intCodec).isEmpty())
        @Expect(YJson.fromJson(yJsonRegressionBytes("[ ]"), codec: intCodec).isEmpty())
        let decodedIntegers = YJson.fromJson(YJson.toJson(integers, codec: intCodec), codec: intCodec)
        @Expect(decodedIntegers.size, 3)
        @Expect(decodedIntegers[0], -1)
        @Expect(decodedIntegers[2], Int64.Max)

        let strings = ArrayList<String>()
        strings.add("ASCII")
        strings.add("仓颉")
        strings.add("quote\"slash\\line\n")
        let stringCodec = JsonCodecs.arrayList(JsonCodecs.string)
        let emptyStrings = YJson.fromJson("[ ]", codec: stringCodec)
        let emptyStringsAgain = YJson.fromJson(yJsonRegressionBytes("[]"), codec: stringCodec)
        emptyStrings.add("fresh")
        @Expect(emptyStringsAgain.isEmpty())
        let decodedStrings = YJson.fromJson(YJson.toJson(strings, codec: stringCodec), codec: stringCodec)
        @Expect(decodedStrings.size, 3)
        @Expect(decodedStrings[1], "仓颉")
        @Expect(decodedStrings[2], "quote\"slash\\line\n")

        let values = HashMap<String, Int64>()
        values["short"] = -7
        values["escaped\"key"] = Int64.Max
        let mapCodec = JsonCodecs.stringMap(JsonCodecs.int64)
        let emptyMap = YJson.fromJson("{ }", codec: mapCodec)
        let emptyMapAgain = YJson.fromJson(yJsonRegressionBytes("{}"), codec: mapCodec)
        emptyMap["fresh"] = 1
        @Expect(emptyMapAgain.isEmpty())
        let decodedValues = YJson.fromJson(YJson.toJson(values, codec: mapCodec), codec: mapCodec)
        @Expect(decodedValues["short"], -7)
        @Expect(decodedValues["escaped\"key"], Int64.Max)

        let optionCodec = JsonCodecs.option(JsonCodecs.string)
        @Expect(YJson.fromJson("null", codec: optionCodec).isNone())
        @Expect(YJson.fromJson("\"仓颉\"", codec: optionCodec).getOrThrow(), "仓颉")
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.fromJson("[1,\"not-an-integer\"]", codec: intCodec)
        }))
    }

    @TestCase
    func compactInt64MapEncodeMatchesAcrossTargetsAndGrowth(): Unit {
        let codec = JsonCodecs.stringMap(JsonCodecs.int64)
        let empty = HashMap<String, Int64>()
        @Expect(YJson.toJson(empty, codec: codec), "{}")
        @Expect(String.fromUtf8(YJson.toJsonBytes(empty, codec: codec)), "{}")
        let emptyOutput = MemoryOutputStream()
        YJson.writeJson(empty, emptyOutput, codec: codec)
        @Expect(emptyOutput.toUtf8String(), "{}")

        let values = HashMap<String, Int64>(272)
        for (index in 0..256) {
            values["metric_${index}"] = index * 17 + 3
        }
        values[""] = 0
        values["negative"] = -7
        values["minimum"] = -9223372036854775808
        values["maximum"] = Int64.Max
        values["escaped\"key"] = 41
        values["slash\\key"] = 42
        values["line\nkey"] = 43
        values["仓颉😀"] = 44
        let longKeyBuilder = StringBuilder()
        for (_ in 0..5000) {
            longKeyBuilder.append("x")
        }
        let longKey = longKeyBuilder.toString()
        values[longKey] = 45

        let text = YJson.toJson(values, codec: codec)
        let bytesText = String.fromUtf8(YJson.toJsonBytes(values, codec: codec))
        let output = MemoryOutputStream()
        YJson.writeJson(values, output, codec: codec)
        let streamText = output.toUtf8String()
        @Expect(bytesText, text)
        @Expect(streamText, text)
        @Expect(YJson.toJson(values, codec: JsonCodecs.stringMap(JsonCodecs.int64)), text)
        @Expect(YJson.toJson(values), text)

        let decoded = YJson.fromJson(text, codec: codec)
        let providerDecoded = YJson.fromJson<HashMap<String, Int64>>(text)
        @Expect(decoded.size, values.size)
        @Expect(providerDecoded.size, values.size)
        @Expect(providerDecoded["maximum"], Int64.Max)
        @Expect(decoded["minimum"], -9223372036854775808)
        @Expect(decoded["maximum"], Int64.Max)
        @Expect(decoded["escaped\"key"], 41)
        @Expect(decoded["slash\\key"], 42)
        @Expect(decoded["line\nkey"], 43)
        @Expect(decoded["仓颉😀"], 44)
        @Expect(decoded[longKey], 45)

        let htmlValues = HashMap<String, Int64>()
        htmlValues["<tag>"] = 1
        let htmlText = YJson.toJson(htmlValues, codec: codec, options: JsonWriteOptions(htmlSafe: true))
        @Expect(htmlText.contains("\\u003ctag\\u003e"))
        @Expect(YJson.fromJson(htmlText, codec: codec)["<tag>"], 1)
        let prettyText = YJson.toJson(htmlValues, codec: codec, options: JsonWriteOptions.pretty())
        @Expect(prettyText.contains("\n  \"<tag>\": 1\n"))
    }

    @TestCase
    func byteNativeAstMatchesStringAstAndRejectsInvalidUtf8(): Unit {
        let text = "{\"ascii\":\"value\",\"cjk\":\"仓颉\",\"emoji\":\"😀\",\"escaped\":\"line\\n\\u4ed3\",\"number\":-9223372036854775808}"
        let fromText = JsonNode.parse(text)
        let fromBytes = JsonNode.parse(unsafe { text.rawData() })
        @Expect(fromBytes.toString(), fromText.toString())
        @Expect(fromBytes.asObject().get("cjk").getOrThrow().asString(), "仓颉")
        let invalid: Array<Byte> = [b'{', b'"', b'x', b'"', b':', b'"', 0xC3u8, 0x28u8, b'"', b'}']
        let error = @AssertThrows[JsonException](JsonNode.parse(invalid))
        @Expect(error.code, "parse_error")
        @Expect(error.location.getOrThrow().byteOffset >= 6)
        let duplicate = unsafe { "{\"a\":1,\"a\":2}".rawData() }
        @Expect(JsonNode.parse(duplicate,
            config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins))
            .asObject().get("a").getOrThrow().asInt64(), 2)
        let duplicateError = @AssertThrows[JsonException](JsonNode.parse(
            duplicate,
            config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        ))
        let stringDuplicateError = @AssertThrows[JsonException](JsonNode.parse(
            "{\"a\":1,\"a\":2}",
            config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
        ))
        @Expect(duplicateError.code, stringDuplicateError.code)
        @AssertThrows[JsonException](JsonNode.parse(unsafe { "{\"a\":\"unterminated".rawData() }))
        @AssertThrows[JsonException](JsonNode.parse(unsafe { "\"\\x\"".rawData() }))
    }

    @TestCase
    func generatedArrayListFastReaderFallsBackForWhitespaceArrays(): Unit {
        let profileListCodec = JsonCodecs.arrayList(ProfileRecordJson)
        let decoded = YJson.fromJson("[\n" +
                "  {\"profile_id\":1,\"alias\":\"one\",\"level\":7},\n" +
                "  {\"profile_id\":2,\"alias\":\"two\",\"level\":8}\n" +
            "]", codec: profileListCodec)
        @Expect(decoded.size, 2)
        @Expect(decoded[1].alias, "two")
    }

    @TestCase
    func orderedFastReaderKeepsDuplicateTrailingFieldSemantics(): Unit {
        let decoded = YJson.fromJson("{\"profile_id\":1,\"alias\":\"first\",\"level\":7,\"alias\":\"second\"}", codec: ProfileRecordJson,
            options: JsonReadOptions(duplicateKeyPolicy: LastWins))
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
        let decodedDuplicate = YJson.fromJson(reversedWithDuplicateTail, codec: PersonJson,
            options: JsonReadOptions(duplicateKeyPolicy: LastWins))
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
        let decodedUnknown = YJson.fromJson(unknownGaps, codec: PersonJson)
        @Expect(decodedUnknown.id, 42)
        @Expect(decodedUnknown.name, "Lin")
        @Expect(decodedUnknown.tags[2], "reflect")
        @Expect(decodedUnknown.address.zipcode, 518000)
        match (decodedUnknown.nick) {
            case Some(_) => @Expect(false)
            case None => @Expect(true)
        }

        let partiallyOrdered = YJson.fromJson("{" +
                "\"user_id\":42," +
                "\"scores\":{\"english\":88,\"math\":95}," +
                "\"name\":\"Lin\"," +
                "\"nick\":null," +
                "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
                "\"age\":28," +
                "\"tags\":[\"cangjie\",\"json\",\"reflect\"]" +
            "}", codec: PersonJson)
        @Expect(partiallyOrdered.id, 42)
        @Expect(partiallyOrdered.name, "Lin")
        @Expect(partiallyOrdered.tags[2], "reflect")
        @Expect(partiallyOrdered.address.zipcode, 518000)

        let mixedOrder = YJson.fromJson("{" +
                "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
                "\"age\":28," +
                "\"user_id\":42," +
                "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
                "\"nick\":null," +
                "\"name\":\"Lin\"," +
                "\"scores\":{\"english\":88,\"math\":95}" +
            "}", codec: PersonJson)
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

        let fromString = YJson.fromJson(escapedAndUnicodeUnknown, codec: PersonJson)
        let fromBytes = YJson.fromJson(yJsonRegressionBytes(escapedAndUnicodeUnknown), codec: PersonJson)
        @Expect(fromString.id, 42)
        @Expect(fromString.address.street, "Nanshan Road")
        @Expect(fromBytes.id, fromString.id)
        @Expect(fromBytes.name, fromString.name)
        @Expect(fromBytes.address.street, fromString.address.street)
        @Expect(fromBytes.scores["math"], 95)
    }

    @TestCase
    func fastReaderSkipsUnknownEscapedStringsWithoutAllocatingValues(): Unit {
        let decoded = YJson.fromJson("{" +
                "\"user_id\":42," +
                "\"ignored\":{\"escaped\":\"a\\\"b\\\\c\\n\\t\\uD834\\uDD1E\",\"array\":[\"x\",{\"y\":\"z\"}]}," +
                "\"name\":\"Lin\"," +
                "\"age\":28," +
                "\"tags\":[\"cangjie\",\"json\"]," +
                "\"scores\":{\"math\":95}," +
                "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000}," +
                "\"nick\":null" +
            "}", codec: PersonJson)
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
            YJson.fromJson(mixedRawUtf8, codec: JsonCodecs.string),
            "Cangjie JSON \"escape\" \\ slash / line\n tab\t raw 仓颉 Δ ✓ unicode 仓颉 Δ ✓"
        )
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let invalidUtf8: Array<Byte> = [b'"', 0xE4u8, 0xB8u8, b'\\', b'n', b'"']
            let _ = YJson.fromJson(invalidUtf8, codec: JsonCodecs.string)
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
        @Expect(YJson.fromJson(text, codec: JsonCodecs.string), "仓颉\n")
    }

    @TestCase
    func fastReaderDecodesEscapedStringChunks(): Unit {
        @Expect(
            YJson.fromJson("\"left\\\"mid\\\\line\\n\\t\\u4ed3\\u9889\\uD834\\uDD1Eright\"", codec: JsonCodecs.string),
            "left\"mid\\line\n\t仓颉\u{1D11E}right"
        )
    }

    @TestCase
    func fastReaderEscapedStringPreservesByteValidationFallback(): Unit {
        let text = "\"仓颉\\n\\u2713\""
        @Expect(YJson.fromJson(yJsonRegressionBytes(text), codec: JsonCodecs.string), "仓颉\n✓")
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.fromJson(yJsonRegressionBytes("\"\\uD834\""), codec: JsonCodecs.string)
        }))
    }

    @TestCase
    func floatWritersRejectNonFiniteValues(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.toJson(Float64.NaN, codec: JsonCodecs.float64)
        }))
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.toJson(Float64.Inf, codec: JsonCodecs.float64)
        }))
    }

    @TestCase
    func jsonExceptionCarriesStructuredParseLocation(): Unit {
        try {
            let _ = JsonNode.parse("{\n\"a\":01}")
            throw JsonException("expected parse failure")
        } catch (error: JsonException) {
            @Expect(error.code, "parse_error")
            @Expect(error.location.getOrThrow().byteOffset, 7)
            @Expect(error.location.getOrThrow().line, 2)
            @Expect(error.location.getOrThrow().column, 6)
            @Expect(error.path, "")
        }
    }

    @TestCase
    func jsonReadOptionsAlwaysReportErrorLocation(): Unit {
        try {
            let _ = JsonNode.parse(
                "{\n\"a\":01}",
                config: JsonReadOptions()
            )
            throw JsonException("expected parse failure")
        } catch (error: JsonException) {
            @Expect(error.location.getOrThrow().byteOffset, 7)
            @Expect(error.location.getOrThrow().line, 2)
            @Expect(error.location.getOrThrow().column, 6)
        }
    }

    @TestCase
    func jsonReadConfigCanRejectDuplicateKeys(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = JsonNode.parse(
                "{\"a\":1,\"a\":2}",
                config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject)
            )
        }))
    }

    @TestCase
    func exactIntegersUseInt64AndFractionalSyntaxPreservesLiteral(): Unit {
        let value = JsonNode.parse("42", config: JsonReadOptions())
        @Expect(value.asInt64(), 42)
        @Expect(JsonNode.parse("42.0").asNumberText(), "42.0")
    }

    @TestCase
    func jsonCodecConfigCanRejectUnknownDirectFields(): Unit {
        @Expect(yJsonRegressionThrowsJsonException({ =>
            let _ = YJson.fromJson("{\"profile_id\":1,\"alias\":\"one\",\"level\":7,\"extra\":true}", codec: ProfileRecordJson, options: JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject))
        }))
    }

    @TestCase
    func jsonConfigDefaultsKeepExistingCompactBehavior(): Unit {
        @Expect(jsonReadOptionsUsesDefaultFastPath(JsonReadOptions.defaults))
        @Expect(JsonWriteOptions.compact.newline, "")
        @Expect(JsonWriteOptions.compact.indent, "")
        @Expect(!JsonWriteOptions.compact.useSpaceAfterSeparators)
        @Expect(!JsonWriteOptions.compact.htmlSafe)
        @Expect(YJson.toJson("<tag>", codec: JsonCodecs.string), "\"<tag>\"")
        @Expect(YJson.toJson("<tag>", codec: JsonCodecs.string, options: JsonWriteOptions(htmlSafe: true)), "\"\\u003ctag\\u003e\"")
    }
}
