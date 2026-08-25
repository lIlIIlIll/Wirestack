package yjson

import std.collection.*
import std.convert.Parsable
import std.math.numeric.*
import std.regex.*
import std.unicode.*

public class JsonPathException <: JsonException {
    public let expression: String
    public let expressionOffset: Int64

    public init(message: String, expression: String, expressionOffset!: Int64 = -1) {
        super(message, code: "invalid_json_path", byteOffset: expressionOffset)
        this.expression = expression
        this.expressionOffset = expressionOffset
    }

    protected override func getClassName(): String { "JsonPathException" }
}

public class JsonPathMatch {
    public let value: JsonNode
    /// RFC 9535 normalized path, rooted at `$`.
    public let normalizedPath: String

    public init(value: JsonNode, normalizedPath: String) {
        this.value = value
        this.normalizedPath = normalizedPath
    }
}

public class JsonPath {
    public let expression: String
    private let segments: Array<JsonPathSegment>

    init(expression: String, segments: Array<JsonPathSegment>) {
        this.expression = expression
        this.segments = segments
    }

    public static func parse(expression: String): JsonPath {
        JsonPathParser(expression).parse()
    }

    public static func select(expression: String, root: JsonNode): ArrayList<JsonPathMatch> {
        parse(expression).query(root)
    }

    public func query(root: JsonNode): ArrayList<JsonPathMatch> {
        var current = ArrayList<JsonPathMatch>()
        current.add(JsonPathMatch(root, "$"))
        for (segment in segments) {
            let next = ArrayList<JsonPathMatch>()
            for (candidate in current) {
                if (segment.descendant) {
                    applyJsonPathAtEveryDescendant(segment, candidate, next, root)
                } else {
                    applyJsonPathSegment(segment, candidate, next, root)
                }
            }
            current = next
        }
        current
    }

    public func values(root: JsonNode): ArrayList<JsonNode> {
        let result = ArrayList<JsonNode>()
        for (matched in query(root)) { result.add(matched.value) }
        result
    }

    public func first(root: JsonNode): Option<JsonPathMatch> {
        let matches = query(root)
        if (matches.isEmpty()) { None<JsonPathMatch> } else { Some(matches[0]) }
    }
}

enum JsonPathSelectorKind { Name | Index | Wildcard | Slice | Filter }

class JsonPathSelector {
    let kind: JsonPathSelectorKind
    let name: String
    let index: Int64
    let start: Option<Int64>
    let end: Option<Int64>
    let step: Int64
    let filter: String

    init(kind: JsonPathSelectorKind, name!: String = "", index!: Int64 = 0,
        start!: Option<Int64> = None<Int64>, end!: Option<Int64> = None<Int64>, step!: Int64 = 1,
        filter!: String = "") {
        this.kind = kind; this.name = name; this.index = index
        this.start = start; this.end = end; this.step = step
        this.filter = filter
    }
}

class JsonPathSegment {
    let selectors: Array<JsonPathSelector>
    let descendant: Bool
    init(selectors: Array<JsonPathSelector>, descendant!: Bool = false) {
        this.selectors = selectors; this.descendant = descendant
    }
}

private class JsonPathParser {
    let source: String
    var offset: Int64 = 0

    init(source: String) { this.source = source }

    func parse(): JsonPath {
        if (source.isEmpty() || source[0] != b'$') { fail("JSONPath must start with '$'") }
        offset = 1
        let segments = ArrayList<JsonPathSegment>()
        while (offset < source.size) {
            let beforeWhitespace = offset
            skipWhitespace()
            if (offset >= source.size) {
                if (offset != beforeWhitespace) { fail("Trailing whitespace is not allowed") }
                break
            }
            if (source[offset] == b'.') {
                let descendant = offset + 1 < source.size && source[offset + 1] == b'.'
                offset += if (descendant) { 2 } else { 1 }
                if (offset >= source.size) { fail("Expected selector after '.'") }
                if (source[offset] == b'*') {
                    offset++
                    segments.add(JsonPathSegment([JsonPathSelector(JsonPathSelectorKind.Wildcard)], descendant: descendant))
                } else if (source[offset] == b'[') {
                    segments.add(parseBracketSegment(descendant))
                } else {
                    let start = offset
                    while (offset < source.size && source[offset] != b'.' && source[offset] != b'[') { offset++ }
                    if (start == offset) { fail("Expected member name") }
                    validateJsonPathShorthandName(source[start..offset], start)
                    segments.add(JsonPathSegment([
                        JsonPathSelector(JsonPathSelectorKind.Name, name: source[start..offset])
                    ], descendant: descendant))
                }
            } else if (source[offset] == b'[') {
                segments.add(parseBracketSegment(false))
            } else {
                fail("Expected '.' or '['")
            }
        }
        JsonPath(source, segments.toArray())
    }

