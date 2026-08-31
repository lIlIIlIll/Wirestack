package yjson

import yjson_macros.*

import std.collection.*
import std.convert.Parsable
import std.math.numeric.*
import std.time.*

@JsonCodec
public struct Address {
    @JsonName["street_name"]
    public var street: String
    public var zipcode: Int64

    public init(street: String, zipcode: Int64) {
        this.street = street
        this.zipcode = zipcode
    }
}

@JsonCodec
public class Person {
    @JsonName["user_id"]
    public let id: Int64
    public var name: String
    public var age: Int32
    public var tags: ArrayList<String>
    public var scores: HashMap<String, Int64>
    public var address: Address
    @JsonIncludeNull
    public var nick: Option<String>
    @JsonIgnore
    public var ignored: String = "should-not-appear"

    public init(
        @JsonName["user_id"] id: Int64,
        name: String,
        age: Int32,
        tags: ArrayList<String>,
        scores: HashMap<String, Int64>,
        address: Address,
        nick: Option<String>
    ) {
        this.id = id
        this.name = name
        this.age = age
        this.tags = tags
        this.scores = scores
        this.address = address
        this.nick = nick
    }
}

@JsonCodec
public struct AddressBatch {
    public var homes: Array<Address>

    public init(homes: Array<Address>) {
        this.homes = homes
    }
}

@JsonCodec
public class ProfileRecord {
    @JsonName["profile_id"]
    public let id: Int64
    public var alias: String = ""
    public var level: Int32 = 0

    public init(id: Int64) {
        this.id = id
    }
}

@JsonCodec
public class ZeroPreferred {
    public var createdBy: String = "zero-ctor"
    public var enabled: Bool = false

    public init() {}

    public init(createdBy: String, enabled: Bool) {
        this.createdBy = createdBy
        this.enabled = enabled
    }
}

@JsonCodec
public struct ProfileBundle {
    public var groups: HashMap<String, ArrayList<ProfileRecord>>
    @JsonIncludeNull
    public var featured: Option<ProfileRecord>

    public init() {
        this.groups = HashMap<String, ArrayList<ProfileRecord>>()
        this.featured = None
    }

    public init(groups: HashMap<String, ArrayList<ProfileRecord>>, featured: Option<ProfileRecord>) {
        this.groups = groups
        this.featured = featured
    }
}

@JsonCodec
public struct TemporalStats {
    @JsonUsing[JsonCodecs.rfc3339DateTime]
    public var createdAt: DateTime
    public var totalEvents: BigInt
    public var averageLatency: Decimal
    @JsonUsing[JsonCodecs.arrayList(JsonCodecs.rfc3339DateTime)]
    public var checkpoints: ArrayList<DateTime>
    public var ratios: HashMap<String, Decimal>

    public init(
        createdAt: DateTime,
        totalEvents: BigInt,
        averageLatency: Decimal,
        checkpoints: ArrayList<DateTime>,
        ratios: HashMap<String, Decimal>
    ) {
        this.createdAt = createdAt
        this.totalEvents = totalEvents
        this.averageLatency = averageLatency
        this.checkpoints = checkpoints
        this.ratios = ratios
    }
}

@JsonCodec
public struct UInt64Envelope {
    public var id: UInt64
    public var shardIds: Array<UInt64>
    public var quotas: HashMap<String, UInt64>

    public init(id: UInt64, shardIds: Array<UInt64>, quotas: HashMap<String, UInt64>) {
        this.id = id
        this.shardIds = shardIds
        this.quotas = quotas
    }
}

public func assertJson(condition: Bool, message: String): Unit {
    if (!condition) {
        throw JsonException(message)
    }
}

public func assertProfileRecord(profile: ProfileRecord, id: Int64, alias: String, level: Int32, messagePrefix: String): Unit {
    assertJson(profile.id == id, "${messagePrefix}: id mismatch")
    assertJson(profile.alias == alias, "${messagePrefix}: alias mismatch")
    assertJson(profile.level == level, "${messagePrefix}: level mismatch")
}

