package yjson

import std.collection.*
import std.runtime.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * JSON 堆占用观察测试 - P3 级别
 *
 * 使用仓颉的 getAllocatedHeapSize() 和 getUsedHeapSize() 测量内存占用。
 * 注意：这些 API 提供的是整个堆的统计，不足以证明对象级内存效率或无泄漏。
 */

// ============================================================================
// 辅助函数：生成测试数据
// ============================================================================

func generateMemoryTestJson(size: Int64): String {
    let builder = StringBuilder()
    builder.append("[")
    for (i in 0..size) {
        if (i > 0) { builder.append(",") }
        builder.append("{\"id\":${i},\"value\":\"${i * 10}\"}")
    }
    builder.append("]")
    builder.toString()
}

func generateMemoryTestString(length: Int64): String {
    // String 没有 repeat 方法，使用 StringBuilder
    let builder = StringBuilder()
    builder.append("{\"largeString\":\"")
    for (_ in 0..length) {
        builder.append("x")
    }
    builder.append("\"}")
    builder.toString()
}

func generateMemoryTestWideObject(fields: Int64): String {
    let builder = StringBuilder()
    builder.append("{")
    for (i in 0..fields) {
        if (i > 0) { builder.append(",") }
        builder.append("\"field${i}\":${i}")
    }
    builder.append("}")
    builder.toString()
}

func generateMemoryTestDeepNesting(depth: Int64): String {
    let builder = StringBuilder()
    for (_ in 0..depth) {
        builder.append("{\"nested\":")
    }
    builder.append("null")
    for (_ in 0..depth) {
        builder.append("}")
    }
    builder.toString()
}

// ============================================================================
// 内存占用测试
// ============================================================================

@Test
class JsonHeapObservationTest {

    /// 测试小 JSON 的内存占用
    /// 注意：由于 API 只提供全局堆统计，结果仅供参考
    @TestCase
    func smallJsonMemory(): Unit {
        let before = getAllocatedHeapSize()

        let json = "{\"a\":1,\"b\":\"test\"}"
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        // 小 JSON 的内存增量应该很小（由于对象复用等原因可能为负）
        // 主要验证解析不崩溃
        @Expect(value.asObject().size() == 2)

        // 输出内存变化（仅供参考）
        println("Small JSON memory delta: ${delta} bytes")
    }

    /// 测试中等 JSON 的内存占用
    @TestCase
    func mediumJsonMemory(): Unit {
        let before = getAllocatedHeapSize()

        let json = generateMemoryTestJson(500)
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        @Expect(value.asArray().size() == 500)

        println("Medium JSON (500 items) memory delta: ${delta} bytes")
    }

    /// 测试大 JSON 的内存占用
    @TestCase
    func largeJsonMemory(): Unit {
        let before = getAllocatedHeapSize()

        let json = generateMemoryTestJson(2000)
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        @Expect(value.asArray().size() == 2000)

        println("Large JSON (2000 items) memory delta: ${delta} bytes")
    }

    /// 测试大型字符串的内存占用
    @TestCase
    func largeStringMemory(): Unit {
        let stringSize = 50000

        let before = getAllocatedHeapSize()

        let json = generateMemoryTestString(stringSize)
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        @Expect(value.asObject().get("largeString").getOrThrow().asString().value.size == stringSize)

        println("Large string (${stringSize} chars) memory delta: ${delta} bytes")
    }

    /// 测试宽对象的内存占用
    @TestCase
    func wideObjectMemory(): Unit {
        let fieldCount = 500

        let before = getAllocatedHeapSize()

        let json = generateMemoryTestWideObject(fieldCount)
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        @Expect(value.asObject().size() == fieldCount)

        println("Wide object (${fieldCount} fields) memory delta: ${delta} bytes")
    }

    /// 测试深层嵌套结构的内存占用
    @TestCase
    func deepNestingMemory(): Unit {
        let depth = 100

        let before = getAllocatedHeapSize()

        let json = generateMemoryTestDeepNesting(depth)
        let value = YJson.parse(json)

        let after = getAllocatedHeapSize()
        let delta = after - before

        // 验证解析成功
        var current = value
        for (_ in 0..depth) {
            current = current.asObject().get("nested").getOrThrow()
        }
        @Expect(current.kind() == JsonKind.JsNull)

        println("Deep nesting (${depth} levels) memory delta: ${delta} bytes")
    }
}

// ============================================================================
// 堆稳定性观察测试
// ============================================================================

@Test
class JsonHeapStabilityObservationTest {

