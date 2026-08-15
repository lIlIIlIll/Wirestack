// Adapter benchmark compiled inside a pinned cjfast_json checkout.
package fastjson.bench

import fastjson.*
import fastjson.macros.*
import fastjson.stream.*
import std.collection.*
import std.convert.Parsable
import std.io.*
import std.math.numeric.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@JsonAdapter
public class CompareAddress {
    @JsonName["street_name"]
    public var street: String = ""
    public var zipcode: Int64 = 0
}

@JsonAdapter
public class ComparePerson {
    @JsonName["user_id"]
    public var id: Int64 = 0
    public var name: String = ""
    public var age: Int32 = 0
    public var tags: ArrayList<String> = ArrayList<String>()
    public var scores: HashMap<String, Int64> = HashMap<String, Int64>()
    public var address: CompareAddress = CompareAddress()
    public var nick: Option<String> = None
}

@JsonAdapter
public class CompareProfileRecord {
    @JsonName["profile_id"]
    public var id: Int64 = 0
    public var alias: String = ""
    public var level: Int32 = 0
}

@JsonAdapter
public class CompareProfileBundle {
    public var groups: HashMap<String, ArrayList<CompareProfileRecord>> =
        HashMap<String, ArrayList<CompareProfileRecord>>()
    public var featured: Option<CompareProfileRecord> = None
}

@JsonAdapter
public class CompareUInt64Envelope {
    public var id: UInt64 = 0
    public var shardIds: Array<UInt64> = Array<UInt64>()
    public var quotas: HashMap<String, UInt64> = HashMap<String, UInt64>()
}

@JsonAdapter
public class CompareTemporalStats {
    public var createdAt: DateTime = DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339)
    public var totalEvents: BigInt = BigInt.parse("0")
    public var averageLatency: Decimal = Decimal.parse("0")
    public var checkpoints: ArrayList<DateTime> = ArrayList<DateTime>()
    public var ratios: HashMap<String, Decimal> = HashMap<String, Decimal>()
}

private func makePerson(): ComparePerson {
    let value = ComparePerson()
    value.id = 42
    value.name = "Lin"
    value.age = 28
    value.tags = ArrayList<String>(["cangjie", "json", "reflect"])
    value.scores.add("math", 95)
    value.scores.add("english", 88)
    value.address.street = "Nanshan Road"
    value.address.zipcode = 518000
    value
}

private func makeProfiles(count: Int64): ArrayList<CompareProfileRecord> {
    let values = ArrayList<CompareProfileRecord>(count)
    for (index in 0..count) {
        let value = CompareProfileRecord()
        value.id = 10_000 + index
        value.alias = "alias-${index % 16}-json-escape"
        value.level = Int32(index % 10)
        values.add(value)
    }
    values
}

private func makeMap(count: Int64): HashMap<String, Int64> {
    let values = HashMap<String, Int64>(count)
    for (index in 0..count) {
        values.add("metric_${index}", index * 17 + 3)
    }
    values
}

private func makeProfile(id: Int64, alias: String, level: Int32): CompareProfileRecord {
    let value = CompareProfileRecord()
    value.id = id
    value.alias = alias
    value.level = level
    value
}

private func makeProfileBundle(): CompareProfileBundle {
    let value = CompareProfileBundle()
    let ops = ArrayList<CompareProfileRecord>()
    ops.add(makeProfile(7, "ops", 3))
    ops.add(makeProfile(9, "infra", 4))
    value.groups.add("ops", ops)
    let platform = ArrayList<CompareProfileRecord>()
    platform.add(makeProfile(11, "platform", 5))
    value.groups.add("platform", platform)
    value
}

private func makeUInt64Envelope(): CompareUInt64Envelope {
    let value = CompareUInt64Envelope()
    value.id = UInt64.parse("18446744073709551615")
    value.shardIds = [0u64, UInt64.parse("18446744073709551614"), 42u64]
    value.quotas.add("burst", UInt64.parse("18446744073709551613"))
    value.quotas.add("steady", 42u64)
    value
}