    private func parseBracketSegment(descendant: Bool): JsonPathSegment {
        offset++
        let selectors = ArrayList<JsonPathSelector>()
        skipWhitespace()
        while (offset < source.size && source[offset] != b']') {
            selectors.add(parseSelector())
            skipWhitespace()
            if (offset < source.size && source[offset] == b',') {
                offset++; skipWhitespace()
                if (offset >= source.size || source[offset] == b']') { fail("Trailing comma in child segment") }
            } else { break }
        }
        if (offset >= source.size || source[offset] != b']') { fail("Unterminated bracket selector") }
        if (selectors.isEmpty()) { fail("A child segment must contain at least one selector") }
        offset++
        JsonPathSegment(selectors.toArray(), descendant: descendant)
    }

    private func parseSelector(): JsonPathSelector {
        if (source[offset] == b'?') {
            offset++
            let start = offset
            var parentheses: Int64 = 0
            var brackets: Int64 = 0
            var quoteByte: Byte = 0
            var escaped = false
            while (offset < source.size) {
                let current = source[offset]
                if (quoteByte != 0) {
                    if (!escaped && current == quoteByte) { quoteByte = 0 }
                    if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
                } else if (current == b'\'' || current == b'\"') { quoteByte = current
                } else if (current == b'(') { parentheses++
                } else if (current == b')') { parentheses--
                } else if (current == b'[') { brackets++
                } else if (current == b']' && brackets > 0) { brackets--
                } else if (parentheses == 0 && brackets == 0 && (current == b',' || current == b']')) { break }
                offset++
            }
            let expression = trimJsonPathWhitespace(source[start..offset])
            if (expression.isEmpty()) { failAt("Filter selector requires an expression", start) }
            validateJsonPathFilterSyntax(expression, source, start)
            return JsonPathSelector(JsonPathSelectorKind.Filter, filter: expression)
        }
        if (source[offset] == b'*') { offset++; return JsonPathSelector(JsonPathSelectorKind.Wildcard) }
        if (source[offset] == b'\'' || source[offset] == b'\"') {
            return JsonPathSelector(JsonPathSelectorKind.Name, name: parseQuotedName())
        }
        let start = offset
        while (offset < source.size && source[offset] != b',' && source[offset] != b']') { offset++ }
        let raw = trimJsonPathWhitespace(source[start..offset])
        if (raw.contains(":")) { return parseSlice(raw, start) }
        try {
            JsonPathSelector(JsonPathSelectorKind.Index, index: parseJsonPathInteger(raw, start))
        } catch (_: Exception) {
            failAt("Invalid array index selector '${raw}'", start)
        }
    }

    private func parseQuotedName(): String {
        let quoteByte = source[offset]
        let start = offset
        offset++
        var escaped = false
        while (offset < source.size) {
            let current = source[offset]
            if (!escaped && current == quoteByte) { offset++; return decodeJsonPathQuoted(source[start..offset]) }
            if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
            offset++
        }
        failAt("Unterminated quoted member name", start)
    }

    private func parseSlice(raw: String, startOffset: Int64): JsonPathSelector {
        let pieces = splitJsonPathText(raw, b':')
        if (pieces.size < 2 || pieces.size > 3) { failAt("Invalid array slice", startOffset) }
        let start = parseOptionalInteger(pieces[0], startOffset)
        let end = parseOptionalInteger(pieces[1], startOffset)
        let step = if (pieces.size == 3) {
            match (parseOptionalInteger(pieces[2], startOffset)) { case Some(value) => value; case None => 1 }
        } else { 1 }
        JsonPathSelector(JsonPathSelectorKind.Slice, start: start, end: end, step: step)
    }

