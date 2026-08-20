macro package yjson_macros

import std.ast.*
import std.collection.*
import std.convert.Parsable

private enum JsonDslKind {
    DslNull | DslBool | DslString | DslNumber | DslInterpolation | DslArray | DslObject
}

private class JsonDslBinding {
    let name: String
    let expression: String
    let keyBinding: Bool

    init(name: String, expression: String, keyBinding: Bool) {
        this.name = name
        this.expression = expression
        this.keyBinding = keyBinding
    }
}

private class JsonDslField {
    let keyExpression: String
    let staticKey: Bool
    let staticIdentity: String
    let value: JsonDslNode

    init(keyExpression: String, staticKey: Bool, staticIdentity: String, value: JsonDslNode) {
        this.keyExpression = keyExpression
        this.staticKey = staticKey
        this.staticIdentity = staticIdentity
        this.value = value
    }
}

private class JsonDslNode {
    let kind: JsonDslKind
    let text: String
    let items: ArrayList<JsonDslNode>
    let fields: ArrayList<JsonDslField>

    init(
        kind: JsonDslKind,
        text!: String = "",
        items!: ArrayList<JsonDslNode> = ArrayList<JsonDslNode>(),
        fields!: ArrayList<JsonDslField> = ArrayList<JsonDslField>()
    ) {
        this.kind = kind
        this.text = text
        this.items = items
        this.fields = fields
    }
}

private class JsonDslDocument {
    let root: JsonDslNode
    let bindings: ArrayList<JsonDslBinding>

    init(root: JsonDslNode, bindings: ArrayList<JsonDslBinding>) {
        this.root = root
        this.bindings = bindings
    }
}

private func jsonDslHexValue(value: Rune): UInt32 {
    let code = UInt32(value)
    if (value >= r'0' && value <= r'9') {
        return code - UInt32(r'0')
    }
    if (value >= r'a' && value <= r'f') {
        return code - UInt32(r'a') + 10u32
    }
    code - UInt32(r'A') + 10u32
}

private func jsonDslStaticStringValue(value: String): String {
    let runes = value.toRuneArray()
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < runes.size) {
        let current = runes[index]
        index++
        if (current != r'\\') {
            builder.append(current)
            continue
        }
        let escaped = runes[index]
        index++
        match (escaped) {
            case r'0' => builder.append(r'\0')
            case r'\\' => builder.append(r'\\')
            case r'b' => builder.append(r'\b')
            case r'f' => builder.append(r'\f')
            case r'n' => builder.append(r'\n')
            case r'r' => builder.append(r'\r')
            case r't' => builder.append(r'\t')
            case r'v' => builder.append(r'\v')
            case r'\'' => builder.append(r'\'')
            case r'"' => builder.append(r'"')
            case r'u' =>
                index++ // '{'
                var codePoint = 0u32
                while (runes[index] != r'}') {
                    codePoint = codePoint * 16u32 + jsonDslHexValue(runes[index])
                    index++
                }
                index++ // '}'
                builder.append(Rune(codePoint))
            case _ => builder.append(escaped)
        }
    }
    builder.toString()
}

private class JsonDslParser {
    private let tokens: Tokens
    private var index: Int64 = 0
    private var bindingIndex: Int64 = 0
    private let bindings = ArrayList<JsonDslBinding>()

    init(tokens: Tokens) {
        this.tokens = tokens
    }

    func parse(): JsonDslDocument {
        let root = parseValue()
        skipTrivia()
        if (index != tokens.size) {
            fail("unexpected token '${tokens[index].toTokens().toString()}' after the root value")
        }
        JsonDslDocument(root, bindings)
    }

    private func fail(message: String): Nothing {
        throw Exception("JSON literal syntax error: ${message}")
    }

    private func skipTrivia(): Unit {
        while (index < tokens.size) {
            match (tokens[index].kind) {
                case TokenKind.NL | TokenKind.COMMENT => index++
                case _ => return
            }
        }
    }

    private func at(kind: TokenKind): Bool {
        skipTrivia()
        index < tokens.size && tokens[index].kind == kind
    }

