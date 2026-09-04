package json4cj_databind.test.macros_test

import std.unittest.*
import std.unittest.testmacro.*
import std.io.ByteBuffer
import std.collection.*
import json4cj_annotations.macros.*
import json4cj_core.*

/**
 * T9.1 ~ T9.4 吞吐量基准（对标 Jackson，execution-plan §9.9）。
 *
 * 路径选择：Jackson 默认流式，故序列化用宏流式 encode(writer)、反序列化用 decode(reader)。
 * ops/ms = 1000 / median(μs)。每用例写入 sink 防死代码消除。
 * 大对象/大集合在 init 中预建，反序列化用例预生成 JSON 串。
 */

// ==================== T9.1 PrimitiveBean ====================

@Codable[fixedSchema]
class PrimitiveBean {
    var i8: Int8 = 0
    var i16: Int16 = 0
    var i32: Int32 = 0
    var i64: Int64 = 0
    var f64: Float64 = 0.0
    var flag: Bool = false
    var text: String = ""
    public init() {}
}

// ==================== T9.2 StringBean ====================

@Codable
class StringBean {
    var s1: String = ""
    var s2: String = ""
    var s3: String = ""
    var s4: String = ""
    var s5: String = ""
    var s6: String = ""
    var s7: String = ""
    var s8: String = ""
    public init() {}
}

// ==================== T9.3 CollectionBean ====================

@Codable
class CollectionBean {
    var intArray: Array<Int64> = Array<Int64>()
    var strArray: Array<String> = Array<String>()
    // The deserialize benchmark below uses a 100-entry JSON object.  Keep
    // this explicit capacity hint scoped to the benchmark schema.
    @CodableMapCapacity[100]
    var intMap: HashMap<String, Int64> = HashMap<String, Int64>()
    var strMap: HashMap<String, String> = HashMap<String, String>()
    public init() {}
}

@Codable
class NestedCollBean {
    var data: HashMap<String, Array<Int64>> = HashMap<String, Array<Int64>>()
    public init() {}
}

@Codable
class FloatArrayBean {
    var f64Array: Array<Float64> = Array<Float64>()
    public init() {}
}

// ==================== T9.4 嵌套对象 ====================

@Codable[fixedSchema]
class DeepNested {
    var level1: Level1 = Level1()
    public init() {}
}

@Codable[fixedSchema]
class Level1 {
    var value: String = ""
    var level2: Level2 = Level2()
    public init() {}
}

@Codable[fixedSchema]
class Level2 {
    var value: String = ""
    var level3: Level3 = Level3()
    public init() {}
}

@Codable[fixedSchema]
class Level3 {
    var value: String = ""
    var count: Int64 = 0
    public init() {}
}

@Codable[fixedSchema]
class WideNested {
    var f1: Int64 = 0
    var f2: String = ""
    var f3: Float64 = 0.0
    var f4: Bool = false
    var f5: String = ""
    var f6: Int64 = 0
    var f7: String = ""
    var f8: Float64 = 0.0
    var f9: Bool = false
    var f10: String = ""
    var f11: Int64 = 0
    var f12: String = ""
    var f13: Float64 = 0.0
    var f14: Bool = false
    var f15: String = ""
    var f16: Int64 = 0
    var f17: String = ""
    var f18: Float64 = 0.0
    var f19: Bool = false
    var f20: String = ""
    public init() {}
}

@Codable[fixedSchema]
class UltraWide {
    var f0: Int64 = 0
    var f1: Int64 = 0
    var f2: Int64 = 0
    var f3: Int64 = 0
    var f4: Int64 = 0
    var f5: Int64 = 0
    var f6: Int64 = 0
    var f7: Int64 = 0
    var f8: Int64 = 0
    var f9: Int64 = 0
    var f10: Int64 = 0
    var f11: Int64 = 0
    var f12: Int64 = 0
    var f13: Int64 = 0
    var f14: Int64 = 0
    var f15: Int64 = 0
    var f16: Int64 = 0
    var f17: Int64 = 0
    var f18: Int64 = 0
    var f19: Int64 = 0
    var f20: Int64 = 0
    var f21: Int64 = 0
    var f22: Int64 = 0
    var f23: Int64 = 0
    var f24: Int64 = 0
    var f25: Int64 = 0
    var f26: Int64 = 0
    var f27: Int64 = 0
    var f28: Int64 = 0
    var f29: Int64 = 0
    var f30: Int64 = 0
    var f31: Int64 = 0
    var f32: Int64 = 0
    var f33: Int64 = 0
    var f34: Int64 = 0
    var f35: Int64 = 0
    var f36: Int64 = 0
    var f37: Int64 = 0
    var f38: Int64 = 0
    var f39: Int64 = 0
    var f40: Int64 = 0
    var f41: Int64 = 0
    var f42: Int64 = 0
    var f43: Int64 = 0
    var f44: Int64 = 0
    var f45: Int64 = 0
    var f46: Int64 = 0
    var f47: Int64 = 0
    var f48: Int64 = 0
    var f49: Int64 = 0
    public init() {}
}