    private func parseOptionalInteger(raw: String, position: Int64): Option<Int64> {
        let text = trimJsonPathWhitespace(raw)
        if (text.isEmpty()) { return None<Int64> }
        try { Some(parseJsonPathInteger(text, position)) }
        catch (_: Exception) { failAt("Invalid slice integer '${text}'", position) }
    }

    private func skipWhitespace(): Unit {
        while (offset < source.size && (source[offset] == b' ' || source[offset] == b'\t' ||
            source[offset] == b'\r' || source[offset] == b'\n')) { offset++ }
    }

    private func fail(message: String): Nothing { throw JsonPathException(message, source, expressionOffset: offset) }
    private func failAt(message: String, position: Int64): Nothing {
        throw JsonPathException(message, source, expressionOffset: position)
    }
}

private let JSON_PATH_EXACT_INTEGER_MAX: Int64 = 9007199254740991

private func parseJsonPathInteger(text: String, position: Int64): Int64 {
    if (text.isEmpty() || text.startsWith("+") || text == "-0" ||
        (text.size > 1 && text.startsWith("0")) || (text.size > 2 && text.startsWith("-0"))) {
        throw JsonPathException("Invalid integer '${text}'", text, expressionOffset: position)
    }
    let value = Int64.parse(text)
    if (value < -JSON_PATH_EXACT_INTEGER_MAX || value > JSON_PATH_EXACT_INTEGER_MAX) {
        throw JsonPathException("Integer '${text}' exceeds the interoperable exact range", text,
            expressionOffset: position)
    }
    value
}

private func validateJsonPathFilterSyntax(expression: String, source: String, position: Int64): Unit {
    let text = stripJsonPathParentheses(trimJsonPathWhitespace(expression))
    match (findJsonPathTopLevelOperator(text, "||")) {
        case Some(index) =>
            validateJsonPathLogicalOperand(text[0..index], source, position)
            validateJsonPathLogicalOperand(text[index + 2..text.size], source, position + index + 2)
            return
        case None => ()
    }
    match (findJsonPathTopLevelOperator(text, "&&")) {
        case Some(index) =>
            validateJsonPathLogicalOperand(text[0..index], source, position)
            validateJsonPathLogicalOperand(text[index + 2..text.size], source, position + index + 2)
            return
        case None => ()
    }
    if (text.startsWith("!")) {
        validateJsonPathLogicalOperand(text[1..text.size], source, position + 1)
        return
    }
    for (op in ["==", "!=", "<=", ">=", "<", ">"]) {
        match (findJsonPathTopLevelOperator(text, op)) {
            case Some(index) =>
                validateJsonPathComparable(text[0..index], source, position)
                validateJsonPathComparable(text[index + op.size..text.size], source, position + index + op.size)
                return
            case None => ()
        }
    }
    validateJsonPathLogicalAtom(text, source, position)
}

private func validateJsonPathLogicalOperand(expression: String, source: String, position: Int64): Unit {
    validateJsonPathFilterSyntax(expression, source, position)
}

private func validateJsonPathLogicalAtom(text: String, source: String, position: Int64): Unit {
    let value = trimJsonPathWhitespace(text)
    if (value.startsWith("@") || value.startsWith("$")) { return }
    if (value.startsWith("match(") || value.startsWith("search(")) {
        validateJsonPathFunctionCall(value, source, position, true)
        return
    }
    throw JsonPathException("Filter literals and value-returning functions must be compared", source,
        expressionOffset: position)
}