public func findProfilesByGroup(
    nested: ArrayList<HashMap<String, ArrayList<ProfileRecord>>>,
    groupName: String
): ArrayList<ProfileRecord> {
    for (group in nested) {
        for ((key, profiles) in group) {
            if (key == groupName) {
                return profiles
            }
        }
    }
    throw JsonException("nested profile group `${groupName}` not found")
}

public func assertProfileBundle(bundle: ProfileBundle, messagePrefix: String): Unit {
    assertJson(bundle.groups.size == 2, "${messagePrefix}: group size mismatch")
    assertProfileRecord(bundle.groups["ops"][1], 9, "infra", 4, "${messagePrefix}: ops profile")
    assertProfileRecord(bundle.groups["platform"][0], 11, "platform", 5, "${messagePrefix}: platform profile")
    assertProfileRecord(bundle.featured.getOrThrow(), 11, "platform", 5, "${messagePrefix}: featured profile")
}

public func assertUInt64Envelope(envelope: UInt64Envelope, messagePrefix: String): Unit {
    assertJson(envelope.id == UInt64.parse("18446744073709551615"), "${messagePrefix}: id mismatch")
    assertJson(envelope.shardIds.size == 3, "${messagePrefix}: shardIds size mismatch")
    assertJson(envelope.shardIds[1] == UInt64.parse("18446744073709551614"), "${messagePrefix}: shardIds[1] mismatch")
    assertJson(envelope.quotas.size == 2, "${messagePrefix}: quotas size mismatch")
    assertJson(envelope.quotas["burst"] == UInt64.parse("18446744073709551613"), "${messagePrefix}: burst quota mismatch")
    assertJson(envelope.quotas["steady"] == 42, "${messagePrefix}: steady quota mismatch")
}

public func samplePerson(): Person {
    let scores = HashMap<String, Int64>()
    scores.add("math", 95)
    scores.add("english", 88)
    Person(
        42,
        "Lin",
        28,
        ArrayList<String>(["cangjie", "json", "reflect"]),
        scores,
        Address("Nanshan Road", 518000),
        None
    )
}

public func sampleAddressBatch(): AddressBatch {
    AddressBatch(Array<Address>(2, {
        index => if (index == 0) {
            Address("Nanshan Road", 518000)
        } else {
            Address("Binjiang Avenue", 200000)
        }
    }))
}

public func sampleProfileRecord(): ProfileRecord {
    let profile = ProfileRecord(7)
    profile.alias = "ops"
    profile.level = 3
    profile
}

public func makeProfileRecord(id: Int64, alias: String, level: Int32): ProfileRecord {
    let profile = ProfileRecord(id)
    profile.alias = alias
    profile.level = level
    profile
}

public func sampleLargeProfileRecords(count!: Int64 = 64): ArrayList<ProfileRecord> {
    let profiles = ArrayList<ProfileRecord>(count)
    for (index in 0..count) {
        profiles.add(makeProfileRecord(
            10_000 + index,
            "alias-${index % 16}-json-escape",
            Int32(index % 10)
        ))
    }
    profiles
}

public func sampleLargeInt64Map(count!: Int64 = 64): HashMap<String, Int64> {
    let values = HashMap<String, Int64>(count)
    for (index in 0..count) {
        values.add("metric_${index}", index * 17 + 3)
    }
    values
}

