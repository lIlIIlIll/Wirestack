/*
 * yjson T9 throughput benchmarks — mirrors json4cj's T9BenchThroughput + T9BenchE2E +
 * T9BenchLargeList workloads, using yjson's typed codec API.
 *
 * Each case maps 1:1 to JacksonBench.java / JacksonBenchE2E.java scenarios:
 *   - PrimitiveBean (7 scalar fields)
 *   - StringBean (8 String fields: short/long/escape/unicode)
 *   - CollectionBean (Array<Int64>, Array<String>, HashMap<String,Int64>, HashMap<String,String>)
 *   - NestedCollBean (HashMap<String, Array<Int64>>)
 *   - FloatArrayBean (Array<Float64>)
 *   - DeepNested (4 levels)
 *   - WideNested (20 mixed fields)
 *   - UltraWide (50 Int64 fields)
 *   - LargeBean E2E (24 mixed fields + nested, ~1.3KB)
 *   - BigString E2E (~32KB blob + 32×256 char array, ~41KB)
 *   - PerfLargeList E2E (200 × 110-field objects, ~600KB+)
 */

package yjson_benchmarks

import yjson.*
import yjson_macros.*

import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

// ==================== T9.1 PrimitiveBean ====================

@JsonCodec
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

@JsonCodec
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

@JsonCodec
public class CollectionBean {
    public var intArray: Array<Int64> = Array<Int64>()
    public var strArray: Array<String> = Array<String>()
    public var intMap: HashMap<String, Int64> = HashMap<String, Int64>()
    public var strMap: HashMap<String, String> = HashMap<String, String>()
    public init() {}
}

@JsonCodec
public class NestedCollBean {
    public var data: HashMap<String, Array<Int64>> = HashMap<String, Array<Int64>>()
    public init() {}
}

@JsonCodec
public class FloatArrayBean {
    public var f64Array: Array<Float64> = Array<Float64>()
    public init() {}
}

// ==================== T9.4 DeepNested ====================

@JsonCodec
public class Level3 {
    public var value: String = ""
    public var count: Int64 = 0
    public init() {}
}

@JsonCodec
public class Level2 {
    public var value: String = ""
    public var level3: Level3 = Level3()
    public init() {}
}

@JsonCodec
public class Level1 {
    public var value: String = ""
    public var level2: Level2 = Level2()
    public init() {}
}

@JsonCodec
public class DeepNested {
    public var level1: Level1 = Level1()
    public init() {}
}

@JsonCodec
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

@JsonCodec
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

@JsonCodec
public class E2EDetail {
    public var sku: String = "SKU-9999-MX"
    public var price: Int64 = 129900
    public var stock: Int64 = 2048
    public var weight: Float64 = 0.375
    public var warehouse: String = "WH-BJ-007"
    public init() {}
}

@JsonCodec
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

@JsonCodec
public class E2EBigString {
    public var id: Int64 = 1
    public var label: String = "payload"
    public var blob: String = ""
    public var chunks: Array<String> = Array<String>()
    public var checksum: Int64 = 1234567890
    public init() {}
}

// ==================== T9.5 coverage beans (matrix expansion) ====================

@JsonCodec
public class InnerBean {
    public var id: Int64 = 0
    public var label: String = ""
    public var score: Int64 = 0
    public init() {}
}

@JsonCodec
public class OptionBean {
    public var name: Option<String> = None
    public var count: Option<Int64> = None
    public var inner: Option<InnerBean> = None
    public var tag: Option<String> = None
    public init() {}
}

@JsonCodec
public class EmptyBean {
    public var arr: Array<Int64> = Array<Int64>()
    public var m: HashMap<String, Int64> = HashMap<String, Int64>()
    public var strs: Array<String> = Array<String>()
    public var inner: InnerBean = InnerBean()
    public init() {}
}

