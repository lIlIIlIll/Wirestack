package yjson

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * JSON 并行使用 smoke 测试 - P3 级别
 *
 * 这些测试验证常见并行读/解析场景下的基本可用性，不证明完整线程安全契约。
 */

// ============================================================================
// 辅助函数：生成测试数据
// ============================================================================

func generateConcurrentTestJson(id: Int64): String {
    "{\"id\":${id},\"name\":\"test_${id}\",\"value\":${id * 10}}"
}

func generateLargeConcurrentJson(size: Int64): String {
    let builder = StringBuilder()
    builder.append("[")
    for (i in 0..size) {
        if (i > 0) { builder.append(",") }
        builder.append("{\"i\":${i}}")
    }
    builder.append("]")
    builder.toString()
}

// ============================================================================
// 多线程解析测试
// ============================================================================

@Test
class ParallelParseSmokeTest {

    /// 测试多个线程同时解析不同的 JSON 字符串
    @TestCase
    func concurrentParseDifferentJsonStrings(): Unit {
        let count = 10
        let futures = ArrayList<Future<JsonValue>>()

        for (i in 0..count) {
            let json = generateConcurrentTestJson(i)
            let future = spawn {
                YJson.parse(json)
            }
            futures.add(future)
        }

        // 等待所有线程完成并验证结果
        for (i in 0..count) {
            let value = futures[i].get()
            let obj = value.asObject()
            @Expect(obj.get("id").getOrThrow().asInt().value == i)
            @Expect(obj.get("name").getOrThrow().asString().value == "test_${i}")
            @Expect(obj.get("value").getOrThrow().asInt().value == i * 10)
        }
    }

    /// 测试多个线程同时解析同一个 JSON 字符串
    @TestCase
    func concurrentParseSameJsonString(): Unit {
        let json = "{\"shared\":\"value\",\"count\":100}"
        let count: Int64 = 20
        let futures = ArrayList<Future<JsonValue>>()
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)

        for (_ in 0..count) {
            let future = spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {}
                YJson.parse(json)
            }
            futures.add(future)
        }
        while (ready.load() != count) {}
        start.store(1)

        // 所有线程应该得到相同的结果
        for (future in futures) {
            let value = future.get()
            let obj = value.asObject()
            @Expect(obj.get("shared").getOrThrow().asString().value == "value")
            @Expect(obj.get("count").getOrThrow().asInt().value == 100)
        }
    }

    /// 测试并发解析大型 JSON
    @TestCase
    func concurrentParseLargeJson(): Unit {
        let json = generateLargeConcurrentJson(500)
        let count = 5
        let futures = ArrayList<Future<JsonValue>>()

        for (_ in 0..count) {
            let future = spawn {
                YJson.parse(json)
            }
            futures.add(future)
        }

        // 验证所有解析结果
        for (future in futures) {
            let value = future.get()
            @Expect(value.asArray().size() == 500)
        }
    }

    /// 测试并发解析复杂嵌套结构
    @TestCase
    func concurrentParseNestedStructures(): Unit {
        let count = 10
        let futures = ArrayList<Future<JsonValue>>()

        for (i in 0..count) {
            let json = "{\"level\":${i},\"nested\":{\"a\":{\"b\":{\"c\":${i}}}}}"
            let future = spawn {
                YJson.parse(json)
            }
            futures.add(future)
        }

        // 验证深层嵌套解析正确
        for (i in 0..count) {
            let value = futures[i].get()
            let obj = value.asObject()
            @Expect(obj.get("level").getOrThrow().asInt().value == i)

            // 验证嵌套路径
            let nested = obj.get("nested").getOrThrow().asObject()
            let a = nested.get("a").getOrThrow().asObject()
            let b = a.get("b").getOrThrow().asObject()
            let c = b.get("c").getOrThrow().asInt()
            @Expect(c.value == i)
        }
    }
}

