package yjson_codec_integration

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@JsonCodec
class ExternalCollectionEnvelope {
    public let arrayLists: Array<ArrayList<Int64>>
    public let listMaps: ArrayList<HashMap<String, Int64>>
    public let mapArrays: HashMap<String, Array<Int64>>

    public init(
        arrayLists: Array<ArrayList<Int64>>,
        listMaps: ArrayList<HashMap<String, Int64>>,
        mapArrays: HashMap<String, Array<Int64>>
    ) {
        this.arrayLists = arrayLists
        this.listMaps = listMaps
        this.mapArrays = mapArrays
    }
}

@JsonCodec
class ExternalStringArrayEnvelope {
    public let labels: Array<String>

    public init(labels: Array<String>) {
        this.labels = labels
    }
}

@JsonCodec
class ExternalFastReadEnvelope {
    public let tags: ArrayList<String>
    public let metrics: HashMap<String, Int64>
    public let nickname: Option<String>

    public init(
        tags: ArrayList<String>,
        metrics: HashMap<String, Int64>,
        nickname: Option<String>
    ) {
        this.tags = tags
        this.metrics = metrics
        this.nickname = nickname
    }
}

@JsonCodec
class ExternalNonCompactInner {
    @JsonUsing[JsonCodecs.array(JsonCodecs.int64)]
    public let numbers: Array<Int64>

    public init(numbers: Array<Int64>) {
        this.numbers = numbers
    }
}

@JsonCodec
class ExternalNestedFallbackEnvelope {
    public let items: Array<ExternalNonCompactInner>

    public init(items: Array<ExternalNonCompactInner>) {
        this.items = items
    }
}

@JsonCodec
class ExternalRemainingNestingEnvelope {
    public let arrayArrays: Array<Array<Int64>>
    public let arrayMaps: Array<HashMap<String, Int64>>
    public let listArrays: ArrayList<Array<Int64>>
    public let listLists: ArrayList<ArrayList<Int64>>
    public let mapLists: HashMap<String, ArrayList<Int64>>
    public let mapMaps: HashMap<String, HashMap<String, Int64>>

    public init(
        arrayArrays: Array<Array<Int64>>,
        arrayMaps: Array<HashMap<String, Int64>>,
        listArrays: ArrayList<Array<Int64>>,
        listLists: ArrayList<ArrayList<Int64>>,
        mapLists: HashMap<String, ArrayList<Int64>>,
        mapMaps: HashMap<String, HashMap<String, Int64>>
    ) {
        this.arrayArrays = arrayArrays
        this.arrayMaps = arrayMaps
        this.listArrays = listArrays
        this.listLists = listLists
        this.mapLists = mapLists
        this.mapMaps = mapMaps
    }
}

@JsonCodec
class ExternalOptionalUserEnvelope {
    public let member: Option<ExternalUser>

    public init(member: Option<ExternalUser>) {
        this.member = member
    }
}

@JsonCodec
class ExternalFieldBranchEnvelope {
    public let tags: ArrayList<String>
    public let metrics: HashMap<String, Int64>
    @JsonIncludeNull
    public let nickname: Option<String>
    public let members: Array<ExternalUser>
    public let maybeMember: Option<ExternalUser>
    @JsonUsing[JsonCodecs.array(JsonCodecs.int64)]
    public let customNumbers: Array<Int64>

    public init(
        tags: ArrayList<String>,
        metrics: HashMap<String, Int64>,
        nickname: Option<String>,
        members: Array<ExternalUser>,
        maybeMember: Option<ExternalUser>,
        customNumbers: Array<Int64>
    ) {
        this.tags = tags
        this.metrics = metrics
        this.nickname = nickname
        this.members = members
        this.maybeMember = maybeMember
        this.customNumbers = customNumbers
    }
}

private func externalNonEmptyEnvelope(): ExternalCollectionEnvelope {
    let numbers = ArrayList<Int64>([1, 2])
    let metrics = HashMap<String, Int64>()
    metrics.add("count", 3)
    let arrays = HashMap<String, Array<Int64>>()
    arrays.add("team", [4, 5])
    ExternalCollectionEnvelope(
        [numbers],
        ArrayList<HashMap<String, Int64>>([metrics]),
        arrays
    )
}