@JsonCodec
public class ExtremeBean {
    public var a: Int64 = 0
    public var b: Int64 = 0
    public var c: Int64 = -1
    public var d: Int64 = 0
    public var e: Int64 = 1
    public init() {}
}

@JsonCodec
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

@JsonCodec
public class LargeDoc {
    public var items: Array<LargeDocItem> = Array<LargeDocItem>()
    public var index: HashMap<String, Int64> = HashMap<String, Int64>()
    public init() {}
}

@JsonCodec
public class MatrixBean {
    public var grid: Array<Array<Int64>> = Array<Array<Int64>>()
    public init() {}
}

// ==================== E2E: PerfLargeList (200×110 fields) ====================

// @JsonCodec
// public class PerfLargeItem {
//     public var optStr01: String = ""
//     public var optStr02: String = ""
//     public var optStr03: String = ""
//     public var optStr04: String = ""
//     public var optStr05: String = ""
//     public var optStr06: String = ""
//     public var optStr07: String = ""
//     public var optStr08: String = ""
//     public var optStr09: String = ""
//     public var optStr10: String = ""
//     public var optStr11: String = ""
//     public var optStr12: String = ""
//     public var optStr13: String = ""
//     public var optStr14: String = ""
//     public var optStr15: String = ""
//     public var optStr16: String = ""
//     public var optStr17: String = ""
//     public var optStr18: String = ""
//     public var optStr19: String = ""
//     public var optStr20: String = ""
//     public var optStr21: String = ""
//     public var optStr22: String = ""
//     public var optStr23: String = ""
//     public var optStr24: String = ""
//     public var optStr25: String = ""
//     public var optStr26: String = ""
//     public var optStr27: String = ""
//     public var optStr28: String = ""
//     public var optStr29: String = ""
//     public var optStr30: String = ""
//     public var optStr31: String = ""
//     public var optStr32: String = ""
//     public var optStr33: String = ""
//     public var optStr34: String = ""
//     public var optStr35: String = ""
//     public var optStr36: String = ""
//     public var optStr37: String = ""
//     public var optStr38: String = ""
//     public var optStr39: String = ""
//     public var optStr40: String = ""
//     public var optStr41: String = ""
//     public var optStr42: String = ""
//     public var optStr43: String = ""
//     public var optStr44: String = ""
//     public var optStr45: String = ""
//     public var optStr46: String = ""
//     public var optStr47: String = ""
//     public var optStr48: String = ""
//     public var optStr49: String = ""
//     public var optStr50: String = ""
//     public var optStr51: String = ""
//     public var optStr52: String = ""
//     public var optStr53: String = ""
//     public var optStr54: String = ""
//     public var optStr55: String = ""
//     public var optStr56: String = ""
//     public var optStr57: String = ""
//     public var optStr58: String = ""
//     public var optStr59: String = ""
//     public var optStr60: String = ""
//     public var optStr61: String = ""
//     public var intVal01: Int32 = 0
//     public var intVal02: Int32 = 0
//     public var intVal03: Int32 = 0
//     public var intVal04: Int32 = 0
//     public var intVal05: Int32 = 0
//     public var intVal06: Int32 = 0
//     public var intVal07: Int32 = 0
//     public var intVal08: Int32 = 0
//     public var intVal09: Int32 = 0
//     public var intVal10: Int32 = 0
//     public var intVal11: Int32 = 0
//     public var intVal12: Int32 = 0
//     public var intVal13: Int32 = 0
//     public var intVal14: Int32 = 0
//     public var intVal15: Int32 = 0
//     public var intVal16: Int32 = 0
//     public var intVal17: Int32 = 0
//     public var intVal18: Int32 = 0
//     public var intVal19: Int32 = 0
//     public var intVal20: Int32 = 0
//     public var intVal21: Int32 = 0
//     public var intVal22: Int32 = 0
//     public var intVal23: Int32 = 0
//     public var intVal24: Int32 = 0
//     public var intVal25: Int32 = 0
//     public var intVal26: Int32 = 0
//     public var intVal27: Int32 = 0
//     public var intVal28: Int32 = 0
//     public var intVal29: Int32 = 0
//     public var intVal30: Int32 = 0
//     public var longVal01: Int64 = 0
//     public var longVal02: Int64 = 0
//     public var longVal03: Int64 = 0
//     public var longVal04: Int64 = 0
//     public var longVal05: Int64 = 0
//     public var longVal06: Int64 = 0
//     public var longVal07: Int64 = 0
//     public var longVal08: Int64 = 0
//     public var longVal09: Int64 = 0
//     public var longVal10: Int64 = 0
//     public var longVal11: Int64 = 0
//     public var longVal12: Int64 = 0
//     public var longVal13: Int64 = 0
//     public var longVal14: Int64 = 0
//     public var longVal15: Int64 = 0
//     public var longVal16: Int64 = 0
//     public var boolVal: Bool = false
//     public var tags: ArrayList<String> = ArrayList<String>()
//     public var attrs: HashMap<String, String> = HashMap<String, String>()
//     public init() {}
// }

