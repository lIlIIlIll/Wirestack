/*
 * cjjson T9 throughput benchmarks — verbatim port of yjson's
 * packages/benchmarks/src/bench_t9_throughput.cj (the 22 t9_* cases), using
 * cjjson's @JsonAdapter macro API (string materialization only).
 *
 * Bean fields, populations, case bodies and @Configure mirror the yjson blueprint
 * with ONE documented deviation: WideNested f8/f13/f18 are assigned 8.5/13.5/18.5
 * instead of staying 0.0 — cjjson's writer emits whole Float64 values as integer
 * tokens ("0") and its strict fromJson then rejects them for Float64 fields
 * (Int/Float type mismatch).  Non-integral floats keep the cjjson round-trip
 * closed; timing impact on the wide cases is negligible.
 *
 * The init() preflight validates round-trip correctness for key beans; a
 * wrong port fails loudly at first run instead of producing wrong numbers.
 */

package cjjson.test

import cjjson.*
import cjjson.macros.*

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

// ==================== T9.1 PrimitiveBean ====================

@JsonAdapter
public class PrimitiveBean {
    public var i8: Int8 = 0
    public var i16: Int16 = 0
    public var i32: Int32 = 0
    public var i64: Int64 = 0
    public var f64: Float64 = 0.0
    public var flag: Bool = false
    public var text: String = ""
    public init() {}
}

// ==================== T9.2 StringBean ====================

@JsonAdapter
public class StringBean {
    public var s1: String = ""
    public var s2: String = ""
    public var s3: String = ""
    public var s4: String = ""
    public var s5: String = ""
    public var s6: String = ""
    public var s7: String = ""
    public var s8: String = ""
    public init() {}
}

// ==================== T9.3 CollectionBean ====================

@JsonAdapter
public class CollectionBean {
    public var intArray: Array<Int64> = Array<Int64>()
    public var strArray: Array<String> = Array<String>()
    public var intMap: HashMap<String, Int64> = HashMap<String, Int64>()
    public var strMap: HashMap<String, String> = HashMap<String, String>()
    public init() {}
}

@JsonAdapter
public class NestedCollBean {
    public var data: HashMap<String, Array<Int64>> = HashMap<String, Array<Int64>>()
    public init() {}
}

@JsonAdapter
public class FloatArrayBean {
    public var f64Array: Array<Float64> = Array<Float64>()
    public init() {}
}

// ==================== T9.4 DeepNested ====================

@JsonAdapter
public class Level3 {
    public var value: String = ""
    public var count: Int64 = 0
    public init() {}
}

@JsonAdapter
public class Level2 {
    public var value: String = ""
    public var level3: Level3 = Level3()
    public init() {}
}

@JsonAdapter
public class Level1 {
    public var value: String = ""
    public var level2: Level2 = Level2()
    public init() {}
}

@JsonAdapter
public class DeepNested {
    public var level1: Level1 = Level1()
    public init() {}
}

@JsonAdapter
public class WideNested {
    public var f1: Int64 = 0
    public var f2: String = ""
    public var f3: Float64 = 0.0
    public var f4: Bool = false
    public var f5: String = ""
    public var f6: Int64 = 0
    public var f7: String = ""
    public var f8: Float64 = 0.0
    public var f9: Bool = false
    public var f10: String = ""
    public var f11: Int64 = 0
    public var f12: String = ""
    public var f13: Float64 = 0.0
    public var f14: Bool = false
    public var f15: String = ""
    public var f16: Int64 = 0
    public var f17: String = ""
    public var f18: Float64 = 0.0
    public var f19: Bool = false
    public var f20: String = ""
    public init() {}
}