/**
 * Same fixed 50-field JSON schema as UltraWide, but as a value-type DTO.
 * This is the performance case for the HandleStruct compact-schema emitter.
 */
@Codable
struct UltraWideStruct {
    var f0: Int64 = 0
    var f1: Int64 = 0
    var f2: Int64 = 0
    var f3: Int64 = 0
    var f4: Int64 = 0
    var f5: Int64 = 0
    var f6: Int64 = 0
    var f7: Int64 = 0
    var f8: Int64 = 0
    var f9: Int64 = 0
    var f10: Int64 = 0
    var f11: Int64 = 0
    var f12: Int64 = 0
    var f13: Int64 = 0
    var f14: Int64 = 0
    var f15: Int64 = 0
    var f16: Int64 = 0
    var f17: Int64 = 0
    var f18: Int64 = 0
    var f19: Int64 = 0
    var f20: Int64 = 0
    var f21: Int64 = 0
    var f22: Int64 = 0
    var f23: Int64 = 0
    var f24: Int64 = 0
    var f25: Int64 = 0
    var f26: Int64 = 0
    var f27: Int64 = 0
    var f28: Int64 = 0
    var f29: Int64 = 0
    var f30: Int64 = 0
    var f31: Int64 = 0
    var f32: Int64 = 0
    var f33: Int64 = 0
    var f34: Int64 = 0
    var f35: Int64 = 0
    var f36: Int64 = 0
    var f37: Int64 = 0
    var f38: Int64 = 0
    var f39: Int64 = 0
    var f40: Int64 = 0
    var f41: Int64 = 0
    var f42: Int64 = 0
    var f43: Int64 = 0
    var f44: Int64 = 0
    var f45: Int64 = 0
    var f46: Int64 = 0
    var f47: Int64 = 0
    var f48: Int64 = 0
    var f49: Int64 = 0
    public init() {}
}

// Equivalent to the pre-compact HandleStruct emitter for this fixed schema:
// static names and scalar values still use their existing fast APIs, while
// the writer performs the regular object/field state transitions.
func encodeUltraWideStructRegular(value: UltraWideStruct, writer: JsonWriter): Unit {
    writer.startObject()
    writer.writeStaticInt64Field("f0", value.f0)
    writer.writeStaticInt64Field("f1", value.f1)
    writer.writeStaticInt64Field("f2", value.f2)
    writer.writeStaticInt64Field("f3", value.f3)
    writer.writeStaticInt64Field("f4", value.f4)
    writer.writeStaticInt64Field("f5", value.f5)
    writer.writeStaticInt64Field("f6", value.f6)
    writer.writeStaticInt64Field("f7", value.f7)
    writer.writeStaticInt64Field("f8", value.f8)
    writer.writeStaticInt64Field("f9", value.f9)
    writer.writeStaticInt64Field("f10", value.f10)
    writer.writeStaticInt64Field("f11", value.f11)
    writer.writeStaticInt64Field("f12", value.f12)
    writer.writeStaticInt64Field("f13", value.f13)
    writer.writeStaticInt64Field("f14", value.f14)
    writer.writeStaticInt64Field("f15", value.f15)
    writer.writeStaticInt64Field("f16", value.f16)
    writer.writeStaticInt64Field("f17", value.f17)
    writer.writeStaticInt64Field("f18", value.f18)
    writer.writeStaticInt64Field("f19", value.f19)
    writer.writeStaticInt64Field("f20", value.f20)
    writer.writeStaticInt64Field("f21", value.f21)
    writer.writeStaticInt64Field("f22", value.f22)
    writer.writeStaticInt64Field("f23", value.f23)
    writer.writeStaticInt64Field("f24", value.f24)
    writer.writeStaticInt64Field("f25", value.f25)
    writer.writeStaticInt64Field("f26", value.f26)
    writer.writeStaticInt64Field("f27", value.f27)
    writer.writeStaticInt64Field("f28", value.f28)
    writer.writeStaticInt64Field("f29", value.f29)
    writer.writeStaticInt64Field("f30", value.f30)
    writer.writeStaticInt64Field("f31", value.f31)
    writer.writeStaticInt64Field("f32", value.f32)
    writer.writeStaticInt64Field("f33", value.f33)
    writer.writeStaticInt64Field("f34", value.f34)
    writer.writeStaticInt64Field("f35", value.f35)
    writer.writeStaticInt64Field("f36", value.f36)
    writer.writeStaticInt64Field("f37", value.f37)
    writer.writeStaticInt64Field("f38", value.f38)
    writer.writeStaticInt64Field("f39", value.f39)
    writer.writeStaticInt64Field("f40", value.f40)
    writer.writeStaticInt64Field("f41", value.f41)
    writer.writeStaticInt64Field("f42", value.f42)
    writer.writeStaticInt64Field("f43", value.f43)
    writer.writeStaticInt64Field("f44", value.f44)
    writer.writeStaticInt64Field("f45", value.f45)
    writer.writeStaticInt64Field("f46", value.f46)
    writer.writeStaticInt64Field("f47", value.f47)
    writer.writeStaticInt64Field("f48", value.f48)
    writer.writeStaticInt64Field("f49", value.f49)
    writer.endObject()
}