private func makeTemporalStats(): CompareTemporalStats {
    let value = CompareTemporalStats()
    value.totalEvents = BigInt.parse("123456789012345678901234567890")
    value.averageLatency = Decimal.parse("12.375")
    value.checkpoints.add(value.createdAt)
    value.checkpoints.add(DateTime.parse("2024-06-20T15:12:33+08:00", DateTimeFormat.RFC3339))
    value.ratios.add("p50", Decimal.parse("12.5"))
    value.ratios.add("p99", Decimal.parse("98.25"))
    value
}

private func makeDeepProfiles(): ArrayList<HashMap<String, ArrayList<CompareProfileRecord>>> {
    let nested = ArrayList<HashMap<String, ArrayList<CompareProfileRecord>>>(8)
    for (groupIndex in 0..8) {
        let group = HashMap<String, ArrayList<CompareProfileRecord>>(2)
        let profiles = ArrayList<CompareProfileRecord>(4)
        for (recordIndex in 0..4) {
            profiles.add(makeProfile(
                groupIndex * 100 + recordIndex,
                "group-${groupIndex}-profile-${recordIndex}",
                Int32((groupIndex + recordIndex) % 10)
            ))
        }
        group.add("group_${groupIndex}", profiles)
        nested.add(group)
    }
    nested
}

private func encodeBytes<T>(value: T, config!: WriteConfig = WriteConfig.compact): Array<Byte>
    where T <: JsonStreamSerializable {
    let stream = ByteBuffer()
    let writer = JsonStreamWriter(stream)
    writer.writeConfig = config
    value.toJson(writer)
    writer.flush()
    readToEnd(stream)
}

private func decodeBytes<T>(bytes: Array<Byte>): T where T <: JsonStreamDeserializable<T> {
    T.fromJson(JsonStreamReader(ByteBuffer(bytes)))
}

private func comparePrettyConfig(): WriteConfig {
    var config = WriteConfig.pretty
    config.indent = "  "
    config
}

private func unorderedPersonText(): String {
    "{" +
        "\"nick\":null," +
        "\"address\":{\"zipcode\":518000,\"street_name\":\"Nanshan Road\"}," +
        "\"scores\":{\"english\":88,\"math\":95}," +
        "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
        "\"age\":28,\"name\":\"Lin\",\"user_id\":42}"
}

private func unknownPersonText(): String {
    "{" +
        "\"user_id\":42," +
        "\"unknownObject\":{\"left\":[1,2,3],\"right\":{\"enabled\":true}}," +
        "\"name\":\"Lin\",\"age\":28," +
        "\"tags\":[\"cangjie\",\"json\",\"reflect\"]," +
        "\"scores\":{\"math\":95,\"english\":88}," +
        "\"address\":{\"street_name\":\"Nanshan Road\",\"zipcode\":518000,\"ignored\":true}," +
        "\"unknownArray\":[{\"x\":1},null,false],\"nick\":null}"
}

private func prettyPersonText(): String {
    "{\n" +
        "  \"user_id\": 42,\n  \"name\": \"Lin\",\n  \"age\": 28,\n" +
        "  \"tags\": [\n    \"cangjie\",\n    \"json\",\n    \"reflect\"\n  ],\n" +
        "  \"scores\": {\n    \"math\": 95,\n    \"english\": 88\n  },\n" +
        "  \"address\": {\n    \"street_name\": \"Nanshan Road\",\n    \"zipcode\": 518000\n  },\n" +
        "  \"nick\": null\n}"
}