    private func take(kind: TokenKind, expected: String): Token {
        skipTrivia()
        if (index >= tokens.size || tokens[index].kind != kind) {
            fail("expected ${expected}")
        }
        let result = tokens[index]
        index++
        result
    }

    private func parseValue(): JsonDslNode {
        skipTrivia()
        if (index >= tokens.size) {
            fail("expected a value")
        }
        let token = tokens[index]
        match (token.kind) {
            case TokenKind.LCURL => parseObject()
            case TokenKind.LSQUARE => parseArray()
            case TokenKind.STRING_LITERAL =>
                let source = token.toTokens().toString().trimAscii()
                if (!source.startsWith("\"")) {
                    fail("only double-quoted strings are supported")
                }
                index++
                JsonDslNode(JsonDslKind.DslString, text: source)
            case TokenKind.BOOL_LITERAL =>
                index++
                JsonDslNode(JsonDslKind.DslBool, text: token.value)
            case TokenKind.INTEGER_LITERAL | TokenKind.FLOAT_LITERAL => parseNumber(false)
            case TokenKind.SUB => parseNumber(true)
            case TokenKind.DOLLAR =>
                let binding = parseInterpolation(false)
                JsonDslNode(JsonDslKind.DslInterpolation, text: binding.name)
            case TokenKind.IDENTIFIER =>
                if (token.value != "null") {
                    fail("unsupported identifier '${token.value}'")
                }
                index++
                JsonDslNode(JsonDslKind.DslNull)
            case _ => fail("expected an object, array, string, number, boolean, null, or $() interpolation")
        }
    }

    private func parseNumber(negative: Bool): JsonDslNode {
        let builder = StringBuilder()
        if (negative) {
            let _ = take(TokenKind.SUB, "a minus sign")
            builder.append("-")
        }
        skipTrivia()
        if (index >= tokens.size) {
            fail("expected digits after '-'")
        }
        let token = tokens[index]
        if (token.kind != TokenKind.INTEGER_LITERAL && token.kind != TokenKind.FLOAT_LITERAL) {
            fail("expected a JSON number")
        }
        index++
        builder.append(token.value)
        let text = builder.toString()
        if (!isStrictJsonNumber(text)) {
            fail("'${text}' is not a strict JSON number")
        }
        JsonDslNode(JsonDslKind.DslNumber, text: text)
    }

    private func parseArray(): JsonDslNode {
        let _ = take(TokenKind.LSQUARE, "'['")
        let items = ArrayList<JsonDslNode>()
        if (at(TokenKind.RSQUARE)) {
            let _ = take(TokenKind.RSQUARE, "']'")
            return JsonDslNode(JsonDslKind.DslArray, items: items)
        }
        while (true) {
            items.add(parseValue())
            if (at(TokenKind.RSQUARE)) {
                let _ = take(TokenKind.RSQUARE, "']'")
                break
            }
            let _ = take(TokenKind.COMMA, "',' or ']'")
            if (at(TokenKind.RSQUARE)) {
                let _ = take(TokenKind.RSQUARE, "']'")
                break
            }
        }
        JsonDslNode(JsonDslKind.DslArray, items: items)
    }

    private func parseObject(): JsonDslNode {
        let _ = take(TokenKind.LCURL, "'{'")
        let fields = ArrayList<JsonDslField>()
        let staticKeys = ArrayList<String>()
        if (at(TokenKind.RCURL)) {
            let _ = take(TokenKind.RCURL, "'}'")
            return JsonDslNode(JsonDslKind.DslObject, fields: fields)
        }
        while (true) {
            skipTrivia()
            if (index >= tokens.size) {
                fail("expected an object key")
            }
            var keyExpression = ""
            var staticKey = false
            var staticIdentity = ""
            if (tokens[index].kind == TokenKind.STRING_LITERAL) {
                let token = tokens[index]
                keyExpression = token.toTokens().toString().trimAscii()
                if (!keyExpression.startsWith("\"")) {
                    fail("object keys must use double-quoted strings or $()")
                }
                staticKey = true
                staticIdentity = jsonDslStaticStringValue(token.value)
                for (existing in staticKeys) {
                    if (existing == staticIdentity) {
                        fail("duplicate static object key ${keyExpression}")
                    }
                }
                staticKeys.add(staticIdentity)
                index++
            } else if (tokens[index].kind == TokenKind.DOLLAR) {
                let binding = parseInterpolation(true)
                keyExpression = binding.name
            } else {
                fail("object keys must use double-quoted strings or $()")
            }
            let _ = take(TokenKind.COLON, "':' after an object key")
            fields.add(JsonDslField(keyExpression, staticKey, staticIdentity, parseValue()))
            if (at(TokenKind.RCURL)) {
                let _ = take(TokenKind.RCURL, "'}'")
                break
            }
            let _ = take(TokenKind.COMMA, "',' or '}'")
            if (at(TokenKind.RCURL)) {
                let _ = take(TokenKind.RCURL, "'}'")
                break
            }
        }
        JsonDslNode(JsonDslKind.DslObject, fields: fields)
    }