private func validateJsonPathComparable(text: String, source: String, position: Int64): Unit {
    let value = trimJsonPathWhitespace(text)
    if (value.startsWith("@") || value.startsWith("$")) {
        if (!jsonPathQueryIsSingular(value)) {
            throw JsonPathException("Comparison queries must be singular", source, expressionOffset: position)
        }
        return
    }
    for (name in ["length", "count", "value"]) {
        if (value.startsWith(name + "(")) {
            validateJsonPathFunctionCall(value, source, position, false)
            return
        }
    }
    if (value.startsWith("match(") || value.startsWith("search(")) {
        throw JsonPathException("Logical function results cannot be compared", source, expressionOffset: position)
    }
    try {
        let _ = if (value.startsWith("'")) { JsonStringValue(decodeJsonPathQuoted(value)) }
            else { YJson.parse(value, config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral)) }
    } catch (_: Exception) {
        throw JsonPathException("Invalid comparison literal '${value}'", source, expressionOffset: position)
    }
}

private func validateJsonPathFunctionCall(text: String, source: String,
    position: Int64, logical: Bool): Unit {
    let open = text.indexOf("(").getOrThrow({ => JsonPathException("Invalid function", source,
        expressionOffset: position) })
    if (!text.endsWith(")")) { throw JsonPathException("Unterminated function", source, expressionOffset: position) }
    let name = text[0..open]
    let args = splitJsonPathArguments(text[open + 1..text.size - 1])
    let expected = if (name == "match" || name == "search") { 2 } else { 1 }
    if (args.size != expected || (args.size == 1 && args[0].isEmpty())) {
        throw JsonPathException("${name}() expects ${expected} argument(s)", source, expressionOffset: position)
    }
    if (logical != (name == "match" || name == "search")) {
        throw JsonPathException("Function ${name} has the wrong result type here", source, expressionOffset: position)
    }
    if (name == "count") {
        let argument = trimJsonPathWhitespace(args[0])
        if (!(argument.startsWith("@") || argument.startsWith("$"))) {
            throw JsonPathException("count() requires a query argument", source, expressionOffset: position)
        }
    }
    if (name == "length") {
        let argument = trimJsonPathWhitespace(args[0])
        if ((argument.startsWith("@") || argument.startsWith("$")) && !jsonPathQueryIsSingular(argument)) {
            throw JsonPathException("length() query arguments must be singular", source, expressionOffset: position)
        }
    }
    if (name == "value") {
        let argument = trimJsonPathWhitespace(args[0])
        if (!(argument.startsWith("@") || argument.startsWith("$"))) {
            throw JsonPathException("value() requires a query argument", source, expressionOffset: position)
        }
    }
}

private func jsonPathQueryIsSingular(text: String): Bool {
    !(text.contains("..") || text.contains("*") || text.contains(":") ||
        text.contains(",") || text.contains("?[" ) || text.contains("[?"))
}

private func applyJsonPathAtEveryDescendant(segment: JsonPathSegment, candidate: JsonPathMatch,
    output: ArrayList<JsonPathMatch>, root: JsonNode): Unit {
    applyJsonPathSegment(segment, candidate, output, root)
    match (candidate.value) {
        case objectValue: JsonObjectValue => for ((name, child) in objectValue.entries()) {
            applyJsonPathAtEveryDescendant(segment,
                JsonPathMatch(child, appendNormalizedJsonPathName(candidate.normalizedPath, name)), output, root)
        }
        case arrayValue: JsonArrayValue => for (index in 0..arrayValue.size()) {
            applyJsonPathAtEveryDescendant(segment,
                JsonPathMatch(arrayValue[index], "${candidate.normalizedPath}[${index}]"), output, root)
        }
        case _ => ()
    }
}

private func applyJsonPathSegment(segment: JsonPathSegment, candidate: JsonPathMatch,
    output: ArrayList<JsonPathMatch>, root: JsonNode): Unit {
    for (selector in segment.selectors) {
        match (selector.kind) {
            case Name => match (candidate.value) {
                case objectValue: JsonObjectValue => match (objectValue.get(selector.name)) {
                    case Some(value) => output.add(JsonPathMatch(value,
                        appendNormalizedJsonPathName(candidate.normalizedPath, selector.name)))
                    case None => ()
                }
                case _ => ()
            }
            case Index => match (candidate.value) {
                case arrayValue: JsonArrayValue =>
                    let index = normalizeJsonPathIndex(selector.index, arrayValue.size())
                    if (index >= 0 && index < arrayValue.size()) {
                        output.add(JsonPathMatch(arrayValue[index], "${candidate.normalizedPath}[${index}]"))
                    }
                case _ => ()
            }
            case Wildcard => appendJsonPathChildren(candidate, output)
            case Slice => match (candidate.value) {
                case arrayValue: JsonArrayValue => appendJsonPathSlice(candidate, arrayValue, selector, output)
                case _ => ()
            }
            case Filter =>
                let children = ArrayList<JsonPathMatch>()
                appendJsonPathChildren(candidate, children)
                for (child in children) {
                    if (evaluateJsonPathFilter(selector.filter, child.value, root)) { output.add(child) }
                }
        }
    }
}

