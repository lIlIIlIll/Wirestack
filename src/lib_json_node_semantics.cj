package yjson

import std.collection.*
import std.math.numeric.*

func deepCopyJsonNode(value: JsonNode): JsonNode {
    deepCopyJsonNodeGuarded(value, ArrayList<JsonNode>())
}

private func deepCopyJsonNodeGuarded(value: JsonNode, ancestors: ArrayList<JsonNode>): JsonNode {
    match (value) {
        case _: JsonNullValue => JsonNullValue()
        case boolValue: JsonBoolValue => JsonBoolValue(boolValue.value)
        case intValue: JsonIntValue => JsonIntValue(intValue.value)
        case floatValue: JsonFloatValue => JsonFloatValue(floatValue.value)
        case numberValue: JsonNumberLiteralValue => JsonNumberLiteralValue.fromParsedLiteral(numberValue.literal)
        case stringValue: JsonStringValue => JsonStringValue(stringValue.value)
        case arrayValue: JsonArrayValue =>
            enterJsonNodeAncestor(arrayValue, ancestors)
            let result = JsonArrayValue()
            try {
                for (item in arrayValue.values()) { result.add(deepCopyJsonNodeGuarded(item, ancestors)) }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
            result
        case objectValue: JsonObjectValue =>
            enterJsonNodeAncestor(objectValue, ancestors)
            let result = JsonObjectValue()
            try {
                for ((key, item) in objectValue.entries()) {
                    result.put(key, deepCopyJsonNodeGuarded(item, ancestors))
                }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
            result
        case _ => throw JsonException("Unsupported JsonNode implementation", code: "json_node_type")
    }
}

func jsonNodesEquivalent(left: JsonNode, right: JsonNode): Bool {
    jsonNodesEquivalentGuarded(left, right, ArrayList<JsonNode>(), ArrayList<JsonNode>())
}

private func jsonNodesEquivalentGuarded(
    left: JsonNode,
    right: JsonNode,
    leftAncestors: ArrayList<JsonNode>,
    rightAncestors: ArrayList<JsonNode>
): Bool {
    match ((left, right)) {
        case (_: JsonNullValue, _: JsonNullValue) => true
        case (a: JsonBoolValue, b: JsonBoolValue) => a.value == b.value
        case (a: JsonStringValue, b: JsonStringValue) => a.value == b.value
        case (a: JsonArrayValue, b: JsonArrayValue) =>
            if (a.size() != b.size()) { return false }
            enterJsonNodeAncestor(a, leftAncestors)
            try {
                enterJsonNodeAncestor(b, rightAncestors)
                try {
                    for (index in 0..a.size()) {
                        if (!jsonNodesEquivalentGuarded(a[index], b[index], leftAncestors, rightAncestors)) {
                            return false
                        }
                    }
                } finally {
                    rightAncestors.remove(at: rightAncestors.size - 1)
                }
            } finally {
                leftAncestors.remove(at: leftAncestors.size - 1)
            }
            true
        case (a: JsonObjectValue, b: JsonObjectValue) =>
            if (a.size() != b.size()) { return false }
            enterJsonNodeAncestor(a, leftAncestors)
            try {
                enterJsonNodeAncestor(b, rightAncestors)
                try {
                    for ((key, value) in a.entries()) {
                        match (b.get(key)) {
                            case Some(other) =>
                                if (!jsonNodesEquivalentGuarded(value, other, leftAncestors, rightAncestors)) {
                                    return false
                                }
                            case None => return false
                        }
                    }
                } finally {
                    rightAncestors.remove(at: rightAncestors.size - 1)
                }
            } finally {
                leftAncestors.remove(at: leftAncestors.size - 1)
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
