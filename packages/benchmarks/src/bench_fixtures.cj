package yjson_benchmarks

import yjson.*
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
public class ProfileRecord {
    @JsonName["profile_id"]
    public let id: Int64
    public var alias: String = ""
    public var level: Int32 = 0

    public init(id: Int64) { this.id = id }
}

@JsonCodec
public struct ProfileBundle {
    public var groups: HashMap<String, ArrayList<ProfileRecord>>
    @JsonIncludeNull
    public var featured: Option<ProfileRecord>

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
    if (!condition) { throw JsonException(message) }
}

public func findProfilesByGroup(
    nested: ArrayList<HashMap<String, ArrayList<ProfileRecord>>>,
    groupName: String
): ArrayList<ProfileRecord> {
    for (group in nested) {
        for ((key, profiles) in group) {
            if (key == groupName) { return profiles }
        }
    }
    throw JsonException("nested profile group `${groupName}` not found")
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

public func sampleProfileRecord(): ProfileRecord {
    makeProfileRecord(7, "ops", 3)
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
    for (index in 0..count) { values.add("metric_${index}", index * 17 + 3) }
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

public func sampleProfileBundleForBench(): ProfileBundle {
    let groups = HashMap<String, ArrayList<ProfileRecord>>()
    let opsProfiles = ArrayList<ProfileRecord>()
    opsProfiles.add(makeProfileRecord(7, "ops", 3))
    opsProfiles.add(makeProfileRecord(9, "infra", 4))
    groups.add("ops", opsProfiles)
    let platformProfiles = ArrayList<ProfileRecord>()
    platformProfiles.add(makeProfileRecord(11, "platform", 5))
    groups.add("platform", platformProfiles)
    ProfileBundle(groups, None)
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

public func nestedProfilesJson(): JsonCodec<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>> {
    JsonCodecs.arrayList(JsonCodecs.stringMap(JsonCodecs.arrayList(ProfileRecordJson)))
}

public func encodeToUtf8String<T>(
    codec: JsonCodec<T>,
    value: T,
    config!: JsonWriteOptions = JsonWriteOptions.compact
): String {
    let out = YJsonMemoryOutputStream()
    YJson.writeJson(value, out, codec: codec, options: config)
    out.toUtf8String()
}

public func htmlSafeCompactConfig(): JsonWriteOptions {
    JsonWriteOptions(indent: JsonWriteOptions.compact.indent, htmlSafe: true)
}