public func sampleDeepNestedProfiles(
    groupCount!: Int64 = 8,
    recordCount!: Int64 = 4
): ArrayList<HashMap<String, ArrayList<ProfileRecord>>> {
    let nested = ArrayList<HashMap<String, ArrayList<ProfileRecord>>>(groupCount)
    for (groupIndex in 0..groupCount) {
        let group = HashMap<String, ArrayList<ProfileRecord>>(2)
        let profiles = ArrayList<ProfileRecord>(recordCount)
        for (recordIndex in 0..recordCount) {
            profiles.add(makeProfileRecord(
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

public func sampleNestedProfiles(): ArrayList<HashMap<String, ArrayList<ProfileRecord>>> {
    let opsProfiles = ArrayList<ProfileRecord>()
    opsProfiles.add(makeProfileRecord(7, "ops", 3))
    opsProfiles.add(makeProfileRecord(9, "infra", 4))

    let platformProfiles = ArrayList<ProfileRecord>()
    platformProfiles.add(makeProfileRecord(11, "platform", 5))

    let firstGroup = HashMap<String, ArrayList<ProfileRecord>>()
    firstGroup.add("ops", opsProfiles)

    let secondGroup = HashMap<String, ArrayList<ProfileRecord>>()
    secondGroup.add("platform", platformProfiles)

    let nested = ArrayList<HashMap<String, ArrayList<ProfileRecord>>>()
    nested.add(firstGroup)
    nested.add(secondGroup)
    nested
}

public func sampleProfileBundle(): ProfileBundle {
    let groups = HashMap<String, ArrayList<ProfileRecord>>()

    let opsProfiles = ArrayList<ProfileRecord>()
    opsProfiles.add(makeProfileRecord(7, "ops", 3))
    opsProfiles.add(makeProfileRecord(9, "infra", 4))
    groups.add("ops", opsProfiles)

    let platformProfiles = ArrayList<ProfileRecord>()
    platformProfiles.add(makeProfileRecord(11, "platform", 5))
    groups.add("platform", platformProfiles)

    ProfileBundle(groups, Some(makeProfileRecord(11, "platform", 5)))
}

public func sampleProfileBundleForBench(): ProfileBundle {
    var bundle = sampleProfileBundle()
    bundle.featured = None
    bundle
}

public func sampleDateTime(): DateTime {
    DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339)
}

public func sampleTemporalStats(): TemporalStats {
    let checkpoints = ArrayList<DateTime>()
    checkpoints.add(sampleDateTime())
    checkpoints.add(DateTime.parse("2024-06-20T15:12:33+08:00", DateTimeFormat.RFC3339))

    let ratios = HashMap<String, Decimal>()
    ratios.add("p50", Decimal.parse("12.5"))
    ratios.add("p99", Decimal.parse("98.25"))

    TemporalStats(
        sampleDateTime(),
        BigInt.parse("123456789012345678901234567890"),
        Decimal.parse("12.375"),
        checkpoints,
        ratios
    )
}

public func sampleUInt64Envelope(): UInt64Envelope {
    let quotas = HashMap<String, UInt64>()
    quotas.add("burst", UInt64.parse("18446744073709551613"))
    quotas.add("steady", 42)

    UInt64Envelope(
        UInt64.parse("18446744073709551615"),
        Array<UInt64>(3, {
            index => match (index) {
                case 0 => 0
                case 1 => UInt64.parse("18446744073709551614")
                case _ => 42
            }
        }),
        quotas
    )
}

public func profileRecordOptionJson(): JsonCodec<Option<ProfileRecord>> {
    JsonCodecs.option(ProfileRecordJson)
}

public func nestedProfilesJson(): JsonCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>> {
    JsonCodecs.arrayList(JsonCodecs.stringMap(JsonCodecs.arrayList(ProfileRecordJson)))
}

public func encodeToUtf8String<T>(
    codec: JsonCodec<T>,
    value: T,
    config!: JsonWriteOptions = JsonWriteOptions.compact
): String {
    let out = MemoryOutputStream()
    YJson.writeJson(value, out, codec: codec, options: config)
    out.toUtf8String()
}

public func decodeFromUtf8String<T>(codec: JsonCodec<T>, text: String): T {
    YJson.fromJson(ByteArrayInputStream(text), codec: codec)
}

public func htmlSafeCompactConfig(): JsonWriteOptions {
    JsonWriteOptions(indent: JsonWriteOptions.compact.indent, htmlSafe: true)
}

public func elapsedNanoseconds(start: DateTime): Int64 {
    let elapsed: Duration = DateTime.now() - start
    elapsed.toNanoseconds()
}

public func benchmark(label: String, iterations: Int64, action: () -> Unit): Unit {
    for (_ in 0..1000) {
        action()
    }
    let start = DateTime.now()
    for (_ in 0..iterations) {
        action()
    }
    let nanos = elapsedNanoseconds(start)
    let perOp = Float64(nanos) / Float64(iterations)
    let totalMillis = Float64(nanos) / 1_000_000.0
    println("${label}: total=${totalMillis} ms, ns/op=${perOp}")
}

public func runChecks(person: Person): String {
    let profileOptionCodec = profileRecordOptionJson()
    let nestedCodec = nestedProfilesJson()
    let codecText = YJson.toJson(person, codec: PersonJson)
    assertJson(codecText.contains("\"user_id\":42"), "renamed field missing")
    assertJson(!codecText.contains("ignored"), "ignored field leaked into json")
    assertJson(codecText.contains("\"nick\":null"), "include-null field missing")
    let codecDecoded = YJson.fromJson(codecText, codec: PersonJson)
    assertJson(codecDecoded.id == person.id, "codec id mismatch after decode")
    assertJson(codecDecoded.name == person.name, "codec name mismatch after decode")
    assertJson(codecDecoded.age == person.age, "codec age mismatch after decode")
    assertJson(codecDecoded.address.street == person.address.street, "codec nested object mismatch")
    assertJson(codecDecoded.tags.size == person.tags.size, "codec array size mismatch")
    assertJson(codecDecoded.scores["math"] == 95, "codec hash map mismatch")
    let streamText = encodeToUtf8String(PersonJson, person, config: JsonWriteOptions.pretty())
    assertJson(streamText.contains("\"user_id\": 42"), "stream pretty output mismatch")
    let streamDecoded = decodeFromUtf8String(PersonJson, streamText)
    assertJson(streamDecoded.id == person.id, "stream id mismatch after decode")
    assertJson(streamDecoded.address.zipcode == person.address.zipcode, "stream nested object mismatch")
    let htmlSafeText = encodeToUtf8String(JsonCodecs.string, "<tag attr='x'>&payload</tag>", config: htmlSafeCompactConfig())
    assertJson(htmlSafeText.contains("\\u003C"), "htmlSafe should escape <")
    assertJson(htmlSafeText.contains("\\u0026"), "htmlSafe should escape &")
    let dateTimeText = YJson.toJson(sampleDateTime(), codec: JsonCodecs.rfc3339DateTime)
    assertJson(dateTimeText.contains("2024-06-20T14:42:33+08:00"), "DateTime codec output mismatch")
    let decodedDateTime = YJson.fromJson(dateTimeText, codec: JsonCodecs.rfc3339DateTime)
    assertJson(decodedDateTime == sampleDateTime(), "DateTime codec roundtrip mismatch")
    let bigIntText = YJson.toJson(BigInt.parse("123456789012345678901234567890"), codec: JsonCodecs.bigInt)
    assertJson(bigIntText == "123456789012345678901234567890", "BigInt codec output mismatch")
    let decimalText = YJson.toJson(Decimal.parse("12.375"), codec: JsonCodecs.decimal)
    assertJson(decimalText == "12.375", "Decimal codec output mismatch")

    let topLevelUInt64 = UInt64.parse("18446744073709551615")
    let topLevelUInt64Text = YJson.toJson(topLevelUInt64, codec: JsonCodecs.uint64)
    assertJson(topLevelUInt64Text == "18446744073709551615", "JsonCodecs.uint64 should encode as a bare number")
    assertJson(YJson.fromJson(topLevelUInt64Text, codec: JsonCodecs.uint64) == topLevelUInt64, "JsonCodecs.uint64 roundtrip mismatch")
    assertJson(
        YJson.fromJson("18446744073709551614", codec: JsonCodecs.uint64) == UInt64.parse("18446744073709551614"),
        "JsonCodecs.uint64 should decode bare numbers"
    )
    let quotedUInt64Rejected = try {
        let _ = YJson.fromJson("\"18446744073709551614\"", codec: JsonCodecs.uint64)
        false
    } catch (_: JsonException) {
        true
    }
    assertJson(quotedUInt64Rejected, "JsonCodecs.uint64 should reject quoted numeric strings")

    let uint64Envelope = sampleUInt64Envelope()
    let uint64EnvelopeText = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
    assertJson(
        uint64EnvelopeText.contains("\"id\":18446744073709551615"),
        "generated UInt64 field should encode as a bare number"
    )
    assertJson(
        uint64EnvelopeText.contains("\"shardIds\":[0,18446744073709551614,42]"),
        "generated Array<UInt64> should encode as bare numbers"
    )
    assertJson(
        uint64EnvelopeText.contains("\"burst\":18446744073709551613"),
        "generated HashMap<String, UInt64> should encode bare number values"
    )
    assertJson(
        uint64EnvelopeText.contains("\"steady\":42"),
        "generated HashMap<String, UInt64> should encode small bare number values"
    )
    assertUInt64Envelope(YJson.fromJson(uint64EnvelopeText, codec: UInt64EnvelopeJson), "generated UInt64 envelope roundtrip")

    let batch = sampleAddressBatch()
    let batchText = YJson.toJson(batch, codec: AddressBatchJson)
    let batchDecoded = YJson.fromJson(batchText, codec: AddressBatchJson)
    assertJson(batchDecoded.homes.size == 2, "codec fixed array size mismatch")
    assertJson(batchDecoded.homes[1].street == "Binjiang Avenue", "codec fixed array nested decode mismatch")

    let profile = sampleProfileRecord()
    let profileText = YJson.toJson(profile, codec: ProfileRecordJson)
    let profileDecoded = YJson.fromJson(profileText, codec: ProfileRecordJson)
    assertJson(profileDecoded.id == 7, "constructor parameter fallback to field JsonName failed")
    assertJson(profileDecoded.alias == "ops", "post-construction mutable field assignment failed")
    assertJson(profileDecoded.level == 3, "post-construction Int32 assignment failed")

    let zeroPreferred = YJson.fromJson("{\"enabled\":true}", codec: ZeroPreferredJson)
    assertJson(zeroPreferred.createdBy == "zero-ctor", "zero-arg constructor should be preferred when available")
    assertJson(zeroPreferred.enabled, "zero-arg constructor path should still apply mutable field updates")

    let bundle = sampleProfileBundle()
    let bundleText = YJson.toJson(bundle, codec: ProfileBundleJson)
    assertJson(bundleText.contains("\"groups\""), "profile bundle nested groups field missing")
    let bundleFeaturedNode = JsonNode.parse(bundleText).asObject().get("featured").getOrThrow()
    let bundleFeatured = YJson.fromJson(bundleFeaturedNode.toJson(), codec: profileOptionCodec)
    assertProfileRecord(
        bundleFeatured.getOrThrow(),
        11,
        "platform",
        5,
        "profile bundle standalone featured"
    )
    let bundleDecoded = YJson.fromJson(bundleText, codec: ProfileBundleJson)
    assertProfileBundle(bundleDecoded, "profile bundle codec")

    let temporalStats = sampleTemporalStats()
    let temporalText = YJson.toJson(temporalStats, codec: TemporalStatsJson)
    let temporalDecoded = YJson.fromJson(temporalText, codec: TemporalStatsJson)
    assertJson(temporalDecoded.createdAt == temporalStats.createdAt, "temporal stats DateTime mismatch")
    assertJson(temporalDecoded.totalEvents == temporalStats.totalEvents, "temporal stats BigInt mismatch")
    assertJson(temporalDecoded.averageLatency == temporalStats.averageLatency, "temporal stats Decimal mismatch")
    assertJson(temporalDecoded.checkpoints.size == 2, "temporal stats checkpoints size mismatch")
    assertJson(temporalDecoded.ratios["p99"] == Decimal.parse("98.25"), "temporal stats nested decimal mismatch")

    let nestedProfiles = sampleNestedProfiles()
    let nestedCodecText = YJson.toJson(nestedProfiles, codec: nestedCodec)
    let nestedCodecDecoded = YJson.fromJson(nestedCodecText, codec: nestedCodec)
    let codecOpsProfiles = findProfilesByGroup(nestedCodecDecoded, "ops")
    let codecPlatformProfiles = findProfilesByGroup(nestedCodecDecoded, "platform")
    assertJson(nestedCodecDecoded.size == 2, "nested codec outer size mismatch")
    assertJson(codecOpsProfiles.size == 2, "nested codec first group size mismatch")
    assertProfileRecord(codecOpsProfiles[1], 9, "infra", 4, "nested codec second ops profile")
    assertProfileRecord(codecPlatformProfiles[0], 11, "platform", 5, "nested codec platform profile")

    codecText
}

public func runBenchmarks(person: Person, jsonText: String): Unit {
    let iterations = 20000
    let bundle = sampleProfileBundleForBench()
    let uint64Value = UInt64.parse("18446744073709551615")
    let uint64Envelope = sampleUInt64Envelope()
    let dateTimeText = YJson.toJson(sampleDateTime(), codec: JsonCodecs.rfc3339DateTime)
    let nestedCodec = nestedProfilesJson()
    let addressText = YJson.toJson(person.address, codec: AddressJson)
    let bundleText = YJson.toJson(bundle, codec: ProfileBundleJson)
    let nestedProfilesText = YJson.toJson(sampleNestedProfiles(), codec: nestedCodec)
    let uint64EnvelopeText = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
    let personStreamText = encodeToUtf8String(PersonJson, person)
    let htmlSample = "<script>alert('yjson & stream')</script>"
    println("\n=== Benchmarks ===")
    benchmark("encode-codec-uint64", iterations, { => let _ = YJson.toJson(uint64Value, codec: JsonCodecs.uint64) })
    benchmark("decode-codec-uint64", iterations, { => let _ = YJson.fromJson("18446744073709551615", codec: JsonCodecs.uint64) })
    benchmark("encode-codec-uint64-envelope", iterations, {
        => let _ = YJson.toJson(uint64Envelope, codec: UInt64EnvelopeJson)
    })
    benchmark("decode-codec-uint64-envelope", iterations, {
        => let _ = YJson.fromJson(uint64EnvelopeText, codec: UInt64EnvelopeJson)
    })
    benchmark("encode-codec-person", iterations, { => let _ = YJson.toJson(person, codec: PersonJson) })
    benchmark("encode-codec-person-to-stream", iterations, {
        =>
        let out = MemoryOutputStream()
        YJson.writeJson(person, out, codec: PersonJson)
    })
    benchmark("decode-codec-address", iterations, { => let _ = YJson.fromJson(addressText, codec: AddressJson) })
    benchmark("decode-codec-person", iterations, { => let _ = YJson.fromJson(jsonText, codec: PersonJson) })
    benchmark("decode-codec-person-from-stream", iterations, {
        =>
        let _ = YJson.fromJson(ByteArrayInputStream(personStreamText), codec: PersonJson)
    })
    benchmark("decode-codec-profile-bundle", iterations, {
        => let _ = YJson.fromJson(bundleText, codec: ProfileBundleJson)
    })
    benchmark("decode-codec-nested-profiles", iterations, {
        => let _ = YJson.fromJson(nestedProfilesText, codec: nestedCodec)
    })
    benchmark("encode-large-string-html-safe", iterations, {
        => let _ = encodeToUtf8String(JsonCodecs.string, htmlSample, config: htmlSafeCompactConfig())
    })
    benchmark("decode-codec-datetime", iterations, { => let _ = YJson.fromJson(dateTimeText, codec: JsonCodecs.rfc3339DateTime) })
    benchmark("parse-only-person", iterations, { => let _ = JsonNode.parse(jsonText) })
}