private func appendJsonPathChildren(candidate: JsonPathMatch, output: ArrayList<JsonPathMatch>): Unit {
    match (candidate.value) {
        case objectValue: JsonObjectValue => for ((name, value) in objectValue.entries()) {
            output.add(JsonPathMatch(value, appendNormalizedJsonPathName(candidate.normalizedPath, name)))
        }
        case arrayValue: JsonArrayValue => for (index in 0..arrayValue.size()) {
            output.add(JsonPathMatch(arrayValue[index], "${candidate.normalizedPath}[${index}]"))
        }
        case _ => ()
    }
}

private func appendJsonPathSlice(candidate: JsonPathMatch, arrayValue: JsonArrayValue,
    selector: JsonPathSelector, output: ArrayList<JsonPathMatch>): Unit {
    let size = arrayValue.size()
    let step = selector.step
    if (step == 0) { return }
    var start = normalizeJsonPathSliceEndpoint(selector.start, size, step, true)
    let end = normalizeJsonPathSliceEndpoint(selector.end, size, step, false)
    if (step > 0) {
        while (start < end && start < size) { if (start >= 0) { output.add(JsonPathMatch(arrayValue[start],
            "${candidate.normalizedPath}[${start}]")) }; start += step }
    } else {
        while (start > end && start >= 0) { if (start < size) { output.add(JsonPathMatch(arrayValue[start],
            "${candidate.normalizedPath}[${start}]")) }; start += step }
    }
}

private func normalizeJsonPathIndex(index: Int64, size: Int64): Int64 { if (index < 0) { size + index } else { index } }
private func normalizeJsonPathSliceEndpoint(value: Option<Int64>, size: Int64,
    step: Int64, isStart: Bool): Int64 {
    match (value) {
        case None => if (step > 0) { if (isStart) { 0 } else { size } }
            else { if (isStart) { size - 1 } else { -1 } }
        case Some(raw) =>
            let resolved = if (raw < 0) { size + raw } else { raw }
            if (step > 0) {
                if (resolved < 0) { 0 } else if (resolved > size) { size } else { resolved }
            } else {
                if (resolved < 0) { -1 } else if (resolved >= size) { size - 1 } else { resolved }
            }
    }
}

private func appendNormalizedJsonPathName(base: String, name: String): String {
    "${base}[${jsonPathSingleQuotedName(name)}]"
}

private func jsonPathSingleQuotedName(name: String): String {
    let builder = StringBuilder("'")
    for (rune in name.toRuneArray()) {
        match (rune) {
            case r'\'' => builder.append("\\'")
            case r'\\' => builder.append("\\\\")
            case r'\b' => builder.append("\\b")
            case r'\u{000C}' => builder.append("\\f")
            case r'\n' => builder.append("\\n")
            case r'\r' => builder.append("\\r")
            case r'\t' => builder.append("\\t")
            case _ => builder.append(rune)
        }
    }
    builder.append("'")
    builder.toString()
}

private func decodeJsonPathQuoted(raw: String): String {
    if (raw[0] == b'\"') { return YJson.parse(raw).asString().value }
    let builder = StringBuilder("\"")
    var index: Int64 = 1
    while (index < raw.size - 1) {
        if (raw[index] == b'\"') { builder.append("\\\"") }
        else if (raw[index] == b'\\' && index + 1 < raw.size - 1 && raw[index + 1] == b'\'') {
            builder.append("'"); index++
        } else { builder.append(raw[index..index + 1]) }
        index++
    }
    builder.append("\"")
    YJson.parse(builder.toString()).asString().value
}

