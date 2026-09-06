package yjson

import yjson_macros.*
import std.collection.*
import std.math.numeric.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@JsonCodec
class PrimitiveContainerBulkMatrix {
    public var arrayBool: Array<Bool> = Array<Bool>()
    public var arrayInt8: Array<Int8> = Array<Int8>()
    public var arrayInt16: Array<Int16> = Array<Int16>()
    public var arrayInt32: Array<Int32> = Array<Int32>()
    public var arrayInt64: Array<Int64> = Array<Int64>()
    public var arrayUInt8: Array<UInt8> = Array<UInt8>()
    public var arrayUInt16: Array<UInt16> = Array<UInt16>()
    public var arrayUInt32: Array<UInt32> = Array<UInt32>()
    public var arrayUInt64: Array<UInt64> = Array<UInt64>()
    public var arrayFloat16: Array<Float16> = Array<Float16>()
    public var arrayFloat32: Array<Float32> = Array<Float32>()
    public var arrayFloat64: Array<Float64> = Array<Float64>()
    public var arrayString: Array<String> = Array<String>()

    public var listBool: ArrayList<Bool> = ArrayList<Bool>()
    public var listInt8: ArrayList<Int8> = ArrayList<Int8>()
    public var listInt16: ArrayList<Int16> = ArrayList<Int16>()
    public var listInt32: ArrayList<Int32> = ArrayList<Int32>()
    public var listInt64: ArrayList<Int64> = ArrayList<Int64>()
    public var listUInt8: ArrayList<UInt8> = ArrayList<UInt8>()
    public var listUInt16: ArrayList<UInt16> = ArrayList<UInt16>()
    public var listUInt32: ArrayList<UInt32> = ArrayList<UInt32>()
    public var listUInt64: ArrayList<UInt64> = ArrayList<UInt64>()
    public var listFloat16: ArrayList<Float16> = ArrayList<Float16>()
    public var listFloat32: ArrayList<Float32> = ArrayList<Float32>()
    public var listFloat64: ArrayList<Float64> = ArrayList<Float64>()
    public var listString: ArrayList<String> = ArrayList<String>()

    public var mapBool: HashMap<String, Bool> = HashMap<String, Bool>()
    public var mapInt8: HashMap<String, Int8> = HashMap<String, Int8>()
    public var mapInt16: HashMap<String, Int16> = HashMap<String, Int16>()
    public var mapInt32: HashMap<String, Int32> = HashMap<String, Int32>()
    public var mapInt64: HashMap<String, Int64> = HashMap<String, Int64>()
    public var mapUInt8: HashMap<String, UInt8> = HashMap<String, UInt8>()
    public var mapUInt16: HashMap<String, UInt16> = HashMap<String, UInt16>()
    public var mapUInt32: HashMap<String, UInt32> = HashMap<String, UInt32>()
    public var mapUInt64: HashMap<String, UInt64> = HashMap<String, UInt64>()
    public var mapFloat16: HashMap<String, Float16> = HashMap<String, Float16>()
    public var mapFloat32: HashMap<String, Float32> = HashMap<String, Float32>()
    public var mapFloat64: HashMap<String, Float64> = HashMap<String, Float64>()
    public var mapString: HashMap<String, String> = HashMap<String, String>()

    public var mapArrayBool: HashMap<String, Array<Bool>> = HashMap<String, Array<Bool>>()
    public var mapArrayInt8: HashMap<String, Array<Int8>> = HashMap<String, Array<Int8>>()
    public var mapArrayInt16: HashMap<String, Array<Int16>> = HashMap<String, Array<Int16>>()
    public var mapArrayInt32: HashMap<String, Array<Int32>> = HashMap<String, Array<Int32>>()
    public var mapArrayInt64: HashMap<String, Array<Int64>> = HashMap<String, Array<Int64>>()
    public var mapArrayUInt8: HashMap<String, Array<UInt8>> = HashMap<String, Array<UInt8>>()
    public var mapArrayUInt16: HashMap<String, Array<UInt16>> = HashMap<String, Array<UInt16>>()
    public var mapArrayUInt32: HashMap<String, Array<UInt32>> = HashMap<String, Array<UInt32>>()
    public var mapArrayUInt64: HashMap<String, Array<UInt64>> = HashMap<String, Array<UInt64>>()
    public var mapArrayFloat16: HashMap<String, Array<Float16>> = HashMap<String, Array<Float16>>()
    public var mapArrayFloat32: HashMap<String, Array<Float32>> = HashMap<String, Array<Float32>>()
    public var mapArrayFloat64: HashMap<String, Array<Float64>> = HashMap<String, Array<Float64>>()
    public var mapArrayString: HashMap<String, Array<String>> = HashMap<String, Array<String>>()