// ==================== T9.5 coverage beans (matrix expansion) ====================

@Codable
class InnerBean {
    var id: Int64 = 0
    var label: String = ""
    var score: Int64 = 0
    public init() {}
}

@Codable
class OptionBean {
    var name: ?String = None
    var count: ?Int64 = None
    var inner: ?InnerBean = None
    var tag: ?String = None
    public init() {}
}

@Codable
class EmptyBean {
    var arr: Array<Int64> = Array<Int64>()
    var m: HashMap<String, Int64> = HashMap<String, Int64>()
    var strs: Array<String> = Array<String>()
    var inner: InnerBean = InnerBean()
    public init() {}
}

@Codable
class ExtremeBean {
    var a: Int64 = 0
    var b: Int64 = 0
    var c: Int64 = -1
    var d: Int64 = 0
    var e: Int64 = 1
    public init() {}
}

@Codable
class LargeDocItem {
    var id: Int64 = 0
    var sku: String = ""
    var name: String = ""
    var desc: String = ""
    var price: Int64 = 0
    var stock: Int64 = 0
    var active: Bool = false
    var score: Int64 = 0
    var cat: String = ""
    var rank: Int64 = 0
    public init() {}
}

@Codable
class LargeDoc {
    var items: Array<LargeDocItem> = Array<LargeDocItem>()
    @CodableMapCapacity[2000]
    var index: HashMap<String, Int64> = HashMap<String, Int64>()
    public init() {}
}

@Codable
class MatrixBean {
    var grid: Array<Array<Int64>> = Array<Array<Int64>>()
    public init() {}
}

// ==================== 辅助 ====================

func buildLongStr(n: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..n) {
        sb.append(Rune(97))
    }
    return sb.toString()
}

func buildIntArray(n: Int64): Array<Int64> {
    let arr = ArrayList<Int64>()
    for (i in 0..n) {
        arr.add(i)
    }
    return arr.toArray()
}

func buildFloat64Array(n: Int64): Array<Float64> {
    let arr = ArrayList<Float64>()
    for (i in 0..n) {
        arr.add(Float64(i) * 3.14)
    }
    return arr.toArray()
}

func buildIntMap(n: Int64): HashMap<String, Int64> {
    let m = HashMap<String, Int64>()
    for (i in 0..n) {
        m.add("key${i}", i)
    }
    return m
}

func jsonReaderOf(json: String): JsonReader {
    let buf = ByteBuffer()
    unsafe { buf.write(json.rawData()) }
    return JsonReader(buf)
}

// ==================== 基准类 ====================

@Test
class T9ThroughputBench {
    // T9.1
    let prim: PrimitiveBean
    let primJson: String

    // T9.2 四实例
    let strShort: StringBean
    let strLong: StringBean
    let strEscape: StringBean
    let strUnicode: StringBean

