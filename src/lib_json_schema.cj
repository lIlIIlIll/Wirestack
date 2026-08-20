package yjson

import std.collection.*
import std.convert.Parsable

public class JsonValidationError <: JsonException {
    public let jsonPath: String
    public let schemaPath: String

    public init(jsonPath: String, schemaPath: String, message: String) {
        super("${jsonPath} ${schemaPath}: ${message}")
        this.jsonPath = jsonPath
        this.schemaPath = schemaPath
    }

    protected override func getClassName(): String {
        "JsonValidationError"
    }
}

public class JsonSchema {
    public let document: JsonNode
    public let draft: String

    public init(document: JsonNode, draft!: String = "https://json-schema.org/draft/2020-12/schema") {
        this.document = document
        this.draft = draft
        validateJsonSchemaDocument(document, "#")
    }

    public static func parse(text: String): JsonSchema {
        JsonSchema(YJson.parse(text))
    }

    public static func fromValue(value: JsonNode): JsonSchema {
        JsonSchema(value)
    }

    public func validator(): JsonSchemaValidator {
        JsonSchemaValidator(this)
    }

    public func validate(instance: JsonNode): ArrayList<JsonValidationError> {
        validator().validate(instance)
    }

    public func validateOrThrow(instance: JsonNode): Unit {
        validator().validateOrThrow(instance)
    }
}

public class JsonSchemaValidator {
    private let schema: JsonSchema

    public init(schema: JsonSchema) {
        this.schema = schema
    }

    public func validate(instance: JsonNode): ArrayList<JsonValidationError> {
        let errors = ArrayList<JsonValidationError>()
        validateSchemaValue(schema.document, instance, "$", "#", errors, ArrayList<String>())
        errors
    }

    public func isValid(instance: JsonNode): Bool {
        validate(instance).isEmpty()
    }

    public func validateOrThrow(instance: JsonNode): Unit {
        let errors = validate(instance)
        if (!errors.isEmpty()) {
            throw errors[0]
        }
    }

    private func validateSchemaValue(
        schemaValue: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        match (schemaValue) {
            case boolSchema: JsonBoolValue =>
                if (!boolSchema.value) {
                    addError(errors, jsonPath, schemaPath, "boolean schema false rejects every value")
                }
                return
            case objectSchema: JsonObjectValue =>
                validateObjectSchema(objectSchema, instance, jsonPath, schemaPath, errors, refStack)
            case _ =>
                addError(errors, jsonPath, schemaPath, "schema must be a boolean or object")
        }
    }

    private func validateObjectSchema(
        objectSchema: JsonObjectValue,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        match (objectSchema.get("$ref")) {
            case Some(refValue) =>
                let refText = refValue.asString().value
                if (containsText(refStack, refText)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "cyclic $ref ${refText}")
                } else {
                    refStack.add(refText)
                    match (resolveLocalRef(refText)) {
                        case Some(target) =>
                            validateSchemaValue(target.value, instance, jsonPath, target.schemaPath, errors, refStack)
                        case None =>
                            addError(errors, jsonPath, appendSchemaPath(schemaPath, "$ref"), "unresolved local $ref ${refText}")
                    }
                    refStack.remove(at: refStack.size - 1)
                }
            case None => ()
        }

        match (objectSchema.get("type")) {
            case Some(typeSchema) => validateType(typeSchema, instance, jsonPath, appendSchemaPath(schemaPath, "type"), errors)
            case None => ()
        }