// ============================================================================
// 并发序列化测试
// ============================================================================

@Test
class ParallelSerializeSmokeTest {

    /// 测试多个线程同时序列化不同的 JsonValue
    @TestCase
    func concurrentSerializeDifferentValues(): Unit {
        let count = 10
        let futures = ArrayList<Future<String>>()

        for (i in 0..count) {
            let obj = JsonObjectValue()
            obj.put("id", JsonIntValue(i))
            obj.put("data", JsonStringValue("thread_${i}"))

            let future = spawn {
                obj.toString()
            }
            futures.add(future)
        }

        // 验证所有序列化结果
        for (i in 0..count) {
            let result = futures[i].get()
            @Expect(result.contains("id"))
            @Expect(result.contains("${i}"))
        }
    }

    /// 测试多个线程同时序列化同一个 JsonValue
    /// 注意：这测试读取安全性，不涉及修改
    @TestCase
    func concurrentSerializeSameValue(): Unit {
        let arr = JsonArrayValue()
        for (i in 0..100) {
            arr.add(JsonIntValue(i))
        }

        let count: Int64 = 20
        let futures = ArrayList<Future<String>>()
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)

        for (_ in 0..count) {
            let future = spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {}
                arr.toString()
            }
            futures.add(future)
        }
        while (ready.load() != count) {}
        start.store(1)

        // 所有线程应该得到相同的结果
        let firstResult = futures[0].get()
        for (future in futures) {
            let result = future.get()
            @Expect(result == firstResult)
        }
    }

    /// 测试并发序列化大型结构
    @TestCase
    func concurrentSerializeLargeStructure(): Unit {
        let largeArr = JsonArrayValue()
        for (i in 0..500) {
            let obj = JsonObjectValue()
            obj.put("index", JsonIntValue(i))
            largeArr.add(obj)
        }

        let count = 5
        let futures = ArrayList<Future<String>>()

        for (_ in 0..count) {
            let future = spawn {
                largeArr.toString()
            }
            futures.add(future)
        }

        // 验证所有序列化结果有效
        for (future in futures) {
            let result = future.get()
            @Expect(result.startsWith("["))
            @Expect(result.endsWith("]"))
        }
    }
}

// ============================================================================
// 共享状态测试
// ============================================================================

@Test
class SharedReadSmokeTest {

    /// 测试多线程读取同一个 JsonValue
    /// 这是安全的，因为读取不修改状态
    @TestCase
    func concurrentReadSharedValue(): Unit {
        let sharedObj = JsonObjectValue()
        sharedObj.put("name", JsonStringValue("shared"))
        sharedObj.put("value", JsonIntValue(42))
        sharedObj.put("enabled", JsonBoolValue(true))

        let count = 30
        let futures = ArrayList<Future<Bool>>()

        for (_ in 0..count) {
            let future = spawn {
                // 读取操作
                let name = sharedObj.get("name").getOrThrow().asString().value
                let value = sharedObj.get("value").getOrThrow().asInt().value
                let enabled = sharedObj.get("enabled").getOrThrow().asBool().value

                // 返回验证结果
                name == "shared" && value == 42 && enabled
            }
            futures.add(future)
        }

        // 所有读取应该成功且一致
        for (future in futures) {
            @Expect(future.get())
        }
    }

    /// 测试多线程读取数组元素
    @TestCase
    func concurrentReadArrayElements(): Unit {
        let sharedArr = JsonArrayValue()
        for (i in 0..200) {
            sharedArr.add(JsonIntValue(i))
        }

        let count = 20
        let futures = ArrayList<Future<Int64>>()

        for (i in 0..count) {
            let index = i * 10
            let future = spawn {
                sharedArr[index].asInt().value
            }
            futures.add(future)
        }

        // 验证读取的值正确
        for (i in 0..count) {
            @Expect(futures[i].get() == i * 10)
        }
    }

