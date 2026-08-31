package yjson_benchmarks

import yjson.*

import std.collection.*
import std.convert.Parsable
import std.unittest.*
import std.unittest.testmacro.*

main(): Unit {}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class YJsonBenchmarks {
    let person = samplePerson()
    let uint64Value = UInt64.parse("18446744073709551615")
    let uint64Envelope = sampleUInt64Envelope()
    let nestedProfilesCodec: JsonCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>
    let personText: String
    let personStreamText: String
    let addressText: String
    let bundleText: String
    let nestedProfilesText: String
    let uint64EnvelopeText: String
    let dateTimeText: String
    let htmlText: String
    var stringSink = ""
    var intSink: Int64 = 0
    var valueSink: JsonNode = JsonNode.nullValue

    init() {
        nestedProfilesCodec = nestedProfilesJson()
        personText = YJson.toJson(samplePerson(), codec: PersonJson)
        personStreamText = encodeToUtf8String(PersonJson, samplePerson())
        addressText = YJson.toJson(samplePerson().address, codec: AddressJson)
        bundleText = YJson.toJson(sampleProfileBundleForBench(), codec: ProfileBundleJson)
        nestedProfilesText = YJson.toJson(sampleNestedProfiles(), codec: nestedProfilesCodec)
        uint64EnvelopeText = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
        dateTimeText = YJson.toJson(sampleDateTime(), codec: JsonCodecs.rfc3339DateTime)
        htmlText = "<script>alert('yjson & stream')</script>"
    }

    @Bench
    func encodeCodecUInt64(): Unit {
        stringSink = YJson.toJson(uint64Value, codec: JsonCodecs.uint64)
    }

    @Bench
    func decodeCodecUInt64(): Unit {
        stringSink = YJson.fromJson("18446744073709551615", codec: JsonCodecs.uint64).toString()
    }

    @Bench
    func encodeCodecUInt64Envelope(): Unit {
        stringSink = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
    }

    @Bench
    func decodeCodecUInt64Envelope(): Unit {
        intSink = Int64(YJson.fromJson(uint64EnvelopeText, codec: UInt64EnvelopeJson).shardIds.size)
    }

    @Bench
    func encodeCodecPerson(): Unit {
        stringSink = YJson.toJson(person, codec: PersonJson)
    }

    @Bench
    func encodeCodecPersonToStream(): Unit {
        let out = YJsonMemoryOutputStream()
        YJson.writeJson(person, out, codec: PersonJson)
        stringSink = out.toUtf8String()
    }

    @Bench
    func decodeCodecAddress(): Unit {
        intSink = YJson.fromJson(addressText, codec: AddressJson).zipcode
    }

    @Bench
    func decodeCodecPerson(): Unit {
        intSink = YJson.fromJson(personText, codec: PersonJson).id
    }

    @Bench
    func decodeCodecPersonFromStream(): Unit {
        intSink = YJson.fromJson(YJsonByteArrayInputStream(personStreamText), codec: PersonJson).id
    }

    @Bench
    func decodeCodecProfileBundle(): Unit {
        intSink = YJson.fromJson(bundleText, codec: ProfileBundleJson).groups["platform"][0].id
    }

    @Bench
    func decodeCodecNestedProfiles(): Unit {
        intSink = findProfilesByGroup(
            YJson.fromJson(nestedProfilesText, codec: nestedProfilesCodec),
            "platform"
        )[0].id
    }

    @Bench
    func encodeLargeStringHtmlSafe(): Unit {
        stringSink = encodeToUtf8String(JsonCodecs.string, htmlText, config: htmlSafeCompactConfig())
    }

    @Bench
    func decodeCodecDateTime(): Unit {
        stringSink = YJson.fromJson(dateTimeText, codec: JsonCodecs.rfc3339DateTime).toString()
    }

    @Bench
    func parseOnlyPerson(): Unit {
        valueSink = JsonNode.parse(personText)
    }
}