    public var mapListBool: HashMap<String, ArrayList<Bool>> = HashMap<String, ArrayList<Bool>>()
    public var mapListInt8: HashMap<String, ArrayList<Int8>> = HashMap<String, ArrayList<Int8>>()
    public var mapListInt16: HashMap<String, ArrayList<Int16>> = HashMap<String, ArrayList<Int16>>()
    public var mapListInt32: HashMap<String, ArrayList<Int32>> = HashMap<String, ArrayList<Int32>>()
    public var mapListInt64: HashMap<String, ArrayList<Int64>> = HashMap<String, ArrayList<Int64>>()
    public var mapListUInt8: HashMap<String, ArrayList<UInt8>> = HashMap<String, ArrayList<UInt8>>()
    public var mapListUInt16: HashMap<String, ArrayList<UInt16>> = HashMap<String, ArrayList<UInt16>>()
    public var mapListUInt32: HashMap<String, ArrayList<UInt32>> = HashMap<String, ArrayList<UInt32>>()
    public var mapListUInt64: HashMap<String, ArrayList<UInt64>> = HashMap<String, ArrayList<UInt64>>()
    public var mapListFloat16: HashMap<String, ArrayList<Float16>> = HashMap<String, ArrayList<Float16>>()
    public var mapListFloat32: HashMap<String, ArrayList<Float32>> = HashMap<String, ArrayList<Float32>>()
    public var mapListFloat64: HashMap<String, ArrayList<Float64>> = HashMap<String, ArrayList<Float64>>()
    public var mapListString: HashMap<String, ArrayList<String>> = HashMap<String, ArrayList<String>>()
    public init() {}
}