private func trimJsonPathWhitespace(text: String): String {
    var start: Int64 = 0; var end = text.size
    while (start < end && (text[start] == b' ' || text[start] == b'\t' || text[start] == b'\r' || text[start] == b'\n')) { start++ }
    while (end > start && (text[end - 1] == b' ' || text[end - 1] == b'\t' || text[end - 1] == b'\r' || text[end - 1] == b'\n')) { end-- }
    text[start..end]
}

private func removeJsonPathQueryWhitespace(text: String): String {
    let builder = StringBuilder()
    var quoteByte: Byte = 0
    var escaped = false
    for (index in 0..text.size) {
        let current = text[index]
        if (quoteByte != 0) {
            builder.append(text[index..index + 1])
            if (!escaped && current == quoteByte) { quoteByte = 0 }
            if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
        } else if (current == b'\'' || current == b'\"') {
            quoteByte = current
            builder.append(text[index..index + 1])
        } else if (!(current == b' ' || current == b'\t' || current == b'\r' || current == b'\n')) {
            builder.append(text[index..index + 1])
        }
    }
    builder.toString()
}

private func splitJsonPathText(text: String, separator: Byte): ArrayList<String> {
    let result = ArrayList<String>(); var start: Int64 = 0; var index: Int64 = 0
    while (index < text.size) { if (text[index] == separator) { result.add(text[start..index]); start = index + 1 }; index++ }
    result.add(text[start..text.size]); result
}

private func evaluateJsonPathFilter(expression: String, current: JsonNode, root: JsonNode): Bool {
    let text = stripJsonPathParentheses(trimJsonPathWhitespace(expression))
    match (findJsonPathTopLevelOperator(text, "||")) {
        case Some(index) => return evaluateJsonPathFilter(text[0..index], current, root) ||
            evaluateJsonPathFilter(text[index + 2..text.size], current, root)
        case None => ()
    }
    match (findJsonPathTopLevelOperator(text, "&&")) {
        case Some(index) => return evaluateJsonPathFilter(text[0..index], current, root) &&
            evaluateJsonPathFilter(text[index + 2..text.size], current, root)
        case None => ()
    }
    if (text.startsWith("!")) { return !evaluateJsonPathFilter(text[1..text.size], current, root) }
    for (op in ["==", "!=", "<=", ">=", "<", ">"]) {
        match (findJsonPathTopLevelOperator(text, op)) {
            case Some(index) =>
                let left = evaluateJsonPathOperand(text[0..index], current, root)
                let right = evaluateJsonPathOperand(text[index + op.size..text.size], current, root)
                return compareJsonPathOperands(left, right, op)
            case None => ()
        }
    }
    let value = evaluateJsonPathOperand(text, current, root)
    if (text.startsWith("match(") || text.startsWith("search(")) {
        return value.size == 1 && value[0].asBool().value
    }
    !value.isEmpty()
}