@JsonAdapter
public class UltraWide {
    public var f0: Int64 = 0
    public var f1: Int64 = 0
    public var f2: Int64 = 0
    public var f3: Int64 = 0
    public var f4: Int64 = 0
    public var f5: Int64 = 0
    public var f6: Int64 = 0
    public var f7: Int64 = 0
    public var f8: Int64 = 0
    public var f9: Int64 = 0
    public var f10: Int64 = 0
    public var f11: Int64 = 0
    public var f12: Int64 = 0
    public var f13: Int64 = 0
    public var f14: Int64 = 0
    public var f15: Int64 = 0
    public var f16: Int64 = 0
    public var f17: Int64 = 0
    public var f18: Int64 = 0
    public var f19: Int64 = 0
    public var f20: Int64 = 0
    public var f21: Int64 = 0
    public var f22: Int64 = 0
    public var f23: Int64 = 0
    public var f24: Int64 = 0
    public var f25: Int64 = 0
    public var f26: Int64 = 0
    public var f27: Int64 = 0
    public var f28: Int64 = 0
    public var f29: Int64 = 0
    public var f30: Int64 = 0
    public var f31: Int64 = 0
    public var f32: Int64 = 0
    public var f33: Int64 = 0
    public var f34: Int64 = 0
    public var f35: Int64 = 0
    public var f36: Int64 = 0
    public var f37: Int64 = 0
    public var f38: Int64 = 0
    public var f39: Int64 = 0
    public var f40: Int64 = 0
    public var f41: Int64 = 0
    public var f42: Int64 = 0
    public var f43: Int64 = 0
    public var f44: Int64 = 0
    public var f45: Int64 = 0
    public var f46: Int64 = 0
    public var f47: Int64 = 0
    public var f48: Int64 = 0
    public var f49: Int64 = 0
    public init() {}
}

// ==================== E2E: LargeBean ====================

@JsonAdapter
public class E2EDetail {
    public var sku: String = "SKU-9999-MX"
    public var price: Int64 = 129900
    public var stock: Int64 = 2048
    public var weight: Float64 = 0.375
    public var warehouse: String = "WH-BJ-007"
    public init() {}
}

@JsonAdapter
public class E2ELargeBean {
    public var id: Int64 = 1000001
    public var seq: Int64 = 42
    public var version: Int64 = 3
    public var timestamp: Int64 = 1700000000000
    public var flags: Int64 = 7
    public var name: String = "order-2026-08-10-0001"
    public var code: String = "ORD-AABBCCDD-1234"
    public var category: String = "electronics/phones/accessories"
    public var owner: String = "user.mufengzi@example.com"
    public var description: String = ""
    public var active: Bool = true
    public var verified: Bool = false
    public var enabled: Bool = true
    public var score: Float64 = 98.5
    public var ratio: Float64 = 0.875
    public var latitude: Float64 = 39.9042
    public var longitude: Float64 = 116.4074
    public var tags: Array<String> = Array<String>()
    public var scores: Array<Int64> = Array<Int64>()
    public var meta: HashMap<String, String> = HashMap<String, String>()
    public var detail: E2EDetail = E2EDetail()
    public init() {}
}

// ==================== E2E: BigString ====================

@JsonAdapter
public class E2EBigString {
    public var id: Int64 = 1
    public var label: String = "payload"
    public var blob: String = ""
    public var chunks: Array<String> = Array<String>()
    public var checksum: Int64 = 1234567890
    public init() {}
}

// ==================== T9.5 coverage beans (matrix expansion) ====================

@JsonAdapter
public class InnerBean {
    public var id: Int64 = 0
    public var label: String = ""
    public var score: Int64 = 0
    public init() {}
}

@JsonAdapter
public class OptionBean {
    public var name: ?String = None
    public var count: ?Int64 = None
    public var inner: ?InnerBean = None
    public var tag: ?String = None
    public init() {}
}

@JsonAdapter
public class EmptyBean {
    public var arr: Array<Int64> = Array<Int64>()
    public var m: HashMap<String, Int64> = HashMap<String, Int64>()
    public var strs: Array<String> = Array<String>()
    public var inner: InnerBean = InnerBean()
    public init() {}
}

@JsonAdapter
public class ExtremeBean {
    public var a: Int64 = 0
    public var b: Int64 = 0
    public var c: Int64 = -1
    public var d: Int64 = 0
    public var e: Int64 = 1
    public init() {}
}

@JsonAdapter
public class LargeDocItem {
    public var id: Int64 = 0
    public var sku: String = ""
    public var name: String = ""
    public var desc: String = ""
    public var price: Int64 = 0
    public var stock: Int64 = 0
    public var active: Bool = false
    public var score: Int64 = 0
    public var cat: String = ""
    public var rank: Int64 = 0
    public init() {}
}

