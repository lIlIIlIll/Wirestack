package yjson_algorithms

import yjson.*

import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func yJsonSchemaErrors(schemaText: String, instanceText: String): JsonSchemaResult {
    JsonSchema.parse(schemaText).validate(JsonNode.parse(instanceText))
}

func yJsonSchemaValid(schemaText: String, instanceText: String): Bool {
    yJsonSchemaErrors(schemaText, instanceText).isEmpty()
}

private class EvenLengthSchemaFormat <: JsonSchemaFormat {
    public func validate(value: String): Bool { value.toRuneArray().size % 2 == 0 }
}

private class TestSchemaFormatProvider <: JsonSchemaFormatProvider {
    public func installInto(registry: JsonSchemaFormatRegistry): Unit {
        registry.register("even-length", EvenLengthSchemaFormat())
    }
}

private class OneShotSchemaResolver <: UriResolver {
    var enabled: Bool = true
    var calls: Int64 = 0
    private let resource: JsonNode

    init(resource: JsonNode) { this.resource = resource }

    public func resolve(uri: String): Option<JsonNode> {
        calls++
        if (!enabled) { throw Exception("resolver called after schema compilation") }
        if (uri == "urn:test:frozen") { Some(resource.deepCopy()) }
        else { None<JsonNode> }
    }
}

@Test
class YJsonSchemaTest {
    @TestCase
    func schemaSnapshotsDocumentAndDefaultFormats(): Unit {
        let source = JsonNode.parse("{\"type\":\"string\"}")
        let schema = JsonSchema.fromValue(source)
        source.asObject().put("type", JsonNode.string("integer"))
        @Expect(schema.validate(JsonNode.parse("\"ok\"")).isEmpty())
        let exposed = schema.document
        exposed.asObject().put("type", JsonNode.string("integer"))
        @Expect(schema.validate(JsonNode.parse("\"still a string\"")).isEmpty())
        @Expect(!schema.validate(JsonNode.parse("42")).isEmpty())
        let _ = @AssertThrows[IllegalStateException](
            JsonSchemaConfig.defaults.formats.register("mutable-default", EvenLengthSchemaFormat()))
    }
    @TestCase
    func booleanSchemasAcceptAndReject(): Unit {
        @Expect(yJsonSchemaValid("true", "{\"anything\":1}"))
        let errors = yJsonSchemaErrors("false", "null")
        @Expect(errors.size, 1)
        @Expect(errors[0].instancePath, "")
        @Expect(errors[0].schemaPath, "#")
    }

    @TestCase
    func typeKeywordSupportsSingleAndUnionTypes(): Unit {
        @Expect(yJsonSchemaValid("{\"type\":\"object\"}", "{\"id\":1}"))
        @Expect(yJsonSchemaValid("{\"type\":[\"string\",\"integer\"]}", "42"))

        let errors = yJsonSchemaErrors("{\"type\":\"array\"}", "{\"id\":1}")
        @Expect(errors.size, 1)
        @Expect(errors[0].schemaPath, "#/type")
        @Expect(errors[0].message.contains("expected type array"))
    }

    @TestCase
    func objectRequiredAndPropertiesReportNestedPaths(): Unit {
        let schema = "{\"type\":\"object\",\"required\":[\"id\",\"name\"],\"properties\":{\"id\":{\"type\":\"integer\"},\"name\":{\"minLength\":2}}}"
        @Expect(yJsonSchemaValid(schema, "{\"id\":7,\"name\":\"Li\"}"))

        let errors = yJsonSchemaErrors(schema, "{\"id\":\"7\",\"name\":\"L\"}")
        @Expect(errors.size, 2)
        @Expect(errors[0].instancePath, "/id")
        @Expect(errors[0].schemaPath, "#/properties/id/type")
        @Expect(errors[1].instancePath, "/name")
        @Expect(errors[1].schemaPath, "#/properties/name/minLength")

        let missing = yJsonSchemaErrors(schema, "{\"id\":1}")
        @Expect(missing.size, 1)
        @Expect(missing[0].schemaPath, "#/required/1")
        @Expect(missing[0].message.contains("missing required property name"))
    }