    private func parseInterpolation(keyBinding: Bool): JsonDslBinding {
        let _ = take(TokenKind.DOLLAR, "'$'")
        let _ = take(TokenKind.LPAREN, "'(' after '$'")
        let expressionTokens = Tokens()
        var depth: Int64 = 1
        while (index < tokens.size) {
            let token = tokens[index]
            index++
            if (token.kind == TokenKind.LPAREN) {
                depth++
                expressionTokens.append(token)
                continue
            }
            if (token.kind == TokenKind.RPAREN) {
                depth--
                if (depth == 0) {
                    break
                }
                expressionTokens.append(token)
                continue
            }
            expressionTokens.append(token)
        }
        if (depth != 0) {
            fail("unterminated $() interpolation")
        }
        let expression = expressionTokens.toString().trimAscii()
        if (expression.isEmpty()) {
            fail("$() interpolation cannot be empty")
        }
        let name = "__yjson_literal_binding_${bindingIndex}"
        bindingIndex++
        let binding = JsonDslBinding(name, expression, keyBinding)
        bindings.add(binding)
        binding
    }
}

private func isJsonDigit(value: Rune): Bool {
    value >= r'0' && value <= r'9'
}

private func isStrictJsonNumber(text: String): Bool {
    let values = text.toRuneArray()
    var index: Int64 = 0
    if (index < values.size && values[index] == r'-') {
        index++
    }
    if (index >= values.size) {
        return false
    }
    if (values[index] == r'0') {
        index++
        if (index < values.size && isJsonDigit(values[index])) {
            return false
        }
    } else {
        if (values[index] < r'1' || values[index] > r'9') {
            return false
        }
        index++
        while (index < values.size && isJsonDigit(values[index])) {
            index++
        }
    }
    if (index < values.size && values[index] == r'.') {
        index++
        if (index >= values.size || !isJsonDigit(values[index])) {
            return false
        }
        while (index < values.size && isJsonDigit(values[index])) {
            index++
        }
    }
    if (index < values.size && (values[index] == r'e' || values[index] == r'E')) {
        index++
        if (index < values.size && (values[index] == r'+' || values[index] == r'-')) {
            index++
        }
        if (index >= values.size || !isJsonDigit(values[index])) {
            return false
        }
        while (index < values.size && isJsonDigit(values[index])) {
            index++
        }
    }
    index == values.size
}

private func jsonDslAppendLine(builder: StringBuilder, level: Int64, value: String): Unit {
    for (_ in 0..level) {
        builder.append("    ")
    }
    builder.append(value)
    builder.append("\n")
}

private class JsonDslRenderer {
    private var localIndex: Int64 = 0

    private func localName(prefix: String): String {
        let result = "__yjson_literal_${prefix}_${localIndex}"
        localIndex++
        result
    }

    func renderString(document: JsonDslDocument): Tokens {
        let builder = StringBuilder()
        jsonDslAppendLine(builder, 0, "({ =>")
        renderBindings(document.bindings, builder, 1)
        jsonDslAppendLine(builder, 1, "let __yjson_literal_writer = JsonDirectWriter()")
        jsonDslAppendLine(builder, 1, "let __yjson_literal_context = JsonEncodeContext(JsonWriteConfig.compact)")
        renderDirect(document.root, builder, 1)
        jsonDslAppendLine(builder, 1, "__yjson_literal_writer.finishString()")
        jsonDslAppendLine(builder, 0, "})()")
        cangjieLex(builder.toString())
    }