    // T9.3
    let collSmallArr: CollectionBean
    let collLargeArr: CollectionBean
    let collLargeArrJson: String
    let collLargeArrBytes: Array<Byte>
    let collSmallMap: CollectionBean
    let collLargeMap: CollectionBean
    let collLargeMapJson: String
    let collLargeMapBytes: Array<Byte>
    let nestedColl: NestedCollBean
    let nestedCollJson: String
    let nestedCollBytes: Array<Byte>
    let collLargeFloatArr: FloatArrayBean

    // T9.4
    let deep: DeepNested
    let deepJson: String
    let wide: WideNested
    let wideJson: String
    let ultra: UltraWide
    let ultraJson: String
    let ultraStruct: UltraWideStruct

    // P4 service-style metric. This writer is intentionally stateful and is
    // only used by the explicit reuse benchmark below; normal T9 cases keep
    // constructing a writer so their Java comparison remains one-shot.
    let reusablePrimBuf: ByteBuffer
    let reusablePrimWriter: JsonWriter
    let optionMixed: OptionBean
    let optionFull: OptionBean
    let optionJson: String
    let emptyBean: EmptyBean
    let emptyJson: String
    let extBean: ExtremeBean
    let extJson: String
    let largeDoc: LargeDoc
    let largeDocJson: String
    let largeDocBytes: Array<Byte>
    let matrixBean: MatrixBean
    let matrixJson: String
    let unknownPayload: String
    let prettyWideJson: String
    let primBytes: Array<Byte>

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
        let shortBase = "abc123"
        strShort = StringBean()
        strShort.s1 = shortBase
        strShort.s2 = "name"
        strShort.s3 = "value"
        strShort.s4 = "test"
        strShort.s5 = "data"
        strShort.s6 = "item"
        strShort.s7 = "code"
        strShort.s8 = "desc"

        let longBase = buildLongStr(1000)
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
        collSmallArr.intArray = buildIntArray(10)

        collLargeArr = CollectionBean()
        collLargeArr.intArray = buildIntArray(1000)
        collLargeArrJson = collLargeArr.toJson()
        collLargeArrBytes = collLargeArrJson.toArray()

        collSmallMap = CollectionBean()
        collSmallMap.intMap = buildIntMap(10)

        collLargeMap = CollectionBean()
        collLargeMap.intMap = buildIntMap(100)
        collLargeMapJson = collLargeMap.toJson()
        collLargeMapBytes = collLargeMapJson.toArray()

        nestedColl = NestedCollBean()
        for (i in 0..10) {
            nestedColl.data.add("k${i}", buildIntArray(10))
        }
        nestedCollJson = nestedColl.toJson()
        nestedCollBytes = nestedCollJson.toArray()

        // T9.3.9 large Float64 array
        collLargeFloatArr = FloatArrayBean()
        collLargeFloatArr.f64Array = buildFloat64Array(1000)

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
        wide.f20 = "wide"
        wideJson = wide.toJson()

        ultra = UltraWide()
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

        let desc64 = buildLongStr(64)
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
        largeDoc.index = buildIntMap(2000)
        largeDocJson = largeDoc.toJson()
        largeDocBytes = largeDocJson.toArray()

        let grid = ArrayList<Array<Int64>>()
        for (_ in 0..50) {
            grid.add(buildIntArray(20))
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
        primBytes = primJson.toArray()
        ultraJson = ultra.toJson()
        ultraStruct = UltraWideStruct()

        reusablePrimBuf = ByteBuffer()
        reusablePrimWriter = JsonWriter(reusablePrimBuf)
    }

    // ---------- T9.1 基础类型 ----------