private func externalEmptyEnvelope(): ExternalCollectionEnvelope {
    ExternalCollectionEnvelope(
        Array<ArrayList<Int64>>(0, repeat: ArrayList<Int64>()),
        ArrayList<HashMap<String, Int64>>(),
        HashMap<String, Array<Int64>>()
    )
}

@Test
class GeneratedCollectionConsumerTest {
    @TestCase
    func nonEmptyHashMapOfArraysUsesTypedTopLevelCodec(): Unit {
        let value = HashMap<String, Array<Int64>>()
        value.add("team", [1, 2])

        let compact = YJson.toJson(value)
        @Assert(compact, "{\"team\":[1,2]}")

        let decoded = YJson.fromJson<HashMap<String, Array<Int64>>>(compact)
        @Assert(decoded.size, 1)
        @Assert(decoded["team"].size, 2)
        @Expect(decoded["team"][0], 1)
        @Expect(decoded["team"][1], 2)
    }

    @TestCase
    func stringArrayFieldUsesDefaultCompactWriterAndRoundTrips(): Unit {
        let value = ExternalStringArrayEnvelope(["alpha", "仓颉", "quote\""])
        let compact = YJson.toJson(value)
        @Assert(compact, "{\"labels\":[\"alpha\",\"仓颉\",\"quote\\\"\"]}")
        let decoded = YJson.fromJson<ExternalStringArrayEnvelope>(compact)
        @Assert(decoded.labels.size, 3)
        @Expect(decoded.labels[0], "alpha")
        @Expect(decoded.labels[1], "仓颉")
        @Expect(decoded.labels[2], "quote\"")

        let empty = YJson.toJson(ExternalStringArrayEnvelope([]))
        @Expect(empty, "{\"labels\":[]}")
        @Expect(YJson.fromJson<ExternalStringArrayEnvelope>(empty).labels.size, 0)
        let emptyPretty = YJson.toJson(
            ExternalStringArrayEnvelope([]), options: JsonWriteOptions.pretty())
        @Expect(emptyPretty.contains("\n  \"labels\""))
        @Expect(YJson.fromJson<ExternalStringArrayEnvelope>(emptyPretty).labels.size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"labels\""))
        let prettyDecoded = YJson.fromJson<ExternalStringArrayEnvelope>(pretty)
        @Expect(prettyDecoded.labels.size, 3)
        @Expect(prettyDecoded.labels[1], "仓颉")
        @Expect(prettyDecoded.labels[2], "quote\"")
    }

    @TestCase
    func nestedCompactCapabilityFalseFallsBackWithoutInvalidRawWrite(): Unit {
        let value = ExternalNestedFallbackEnvelope([
            ExternalNonCompactInner([1, 2]),
            ExternalNonCompactInner([])
        ])

        let compact = YJson.toJson(value)
        @Assert(compact, "{\"items\":[{\"numbers\":[1,2]},{\"numbers\":[]}]}")
        let compactDecoded = YJson.fromJson<ExternalNestedFallbackEnvelope>(compact)
        @Expect(compactDecoded.items.size, 2)
        @Expect(compactDecoded.items[0].numbers[1], 2)
        @Expect(compactDecoded.items[1].numbers.size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"items\""))
        let prettyDecoded = YJson.fromJson<ExternalNestedFallbackEnvelope>(pretty)
        @Expect(prettyDecoded.items[0].numbers[0], 1)
        @Expect(prettyDecoded.items[1].numbers.size, 0)
    }

    @TestCase
    func directCollectionFieldsUseFastReadForEmptyAndNonEmptyValues(): Unit {
        let metrics = HashMap<String, Int64>()
        metrics.add("count", 3)
        let nonEmptyText = "{\"tags\":[\"alpha\",\"仓颉\"],\"metrics\":{\"count\":3},\"nickname\":\"neo\"}"
        let nonEmpty = YJson.fromJson<ExternalFastReadEnvelope>(nonEmptyText)
        @Expect(nonEmpty.tags[1], "仓颉")
        @Expect(nonEmpty.metrics["count"], 3)
        @Expect(nonEmpty.nickname.getOrThrow(), "neo")
        @Expect(YJson.toJson(nonEmpty), nonEmptyText)

        let empty = YJson.fromJson<ExternalFastReadEnvelope>(
            "{\"tags\":[],\"metrics\":{}}")
        @Expect(empty.tags.size, 0)
        @Expect(empty.metrics.size, 0)
        @Expect(empty.nickname.isNone())
        @Expect(YJson.toJson(empty), "{\"tags\":[],\"metrics\":{}}")
    }

    @TestCase
    func remainingTopLevelNestingPairsCoverCompactPrettyAndRoundTrip(): Unit {
        let oneMap = HashMap<String, Int64>()
        oneMap.add("count", 3)
        let oneList = ArrayList<Int64>([1, 2])
        let nestedMap = HashMap<String, Int64>()
        nestedMap.add("count", 3)

        let arrayArrays: Array<Array<Int64>> = [[1, 2]]
        let arrayMaps: Array<HashMap<String, Int64>> = [oneMap]
        let listArrays = ArrayList<Array<Int64>>([[1, 2]])
        let listLists = ArrayList<ArrayList<Int64>>([oneList])
        let mapLists = HashMap<String, ArrayList<Int64>>()
        mapLists.add("team", oneList)
        let mapMaps = HashMap<String, HashMap<String, Int64>>()
        mapMaps.add("team", nestedMap)

        @Expect(YJson.toJson(arrayArrays), "[[1,2]]")
        @Expect(YJson.toJson(arrayMaps), "[{\"count\":3}]")
        @Expect(YJson.toJson(listArrays), "[[1,2]]")
        @Expect(YJson.toJson(listLists), "[[1,2]]")
        @Expect(YJson.toJson(mapLists), "{\"team\":[1,2]}")
        @Expect(YJson.toJson(mapMaps), "{\"team\":{\"count\":3}}")

        @Expect(YJson.fromJson<Array<Array<Int64>>>(YJson.toJson(
            arrayArrays, options: JsonWriteOptions.pretty()))[0][1], 2)
        @Expect(YJson.fromJson<Array<HashMap<String, Int64>>>(YJson.toJson(
            arrayMaps, options: JsonWriteOptions.pretty()))[0]["count"], 3)
        @Expect(YJson.fromJson<ArrayList<Array<Int64>>>(YJson.toJson(
            listArrays, options: JsonWriteOptions.pretty()))[0][1], 2)
        @Expect(YJson.fromJson<ArrayList<ArrayList<Int64>>>(YJson.toJson(
            listLists, options: JsonWriteOptions.pretty()))[0][1], 2)
        @Expect(YJson.fromJson<HashMap<String, ArrayList<Int64>>>(YJson.toJson(
            mapLists, options: JsonWriteOptions.pretty()))["team"][1], 2)
        @Expect(YJson.fromJson<HashMap<String, HashMap<String, Int64>>>(YJson.toJson(
            mapMaps, options: JsonWriteOptions.pretty()))["team"]["count"], 3)

        let emptyArrayArrays = Array<Array<Int64>>(0, repeat: Array<Int64>())
        let emptyArrayMaps = Array<HashMap<String, Int64>>(
            0, repeat: HashMap<String, Int64>())
        let emptyListArrays = ArrayList<Array<Int64>>()
        let emptyListLists = ArrayList<ArrayList<Int64>>()
        let emptyMapLists = HashMap<String, ArrayList<Int64>>()
        let emptyMapMaps = HashMap<String, HashMap<String, Int64>>()
        @Expect(YJson.toJson(emptyArrayArrays), "[]")
        @Expect(YJson.toJson(emptyArrayMaps), "[]")
        @Expect(YJson.toJson(emptyListArrays), "[]")
        @Expect(YJson.toJson(emptyListLists), "[]")
        @Expect(YJson.toJson(emptyMapLists), "{}")
        @Expect(YJson.toJson(emptyMapMaps), "{}")
        @Expect(YJson.fromJson<Array<Array<Int64>>>(YJson.toJson(
            emptyArrayArrays, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<Array<HashMap<String, Int64>>>(YJson.toJson(
            emptyArrayMaps, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<ArrayList<Array<Int64>>>(YJson.toJson(
            emptyListArrays, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<ArrayList<ArrayList<Int64>>>(YJson.toJson(
            emptyListLists, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<HashMap<String, ArrayList<Int64>>>(YJson.toJson(
            emptyMapLists, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<HashMap<String, HashMap<String, Int64>>>(YJson.toJson(
            emptyMapMaps, options: JsonWriteOptions.pretty())).size, 0)
    }

    @TestCase
    func allTopLevelNestingPairsCoverNonEmptyOuterWithEmptyInner(): Unit {
        let arrayArrays: Array<Array<Int64>> = [Array<Int64>()]
        let arrayLists: Array<ArrayList<Int64>> = [ArrayList<Int64>()]
        let arrayMaps: Array<HashMap<String, Int64>> = [HashMap<String, Int64>()]
        let listArrays = ArrayList<Array<Int64>>([Array<Int64>()])
        let listLists = ArrayList<ArrayList<Int64>>([ArrayList<Int64>()])
        let listMaps = ArrayList<HashMap<String, Int64>>([HashMap<String, Int64>()])
        let mapArrays = HashMap<String, Array<Int64>>()
        mapArrays.add("empty", Array<Int64>())
        let mapLists = HashMap<String, ArrayList<Int64>>()
        mapLists.add("empty", ArrayList<Int64>())
        let mapMaps = HashMap<String, HashMap<String, Int64>>()
        mapMaps.add("empty", HashMap<String, Int64>())

        @Expect(YJson.toJson(arrayArrays), "[[]]")
        @Expect(YJson.toJson(arrayLists), "[[]]")
        @Expect(YJson.toJson(arrayMaps), "[{}]")
        @Expect(YJson.toJson(listArrays), "[[]]")
        @Expect(YJson.toJson(listLists), "[[]]")
        @Expect(YJson.toJson(listMaps), "[{}]")
        @Expect(YJson.toJson(mapArrays), "{\"empty\":[]}")
        @Expect(YJson.toJson(mapLists), "{\"empty\":[]}")
        @Expect(YJson.toJson(mapMaps), "{\"empty\":{}}")

        @Expect(YJson.fromJson<Array<Array<Int64>>>(YJson.toJson(
            arrayArrays, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<Array<ArrayList<Int64>>>(YJson.toJson(
            arrayLists, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<Array<HashMap<String, Int64>>>(YJson.toJson(
            arrayMaps, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<ArrayList<Array<Int64>>>(YJson.toJson(
            listArrays, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<ArrayList<ArrayList<Int64>>>(YJson.toJson(
            listLists, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<ArrayList<HashMap<String, Int64>>>(YJson.toJson(
            listMaps, options: JsonWriteOptions.pretty()))[0].size, 0)
        @Expect(YJson.fromJson<HashMap<String, Array<Int64>>>(YJson.toJson(
            mapArrays, options: JsonWriteOptions.pretty()))["empty"].size, 0)
        @Expect(YJson.fromJson<HashMap<String, ArrayList<Int64>>>(YJson.toJson(
            mapLists, options: JsonWriteOptions.pretty()))["empty"].size, 0)
        @Expect(YJson.fromJson<HashMap<String, HashMap<String, Int64>>>(YJson.toJson(
            mapMaps, options: JsonWriteOptions.pretty()))["empty"].size, 0)
    }

    @TestCase
    func remainingGeneratedNestingFieldsCoverEmptyInnerAndOuterValues(): Unit {
        let emptyMap = HashMap<String, Int64>()
        let emptyList = ArrayList<Int64>()
        let mapLists = HashMap<String, ArrayList<Int64>>()
        mapLists.add("empty", emptyList)
        let mapMaps = HashMap<String, HashMap<String, Int64>>()
        mapMaps.add("empty", emptyMap)
        let value = ExternalRemainingNestingEnvelope(
            [Array<Int64>()],
            [emptyMap],
            ArrayList<Array<Int64>>([Array<Int64>()]),
            ArrayList<ArrayList<Int64>>([emptyList]),
            mapLists,
            mapMaps
        )

        let compact = YJson.toJson(value)
        @Assert(compact,
            "{\"arrayArrays\":[[]],\"arrayMaps\":[{}],\"listArrays\":[[]]," +
            "\"listLists\":[[]],\"mapLists\":{\"empty\":[]},\"mapMaps\":{\"empty\":{}}}")
        let decoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(compact)
        @Expect(decoded.arrayArrays[0].size, 0)
        @Expect(decoded.arrayMaps[0].size, 0)
        @Expect(decoded.listArrays[0].size, 0)
        @Expect(decoded.listLists[0].size, 0)
        @Expect(decoded.mapLists["empty"].size, 0)
        @Expect(decoded.mapMaps["empty"].size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        let prettyDecoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(pretty)
        @Expect(prettyDecoded.arrayArrays[0].size, 0)
        @Expect(prettyDecoded.arrayMaps[0].size, 0)
        @Expect(prettyDecoded.listArrays[0].size, 0)
        @Expect(prettyDecoded.listLists[0].size, 0)
        @Expect(prettyDecoded.mapLists["empty"].size, 0)
        @Expect(prettyDecoded.mapMaps["empty"].size, 0)

        let empty = ExternalRemainingNestingEnvelope(
            Array<Array<Int64>>(0, repeat: Array<Int64>()),
            Array<HashMap<String, Int64>>(0, repeat: HashMap<String, Int64>()),
            ArrayList<Array<Int64>>(),
            ArrayList<ArrayList<Int64>>(),
            HashMap<String, ArrayList<Int64>>(),
            HashMap<String, HashMap<String, Int64>>()
        )
        let emptyCompact = YJson.toJson(empty)
        @Assert(emptyCompact,
            "{\"arrayArrays\":[],\"arrayMaps\":[],\"listArrays\":[]," +
            "\"listLists\":[],\"mapLists\":{},\"mapMaps\":{}}")
        let emptyPretty = YJson.toJson(empty, options: JsonWriteOptions.pretty())
        let emptyCompactDecoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(emptyCompact)
        @Expect(emptyCompactDecoded.arrayArrays.size, 0)
        @Expect(emptyCompactDecoded.arrayMaps.size, 0)
        @Expect(emptyCompactDecoded.listArrays.size, 0)
        @Expect(emptyCompactDecoded.listLists.size, 0)
        @Expect(emptyCompactDecoded.mapLists.size, 0)
        @Expect(emptyCompactDecoded.mapMaps.size, 0)
        let emptyPrettyDecoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(emptyPretty)
        @Expect(emptyPrettyDecoded.arrayArrays.size, 0)
        @Expect(emptyPrettyDecoded.arrayMaps.size, 0)
        @Expect(emptyPrettyDecoded.listArrays.size, 0)
        @Expect(emptyPrettyDecoded.listLists.size, 0)
        @Expect(emptyPrettyDecoded.mapLists.size, 0)
        @Expect(emptyPrettyDecoded.mapMaps.size, 0)

        let fullMap = HashMap<String, Int64>()
        fullMap.add("count", 3)
        let fullList = ArrayList<Int64>([1, 2])
        let fullMapLists = HashMap<String, ArrayList<Int64>>()
        fullMapLists.add("team", fullList)
        let fullMapMaps = HashMap<String, HashMap<String, Int64>>()
        fullMapMaps.add("team", fullMap)
        let full = ExternalRemainingNestingEnvelope(
            [[1, 2]],
            [fullMap],
            ArrayList<Array<Int64>>([[1, 2]]),
            ArrayList<ArrayList<Int64>>([fullList]),
            fullMapLists,
            fullMapMaps
        )
        let fullCompact = YJson.toJson(full)
        @Assert(fullCompact,
            "{\"arrayArrays\":[[1,2]],\"arrayMaps\":[{\"count\":3}]," +
            "\"listArrays\":[[1,2]],\"listLists\":[[1,2]]," +
            "\"mapLists\":{\"team\":[1,2]},\"mapMaps\":{\"team\":{\"count\":3}}}")
        let fullDecoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(fullCompact)
        @Expect(fullDecoded.arrayArrays[0][1], 2)
        @Expect(fullDecoded.arrayMaps[0]["count"], 3)
        @Expect(fullDecoded.listArrays[0][1], 2)
        @Expect(fullDecoded.listLists[0][1], 2)
        @Expect(fullDecoded.mapLists["team"][1], 2)
        @Expect(fullDecoded.mapMaps["team"]["count"], 3)
        let fullPretty = YJson.toJson(full, options: JsonWriteOptions.pretty())
        let fullPrettyDecoded = YJson.fromJson<ExternalRemainingNestingEnvelope>(fullPretty)
        @Expect(fullPrettyDecoded.arrayArrays[0][1], 2)
        @Expect(fullPrettyDecoded.arrayMaps[0]["count"], 3)
        @Expect(fullPrettyDecoded.listArrays[0][1], 2)
        @Expect(fullPrettyDecoded.listLists[0][1], 2)
        @Expect(fullPrettyDecoded.mapLists["team"][0], 1)
        @Expect(fullPrettyDecoded.mapMaps["team"]["count"], 3)
    }

    @TestCase
    func originalGeneratedNestingFieldsCoverNonEmptyOuterWithEmptyInner(): Unit {
        let arrayLists: Array<ArrayList<Int64>> = [ArrayList<Int64>()]
        let listMaps = ArrayList<HashMap<String, Int64>>([HashMap<String, Int64>()])
        let mapArrays = HashMap<String, Array<Int64>>()
        mapArrays.add("empty", Array<Int64>())
        let value = ExternalCollectionEnvelope(arrayLists, listMaps, mapArrays)

        let compact = YJson.toJson(value)
        @Assert(compact,
            "{\"arrayLists\":[[]],\"listMaps\":[{}],\"mapArrays\":{\"empty\":[]}}")
        let compactDecoded = YJson.fromJson<ExternalCollectionEnvelope>(compact)
        @Expect(compactDecoded.arrayLists[0].size, 0)
        @Expect(compactDecoded.listMaps[0].size, 0)
        @Expect(compactDecoded.mapArrays["empty"].size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        let prettyDecoded = YJson.fromJson<ExternalCollectionEnvelope>(pretty)
        @Expect(prettyDecoded.arrayLists[0].size, 0)
        @Expect(prettyDecoded.listMaps[0].size, 0)
        @Expect(prettyDecoded.mapArrays["empty"].size, 0)
    }

    @TestCase
    func specialDirectAndCustomFieldsRoundTripNonEmptyCompactAndPretty(): Unit {
        let metrics = HashMap<String, Int64>()
        metrics.add("count", 3)
        let value = ExternalFieldBranchEnvelope(
            ArrayList<String>(["alpha", "仓颉"]),
            metrics,
            Some("neo"),
            [ExternalUser(7, "Alice")],
            Some(ExternalUser(8, "Bob")),
            [9, 10]
        )

        let compact = YJson.toJson(value)
        @Assert(compact,
            "{\"tags\":[\"alpha\",\"仓颉\"],\"metrics\":{\"count\":3},\"nickname\":\"neo\"," +
            "\"members\":[{\"id\":7,\"name\":\"Alice\"}]," +
            "\"maybeMember\":{\"id\":8,\"name\":\"Bob\"},\"customNumbers\":[9,10]}")
        let compactDecoded = YJson.fromJson<ExternalFieldBranchEnvelope>(compact)
        @Expect(compactDecoded.tags[1], "仓颉")
        @Expect(compactDecoded.metrics["count"], 3)
        @Expect(compactDecoded.nickname.getOrThrow(), "neo")
        @Expect(compactDecoded.members[0].name, "Alice")
        @Expect(compactDecoded.maybeMember.getOrThrow().id, 8)
        @Expect(compactDecoded.customNumbers[1], 10)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"tags\""))
        let prettyDecoded = YJson.fromJson<ExternalFieldBranchEnvelope>(pretty)
        @Expect(prettyDecoded.tags[0], "alpha")
        @Expect(prettyDecoded.metrics["count"], 3)
        @Expect(prettyDecoded.members[0].id, 7)
        @Expect(prettyDecoded.customNumbers[0], 9)
    }

    @TestCase
    func generatedOptionFieldOmitsNoneAndRoundTripsSome(): Unit {
        let noneCompact = YJson.toJson(ExternalOptionalUserEnvelope(None<ExternalUser>))
        @Assert(noneCompact, "{}")
        @Expect(YJson.fromJson<ExternalOptionalUserEnvelope>(noneCompact).member.isNone())

        let someCompact = YJson.toJson(
            ExternalOptionalUserEnvelope(Some(ExternalUser(12, "Tao"))))
        @Assert(someCompact, "{\"member\":{\"id\":12,\"name\":\"Tao\"}}")
        let decoded = YJson.fromJson<ExternalOptionalUserEnvelope>(someCompact)
        @Expect(decoded.member.getOrThrow().id, 12)
        @Expect(decoded.member.getOrThrow().name, "Tao")
    }

    @TestCase
    func specialDirectAndCustomFieldsRoundTripEmptyCompactAndPretty(): Unit {
        let value = ExternalFieldBranchEnvelope(
            ArrayList<String>(),
            HashMap<String, Int64>(),
            None<String>,
            Array<ExternalUser>(0, repeat: ExternalUser(0, "")),
            None<ExternalUser>,
            Array<Int64>()
        )

        let compact = YJson.toJson(value)
        @Assert(compact,
            "{\"tags\":[],\"metrics\":{},\"nickname\":null,\"members\":[],\"customNumbers\":[]}")
        let compactDecoded = YJson.fromJson<ExternalFieldBranchEnvelope>(compact)
        @Expect(compactDecoded.tags.size, 0)
        @Expect(compactDecoded.metrics.size, 0)
        @Expect(compactDecoded.nickname.isNone())
        @Expect(compactDecoded.members.size, 0)
        @Expect(compactDecoded.maybeMember.isNone())
        @Expect(compactDecoded.customNumbers.size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n"))
        let prettyDecoded = YJson.fromJson<ExternalFieldBranchEnvelope>(pretty)
        @Expect(prettyDecoded.tags.size, 0)
        @Expect(prettyDecoded.metrics.size, 0)
        @Expect(prettyDecoded.members.size, 0)
        @Expect(prettyDecoded.customNumbers.size, 0)
    }

    @TestCase
    func emptyTopLevelNestedCollectionsRoundTripCompactAndPretty(): Unit {
        let arrayLists = Array<ArrayList<Int64>>(0, repeat: ArrayList<Int64>())
        let listMaps = ArrayList<HashMap<String, Int64>>()
        let mapArrays = HashMap<String, Array<Int64>>()

        @Expect(YJson.toJson(arrayLists), "[]")
        @Expect(YJson.toJson(listMaps), "[]")
        @Expect(YJson.toJson(mapArrays), "{}")
        @Expect(YJson.fromJson<Array<ArrayList<Int64>>>("[]").size, 0)
        @Expect(YJson.fromJson<ArrayList<HashMap<String, Int64>>>("[]").size, 0)
        @Expect(YJson.fromJson<HashMap<String, Array<Int64>>>("{}").size, 0)
        @Expect(YJson.fromJson<Array<ArrayList<Int64>>>(
            YJson.toJson(arrayLists, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<ArrayList<HashMap<String, Int64>>>(
            YJson.toJson(listMaps, options: JsonWriteOptions.pretty())).size, 0)
        @Expect(YJson.fromJson<HashMap<String, Array<Int64>>>(
            YJson.toJson(mapArrays, options: JsonWriteOptions.pretty())).size, 0)
    }

    @TestCase
    func nonEmptyTopLevelNestedCollectionsRoundTripCompactAndPretty(): Unit {
        let numbers = ArrayList<Int64>([1, 2])
        let arrayLists: Array<ArrayList<Int64>> = [numbers]
        let metrics = HashMap<String, Int64>()
        metrics.add("count", 3)
        let listMaps = ArrayList<HashMap<String, Int64>>([metrics])
        let mapArrays = HashMap<String, Array<Int64>>()
        mapArrays.add("team", [4, 5])

        let compactArrayLists = YJson.toJson(arrayLists)
        let compactListMaps = YJson.toJson(listMaps)
        let compactMapArrays = YJson.toJson(mapArrays)
        @Expect(compactArrayLists, "[[1,2]]")
        @Expect(compactListMaps, "[{\"count\":3}]")
        @Expect(compactMapArrays, "{\"team\":[4,5]}")
        @Expect(YJson.fromJson<Array<ArrayList<Int64>>>(compactArrayLists)[0][1], 2)
        @Expect(YJson.fromJson<ArrayList<HashMap<String, Int64>>>(compactListMaps)[0]["count"], 3)
        @Expect(YJson.fromJson<HashMap<String, Array<Int64>>>(compactMapArrays)["team"][1], 5)

        let prettyArrayLists = YJson.toJson(arrayLists, options: JsonWriteOptions.pretty())
        let prettyListMaps = YJson.toJson(listMaps, options: JsonWriteOptions.pretty())
        let prettyMapArrays = YJson.toJson(mapArrays, options: JsonWriteOptions.pretty())
        @Expect(prettyArrayLists.contains("\n"))
        @Expect(prettyListMaps.contains("\n"))
        @Expect(prettyMapArrays.contains("\n"))
        @Expect(YJson.fromJson<Array<ArrayList<Int64>>>(prettyArrayLists)[0][0], 1)
        @Expect(YJson.fromJson<ArrayList<HashMap<String, Int64>>>(prettyListMaps)[0]["count"], 3)
        @Expect(YJson.fromJson<HashMap<String, Array<Int64>>>(prettyMapArrays)["team"][0], 4)
    }

    @TestCase
    func emptyGeneratedFieldsRoundTripCompactAndPretty(): Unit {
        let value = externalEmptyEnvelope()
        let compact = YJson.toJson(value)
        @Expect(compact, "{\"arrayLists\":[],\"listMaps\":[],\"mapArrays\":{}}")
        let compactDecoded = YJson.fromJson<ExternalCollectionEnvelope>(compact)
        @Expect(compactDecoded.arrayLists.size, 0)
        @Expect(compactDecoded.listMaps.size, 0)
        @Expect(compactDecoded.mapArrays.size, 0)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n"))
        let prettyDecoded = YJson.fromJson<ExternalCollectionEnvelope>(pretty)
        @Expect(prettyDecoded.arrayLists.size, 0)
        @Expect(prettyDecoded.listMaps.size, 0)
        @Expect(prettyDecoded.mapArrays.size, 0)
    }

    @TestCase
    func nonEmptyGeneratedFieldsRoundTripCompactAndPretty(): Unit {
        let value = externalNonEmptyEnvelope()
        let compact = YJson.toJson(value)
        @Expect(compact,
            "{\"arrayLists\":[[1,2]],\"listMaps\":[{\"count\":3}],\"mapArrays\":{\"team\":[4,5]}}")
        let compactDecoded = YJson.fromJson<ExternalCollectionEnvelope>(compact)
        @Expect(compactDecoded.arrayLists[0][1], 2)
        @Expect(compactDecoded.listMaps[0]["count"], 3)
        @Expect(compactDecoded.mapArrays["team"][1], 5)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        @Expect(pretty.contains("\n  \"arrayLists\""))
        let prettyDecoded = YJson.fromJson<ExternalCollectionEnvelope>(pretty)
        @Expect(prettyDecoded.arrayLists[0][0], 1)
        @Expect(prettyDecoded.listMaps[0]["count"], 3)
        @Expect(prettyDecoded.mapArrays["team"][0], 4)
    }
}
