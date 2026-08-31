package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func semanticBytes(text: String): Array<Byte> {
    unsafe { text.rawData().clone() }
}

private func semanticError(action: () -> Unit): JsonException {
    try {
        action()
        throw Exception("expected JSON failure")
    } catch (error: JsonException) {
        error
    }
}

private func assertSameSemanticError(expected: JsonException, actual: JsonException,
    label: String): Unit {
    assertJson(actual.code == expected.code, "${label}: code")
    match ((expected.location, actual.location)) {
        case (Some(expectedLocation), Some(actualLocation)) =>
            assertJson(actualLocation.byteOffset == expectedLocation.byteOffset,
                "${label}: byte offset expected ${expectedLocation.byteOffset}, actual ${actualLocation.byteOffset}")
            assertJson(actualLocation.line == expectedLocation.line,
                "${label}: line expected ${expectedLocation.line}, actual ${actualLocation.line}")
            assertJson(actualLocation.column == expectedLocation.column,
                "${label}: column expected ${expectedLocation.column}, actual ${actualLocation.column}")
        case (None, None) => ()
        case _ => assertJson(false, "${label}: location presence")
    }
}

private func assertValidSemanticVector(text: String): Unit {
    let canonical = (JsonNode.parse(text)).toJson()
    @Expect((JsonNode.parse(semanticBytes(text))).toJson(), canonical)
    @Expect((YJson.parseDocument(text).materialize()).toJson(), canonical)
    @Expect((YJson.parseDocument(semanticBytes(text)).materialize()).toJson(), canonical)

    for (split in 1..text.size) {
        let streamed = parseJsonValueFromStream(SplitPointInputStream(text, split))
        assertJson((streamed).toJson() == canonical,
            "semantic stream split ${split} for ${text}")
    }
}

private func assertInvalidSemanticVector(text: String): Unit {
    let expected = semanticError({ => let _ = JsonNode.parse(text) })
    let bytesError = semanticError({ => let _ = JsonNode.parse(semanticBytes(text)) })
    assertSameSemanticError(expected, bytesError, "bytes ${text}")

    for (split in 1..text.size) {
        let streamError = semanticError({ =>
            let _ = parseJsonValueFromStream(SplitPointInputStream(text, split))
        })
        assertSameSemanticError(expected, streamError, "stream split ${split} for ${text}")
    }
}

@Test
class JsonSemanticVectorsTest {
    @TestCase
    func validGrammarIsIdenticalAcrossManagedAndIncrementalInputs(): Unit {
        let vectors = [
            "null",
            " true \r\n",
            "-0.125e+2",
            "\"plain\\n\\ttext\"",
            "\"\\u4E2D\\uD83D\\uDE42\"",
            "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
            "{\"escaped\\u005fkey\":\"value\",\"nested\":[{\"x\":1},[]]}"
        ]
        for (text in vectors) { assertValidSemanticVector(text) }
    }

    @TestCase
    func invalidGrammarHasNormalizedCodeAndLocationAtEverySplit(): Unit {
        let vectors = [
            "\"unterminated",
            "\"bad\\xescape\"",
            "\"\\uD83Dvalue\"",
            "01",
            "[1,]",
            "{\"a\" 1}",
            "{\"a\":true} trailing"
        ]
        for (text in vectors) { assertInvalidSemanticVector(text) }
    }

    @TestCase
    func invalidUtf8IsRejectedAtEveryByteSplit(): Unit {
        let bytes: Array<Byte> = [b'"', 0xF0, 0x28, 0x8C, 0x28, b'"']
        let expected = semanticError({ => let _ = JsonNode.parse(bytes) })
        for (split in 1..bytes.size) {
            let actual = semanticError({ =>
                let _ = parseJsonValueFromStream(SplitPointInputStream(bytes, split))
            })
            assertSameSemanticError(expected, actual, "invalid UTF-8 split ${split}")
        }
    }

    @TestCase
    func generatedRecursiveContainersUseTheSameStreamSemantics(): Unit {
        let text = "[{\"team\":[{\"profile_id\":7,\"alias\":\"中🙂\",\"level\":3}]}]"
        let expected = YJson.fromJson<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>(text)
        @Expect(expected.size, 1)
        assertProfileRecord(expected[0]["team"][0], 7, "中🙂", 3, "generated string")

        for (split in 1..text.size) {
            let actual = YJson.fromJson<ArrayList<HashMap<String, ArrayList<ProfileRecord>>>>(
                SplitPointInputStream(text, split))
            assertProfileRecord(actual[0]["team"][0], 7, "中🙂", 3,
                "generated split ${split}")
        }
        @Expect(YJson.toJson(expected), text)
    }
}
