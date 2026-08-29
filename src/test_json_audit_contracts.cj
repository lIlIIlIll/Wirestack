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
        let mismatchedRight = JsonArrayValue().add(JsonIntValue(0))
        @Expect(@AssertThrows[JsonException](arrayCycle.equivalentTo(mismatchedRight)).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](mismatchedRight.equivalentTo(arrayCycle)).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](arrayCycle.equivalentTo(JsonArrayValue())).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](JsonArrayValue().equivalentTo(arrayCycle)).code,
            "cyclic_json_node")

        let objectCycle = JsonObjectValue()
        objectCycle.entries()["self"] = objectCycle
        let objectError = @AssertThrows[JsonException](objectCycle.toString())
        @Expect(objectError.code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](objectCycle.equivalentTo(JsonObjectValue())).code,
            "cyclic_json_node")

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

        let nonDefaultWrites = [
            JsonWriteConfig("\n", "", false, false),
            JsonWriteConfig("", "  ", false, false),
            JsonWriteConfig("", "", true, false),
            JsonWriteConfig("", "", false, true),
            JsonWriteConfig("", "", false, false, includeErrorLocation: false),
            JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxDepth: 255)),
            JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxBytes: 1))
        ]
        for (writeConfig in nonDefaultWrites) {
            let error = @AssertThrows[JsonException](YJsonAst.encodeWith(codec, 7,
                config: JsonCodecConfig(write: writeConfig)))
            @Expect(error.code, "unsupported_config")
        }
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

    @TestCase
    func genericCompactMapHandlesEmptyPlainAndEscapedKeys(): Unit {
        let codec = YJson.hashMapCodec(StringJson)
        let empty = HashMap<String, String>()
        @Expect(YJson.encodeStringWith(codec, empty), "{}")

        let single = HashMap<String, String>()
        single["only"] = "value"
        @Expect(YJson.decodeStringWith(codec, YJson.encodeStringWith(codec, single))["only"], "value")

        let values = HashMap<String, String>()
        values["plain"] = "first"
        values["line\nkey"] = "second"
        let encoded = YJson.encodeStringWith(codec, values)
        let decoded = YJson.decodeStringWith(codec, encoded)
        @Expect(decoded.size, 2)
        @Expect(decoded["plain"], "first")
        @Expect(decoded["line\nkey"], "second")

        let many = HashMap<String, String>()
        for (index in 0..16) { many["key-${index}"] = "value-${index}" }
        let decodedMany = YJson.decodeStringWith(codec, YJson.encodeStringWith(codec, many))
        @Expect(decodedMany.size, 16)
        @Expect(decodedMany["key-15"], "value-15")
    }

    @TestCase
    func streamTargetHandlesLargeExactAndRepeatedLimitFailures(): Unit {
        let builder = StringBuilder()
        for (_ in 0..10000) { builder.append("x") }
        let large = builder.toString()

        let exactOutput = MemoryOutputStream()
        let exact = JsonDirectWriter(exactOutput, config: JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxBytes: 10002)))
        exact.writeString(large)
        exact.finish()
        @Expect(exactOutput.toByteArray().size, 10002)

        let limitedOutput = MemoryOutputStream()
        let limited = JsonDirectWriter(limitedOutput, config: JsonWriteConfig("", "", false, false,
            includeErrorLocation: false, limits: JsonWriteLimits(maxBytes: 10001)))
        let first = @AssertThrows[JsonException](limited.writeString(large))
        @Expect(first.code, "output_too_large")
        @Expect(first.byteOffset, -1)
        let repeated = @AssertThrows[JsonException](limited.finish())
        @Expect(repeated.code, "output_too_large")
        @Expect(limitedOutput.toByteArray().size <= 10001)

        let exactBufferBuilder = StringBuilder()
        for (_ in 0..8190) { exactBufferBuilder.append("y") }
        let exactBufferOutput = MemoryOutputStream()
        let exactBuffer = JsonDirectWriter(exactBufferOutput)
        exactBuffer.writeString(exactBufferBuilder.toString())
        exactBuffer.finish()
        @Expect(exactBufferOutput.toByteArray().size, 8192)

        let bytes = Array<Byte>(9002, repeat: b'z')
        let bytesOutput = MemoryOutputStream()
        let bytesTarget = DirectStreamWriterTarget(bytesOutput, JsonWriteConfig.compact)
        bytesTarget.writeBytes(bytes[1..9001])
        bytesTarget.finish()
        @Expect(bytesOutput.toByteArray().size, 9000)

        let rangeOutput = MemoryOutputStream()
        let rangeTarget = DirectStreamWriterTarget(rangeOutput, JsonWriteConfig.compact)
        rangeTarget.writeBytesRange(bytes, 1, 9001)
        rangeTarget.finish()
        @Expect(rangeOutput.toByteArray().size, 9000)

        let byteLimitTarget = DirectStreamWriterTarget(MemoryOutputStream(), JsonWriteConfig("", "", false,
            false, includeErrorLocation: false, limits: JsonWriteLimits(maxBytes: 1)))
        let byteLimitError = @AssertThrows[JsonException](byteLimitTarget.writeBytes([b'a', b'b']))
        @Expect(byteLimitError.code, "output_too_large")
        @Expect(byteLimitError.byteOffset, -1)
        let repeatedByteLimitError = @AssertThrows[JsonException](byteLimitTarget.writeByte(b'a'))
        @Expect(repeatedByteLimitError.code, "output_too_large")

        let byteByByteOutput = MemoryOutputStream()
        let byteByByteTarget = DirectStreamWriterTarget(byteByByteOutput, JsonWriteConfig.compact)
        for (_ in 0..8192) { byteByByteTarget.writeByte(b'a') }
        byteByByteTarget.finish()
        @Expect(byteByByteOutput.toByteArray().size, 8192)

        let digitOutput = MemoryOutputStream()
        let digitTarget = DirectStreamWriterTarget(digitOutput, JsonWriteConfig.compact)
        for (_ in 0..4096) { digitTarget.writeInt64Text(1) }
        digitTarget.finish()
        @Expect(digitOutput.toByteArray().size, 4096)

        let arrayCases = ArrayList<ArrayList<Int64>>()
        arrayCases.add(ArrayList<Int64>())
        let one = ArrayList<Int64>(); one.add(1); arrayCases.add(one)
        let two = ArrayList<Int64>(); two.add(-1); two.add(42); arrayCases.add(two)
        let manyInts = ArrayList<Int64>()
        for (index in 0..64) { manyInts.add(index) }
        arrayCases.add(manyInts)
        for (values in arrayCases) {
            let arrayWriter = JsonDirectWriter()
            @Expect(arrayWriter.tryWriteCompactInt64ArrayList(values))
            let encoded = arrayWriter.finishString()
            @Expect(YJson.decodeStringWith(YJson.arrayListCodec(Int64Json), encoded), values)
        }
    }

    @TestCase
    func rawWriterStateAndNodeInequalityPathsRemainObservable(): Unit {
        let raw = JsonDirectWriter()
        @Expect(raw.tryBeginGeneratedCompactRawValue())
        raw.writeRawBeginArray()
        raw.writeRawNull()
        raw.writeRawEndArray()
        @Expect(raw.finishString(), "[null]")

        let rawScalar = JsonDirectWriter()
        @Expect(rawScalar.tryBeginGeneratedCompactRawValue())
        rawScalar.writeRawNull()
        @Expect(rawScalar.finishString(), "null")

        let lateCycle = JsonArrayValue().add(JsonIntValue(1)).add(JsonStringValue("safe"))
        lateCycle.add(lateCycle)
        @Expect(@AssertThrows[JsonException](lateCycle.deepCopy()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](lateCycle.toString()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](lateCycle.equivalentTo(lateCycle)).code, "cyclic_json_node")

        let lateMismatchLeft = JsonArrayValue().add(JsonIntValue(1)).add(JsonIntValue(2)).add(JsonIntValue(3))
        let lateMismatchRight = JsonArrayValue().add(JsonIntValue(1)).add(JsonIntValue(2)).add(JsonIntValue(4))
        @Expect(!lateMismatchLeft.equivalentTo(lateMismatchRight))

        let wideCycle = JsonObjectValue()
        for (index in 0..16) { wideCycle.put("safe-${index}", JsonIntValue(index)) }
        wideCycle.put("cycle", wideCycle)
        @Expect(@AssertThrows[JsonException](wideCycle.deepCopy()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](wideCycle.toString()).code, "cyclic_json_node")

        let wideLeft = JsonObjectValue()
        let wideRight = JsonObjectValue()
        for (index in 0..16) {
            wideLeft.put("field-${index}", JsonIntValue(index))
            wideRight.put("field-${index}", JsonIntValue(index))
        }
        wideRight.put("field-15", JsonIntValue(99))
        @Expect(!wideLeft.equivalentTo(wideRight))

        let unbalanced = JsonDirectWriter()
        let unbalancedError = @AssertThrows[JsonException](unbalanced.writeRawEndObject())
        @Expect(unbalancedError.code, "writer_state")

        let shallow = JsonDirectWriter(JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxDepth: 1)))
        shallow.writeRawBeginObject()
        let depthError = @AssertThrows[JsonException](shallow.writeRawBeginArray())
        @Expect(depthError.code, "max_depth")
        shallow.writeRawEndObject()
        @Expect(shallow.finishString(), "{}")

        let semantic = JsonDirectWriter(JsonWriteConfig("", "", false, false,
            limits: JsonWriteLimits(maxDepth: 1)))
        semantic.startObject()
        semantic.writeName("x")
        let semanticDepthError = @AssertThrows[JsonException](semantic.writeRawBeginArray())
        @Expect(semanticDepthError.code, "max_depth")
        semantic.writeNull()
        semantic.endObject()
        @Expect(semantic.finishString(), "{\"x\":null}")

        @Expect(!JsonArrayValue().add(JsonIntValue(1)).equivalentTo(
            JsonArrayValue().add(JsonIntValue(2))))
        @Expect(!JsonArrayValue().equivalentTo(JsonArrayValue().add(JsonIntValue(1))))
        @Expect(!JsonObjectValue().put("a", JsonIntValue(1)).equivalentTo(
            JsonObjectValue().put("b", JsonIntValue(1))))
        @Expect(!JsonObjectValue().put("a", JsonIntValue(1)).equivalentTo(
            JsonObjectValue().put("a", JsonIntValue(2))))
        @Expect(!JsonObjectValue().equivalentTo(JsonObjectValue().put("a", JsonIntValue(1))))

        let equalArray = JsonArrayValue().add(JsonIntValue(1)).add(JsonStringValue("x"))
        @Expect(equalArray.deepCopy().equivalentTo(equalArray))
        let equalObject = JsonObjectValue().put("a", JsonIntValue(1)).put("b", JsonStringValue("x"))
        @Expect(equalObject.deepCopy().equivalentTo(equalObject))
        @Expect(JsonArrayValue().deepCopy().equivalentTo(JsonArrayValue()))
        @Expect(JsonObjectValue().deepCopy().equivalentTo(JsonObjectValue()))
    }
}
