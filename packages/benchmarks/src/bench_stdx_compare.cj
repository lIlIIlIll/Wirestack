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
import std.convert.Parsable
import std.io.*
import std.math.numeric.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json as stdxjson
import stdx.encoding.json.stream.*

class StdxAddress <: JsonSerializable & JsonDeserializable<StdxAddress> {
    public let street: String
    public let zipcode: Int64

    public init(street: String, zipcode: Int64) {
        this.street = street
        this.zipcode = zipcode
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("street_name")
        w.writeValue<String>(street)
        w.writeName("zipcode")
        w.writeValue<Int64>(zipcode)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxAddress {
        var street = ""
        var zipcode: Int64 = 0
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "street_name" => street = r.readValue<String>()
                case "zipcode" => zipcode = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxAddress(street, zipcode)
    }
}

class StdxPerson <: JsonSerializable & JsonDeserializable<StdxPerson> {
    public let id: Int64
    public let name: String
    public let age: Int32
    public let tags: ArrayList<String>
    public let scores: HashMap<String, Int64>
    public let address: StdxAddress
    public let nick: Option<String>

    public init(
        id: Int64,
        name: String,
        age: Int32,
        tags: ArrayList<String>,
        scores: HashMap<String, Int64>,
        address: StdxAddress,
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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("user_id")
        w.writeValue<Int64>(id)
        w.writeName("name")
        w.writeValue<String>(name)
        w.writeName("age")
        w.writeValue<Int32>(age)
        w.writeName("tags")
        w.writeValue<ArrayList<String>>(tags)
        w.writeName("scores")
        w.writeValue<HashMap<String, Int64>>(scores)
        w.writeName("address")
        w.writeValue<StdxAddress>(address)
        w.writeName("nick")
        w.writeValue<Option<String>>(nick)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxPerson {
        var id: Int64 = 0
        var name = ""
        var age: Int32 = 0
        var tags = ArrayList<String>()
        var scores = HashMap<String, Int64>()
        var address = StdxAddress("", 0)
        var nick: Option<String> = None
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "user_id" => id = r.readValue<Int64>()
                case "name" => name = r.readValue<String>()
                case "age" => age = r.readValue<Int32>()
                case "tags" => tags = r.readValue<ArrayList<String>>()
                case "scores" => scores = r.readValue<HashMap<String, Int64>>()
                case "address" => address = r.readValue<StdxAddress>()
                case "nick" => nick = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxPerson(id, name, age, tags, scores, address, nick)
    }
}

class StdxProfileRecord <: JsonSerializable & JsonDeserializable<StdxProfileRecord> {
    public let id: Int64
    public let alias: String
    public let level: Int32

    public init(id: Int64, alias: String, level: Int32) {
        this.id = id
        this.alias = alias
        this.level = level
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("profile_id")
        w.writeValue<Int64>(id)
        w.writeName("alias")
        w.writeValue<String>(alias)
        w.writeName("level")
        w.writeValue<Int32>(level)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxProfileRecord {
        var id: Int64 = 0
        var alias = ""
        var level: Int32 = 0
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "profile_id" => id = r.readValue<Int64>()
                case "alias" => alias = r.readValue<String>()
                case "level" => level = r.readValue<Int32>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxProfileRecord(id, alias, level)
    }
}

class StdxProfileBundle <: JsonSerializable & JsonDeserializable<StdxProfileBundle> {
    public let groups: HashMap<String, ArrayList<StdxProfileRecord>>
    public let featured: Option<StdxProfileRecord>

    public init(groups: HashMap<String, ArrayList<StdxProfileRecord>>, featured: Option<StdxProfileRecord>) {
        this.groups = groups
        this.featured = featured
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("groups")
        w.writeValue<HashMap<String, ArrayList<StdxProfileRecord>>>(groups)
        w.writeName("featured")
        w.writeValue<Option<StdxProfileRecord>>(featured)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxProfileBundle {
        var groups = HashMap<String, ArrayList<StdxProfileRecord>>()
        var featured: Option<StdxProfileRecord> = None
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "groups" => groups = r.readValue<HashMap<String, ArrayList<StdxProfileRecord>>>()
                case "featured" => featured = r.readValue<Option<StdxProfileRecord>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxProfileBundle(groups, featured)
    }
}

class StdxUInt64Envelope <: JsonSerializable & JsonDeserializable<StdxUInt64Envelope> {
    public let id: UInt64
    public let shardIds: Array<UInt64>
    public let quotas: HashMap<String, UInt64>

