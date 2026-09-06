package yjson

import yjson_macros.*

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@JsonCodec
class PatchCovRound3Bean {
    public var nullable: Option<Int64> = None
    public var arr: Array<Int64> = Array<Int64>()
    public var map: HashMap<String, Int64> = HashMap<String, Int64>()
    public var name: String = ""

    public init() {}
}

@Test
class JsonPatchCovRound3CodecTest {

    @TestCase
    func round3NullEmptyRoundTripBranches(): Unit {
        // Null/empty Option/array/map fields round-trip through the
        // generated bean codec; an empty Option writes no member by default.
        let decoded = YJson.fromJson("{\"nullable\":null,\"arr\":[],\"map\":{},\"name\":\"\"}",
            codec: PatchCovRound3BeanJson)
        @Expect(decoded.nullable.isNone(), true)
        @Expect(decoded.arr.size, 0)
        @Expect(decoded.map.size, 0)
        @Expect(decoded.name, "")

        let text = YJson.toJson(decoded, codec: PatchCovRound3BeanJson)
        @Expect(text.contains("\"nullable\""), false)
        let back = YJson.fromJson(text, codec: PatchCovRound3BeanJson)
        @Expect(back.nullable.isNone(), true)
        @Expect(back.name, "")
    }

    @TestCase
    func round3PopulatedRoundTripBranches(): Unit {
        // Populated Option/array/map fields exercise the fast compact
        // read/write paths of the generated bean codec.
        let decoded = YJson.fromJson("{\"nullable\":7,\"arr\":[1,2],\"map\":{\"a\":1},\"name\":\"hi\"}",
            codec: PatchCovRound3BeanJson)
        @Expect(decoded.nullable.getOrThrow(), 7)
        @Expect(decoded.arr.size, 2)
        @Expect(decoded.map["a"], 1)
        @Expect(decoded.name, "hi")

        let text = YJson.toJson(decoded, codec: PatchCovRound3BeanJson)
        let back = YJson.fromJson(text, codec: PatchCovRound3BeanJson)
        @Expect(back.nullable.getOrThrow(), 7)
        @Expect(back.arr.size, 2)
        @Expect(back.map["a"], 1)
        @Expect(back.name, "hi")
    }

    @TestCase
    func round3BulkAndOptionCodecBranches(): Unit {
        // jsonTryWriteCompact* helpers on a plain JsonDirectWriter (both the
        // bulk writer match arm and the non-bulk false arm).
        let ints = [1, 2, 3]
        @Expect(jsonTryWriteCompactInt64Array(JsonDirectWriter(), ints), true)
        let floats = [1.5, -2.0]
        @Expect(jsonTryWriteCompactFloat64Array(JsonDirectWriter(), floats), true)
        let strings = ["a", "b"]
        @Expect(jsonTryWriteCompactStringArray(JsonDirectWriter(), strings), true)
        let intsList = ArrayList<Int64>(); intsList.add(1); intsList.add(2)
        @Expect(jsonTryWriteCompactInt64ArrayList(JsonDirectWriter(), intsList), true)
        let stringsList = ArrayList<String>(); stringsList.add("x")
        @Expect(jsonTryWriteCompactStringArrayList(JsonDirectWriter(), stringsList), true)
        let intMap = HashMap<String, Int64>(); intMap["k"] = 1
        @Expect(jsonTryWriteCompactInt64Map(JsonDirectWriter(), intMap), true)
        let strMap = HashMap<String, String>(); strMap["k"] = "v"
        @Expect(jsonTryWriteCompactStringMap(JsonDirectWriter(), strMap), true)
        let arrMap = HashMap<String, Array<Int64>>(); arrMap["k"] = [1]
        @Expect(jsonTryWriteCompactInt64ArrayMap(JsonDirectWriter(), arrMap), true)

    }

    @TestCase
    func round3NonDefaultOptionEntryPoints(): Unit {
        // decodeString/decodeBytes with non-default options route through
        // JsonDirectReader (semantic path) instead of JsonFastReader.
        let lastWins = JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins)
        let decoded = YJson.fromJson("{\"a\":1,\"a\":2}", codec: JsonCodecs.stringMap(JsonCodecs.int64),
            options: lastWins)
        @Expect(decoded["a"], 2)
        let decodedBytes = YJson.fromJson(
            unsafe { "{\"a\":3}".rawData().clone() },
            codec: JsonCodecs.stringMap(JsonCodecs.int64), options: lastWins)
        @Expect(decodedBytes["a"], 3)

        // Option codec with default options uses the cursor fast path.
        let optionCodec = JsonCodecs.option(JsonCodecs.int64)
        @Expect(YJson.fromJson("9", codec: optionCodec).getOrThrow(), 9)
        @Expect(YJson.fromJson("null", codec: optionCodec).isNone(), true)
        @Expect(YJson.toJson(Some(4), codec: optionCodec), "4")
        @Expect(YJson.toJson(None<Int64>, codec: optionCodec), "null")
    }
}