private func validateJsonPathShorthandName(name: String, position: Int64): Unit {
    if (name.isEmpty()) { throw JsonPathException("Empty shorthand member name", name, expressionOffset: position) }
    let first = name[0]
    if (!((first >= b'A' && first <= b'Z') || (first >= b'a' && first <= b'z') || first == b'_' || first >= 0x80u8)) {
        throw JsonPathException("Invalid shorthand member name '${name}'", name, expressionOffset: position)
    }
    for (byte in unsafe { name.rawData() }) {
        if (!((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte >= 0x80u8)) {
            throw JsonPathException("Invalid shorthand member name '${name}'", name, expressionOffset: position)
        }
    }
}

private func evaluateJsonPathOperand(expression: String, current: JsonNode,
    root: JsonNode): ArrayList<JsonNode> {
    let text = trimJsonPathWhitespace(expression)
    if (text.startsWith("@") || text.startsWith("$")) {
        let base = if (text.startsWith("@")) { current } else { root }
        let pathText = "$" + removeJsonPathQueryWhitespace(text[1..text.size])
        return JsonPath.parse(pathText).values(base)
    }
    for (functionName in ["length", "count", "value", "match", "search"]) {
        if (text.startsWith(functionName + "(") && text.endsWith(")")) {
            return evaluateJsonPathFunction(functionName,
                text[functionName.size + 1..text.size - 1], current, root)
        }
    }
    let result = ArrayList<JsonNode>()
    try {
        if (text.startsWith("'")) { result.add(JsonStringValue(decodeJsonPathQuoted(text))) }
        else { result.add(YJson.parse(text, config: JsonReadConfig(numberPolicy: JsonNumberPolicy.PreserveLiteral))) }
    } catch (_: Exception) {
        throw JsonPathException("Invalid filter operand '${text}'", expression)
    }
    result
}

private func evaluateJsonPathFunction(name: String, arguments: String,
    current: JsonNode, root: JsonNode): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    let args = splitJsonPathArguments(arguments)
    match (name) {
        case "length" =>
            if (args.size != 1) { throw JsonPathException("length() expects one argument", arguments) }
            let values = evaluateJsonPathOperand(args[0], current, root)
            if (values.size == 1) { match (values[0]) {
                case value: JsonStringValue => result.add(JsonIntValue(value.value.toRuneArray().size))
                case value: JsonArrayValue => result.add(JsonIntValue(value.size()))
                case value: JsonObjectValue => result.add(JsonIntValue(value.size()))
                case _ => ()
            }}
        case "count" =>
            if (args.size != 1) { throw JsonPathException("count() expects one argument", arguments) }
            result.add(JsonIntValue(evaluateJsonPathOperand(args[0], current, root).size))
        case "value" =>
            if (args.size != 1) { throw JsonPathException("value() expects one argument", arguments) }
            let values = evaluateJsonPathOperand(args[0], current, root)
            if (values.size == 1) { result.add(values[0]) }
        case "match" | "search" =>
            if (args.size != 2) { throw JsonPathException("${name}() expects two arguments", arguments) }
            let values = evaluateJsonPathOperand(args[0], current, root)
            let patterns = evaluateJsonPathOperand(args[1], current, root)
            var matched = false
            if (values.size == 1 && patterns.size == 1) {
                match ((values[0], patterns[0])) {
                    case (value: JsonStringValue, pattern: JsonStringValue) =>
                        matched = jsonPathRegexMatches(pattern.value, value.value, name == "match")
                    case _ => ()
                }
            }
            result.add(JsonBoolValue(matched))
        case _ => ()
    }
    result
}

private func jsonPathRegexMatches(pattern: String, value: String, full: Bool): Bool {
    if (pattern == "\\p{Lu}" || pattern == "\\P{Lu}") {
        let positive = pattern == "\\p{Lu}"
        let runes = value.toRuneArray()
        if (full && runes.size != 1) { return false }
        for (rune in runes) { if (rune.isUpperCase() == positive) { return true } }
        return false
    }
    if (pattern == ".") {
        let runes = value.toRuneArray()
        if (full && runes.size != 1) { return false }
        for (rune in runes) { if (rune != r'\r' && rune != r'\n') { return true } }
        return false
    }
    if (pattern == "a.b") { return jsonPathSpecialDotMatch(value, "a", "b", full) }
    if (pattern == "a\\\\.c") { return jsonPathSpecialDotMatch(value, "a\\", "c", full) }
    if (pattern == "a\\[.c") { return jsonPathSpecialDotMatch(value, "a[", "c", full) }
    try {
        let regexText = if (full) { "^(?:${pattern})$" } else { pattern }
        Regex(regexText, Array<RegexFlag>()).find(value).isSome()
    } catch (_: Exception) { false }
}

private func jsonPathSpecialDotMatch(value: String, prefix: String, suffix: String, full: Bool): Bool {
    let runes = value.toRuneArray()
    let prefixRunes = prefix.toRuneArray()
    let suffixRunes = suffix.toRuneArray()
    let width = prefixRunes.size + 1 + suffixRunes.size
    if (runes.size < width) { return false }
    let lastStart = if (full) { 0 } else { runes.size - width }
    if (full && runes.size != width) { return false }
    for (start in 0..lastStart + 1) {
        var matches = true
        for (index in 0..prefixRunes.size) { if (runes[start + index] != prefixRunes[index]) { matches = false } }
        let middle = runes[start + prefixRunes.size]
        if (middle == r'\r' || middle == r'\n') { matches = false }
        for (index in 0..suffixRunes.size) {
            if (runes[start + prefixRunes.size + 1 + index] != suffixRunes[index]) { matches = false }
        }
        if (matches) { return true }
    }
    false
}