    @Bench
    func t9_1_1_primitiveSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        prim.encode(w)
        sink = w.toString().size
    }

    /**
     * P4-only service throughput metric. It is deliberately not part of the
     * cross-language default set because Java's baseline remains one-shot.
     */
    @Bench
    func t9_1_1_primitiveSerialize_reuseString() {
        reusablePrimWriter.reset()
        prim.encode(reusablePrimWriter)
        sink = reusablePrimWriter.toString().size
    }

    @Bench
    func t9_1_2_primitiveDeserialize() {
        let r = jsonReaderOf(primJson)
        let o = PrimitiveBean.decode(r)
        sink = o.i64
    }

    @Bench
    func t9_1_3_primitiveRoundTrip() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        prim.encode(w)
        let json = w.toString()
        let r = jsonReaderOf(json)
        let o = PrimitiveBean.decode(r)
        sink = o.i64
    }

    // ---------- T9.2 字符串密集型 ----------

    @Bench
    func t9_2_1_shortStringSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        strShort.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_2_2_longStringSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        strLong.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_2_3_escapeStringSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        strEscape.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_2_4_unicodeStringSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        strUnicode.encode(w)
        sink = w.toString().size
    }

    // ---------- T9.3 集合 ----------

    @Bench
    func t9_3_1_smallArraySerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        collSmallArr.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_3_2_largeArraySerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        collLargeArr.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_3_3_largeArrayDeserialize() {
        let r = jsonReaderOf(collLargeArrJson)
        let o = CollectionBean.decode(r)
        sink = o.intArray.size
    }

    // P0 diagnostic: input bytes have already been acquired by the caller.
    // It isolates reader construction/materialization from JSON decoding.
    @Bench
    func t9_3_3_largeArrayDeserialize_bytesInput() {
        let r = JsonStreamFactory.createReader(collLargeArrBytes)
        let o = CollectionBean.decode(r)
        sink = o.intArray.size
    }

    @Bench
    func t9_3_4_smallMapSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        collSmallMap.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_3_5_largeMapSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        collLargeMap.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_3_6_largeMapDeserialize() {
        let r = jsonReaderOf(collLargeMapJson)
        let o = CollectionBean.decode(r)
        sink = o.intMap.size
    }

    @Bench
    func t9_3_6_largeMapDeserialize_bytesInput() {
        let r = JsonStreamFactory.createReader(collLargeMapBytes)
        let o = CollectionBean.decode(r)
        sink = o.intMap.size
    }

    @Bench
    func t9_3_7_nestedCollectionSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        nestedColl.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_3_8_nestedCollectionDeserialize() {
        let r = jsonReaderOf(nestedCollJson)
        let o = NestedCollBean.decode(r)
        sink = o.data.size
    }

    @Bench
    func t9_3_8_nestedCollectionDeserialize_bytesInput() {
        let r = JsonStreamFactory.createReader(nestedCollBytes)
        let o = NestedCollBean.decode(r)
        sink = o.data.size
    }

    @Bench
    func t9_3_9_largeFloat64ArraySerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        collLargeFloatArr.encode(w)
        sink = w.toString().size
    }

    // ---------- T9.4 嵌套对象 ----------

    @Bench
    func t9_4_1_deepNestedSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        deep.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_4_2_deepNestedDeserialize() {
        let r = jsonReaderOf(deepJson)
        let o = DeepNested.decode(r)
        sink = o.level1.level2.level3.count
    }

    @Bench
    func t9_4_3_wideSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        wide.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_4_4_wideDeserialize() {
        let r = jsonReaderOf(wideJson)
        let o = WideNested.decode(r)
        sink = o.f1
    }

    @Bench
    func t9_4_5_ultraWideSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        ultra.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_4_6_ultraWideDeserialize() {
        let r = jsonReaderOf(ultraJson)
        let o = UltraWide.decode(r)
        sink = o.f49
    }

    // ---------- T9.5 coverage (matrix expansion) ----------

    @Bench
    func t9_5_1_optionSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        optionMixed.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_5_2_optionDeserialize() {
        let r = jsonReaderOf(optionJson)
        let o = OptionBean.decode(r)
        sink = (o.count ?? 0)
    }

    @Bench
    func t9_5_3_optionRoundTrip() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        optionFull.encode(w)
        let json = w.toString()
        let r = jsonReaderOf(json)
        let o = OptionBean.decode(r)
        sink = (o.count ?? 0)
    }

    @Bench
    func t9_5_4_emptyContainersSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        emptyBean.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_5_5_emptyContainersDeserialize() {
        let r = jsonReaderOf(emptyJson)
        let o = EmptyBean.decode(r)
        sink = o.arr.size
    }

    @Bench
    func t9_5_6_int64ExtremesSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        extBean.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_5_7_int64ExtremesDeserialize() {
        let r = jsonReaderOf(extJson)
        let o = ExtremeBean.decode(r)
        sink = o.a
    }

    @Bench
    func t9_5_8_unknownFieldDeserialize() {
        let r = jsonReaderOf(unknownPayload)
        let o = CollectionBean.decode(r)
        sink = o.intArray.size
    }

    @Bench
    func t9_5_9_largeDocumentSerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        largeDoc.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_5_10_largeDocumentDeserialize() {
        let r = jsonReaderOf(largeDocJson)
        let o = LargeDoc.decode(r)
        sink = o.items.size
    }

    @Bench
    func t9_5_11_arrayOfArraySerialize() {
        let buf = ByteBuffer()
        let w = JsonWriter(buf)
        matrixBean.encode(w)
        sink = w.toString().size
    }

    @Bench
    func t9_5_12_arrayOfArrayDeserialize() {
        let r = jsonReaderOf(matrixJson)
        let o = MatrixBean.decode(r)
        sink = o.grid.size
    }

    @Bench
    func t9_5_13_prettyWideDeserialize() {
        let r = jsonReaderOf(prettyWideJson)
        let o = WideNested.decode(r)
        sink = o.f1
    }

    // ---------- 输出物化诊断 ----------
    // writerBytes 只测写入 ByteBuffer；bytes 物化独立 Array<Byte>；string 物化 String。

    @Bench
    func t9_1_1_primitiveSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); prim.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_1_1_primitiveSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); prim.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_1_1_primitiveSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); prim.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_2_1_shortStringSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strShort.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_2_1_shortStringSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strShort.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_2_1_shortStringSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strShort.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_2_2_longStringSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strLong.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_2_2_longStringSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strLong.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_2_2_longStringSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strLong.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_2_3_escapeStringSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strEscape.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_2_3_escapeStringSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strEscape.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_2_3_escapeStringSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strEscape.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_2_4_unicodeStringSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strUnicode.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_2_4_unicodeStringSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strUnicode.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_2_4_unicodeStringSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); strUnicode.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_1_smallArraySerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallArr.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_1_smallArraySerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallArr.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_1_smallArraySerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallArr.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_2_largeArraySerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeArr.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_2_largeArraySerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeArr.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_2_largeArraySerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeArr.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_4_smallMapSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallMap.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_4_smallMapSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallMap.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_4_smallMapSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collSmallMap.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_5_largeMapSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeMap.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_5_largeMapSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeMap.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_5_largeMapSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeMap.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_7_nestedCollectionSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); nestedColl.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_7_nestedCollectionSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); nestedColl.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_7_nestedCollectionSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); nestedColl.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_3_9_largeFloat64ArraySerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeFloatArr.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_3_9_largeFloat64ArraySerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeFloatArr.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_3_9_largeFloat64ArraySerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); collLargeFloatArr.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_4_1_deepNestedSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); deep.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_4_1_deepNestedSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); deep.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_4_1_deepNestedSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); deep.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_4_3_wideSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); wide.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_4_3_wideSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); wide.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_4_3_wideSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); wide.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_4_5_ultraWideSerialize_writerBytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); ultra.encode(w); w.flush(); sink = buf.bytes().size
    }
    @Bench
    func t9_4_5_ultraWideSerialize_bytes() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); ultra.encode(w); sink = w.toBytes().size
    }
    @Bench
    func t9_4_5_ultraWideSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); ultra.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_4_s1_ultraWideStructSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); ultraStruct.encode(w); sink = w.toString().size
    }

    @Bench
    func t9_4_s2_ultraWideStructRegularSerialize_string() {
        let buf = ByteBuffer(); let w = JsonWriter(buf); encodeUltraWideStructRegular(ultraStruct, w); sink = w.toString().size
    }
}


