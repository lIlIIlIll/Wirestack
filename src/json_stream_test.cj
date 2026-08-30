package yjson

import std.unittest.*
import std.unittest.testmacro.*

/**
 * JSON InputStream/OutputStream 功能测试 - P3 级别
 *
 * 注意：当前实现不是真正的增量/分块解析器。
 * StreamJsonByteSource 使用缓冲读取，但仍需一次性读取全部数据后解析。
 * 流式写入支持增量输出到 OutputStream，但构建 JsonNode 时仍在内存中。
 */

// ============================================================================
// 辅助函数：生成测试数据
// ============================================================================

func generateJsonArrayOfInts(count: Int64): String {
    let builder = StringBuilder()
    builder.append("[")
    for (i in 0..count) {
        if (i > 0) { builder.append(",") }
        builder.append("${i}")
    }
    builder.append("]")
    builder.toString()
}

func generateJsonWideObject(fieldCount: Int64): String {
    let builder = StringBuilder()
    builder.append("{")
    for (i in 0..fieldCount) {
        if (i > 0) { builder.append(",") }
        builder.append("\"field_${i}\":${i}")
    }
    builder.append("}")
    builder.toString()
}

func generateJsonDeepNesting(depth: Int64): String {
    let builder = StringBuilder()
    for (_ in 0..depth) {
        builder.append("{\"a\":")
    }
    builder.append("null")
    for (_ in 0..depth) {
        builder.append("}")
    }
    builder.toString()
}

func generateJsonLargeString(size: Int64): String {
    let builder = StringBuilder()
    builder.append("\"")
    for (_ in 0..size) {
        builder.append("x")
    }
    builder.append("\"")
    builder.toString()
}

// ============================================================================
// 流式解析测试
// ============================================================================

@Test
class JsonInputStreamParseFunctionalityTest {

    /// 测试从 ByteArrayInputStream 解析小型 JSON
    @TestCase
    func parseFromMemoryStream(): Unit {
        let json = "{\"name\":\"test\",\"value\":42}"
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)
        let obj = value.asObject()
        @Expect(obj.size() == 2)
        @Expect(obj.get("name").getOrThrow().asString().value == "test")
        @Expect(obj.get("value").getOrThrow().asInt().value == 42)
    }

    /// 测试从 ByteArrayInputStream 解析数组
    @TestCase
    func parseArrayFromMemoryStream(): Unit {
        let json = "[1, 2, 3, 4, 5]"
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)
        let arr = value.asArray()
        @Expect(arr.size() == 5)
        @Expect(arr[0].asInt().value == 1)
        @Expect(arr[4].asInt().value == 5)
    }

    /// 测试从 ByteArrayInputStream 解析大型数组
    @TestCase
    func parseLargeArrayFromMemoryStream(): Unit {
        let json = generateJsonArrayOfInts(1000)
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)
        let arr = value.asArray()
        @Expect(arr.size() == 1000)
        @Expect(arr[0].asInt().value == 0)
        @Expect(arr[999].asInt().value == 999)
    }

    /// 测试从 ByteArrayInputStream 解析宽对象
    @TestCase
    func parseWideObjectFromMemoryStream(): Unit {
        let json = generateJsonWideObject(100)
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)
        let obj = value.asObject()
        @Expect(obj.size() == 100)
        @Expect(obj.contains("field_0"))
        @Expect(obj.contains("field_99"))
    }

    /// 测试从 ByteArrayInputStream 解析深层嵌套结构
    @TestCase
    func parseDeepNestingFromMemoryStream(): Unit {
        let json = generateJsonDeepNesting(50)
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)

        // 验证深度嵌套结构
        var current = value
        for (_ in 0..50) {
            let obj = current.asObject()
            @Expect(obj.size() == 1)
            current = obj.get("a").getOrThrow()
        }
        @Expect(current.kind() == JsonKind.JsNull)
    }

    /// 测试从 ByteArrayInputStream 解析大型字符串
    @TestCase
    func parseLargeStringFromMemoryStream(): Unit {
        let json = generateJsonLargeString(10000)
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)
        @Expect(value.asString().value.size == 10000)
    }

    /// 测试空流
    @TestCase
    func parseFromEmptyStream(): Unit {
        // 注意：空流应该抛出异常
        var caughtException = false
        try {
            let stream = ByteArrayInputStream("")
            let _ = parseJsonValueFromStream(stream)
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }

    /// 测试流中只包含空白字符
    @TestCase
    func parseFromWhitespaceOnlyStream(): Unit {
        var caughtException = false
        try {
            let stream = ByteArrayInputStream("   \n\t  ")
            let _ = parseJsonValueFromStream(stream)
        } catch (_: JsonException) {
            caughtException = true
        }
        @Expect(caughtException)
    }
}