    /// 测试并发类型转换（asInt/asFloat 等）
    @TestCase
    func concurrentTypeConversion(): Unit {
        let sharedValue = JsonIntValue(100)

        let count = 20
        let futures = ArrayList<Future<Int64>>()

        for (_ in 0..count) {
            let future = spawn {
                sharedValue.asInt().value
            }
            futures.add(future)
        }

        // 所有转换应该返回相同值
        for (future in futures) {
            @Expect(future.get() == 100)
        }
    }
}

// ============================================================================
// 并发计数器测试（验证原子操作）
// ============================================================================

@Test
class ParallelCounterSmokeTest {

    /// 测试使用原子计数器统计并发解析结果
    @TestCase
    func atomicCounterForParseResults(): Unit {
        let successCounter = AtomicInt64(0)
        let count = 20

        let futures = ArrayList<Future<Int64>>()
        for (i in 0..count) {
            let json = generateConcurrentTestJson(i)
            let future = spawn {
                try {
                    let _ = YJson.parse(json)
                    successCounter.fetchAdd(1)
                    1  // 成功返回 1
                } catch (_: Exception) {
                    0  // 失败返回 0
                }
            }
            futures.add(future)
        }

        // 等待所有线程完成
        for (future in futures) {
            future.get()
        }

        // 所有解析应该成功
        @Expect(successCounter.load() == count)
    }

    /// 测试并发统计数组大小
    @TestCase
    func concurrentCountArraySizes(): Unit {
        let totalSize = AtomicInt64(0)
        let count = 10

        let futures = ArrayList<Future<Unit>>()
        for (i in 0..count) {
            let json = generateLargeConcurrentJson(i * 10 + 10)
            let future = spawn {
                let arr = YJson.parse(json).asArray()
                let _ = totalSize.fetchAdd(arr.size())  // fetchAdd 返回旧值，忽略
            }
            futures.add(future)
        }

        // 等待所有线程完成
        for (future in futures) {
            future.get()
        }

        // 验证总大小（计算期望值：10 + 20 + 30 + ... + 100）
        var expectedTotal: Int64 = 0
        for (i in 0..count) {
            expectedTotal += i * 10 + 10
        }
        @Expect(totalSize.load() == expectedTotal)
    }
}

// ============================================================================
// 并发往返测试
// ============================================================================

@Test
class ParallelRoundtripSmokeTest {

    /// 测试并发解析和序列化往返
    @TestCase
    func concurrentRoundtrip(): Unit {
        let count = 10
        let futures = ArrayList<Future<Bool>>()

        for (i in 0..count) {
            let original = generateConcurrentTestJson(i)
            let future = spawn {
                let parsed = YJson.parse(original)
                let serialized = parsed.toString()
                let reparsed = YJson.parse(serialized)

                // 验证往返后的值
                let obj = reparsed.asObject()
                obj.get("id").getOrThrow().asInt().value == i
            }
            futures.add(future)
        }

        // 验证所有往返成功
        for (future in futures) {
            @Expect(future.get())
        }
    }
}

// ============================================================================
// 功能限制说明
// ============================================================================

// 注意：以下场景当前可能存在并发问题，标注为已知限制：
//
// 1. 写入操作的并发安全：
//    - JsonObjectValue.put() 和 JsonArrayValue.add() 不是线程安全的
//    - 如果一个线程在修改结构，其他线程读取可能会有问题
//    - 建议：文档说明或添加并发版本（如 ConcurrentJsonObjectValue）
//
// 2. 深度并发测试：
//    - 当前测试线程数较少（10-30）
//    - 更高的并发压力可能暴露更多问题
//    - 建议：添加压力测试配置选项
//
// 3. 长时间并发运行：
//    - 当前测试较短，未测试长时间并发稳定性
//    - 建议：添加长时间运行的并发测试
//
// 4. 异常处理：
//    - 并发环境下的异常传播需要更多测试
//    - 建议：添加并发异常场景测试