@Test
class BytesBench {
    let prim: PrimitiveBean
    let primJson: String
    let primBytes: Array<Byte>
    let largeDoc: LargeDoc
    let largeDocJson: String
    let largeDocBytes: Array<Byte>

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
        primJson = prim.toJson()
        primBytes = primJson.toArray()

        largeDoc = LargeDoc()
        let items = ArrayList<LargeDocItem>()
        let desc64 = buildLongStr(64)
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
        largeDoc.index = buildIntMap(2000)
        largeDocJson = largeDoc.toJson()
        largeDocBytes = largeDocJson.toArray()
    }

    @Bench
    func t9_b_1_bytesParsePrimitive() {
        let r = JsonStreamFactory.createReader(primBytes)
        let o = PrimitiveBean.decode(r)
        sink = o.i64
    }

    @Bench
    func t9_b_2_bytesParseLargeDoc() {
        let r = JsonStreamFactory.createReader(largeDocBytes)
        let o = LargeDoc.decode(r)
        sink = o.items.size
    }

    @Bench
    func t9_b_3_streamLargeDoc() {
        let buf = ByteBuffer()
        unsafe { buf.write(largeDocJson.rawData()) }
        let r = JsonStreamFactory.createReader(buf)
        let o = LargeDoc.decode(r)
        sink = o.items.size
    }
}