    @TestCase
    func itemsValidatesEveryArrayElement(): Unit {
        let schema = "{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":0}}"
        @Expect(yJsonSchemaValid(schema, "[0,1,2]"))

        let errors = yJsonSchemaErrors(schema, "[0,-1,\"x\"]")
        @Expect(errors.size, 2)
        @Expect(errors[0].instancePath, "/1")
        @Expect(errors[0].schemaPath, "#/items/minimum")
        @Expect(errors[1].instancePath, "/2")
        @Expect(errors[1].schemaPath, "#/items/type")
    }

    @TestCase
    func enumAndConstUseJsonValueSemantics(): Unit {
        @Expect(yJsonSchemaValid("{\"enum\":[1,\"two\",{\"ok\":true}]}", "{\"ok\":true}"))
        @Expect(yJsonSchemaValid("{\"const\":{\"id\":1,\"tags\":[\"a\"]}}", "{\"tags\":[\"a\"],\"id\":1}"))

        let enumErrors = yJsonSchemaErrors("{\"enum\":[1,2,3]}", "4")
        @Expect(enumErrors.size, 1)
        @Expect(enumErrors[0].schemaPath, "#/enum")

        let constErrors = yJsonSchemaErrors("{\"const\":\"fixed\"}", "\"other\"")
        @Expect(constErrors.size, 1)
        @Expect(constErrors[0].schemaPath, "#/const")
    }

    @TestCase
    func numericAndStringBoundsAreAppliedByInstanceType(): Unit {
        @Expect(yJsonSchemaValid("{\"minimum\":1,\"maximum\":3}", "2"))
        @Expect(yJsonSchemaValid("{\"minLength\":2,\"maxLength\":3}", "\"仓颉\""))

        let numberErrors = yJsonSchemaErrors("{\"minimum\":1,\"maximum\":3}", "4")
        @Expect(numberErrors.size, 1)
        @Expect(numberErrors[0].schemaPath, "#/maximum")

        let stringErrors = yJsonSchemaErrors("{\"minLength\":2,\"maxLength\":3}", "\"a\"")
        @Expect(stringErrors.size, 1)
        @Expect(stringErrors[0].schemaPath, "#/minLength")
    }

    @TestCase
    func combinatorsAllOfAnyOfOneOfAndNot(): Unit {
        @Expect(yJsonSchemaValid("{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":1}]}", "3"))
        @Expect(yJsonSchemaValid("{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", "3"))
        @Expect(yJsonSchemaValid("{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", "\"x\""))
        @Expect(yJsonSchemaValid("{\"not\":{\"type\":\"null\"}}", "true"))

        let allOfErrors = yJsonSchemaErrors("{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":1}]}", "0")
        @Expect(allOfErrors.size, 1)
        @Expect(allOfErrors[0].schemaPath, "#/allOf/1/minimum")

        let anyOfErrors = yJsonSchemaErrors("{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"array\"}]}", "false")
        @Expect(anyOfErrors.size, 1)
        @Expect(anyOfErrors[0].schemaPath, "#/anyOf")

        let oneOfErrors = yJsonSchemaErrors("{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}", "1")
        @Expect(oneOfErrors.size, 1)
        @Expect(oneOfErrors[0].message.contains("matched 2"))

        let notErrors = yJsonSchemaErrors("{\"not\":{\"type\":\"null\"}}", "null")
        @Expect(notErrors.size, 1)
        @Expect(notErrors[0].schemaPath, "#/not")
    }

    @TestCase
    func localRefResolvesDefinitionsAndReportsTargetSchemaPath(): Unit {
        let schema = "{\"$defs\":{\"positiveId\":{\"type\":\"integer\",\"minimum\":1}},\"type\":\"object\",\"properties\":{\"id\":{\"$ref\":\"#/$defs/positiveId\"}}}"
        @Expect(yJsonSchemaValid(schema, "{\"id\":7}"))

        let errors = yJsonSchemaErrors(schema, "{\"id\":0}")
        @Expect(errors.size, 1)
        @Expect(errors[0].instancePath, "/id")
        @Expect(errors[0].schemaPath, "#/$defs/positiveId/minimum")
    }

    @TestCase
    func invalidLocalRefReturnsValidationError(): Unit {
        let errors = yJsonSchemaErrors("{\"$ref\":\"#/$defs/missing\"}", "1")
        @Expect(errors.size, 1)
        @Expect(errors[0].schemaPath, "#/$ref")
        @Expect(errors[0].message.contains("unresolved local $ref"))
    }

    @TestCase
    func draft202012NumericStringArrayAndObjectKeywords(): Unit {
        @Expect(yJsonSchemaValid("{\"multipleOf\":0.01,\"exclusiveMinimum\":1}", "1.25"))
        @Expect(!yJsonSchemaValid("{\"multipleOf\":0.01}", "1.001"))
        @Expect(yJsonSchemaValid("{\"type\":\"integer\"}", "1.0"))
        @Expect(!yJsonSchemaValid("{\"pattern\":\"^[A-Z]+$\"}", "\"Ab\""))
        let arraySchema = "{\"prefixItems\":[{\"type\":\"string\"}],\"items\":{\"type\":\"integer\"}," +
            "\"contains\":{\"minimum\":10},\"minContains\":1,\"uniqueItems\":true}"
        @Expect(yJsonSchemaValid(arraySchema, "[\"id\",10,11]"))
        @Expect(!yJsonSchemaValid(arraySchema, "[\"id\",2,2]"))
        let objectSchema = "{\"properties\":{\"id\":true,\"name\":true},\"patternProperties\":{\"^x-\":{\"type\":\"string\"}}," +
            "\"additionalProperties\":false,\"dependentRequired\":{\"id\":[\"name\"]}}"
        @Expect(yJsonSchemaValid(objectSchema, "{\"id\":1,\"name\":\"n\",\"x-a\":\"v\"}"))
        @Expect(!yJsonSchemaValid(objectSchema, "{\"id\":1,\"other\":true}"))
    }

    @TestCase
    func schemaRegexesCompileOnceWhileRegexFormatValidatesEcmaSyntax(): Unit {
        @Expect(@AssertThrows[JsonException](JsonSchema.parse("{\"pattern\":\"(a)\\\\1\"}")).code,
            "invalid_regex")

        let assertion = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
        @Expect(JsonSchema.parse("{\"format\":\"regex\"}", config: assertion)
            .isValid(JsonNode.string("^[A-Z]+$")))
        let regexFormat = JsonSchema.parse("{\"format\":\"regex\"}", config: assertion)
        @Expect(regexFormat.isValid(JsonNode.string("(?<name>x)")))
        @Expect(regexFormat.isValid(JsonNode.string("(?<n>a)\\k<n>")))
        @Expect(regexFormat.isValid(JsonNode.string("(?<=a+)b")))
        @Expect(regexFormat.isValid(JsonNode.string("(a)\\1")))
        @Expect(!regexFormat.isValid(JsonNode.string("\\a")))
        @Expect(!regexFormat.isValid(JsonNode.string("(?P<name>x)")))
        @Expect(!regexFormat.isValid(JsonNode.string("(?i)abc")))

        let configured = JsonSchemaConfig(limits: JsonSchemaLimits(maxRegexSteps: 200))
        let schema = JsonSchema.parse("{\"pattern\":\"^(a+)+$\"}", config: configured)
        let value = StringBuilder()
        for (_ in 0..1000) { value.append("a") }
        value.append("X")
        @Expect(@AssertThrows[JsonException](schema.isValid(JsonNode.string(value.toString()))).code,
            "work_limit_exceeded")
    }

    @TestCase
    func registryResolvesExternalPointersAndAnchors(): Unit {
        let registry = JsonSchemaRegistry()
        registry.register("urn:test:defs", "{\"$defs\":{\"positive\":{\"$anchor\":\"positive\",\"type\":\"integer\",\"minimum\":1}}}")
        let config = JsonSchemaConfig(resolver: Some<UriResolver>(registry))
        @Expect(JsonSchema.parse("{\"$ref\":\"urn:test:defs#positive\"}", config: config).validator().isValid(JsonNode.int64(2)))
        @Expect(!JsonSchema.parse("{\"$ref\":\"urn:test:defs#/$defs/positive\"}", config: config).validator().isValid(JsonNode.int64(0)))
    }

    @TestCase
    func resolverGraphIsDetachedDuringCompilation(): Unit {
        let resolver = OneShotSchemaResolver(JsonNode.parse("{\"type\":\"integer\"}"))
        let schema = JsonSchema.parse("{\"$ref\":\"urn:test:frozen\"}",
            config: JsonSchemaConfig(resolver: Some<UriResolver>(resolver)))
        @Expect(resolver.calls, 1)
        @Expect(schema.config.resolver.isNone())
        resolver.enabled = false
        @Expect(schema.isValid(JsonNode.int64(7)))
        @Expect(!schema.isValid(JsonNode.string("7")))
        @Expect(resolver.calls, 1)
    }

    @TestCase
    func unsupportedDialectAndOptInFormatAssertion(): Unit {
        @AssertThrows[JsonException](JsonSchema.parse("{\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"))
        @Expect(JsonSchema.parse("{\"format\":\"ipv4\"}").validator().isValid(JsonNode.string("999.1.1.1")))
        let strict = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
        @Expect(!JsonSchema.parse("{\"format\":\"ipv4\"}", config: strict).validator().isValid(JsonNode.string("999.1.1.1")))
    }

    @TestCase
    func formatModesTreatUnknownFormatsAsAnnotations(): Unit {
        let unknownSchema = "{\"format\":\"application-specific\"}"
        @Expect(JsonSchema.parse(unknownSchema).validator().isValid(JsonNode.string("value")))
        let assertion = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
        @Expect(JsonSchema.parse(unknownSchema, config: assertion).validator().isValid(JsonNode.string("value")))

        let formats = JsonSchemaFormatRegistry.withCoreFormats()
        formats.install(TestSchemaFormatProvider())
        let configured = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion, formats: formats)
        @Expect(JsonSchema.parse("{\"format\":\"even-length\"}", config: configured)
            .validator().isValid(JsonNode.string("仓颉")))
        @Expect(!JsonSchema.parse("{\"format\":\"even-length\"}", config: configured)
            .validator().isValid(JsonNode.string("json!")))
        @AssertThrows[IllegalArgumentException](formats.register("even-length", EvenLengthSchemaFormat()))
    }

    @TestCase
    func concurrentValidateCallsAreIndependent(): Unit {
        let schema = JsonSchema.parse("""
            {"type":"object","required":["id"],"properties":{"id":{"type":"integer","minimum":1}},
             "anyOf":[{"required":["a"]},{"required":["b"]}],
             "patternProperties":{"^x-":{"type":"string"}}}
        """)
        let validator = schema.validator()
        let valid = JsonNode.parse("{\"id\":7,\"a\":1,\"x-note\":\"n\"}")
        let invalid = JsonNode.parse("{\"id\":0,\"b\":true}")
        let barrier = Barrier(3)
        let ready = SyncCounter(3)
        let start = SyncCounter(1)
        let futures = ArrayList<Future<JsonSchemaResult>>()
        for (_ in 0..3) {
            futures.add(spawn {
                ready.dec()
                start.waitUntilZero(timeout: Duration.second * 5)
                barrier.wait(timeout: Duration.second * 5)
                schema.validate(valid)
            })
        }
        ready.waitUntilZero(timeout: Duration.second * 5)
        start.dec()
        for (future in futures) {
            let result = future.get()
            @Expect(result.valid)
            @Expect(result.size, 0)
        }
        // 同一 validator 继续给出独立、正确的结果
        @Expect(validator.validate(invalid).size, 1)
        @Expect(validator.validate(valid).isEmpty())
    }

    @TestCase
    func concurrentValidateAndIsValidAreIndependent(): Unit {
        let schema = JsonSchema.parse(
            "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":1}}}")
        let validator = schema.validator()
        let valid = JsonNode.parse("{\"id\":7}")
        let invalid = JsonNode.parse("{\"id\":0}")
        let barrier = Barrier(4)
        let ready = SyncCounter(4)
        let start = SyncCounter(1)
        let futures = ArrayList<Future<Bool>>()
        for (_ in 0..3) {
            futures.add(spawn {
                ready.dec()
                start.waitUntilZero(timeout: Duration.second * 5)
                barrier.wait(timeout: Duration.second * 5)
                validator.isValid(invalid)
            })
        }
        ready.waitUntilZero(timeout: Duration.second * 5)
        start.dec()
        barrier.wait(timeout: Duration.second * 5)
        let mainResult = validator.validate(valid)
        @Expect(mainResult.valid)
        for (future in futures) { @Expect(!future.get()) }
        // 同一 validator 继续给出独立、正确的结果
        @Expect(validator.isValid(valid))
        @Expect(!validator.validate(invalid).isEmpty())
    }
}