@JsonAdapter
public class LargeDoc {
    public var items: Array<LargeDocItem> = Array<LargeDocItem>()
    public var index: HashMap<String, Int64> = HashMap<String, Int64>()
    public init() {}
}

@JsonAdapter
public class MatrixBean {
    public var grid: Array<Array<Int64>> = Array<Array<Int64>>()
    public init() {}
}

// ==================== Helpers ====================

func t9BuildLongStr(n: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..n) { sb.append(Rune(97)) }
    sb.toString()
}

func t9BuildIntArray(n: Int64): Array<Int64> {
    let arr = ArrayList<Int64>()
    for (i in 0..n) { arr.add(i) }
    arr.toArray()
}

func t9BuildFloat64Array(n: Int64): Array<Float64> {
    let arr = ArrayList<Float64>()
    for (i in 0..n) { arr.add(Float64(i) * 3.14) }
    arr.toArray()
}

func t9BuildIntMap(n: Int64): HashMap<String, Int64> {
    let m = HashMap<String, Int64>()
    for (i in 0..n) { m.add("key${i}", i) }
    m
}

func t9BuildStrMap(n: Int64): HashMap<String, String> {
    let m = HashMap<String, String>()
    for (i in 0..n) { m.add("k${i}", "v${i}") }
    m
}

