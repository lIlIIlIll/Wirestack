package yjson_algorithms

import yjson.*

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func yJsonSchemaErrors(schemaText: String, instanceText: String): ArrayList<JsonValidationError> {
    JsonSchema.parse(schemaText).validate(YJson.parse(instanceText))
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

@Test
class YJsonSchemaTest {
    @TestCase
    func schemaSnapshotsDocumentAndDefaultFormats(): Unit {
        let source = YJson.parse("{\"type\":\"string\"}")
        let schema = JsonSchema.fromValue(source)
        source.asObject().put("type", JsonStringValue("integer"))
        @Expect(schema.validate(YJson.parse("\"ok\"")).isEmpty())
        let exposed = schema.document
        exposed.asObject().put("type", JsonStringValue("integer"))
        @Expect(schema.validate(YJson.parse("\"still a string\"")).isEmpty())
        @Expect(!schema.validate(YJson.parse("42")).isEmpty())
        let _ = @AssertThrows[IllegalStateException](
            JsonSchemaConfig.defaults.formats.register("mutable-default", EvenLengthSchemaFormat()))
    }
    @TestCase
    func booleanSchemasAcceptAndReject(): Unit {
        @Expect(yJsonSchemaValid("true", "{\"anything\":1}"))
        let errors = yJsonSchemaErrors("false", "null")
        @Expect(errors.size, 1)
        @Expect(errors[0].jsonPath, "$")
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
        @Expect(errors[0].jsonPath, "$[\"id\"]")
        @Expect(errors[0].schemaPath, "#/properties/id/type")
        @Expect(errors[1].jsonPath, "$[\"name\"]")
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
        @Expect(errors[0].jsonPath, "$[1]")
        @Expect(errors[0].schemaPath, "#/items/minimum")
        @Expect(errors[1].jsonPath, "$[2]")
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
        @Expect(errors[0].jsonPath, "$[\"id\"]")
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
    func registryResolvesExternalPointersAndAnchors(): Unit {
        let registry = JsonSchemaRegistry()
        registry.register("urn:test:defs", "{\"$defs\":{\"positive\":{\"$anchor\":\"positive\",\"type\":\"integer\",\"minimum\":1}}}")
        let config = JsonSchemaConfig(resolver: Some<UriResolver>(registry))
        @Expect(JsonSchema.parse("{\"$ref\":\"urn:test:defs#positive\"}", config: config).validator().isValid(JsonIntValue(2)))
        @Expect(!JsonSchema.parse("{\"$ref\":\"urn:test:defs#/$defs/positive\"}", config: config).validator().isValid(JsonIntValue(0)))
    }

    @TestCase
    func unsupportedDialectAndOptInFormatAssertion(): Unit {
        @AssertThrows[JsonException](JsonSchema.parse("{\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"))
        @Expect(JsonSchema.parse("{\"format\":\"ipv4\"}").validator().isValid(JsonStringValue("999.1.1.1")))
        let strict = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
        @Expect(!JsonSchema.parse("{\"format\":\"ipv4\"}", config: strict).validator().isValid(JsonStringValue("999.1.1.1")))
    }

    @TestCase
    func formatModesAndProviderRegistryHaveExplicitUnknownPolicy(): Unit {
        let unknownSchema = "{\"format\":\"application-specific\"}"
        @Expect(JsonSchema.parse(unknownSchema).validator().isValid(JsonStringValue("value")))
        let assertion = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
        @Expect(JsonSchema.parse(unknownSchema, config: assertion).validator().isValid(JsonStringValue("value")))

        let strict = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.StrictAssertion)
        let unsupported = JsonSchema.parse(unknownSchema, config: strict).validate(JsonStringValue("value"))
        @Expect(unsupported.size, 1)
        @Expect(unsupported[0].code, "unsupported_schema_format")

        let formats = JsonSchemaFormatRegistry.withCoreFormats()
        formats.install(TestSchemaFormatProvider())
        let configured = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion, formats: formats)
        @Expect(JsonSchema.parse("{\"format\":\"even-length\"}", config: configured)
            .validator().isValid(JsonStringValue("仓颉")))
        @Expect(!JsonSchema.parse("{\"format\":\"even-length\"}", config: configured)
            .validator().isValid(JsonStringValue("json!")))
        @AssertThrows[IllegalArgumentException](formats.register("even-length", EvenLengthSchemaFormat()))
    }
}