        match (objectSchema.get("enum")) {
            case Some(enumSchema) => validateEnum(enumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "enum"), errors)
            case None => ()
        }

        match (objectSchema.get("const")) {
            case Some(constSchema) =>
                if (!jsonSchemaValuesEqual(constSchema, instance)) {
                    addError(errors, jsonPath, appendSchemaPath(schemaPath, "const"), "value must equal const")
                }
            case None => ()
        }

        match (objectSchema.get("minimum")) {
            case Some(minimumSchema) => validateNumericLimit(minimumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minimum"), true, errors)
            case None => ()
        }

        match (objectSchema.get("maximum")) {
            case Some(maximumSchema) => validateNumericLimit(maximumSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maximum"), false, errors)
            case None => ()
        }

        match (objectSchema.get("minLength")) {
            case Some(minLengthSchema) => validateStringLength(minLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "minLength"), true, errors)
            case None => ()
        }

        match (objectSchema.get("maxLength")) {
            case Some(maxLengthSchema) => validateStringLength(maxLengthSchema, instance, jsonPath, appendSchemaPath(schemaPath, "maxLength"), false, errors)
            case None => ()
        }

        match (objectSchema.get("required")) {
            case Some(requiredSchema) => validateRequired(requiredSchema, instance, jsonPath, appendSchemaPath(schemaPath, "required"), errors)
            case None => ()
        }

        match (objectSchema.get("properties")) {
            case Some(propertiesSchema) => validateProperties(propertiesSchema, instance, jsonPath, appendSchemaPath(schemaPath, "properties"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("items")) {
            case Some(itemsSchema) => validateItems(itemsSchema, instance, jsonPath, appendSchemaPath(schemaPath, "items"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("allOf")) {
            case Some(combinatorSchema) => validateAllOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "allOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("anyOf")) {
            case Some(combinatorSchema) => validateAnyOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "anyOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("oneOf")) {
            case Some(combinatorSchema) => validateOneOf(combinatorSchema, instance, jsonPath, appendSchemaPath(schemaPath, "oneOf"), errors, refStack)
            case None => ()
        }

        match (objectSchema.get("not")) {
            case Some(notSchema) => validateNot(notSchema, instance, jsonPath, appendSchemaPath(schemaPath, "not"), errors, refStack)
            case None => ()
        }
    }

    private func resolveLocalRef(refText: String): Option<JsonSchemaResolvedRef> {
        if (refText == "#") {
            return Some(JsonSchemaResolvedRef(schema.document, "#"))
        }
        if (!refText.startsWith("#/")) {
            return None<JsonSchemaResolvedRef>
        }

        let tokens = jsonPointerTokens(refText)
        var current = schema.document
        var currentPath = "#"
        for (token in tokens) {
            currentPath = appendSchemaPath(currentPath, token)
            match (current) {
                case objectValue: JsonObjectValue =>
                    match (objectValue.get(token)) {
                        case Some(next) => current = next
                        case None => return None<JsonSchemaResolvedRef>
                    }
                case arrayValue: JsonArrayValue =>
                    let index = tryParseNonNegativeInt64(token)
                    match (index) {
                        case Some(i) =>
                            if (i < 0 || i >= arrayValue.size()) {
                                return None<JsonSchemaResolvedRef>
                            }
                            current = arrayValue[i]
                        case None => return None<JsonSchemaResolvedRef>
                    }
                case _ => return None<JsonSchemaResolvedRef>
            }
        }
        Some(JsonSchemaResolvedRef(current, currentPath))
    }

    private func validateType(
        typeSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (typeSchema) {
            case typeName: JsonStringValue =>
                if (!jsonSchemaMatchesType(instance, typeName.value)) {
                    addError(errors, jsonPath, schemaPath, "expected type ${typeName.value}, got ${jsonSchemaInstanceType(instance)}")
                }
            case typeNames: JsonArrayValue =>
                var matched = false
                let expected = ArrayList<String>()
                for (index in 0..typeNames.size()) {
                    let name = typeNames[index].asString().value
                    expected.add(name)
                    if (jsonSchemaMatchesType(instance, name)) {
                        matched = true
                    }
                }
                if (!matched) {
                    addError(errors, jsonPath, schemaPath, "expected one of ${joinStrings(expected, ", ")}, got ${jsonSchemaInstanceType(instance)}")
                }
            case _ => throw JsonException("${schemaPath}: type must be a string or string array")
        }
    }

    private func validateEnum(
        enumSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        let values = enumSchema.asArray()
        for (candidate in values.values()) {
            if (jsonSchemaValuesEqual(candidate, instance)) {
                return
            }
        }
        addError(errors, jsonPath, schemaPath, "value must match one enum entry")
    }

    private func validateNumericLimit(
        limitSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (jsonSchemaNumberAsFloat(instance)) {
            case Some(instanceNumber) =>
                let limit = requireSchemaNumber(limitSchema, schemaPath)
                if (minimum && instanceNumber < limit) {
                    addError(errors, jsonPath, schemaPath, "number must be >= ${limit}")
                }
                if (!minimum && instanceNumber > limit) {
                    addError(errors, jsonPath, schemaPath, "number must be <= ${limit}")
                }
            case None => ()
        }
    }

    private func validateStringLength(
        lengthSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        minimum: Bool,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (instance) {
            case stringValue: JsonStringValue =>
                let limit = requireSchemaNonNegativeInt(lengthSchema, schemaPath)
                let actual = stringValue.value.toRuneArray().size
                if (minimum && actual < limit) {
                    addError(errors, jsonPath, schemaPath, "string length must be >= ${limit}")
                }
                if (!minimum && actual > limit) {
                    addError(errors, jsonPath, schemaPath, "string length must be <= ${limit}")
                }
            case _ => ()
        }
    }

    private func validateRequired(
        requiredSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>
    ): Unit {
        match (instance) {
            case objectValue: JsonObjectValue =>
                let required = requiredSchema.asArray()
                for (index in 0..required.size()) {
                    let field = required[index].asString().value
                    if (!objectValue.contains(field)) {
                        addError(errors, jsonPath, appendSchemaPath(schemaPath, index.toString()), "missing required property ${field}")
                    }
                }
            case _ => ()
        }
    }

    private func validateProperties(
        propertiesSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let properties = propertiesSchema.asObject()
        match (instance) {
            case objectValue: JsonObjectValue =>
                for ((field, childSchema) in properties.entries()) {
                    match (objectValue.get(field)) {
                        case Some(child) =>
                            validateSchemaValue(
                                childSchema,
                                child,
                                appendJsonPath(jsonPath, field),
                                appendSchemaPath(schemaPath, field),
                                errors,
                                refStack
                            )
                        case None => ()
                    }
                }
            case _ => ()
        }
    }

    private func validateItems(
        itemsSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        match (instance) {
            case arrayValue: JsonArrayValue =>
                for (index in 0..arrayValue.size()) {
                    validateSchemaValue(itemsSchema, arrayValue[index], "${jsonPath}[${index}]", schemaPath, errors, refStack)
                }
            case _ => ()
        }
    }

    private func validateAllOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), errors, refStack)
        }
    }

    private func validateAnyOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        for (index in 0..schemas.size()) {
            let nestedErrors = ArrayList<JsonValidationError>()
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), nestedErrors, refStack)
            if (nestedErrors.isEmpty()) {
                return
            }
        }
        addError(errors, jsonPath, schemaPath, "value must match at least one anyOf schema")
    }

    private func validateOneOf(
        combinatorSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let schemas = combinatorSchema.asArray()
        var matches = 0
        for (index in 0..schemas.size()) {
            let nestedErrors = ArrayList<JsonValidationError>()
            validateSchemaValue(schemas[index], instance, jsonPath, appendSchemaPath(schemaPath, index.toString()), nestedErrors, refStack)
            if (nestedErrors.isEmpty()) {
                matches++
            }
        }
        if (matches != 1) {
            addError(errors, jsonPath, schemaPath, "value must match exactly one oneOf schema, matched ${matches}")
        }
    }

    private func validateNot(
        notSchema: JsonNode,
        instance: JsonNode,
        jsonPath: String,
        schemaPath: String,
        errors: ArrayList<JsonValidationError>,
        refStack: ArrayList<String>
    ): Unit {
        let nestedErrors = ArrayList<JsonValidationError>()
        validateSchemaValue(notSchema, instance, jsonPath, schemaPath, nestedErrors, refStack)
        if (nestedErrors.isEmpty()) {
            addError(errors, jsonPath, schemaPath, "value must not match this schema")
        }
    }
}