@Test
class GeneratedBulkPathRegressionTest {
    @TestCase
    func generatedPrimitiveContainerFamiliesStayOnCompactRawPath(): Unit {
        let value = PrimitiveContainerBulkMatrix()
        value.arrayBool = [true, false]
        value.arrayInt8 = [-1i8, 2i8]
        value.arrayInt16 = [-2, 7]
        value.arrayInt32 = [-3, 8]
        value.arrayInt64 = [-4, 9]
        value.arrayUInt8 = [0u8, UInt8.Max]
        value.arrayUInt16 = [0u16, UInt16.Max]
        value.arrayUInt32 = [0u32, UInt32.Max]
        value.arrayUInt64 = [0u64, UInt64.Max]
        value.arrayFloat16 = [1.5f16, -2.0f16]
        value.arrayFloat32 = [1.5f32, -2.0f32]
        value.arrayFloat64 = [1.5, -2.0]
        value.arrayString = ["a", "b"]

        value.listBool.add(true)
        value.listInt8.add(-1i8)
        value.listInt16.add(-2i16)
        value.listInt32.add(-3i32)
        value.listInt64.add(-4)
        value.listUInt8.add(1u8)
        value.listUInt16.add(2u16)
        value.listUInt32.add(3u32)
        value.listUInt64.add(4u64)
        value.listFloat16.add(1.5f16)
        value.listFloat32.add(1.5f32)
        value.listFloat64.add(1.5)
        value.listString.add("list")

        value.mapBool.add("enabled", true)
        value.mapInt8.add("value", -1i8)
        value.mapInt16.add("value", -2i16)
        value.mapInt32.add("value", -3i32)
        value.mapInt64.add("value", -4)
        value.mapUInt8.add("value", 1u8)
        value.mapUInt16.add("value", 2u16)
        value.mapUInt32.add("value", 3u32)
        value.mapUInt64.add("value", 4u64)
        value.mapFloat16.add("value", 1.5f16)
        value.mapFloat32.add("value", 1.5f32)
        value.mapFloat64.add("value", 1.5)
        value.mapString.add("value", "map")

        value.mapArrayBool.add("items", [true])
        value.mapArrayInt8.add("items", [-1i8])
        value.mapArrayInt16.add("items", [-2i16])
        value.mapArrayInt32.add("items", [-3i32])
        value.mapArrayInt64.add("items", [-4])
        value.mapArrayUInt8.add("items", [1u8])
        value.mapArrayUInt16.add("items", [1u16, UInt16.Max])
        value.mapArrayUInt32.add("items", [3u32])
        value.mapArrayUInt64.add("items", [4u64])
        value.mapArrayFloat16.add("items", [1.5f16])
        value.mapArrayFloat32.add("items", [1.5f32])
        value.mapArrayFloat64.add("items", [1.5])
        value.mapArrayString.add("items", ["array"])

        let listBool = ArrayList<Bool>(); listBool.add(true); value.mapListBool.add("items", listBool)
        let listInt8 = ArrayList<Int8>(); listInt8.add(-1i8); value.mapListInt8.add("items", listInt8)
        let listInt16 = ArrayList<Int16>(); listInt16.add(-2i16); value.mapListInt16.add("items", listInt16)
        let listInt32 = ArrayList<Int32>(); listInt32.add(-3i32); value.mapListInt32.add("items", listInt32)
        let listInt64 = ArrayList<Int64>(); listInt64.add(-4); value.mapListInt64.add("items", listInt64)
        let listUInt8 = ArrayList<UInt8>(); listUInt8.add(1u8); value.mapListUInt8.add("items", listUInt8)
        let listUInt16 = ArrayList<UInt16>(); listUInt16.add(2u16); value.mapListUInt16.add("items", listUInt16)
        let listUInt32 = ArrayList<UInt32>(); listUInt32.add(3u32); value.mapListUInt32.add("items", listUInt32)
        let listUInt64 = ArrayList<UInt64>(); listUInt64.add(4u64); value.mapListUInt64.add("items", listUInt64)
        let listFloat16 = ArrayList<Float16>(); listFloat16.add(1.5f16); value.mapListFloat16.add("items", listFloat16)
        let listFloat32 = ArrayList<Float32>(); listFloat32.add(1.5f32); value.mapListFloat32.add("items", listFloat32)
        let listFloat64 = ArrayList<Float64>(); listFloat64.add(1.5); value.mapListFloat64.add("items", listFloat64)
        let listString = ArrayList<String>(); listString.add("value"); value.mapListString.add("items", listString)

        let text = YJson.toJson(value, codec: PrimitiveContainerBulkMatrixJson)
        let decoded = YJson.fromJson(text, codec: PrimitiveContainerBulkMatrixJson)
        @Expect(YJson.toJson(decoded, codec: PrimitiveContainerBulkMatrixJson), text)

        let bytes = YJson.toJsonBytes(value, codec: PrimitiveContainerBulkMatrixJson)
        @Expect(String.fromUtf8(bytes), text)
        let decodedBytes = YJson.fromJson(bytes, codec: PrimitiveContainerBulkMatrixJson)
        @Expect(YJson.toJson(decodedBytes, codec: PrimitiveContainerBulkMatrixJson), text)

        let input = YJsonByteArrayInputStream(bytes)
        let decodedStream = YJson.fromJson(input, codec: PrimitiveContainerBulkMatrixJson)
        @Expect(YJson.toJson(decodedStream, codec: PrimitiveContainerBulkMatrixJson), text)

        let output = YJsonMemoryOutputStream()
        YJson.writeJson(value, output, codec: PrimitiveContainerBulkMatrixJson)
        @Expect(output.toUtf8String(), text)
    }
}