    public init(id: UInt64, shardIds: Array<UInt64>, quotas: HashMap<String, UInt64>) {
        this.id = id
        this.shardIds = shardIds
        this.quotas = quotas
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id")
        w.writeValue<UInt64>(id)
        w.writeName("shardIds")
        w.writeValue<Array<UInt64>>(shardIds)
        w.writeName("quotas")
        w.writeValue<HashMap<String, UInt64>>(quotas)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxUInt64Envelope {
        var id: UInt64 = 0
        var shardIds = Array<UInt64>(0, repeat: 0)
        var quotas = HashMap<String, UInt64>()
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "id" => id = r.readValue<UInt64>()
                case "shardIds" => shardIds = r.readValue<Array<UInt64>>()
                case "quotas" => quotas = r.readValue<HashMap<String, UInt64>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxUInt64Envelope(id, shardIds, quotas)
    }
}

class StdxTemporalStats <: JsonSerializable & JsonDeserializable<StdxTemporalStats> {
    public let createdAt: DateTime
    public let totalEvents: BigInt
    public let averageLatency: Decimal
    public let checkpoints: ArrayList<DateTime>
    public let ratios: HashMap<String, Decimal>

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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("createdAt")
        w.writeValue<DateTime>(createdAt)
        w.writeName("totalEvents")
        w.writeValue<BigInt>(totalEvents)
        w.writeName("averageLatency")
        w.writeValue<Decimal>(averageLatency)
        w.writeName("checkpoints")
        w.writeValue<ArrayList<DateTime>>(checkpoints)
        w.writeName("ratios")
        w.writeValue<HashMap<String, Decimal>>(ratios)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): StdxTemporalStats {
        var createdAt = sampleDateTime()
        var totalEvents = BigInt.parse("0")
        var averageLatency = Decimal.parse("0")
        var checkpoints = ArrayList<DateTime>()
        var ratios = HashMap<String, Decimal>()
        r.startObject()
        while (r.peek() != Some(EndObject)) {
            match (r.readName()) {
                case "createdAt" => createdAt = r.readValue<DateTime>()
                case "totalEvents" => totalEvents = r.readValue<BigInt>()
                case "averageLatency" => averageLatency = r.readValue<Decimal>()
                case "checkpoints" => checkpoints = r.readValue<ArrayList<DateTime>>()
                case "ratios" => ratios = r.readValue<HashMap<String, Decimal>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        StdxTemporalStats(createdAt, totalEvents, averageLatency, checkpoints, ratios)
    }
}

func cloneStringList(value: ArrayList<String>): ArrayList<String> {
    let result = ArrayList<String>(value.size)
    for (item in value) {
        result.add(item)
    }
    result
}

func cloneInt64Map(value: HashMap<String, Int64>): HashMap<String, Int64> {
    let result = HashMap<String, Int64>(value.size)
    for ((key, item) in value) {
        result.add(key, item)
    }
    result
}

func cloneUInt64Map(value: HashMap<String, UInt64>): HashMap<String, UInt64> {
    let result = HashMap<String, UInt64>(value.size)
    for ((key, item) in value) {
        result.add(key, item)
    }
    result
}

func cloneDecimalMap(value: HashMap<String, Decimal>): HashMap<String, Decimal> {
    let result = HashMap<String, Decimal>(value.size)
    for ((key, item) in value) {
        result.add(key, item)
    }
    result
}

func cloneDateTimeList(value: ArrayList<DateTime>): ArrayList<DateTime> {
    let result = ArrayList<DateTime>(value.size)
    for (item in value) {
        result.add(item)
    }
    result
}

func toStdxAddress(source: Address): StdxAddress {
    StdxAddress(source.street, source.zipcode)
}

func toStdxPerson(source: Person): StdxPerson {
    StdxPerson(
        source.id,
        source.name,
        source.age,
        cloneStringList(source.tags),
        cloneInt64Map(source.scores),
        toStdxAddress(source.address),
        match (source.nick) {
            case Some(value) => Some(value)
            case None => None<String>
        }
    )
}

func toStdxProfileRecord(source: ProfileRecord): StdxProfileRecord {
    StdxProfileRecord(source.id, source.alias, source.level)
}

func toStdxProfileBundle(source: ProfileBundle): StdxProfileBundle {
    let groups = HashMap<String, ArrayList<StdxProfileRecord>>(source.groups.size)
    for ((key, profiles) in source.groups) {
        let convertedProfiles = ArrayList<StdxProfileRecord>(profiles.size)
        for (profile in profiles) {
            convertedProfiles.add(toStdxProfileRecord(profile))
        }
        groups.add(key, convertedProfiles)
    }
    let featured = match (source.featured) {
        case Some(value) => Some(toStdxProfileRecord(value))
        case None => None<StdxProfileRecord>
    }
    StdxProfileBundle(groups, featured)
}

func toStdxUInt64Envelope(source: UInt64Envelope): StdxUInt64Envelope {
    StdxUInt64Envelope(
        source.id,
        Array<UInt64>(source.shardIds.size, {
            index => source.shardIds[index]
        }),
        cloneUInt64Map(source.quotas)
    )
}

func toStdxTemporalStats(source: TemporalStats): StdxTemporalStats {
    StdxTemporalStats(
        source.createdAt,
        source.totalEvents,
        source.averageLatency,
        cloneDateTimeList(source.checkpoints),
        cloneDecimalMap(source.ratios)
    )
}

func encodeStdxToUtf8String<T>(
    value: T,
    config!: WriteConfig = WriteConfig.compact
): String where T <: JsonSerializable {
    let out = YJsonMemoryOutputStream()
    let writer = JsonWriter(out)
    writer.writeConfig = config
    writer.writeValue<T>(value)
    writer.flush()
    return out.toUtf8String()
}

func decodeStdxFromUtf8String<T>(text: String): T where T <: JsonDeserializable<T> {
    return decodeStdxFromStream<T>(YJsonByteArrayInputStream(text))
}

func encodeStdxToStream<T>(
    value: T,
    out: OutputStream,
    config!: WriteConfig = WriteConfig.compact
): Unit where T <: JsonSerializable {
    let writer = JsonWriter(out)
    writer.writeConfig = config
    writer.writeValue<T>(value)
    writer.flush()
}

func decodeStdxFromStream<T>(input: InputStream): T where T <: JsonDeserializable<T> {
    let reader = JsonReader(input)
    return reader.readValue<T>()
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class StdxCompareBenchmarks {
    let address = samplePerson().address
    let person = samplePerson()
    let bundle = sampleProfileBundleForBench()
    let uint64Envelope = sampleUInt64Envelope()
    let temporalStats = sampleTemporalStats()
    let stdxAddress: StdxAddress
    let stdxPerson: StdxPerson
    let stdxBundle: StdxProfileBundle
    let stdxUInt64Envelope: StdxUInt64Envelope
    let stdxTemporalStats: StdxTemporalStats
    let canonicalPersonText: String
    let canonicalAddressText: String
    let canonicalBundleText: String
    let canonicalUInt64EnvelopeText: String
    let canonicalTemporalStatsText: String
    let yjsonPersonAst: JsonNode
    let stdxPersonAst: stdxjson.JsonValue
    var stringSink = ""
    var intSink: Int64 = 0
    var yjsonAstSink: JsonNode = JsonNullValue()
    var stdxAstSink: stdxjson.JsonValue = stdxjson.JsonNull()

    init() {
        stdxAddress = toStdxAddress(address)
        stdxPerson = toStdxPerson(person)
        stdxBundle = toStdxProfileBundle(bundle)
        stdxUInt64Envelope = toStdxUInt64Envelope(uint64Envelope)
        stdxTemporalStats = toStdxTemporalStats(temporalStats)
        canonicalPersonText = YJson.encodeStringWith(PersonJson, person)
        canonicalAddressText = YJson.encodeStringWith(AddressJson, address)
        canonicalBundleText = YJson.encodeStringWith(ProfileBundleJson, bundle)
        canonicalUInt64EnvelopeText = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
        canonicalTemporalStatsText = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
        yjsonPersonAst = YJson.parse(canonicalPersonText)
        stdxPersonAst = stdxjson.JsonValue.fromStr(canonicalPersonText)

        assertJson(
            decodeStdxFromUtf8String<StdxAddress>(canonicalAddressText).zipcode == address.zipcode,
            "stdx address decode should match canonical yjson text"
        )
        assertJson(
            YJson.decodeStringWith(AddressJson, encodeStdxToUtf8String<StdxAddress>(stdxAddress)).street == address.street,
            "stdx address encode should preserve canonical wire shape"
        )
        assertJson(
            decodeStdxFromUtf8String<StdxPerson>(canonicalPersonText).id == person.id,
            "stdx person decode should match canonical yjson text"
        )
        assertJson(
            YJson.decodeStringWith(PersonJson, encodeStdxToUtf8String<StdxPerson>(stdxPerson)).scores["math"] == 95,
            "stdx person encode should preserve nested map semantics"
        )
        assertJson(
            decodeStdxFromUtf8String<StdxProfileBundle>(canonicalBundleText).groups["platform"][0].id == 11,
            "stdx profile bundle decode should match canonical yjson text"
        )
        assertJson(
            YJson.decodeStringWith(ProfileBundleJson, encodeStdxToUtf8String<StdxProfileBundle>(stdxBundle)).groups["ops"][1].level == 4,
            "stdx profile bundle encode should preserve nested object semantics"
        )
        assertJson(
            decodeStdxFromUtf8String<StdxUInt64Envelope>(canonicalUInt64EnvelopeText).id == uint64Envelope.id,
            "stdx UInt64 envelope decode should match canonical yjson text"
        )
        assertJson(
            YJson.decodeStringWith(UInt64EnvelopeJson, encodeStdxToUtf8String<StdxUInt64Envelope>(stdxUInt64Envelope)).quotas["burst"] ==
            UInt64.parse("18446744073709551613"),
            "stdx UInt64 envelope encode should preserve bare-number UInt64 values"
        )
        assertJson(
            decodeStdxFromUtf8String<StdxTemporalStats>(canonicalTemporalStatsText).totalEvents == temporalStats.totalEvents,
            "stdx temporal stats decode should match canonical yjson text"
        )
        assertJson(
            YJson.decodeStringWith(TemporalStatsJson, encodeStdxToUtf8String<StdxTemporalStats>(stdxTemporalStats)).averageLatency ==
            temporalStats.averageLatency,
            "stdx temporal stats encode should preserve BigInt/Decimal/DateTime semantics"
        )
    }

    @Bench
    func parseAstYjsonPerson(): Unit {
        yjsonAstSink = YJson.parse(canonicalPersonText)
    }

    @Bench
    func parseAstStdxPerson(): Unit {
        stdxAstSink = stdxjson.JsonValue.fromStr(canonicalPersonText)
    }

    @Bench
    func stringifyAstYjsonPerson(): Unit {
        stringSink = YJson.stringify(yjsonPersonAst)
    }

    @Bench
    func stringifyAstStdxPerson(): Unit {
        stringSink = stdxPersonAst.toJsonString()
    }

    @Bench
    func decodeStreamYjsonPerson(): Unit {
        intSink = YJson.decodeFromStreamWith(PersonJson, YJsonByteArrayInputStream(canonicalPersonText)).id
    }

    @Bench
    func decodeStreamStdxPerson(): Unit {
        intSink = decodeStdxFromStream<StdxPerson>(YJsonByteArrayInputStream(canonicalPersonText)).id
    }

    @Bench
    func encodeStreamYjsonPerson(): Unit {
        let out = YJsonMemoryOutputStream()
        YJson.encodeToStreamWith(PersonJson, person, out)
        stringSink = out.toUtf8String()
    }

    @Bench
    func encodeStreamStdxPerson(): Unit {
        let out = YJsonMemoryOutputStream()
        encodeStdxToStream<StdxPerson>(stdxPerson, out)
        stringSink = out.toUtf8String()
    }

    @Bench
    func encodeObjectYjsonAddress(): Unit {
        stringSink = YJson.encodeStringWith(AddressJson, address)
    }

    @Bench
    func encodeObjectStdxAddress(): Unit {
        stringSink = encodeStdxToUtf8String<StdxAddress>(stdxAddress)
    }

    @Bench
    func decodeObjectYjsonAddress(): Unit {
        intSink = YJson.decodeStringWith(AddressJson, canonicalAddressText).zipcode
    }

    @Bench
    func decodeObjectStdxAddress(): Unit {
        intSink = decodeStdxFromUtf8String<StdxAddress>(canonicalAddressText).zipcode
    }

    @Bench
    func encodeObjectYjsonPerson(): Unit {
        stringSink = YJson.encodeStringWith(PersonJson, person)
    }

    @Bench
    func encodeObjectStdxPerson(): Unit {
        stringSink = encodeStdxToUtf8String<StdxPerson>(stdxPerson)
    }

    @Bench
    func decodeObjectYjsonPerson(): Unit {
        intSink = YJson.decodeStringWith(PersonJson, canonicalPersonText).id
    }

    @Bench
    func decodeObjectStdxPerson(): Unit {
        intSink = decodeStdxFromUtf8String<StdxPerson>(canonicalPersonText).id
    }

    @Bench
    func encodeObjectYjsonProfileBundle(): Unit {
        stringSink = YJson.encodeStringWith(ProfileBundleJson, bundle)
    }

    @Bench
    func encodeObjectStdxProfileBundle(): Unit {
        stringSink = encodeStdxToUtf8String<StdxProfileBundle>(stdxBundle)
    }

    @Bench
    func decodeObjectYjsonProfileBundle(): Unit {
        intSink = YJson.decodeStringWith(ProfileBundleJson, canonicalBundleText).groups["platform"][0].id
    }

    @Bench
    func decodeObjectStdxProfileBundle(): Unit {
        intSink = decodeStdxFromUtf8String<StdxProfileBundle>(canonicalBundleText).groups["platform"][0].id
    }

    @Bench
    func encodeObjectYjsonUInt64Envelope(): Unit {
        stringSink = YJson.encodeStringWith(UInt64EnvelopeJson, uint64Envelope)
    }

    @Bench
    func encodeObjectStdxUInt64Envelope(): Unit {
        stringSink = encodeStdxToUtf8String<StdxUInt64Envelope>(stdxUInt64Envelope)
    }

    @Bench
    func decodeObjectYjsonUInt64Envelope(): Unit {
        intSink = Int64(YJson.decodeStringWith(UInt64EnvelopeJson, canonicalUInt64EnvelopeText).shardIds.size)
    }

    @Bench
    func decodeObjectStdxUInt64Envelope(): Unit {
        intSink = Int64(decodeStdxFromUtf8String<StdxUInt64Envelope>(canonicalUInt64EnvelopeText).shardIds.size)
    }

    @Bench
    func encodeObjectYjsonTemporalStats(): Unit {
        stringSink = YJson.encodeStringWith(TemporalStatsJson, temporalStats)
    }

    @Bench
    func encodeObjectStdxTemporalStats(): Unit {
        stringSink = encodeStdxToUtf8String<StdxTemporalStats>(stdxTemporalStats)
    }

    @Bench
    func decodeObjectYjsonTemporalStats(): Unit {
        stringSink = YJson.decodeStringWith(TemporalStatsJson, canonicalTemporalStatsText).totalEvents.toString()
    }

    @Bench
    func decodeObjectStdxTemporalStats(): Unit {
        stringSink = decodeStdxFromUtf8String<StdxTemporalStats>(canonicalTemporalStatsText).totalEvents.toString()
    }
}
