package yjson

import std.collection.*
import std.math.numeric.*

private let JSON_NODE_OPERATION_MAX_DEPTH: Int64 = 256
private let JSON_NODE_OPERATION_MAX_WORK: Int64 = 100000

private class JsonNodeOperationBudget {
    private var remaining: Int64

    init(maxWork: Int64) {
        if (maxWork <= 0) { throw IllegalArgumentException("maxNodes must be positive") }
        remaining = maxWork
    }

    func visit(depth: Int64): Unit {
        if (depth > JSON_NODE_OPERATION_MAX_DEPTH) {
            throw JsonException(
                "Maximum JsonNode operation depth ${JSON_NODE_OPERATION_MAX_DEPTH} exceeded",
                code: "max_depth"
            )
        }
        if (remaining <= 0) {
            throw JsonException("JsonNode operation work limit exceeded", code: "work_limit_exceeded")
        }
        remaining--
    }
}

func deepCopyJsonNode(value: JsonNode): JsonNode {
    deepCopyJsonNode(value, JSON_NODE_OPERATION_MAX_WORK)
}

func deepCopyJsonNode(value: JsonNode, maxNodes: Int64): JsonNode {
    deepCopyJsonNodeGuarded(value, ArrayList<JsonNode>(), JsonNodeOperationBudget(maxNodes), 0)
}

private func deepCopyJsonNodeGuarded(
    value: JsonNode,
    ancestors: ArrayList<JsonNode>,
    budget: JsonNodeOperationBudget,
    depth: Int64
): JsonNode {
    budget.visit(depth)
    match (value) {
        case _: JsonNullValue => JsonNullValue()
        case boolValue: JsonBoolValue => JsonBoolValue(boolValue.value)
        case intValue: JsonIntValue => JsonIntValue(intValue.value)
        case uintValue: JsonUIntValue => JsonUIntValue(uintValue.value)
        case floatValue: JsonFloatValue => JsonFloatValue(floatValue.value)
        case numberValue: JsonNumberLiteralValue => JsonNumberLiteralValue.fromParsedLiteral(numberValue.literal)
        case stringValue: JsonStringValue => JsonStringValue(stringValue.value)
        case arrayValue: JsonArray =>
            enterJsonNodeAncestor(arrayValue, ancestors)
            let result = JsonArray()
            try {
                for (item in arrayValue.values()) {
                    result.add(deepCopyJsonNodeGuarded(item, ancestors, budget, depth + 1))
                }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
            result
        case objectValue: JsonObject =>
            enterJsonNodeAncestor(objectValue, ancestors)
            let result = JsonObject()
            try {
                for (index in 0..objectValue.size()) {
                    result.put(objectValue.nameAt(index), deepCopyJsonNodeGuarded(
                        objectValue.valueAt(index), ancestors, budget, depth + 1))
                }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
            result
        case _ => throw JsonException("Unsupported JsonNode implementation", code: "json_node_type")
    }
}

func jsonNodesEquivalent(left: JsonNode, right: JsonNode): Bool {
    jsonNodesEquivalentGuarded(
        left, right, ArrayList<JsonNode>(), ArrayList<JsonNode>(),
        JsonNodeOperationBudget(JSON_NODE_OPERATION_MAX_WORK), 0
    )
}

private func jsonNodesEquivalentGuarded(
    left: JsonNode,
    right: JsonNode,
    leftAncestors: ArrayList<JsonNode>,
    rightAncestors: ArrayList<JsonNode>,
    budget: JsonNodeOperationBudget,
    depth: Int64
): Bool {
    budget.visit(depth)
    ensureJsonNodeNotAncestor(left, leftAncestors)
    ensureJsonNodeNotAncestor(right, rightAncestors)
    match ((left, right)) {
        case (_: JsonNullValue, _: JsonNullValue) => true
        case (a: JsonBoolValue, b: JsonBoolValue) => a.value == b.value
        case (a: JsonStringValue, b: JsonStringValue) => a.value == b.value
        case (a: JsonArray, b: JsonArray) =>
            if (a.size() != b.size()) {
                ensureJsonNodeGraphAcyclic(a, budget, depth)
                ensureJsonNodeGraphAcyclic(b, budget, depth)
                return false
            }
            leftAncestors.add(a)
            try {
                rightAncestors.add(b)
                try {
                    for (index in 0..a.size()) {
                        if (!jsonNodesEquivalentGuarded(
                            a[index], b[index], leftAncestors, rightAncestors, budget, depth + 1
                        )) {
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
        case (a: JsonObject, b: JsonObject) =>
            if (a.size() != b.size()) {
                ensureJsonNodeGraphAcyclic(a, budget, depth)
                ensureJsonNodeGraphAcyclic(b, budget, depth)
                return false
            }
            leftAncestors.add(a)
            try {
                rightAncestors.add(b)
                try {
                    for (index in 0..a.size()) {
                        let key = a.nameAt(index)
                        let value = a.valueAt(index)
                        match (b.get(key)) {
                            case Some(other) =>
                                if (!jsonNodesEquivalentGuarded(
                                    value, other, leftAncestors, rightAncestors, budget, depth + 1
                                )) {
                                    return false
                                }
                            case None =>
                                ensureJsonNodeGraphAcyclic(a, budget, depth)
                                ensureJsonNodeGraphAcyclic(b, budget, depth)
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
        case _ =>
            ensureJsonNodeGraphAcyclic(left, budget, depth)
            ensureJsonNodeGraphAcyclic(right, budget, depth)
            jsonCoreNumbersEquivalent(left, right)
    }
}

private func ensureJsonNodeGraphAcyclic(
    value: JsonNode,
    budget: JsonNodeOperationBudget,
    depth: Int64
): Unit {
    ensureJsonNodeGraphAcyclicGuarded(value, ArrayList<JsonNode>(), budget, depth)
}

private func ensureJsonNodeGraphAcyclicGuarded(
    value: JsonNode,
    ancestors: ArrayList<JsonNode>,
    budget: JsonNodeOperationBudget,
    depth: Int64
): Unit {
    budget.visit(depth)
    match (value) {
        case arrayValue: JsonArray =>
            enterJsonNodeAncestor(arrayValue, ancestors)
            try {
                for (item in arrayValue.values()) {
                    ensureJsonNodeGraphAcyclicGuarded(item, ancestors, budget, depth + 1)
                }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
        case objectValue: JsonObject =>
            enterJsonNodeAncestor(objectValue, ancestors)
            try {
                for (index in 0..objectValue.size()) {
                    ensureJsonNodeGraphAcyclicGuarded(
                        objectValue.valueAt(index), ancestors, budget, depth + 1)
                }
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
        case _ => ()
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
            case uintValue: JsonUIntValue => Some(Decimal.parse(uintValue.value.toString()))
            case floatValue: JsonFloatValue => Some(Decimal.parse(floatValue.value.toString()))
            case numberValue: JsonNumberLiteralValue => Some(Decimal.parse(numberValue.literal))
            case _ => None<Decimal>
        }
    } catch (_: Exception) { None<Decimal> }
}
