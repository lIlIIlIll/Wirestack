package yjson

import yjson_macros.*
import std.collection.*
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
    }
}