private class JsonSchemaResolvedRef {
    public let value: JsonNode
    public let schemaPath: String

    public init(value: JsonNode, schemaPath: String) {
        this.value = value
        this.schemaPath = schemaPath
    }
}

private func validateJsonSchemaDocument(schemaValue: JsonNode, schemaPath: String): Unit {
    match (schemaValue) {
        case _: JsonBoolValue => ()
        case objectValue: JsonObjectValue =>
            match (objectValue.get("type")) {
                case Some(typeSchema) => validateJsonSchemaTypeKeyword(typeSchema, appendSchemaPath(schemaPath, "type"))
                case None => ()
            }
            match (objectValue.get("required")) {
                case Some(requiredSchema) => validateJsonSchemaStringArray(requiredSchema, appendSchemaPath(schemaPath, "required"))
                case None => ()
            }
            match (objectValue.get("properties")) {
                case Some(propertiesSchema) =>
                    let properties = propertiesSchema.asObject()
                    for ((field, childSchema) in properties.entries()) {
                        validateJsonSchemaDocument(childSchema, appendSchemaPath(appendSchemaPath(schemaPath, "properties"), field))
                    }
                case None => ()
            }
            match (objectValue.get("items")) {
                case Some(itemsSchema) => validateJsonSchemaDocument(itemsSchema, appendSchemaPath(schemaPath, "items"))
                case None => ()
            }
            match (objectValue.get("enum")) {
                case Some(enumSchema) =>
                    let _ = enumSchema.asArray()
                case None => ()
            }
            match (objectValue.get("minimum")) {
                case Some(limitSchema) =>
                    let _ = requireSchemaNumber(limitSchema, appendSchemaPath(schemaPath, "minimum"))
                case None => ()
            }
            match (objectValue.get("maximum")) {
                case Some(limitSchema) =>
                    let _ = requireSchemaNumber(limitSchema, appendSchemaPath(schemaPath, "maximum"))
                case None => ()
            }
            match (objectValue.get("minLength")) {
                case Some(lengthSchema) =>
                    let _ = requireSchemaNonNegativeInt(lengthSchema, appendSchemaPath(schemaPath, "minLength"))
                case None => ()
            }
            match (objectValue.get("maxLength")) {
                case Some(lengthSchema) =>
                    let _ = requireSchemaNonNegativeInt(lengthSchema, appendSchemaPath(schemaPath, "maxLength"))
                case None => ()
            }
            validateJsonSchemaDocumentArray(objectValue, "allOf", schemaPath)
            validateJsonSchemaDocumentArray(objectValue, "anyOf", schemaPath)
            validateJsonSchemaDocumentArray(objectValue, "oneOf", schemaPath)
            match (objectValue.get("not")) {
                case Some(notSchema) => validateJsonSchemaDocument(notSchema, appendSchemaPath(schemaPath, "not"))
                case None => ()
            }
            match (objectValue.get("$defs")) {
                case Some(defsSchema) =>
                    let defs = defsSchema.asObject()
                    for ((name, defSchema) in defs.entries()) {
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "$defs"), name))
                    }
                case None => ()
            }
            match (objectValue.get("definitions")) {
                case Some(defsSchema) =>
                    let defs = defsSchema.asObject()
                    for ((name, defSchema) in defs.entries()) {
                        validateJsonSchemaDocument(defSchema, appendSchemaPath(appendSchemaPath(schemaPath, "definitions"), name))
                    }
                case None => ()
            }
        case _ => throw JsonException("${schemaPath}: schema must be a boolean or object")
    }
}

