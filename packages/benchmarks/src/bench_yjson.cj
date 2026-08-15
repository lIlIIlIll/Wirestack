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
    let nestedProfilesCodec: JsonDirectCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>
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
    var valueSink: JsonValue = JsonNullValue()

    init() {
        nestedProfilesCodec = nestedProfilesJson()
        personText = YJson.encodeStringWith(PersonJson, samplePerson())
        personStreamText = encodeToUtf8String(PersonJson, samplePerson())
        addressText = YJson.encodeStringWith(AddressJson, samplePerson().address)
        bundleText = YJson.encodeStringWith(ProfileBundleJson, sampleProfileBundleForBench())
        nestedProfilesText = YJson.encodeStringWith(nestedProfilesCodec, sampleNestedProfiles())
        uint64EnvelopeText = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
        dateTimeText = YJson.encodeStringWith(DateTimeJson, sampleDateTime())
        htmlText = "<script>alert('yjson & stream')</script>"
    }

    @Bench
    func encodeCodecUInt64(): Unit {
        stringSink = YJson.encodeStringWith(UInt64Json, uint64Value)
    }

    @Bench
    func decodeCodecUInt64(): Unit {
        stringSink = YJson.decodeStringWith(UInt64Json, "18446744073709551615").toString()
    }

    @Bench
    func encodeCodecUInt64Envelope(): Unit {
        stringSink = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
    }

    @Bench
    func decodeCodecUInt64Envelope(): Unit {
        intSink = Int64(YJson.decodeStringWith(UInt64EnvelopeJson, uint64EnvelopeText).shardIds.size)
    }

    @Bench
    func encodeCodecPerson(): Unit {
        stringSink = YJson.encodeStringWith(PersonJson, person)
    }

    @Bench
    func encodeCodecPersonToStream(): Unit {
        let out = YJsonMemoryOutputStream()
        YJson.encodeToStreamWith(PersonJson, person, out)
        stringSink = out.toUtf8String()
    }

    @Bench
    func decodeCodecAddress(): Unit {
        intSink = YJson.decodeStringWith(AddressJson, addressText).zipcode
    }

    @Bench
    func decodeCodecPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, personText).id
    }

    @Bench
    func decodeCodecPersonFromStream(): Unit {
        intSink = YJson.decodeFromStreamWith(PersonJson, YJsonByteArrayInputStream(personStreamText)).id
    }

    @Bench
    func decodeCodecProfileBundle(): Unit {
        intSink = YJson.decodeStringWith(ProfileBundleJson, bundleText).groups["platform"][0].id
    }

    @Bench
    func decodeCodecNestedProfiles(): Unit {
        intSink = findProfilesByGroup(
            YJson.decodeStringWith(nestedProfilesCodec, nestedProfilesText),
            "platform"
        )[0].id
    }

    @Bench
    func encodeLargeStringHtmlSafe(): Unit {
        stringSink = encodeToUtf8String(StringJson, htmlText, config: htmlSafeCompactConfig())
    }

    @Bench
    func decodeCodecDateTime(): Unit {
        stringSink = YJson.decodeStringWith(DateTimeJson, dateTimeText).toString()
    }

    @Bench
    func parseOnlyPerson(): Unit {
        valueSink = YJson.parse(personText)
    }
}
