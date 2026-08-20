/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
 * This source file is part of the Cangjie project, licensed under Apache-2.0
 * with Runtime Library Exception.
 *
 * See https://cangjie-lang.cn/pages/LICENSE for license information.
 */

package yjson_benchmarks

import yjson.*

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json as stdxjson
import stdx.encoding.json.stream.*

func profileRecordArrayListJson(): JsonDirectCodec<ArrayList<ProfileRecord>> {
    YJson.arrayListCodec(ProfileRecordJson)
}

func profileRecordArrayJson(): JsonDirectCodec<Array<ProfileRecord>> {
    YJson.arrayCodec(ProfileRecordJson)
}

func int64HashMapJson(): JsonDirectCodec<HashMap<String, Int64>> {
    YJson.hashMapCodec(Int64Json)
}

func escapedUnicodeStringJsonText(): String {
    "\"Cangjie JSON \\\"escape\\\" \\\\ slash / line\\n tab\\t unicode \\u4ed3\\u9889 \\u0394 \\u2713\""
}

func sampleEscapedUnicodeString(): String {
    YJson.decodeStringWith(StringJson, escapedUnicodeStringJsonText())
}

func sampleBenchmarkStrings(count: Int64): ArrayList<String> {
    let values = ArrayList<String>(count)
    for (index in 0..count) {
        values.add("value-${index}-仓颉-json")
    }
    values
}

func toStdxProfileList(source: ArrayList<ProfileRecord>): ArrayList<StdxProfileRecord> {
    let converted = ArrayList<StdxProfileRecord>(source.size)
    for (profile in source) {
        converted.add(toStdxProfileRecord(profile))
    }
    converted
}

func toStdxNestedProfiles(
    source: ArrayList<HashMap<String, ArrayList<ProfileRecord>>>
): ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>> {
    let converted = ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>>(source.size)
    for (group in source) {
        let convertedGroup = HashMap<String, ArrayList<StdxProfileRecord>>(group.size)
        for ((key, profiles) in group) {
            convertedGroup.add(key, toStdxProfileList(profiles))
        }
        converted.add(convertedGroup)
    }
    converted
}

func encodeStdxToUtf8Bytes<T>(
    value: T,
    config!: WriteConfig = WriteConfig.compact
): Array<Byte> where T <: JsonSerializable {
    let out = YJsonMemoryOutputStream()
    encodeStdxToStream<T>(value, out, config: config)
    out.toByteArray()
}

func decodeStdxFromUtf8Bytes<T>(bytes: Array<Byte>): T where T <: JsonDeserializable<T> {
    decodeStdxFromStream<T>(YJsonByteArrayInputStream(bytes))
}

func unorderedPersonJsonText(): String {
    "{" +
        "\"nick\":null," +
        "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
        "\"scores\":{\"english\":88,\"math\":95}," +
        "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
        "\"age\":28," +
        "\"name\":\"Lin\"," +
        "\"user_id\":42" +
        "}"
}

func unknownPersonJsonText(): String {
    "{" +
        "\"user_id\":42," +
        "\"unknownObject\":{\"left\":[1,2,3],\"right\":{\"enabled\":true}}," +
        "\"name\":\"Lin\"," +
        "\"age\":28," +
        "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
        "\"scores\":{\"math\":95,\"english\":88}," +
        "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000,\"ignored\":true}," +
        "\"unknownArray\":[{\"x\":1},null,false]," +
        "\"nick\":null" +
        "}"
}