    /// 测试多次解析同一个 JSON 后的内存稳定性
    @TestCase
    func repeatedParseSameJson(): Unit {
        let json = generateMemoryTestJson(100)
        let iterations = 100

        let before = getAllocatedHeapSize()

        for (_ in 0..iterations) {
            let _ = YJson.parse(json)
        }

        let after = getAllocatedHeapSize()
        let delta = after - before

        println("Repeated parse (${iterations} times) memory delta: ${delta} bytes")

        // 验证最后一次解析有效
        let value = YJson.parse(json)
        @Expect(value.asArray().size() == 100)
    }

    /// 测试多次解析不同 JSON 后的内存稳定性
    @TestCase
    func repeatedParseDifferentJson(): Unit {
        let iterations = 50

        let before = getAllocatedHeapSize()

        for (i in 0..iterations) {
            let json = generateMemoryTestJson(i * 5 + 10)
            let _ = YJson.parse(json)
        }

        let after = getAllocatedHeapSize()
        let delta = after - before

        println("Repeated parse different JSON (${iterations} times) memory delta: ${delta} bytes")
    }

    /// 测试序列化后的内存稳定性
    @TestCase
    func repeatedSerializeSameValue(): Unit {
        let arr = JsonArrayValue()
        for (i in 0..200) {
            arr.add(JsonIntValue(i))
        }

        let iterations = 100

        let before = getAllocatedHeapSize()

        for (_ in 0..iterations) {
            let _ = arr.toString()
        }

        let after = getAllocatedHeapSize()
        let delta = after - before

        println("Repeated serialize (${iterations} times) memory delta: ${delta} bytes")
    }

    /// 测试往返转换的内存稳定性
    @TestCase
    func repeatedRoundtrip(): Unit {
        let json = "{\"data\":[1,2,3,4,5]}"
        let iterations = 100

        let before = getAllocatedHeapSize()

        for (_ in 0..iterations) {
            let value = YJson.parse(json)
            let _ = value.toString()
        }

        let after = getAllocatedHeapSize()
        let delta = after - before

        println("Repeated roundtrip (${iterations} times) memory delta: ${delta} bytes")

        @Expect(YJson.parse(json).asObject().get("data").getOrThrow().asArray().size() == 5)
    }

    /// 测试大量小对象创建和释放
    @TestCase
    func manySmallObjects(): Unit {
        let before = getAllocatedHeapSize()

        for (i in 0..1000) {
            let obj = JsonObjectValue()
            obj.put("id", JsonIntValue(i))
            obj.put("name", JsonStringValue("item_${i}"))
            let _ = obj.toString()
        }

        let after = getAllocatedHeapSize()
        let delta = after - before

        println("Many small objects (1000) memory delta: ${delta} bytes")
    }
}

// ============================================================================
// 堆变化观察测试
// ============================================================================

@Test
class JsonHeapChangeObservationTest {

    /// 测试解析过程中的峰值（通过中间测量）
    @TestCase
    func parseLargeArrayPeak(): Unit {
        let json = generateMemoryTestJson(3000)

        let before = getAllocatedHeapSize()

        // 解析大型数组
        let value = YJson.parse(json)

        let peak = getAllocatedHeapSize()

        // 验证解析结果
        @Expect(value.asArray().size() == 3000)

        println("Parse peak memory: input size ${json.size} bytes, peak delta ${peak - before} bytes")
    }

    /// 测试序列化过程中的峰值
    @TestCase
    func serializeLargeStructurePeak(): Unit {
        let arr = JsonArrayValue()
        for (i in 0..2000) {
            arr.add(JsonIntValue(i))
        }

        let before = getAllocatedHeapSize()

        let result = arr.toString()

        let peak = getAllocatedHeapSize()

        println("Serialize peak memory: output size ${result.size} bytes, peak delta ${peak - before} bytes")
    }

    /// 测试流式写入的内存峰值
    @TestCase
    func streamWritePeak(): Unit {
        let obj = JsonObjectValue()
        for (i in 0..1000) {
            obj.put("field_${i}", JsonIntValue(i))
        }

        let before = getAllocatedHeapSize()

        let output = MemoryOutputStream()
        writeJsonValueToStream(obj, output, JsonWriteConfig.compact)

        let peak = getAllocatedHeapSize()

        println("Stream write peak delta: ${peak - before} bytes")
    }
}

// ============================================================================
// 输入规模与堆变化观察
// ============================================================================

@Test
class JsonInputSizeHeapObservationTest {