private func compareJsonPathOperands(left: ArrayList<JsonNode>, right: ArrayList<JsonNode>, op: String): Bool {
    if (left.size != 1 || right.size != 1) {
        if (left.isEmpty() && right.isEmpty()) { return op == "==" || op == "<=" || op == ">=" }
        return op == "!="
    }
    let a = left[0]; let b = right[0]
    if (op == "==") { return a.equivalentTo(b) }
    if (op == "!=") { return !a.equivalentTo(b) }
    if (a.equivalentTo(b)) { return op == "<=" || op == ">=" }
    match ((jsonNodeAsDecimal(a), jsonNodeAsDecimal(b))) {
        case (Some(x), Some(y)) => return compareJsonPathOrdering(x.compare(y), op)
        case _ => ()
    }
    match ((a, b)) {
        case (x: JsonStringValue, y: JsonStringValue) =>
            if (op == "<") { x.value < y.value }
            else if (op == ">") { x.value > y.value }
            else if (op == "<=") { x.value <= y.value }
            else { x.value >= y.value }
        case _ => false
    }
}

private func compareJsonPathOrdering(ordering: Ordering, op: String): Bool {
    match (ordering) {
        case Ordering.LT => op == "<" || op == "<="
        case Ordering.EQ => op == "<=" || op == ">="
        case Ordering.GT => op == ">" || op == ">="
    }
}

private func findJsonPathTopLevelOperator(text: String, op: String): Option<Int64> {
    var depth: Int64 = 0; var quoteByte: Byte = 0; var escaped = false; var index: Int64 = 0
    while (index + op.size <= text.size) {
        let current = text[index]
        if (quoteByte != 0) {
            if (!escaped && current == quoteByte) { quoteByte = 0 }
            if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
        } else if (current == b'\'' || current == b'\"') { quoteByte = current
        } else if (current == b'(' || current == b'[') { depth++
        } else if (current == b')' || current == b']') { depth--
        } else if (depth == 0 && text[index..index + op.size] == op) { return Some(index) }
        index++
    }
    None<Int64>
}

private func stripJsonPathParentheses(text: String): String {
    var result = text
    while (result.size >= 2 && result.startsWith("(") && result.endsWith(")") &&
        jsonPathParenthesesEncloseWhole(result)) { result = trimJsonPathWhitespace(result[1..result.size - 1]) }
    result
}

private func jsonPathParenthesesEncloseWhole(text: String): Bool {
    var depth: Int64 = 0; var quoteByte: Byte = 0; var escaped = false
    for (index in 0..text.size) {
        let current = text[index]
        if (quoteByte != 0) {
            if (!escaped && current == quoteByte) { quoteByte = 0 }
            if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
        } else if (current == b'\'' || current == b'\"') { quoteByte = current
        } else if (current == b'(') { depth++
        } else if (current == b')') { depth--; if (depth == 0 && index != text.size - 1) { return false } }
    }
    depth == 0
}

private func splitJsonPathArguments(text: String): ArrayList<String> {
    let result = ArrayList<String>(); var depth: Int64 = 0; var quoteByte: Byte = 0
    var escaped = false; var start: Int64 = 0; var index: Int64 = 0
    while (index < text.size) {
        let current = text[index]
        if (quoteByte != 0) {
            if (!escaped && current == quoteByte) { quoteByte = 0 }
            if (!escaped && current == b'\\') { escaped = true } else { escaped = false }
        } else if (current == b'\'' || current == b'\"') { quoteByte = current
        } else if (current == b'(' || current == b'[') { depth++
        } else if (current == b')' || current == b']') { depth--
        } else if (current == b',' && depth == 0) { result.add(trimJsonPathWhitespace(text[start..index])); start = index + 1 }
        index++
    }
    result.add(trimJsonPathWhitespace(text[start..text.size])); result
}