private func escapedText(): String {
    "Cangjie JSON \"escape\" \\ slash / line\n tab\t unicode 仓颉 Δ ✓"
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class CjFastJsonComprehensiveBenchmarks {
    let address = makePerson().address
    let person = makePerson()
    let profileBundle = makeProfileBundle()
    let uint64Envelope = makeUInt64Envelope()
    let temporalStats = makeTemporalStats()
    let profiles = makeProfiles(64)
    let intMap = makeMap(64)
    let deepProfiles = makeDeepProfiles()
    let unicodeText = escapedText()
    let prettyConfig = comparePrettyConfig()
    let addressText: String
    let personText: String
    let profileBundleText: String
    let uint64EnvelopeText: String
    let temporalStatsText: String
    let profilesText: String
    let mapText: String
    let deepProfilesText: String
    let unicodeJsonText: String
    let addressBytes: Array<Byte>
    let personBytes: Array<Byte>
    let profileBundleBytes: Array<Byte>
    let uint64EnvelopeBytes: Array<Byte>
    let temporalStatsBytes: Array<Byte>
    let unicodeBytes: Array<Byte>
    var stringSink = ""
    var intSink: Int64 = 0
    var bytesSink: Array<Byte> = Array<Byte>()

    init() {
        addressText = address.toJson()
        personText = person.toJson()
        profileBundleText = profileBundle.toJson()
        uint64EnvelopeText = uint64Envelope.toJson()
        temporalStatsText = temporalStats.toJson()
        profilesText = profiles.toJson()
        mapText = intMap.toJson()
        deepProfilesText = deepProfiles.toJson()
        unicodeJsonText = unicodeText.toJson()
        addressBytes = encodeBytes(address)
        personBytes = encodeBytes(person)
        profileBundleBytes = encodeBytes(profileBundle)
        uint64EnvelopeBytes = encodeBytes(uint64Envelope)
        temporalStatsBytes = encodeBytes(temporalStats)
        unicodeBytes = encodeBytes(unicodeText)
        if (ComparePerson.fromJson(personText).id != 42 ||
            CompareProfileBundle.fromJson(profileBundleText).groups["platform"][0].id != 11 ||
            CompareUInt64Envelope.fromJson(uint64EnvelopeText).shardIds.size != 3 ||
            CompareTemporalStats.fromJson(temporalStatsText).totalEvents.toString() != "123456789012345678901234567890" ||
            ArrayList<CompareProfileRecord>.fromJson(profilesText).size != 64 ||
            HashMap<String, Int64>.fromJson(mapText).size != 64 ||
            ArrayList<HashMap<String, ArrayList<CompareProfileRecord>>>.fromJson(deepProfilesText).size != 8 ||
            ComparePerson.fromJson(unorderedPersonText()).id != 42 ||
            ComparePerson.fromJson(unknownPersonText()).address.zipcode != 518000 ||
            ComparePerson.fromJson(prettyPersonText()).id != 42 ||
            String.fromJson(unicodeJsonText) != unicodeText) {
            throw Exception("cjfast_json benchmark fixture validation failed")
        }
        println("CJFAST_PAYLOAD_BYTES person=${personText.toArray().size} profiles64=${profilesText.toArray().size} map64=${mapText.toArray().size} unicode=${unicodeJsonText.toArray().size}")
    }

    @Bench
    func cjfastStringEncodeAddress(): Unit { stringSink = address.toJson() }

    @Bench
    func cjfastStringDecodeAddress(): Unit { intSink = CompareAddress.fromJson(addressText).zipcode }

    @Bench
    func cjfastStringEncodePerson(): Unit { stringSink = person.toJson() }

    @Bench
    func cjfastStringDecodePerson(): Unit { intSink = ComparePerson.fromJson(personText).id }

    @Bench
    func cjfastStringEncodeProfileBundle(): Unit { stringSink = profileBundle.toJson() }

    @Bench
    func cjfastStringDecodeProfileBundle(): Unit {
        intSink = CompareProfileBundle.fromJson(profileBundleText).groups["platform"][0].id
    }

    @Bench
    func cjfastStringEncodeUInt64Envelope(): Unit { stringSink = uint64Envelope.toJson() }

    @Bench
    func cjfastStringDecodeUInt64Envelope(): Unit {
        intSink = Int64(CompareUInt64Envelope.fromJson(uint64EnvelopeText).shardIds.size)
    }

    @Bench
    func cjfastStringEncodeTemporalStats(): Unit { stringSink = temporalStats.toJson() }

    @Bench
    func cjfastStringDecodeTemporalStats(): Unit {
        stringSink = CompareTemporalStats.fromJson(temporalStatsText).totalEvents.toString()
    }

    @Bench
    func cjfastStringEncodePrettyPerson(): Unit {
        bytesSink = encodeBytes(person, config: prettyConfig)
    }

    @Bench
    func cjfastStreamEncodePerson(): Unit {
        stringSink = unsafe { String.fromUtf8Unchecked(encodeBytes(person)) }
    }

    @Bench
    func cjfastStreamDecodePerson(): Unit { intSink = decodeBytes<ComparePerson>(personBytes).id }

    @Bench
    func cjfastBytesEncodePerson(): Unit { bytesSink = encodeBytes(person) }

    @Bench
    func cjfastBytesDecodePerson(): Unit { intSink = decodeBytes<ComparePerson>(personBytes).id }

    @Bench
    func cjfastBytesEncodeAddress(): Unit { bytesSink = encodeBytes(address) }

    @Bench
    func cjfastBytesDecodeAddress(): Unit { intSink = decodeBytes<CompareAddress>(addressBytes).zipcode }

    @Bench
    func cjfastBytesEncodeProfileBundle(): Unit { bytesSink = encodeBytes(profileBundle) }

    @Bench
    func cjfastBytesDecodeProfileBundle(): Unit {
        intSink = decodeBytes<CompareProfileBundle>(profileBundleBytes).groups["platform"][0].id
    }

    @Bench
    func cjfastBytesEncodeUInt64Envelope(): Unit { bytesSink = encodeBytes(uint64Envelope) }

    @Bench
    func cjfastBytesDecodeUInt64Envelope(): Unit {
        intSink = Int64(decodeBytes<CompareUInt64Envelope>(uint64EnvelopeBytes).shardIds.size)
    }

    @Bench
    func cjfastBytesEncodeTemporalStats(): Unit { bytesSink = encodeBytes(temporalStats) }

    @Bench
    func cjfastBytesDecodeTemporalStats(): Unit {
        stringSink = decodeBytes<CompareTemporalStats>(temporalStatsBytes).totalEvents.toString()
    }

    @Bench
    func cjfastStringEncodeLargeProfileArray(): Unit { stringSink = profiles.toJson() }

    @Bench
    func cjfastStringDecodeLargeProfileArray(): Unit {
        intSink = ArrayList<CompareProfileRecord>.fromJson(profilesText)[0].id
    }

    @Bench
    func cjfastStringEncodeLargeInt64Map(): Unit { stringSink = intMap.toJson() }

    @Bench
    func cjfastStringDecodeLargeInt64Map(): Unit {
        intSink = HashMap<String, Int64>.fromJson(mapText)["metric_32"]
    }

    @Bench
    func cjfastStringEncodeDeepNestedProfiles(): Unit { stringSink = deepProfiles.toJson() }

    @Bench
    func cjfastStringDecodeDeepNestedProfiles(): Unit {
        intSink = ArrayList<HashMap<String, ArrayList<CompareProfileRecord>>>.fromJson(deepProfilesText)[0]["group_0"][0].id
    }

    @Bench
    func cjfastStringDecodeUnorderedPerson(): Unit {
        intSink = ComparePerson.fromJson(unorderedPersonText()).id
    }

    @Bench
    func cjfastStringDecodeUnknownPerson(): Unit {
        intSink = ComparePerson.fromJson(unknownPersonText()).id
    }

    @Bench
    func cjfastStringDecodePrettyPerson(): Unit {
        intSink = ComparePerson.fromJson(prettyPersonText()).id
    }

    @Bench
    func cjfastStringEncodeEscapedUnicodeString(): Unit { stringSink = unicodeText.toJson() }

    @Bench
    func cjfastStringDecodeEscapedUnicodeString(): Unit {
        stringSink = String.fromJson(unicodeJsonText)
    }

    @Bench
    func cjfastBytesEncodeEscapedUnicodeString(): Unit { bytesSink = encodeBytes(unicodeText) }

    @Bench
    func cjfastBytesDecodeEscapedUnicodeString(): Unit {
        stringSink = decodeBytes<String>(unicodeBytes)
    }
}
