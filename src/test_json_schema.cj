package yjson

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func yJsonSchemaErrors(schemaText: String, instanceText: String): ArrayList<JsonValidationError> {
    JsonSchema.parse(schemaText).validate(YJson.parse(instanceText))
}

func yJsonSchemaValid(schemaText: String, instanceText: String): Bool {
    yJsonSchemaErrors(schemaText, instanceText).isEmpty()
}

@Test
class YJsonSchemaTest {
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
}