// @JsonCodec
// public class PerfLargeList {
//     public var items: Array<PerfLargeItem> = Array<PerfLargeItem>()
//     public init() {}
// }

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

// func t9BuildLargeItem(index: Int64): PerfLargeItem {
//     let item = PerfLargeItem()
//     item.optStr01 = "os01_${index}"
// func t9BuildLargeItem(index: Int64): PerfLargeItem {
//     let item = PerfLargeItem()
//     item.optStr01 = "os01_${index}"
//     item.optStr02 = "os02_${index}"
//     item.optStr03 = "os03_${index}"
//     item.optStr04 = "os04_${index}"
//     item.optStr05 = "os05_${index}"
//     item.optStr06 = "os06_${index}"
//     item.optStr07 = "os07_${index}"
//     item.optStr08 = "os08_${index}"
//     item.optStr09 = "os09_${index}"
//     item.optStr10 = "os10_${index}"
//     item.optStr11 = "os11_${index}"
//     item.optStr12 = "os12_${index}"
//     item.optStr13 = "os13_${index}"
//     item.optStr14 = "os14_${index}"
//     item.optStr15 = "os15_${index}"
//     item.optStr16 = "os16_${index}"
//     item.optStr17 = "os17_${index}"
//     item.optStr18 = "os18_${index}"
//     item.optStr19 = "os19_${index}"
//     item.optStr20 = "os20_${index}"
//     item.optStr21 = "os21_${index}"
//     item.optStr22 = "os22_${index}"
//     item.optStr23 = "os23_${index}"
//     item.optStr24 = "os24_${index}"
//     item.optStr25 = "os25_${index}"
//     item.optStr26 = "os26_${index}"
//     item.optStr27 = "os27_${index}"
//     item.optStr28 = "os28_${index}"
//     item.optStr29 = "os29_${index}"
//     item.optStr30 = "os30_${index}"
//     item.optStr31 = "os31_${index}"
//     item.optStr32 = "os32_${index}"
//     item.optStr33 = "os33_${index}"
//     item.optStr34 = "os34_${index}"
//     item.optStr35 = "os35_${index}"
//     item.optStr36 = "os36_${index}"
//     item.optStr37 = "os37_${index}"
//     item.optStr38 = "os38_${index}"
//     item.optStr39 = "os39_${index}"
//     item.optStr40 = "os40_${index}"
//     item.optStr41 = "os41_${index}"
//     item.optStr42 = "os42_${index}"
//     item.optStr43 = "os43_${index}"
//     item.optStr44 = "os44_${index}"
//     item.optStr45 = "os45_${index}"
//     item.optStr46 = "os46_${index}"
//     item.optStr47 = "os47_${index}"
//     item.optStr48 = "os48_${index}"
//     item.optStr49 = "os49_${index}"
//     item.optStr50 = "os50_${index}"
//     item.optStr51 = "os51_${index}"
//     item.optStr52 = "os52_${index}"
//     item.optStr53 = "os53_${index}"
//     item.optStr54 = "os54_${index}"
//     item.optStr55 = "os55_${index}"
//     item.optStr56 = "os56_${index}"
//     item.optStr57 = "os57_${index}"
//     item.optStr58 = "os58_${index}"
//     item.optStr59 = "os59_${index}"
//     item.optStr60 = "os60_${index}"
//     item.optStr61 = "os61_${index}"
//     item.intVal01 = Int32(index % 100)
//     item.intVal02 = Int32(index % 200)
//     item.intVal03 = Int32(index % 50)
//     item.intVal04 = Int32(index % 75)
//     item.intVal05 = Int32(index % 30)
//     item.intVal06 = Int32(index % 60)
//     item.intVal07 = Int32(index % 90)
//     item.intVal08 = Int32(index % 40)
//     item.intVal09 = Int32(index % 80)
//     item.intVal10 = Int32(index % 25)
//     item.intVal11 = Int32(index % 100)
//     item.intVal12 = Int32(index % 200)
//     item.intVal13 = Int32(index % 50)
//     item.intVal14 = Int32(index % 75)
//     item.intVal15 = Int32(index % 30)
//     item.intVal16 = Int32(index % 60)
//     item.intVal17 = Int32(index % 90)
//     item.intVal18 = Int32(index % 40)
//     item.intVal19 = Int32(index % 80)
//     item.intVal20 = Int32(index % 25)
//     item.intVal21 = Int32(index % 100)
//     item.intVal22 = Int32(index % 200)
//     item.intVal23 = Int32(index % 50)
//     item.intVal24 = Int32(index % 75)
//     item.intVal25 = Int32(index % 30)
//     item.intVal26 = Int32(index % 60)
//     item.intVal27 = Int32(index % 90)
//     item.intVal28 = Int32(index % 40)
//     item.intVal29 = Int32(index % 80)
//     item.intVal30 = Int32(index % 25)
//     item.longVal01 = index
//     item.longVal02 = index * 2
//     item.longVal03 = index * 3
//     item.longVal04 = index * 4
//     item.longVal05 = index * 5
//     item.longVal06 = index * 6
//     item.longVal07 = index * 7
//     item.longVal08 = index * 8
//     item.longVal09 = index * 9
//     item.longVal10 = index * 10
//     item.longVal11 = index * 11
//     item.longVal12 = index * 12
//     item.longVal13 = index * 13
//     item.longVal14 = index * 14
//     item.longVal15 = index * 15
//     item.longVal16 = index * 16
//     item.boolVal = (index % 2 == 0)
//     let tags = ArrayList<String>()
//     for (j in 0..40) { tags.add("tag_${index}_${j}") }
//     item.tags = tags
//     let attrs = HashMap<String, String>()
//     for (j in 0..40) { attrs.add("k_${index}_${j}", "v_${index}_${j}") }
//     item.attrs = attrs
//     item
// }
@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class T9ThroughputBench {
    // T9.1
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
    // let perfList: PerfLargeList
    // let perfListJson: String

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
    var sink: Int64 = 0
    var strSink: String = ""

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
        primJson = YJson.toJson(prim, codec: PrimitiveBeanJson)

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
        collLargeArrJson = YJson.toJson(collLargeArr, codec: CollectionBeanJson)

        collSmallMap = CollectionBean()
        collSmallMap.intMap = t9BuildIntMap(10)

        collLargeMap = CollectionBean()
        collLargeMap.intMap = t9BuildIntMap(100)
        collLargeMapJson = YJson.toJson(collLargeMap, codec: CollectionBeanJson)

        nestedColl = NestedCollBean()
        for (i in 0..10) { nestedColl.data.add("k${i}", t9BuildIntArray(10)) }
        nestedCollJson = YJson.toJson(nestedColl, codec: NestedCollBeanJson)

        collLargeFloatArr = FloatArrayBean()
        collLargeFloatArr.f64Array = t9BuildFloat64Array(1000)

        // T9.4
        deep = DeepNested()
        deep.level1.value = "L1"
        deep.level1.level2.value = "L2"
        deep.level1.level2.level3.value = "L3"
        deep.level1.level2.level3.count = 99
        deepJson = YJson.toJson(deep, codec: DeepNestedJson)

        wide = WideNested()
        wide.f1 = 1
        wide.f3 = 3.14
        wide.f4 = true
        wide.f6 = 6
        wide.f20 = "wide"
        wideJson = YJson.toJson(wide, codec: WideNestedJson)

        ultra = UltraWide()
        ultraJson = YJson.toJson(ultra, codec: UltraWideJson)

        // E2E: LargeBean
        large = E2ELargeBean()
        large.description = t9BuildLongStr(200)
        large.tags = t9BuildTagArray(20)
        large.scores = t9BuildIntArray(100)
        large.meta = t9BuildStrMap(20)
        largeJson = YJson.toJson(large, codec: E2ELargeBeanJson)

        // E2E: BigString
        big = E2EBigString()
        big.blob = t9BuildLongStr(32768)
        let chunk = t9BuildLongStr(256)
        let chunksList = ArrayList<String>()
        for (_ in 0..32) { chunksList.add(chunk) }
        big.chunks = chunksList.toArray()
        bigJson = YJson.toJson(big, codec: E2EBigStringJson)

        // E2E: PerfLargeList (200 × 110 fields) — commented out due to compiler optimizer crash
        // let items = ArrayList<PerfLargeItem>()
        // for (i in 0..200) { items.add(t9BuildLargeItem(Int64(i))) }
        // perfList = PerfLargeList()
        // perfList.items = items.toArray()
        // perfListJson = YJson.toJson(perfList, codec: PerfLargeListJson)
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
        optionJson = YJson.toJson(optionFull, codec: OptionBeanJson)

        emptyBean = EmptyBean()
        emptyJson = YJson.toJson(emptyBean, codec: EmptyBeanJson)

        extBean = ExtremeBean()
        extBean.a = Int64.Max
        extBean.b = Int64.Min
        extJson = YJson.toJson(extBean, codec: ExtremeBeanJson)

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
        largeDocJson = YJson.toJson(largeDoc, codec: LargeDocJson)

        let grid = ArrayList<Array<Int64>>()
        for (_ in 0..50) {
            grid.add(t9BuildIntArray(20))
        }
        matrixBean = MatrixBean()
        matrixBean.grid = grid.toArray()
        matrixJson = YJson.toJson(matrixBean, codec: MatrixBeanJson)

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
    }

    // ---------- T9.1 ----------

    @Bench
    func t9_1_1_primitiveSerialize() {
        strSink = YJson.toJson(prim, codec: PrimitiveBeanJson)
    }

    @Bench
    func t9_1_2_primitiveDeserialize() {
        sink = YJson.fromJson(primJson, codec: PrimitiveBeanJson).i64
    }

    @Bench
    func t9_1_3_primitiveRoundTrip() {
        let json = YJson.toJson(prim, codec: PrimitiveBeanJson)
        sink = YJson.fromJson(json, codec: PrimitiveBeanJson).i64
    }

    // ---------- T9.2 ----------


    @Bench
    func t9_2_1_shortStringSerialize() {
        strSink = YJson.toJson(strShort, codec: StringBeanJson)
    }

    @Bench
    func t9_2_2_longStringSerialize() {
        strSink = YJson.toJson(strLong, codec: StringBeanJson)
    }

    @Bench
    func t9_2_3_escapeStringSerialize() {
        strSink = YJson.toJson(strEscape, codec: StringBeanJson)
    }

    @Bench
    func t9_2_4_unicodeStringSerialize() {
        strSink = YJson.toJson(strUnicode, codec: StringBeanJson)
    }

    // ---------- T9.3 ----------

    @Bench
    func t9_3_1_smallArraySerialize() {
        strSink = YJson.toJson(collSmallArr, codec: CollectionBeanJson)
    }

    @Bench
    func t9_3_2_largeArraySerialize() {
        strSink = YJson.toJson(collLargeArr, codec: CollectionBeanJson)
    }

    @Bench
    func t9_3_3_largeArrayDeserialize() {
        sink = Int64(YJson.fromJson(collLargeArrJson, codec: CollectionBeanJson).intArray.size)
    }

    @Bench
    func t9_3_4_smallMapSerialize() {
        strSink = YJson.toJson(collSmallMap, codec: CollectionBeanJson)
    }

    @Bench
    func t9_3_5_largeMapSerialize() {
        strSink = YJson.toJson(collLargeMap, codec: CollectionBeanJson)
    }

    @Bench
    func t9_3_6_largeMapDeserialize() {
        sink = Int64(YJson.fromJson(collLargeMapJson, codec: CollectionBeanJson).intMap.size)
    }

    @Bench
    func t9_3_7_nestedCollectionSerialize() {
        strSink = YJson.toJson(nestedColl, codec: NestedCollBeanJson)
    }

    @Bench
    func t9_3_8_nestedCollectionDeserialize() {
        sink = Int64(YJson.fromJson(nestedCollJson, codec: NestedCollBeanJson).data.size)
    }

    @Bench
    func t9_3_9_largeFloat64ArraySerialize() {
        strSink = YJson.toJson(collLargeFloatArr, codec: FloatArrayBeanJson)
    }

    // ---------- T9.4 ----------

    @Bench
    func t9_4_1_deepNestedSerialize() {
        strSink = YJson.toJson(deep, codec: DeepNestedJson)
    }

    @Bench
    func t9_4_2_deepNestedDeserialize() {
        sink = YJson.fromJson(deepJson, codec: DeepNestedJson).level1.level2.level3.count
    }

    @Bench
    func t9_4_3_wideSerialize() {
        strSink = YJson.toJson(wide, codec: WideNestedJson)
    }

    @Bench
    func t9_4_4_wideDeserialize() {
        sink = YJson.fromJson(wideJson, codec: WideNestedJson).f1
    }

    @Bench
    func t9_4_5_ultraWideSerialize() {
        strSink = YJson.toJson(ultra, codec: UltraWideJson)
    }

    @Bench
    func t9_4_6_ultraWideDeserialize() {
        sink = YJson.fromJson(ultraJson, codec: UltraWideJson).f49
    }

    // ---------- T9.5 coverage (matrix expansion) ----------

    @Bench
    func t9_5_1_optionSerialize() {
        strSink = YJson.toJson(optionMixed, codec: OptionBeanJson)
    }

    @Bench
    func t9_5_2_optionDeserialize() {
        sink = (YJson.fromJson(optionJson, codec: OptionBeanJson).count ?? 0)
    }

    @Bench
    func t9_5_3_optionRoundTrip() {
        let json = YJson.toJson(optionFull, codec: OptionBeanJson)
        sink = (YJson.fromJson(json, codec: OptionBeanJson).count ?? 0)
    }

    @Bench
    func t9_5_4_emptyContainersSerialize() {
        strSink = YJson.toJson(emptyBean, codec: EmptyBeanJson)
    }

    @Bench
    func t9_5_5_emptyContainersDeserialize() {
        sink = Int64(YJson.fromJson(emptyJson, codec: EmptyBeanJson).arr.size)
    }

    @Bench
    func t9_5_6_int64ExtremesSerialize() {
        strSink = YJson.toJson(extBean, codec: ExtremeBeanJson)
    }

    @Bench
    func t9_5_7_int64ExtremesDeserialize() {
        sink = YJson.fromJson(extJson, codec: ExtremeBeanJson).a
    }

    @Bench
    func t9_5_8_unknownFieldDeserialize() {
        sink = Int64(YJson.fromJson(unknownPayload, codec: CollectionBeanJson).intArray.size)
    }

    @Bench
    func t9_5_9_largeDocumentSerialize() {
        strSink = YJson.toJson(largeDoc, codec: LargeDocJson)
    }

    @Bench
    func t9_5_10_largeDocumentDeserialize() {
        sink = Int64(YJson.fromJson(largeDocJson, codec: LargeDocJson).items.size)
    }

    @Bench
    func t9_5_11_arrayOfArraySerialize() {
        strSink = YJson.toJson(matrixBean, codec: MatrixBeanJson)
    }

    @Bench
    func t9_5_12_arrayOfArrayDeserialize() {
        sink = Int64(YJson.fromJson(matrixJson, codec: MatrixBeanJson).grid.size)
    }

    @Bench
    func t9_5_13_prettyWideDeserialize() {
        sink = YJson.fromJson(prettyWideJson, codec: WideNestedJson).f1
    }

    // ---------- E2E: LargeBean ----------

    @Bench
    func largeBean_serialize() {
        strSink = YJson.toJson(large, codec: E2ELargeBeanJson)
    }

    @Bench
    func largeBean_deserialize() {
        sink = YJson.fromJson(largeJson, codec: E2ELargeBeanJson).id
    }

    // ---------- E2E: BigString ----------

    @Bench
    func bigString_serialize() {
        strSink = YJson.toJson(big, codec: E2EBigStringJson)
    }

    @Bench
    func bigString_deserialize() {
        sink = YJson.fromJson(bigJson, codec: E2EBigStringJson).id
    }

    // ---------- E2E: PerfLargeList (200×110 fields) — commented out due to compiler optimizer crash ----------

    // @Bench
    // func perfLargeList_serialize() {
    //     strSink = YJson.toJson(perfList, codec: PerfLargeListJson)
    // }

    // @Bench
    // func perfLargeList_deserialize() {
    //     sink = Int64(YJson.fromJson(perfListJson, codec: PerfLargeListJson).items.size)
    // }
}