    func renderValue(document: JsonDslDocument): Tokens {
        let builder = StringBuilder()
        jsonDslAppendLine(builder, 0, "({ =>")
        renderBindings(document.bindings, builder, 1)
        jsonDslAppendLine(builder, 1, renderValueExpression(document.root))
        jsonDslAppendLine(builder, 0, "})()")
        cangjieLex(builder.toString())
    }

    private func renderBindings(bindings: ArrayList<JsonDslBinding>, builder: StringBuilder, level: Int64): Unit {
        for (binding in bindings) {
            let typeText = if (binding.keyBinding) {
                ": String"
            } else {
                ""
            }
            jsonDslAppendLine(builder, level, "let ${binding.name}${typeText} = (${binding.expression})")
        }
    }

    private func objectNeedsSlots(node: JsonDslNode): Bool {
        for (field in node.fields) {
            if (!field.staticKey) {
                return true
            }
        }
        false
    }

    private func renderObjectSlots(node: JsonDslNode, builder: StringBuilder, level: Int64): String {
        if (!objectNeedsSlots(node)) {
            return ""
        }
        let slots = localName("slots")
        jsonDslAppendLine(builder, level, "let ${slots} = YJsonHashMap<String, Int64>()")
        for (index in 0..node.fields.size) {
            jsonDslAppendLine(builder, level, "${slots}[${node.fields[index].keyExpression}] = ${index}")
        }
        slots
    }

    private func renderDirect(node: JsonDslNode, builder: StringBuilder, level: Int64): Unit {
        match (node.kind) {
            case JsonDslKind.DslNull => jsonDslAppendLine(builder, level, "__yjson_literal_writer.writeNull()")
            case JsonDslKind.DslBool => jsonDslAppendLine(builder, level,
                "__yjson_literal_writer.writeBool(${node.text})")
            case JsonDslKind.DslString => jsonDslAppendLine(builder, level,
                "__yjson_literal_writer.writeString(${node.text})")
            case JsonDslKind.DslNumber => jsonDslAppendLine(builder, level,
                "__yjson_literal_writer.writeRawNumber(\"${node.text}\")")
            case JsonDslKind.DslInterpolation => jsonDslAppendLine(builder, level,
                "YJson.writeValue(${node.text}, __yjson_literal_writer, __yjson_literal_context)")
            case JsonDslKind.DslArray => renderDirectArray(node, builder, level)
            case JsonDslKind.DslObject => renderDirectObject(node, builder, level)
        }
    }

    private func renderDirectArray(node: JsonDslNode, builder: StringBuilder, level: Int64): Unit {
        jsonDslAppendLine(builder, level, "__yjson_literal_context.enterValue()")
        jsonDslAppendLine(builder, level, "try {")
        jsonDslAppendLine(builder, level + 1, "__yjson_literal_writer.startArray()")
        for (index in 0..node.items.size) {
            jsonDslAppendLine(builder, level + 1, "__yjson_literal_context.pushIndex(${index})")
            jsonDslAppendLine(builder, level + 1, "try {")
            renderDirect(node.items[index], builder, level + 2)
            jsonDslAppendLine(builder, level + 1, "} finally { __yjson_literal_context.popPath() }")
        }
        jsonDslAppendLine(builder, level + 1, "__yjson_literal_writer.endArray()")
        jsonDslAppendLine(builder, level, "} finally { __yjson_literal_context.leaveValue() }")
    }

