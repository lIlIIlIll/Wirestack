package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonAuditContractRegressionTest {
    @TestCase
    func recursiveJsonNodeOperationsRejectCyclesButAcceptSharedDags(): Unit {
        let arrayCycle = JsonArray()
        arrayCycle.add(arrayCycle)
        let compactError = @AssertThrows[JsonException]((arrayCycle).toJson())
        @Expect(compactError.code, "cyclic_json_node")
        let prettyError = @AssertThrows[JsonException]((arrayCycle).toJson(options: JsonWriteOptions.pretty()))
        @Expect(prettyError.code, "cyclic_json_node")
        let copyError = @AssertThrows[JsonException](arrayCycle.deepCopy())
        @Expect(copyError.code, "cyclic_json_node")
        let equivalentError = @AssertThrows[JsonException](arrayCycle.equivalentTo(arrayCycle))
        @Expect(equivalentError.code, "cyclic_json_node")
        let mismatchedRight = JsonArray().add(JsonIntValue(0))
        @Expect(@AssertThrows[JsonException](arrayCycle.equivalentTo(mismatchedRight)).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](mismatchedRight.equivalentTo(arrayCycle)).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](arrayCycle.equivalentTo(JsonArray())).code,
            "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](JsonArray().equivalentTo(arrayCycle)).code,
            "cyclic_json_node")

        let objectCycle = JsonObject()
        objectCycle.put("self", objectCycle)
        let objectError = @AssertThrows[JsonException](objectCycle.toString())
        @Expect(objectError.code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](objectCycle.equivalentTo(JsonObject())).code,
            "cyclic_json_node")

        let first = JsonObject()
        let second = JsonArray()
        first.put("next", second)
        second.values().add(first)
        let indirectError = @AssertThrows[JsonException](first.deepCopy())
        @Expect(indirectError.code, "cyclic_json_node")

        let shared = JsonArray().add(JsonIntValue(1))
        let dag = JsonObject().put("left", shared).put("right", shared)
        @Expect((dag).toJson(), "{\"left\":[1],\"right\":[1]}")
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
        let config = JsonWriteOptions(maxDepth: 1)

        let direct = JsonDirectWriter(config)
        direct.startArray()
        let directError = @AssertThrows[JsonException](direct.startObject())
        @Expect(directError.code, "max_depth")
        direct.endArray()
        @Expect(direct.finishString(), "[]")

        let ast = JsonArray().add(JsonArray())
        let astError = @AssertThrows[JsonException]((ast).toJson(options: config))
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
        let limited = JsonWriteOptions(maxOutputBytes: 3)
        let output = MemoryOutputStream()
        let writer = JsonDirectWriter(output, config: limited)
        let error = @AssertThrows[JsonException](writer.writeString("long"))
        @Expect(error.code, "output_too_large")
        @Expect(output.toByteArray().size <= 3)
        let terminalError = @AssertThrows[JsonException](writer.finish())
        @Expect(terminalError.code, "output_too_large")
        @Expect(output.toByteArray().size <= 3)

        let exact = MemoryOutputStream()
        let exactWriter = JsonDirectWriter(exact, config: JsonWriteOptions(maxOutputBytes: 6))
        exactWriter.writeString("long")
        exactWriter.finish()
        @Expect(exact.toUtf8String(), "\"long\"")
    }

    @TestCase
    func runeCodecRequiresExactlyOneUnicodeScalarAcrossInputs(): Unit {
        @Expect(YJson.fromJson("\"a\"", codec: JsonCodecs.rune).toString(), "a")
        @Expect(YJson.fromJson("\"仓\"", codec: JsonCodecs.rune).toString(), "仓")
        @Expect(YJson.fromJson("\"😀\"", codec: JsonCodecs.rune).toString(), "😀")
        @Expect(YJson.fromJson("\"\\uD83D\\uDE00\"", codec: JsonCodecs.rune).toString(), "😀")
        for (text in ["\"\"", "\"ab\"", "\"é\"", "\"😀😀\"", "\"a\\u4ed3\""]) {
            let error = @AssertThrows[JsonException](YJson.fromJson(text, codec: JsonCodecs.rune))
            @Expect(error.code, "invalid_value")
        }
        let streamError = @AssertThrows[JsonException](YJson.fromJson(ByteArrayInputStream("\"ab\""), codec: JsonCodecs.rune))
        @Expect(streamError.code, "invalid_value")
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
            @Expect(root.member("missing-${index}").isNone())
        }
        @Expect(root.member("key63").getOrThrow().asInt64(), 63)
        @Expect(root.member("missing-0").isNone())
    }

    @TestCase
    func genericCompactMapHandlesEmptyPlainAndEscapedKeys(): Unit {
        let codec = JsonCodecs.stringMap(JsonCodecs.string)
        let empty = HashMap<String, String>()
        @Expect(YJson.toJson(empty, codec: codec), "{}")

        let single = HashMap<String, String>()
        single["only"] = "value"
        @Expect(YJson.fromJson(YJson.toJson(single, codec: codec), codec: codec)["only"], "value")

        let values = HashMap<String, String>()
        values["plain"] = "first"
        values["line\nkey"] = "second"
        let encoded = YJson.toJson(values, codec: codec)
        let decoded = YJson.fromJson(encoded, codec: codec)
        @Expect(decoded.size, 2)
        @Expect(decoded["plain"], "first")
        @Expect(decoded["line\nkey"], "second")

        let many = HashMap<String, String>()
        for (index in 0..16) { many["key-${index}"] = "value-${index}" }
        let decodedMany = YJson.fromJson(YJson.toJson(many, codec: codec), codec: codec)
        @Expect(decodedMany.size, 16)
        @Expect(decodedMany["key-15"], "value-15")
    }

    @TestCase
    func streamTargetHandlesLargeExactAndRepeatedLimitFailures(): Unit {
        let builder = StringBuilder()
        for (_ in 0..10000) { builder.append("x") }
        let large = builder.toString()

        let exactOutput = MemoryOutputStream()
        let exact = JsonDirectWriter(exactOutput, config: JsonWriteOptions(maxOutputBytes: 10002))
        exact.writeString(large)
        exact.finish()
        @Expect(exactOutput.toByteArray().size, 10002)

        let limitedOutput = MemoryOutputStream()
        let limited = JsonDirectWriter(limitedOutput, config: JsonWriteOptions(maxOutputBytes: 10001))
        let first = @AssertThrows[JsonException](limited.writeString(large))
        @Expect(first.code, "output_too_large")
        @Expect(first.location.isNone())
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
        let bytesTarget = DirectStreamWriterTarget(bytesOutput, JsonWriteOptions.compact)
        bytesTarget.writeBytes(bytes[1..9001])
        bytesTarget.finish()
        @Expect(bytesOutput.toByteArray().size, 9000)

        let rangeOutput = MemoryOutputStream()
        let rangeTarget = DirectStreamWriterTarget(rangeOutput, JsonWriteOptions.compact)
        rangeTarget.writeBytesRange(bytes, 1, 9001)
        rangeTarget.finish()
        @Expect(rangeOutput.toByteArray().size, 9000)

        let byteLimitTarget = DirectStreamWriterTarget(MemoryOutputStream(), JsonWriteOptions(maxOutputBytes: 1))
        let byteLimitError = @AssertThrows[JsonException](byteLimitTarget.writeBytes([b'a', b'b']))
        @Expect(byteLimitError.code, "output_too_large")
        @Expect(byteLimitError.location.isNone())
        let repeatedByteLimitError = @AssertThrows[JsonException](byteLimitTarget.writeByte(b'a'))
        @Expect(repeatedByteLimitError.code, "output_too_large")

        let byteByByteOutput = MemoryOutputStream()
        let byteByByteTarget = DirectStreamWriterTarget(byteByByteOutput, JsonWriteOptions.compact)
        for (_ in 0..8192) { byteByByteTarget.writeByte(b'a') }
        byteByByteTarget.finish()
        @Expect(byteByByteOutput.toByteArray().size, 8192)

        let digitOutput = MemoryOutputStream()
        let digitTarget = DirectStreamWriterTarget(digitOutput, JsonWriteOptions.compact)
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
            @Expect(YJson.fromJson(encoded, codec: JsonCodecs.arrayList(JsonCodecs.int64)), values)
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

        let lateCycle = JsonArray().add(JsonIntValue(1)).add(JsonStringValue("safe"))
        lateCycle.add(lateCycle)
        @Expect(@AssertThrows[JsonException](lateCycle.deepCopy()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](lateCycle.toString()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](lateCycle.equivalentTo(lateCycle)).code, "cyclic_json_node")

        let lateMismatchLeft = JsonArray().add(JsonIntValue(1)).add(JsonIntValue(2)).add(JsonIntValue(3))
        let lateMismatchRight = JsonArray().add(JsonIntValue(1)).add(JsonIntValue(2)).add(JsonIntValue(4))
        @Expect(!lateMismatchLeft.equivalentTo(lateMismatchRight))

        let wideCycle = JsonObject()
        for (index in 0..16) { wideCycle.put("safe-${index}", JsonIntValue(index)) }
        wideCycle.put("cycle", wideCycle)
        @Expect(@AssertThrows[JsonException](wideCycle.deepCopy()).code, "cyclic_json_node")
        @Expect(@AssertThrows[JsonException](wideCycle.toString()).code, "cyclic_json_node")

        let wideLeft = JsonObject()
        let wideRight = JsonObject()
        for (index in 0..16) {
            wideLeft.put("field-${index}", JsonIntValue(index))
            wideRight.put("field-${index}", JsonIntValue(index))
        }
        wideRight.put("field-15", JsonIntValue(99))
        @Expect(!wideLeft.equivalentTo(wideRight))

        let unbalanced = JsonDirectWriter()
        let unbalancedError = @AssertThrows[JsonException](unbalanced.writeRawEndObject())
        @Expect(unbalancedError.code, "writer_state")

        let mismatchedArray = JsonDirectWriter()
        mismatchedArray.writeRawBeginArray()
        let arrayCloseError = @AssertThrows[JsonException](mismatchedArray.writeRawEndObject())
        @Expect(arrayCloseError.code, "writer_state")
        mismatchedArray.writeRawEndArray()
        @Expect(mismatchedArray.finishString(), "[]")

        let mismatchedObject = JsonDirectWriter.bytes()
        @Expect(mismatchedObject.tryBeginGeneratedCompactRawValue())
        mismatchedObject.writeRawBeginObject()
        let objectCloseError = @AssertThrows[JsonException](mismatchedObject.writeRawEndArray())
        @Expect(objectCloseError.code, "writer_state")
        mismatchedObject.writeRawEndObject()
        @Expect(String.fromUtf8(mismatchedObject.finishBytes()), "{}")

        let deepRaw = JsonDirectWriter(JsonWriteOptions(maxDepth: 80))
        for (_ in 0..66) { deepRaw.writeRawBeginArray() }
        let deepCloseError = @AssertThrows[JsonException](deepRaw.writeRawEndObject())
        @Expect(deepCloseError.code, "writer_state")
        for (_ in 0..66) { deepRaw.writeRawEndArray() }
        @Expect(deepRaw.finishString().size, 132)

        let shallow = JsonDirectWriter(JsonWriteOptions(maxDepth: 1))
        shallow.writeRawBeginObject()
        let depthError = @AssertThrows[JsonException](shallow.writeRawBeginArray())
        @Expect(depthError.code, "max_depth")
        shallow.writeRawEndObject()
        @Expect(shallow.finishString(), "{}")

        let semantic = JsonDirectWriter(JsonWriteOptions(maxDepth: 1))
        semantic.startObject()
        semantic.writeName("x")
        let semanticDepthError = @AssertThrows[JsonException](semantic.writeRawBeginArray())
        @Expect(semanticDepthError.code, "max_depth")
        semantic.writeNull()
        semantic.endObject()
        @Expect(semantic.finishString(), "{\"x\":null}")

        @Expect(!JsonArray().add(JsonIntValue(1)).equivalentTo(
            JsonArray().add(JsonIntValue(2))))
        @Expect(!JsonArray().equivalentTo(JsonArray().add(JsonIntValue(1))))
        @Expect(!JsonObject().put("a", JsonIntValue(1)).equivalentTo(
            JsonObject().put("b", JsonIntValue(1))))
        @Expect(!JsonObject().put("a", JsonIntValue(1)).equivalentTo(
            JsonObject().put("a", JsonIntValue(2))))
        @Expect(!JsonObject().equivalentTo(JsonObject().put("a", JsonIntValue(1))))

        let equalArray = JsonArray().add(JsonIntValue(1)).add(JsonStringValue("x"))
        @Expect(equalArray.deepCopy().equivalentTo(equalArray))
        let equalObject = JsonObject().put("a", JsonIntValue(1)).put("b", JsonStringValue("x"))
        @Expect(equalObject.deepCopy().equivalentTo(equalObject))
        @Expect(JsonArray().deepCopy().equivalentTo(JsonArray()))
        @Expect(JsonObject().deepCopy().equivalentTo(JsonObject()))

        var deepManualTree: JsonNode = JsonNullValue()
        for (_ in 0..257) { deepManualTree = JsonArray().add(deepManualTree) }
        @Expect(@AssertThrows[JsonException](deepManualTree.deepCopy()).code, "max_depth")
        @Expect(@AssertThrows[JsonException](deepManualTree.equivalentTo(deepManualTree)).code,
            "max_depth")

        let withinWorkBudget = JsonArray()
        let beyondWorkBudget = JsonArray()
        let sharedNull = JsonNullValue()
        for (_ in 0..99999) {
            withinWorkBudget.add(sharedNull)
            beyondWorkBudget.add(sharedNull)
        }
        beyondWorkBudget.add(sharedNull)
        @Expect(withinWorkBudget.deepCopy().asArray().size(), 99999)
        @Expect(@AssertThrows[JsonException](beyondWorkBudget.deepCopy()).code,
            "work_limit_exceeded")
    }
}