func prettyPersonJsonText(): String {
    "{\n" +
        "  \"user_id\": 42,\n" +
        "  \"name\": \"Lin\",\n" +
        "  \"age\": 28,\n" +
        "  \"tags\": [\n" +
        "    \"cangjie\",\n" +
        "    \"json\",\n" +
        "    \"reflect\"\n" +
        "  ],\n" +
        "  \"scores\": {\n" +
        "    \"math\": 95,\n" +
        "    \"english\": 88\n" +
        "  },\n" +
        "  \"address\": {\n" +
        "    \"street_name\": \"Nanshan Road\",\n" +
        "    \"zipcode\": 518000\n" +
        "  },\n" +
        "  \"nick\": null\n" +
        "}"
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class ComprehensiveJsonCompareBenchmarks {
    let address = samplePerson().address
    let person = samplePerson()
    let profile = sampleProfileRecord()
    let personFastDecoder = YJson.fastDecoder(PersonJson)
    let profileFastDecoder = YJson.fastDecoder(ProfileRecordJson)
    let profileBundle = sampleProfileBundleForBench()
    let uint64Envelope = sampleUInt64Envelope()
    let temporalStats = sampleTemporalStats()
    let largeProfiles = sampleLargeProfileRecords()
    let largeProfileArray = largeProfiles.toArray()
    let largeInt64Map = sampleLargeInt64Map()
    let largeStrings = sampleBenchmarkStrings(64)
    let deepNestedProfiles = sampleDeepNestedProfiles()
    let escapedUnicodeText = sampleEscapedUnicodeString()
    let stdxAddress: StdxAddress
    let stdxPerson: StdxPerson
    let stdxProfileBundle: StdxProfileBundle
    let stdxUInt64Envelope: StdxUInt64Envelope
    let stdxTemporalStats: StdxTemporalStats
    let stdxLargeProfiles: ArrayList<StdxProfileRecord>
    let stdxDeepNestedProfiles: ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>>
    let profileArrayCodec = profileRecordArrayJson()
    let profileListCodec = profileRecordArrayListJson()
    let staticProfileListCodec = ProfileRecordStaticArrayListJson
    let int64MapCodec = int64HashMapJson()
    let stringListCodec = YJson.stringArrayListCodec()
    let deepNestedCodec = nestedProfilesJson()
    let addressText: String
    let personText: String
    let profileText: String
    let profileBundleText: String
    let uint64EnvelopeText: String
    let temporalStatsText: String
    let largeProfilesText: String
    let largeProfileArrayText: String
    let emptyProfileListText = "[]"
    let largeInt64MapText: String
    let emptyStringListText = "[]"
    let largeStringListText: String
    let deepNestedProfilesText: String
    let escapedUnicodeJsonText: String
    let unorderedPersonText = unorderedPersonJsonText()
    let unknownPersonText = unknownPersonJsonText()
    let prettyPersonText = prettyPersonJsonText()
    let unorderedPersonBytes: Array<Byte>
    let unknownPersonBytes: Array<Byte>
    let addressBytes: Array<Byte>
    let personBytes: Array<Byte>
    let profileBytes: Array<Byte>
    let profileBundleBytes: Array<Byte>
    let uint64EnvelopeBytes: Array<Byte>
    let temporalStatsBytes: Array<Byte>
    let largeProfilesBytes: Array<Byte>
    let largeProfileArrayBytes: Array<Byte>
    let emptyProfileListBytes: Array<Byte>
    let largeInt64MapBytes: Array<Byte>
    let emptyStringListBytes: Array<Byte>
    let largeStringListBytes: Array<Byte>
    let deepNestedProfilesBytes: Array<Byte>
    let escapedUnicodeBytes: Array<Byte>
    let personAst: JsonNode
    let stdxPersonAst: stdxjson.JsonValue
    var stringSink = ""
    var intSink: Int64 = 0
    var bytesSink: Array<Byte> = Array<Byte>(0, repeat: 0u8)
    var yjsonAstSink: JsonNode = JsonNullValue()
    var stdxAstSink: stdxjson.JsonValue = stdxjson.JsonNull()

    init() {
        stdxAddress = toStdxAddress(address)
        stdxPerson = toStdxPerson(person)
        stdxProfileBundle = toStdxProfileBundle(profileBundle)
        stdxUInt64Envelope = toStdxUInt64Envelope(uint64Envelope)
        stdxTemporalStats = toStdxTemporalStats(temporalStats)
        stdxLargeProfiles = toStdxProfileList(largeProfiles)
        stdxDeepNestedProfiles = toStdxNestedProfiles(deepNestedProfiles)

        addressText = YJson.encodeStringWith(AddressJson, address)
        personText = YJson.encodeStringWith(PersonJson, person)
        profileText = YJson.encodeStringWith(ProfileRecordJson, profile)
        profileBundleText = YJson.encodeStringWith(ProfileBundleJson, profileBundle)
        uint64EnvelopeText = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
        temporalStatsText = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
        largeProfilesText = YJson.encodeStringWith(profileListCodec, largeProfiles)
        largeProfileArrayText = YJson.encodeStringWith(profileArrayCodec, largeProfileArray)
        largeInt64MapText = YJson.encodeStringWith(int64MapCodec, largeInt64Map)
        largeStringListText = YJson.encodeStringWith(stringListCodec, largeStrings)
        deepNestedProfilesText = YJson.encodeStringWith(deepNestedCodec, deepNestedProfiles)
        escapedUnicodeJsonText = YJson.encodeStringWith(StringJson, escapedUnicodeText)

        addressBytes = encodeYjsonReflectBytesWith(AddressJson, address)
        personBytes = encodeYjsonReflectBytesWith(PersonJson, person)
        profileBytes = encodeYjsonReflectBytesWith(ProfileRecordJson, profile)
        profileBundleBytes = encodeYjsonReflectBytesWith(ProfileBundleJson, profileBundle)
        uint64EnvelopeBytes = encodeYjsonReflectBytesWith(UInt64EnvelopeJson, uint64Envelope)
        temporalStatsBytes = encodeYjsonReflectBytesWith(TemporalStatsJson, temporalStats)
        largeProfilesBytes = encodeYjsonReflectBytesWith(profileListCodec, largeProfiles)
        largeProfileArrayBytes = encodeYjsonReflectBytesWith(profileArrayCodec, largeProfileArray)
        emptyProfileListBytes = unsafe { emptyProfileListText.rawData() }
        largeInt64MapBytes = encodeYjsonReflectBytesWith(int64MapCodec, largeInt64Map)
        emptyStringListBytes = unsafe { emptyStringListText.rawData() }
        largeStringListBytes = encodeYjsonReflectBytesWith(stringListCodec, largeStrings)
        deepNestedProfilesBytes = encodeYjsonReflectBytesWith(deepNestedCodec, deepNestedProfiles)
        escapedUnicodeBytes = encodeYjsonReflectBytesWith(StringJson, escapedUnicodeText)
        unorderedPersonBytes = unsafe { unorderedPersonText.rawData() }
        unknownPersonBytes = unsafe { unknownPersonText.rawData() }
        personAst = YJson.parse(personText)
        stdxPersonAst = stdxjson.JsonValue.fromStr(personText)

        assertJson(decodeStdxFromUtf8String<StdxPerson>(unorderedPersonText).id == person.id, "stdx unordered person")
        assertJson(decodeStdxFromUtf8String<StdxPerson>(unknownPersonText).id == person.id, "stdx unknown person")
        assertJson(decodeStdxFromUtf8String<StdxPerson>(prettyPersonText).id == person.id, "stdx pretty person")
        assertJson(YJson.decodeStringWith(PersonJson, unknownPersonText).address.zipcode == 518000, "yjson unknown person")
        assertJson(YJson.decodeBytesWith(stringListCodec, emptyStringListBytes).isEmpty(), "yjson empty string list")
        assertJson(YJson.decodeBytesWith(stringListCodec, largeStringListBytes).size == 64, "yjson large string list")
        assertJson(YJson.decodeBytesWith(profileListCodec, emptyProfileListBytes).isEmpty(), "yjson empty profile list")
        assertJson(YJson.decodeBytesWith(profileArrayCodec, largeProfileArrayBytes).size == 64, "yjson large profile array")
        assertJson(YJson.decodeBytesWith(staticProfileListCodec, largeProfilesBytes).size == 64, "yjson static profile list")
        assertJson(YJson.decodeBytesWith(deepNestedCodec, deepNestedProfilesBytes).size == deepNestedProfiles.size, "yjson bytes deep nested profiles")
        assertJson(decodeStdxFromUtf8String<ArrayList<StdxProfileRecord>>(largeProfilesText).size == largeProfiles.size, "stdx large profile list")
        assertJson(decodeStdxFromUtf8String<HashMap<String, Int64>>(largeInt64MapText).size == largeInt64Map.size, "stdx large int64 map")
        assertJson(
            decodeStdxFromUtf8String<ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>>>(deepNestedProfilesText).size ==
            deepNestedProfiles.size,
            "stdx deep nested profiles"
        )
    }

    @Bench
    func yjsonAstParsePerson(): Unit {
        yjsonAstSink = YJson.parse(personText)
    }

    @Bench
    func stdxAstParsePerson(): Unit {
        stdxAstSink = stdxjson.JsonValue.fromStr(personText)
    }

    @Bench
    func yjsonAstStringifyPerson(): Unit {
        stringSink = YJson.stringify(personAst)
    }

    @Bench
    func stdxAstStringifyPerson(): Unit {
        stringSink = stdxPersonAst.toJsonString()
    }

    @Bench
    func yjsonStringEncodeAddress(): Unit {
        stringSink = YJson.encodeStringWith(AddressJson, address)
    }

    @Bench
    func stdxStringEncodeAddress(): Unit {
        stringSink = encodeStdxToUtf8String<StdxAddress>(stdxAddress)
    }

    @Bench
    func yjsonStringDecodeAddress(): Unit {
        intSink = YJson.decodeStringWith(AddressJson, addressText).zipcode
    }

    @Bench
    func stdxStringDecodeAddress(): Unit {
        intSink = decodeStdxFromUtf8String<StdxAddress>(addressText).zipcode
    }

    @Bench
    func yjsonStringEncodePerson(): Unit {
        stringSink = YJson.encodeStringWith(PersonJson, person)
    }

    @Bench
    func stdxStringEncodePerson(): Unit {
        stringSink = encodeStdxToUtf8String<StdxPerson>(stdxPerson)
    }

    @Bench
    func yjsonStringDecodePerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, personText).id
    }

    @Bench
    func yjsonStringDecodePersonBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += YJson.decodeStringWith(PersonJson, personText).id
        }
        intSink = value
    }

    @Bench
    func yjsonStringDecodeProfileRecordBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..128) {
            value += YJson.decodeStringWith(ProfileRecordJson, profileText).id
        }
        intSink = value
    }

    @Bench
    func yjsonStringDecodeProfileRecordFastDecoderBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..128) {
            value += profileFastDecoder.decodeString(profileText).id
        }
        intSink = value
    }

    @Bench
    func yjsonStringDecodePersonFastDecoderBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += personFastDecoder.decodeString(personText).id
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodePerson(): Unit {
        intSink = decodeStdxFromUtf8String<StdxPerson>(personText).id
    }

    @Bench
    func yjsonStringEncodeProfileBundle(): Unit {
        stringSink = YJson.encodeStringWith(ProfileBundleJson, profileBundle)
    }

    @Bench
    func stdxStringEncodeProfileBundle(): Unit {
        stringSink = encodeStdxToUtf8String<StdxProfileBundle>(stdxProfileBundle)
    }

    @Bench
    func yjsonStringDecodeProfileBundle(): Unit {
        intSink = YJson.decodeStringWith(ProfileBundleJson, profileBundleText).groups["platform"][0].id
    }

    @Bench
    func stdxStringDecodeProfileBundle(): Unit {
        intSink = decodeStdxFromUtf8String<StdxProfileBundle>(profileBundleText).groups["platform"][0].id
    }

    @Bench
    func yjsonStringEncodeUInt64Envelope(): Unit {
        stringSink = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
    }

    @Bench
    func stdxStringEncodeUInt64Envelope(): Unit {
        stringSink = encodeStdxToUtf8String<StdxUInt64Envelope>(stdxUInt64Envelope)
    }

    @Bench
    func yjsonStringDecodeUInt64Envelope(): Unit {
        intSink = Int64(YJson.decodeStringWith(UInt64EnvelopeJson, uint64EnvelopeText).shardIds.size)
    }

    @Bench
    func stdxStringDecodeUInt64Envelope(): Unit {
        intSink = Int64(decodeStdxFromUtf8String<StdxUInt64Envelope>(uint64EnvelopeText).shardIds.size)
    }

    @Bench
    func yjsonStringEncodeTemporalStats(): Unit {
        stringSink = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
    }

    @Bench
    func stdxStringEncodeTemporalStats(): Unit {
        stringSink = encodeStdxToUtf8String<StdxTemporalStats>(stdxTemporalStats)
    }

    @Bench
    func yjsonStringDecodeTemporalStats(): Unit {
        stringSink = YJson.decodeStringWith(TemporalStatsJson, temporalStatsText).totalEvents.toString()
    }

    @Bench
    func stdxStringDecodeTemporalStats(): Unit {
        stringSink = decodeStdxFromUtf8String<StdxTemporalStats>(temporalStatsText).totalEvents.toString()
    }

    @Bench
    func yjsonStringEncodePrettyPerson(): Unit {
        stringSink = YJson.encodeStringWith(PersonJson, person, config: JsonWriteConfig.pretty)
    }

    @Bench
    func stdxStringEncodePrettyPerson(): Unit {
        stringSink = encodeStdxToUtf8String<StdxPerson>(stdxPerson, config: WriteConfig.pretty)
    }

    @Bench
    func yjsonStreamEncodePerson(): Unit {
        let out = YJsonMemoryOutputStream()
        YJson.encodeToStreamWith(PersonJson, person, out)
        stringSink = out.toUtf8String()
    }

    @Bench
    func stdxStreamEncodePerson(): Unit {
        let out = YJsonMemoryOutputStream()
        encodeStdxToStream<StdxPerson>(stdxPerson, out)
        stringSink = out.toUtf8String()
    }

    @Bench
    func yjsonStreamDecodePerson(): Unit {
        intSink = YJson.decodeFromStreamWith(PersonJson, YJsonByteArrayInputStream(personText)).id
    }

    @Bench
    func stdxStreamDecodePerson(): Unit {
        intSink = decodeStdxFromStream<StdxPerson>(YJsonByteArrayInputStream(personText)).id
    }

    @Bench
    func yjsonBytesEncodePerson(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(PersonJson, person)
    }

    @Bench
    func stdxBytesEncodePerson(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<StdxPerson>(stdxPerson)
    }

    @Bench
    func yjsonBytesDecodePerson(): Unit {
        intSink = decodeYjsonReflectBytesWith(PersonJson, personBytes).id
    }

    @Bench
    func yjsonBytesDecodePersonBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += decodeYjsonReflectBytesWith(PersonJson, personBytes).id
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodeProfileRecordBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..128) {
            value += decodeYjsonReflectBytesWith(ProfileRecordJson, profileBytes).id
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodeProfileRecordFastDecoderBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..128) {
            value += profileFastDecoder.decodeBytes(profileBytes).id
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodePersonFastDecoderBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += personFastDecoder.decodeBytes(personBytes).id
        }
        intSink = value
    }

    @Bench
    func stdxBytesDecodePerson(): Unit {
        intSink = decodeStdxFromUtf8Bytes<StdxPerson>(personBytes).id
    }

    @Bench
    func yjsonBytesEncodeAddress(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(AddressJson, address)
    }

    @Bench
    func stdxBytesEncodeAddress(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<StdxAddress>(stdxAddress)
    }

    @Bench
    func yjsonBytesDecodeAddress(): Unit {
        intSink = decodeYjsonReflectBytesWith(AddressJson, addressBytes).zipcode
    }

    @Bench
    func stdxBytesDecodeAddress(): Unit {
        intSink = decodeStdxFromUtf8Bytes<StdxAddress>(addressBytes).zipcode
    }

    @Bench
    func yjsonBytesEncodeProfileBundle(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(ProfileBundleJson, profileBundle)
    }

    @Bench
    func stdxBytesEncodeProfileBundle(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<StdxProfileBundle>(stdxProfileBundle)
    }

    @Bench
    func yjsonBytesDecodeProfileBundle(): Unit {
        intSink = decodeYjsonReflectBytesWith(ProfileBundleJson, profileBundleBytes).groups["platform"][0].id
    }

    @Bench
    func stdxBytesDecodeProfileBundle(): Unit {
        intSink = decodeStdxFromUtf8Bytes<StdxProfileBundle>(profileBundleBytes).groups["platform"][0].id
    }

    @Bench
    func yjsonBytesEncodeUInt64Envelope(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(UInt64EnvelopeJson, uint64Envelope)
    }

    @Bench
    func stdxBytesEncodeUInt64Envelope(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<StdxUInt64Envelope>(stdxUInt64Envelope)
    }

    @Bench
    func yjsonBytesDecodeUInt64Envelope(): Unit {
        intSink = Int64(decodeYjsonReflectBytesWith(UInt64EnvelopeJson, uint64EnvelopeBytes).shardIds.size)
    }

    @Bench
    func stdxBytesDecodeUInt64Envelope(): Unit {
        intSink = Int64(decodeStdxFromUtf8Bytes<StdxUInt64Envelope>(uint64EnvelopeBytes).shardIds.size)
    }

    @Bench
    func yjsonBytesEncodeTemporalStats(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(TemporalStatsJson, temporalStats)
    }

    @Bench
    func stdxBytesEncodeTemporalStats(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<StdxTemporalStats>(stdxTemporalStats)
    }

    @Bench
    func yjsonBytesDecodeTemporalStats(): Unit {
        stringSink = decodeYjsonReflectBytesWith(TemporalStatsJson, temporalStatsBytes).totalEvents.toString()
    }

    @Bench
    func stdxBytesDecodeTemporalStats(): Unit {
        stringSink = decodeStdxFromUtf8Bytes<StdxTemporalStats>(temporalStatsBytes).totalEvents.toString()
    }

    @Bench
    func yjsonStringEncodeEscapedUnicodeString(): Unit {
        stringSink = YJson.encodeStringWith(StringJson, escapedUnicodeText)
    }

    @Bench
    func stdxStringEncodeEscapedUnicodeString(): Unit {
        stringSink = encodeStdxToUtf8String<String>(escapedUnicodeText)
    }

    @Bench
    func yjsonStringDecodeEscapedUnicodeString(): Unit {
        stringSink = YJson.decodeStringWith(StringJson, escapedUnicodeJsonText)
    }

    @Bench
    func stdxStringDecodeEscapedUnicodeString(): Unit {
        stringSink = decodeStdxFromUtf8String<String>(escapedUnicodeJsonText)
    }

    @Bench
    func yjsonBytesEncodeEscapedUnicodeString(): Unit {
        bytesSink = encodeYjsonReflectBytesWith(StringJson, escapedUnicodeText)
    }

    @Bench
    func stdxBytesEncodeEscapedUnicodeString(): Unit {
        bytesSink = encodeStdxToUtf8Bytes<String>(escapedUnicodeText)
    }

    @Bench
    func yjsonBytesDecodeEscapedUnicodeString(): Unit {
        stringSink = decodeYjsonReflectBytesWith(StringJson, escapedUnicodeBytes)
    }

    @Bench
    func stdxBytesDecodeEscapedUnicodeString(): Unit {
        stringSink = decodeStdxFromUtf8Bytes<String>(escapedUnicodeBytes)
    }

    @Bench
    func yjsonStringEncodeLargeProfileArray(): Unit {
        stringSink = YJson.encodeStringWith(profileListCodec, largeProfiles)
    }

    @Bench
    func stdxStringEncodeLargeProfileArray(): Unit {
        stringSink = encodeStdxToUtf8String<ArrayList<StdxProfileRecord>>(stdxLargeProfiles)
    }

    @Bench
    func yjsonStringDecodeLargeProfileArray(): Unit {
        intSink = YJson.decodeStringWith(profileListCodec, largeProfilesText)[0].id
    }

    @Bench
    func yjsonBytesDecodeLargeProfileArray(): Unit {
        intSink = decodeYjsonReflectBytesWith(profileListCodec, largeProfilesBytes)[0].id
    }

    @Bench
    func yjsonStringDecodeLargeProfileArrayValue(): Unit {
        intSink = YJson.decodeStringWith(profileArrayCodec, largeProfileArrayText)[0].id
    }

    @Bench
    func yjsonBytesDecodeLargeProfileArrayValue(): Unit {
        intSink = decodeYjsonReflectBytesWith(profileArrayCodec, largeProfileArrayBytes)[0].id
    }

    @Bench
    func yjsonStringDecodeLargeProfileStaticArrayList(): Unit {
        intSink = YJson.decodeStringWith(staticProfileListCodec, largeProfilesText)[0].id
    }

    @Bench
    func yjsonBytesDecodeLargeProfileStaticArrayList(): Unit {
        intSink = decodeYjsonReflectBytesWith(staticProfileListCodec, largeProfilesBytes)[0].id
    }

    @Bench
    func yjsonStringDecodeEmptyProfileArrayList(): Unit {
        intSink = YJson.decodeStringWith(profileListCodec, emptyProfileListText).size
    }

    @Bench
    func yjsonStringDecodeEmptyProfileArrayListBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..256) {
            value += YJson.decodeStringWith(profileListCodec, emptyProfileListText).size
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodeEmptyProfileArrayList(): Unit {
        intSink = decodeYjsonReflectBytesWith(profileListCodec, emptyProfileListBytes).size
    }

    @Bench
    func yjsonBytesDecodeEmptyProfileArrayListBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..256) {
            value += decodeYjsonReflectBytesWith(profileListCodec, emptyProfileListBytes).size
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodeLargeProfileArray(): Unit {
        intSink = decodeStdxFromUtf8String<ArrayList<StdxProfileRecord>>(largeProfilesText)[0].id
    }

    @Bench
    func yjsonStringEncodeLargeInt64Map(): Unit {
        stringSink = YJson.encodeStringWith(int64MapCodec, largeInt64Map)
    }

    @Bench
    func stdxStringEncodeLargeInt64Map(): Unit {
        stringSink = encodeStdxToUtf8String<HashMap<String, Int64>>(largeInt64Map)
    }

    @Bench
    func yjsonStringDecodeLargeInt64Map(): Unit {
        intSink = YJson.decodeStringWith(int64MapCodec, largeInt64MapText)["metric_32"]
    }

    @Bench
    func yjsonBytesDecodeLargeInt64Map(): Unit {
        intSink = decodeYjsonReflectBytesWith(int64MapCodec, largeInt64MapBytes)["metric_32"]
    }

    @Bench
    func yjsonStringDecodeEmptyStringArray(): Unit {
        intSink = YJson.decodeStringWith(stringListCodec, emptyStringListText).size
    }

    @Bench
    func yjsonStringDecodeEmptyStringArrayBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..256) {
            value += YJson.decodeStringWith(stringListCodec, emptyStringListText).size
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodeEmptyStringArray(): Unit {
        intSink = decodeYjsonReflectBytesWith(stringListCodec, emptyStringListBytes).size
    }

    @Bench
    func yjsonBytesDecodeEmptyStringArrayBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..256) {
            value += decodeYjsonReflectBytesWith(stringListCodec, emptyStringListBytes).size
        }
        intSink = value
    }

    @Bench
    func yjsonStringDecodeLargeStringArray(): Unit {
        intSink = YJson.decodeStringWith(stringListCodec, largeStringListText).size
    }

    @Bench
    func yjsonStringDecodeLargeStringArrayBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += YJson.decodeStringWith(stringListCodec, largeStringListText).size
        }
        intSink = value
    }

    @Bench
    func yjsonBytesDecodeLargeStringArray(): Unit {
        intSink = decodeYjsonReflectBytesWith(stringListCodec, largeStringListBytes).size
    }

    @Bench
    func yjsonBytesDecodeLargeStringArrayBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += decodeYjsonReflectBytesWith(stringListCodec, largeStringListBytes).size
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodeLargeInt64Map(): Unit {
        intSink = decodeStdxFromUtf8String<HashMap<String, Int64>>(largeInt64MapText)["metric_32"]
    }

    @Bench
    func yjsonStringEncodeDeepNestedProfiles(): Unit {
        stringSink = YJson.encodeStringWith(deepNestedCodec, deepNestedProfiles)
    }

    @Bench
    func stdxStringEncodeDeepNestedProfiles(): Unit {
        stringSink =
            encodeStdxToUtf8String<ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>>>(stdxDeepNestedProfiles)
    }

    @Bench
    func yjsonStringDecodeDeepNestedProfiles(): Unit {
        intSink = YJson.decodeStringWith(deepNestedCodec, deepNestedProfilesText)[0]["group_0"][0].id
    }

    @Bench
    func yjsonBytesDecodeDeepNestedProfiles(): Unit {
        intSink = decodeYjsonReflectBytesWith(deepNestedCodec, deepNestedProfilesBytes)[0]["group_0"][0].id
    }

    @Bench
    func stdxStringDecodeDeepNestedProfiles(): Unit {
        intSink =
            decodeStdxFromUtf8String<ArrayList<HashMap<String, ArrayList<StdxProfileRecord>>>>(deepNestedProfilesText)[0]["group_0"][0].id
    }

    @Bench
    func yjsonStringDecodeUnorderedPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, unorderedPersonText).id
    }

    @Bench
    func yjsonStringDecodeUnorderedPersonBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += YJson.decodeStringWith(PersonJson, unorderedPersonText).id
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodeUnorderedPerson(): Unit {
        intSink = decodeStdxFromUtf8String<StdxPerson>(unorderedPersonText).id
    }

    @Bench
    func yjsonStringDecodeUnknownPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, unknownPersonText).id
    }

    @Bench
    func yjsonStringDecodeUnknownPersonBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += YJson.decodeStringWith(PersonJson, unknownPersonText).id
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodeUnknownPerson(): Unit {
        intSink = decodeStdxFromUtf8String<StdxPerson>(unknownPersonText).id
    }

    @Bench
    func yjsonBytesDecodeUnorderedPerson(): Unit {
        intSink = decodeYjsonReflectBytesWith(PersonJson, unorderedPersonBytes).id
    }

    @Bench
    func stdxBytesDecodeUnorderedPerson(): Unit {
        intSink = decodeStdxFromUtf8Bytes<StdxPerson>(unorderedPersonBytes).id
    }

    @Bench
    func yjsonBytesDecodeUnknownPerson(): Unit {
        intSink = decodeYjsonReflectBytesWith(PersonJson, unknownPersonBytes).id
    }

    @Bench
    func stdxBytesDecodeUnknownPerson(): Unit {
        intSink = decodeStdxFromUtf8Bytes<StdxPerson>(unknownPersonBytes).id
    }

    @Bench
    func yjsonStringDecodePrettyPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, prettyPersonText).id
    }

    @Bench
    func yjsonStringDecodePrettyPersonBatchGuard(): Unit {
        var value: Int64 = 0
        for (_ in 0..64) {
            value += YJson.decodeStringWith(PersonJson, prettyPersonText).id
        }
        intSink = value
    }

    @Bench
    func stdxStringDecodePrettyPerson(): Unit {
        intSink = decodeStdxFromUtf8String<StdxPerson>(prettyPersonText).id
    }
}