private func validateJsonSchemaDocumentArray(objectValue: JsonObjectValue, keyword: String, schemaPath: String): Unit {
    match (objectValue.get(keyword)) {
        case Some(value) =>
            let schemas = value.asArray()
            for (index in 0..schemas.size()) {
                validateJsonSchemaDocument(schemas[index], appendSchemaPath(appendSchemaPath(schemaPath, keyword), index.toString()))
            }
        case None => ()
    }
}

private func validateJsonSchemaTypeKeyword(typeSchema: JsonNode, schemaPath: String): Unit {
    match (typeSchema) {
        case typeName: JsonStringValue => validateJsonSchemaTypeName(typeName.value, schemaPath)
        case typeNames: JsonArrayValue =>
            for (index in 0..typeNames.size()) {
                let childPath = appendSchemaPath(schemaPath, index.toString())
                validateJsonSchemaTypeName(typeNames[index].asString().value, childPath)
            }
        case _ => throw JsonException("${schemaPath}: type must be a string or string array")
    }
}

private func validateJsonSchemaStringArray(value: JsonNode, schemaPath: String): Unit {
    let array = value.asArray()
    for (index in 0..array.size()) {
        match (array[index]) {
            case _: JsonStringValue => ()
            case _ => throw JsonException("${appendSchemaPath(schemaPath, index.toString())}: expected string")
        }
    }
}

