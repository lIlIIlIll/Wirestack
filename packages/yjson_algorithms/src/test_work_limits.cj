package yjson_algorithms

import yjson.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class JsonAlgorithmWorkLimitsTest {
    @TestCase
    func pathAcceptsNAndRejectsNPlusOne(): Unit {
        let root = YJson.parse("{\"a\":1,\"b\":2}")
        @Expect(JsonPath.parse("$.a").query(root,
            limits: JsonPathLimits(maxVisitedNodes: 1, maxMatches: 1)).size, 1)
        let error = @AssertThrows[JsonWorkLimitException](JsonPath.parse("$.*").query(root,
            limits: JsonPathLimits(maxMatches: 1)))
        @Expect(error.code, "work_limit_exceeded")
    }

    @TestCase
    func patchAcceptsNAndRejectsNPlusOne(): Unit {
        let target = YJson.parse("{\"a\":1}")
        let one = JsonPatch.parse("[{\"op\":\"replace\",\"path\":\"/a\",\"value\":2}]")
        @Expect(one.apply(target, limits: JsonPatchLimits(maxOperations: 1))["a"].int64, 2)
        let two = JsonPatch.parse("[{\"op\":\"replace\",\"path\":\"/a\",\"value\":2}," +
            "{\"op\":\"replace\",\"path\":\"/a\",\"value\":3}]")
        @AssertThrows[JsonWorkLimitException](two.apply(target,
            limits: JsonPatchLimits(maxOperations: 1)))
    }

    @TestCase
    func schemaAcceptsNAndRejectsNPlusOne(): Unit {
        let one = JsonSchema.fromValue(JsonBoolValue(true),
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxEvaluations: 1)))
        @Expect(one.validate(JsonNullValue()).isEmpty())
        let nested = JsonSchema.parse("{\"properties\":{\"a\":true}}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxEvaluations: 1)))
        let error = @AssertThrows[JsonWorkLimitException](nested.validate(YJson.parse("{\"a\":1}")))
        @Expect(error.code, "work_limit_exceeded")
    }

    @TestCase
    func schemaErrorLimitCountsProducedErrorsOnly(): Unit {
        let exact = JsonSchema.parse("{\"allOf\":[false,true]}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxErrors: 1)))
        @Expect(exact.validate(JsonNullValue()).size, 1)

        let overflow = JsonSchema.parse("{\"allOf\":[false,false]}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxErrors: 1)))
        let error = @AssertThrows[JsonWorkLimitException](overflow.validate(JsonNullValue()))
        @Expect(error.code, "work_limit_exceeded")
    }
}