// ============================================================================
// 流式写入测试
// ============================================================================

@Test
class JsonOutputStreamWriteFunctionalityTest {

    /// 测试写入到 MemoryOutputStream
    @TestCase
    func writeToMemoryStream(): Unit {
        let obj = JsonObjectValue()
        obj.put("name", JsonStringValue("test"))
        obj.put("value", JsonIntValue(42))

        let output = MemoryOutputStream()
        writeJsonValueToStream(obj, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        @Expect(result.contains("name"))
        @Expect(result.contains("test"))
        @Expect(result.contains("value"))
        @Expect(result.contains("42"))
    }

    /// 测试写入数组到流
    @TestCase
    func writeArrayToMemoryStream(): Unit {
        let arr = JsonArrayValue()
        arr.add(JsonIntValue(1))
        arr.add(JsonIntValue(2))
        arr.add(JsonIntValue(3))

        let output = MemoryOutputStream()
        writeJsonValueToStream(arr, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        @Expect(result, "[1,2,3]")
    }

    /// 测试使用 pretty 格式写入
    @TestCase
    func writePrettyToMemoryStream(): Unit {
        let obj = JsonObjectValue()
        obj.put("a", JsonIntValue(1))
        obj.put("b", JsonIntValue(2))

        let output = MemoryOutputStream()
        writeJsonValueToStream(obj, output, JsonWriteConfig.pretty)

        let result = output.toUtf8String()
        @Expect(result.contains("\n"))
        @Expect(result.contains("    "))
    }

    /// 测试写入大型数组
    @TestCase
    func writeLargeArrayToMemoryStream(): Unit {
        let arr = JsonArrayValue()
        for (i in 0..1000) {
            arr.add(JsonIntValue(i))
        }

        let output = MemoryOutputStream()
        writeJsonValueToStream(arr, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        // 验证输出以 [ 开头，以 ] 结尾
        @Expect(result.startsWith("["))
        @Expect(result.endsWith("]"))
    }

    /// 测试写入大型字符串
    @TestCase
    func writeLargeStringToMemoryStream(): Unit {
        // String 没有 repeat 方法，使用 StringBuilder
        let builder = StringBuilder()
        for (_ in 0..10000) {
            builder.append("x")
        }
        let largeString = builder.toString()
        let value = JsonStringValue(largeString)

        let output = MemoryOutputStream()
        writeJsonValueToStream(value, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        @Expect(result.startsWith("\""))
        @Expect(result.endsWith("\""))
        @Expect(result.size == 10002) // 10000 字符 + 2 引号
    }

    /// 测试写入特殊字符转义
    @TestCase
    func writeSpecialCharactersToMemoryStream(): Unit {
        let value = JsonStringValue("hello\nworld\t\"quoted\"")

        let output = MemoryOutputStream()
        writeJsonValueToStream(value, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        @Expect(result.contains("\\n"))
        @Expect(result.contains("\\t"))
        @Expect(result.contains("\\\""))
    }

    /// 测试写入空值
    @TestCase
    func writeNullToMemoryStream(): Unit {
        let value = JsonNullValue()

        let output = MemoryOutputStream()
        writeJsonValueToStream(value, output, JsonWriteConfig.compact)

        let result = output.toUtf8String()
        @Expect(result, "null")
    }

    /// 测试写入布尔值
    @TestCase
    func writeBooleansToMemoryStream(): Unit {
        let trueValue = JsonBoolValue(true)
        let falseValue = JsonBoolValue(false)

        let output1 = MemoryOutputStream()
        writeJsonValueToStream(trueValue, output1, JsonWriteConfig.compact)
        @Expect(output1.toUtf8String(), "true")

        let output2 = MemoryOutputStream()
        writeJsonValueToStream(falseValue, output2, JsonWriteConfig.compact)
        @Expect(output2.toUtf8String(), "false")
    }
}

// ============================================================================
// 往返测试（流式解析 + 流式写入）
// ============================================================================

@Test
class JsonStreamRoundtripFunctionalityTest {

    /// 测试往返转换保持语义
    @TestCase
    func roundtripPreservesSemantics(): Unit {
        let original = "{\"name\":\"test\",\"value\":42,\"enabled\":true}"
        let stream1 = ByteArrayInputStream(original)
        let value = parseJsonValueFromStream(stream1)

        let output = MemoryOutputStream()
        writeJsonValueToStream(value, output, JsonWriteConfig.compact)

        let reparsed = YJson.parse(output.toUtf8String())
        let obj = reparsed.asObject()
        @Expect(obj.size() == 3)
        @Expect(obj.get("name").getOrThrow().asString().value == "test")
        @Expect(obj.get("value").getOrThrow().asInt().value == 42)
        @Expect(obj.get("enabled").getOrThrow().asBool().value)
    }

    /// 测试多次往返转换
    @TestCase
    func multipleRoundtripsPreserveSemantics(): Unit {
        let original = "{\"a\":[1,2,3],\"b\":{\"c\":true}}"
        var current = original

        for (_ in 0..5) {
            let stream = ByteArrayInputStream(current)
            let value = parseJsonValueFromStream(stream)

            let output = MemoryOutputStream()
            writeJsonValueToStream(value, output, JsonWriteConfig.compact)
            current = output.toUtf8String()
        }

        // 最终结果应该仍然有效
        let final = YJson.parse(current)
        let obj = final.asObject()
        @Expect(obj.size() == 2)
        let arr = obj.get("a").getOrThrow().asArray()
        @Expect(arr.size() == 3)
        @Expect(arr[0].asInt().value == 1)
        @Expect(arr[1].asInt().value == 2)
        @Expect(arr[2].asInt().value == 3)
        @Expect(obj.get("b").getOrThrow().asObject().get("c").getOrThrow().asBool().value)
    }

    /// 测试大型结构的往返转换
    @TestCase
    func roundtripLargeStructure(): Unit {
        let arr = JsonArrayValue()
        for (i in 0..500) {
            let obj = JsonObjectValue()
            obj.put("id", JsonIntValue(i))
            obj.put("name", JsonStringValue("item_${i}"))
            arr.add(obj)
        }

        let output = MemoryOutputStream()
        writeJsonValueToStream(arr, output, JsonWriteConfig.compact)

        let stream = ByteArrayInputStream(output.toUtf8String())
        let reparsed = parseJsonValueFromStream(stream)

        @Expect(reparsed.asArray().size() == 500)
    }
}

// ============================================================================
// 边界情况测试
// ============================================================================

@Test
class BufferedInputBoundarySmokeTest {

    /// 测试分块读取边界（模拟分块流）
    @TestCase
    func parseAcrossMultipleReadCallsSmoke(): Unit {
        // 验证增量 parser 在多次 read() 之间保留语法状态。
        let json = generateJsonArrayOfInts(200)
        let stream = FixedChunkInputStream(json, 7)
        let value = parseJsonValueFromStream(stream)

        @Expect(value.asArray().size() == 200)
    }

    /// 测试大缓冲区配置
    @TestCase
    func largeBufferSize(): Unit {
        // 创建一个较大的 JSON
        let json = generateJsonArrayOfInts(5000)
        let stream = ByteArrayInputStream(json)

        let value = parseJsonValueFromStream(stream)
        @Expect(value.asArray().size() == 5000)
    }

    /// 测试 Unicode 字符流式处理
    @TestCase
    func unicodeStreamProcessing(): Unit {
        let json = "{\"chinese\":\"你好世界\",\"emoji\":\"🎉\"}"
        let stream = ByteArrayInputStream(json)
        let value = parseJsonValueFromStream(stream)

        let obj = value.asObject()
        @Expect(obj.get("chinese").getOrThrow().asString().value == "你好世界")
        @Expect(obj.get("emoji").getOrThrow().asString().value == "🎉")
    }
}

// Stream API 增量读取一个完整 JSON document，但不提供多文档 framing。
// JsonNode 路径仍需保留完整结果树；typed codec 路径不先构建 JsonNode。