private func validateJsonSchemaTypeName(name: String, schemaPath: String): Unit {
    if (
        name != "null" &&
        name != "boolean" &&
        name != "object" &&
        name != "array" &&
        name != "number" &&
        name != "integer" &&
        name != "string"
    ) {
        throw JsonException("${schemaPath}: unsupported JSON Schema type ${name}")
    }
}

private func addError(errors: ArrayList<JsonValidationError>, jsonPath: String, schemaPath: String, message: String): Unit {
    errors.add(JsonValidationError(jsonPath, schemaPath, message))
}

private func jsonSchemaMatchesType(value: JsonNode, typeName: String): Bool {
    match (typeName) {
        case "null" => if (let _: JsonNullValue <- value) { true } else { false }
        case "boolean" => if (let _: JsonBoolValue <- value) { true } else { false }
        case "object" => if (let _: JsonObjectValue <- value) { true } else { false }
        case "array" => if (let _: JsonArrayValue <- value) { true } else { false }
        case "string" => if (let _: JsonStringValue <- value) { true } else { false }
        case "number" => jsonSchemaNumberAsFloat(value).isSome()
        case "integer" => jsonSchemaIsInteger(value)
        case _ => false
    }
}

private func jsonSchemaInstanceType(value: JsonNode): String {
    match (value) {
        case _: JsonNullValue => "null"
        case _: JsonBoolValue => "boolean"
        case _: JsonObjectValue => "object"
        case _: JsonArrayValue => "array"
        case _: JsonStringValue => "string"
        case _ =>
            if (jsonSchemaIsInteger(value)) {
                "integer"
            } else if (jsonSchemaNumberAsFloat(value).isSome()) {
                "number"
            } else {
                "unknown"
            }
    }
}

private func jsonSchemaNumberAsFloat(value: JsonNode): Option<Float64> {
    match (value) {
        case intValue: JsonIntValue => Some(Float64(intValue.value))
        case floatValue: JsonFloatValue => Some(floatValue.value)
        case numberValue: JsonNumberLiteralValue => Some(Float64.parse(numberValue.literal))
        case _ => None<Float64>
    }
}

private func jsonSchemaIsInteger(value: JsonNode): Bool {
    match (value) {
        case _: JsonIntValue => true
        case floatValue: JsonFloatValue =>
            if (floatValue.value.isNaN() || floatValue.value.isInf()) {
                false
            } else {
                floatValue.value == Float64(Int64(floatValue.value))
            }
        case numberValue: JsonNumberLiteralValue =>
            !numberValue.literal.contains(".") && !numberValue.literal.contains("e") && !numberValue.literal.contains("E")
        case _ => false
    }
}

private func requireSchemaNumber(value: JsonNode, schemaPath: String): Float64 {
    match (jsonSchemaNumberAsFloat(value)) {
        case Some(number) => number
        case None => throw JsonException("${schemaPath}: expected numeric schema value")
    }
}

private func requireSchemaNonNegativeInt(value: JsonNode, schemaPath: String): Int64 {
    let decoded = value.asInt().value
    if (decoded < 0) {
        throw JsonException("${schemaPath}: expected non-negative integer schema value")
    }
    decoded
}

