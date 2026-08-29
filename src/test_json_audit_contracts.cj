package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private class AuditIntValueCodec <: JsonValueCodec<Int64> {
    public func encode(value: Int64): JsonNode { JsonIntValue(value) }
    public func decode(value: JsonNode): Int64 { value.int64 }
}

@Test
class JsonAuditContractRegressionTest {
    @TestCase
    func recursiveJsonNodeOperationsRejectCyclesButAcceptSharedDags(): Unit {
        let arrayCycle = JsonArrayValue()
        arrayCycle.add(arrayCycle)
        let compactError = @AssertThrows[JsonException](YJson.stringify(arrayCycle))
        @Expect(compactError.code, "cyclic_json_node")
        let prettyError = @AssertThrows[JsonException](YJson.stringifyPretty(arrayCycle))
        @Expect(prettyError.code, "cyclic_json_node")
        let copyError = @AssertThrows[JsonException](arrayCycle.deepCopy())
        @Expect(copyError.code, "cyclic_json_node")
        let equivalentError = @AssertThrows[JsonException](arrayCycle.equivalentTo(arrayCycle))
        @Expect(equivalentError.code, "cyclic_json_node")

        let objectCycle = JsonObjectValue()
        objectCycle.entries()["self"] = objectCycle
        let objectError = @AssertThrows[JsonException](objectCycle.toString())
        @Expect(objectError.code, "cyclic_json_node")

        let first = JsonObjectValue()
        let second = JsonArrayValue()
        first.put("next", second)
        second.values().add(first)
        let indirectError = @AssertThrows[JsonException](first.deepCopy())
        @Expect(indirectError.code, "cyclic_json_node")

        let shared = JsonArrayValue().add(JsonIntValue(1))
        let dag = JsonObjectValue().put("left", shared).put("right", shared)
        @Expect(YJson.stringify(dag), "{\"left\":[1],\"right\":[1]}")
        @Expect(dag.deepCopy().equivalentTo(dag))
    }

    @TestCase
    func directWriterRequiresExactlyOneRootBeforeAnySecondRootByte(): Unit {
        let empty = JsonDirectWriter()
        let emptyError = @AssertThrows[JsonException](empty.finishString())
        @Expect(emptyError.code, "writer_state")

        let scalar = JsonDirectWriter()
        scalar.writeInt64(1)
        let secondError = @AssertThrows[JsonException](scalar.writeInt64(2))
        @Expect(secondError.code, "writer_state")
        @Expect(scalar.finishString(), "1")
        @Expect(scalar.finishString(), "1")

        let output = MemoryOutputStream()
        let stream = JsonDirectWriter(output)
        stream.startArray()
        stream.endArray()
        let streamError = @AssertThrows[JsonException](stream.startObject())
        @Expect(streamError.code, "writer_state")
        stream.finish()
        @Expect(output.toUtf8String(), "[]")
    }

    @TestCase
    func directAndAstWritersShareTheContainerDepthBoundary(): Unit {
        let config = JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxDepth: 1))

        let direct = JsonDirectWriter(config)
        direct.startArray()
        let directError = @AssertThrows[JsonException](direct.startObject())
        @Expect(directError.code, "max_depth")
        direct.endArray()
        @Expect(direct.finishString(), "[]")

        let ast = JsonArrayValue().add(JsonArrayValue())
        let astError = @AssertThrows[JsonException](YJson.stringify(ast, config: config))
        @Expect(astError.code, "max_depth")

        let output = MemoryOutputStream()
        let stream = JsonDirectWriter(output, config: config)
        stream.startObject()
        stream.writeName("nested")
        let streamError = @AssertThrows[JsonException](stream.startArray())
        @Expect(streamError.code, "max_depth")
    }

    @TestCase
    func streamByteLimitFailsBeforeCommittingBeyondTheBoundary(): Unit {
        let limited = JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxBytes: 3))
        let output = MemoryOutputStream()
        let writer = JsonDirectWriter(output, config: limited)
        let error = @AssertThrows[JsonException](writer.writeString("long"))
        @Expect(error.code, "output_too_large")
        @Expect(output.toByteArray().size <= 3)
        let terminalError = @AssertThrows[JsonException](writer.finish())
        @Expect(terminalError.code, "output_too_large")
        @Expect(output.toByteArray().size <= 3)

        let exact = MemoryOutputStream()
        let exactWriter = JsonDirectWriter(exact, config: JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxBytes: 6)))
        exactWriter.writeString("long")
        exactWriter.finish()
        @Expect(exact.toUtf8String(), "\"long\"")
    }

    @TestCase
    func runeCodecRequiresExactlyOneUnicodeScalarAcrossInputs(): Unit {
        @Expect(YJson.decodeStringWith(RuneJson, "\"a\"").toString(), "a")
        @Expect(YJson.decodeStringWith(RuneJson, "\"仓\"").toString(), "仓")
        @Expect(YJson.decodeStringWith(RuneJson, "\"😀\"").toString(), "😀")
        @Expect(YJson.decodeStringWith(RuneJson, "\"\\uD83D\\uDE00\"").toString(), "😀")
        for (text in ["\"\"", "\"ab\"", "\"é\"", "\"😀😀\"", "\"a\\u4ed3\""]) {
            let error = @AssertThrows[JsonException](YJson.decodeStringWith(RuneJson, text))
            @Expect(error.code, "invalid_value")
        }
        let streamError = @AssertThrows[JsonException](YJson.decodeFromStreamWith(
            RuneJson, ByteArrayInputStream("\"ab\"")))
        @Expect(streamError.code, "invalid_value")
    }

    @TestCase
    func legacyAstCodecRejectsConfigurationItCannotApply(): Unit {
        let codec = AuditIntValueCodec()
        @Expect(YJsonAst.encodeWith(codec, 7).int64, 7)
        @Expect(YJsonAst.decodeWith(codec, JsonIntValue(8)), 8)
        let config = JsonCodecConfig(
            read: JsonReadConfig(limits: JsonReadLimits(maxDepth: 1)),
            write: JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxBytes: 1))
        )
        let encodeError = @AssertThrows[JsonException](YJsonAst.encodeWith(codec, 7, config: config))
        @Expect(encodeError.code, "unsupported_config")
        let decodeError = @AssertThrows[JsonException](YJsonAst.decodeWith(codec, JsonIntValue(8), config: config))
        @Expect(decodeError.code, "unsupported_config")
    }

    @TestCase
    func compactDocumentMissesRemainSemanticallyStableUnderUniqueQueries(): Unit {
        var text = "{"
        for (index in 0..64) {
            if (index > 0) { text += "," }
            text += "\"key${index}\":${index}"
        }
        text += "}"
        let root = YJson.parseDocument(text).root()
        for (index in 0..10000) {
            @Expect(root.get("missing-${index}").isNone())
        }
        @Expect(root.get("key63").getOrThrow().asInt64(), 63)
        @Expect(root.get("missing-0").isNone())
    }
}
