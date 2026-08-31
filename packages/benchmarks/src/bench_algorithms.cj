package yjson_benchmarks

import yjson.*
import yjson_algorithms.*

import std.unittest.*
import std.unittest.testmacro.*

private let ALGORITHM_ITEM_COUNT: Int64 = 8192

private func algorithmDocumentText(): String {
    let builder = StringBuilder()
    builder.append("[")
    for (index in 0..ALGORITHM_ITEM_COUNT) {
        if (index > 0) { builder.append(",") }
        builder.append("{\"id\":${index}}")
    }
    builder.append("]")
    builder.toString()
}

class AlgorithmOptimizationFixture {
    let document: JsonDocument
    let path: JsonPath
    let schemaText: String
    let schema: JsonSchema
    let instance: JsonDocument

    init() {
        document = YJson.parseDocument(algorithmDocumentText())
        path = JsonPath.parse("$[*].id")
        schemaText = "{\"$defs\":{\"name\":{\"type\":\"string\"," +
            "\"pattern\":\"^[A-Z][A-Za-z0-9_-]+$\"}},\"type\":\"object\"," +
            "\"required\":[\"name\"],\"properties\":{\"name\":{\"$ref\":\"#/$defs/name\"}}}"
        schema = JsonSchema.parse(schemaText)
        instance = YJson.parseDocument("{\"name\":\"Alice_01\"}")
        verify()
    }

    func verify(): Unit {
        @Expect(path.first(document.root()).getOrThrow().value.asInt64(), 0)
        @Expect(path.collectValues(document.root()).size, ALGORITHM_ITEM_COUNT)
        @Expect(path.first(document.materialize()).getOrThrow().value.asInt64(), 0)
        @Expect(schema.isValid(instance))
        @Expect(JsonSchema.parse(schemaText).isValid(instance))
    }
}

@Test
class AlgorithmOptimizationContractTest {
    @TestCase
    func comparedPathsHaveTheSameObservableResult(): Unit {
        AlgorithmOptimizationFixture().verify()
    }
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class AlgorithmOptimizationBenchmarks {
    let fixture = AlgorithmOptimizationFixture()
    var intSink: Int64 = 0
    var boolSink: Bool = false

    @Bench
    func jsonPathViewFirst(): Unit {
        intSink = fixture.path.first(fixture.document.root()).getOrThrow().value.asInt64()
    }

    @Bench
    func jsonPathCollectThenFirst(): Unit {
        intSink = fixture.path.collectValues(fixture.document.root())[0].asInt64()
    }

    @Bench
    func jsonPathMaterializeThenFirst(): Unit {
        intSink = fixture.path.first(fixture.document.materialize()).getOrThrow().value.asInt64()
    }

    @Bench
    func schemaCompiledValidation(): Unit {
        boolSink = fixture.schema.isValid(fixture.instance)
    }

    @Bench
    func schemaCompileThenValidation(): Unit {
        boolSink = JsonSchema.parse(fixture.schemaText).isValid(fixture.instance)
    }
}