private func jsonSchemaValuesEqual(left: JsonNode, right: JsonNode): Bool {
    match ((left, right)) {
        case (_: JsonNullValue, _: JsonNullValue) => true
        case (leftBool: JsonBoolValue, rightBool: JsonBoolValue) => leftBool.value == rightBool.value
        case (leftString: JsonStringValue, rightString: JsonStringValue) => leftString.value == rightString.value
        case (leftArray: JsonArrayValue, rightArray: JsonArrayValue) => jsonSchemaArraysEqual(leftArray, rightArray)
        case (leftObject: JsonObjectValue, rightObject: JsonObjectValue) => jsonSchemaObjectsEqual(leftObject, rightObject)
        case _ =>
            match ((jsonSchemaNumberAsFloat(left), jsonSchemaNumberAsFloat(right))) {
                case (Some(leftNumber), Some(rightNumber)) => leftNumber == rightNumber
                case _ => false
            }
    }
}

private func jsonSchemaArraysEqual(left: JsonArrayValue, right: JsonArrayValue): Bool {
    if (left.size() != right.size()) {
        return false
    }
    for (index in 0..left.size()) {
        if (!jsonSchemaValuesEqual(left[index], right[index])) {
            return false
        }
    }
    true
}

private func jsonSchemaObjectsEqual(left: JsonObjectValue, right: JsonObjectValue): Bool {
    if (left.size() != right.size()) {
        return false
    }
    for ((key, leftValue) in left.entries()) {
        match (right.get(key)) {
            case Some(rightValue) =>
                if (!jsonSchemaValuesEqual(leftValue, rightValue)) {
                    return false
                }
            case None => return false
        }
    }
    true
}

private func containsText(values: ArrayList<String>, target: String): Bool {
    for (value in values) {
        if (value == target) {
            return true
        }
    }
    false
}

private func joinStrings(values: ArrayList<String>, separator: String): String {
    if (values.isEmpty()) {
        return ""
    }
    let builder = StringBuilder()
    builder.append(values[0])
    for (index in 1..values.size) {
        builder.append(separator)
        builder.append(values[index])
    }
    builder.toString()
}

private func appendJsonPath(base: String, field: String): String {
    "${base}[${JsonStringValue(field).toString()}]"
}

private func appendSchemaPath(base: String, token: String): String {
    if (base == "#") {
        return "#/${jsonPointerEscape(token)}"
    }
    "${base}/${jsonPointerEscape(token)}"
}

private func jsonPointerTokens(refText: String): ArrayList<String> {
    let tokens = ArrayList<String>()
    if (refText == "#") {
        return tokens
    }
    if (!refText.startsWith("#/")) {
        throw JsonException("unsupported JSON Schema ref ${refText}")
    }

    var start = 2
    while (start <= refText.size) {
        var end = start
        while (end < refText.size && refText[end] != b'/') {
            end++
        }
        tokens.add(jsonPointerUnescape(refText[start..end]))
        start = end + 1
    }
    tokens
}

private func jsonPointerUnescape(token: String): String {
    let builder = StringBuilder()
    var segmentStart = 0
    var index = 0
    while (index < token.size) {
        if (token[index] == b'~' && index + 1 < token.size) {
            if (segmentStart < index) {
                builder.append(token[segmentStart..index])
            }
            let next = token[index + 1]
            if (next == b'0') {
                builder.append("~")
                index += 2
                segmentStart = index
            } else if (next == b'1') {
                builder.append("/")
                index += 2
                segmentStart = index
            } else {
                builder.append("~")
                index++
                segmentStart = index
            }
        } else {
            index++
        }
    }
    if (segmentStart < token.size) {
        builder.append(token[segmentStart..token.size])
    }
    builder.toString()
}

private func jsonPointerEscape(token: String): String {
    let builder = StringBuilder()
    var segmentStart = 0
    var index = 0
    while (index < token.size) {
        if (token[index] == b'~' || token[index] == b'/') {
            if (segmentStart < index) {
                builder.append(token[segmentStart..index])
            }
            if (token[index] == b'~') {
                builder.append("~0")
            } else {
                builder.append("~1")
            }
            index++
            segmentStart = index
        } else {
            index++
        }
    }
    if (segmentStart < token.size) {
        builder.append(token[segmentStart..token.size])
    }
    builder.toString()
}

private func tryParseNonNegativeInt64(text: String): Option<Int64> {
    try {
        let value = Int64.parse(text)
        if (value < 0) {
            return None<Int64>
        }
        Some(value)
    } catch (_: Exception) {
        None<Int64>
    }
}