@JsonCodec
class GeneratedMapInputMatrix {
    public var ints: HashMap<String, Int64> = HashMap<String, Int64>()
    public var arrays: HashMap<String, Array<Int64>> = HashMap<String, Array<Int64>>()
    public init() {}
}

@Test
class GeneratedMapInputRegressionTest {
    @TestCase
    func generatedMapFastReaderKeepsGeneralJsonSyntax(): Unit {
        let text = "{\n" +
            "  \"ints\" : { \"escaped\\\"key\" : -7, \"line\\nkey\" : 2 },\n" +
            "  \"arrays\" : { \"a\\u0062\" : [ 1 , 2 ], \"empty\" : [ ] }\n" +
            "}"
        let decoded = YJson.fromJson(text, codec: GeneratedMapInputMatrixJson)
        @Expect(decoded.ints["escaped\"key"], -7)
        @Expect(decoded.ints["line\nkey"], 2)
        @Expect(decoded.arrays["ab"][1], 2)
        @Expect(decoded.arrays["empty"].isEmpty(), true)
    }
}

@JsonCodec
class CursorMatrixLeaf {
    public let id: Int64
    public let label: String

    public init(id: Int64, label: String) {
        this.id = id
        this.label = label
    }
}

@JsonCodec
enum CursorMatrixEvent {
    Empty | Payload(String, BigInt)
}

@JsonCodec
class ExtendedCursorContainerMatrix {
    public let runes: Array<Rune>
    public let bigInts: ArrayList<BigInt>
    public let decimals: HashMap<String, Decimal>
    @JsonUsing[JsonCodecs.array(JsonCodecs.rfc3339DateTime)]
    public let dates: Array<DateTime>
    public let maybeRunes: Option<Array<Rune>>
    public let leaves: ArrayList<CursorMatrixLeaf>
    public let events: HashMap<String, CursorMatrixEvent>
    public let deep: HashMap<String, ArrayList<Option<Array<Decimal>>>>

    public init(
        runes: Array<Rune>,
        bigInts: ArrayList<BigInt>,
        decimals: HashMap<String, Decimal>,
        dates: Array<DateTime>,
        maybeRunes: Option<Array<Rune>>,
        leaves: ArrayList<CursorMatrixLeaf>,
        events: HashMap<String, CursorMatrixEvent>,
        deep: HashMap<String, ArrayList<Option<Array<Decimal>>>>
    ) {
        this.runes = runes
        this.bigInts = bigInts
        this.decimals = decimals
        this.dates = dates
        this.maybeRunes = maybeRunes
        this.leaves = leaves
        this.events = events
        this.deep = deep
    }
}

@Test
class ExtendedGeneratedCursorPathTest {
    private func hasCursorRead<T>(codec: JsonCodec<T>): Bool {
        match (codec) {
            case _: GeneratedCursorReadCodecV1<T> => true
            case _ => false
        }
    }

    private func hasCursorWrite<T>(codec: JsonCodec<T>): Bool {
        match (codec) {
            case cursor: GeneratedCursorWriteCodecV1<T> => cursor.supportsCompactCursorWrite()
            case _ => false
        }
    }

    private func assertCursorCodec<T>(codec: JsonCodec<T>): Unit {
        @Expect(hasCursorRead(codec))
        @Expect(hasCursorWrite(codec))
    }

