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
    func pathChargesEnumeratedChildrenAndFilterSubqueries(): Unit {
        let root = YJson.parse("[{\"nested\":{\"value\":1}}]")
        @AssertThrows[JsonWorkLimitException](JsonPath.parse("$[*]").query(root,
            limits: JsonPathLimits(maxVisitedNodes: 1)))
        @AssertThrows[JsonWorkLimitException](JsonPath.parse("$[?count(@..*) > 0]").query(root,
            limits: JsonPathLimits(maxVisitedNodes: 2)))
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
    func patchChargesValuesAndEachDynamicCopyBeforeAllocation(): Unit {
        let target = YJson.parse("{\"source\":[1,2],\"copies\":[]}")
        let oneCopy = JsonPatch.parse(
            "[{\"op\":\"copy\",\"from\":\"/source\",\"path\":\"/copies/-\"}]")
        let oneCopyResult = oneCopy.apply(target, limits: JsonPatchLimits(maxCopiedNodes: 8))
        @Expect(oneCopyResult["copies"].array.size(), 1)

        let twoCopies = JsonPatch.parse(
            "[{\"op\":\"copy\",\"from\":\"/source\",\"path\":\"/copies/-\"}," +
            "{\"op\":\"copy\",\"from\":\"/source\",\"path\":\"/copies/-\"}]")
        @AssertThrows[JsonWorkLimitException](twoCopies.apply(target,
            limits: JsonPatchLimits(maxCopiedNodes: 10)))

        let tested = JsonPatch.parse(
            "[{\"op\":\"test\",\"path\":\"/source\",\"value\":[1,2]}]")
        @AssertThrows[JsonWorkLimitException](tested.apply(target,
            limits: JsonPatchLimits(maxCopiedNodes: 7)))
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
    func schemaChargesUniqueComparisonsAndTracksRecursiveDepth(): Unit {
        let exact = JsonSchema.parse("{\"uniqueItems\":true}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxEvaluations: 2)))
        @Expect(exact.validate(YJson.parse("[1,2]")).isEmpty())
        let comparisonOverflow = JsonSchema.parse("{\"uniqueItems\":true}",
            config: JsonSchemaConfig(limits: JsonSchemaLimits(maxEvaluations: 1)))
        @AssertThrows[JsonWorkLimitException](comparisonOverflow.validate(YJson.parse("[1,2]")))

        let registry = JsonSchemaRegistry()
        registry.register("https://example.com/a/very/long/schema/path", "true")
        let shallow = JsonSchemaConfig(resolver: Some<UriResolver>(registry),
            limits: JsonSchemaLimits(maxDepth: 1))
        @Expect(JsonSchema.parse(
            "{\"$ref\":\"https://example.com/a/very/long/schema/path\"}", config: shallow)
            .validate(JsonNullValue()).isEmpty())

        registry.register("https://example.com/nested", "{\"properties\":{\"a\":true}}")
        let nested = JsonSchema.parse("{\"$ref\":\"https://example.com/nested\"}", config: shallow)
        @AssertThrows[JsonWorkLimitException](nested.validate(YJson.parse("{\"a\":1}")))
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