func t9BuildTagArray(n: Int64): Array<String> {
    let arr = ArrayList<String>()
    for (i in 0..n) { arr.add("tag${i}") }
    arr.toArray()
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class T9ThroughputBench {
    let optionMixed: OptionBean
    let optionFull: OptionBean
    let optionJson: String
    let emptyBean: EmptyBean
    let emptyJson: String
    let extBean: ExtremeBean
    let extJson: String
    let largeDoc: LargeDoc
    let largeDocJson: String
    let matrixBean: MatrixBean
    let matrixJson: String
    let unknownPayload: String
    let prettyWideJson: String
    let prim: PrimitiveBean
    let primJson: String

    // T9.2
    let strShort: StringBean
    let strLong: StringBean
    let strEscape: StringBean
    let strUnicode: StringBean

    // T9.3
    let collSmallArr: CollectionBean
    let collLargeArr: CollectionBean
    let collLargeArrJson: String
    let collSmallMap: CollectionBean
    let collLargeMap: CollectionBean
    let collLargeMapJson: String
    let nestedColl: NestedCollBean
    let nestedCollJson: String
    let collLargeFloatArr: FloatArrayBean

    // T9.4
    let deep: DeepNested
    let deepJson: String
    let wide: WideNested
    let wideJson: String
    let ultra: UltraWide
    let ultraJson: String

    // E2E
    let large: E2ELargeBean
    let largeJson: String
    let big: E2EBigString
    let bigJson: String

    var sink: Int64 = 0

    init() {
        // T9.1
        prim = PrimitiveBean()
        prim.i8 = 1
        prim.i16 = 2
        prim.i32 = 3
        prim.i64 = 4
        prim.f64 = 3.14
        prim.flag = true
        prim.text = "hello"
        primJson = prim.toJson()

        // T9.2
        strShort = StringBean()
        strShort.s1 = "abc123"
        strShort.s2 = "name"
        strShort.s3 = "value"
        strShort.s4 = "test"
        strShort.s5 = "data"
        strShort.s6 = "item"
        strShort.s7 = "code"
        strShort.s8 = "desc"

        let longBase = t9BuildLongStr(1000)
        strLong = StringBean()
        strLong.s1 = longBase
        strLong.s2 = longBase
        strLong.s3 = longBase
        strLong.s4 = longBase
        strLong.s5 = longBase
        strLong.s6 = longBase
        strLong.s7 = longBase
        strLong.s8 = longBase

        strEscape = StringBean()
        strEscape.s1 = "line1\nline2"
        strEscape.s2 = "tab\there"
        strEscape.s3 = "quote\"q"
        strEscape.s4 = "back\\slash"
        strEscape.s5 = "cr\rfeed"
        strEscape.s6 = "mix\n\t\"\\"
        strEscape.s7 = "plain"
        strEscape.s8 = "end"

        strUnicode = StringBean()
        strUnicode.s1 = "中文测试"
        strUnicode.s2 = "🎉🎊emoji"
        strUnicode.s3 = "日本語テスト"
        strUnicode.s4 = "한국어"
        strUnicode.s5 = "Русский"
        strUnicode.s6 = "مرحبا"
        strUnicode.s7 = "Ελληνικά"
        strUnicode.s8 = "ทดสอบ"

        // T9.3
        collSmallArr = CollectionBean()
        collSmallArr.intArray = t9BuildIntArray(10)

        collLargeArr = CollectionBean()
        collLargeArr.intArray = t9BuildIntArray(1000)
        collLargeArrJson = collLargeArr.toJson()

        collSmallMap = CollectionBean()
        collSmallMap.intMap = t9BuildIntMap(10)

        collLargeMap = CollectionBean()
        collLargeMap.intMap = t9BuildIntMap(100)
        collLargeMapJson = collLargeMap.toJson()

        nestedColl = NestedCollBean()
        for (i in 0..10) { nestedColl.data.add("k${i}", t9BuildIntArray(10)) }
        nestedCollJson = nestedColl.toJson()

        collLargeFloatArr = FloatArrayBean()
        collLargeFloatArr.f64Array = t9BuildFloat64Array(1000)

        // T9.4
        deep = DeepNested()
        deep.level1.value = "L1"
        deep.level1.level2.value = "L2"
        deep.level1.level2.level3.value = "L3"
        deep.level1.level2.level3.count = 99
        deepJson = deep.toJson()

        wide = WideNested()
        wide.f1 = 1
        wide.f3 = 3.14
        wide.f4 = true
        wide.f6 = 6
        wide.f8 = 8.5
        wide.f13 = 13.5
        wide.f18 = 18.5
        wide.f20 = "wide"
        wideJson = wide.toJson()
        ultra = UltraWide()
        ultraJson = ultra.toJson()

        // E2E: LargeBean
        large = E2ELargeBean()
        large.description = t9BuildLongStr(200)
        large.tags = t9BuildTagArray(20)
        large.scores = t9BuildIntArray(100)
        large.meta = t9BuildStrMap(20)
        largeJson = large.toJson()

        // E2E: BigString
        big = E2EBigString()
        big.blob = t9BuildLongStr(32768)
        let chunk = t9BuildLongStr(256)
        let chunksList = ArrayList<String>()
        for (_ in 0..32) { chunksList.add(chunk) }
        big.chunks = chunksList.toArray()
        bigJson = big.toJson()
        // ---- T9.5 coverage fixtures ----
        optionMixed = OptionBean()
        optionMixed.name = Some("matrix")
        let optionInner = InnerBean()
        optionInner.id = 7
        optionInner.label = "inner"
        optionInner.score = 650
        optionMixed.inner = Some(optionInner)

        optionFull = OptionBean()
        optionFull.name = Some("matrix")
        optionFull.count = Some(42)
        optionFull.inner = Some(optionInner)
        optionFull.tag = Some("full")
        optionJson = optionFull.toJson()

        emptyBean = EmptyBean()
        emptyJson = emptyBean.toJson()

        extBean = ExtremeBean()
        extBean.a = Int64.Max
        extBean.b = Int64.Min
        extJson = extBean.toJson()

        let desc64 = t9BuildLongStr(64)
        let items = ArrayList<LargeDocItem>()
        for (i in 0..3000) {
            let item = LargeDocItem()
            item.id = i
            item.sku = "SKU-${i}-MX"
            item.name = "item-name-${i}"
            item.desc = "description-${i}-" + desc64
            item.price = 1000 + i
            item.stock = i % 500
            item.active = (i % 2 == 0)
            item.score = 90 + (i % 10)
            item.cat = "cat-${i % 12}"
            item.rank = i % 100
            items.add(item)
        }
        largeDoc = LargeDoc()
        largeDoc.items = items.toArray()
        largeDoc.index = t9BuildIntMap(2000)
        largeDocJson = largeDoc.toJson()

        let grid = ArrayList<Array<Int64>>()
        for (_ in 0..50) {
            grid.add(t9BuildIntArray(20))
        }
        matrixBean = MatrixBean()
        matrixBean.grid = grid.toArray()
        matrixJson = matrixBean.toJson()

        unknownPayload = """
            {"intArray":[1,2,3],"strArray":["a"],"intMap":{"k":1},"strMap":{"a":"b"},"x1":1,"x2":"text","x3":[1,2],"x4":{"k":1},"x5":true}
            """
        let pretty = StringBuilder()
        pretty.append("{\n")
        pretty.append("  \"f1\": 1,\n")
        pretty.append("  \"f2\": \"\",\n")
        pretty.append("  \"f3\": 3.14,\n")
        pretty.append("  \"f4\": true,\n")
        pretty.append("  \"f5\": \"\",\n")
        pretty.append("  \"f6\": 6,\n")
        pretty.append("  \"f7\": \"\",\n")
        pretty.append("  \"f8\": 0.0,\n")
        pretty.append("  \"f9\": false,\n")
        pretty.append("  \"f10\": \"\",\n")
        pretty.append("  \"f11\": 0,\n")
        pretty.append("  \"f12\": \"\",\n")
        pretty.append("  \"f13\": 0.0,\n")
        pretty.append("  \"f14\": false,\n")
        pretty.append("  \"f15\": \"\",\n")
        pretty.append("  \"f16\": 0,\n")
        pretty.append("  \"f17\": \"\",\n")
        pretty.append("  \"f18\": 0.0,\n")
        pretty.append("  \"f19\": false,\n")
        pretty.append("  \"f20\": \"wide\"\n")
        pretty.append("}")
        prettyWideJson = pretty.toString()

        let primRound = PrimitiveBean.fromJson(primJson)
        let collRound = CollectionBean.fromJson(collLargeArrJson)
        let largeRound = E2ELargeBean.fromJson(largeJson)
        let wideRound = WideNested.fromJson(wideJson)
        let ultraRound = UltraWide.fromJson(ultraJson)
        let bigRound = E2EBigString.fromJson(bigJson)
        let deepRound = DeepNested.fromJson(deepJson)
        if (primRound.i64 != 4 || primRound.flag != true || primRound.text != "hello" ||
            collRound.intArray.size != 1000 || collRound.intArray[999] != 999 ||
            largeRound.id != 1000001 || largeRound.detail.sku != "SKU-9999-MX" ||
            largeRound.meta.size != 20 || largeRound.scores.size != 100 ||
            wideRound.f8 != 8.5 || wideRound.f13 != 13.5 || wideRound.f18 != 18.5 ||
            wideRound.f1 != 1 || wideRound.f20 != "wide" ||
            ultraRound.f0 != 0 || ultraRound.f49 != 0 ||
            bigRound.blob.size != 32768 || bigRound.chunks.size != 32 ||
            deepRound.level1.level2.level3.count != 99) {
            throw Exception("cjjson T9 port fixture validation failed")
        }
        let optionRound = OptionBean.fromJson(optionJson)
        let emptyRound = EmptyBean.fromJson(emptyJson)
        let extRound = ExtremeBean.fromJson(extJson)
        let largeDocRound = LargeDoc.fromJson(largeDocJson)
        let matrixRound = MatrixBean.fromJson(matrixJson)
        if (optionRound.count != Some(42) || optionRound.name != Some("matrix") ||
            emptyRound.arr.size != 0 || emptyRound.inner.id != 0 ||
            extRound.a != Int64.Max || extRound.b != Int64.Min ||
            largeDocRound.items.size != 3000 || largeDocRound.index.size != 2000 ||
            matrixRound.grid.size != 50 || matrixRound.grid[0].size != 20 ||
            CollectionBean.fromJson(unknownPayload).intArray.size != 3 ||
            WideNested.fromJson(prettyWideJson).f1 != 1) {
            throw Exception("cjjson T9 expansion fixture validation failed")
        }
    }

    // ---------- T9.1 ----------

    @Bench
    func t9_1_1_primitiveSerialize() {
        sink = prim.toJson().size
    }

    @Bench
    func t9_1_2_primitiveDeserialize() {
        sink = PrimitiveBean.fromJson(primJson).i64
    }

    @Bench
    func t9_1_3_primitiveRoundTrip() {
        let json = prim.toJson()
        sink = PrimitiveBean.fromJson(json).i64
    }

    // ---------- T9.2 ----------

    @Bench
    func t9_2_1_shortStringSerialize() {
        sink = strShort.toJson().size
    }

    @Bench
    func t9_2_2_longStringSerialize() {
        sink = strLong.toJson().size
    }

    @Bench
    func t9_2_3_escapeStringSerialize() {
        sink = strEscape.toJson().size
    }

    @Bench
    func t9_2_4_unicodeStringSerialize() {
        sink = strUnicode.toJson().size
    }

    // ---------- T9.3 ----------

    @Bench
    func t9_3_1_smallArraySerialize() {
        sink = collSmallArr.toJson().size
    }

    @Bench
    func t9_3_2_largeArraySerialize() {
        sink = collLargeArr.toJson().size
    }

    @Bench
    func t9_3_3_largeArrayDeserialize() {
        sink = Int64(CollectionBean.fromJson(collLargeArrJson).intArray.size)
    }

    @Bench
    func t9_3_4_smallMapSerialize() {
        sink = collSmallMap.toJson().size
    }

    @Bench
    func t9_3_5_largeMapSerialize() {
        sink = collLargeMap.toJson().size
    }

    @Bench
    func t9_3_6_largeMapDeserialize() {
        sink = Int64(CollectionBean.fromJson(collLargeMapJson).intMap.size)
    }

    @Bench
    func t9_3_7_nestedCollectionSerialize() {
        sink = nestedColl.toJson().size
    }

    @Bench
    func t9_3_8_nestedCollectionDeserialize() {
        sink = Int64(NestedCollBean.fromJson(nestedCollJson).data.size)
    }

    @Bench
    func t9_3_9_largeFloat64ArraySerialize() {
        sink = collLargeFloatArr.toJson().size
    }

    // ---------- T9.4 ----------

    @Bench
    func t9_4_1_deepNestedSerialize() {
        sink = deep.toJson().size
    }

    @Bench
    func t9_4_2_deepNestedDeserialize() {
        sink = DeepNested.fromJson(deepJson).level1.level2.level3.count
    }

    @Bench
    func t9_4_3_wideSerialize() {
        sink = wide.toJson().size
    }

    @Bench
    func t9_4_4_wideDeserialize() {
        sink = WideNested.fromJson(wideJson).f1
    }

    @Bench
    func t9_4_5_ultraWideSerialize() {
        sink = ultra.toJson().size
    }

    @Bench
    func t9_4_6_ultraWideDeserialize() {
        sink = UltraWide.fromJson(ultraJson).f49
    }

    // ---------- T9.5 coverage (matrix expansion) ----------

    @Bench
    func t9_5_1_optionSerialize() {
        sink = optionMixed.toJson().size
    }

    @Bench
    func t9_5_2_optionDeserialize() {
        sink = (OptionBean.fromJson(optionJson).count ?? 0)
    }

    @Bench
    func t9_5_3_optionRoundTrip() {
        let json = optionFull.toJson()
        sink = (OptionBean.fromJson(json).count ?? 0)
    }

    @Bench
    func t9_5_4_emptyContainersSerialize() {
        sink = emptyBean.toJson().size
    }

    @Bench
    func t9_5_5_emptyContainersDeserialize() {
        sink = Int64(EmptyBean.fromJson(emptyJson).arr.size)
    }

    @Bench
    func t9_5_6_int64ExtremesSerialize() {
        sink = extBean.toJson().size
    }

    @Bench
    func t9_5_7_int64ExtremesDeserialize() {
        sink = ExtremeBean.fromJson(extJson).a
    }

    @Bench
    func t9_5_8_unknownFieldDeserialize() {
        sink = Int64(CollectionBean.fromJson(unknownPayload).intArray.size)
    }

    @Bench
    func t9_5_9_largeDocumentSerialize() {
        sink = largeDoc.toJson().size
    }

    @Bench
    func t9_5_10_largeDocumentDeserialize() {
        sink = Int64(LargeDoc.fromJson(largeDocJson).items.size)
    }

    @Bench
    func t9_5_11_arrayOfArraySerialize() {
        sink = matrixBean.toJson().size
    }

    @Bench
    func t9_5_12_arrayOfArrayDeserialize() {
        sink = Int64(MatrixBean.fromJson(matrixJson).grid.size)
    }

    @Bench
    func t9_5_13_prettyWideDeserialize() {
        sink = WideNested.fromJson(prettyWideJson).f1
    }
}