// ==================== Bytes/stream track (three-library suite; cjjson has no bytes API) ====================

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class BytesBench {
    let prim: PrimitiveBean
    let primJson: String
    let largeDoc: LargeDoc
    let largeDocJson: String

    var sink: Int64 = 0

    init() {
        prim = PrimitiveBean()
        prim.i8 = 1
        prim.i16 = 2
        prim.i32 = 3
        prim.i64 = 4
        prim.f64 = 3.14
        prim.flag = true
        prim.text = "hello"
        primJson = YJson.toJson(prim, codec: PrimitiveBeanJson)

        largeDoc = LargeDoc()
        let items = ArrayList<LargeDocItem>()
        let desc64 = t9BuildLongStr(64)
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
        largeDoc.items = items.toArray()
        largeDoc.index = t9BuildIntMap(2000)
        largeDocJson = YJson.toJson(largeDoc, codec: LargeDocJson)
    }

    @Bench
    func t9_b_1_bytesParsePrimitive() {
        sink = YJson.fromJson(YJsonByteArrayInputStream(primJson), codec: PrimitiveBeanJson).i64
    }

    @Bench
    func t9_b_2_bytesParseLargeDoc() {
        sink = Int64(YJson.fromJson(YJsonByteArrayInputStream(largeDocJson), codec: LargeDocJson).items.size)
    }

    @Bench
    func t9_b_3_streamLargeDoc() {
        sink = Int64(YJson.fromJson(YJsonByteArrayInputStream(unsafe { largeDocJson.rawData() }), codec: LargeDocJson).items.size)
    }
}