    private func sample(): ExtendedCursorContainerMatrix {
        let bigInts = ArrayList<BigInt>()
        bigInts.add(BigInt.parse("1234567890123456789012345678901234567890"))
        bigInts.add(BigInt.parse("-42"))
        let decimals = HashMap<String, Decimal>()
        decimals.add("exp", Decimal.parse("1.250e2"))
        decimals.add("small", Decimal.parse("-0.004"))
        let leaves = ArrayList<CursorMatrixLeaf>()
        leaves.add(CursorMatrixLeaf(7, "仓颉"))
        let events = HashMap<String, CursorMatrixEvent>()
        events.add("event", CursorMatrixEvent.Payload("ready", BigInt.parse("9223372036854775808")))
        let deepItems = ArrayList<Option<Array<Decimal>>>()
        deepItems.add(None<Array<Decimal>>)
        deepItems.add(Some([Decimal.parse("3e2"), Decimal.parse("-4.5")]))
        let deep = HashMap<String, ArrayList<Option<Array<Decimal>>>>()
        deep.add("items", deepItems)
        ExtendedCursorContainerMatrix(
            [r'仓', r'𠮷'], bigInts, decimals,
            [DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339)],
            Some([r'界']), leaves, events, deep
        )
    }

    private func assertValue(value: ExtendedCursorContainerMatrix): Unit {
        @Expect(value.runes[1].toString(), "𠮷")
        @Expect(value.bigInts[0], BigInt.parse("1234567890123456789012345678901234567890"))
        @Expect(value.decimals["exp"], Decimal.parse("1.250e2"))
        @Expect(value.dates[0], DateTime.parse("2024-06-20T14:42:33+08:00", DateTimeFormat.RFC3339))
        @Expect(value.maybeRunes.getOrThrow()[0].toString(), "界")
        @Expect(value.leaves[0].label, "仓颉")
        match (value.events["event"]) {
            case CursorMatrixEvent.Payload(label, number) =>
                @Expect(label, "ready")
                @Expect(number, BigInt.parse("9223372036854775808"))
            case _ => fail("expected payload enum")
        }
        @Expect(value.deep["items"][0].isNone())
        @Expect(value.deep["items"][1].getOrThrow()[1], Decimal.parse("-4.5"))
    }

    @TestCase
    func allRemainingLeafAndRecursiveShapesRoundTripAcrossEntrypoints(): Unit {
        let value = sample()
        let text = YJson.toJson(value)
        assertValue(YJson.fromJson<ExtendedCursorContainerMatrix>(text))

        let bytes = YJson.toJsonBytes(value)
        @Expect(String.fromUtf8(bytes), text)
        assertValue(YJson.fromJson<ExtendedCursorContainerMatrix>(bytes))

        let input = YJsonByteArrayInputStream(bytes)
        assertValue(YJson.fromJson<ExtendedCursorContainerMatrix>(input))

        let output = YJsonMemoryOutputStream()
        YJson.writeJson(value, output)
        @Expect(output.toUtf8String(), text)

        let pretty = YJson.toJson(value, options: JsonWriteOptions.pretty())
        assertValue(YJson.fromJson<ExtendedCursorContainerMatrix>(pretty))
    }

    @TestCase
    func everySupportedLeafAndRecursiveConstructorAdvertisesCursorCapability(): Unit {
        assertCursorCodec(JsonCodecs.bool)
        assertCursorCodec(JsonCodecs.int8)
        assertCursorCodec(JsonCodecs.int16)
        assertCursorCodec(JsonCodecs.int32)
        assertCursorCodec(JsonCodecs.int64)
        assertCursorCodec(JsonCodecs.uint8)
        assertCursorCodec(JsonCodecs.uint16)
        assertCursorCodec(JsonCodecs.uint32)
        assertCursorCodec(JsonCodecs.uint64)
        assertCursorCodec(JsonCodecs.float16)
        assertCursorCodec(JsonCodecs.float32)
        assertCursorCodec(JsonCodecs.float64)
        assertCursorCodec(JsonCodecs.string)
        assertCursorCodec(JsonCodecs.rune)
        assertCursorCodec(JsonCodecs.bigInt)
        assertCursorCodec(JsonCodecs.decimal)
        assertCursorCodec(JsonCodecs.rfc3339DateTime)

        assertCursorCodec(JsonCodecs.option(JsonCodecs.int64))
        assertCursorCodec(JsonCodecs.array(JsonCodecs.int64))
        assertCursorCodec(JsonCodecs.arrayList(JsonCodecs.int64))
        assertCursorCodec(JsonCodecs.stringMap(JsonCodecs.int64))
        assertCursorCodec(JsonCodecs.stringMap(JsonCodecs.array(JsonCodecs.decimal)))
        assertCursorCodec(CursorMatrixLeafJson)
        assertCursorCodec(CursorMatrixEventJson)
        assertCursorCodec(ExtendedCursorContainerMatrixJson)
    }
}