    /// 测试输入大小与内存占用的比例
    @TestCase
    func inputToMemoryRatio(): Unit {
        let sizes = [100, 500, 1000, 2000]

        for (size in sizes) {
            let json = generateMemoryTestJson(size)
            let inputSize = json.size

            let before = getAllocatedHeapSize()
            let value = YJson.parse(json)
            let after = getAllocatedHeapSize()

            let memoryDelta = after - before
            let ratio = Float64(memoryDelta) / Float64(inputSize)

            println("Size ${size}: input ${inputSize} bytes, memory delta ${memoryDelta} bytes, ratio ${ratio}")

            // 验证解析成功
            @Expect(value.asArray().size() == size)
        }
    }

    /// 测试字符串大小与内存占用的比例
    @TestCase
    func stringToMemoryRatio(): Unit {
        let sizes = [1000, 10000, 50000]

        for (size in sizes) {
            let json = generateMemoryTestString(size)
            let inputSize = json.size

            let before = getAllocatedHeapSize()
            let value = YJson.parse(json)
            let after = getAllocatedHeapSize()

            let memoryDelta = after - before
            let ratio = Float64(memoryDelta) / Float64(inputSize)

            println("String ${size}: input ${inputSize} bytes, memory delta ${memoryDelta} bytes, ratio ${ratio}")

            @Expect(value.asObject().get("largeString").getOrThrow().asString().value.size == size)
        }
    }
}

// ============================================================================
// 堆信息查询测试
// ============================================================================

@Test
class JsonHeapInfoTest {

    /// 测试获取堆信息
    @TestCase
    func queryHeapInfo(): Unit {
        let allocated = getAllocatedHeapSize()
        let used = getUsedHeapSize()
        let max = getMaxHeapSize()

        println("Heap info: allocated=${allocated}, used=${used}, max=${max}")

        // 验证值合理
        @Expect(allocated >= 0)
        @Expect(used >= 0)
        @Expect(max >= 0)
        @Expect(allocated <= max)
    }

    /// 测试解析前后堆变化
    @TestCase
    func heapChangeBeforeAfterParse(): Unit {
        println("Before parse:")
        println("  Allocated: ${getAllocatedHeapSize()}")
        println("  Used: ${getUsedHeapSize()}")

        let json = generateMemoryTestJson(1000)
        let value = YJson.parse(json)

        println("After parse:")
        println("  Allocated: ${getAllocatedHeapSize()}")
        println("  Used: ${getUsedHeapSize()}")

        @Expect(value.asArray().size() == 1000)
    }
}

// ============================================================================
// 重复操作 smoke 测试
// ============================================================================

@Test
class JsonRepeatedAllocationSmokeTest {

    /// 测试高强度解析
    @TestCase
    func highIntensityParse(): Unit {
        let before = getAllocatedHeapSize()

        for (i in 0..50) {
            let json = generateMemoryTestJson(i * 20 + 20)
            let value = YJson.parse(json)
            @Expect(value.asArray().size() == i * 20 + 20)
        }

        let after = getAllocatedHeapSize()
        println("High intensity parse memory delta: ${after - before} bytes")
    }

    /// 测试高强度序列化
    @TestCase
    func highIntensitySerialize(): Unit {
        let before = getAllocatedHeapSize()

        for (i in 0..50) {
            let arr = JsonArrayValue()
            for (j in 0..i * 10 + 10) {
                arr.add(JsonIntValue(j))
            }
            let _ = arr.toString()
        }

        let after = getAllocatedHeapSize()
        println("High intensity serialize memory delta: ${after - before} bytes")
    }
}

// ============================================================================
// 功能限制说明
// ============================================================================

// 注意：以下内存分析功能当前不可用：
//
// 1. 单个对象的精确内存大小：
//    - getAllocatedHeapSize() 返回整个堆的统计
//    - 无法获取单个 JsonNode 的精确内存占用
//    - 建议：添加 sizeof() 或类似 API
//
// 2. 内存峰值实时监控：
//    - 当前只能在解析前后测量
//    - 无法捕获解析过程中的峰值变化
//    - 建议：使用外部工具（如 valgrind、heaptrack）分析
//
// 3. 内存分配追踪：
//    - 无法追踪具体哪些对象占用了内存
//    - 建议：添加分配追踪 API 或集成分析工具
//
// 4. GC 行为分析：
//    - 无法控制 GC 触发时机
//    - 无法分析 GC 效率
//    - 建议：添加 GC 相关 API