    private func renderDirectObject(node: JsonDslNode, builder: StringBuilder, level: Int64): Unit {
        jsonDslAppendLine(builder, level, "__yjson_literal_context.enterValue()")
        jsonDslAppendLine(builder, level, "try {")
        jsonDslAppendLine(builder, level + 1, "__yjson_literal_writer.startObject()")
        let slots = renderObjectSlots(node, builder, level + 1)
        for (index in 0..node.fields.size) {
            let field = node.fields[index]
            let conditional = !slots.isEmpty()
            if (conditional) {
                jsonDslAppendLine(builder, level + 1, "if (${slots}[${field.keyExpression}] == ${index}) {")
            }
            let fieldLevel = if (conditional) {
                level + 2
            } else {
                level + 1
            }
            jsonDslAppendLine(builder, fieldLevel, "__yjson_literal_writer.writeName(${field.keyExpression})")
            jsonDslAppendLine(builder, fieldLevel, "__yjson_literal_context.pushField(${field.keyExpression})")
            jsonDslAppendLine(builder, fieldLevel, "try {")
            renderDirect(field.value, builder, fieldLevel + 1)
            jsonDslAppendLine(builder, fieldLevel, "} finally { __yjson_literal_context.popPath() }")
            if (conditional) {
                jsonDslAppendLine(builder, level + 1, "}")
            }
        }
        jsonDslAppendLine(builder, level + 1, "__yjson_literal_writer.endObject()")
        jsonDslAppendLine(builder, level, "} finally { __yjson_literal_context.leaveValue() }")
    }

    private func renderValueExpression(node: JsonDslNode): String {
        match (node.kind) {
            case JsonDslKind.DslNull => "JsonNullValue()"
            case JsonDslKind.DslBool => "JsonBoolValue(${node.text})"
            case JsonDslKind.DslString => "JsonStringValue(${node.text})"
            case JsonDslKind.DslNumber => renderNumberValue(node.text)
            case JsonDslKind.DslInterpolation => "YJson.value(${node.text})"
            case JsonDslKind.DslArray => renderArrayValue(node)
            case JsonDslKind.DslObject => renderObjectValue(node)
        }
    }

    private func renderNumberValue(text: String): String {
        if (!text.contains(".") && !text.contains("e") && !text.contains("E")) {
            try {
                let _ = Int64.parse(text)
                return "JsonIntValue(${text})"
            } catch (_) {}
        }
        "JsonNumberLiteralValue(\"${text}\")"
    }

    private func renderArrayValue(node: JsonDslNode): String {
        let arrayName = localName("array")
        let builder = StringBuilder()
        jsonDslAppendLine(builder, 0, "({ =>")
        jsonDslAppendLine(builder, 1, "let ${arrayName} = JsonArrayValue()")
        for (item in node.items) {
            jsonDslAppendLine(builder, 1, "let _ = ${arrayName}.add(${renderValueExpression(item)})")
        }
        jsonDslAppendLine(builder, 1, arrayName)
        jsonDslAppendLine(builder, 0, "})()")
        builder.toString().trimAscii()
    }

    private func renderObjectValue(node: JsonDslNode): String {
        let objectName = localName("object")
        let builder = StringBuilder()
        jsonDslAppendLine(builder, 0, "({ =>")
        jsonDslAppendLine(builder, 1, "let ${objectName} = JsonObjectValue()")
        let slots = renderObjectSlots(node, builder, 1)
        for (index in 0..node.fields.size) {
            let field = node.fields[index]
            if (slots.isEmpty()) {
                jsonDslAppendLine(builder, 1,
                    "let _ = ${objectName}.put(${field.keyExpression}, ${renderValueExpression(field.value)})")
            } else {
                jsonDslAppendLine(builder, 1, "if (${slots}[${field.keyExpression}] == ${index}) {")
                jsonDslAppendLine(builder, 2,
                    "let _ = ${objectName}.put(${field.keyExpression}, ${renderValueExpression(field.value)})")
                jsonDslAppendLine(builder, 1, "}")
            }
        }
        jsonDslAppendLine(builder, 1, objectName)
        jsonDslAppendLine(builder, 0, "})()")
        builder.toString().trimAscii()
    }
}

private func parseJsonDsl(input: Tokens): JsonDslDocument {
    JsonDslParser(input).parse()
}

/// Builds a compact JSON String from JSON-like literal syntax. Runtime values
/// and dynamic String keys use $(). Each interpolation is evaluated once from
/// left to right; object key collisions use LastWins.
public macro Json(input: Tokens): Tokens {
    JsonDslRenderer().renderString(parseJsonDsl(input))
}

/// Builds a mutable JsonNode tree from the same syntax accepted by @Json.
public macro JsonValue(input: Tokens): Tokens {
    JsonDslRenderer().renderValue(parseJsonDsl(input))
}
