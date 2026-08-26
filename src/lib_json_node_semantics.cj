package yjson

import std.math.numeric.*

func deepCopyJsonNode(value: JsonNode): JsonNode {
    match (value) {
        case _: JsonNullValue => JsonNullValue()
        case boolValue: JsonBoolValue => JsonBoolValue(boolValue.value)
        case intValue: JsonIntValue => JsonIntValue(intValue.value)
        case floatValue: JsonFloatValue => JsonFloatValue(floatValue.value)
        case numberValue: JsonNumberLiteralValue => JsonNumberLiteralValue.fromParsedLiteral(numberValue.literal)
        case stringValue: JsonStringValue => JsonStringValue(stringValue.value)
        case arrayValue: JsonArrayValue =>
            let result = JsonArrayValue()
            for (item in arrayValue.values()) { result.add(deepCopyJsonNode(item)) }
            result
        case objectValue: JsonObjectValue =>
            let result = JsonObjectValue()
            for ((key, item) in objectValue.entries()) { result.put(key, deepCopyJsonNode(item)) }
            result
        case _ => throw JsonException("Unsupported JsonNode implementation", code: "json_node_type")
    }
}

func jsonNodesEquivalent(left: JsonNode, right: JsonNode): Bool {
    match ((left, right)) {
        case (_: JsonNullValue, _: JsonNullValue) => true
        case (a: JsonBoolValue, b: JsonBoolValue) => a.value == b.value
        case (a: JsonStringValue, b: JsonStringValue) => a.value == b.value
        case (a: JsonArrayValue, b: JsonArrayValue) =>
            if (a.size() != b.size()) { return false }
            for (index in 0..a.size()) {
                if (!jsonNodesEquivalent(a[index], b[index])) { return false }
            }
            true
        case (a: JsonObjectValue, b: JsonObjectValue) =>
            if (a.size() != b.size()) { return false }
            for ((key, value) in a.entries()) {
                match (b.get(key)) {
                    case Some(other) => if (!jsonNodesEquivalent(value, other)) { return false }
                    case None => return false
                }
            }
            true
        case _ => jsonCoreNumbersEquivalent(left, right)
    }
}

private func jsonCoreNumbersEquivalent(left: JsonNode, right: JsonNode): Bool {
    match ((jsonCoreNodeAsDecimal(left), jsonCoreNodeAsDecimal(right))) {
        case (Some(a), Some(b)) => a == b
        case _ => false
    }
}

private func jsonCoreNodeAsDecimal(value: JsonNode): Option<Decimal> {
    try {
        match (value) {
            case intValue: JsonIntValue => Some(Decimal(intValue.value))
            case floatValue: JsonFloatValue => Some(Decimal.parse(floatValue.value.toString()))
            case numberValue: JsonNumberLiteralValue => Some(Decimal.parse(numberValue.literal))
            case _ => None<Decimal>
        }
    } catch (_: Exception) { None<Decimal> }
}
