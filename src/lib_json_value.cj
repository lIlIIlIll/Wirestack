package yjson

import std.collection.*
import std.convert.Parsable

public enum JsonKind <: Equatable<JsonKind> {
    JsNull | JsBool | JsInt | JsFloat | JsNumberLiteral | JsString | JsArray | JsObject

    public operator func ==(other: JsonKind): Bool {
        match (this) {
            case JsNull =>
                if (let JsNull <- other) {
                    true
                } else {
                    false
                }
            case JsBool =>
                if (let JsBool <- other) {
                    true
                } else {
                    false
                }
            case JsInt =>
                if (let JsInt <- other) {
                    true
                } else {
                    false
                }
            case JsFloat =>
                if (let JsFloat <- other) {
                    true
                } else {
                    false
                }
            case JsNumberLiteral =>
                if (let JsNumberLiteral <- other) {
                    true
                } else {
                    false
                }
            case JsString =>
                if (let JsString <- other) {
                    true
                } else {
                    false
                }
            case JsArray =>
                if (let JsArray <- other) {
                    true
                } else {
                    false
                }
            case JsObject =>
                if (let JsObject <- other) {
                    true
                } else {
                    false
                }
        }
    }

    public operator func !=(other: JsonKind): Bool {
        !(this == other)
    }
}

public open class JsonException <: Exception {
    public let code: String
    public let byteOffset: Int64
    public let line: Int64
    public let column: Int64
    public let path: String

    public init(
        message: String,
        code!: String = "json_error",
        byteOffset!: Int64 = -1,
        line!: Int64 = -1,
        column!: Int64 = -1,
        path!: String = ""
    ) {
        super(message)
        this.code = code
        this.byteOffset = byteOffset
        this.line = line
        this.column = column
        this.path = path
    }

    protected open override func getClassName(): String {
        "JsonException"
    }
}

public enum JsonUnknownFieldPolicy {
    Ignore | Reject
}

public enum JsonDuplicateKeyPolicy {
    LastWins | Reject
}

public enum JsonNumberPolicy {
    Int64WhenExact | PreserveLiteral
}

public class JsonReadLimits {
    public let maxDepth: Int64
    public let maxPolymorphicObjectBytes: Int64
    public let maxStringBytes: Int64
    public let maxBytes: Int64

    public init(maxDepth!: Int64 = 256, maxPolymorphicObjectBytes!: Int64 = 0,
        maxStringBytes!: Int64 = 0, maxBytes!: Int64 = 0) {
        if (maxDepth <= 0) { throw IllegalArgumentException("maxDepth must be positive") }
        if (maxPolymorphicObjectBytes < 0) { throw IllegalArgumentException("maxPolymorphicObjectBytes must not be negative") }
        if (maxStringBytes < 0) { throw IllegalArgumentException("maxStringBytes must not be negative") }
        if (maxBytes < 0) { throw IllegalArgumentException("maxBytes must not be negative") }
        this.maxDepth = maxDepth
        this.maxPolymorphicObjectBytes = maxPolymorphicObjectBytes
        this.maxStringBytes = maxStringBytes
        this.maxBytes = maxBytes
    }

    public static let defaults: JsonReadLimits = JsonReadLimits()
}

public class JsonReadConfig {
    public let unknownFieldPolicy: JsonUnknownFieldPolicy
    public let duplicateKeyPolicy: JsonDuplicateKeyPolicy
    public let numberPolicy: JsonNumberPolicy
    public let includeErrorLocation: Bool
    public let limits: JsonReadLimits
    public let maxDepth: Int64
    public let maxPolymorphicObjectBytes: Int64
    public let maxStringBytes: Int64
    public let maxBytes: Int64
    let defaultFastPath: Bool

    public init(
        unknownFieldPolicy!: JsonUnknownFieldPolicy = JsonUnknownFieldPolicy.Ignore,
        duplicateKeyPolicy!: JsonDuplicateKeyPolicy = JsonDuplicateKeyPolicy.LastWins,
        numberPolicy!: JsonNumberPolicy = JsonNumberPolicy.Int64WhenExact,
        includeErrorLocation!: Bool = true,
        limits!: JsonReadLimits = JsonReadLimits.defaults
    ) {
        this.unknownFieldPolicy = unknownFieldPolicy
        this.duplicateKeyPolicy = duplicateKeyPolicy
        this.numberPolicy = numberPolicy
        this.includeErrorLocation = includeErrorLocation
        this.limits = limits
        this.maxDepth = limits.maxDepth
        this.maxPolymorphicObjectBytes = limits.maxPolymorphicObjectBytes
        this.maxStringBytes = limits.maxStringBytes
        this.maxBytes = limits.maxBytes
        let unknownIsDefault = match (unknownFieldPolicy) {
            case Ignore => true
            case _ => false
        }
        let duplicateIsDefault = match (duplicateKeyPolicy) {
            case LastWins => true
            case _ => false
        }
        let numberIsDefault = match (numberPolicy) {
            case Int64WhenExact => true
            case _ => false
        }
        this.defaultFastPath = unknownIsDefault && duplicateIsDefault && numberIsDefault && includeErrorLocation &&
            limits.maxDepth == 256 && limits.maxPolymorphicObjectBytes == 0 && limits.maxStringBytes == 0 && limits.maxBytes == 0
    }

    public static let defaults: JsonReadConfig = JsonReadConfig()

    public func rejectsUnknownFields(): Bool {
        match (unknownFieldPolicy) {
            case Reject => true
            case _ => false
        }
    }

    public func rejectsDuplicateKeys(): Bool {
        match (duplicateKeyPolicy) {
            case Reject => true
            case _ => false
        }
    }
}

func jsonReadConfigUsesDefaultFastPath(config: JsonReadConfig): Bool {
    config.defaultFastPath
}

func jsonReadConfigRejectsUnknownFields(config: JsonReadConfig): Bool {
    match (config.unknownFieldPolicy) {
        case Reject => true
        case _ => false
    }
}

func jsonReadConfigRejectsDuplicateKeys(config: JsonReadConfig): Bool {
    match (config.duplicateKeyPolicy) {
        case Reject => true
        case _ => false
    }
}

func jsonReadConfigPreservesNumberLiterals(config: JsonReadConfig): Bool {
    match (config.numberPolicy) {
        case PreserveLiteral => true
        case _ => false
    }
}

func jsonLineFromUtf8Bytes(data: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0) {
        return -1
    }
    let limit = if (offset > data.size) {
        data.size
    } else {
        offset
    }
    var line: Int64 = 1
    for (index in 0..limit) {
        if (data[index] == b'\n') {
            line++
        }
    }
    line
}

func jsonColumnFromUtf8Bytes(data: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0) {
        return -1
    }
    let limit = if (offset > data.size) {
        data.size
    } else {
        offset
    }
    var column: Int64 = 1
    for (index in 0..limit) {
        if (data[index] == b'\n') {
            column = 1
        } else {
            column++
        }
    }
    column
}

// Stream readers retain only the current byte buffer, so error positions must
// be reconstructed from absolute newline offsets instead of the current
// cursor. Newlines at the queried offset belong to the preceding line, which
// matches jsonLineFromUtf8Bytes/jsonColumnFromUtf8Bytes.
func jsonStreamLineAt(newlineOffsets: ArrayList<Int64>, offset: Int64): Int64 {
    if (offset < 0) { return -1 }
    var line: Int64 = 1
    for (newlineOffset in newlineOffsets) {
        if (newlineOffset >= offset) { break }
        line++
    }
    line
}

func jsonStreamColumnAt(newlineOffsets: ArrayList<Int64>, offset: Int64): Int64 {
    if (offset < 0) { return -1 }
    for (index in 0..newlineOffsets.size) {
        let reverseIndex = newlineOffsets.size - index - 1
        let newlineOffset = newlineOffsets[reverseIndex]
        if (newlineOffset < offset) { return offset - newlineOffset }
    }
    offset + 1
}

public abstract class JsonNode <: ToString {
    public static func parse(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        JsonParser(text, config: config).parse()
    }

    /// Parses raw UTF-8 JSON without first materializing the complete input as
    /// a String. String values and object keys are still materialized because
    /// they are part of the public JsonNode representation.
    public static func parse(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonNode {
        parseJsonValueFromBytes(bytes, config: config)
    }

    public func kind(): JsonKind

    /// Returns a detached JSON tree. Shared children are copied per occurrence.
    public func deepCopy(): JsonNode {
        deepCopyJsonNode(this)
    }

    /// JSON data-model equality. Numerically equal JSON numbers compare equal
    /// even when their lexical representations differ.
    public func equivalentTo(other: JsonNode): Bool {
        jsonNodesEquivalent(this, other)
    }

    public func toPrettyString(): String {
        toPrettyString("  ")
    }

    public func toPrettyString(indent: String): String

    public func asNull(): JsonNullValue {
        match (this) {
            case value: JsonNullValue => value
            case _ => throw JsonException("Expected null value")
        }
    }

    public func asBool(): JsonBoolValue {
        match (this) {
            case value: JsonBoolValue => value
            case _ => throw JsonException("Expected bool value")
        }
    }

    public func asInt(): JsonIntValue {
        match (this) {
            case value: JsonIntValue => value
            case value: JsonNumberLiteralValue => JsonIntValue(Int64.parse(value.literal))
            case _ => throw JsonException("Expected int value")
        }
    }

    public func asFloat(): JsonFloatValue {
        match (this) {
            case value: JsonFloatValue => value
            case intValue: JsonIntValue => JsonFloatValue(Float64(intValue.value))
            case value: JsonNumberLiteralValue => JsonFloatValue(Float64.parse(value.literal))
            case _ => throw JsonException("Expected float value")
        }
    }

    public func asNumberLiteral(): JsonNumberLiteralValue {
        match (this) {
            case value: JsonNumberLiteralValue => value
            case value: JsonIntValue => JsonNumberLiteralValue(value.value.toString())
            case value: JsonFloatValue => JsonNumberLiteralValue(value.value.toString())
            case _ => throw JsonException("Expected numeric value")
        }
    }

    public func asString(): JsonStringValue {
        match (this) {
            case value: JsonStringValue => value
            case _ => throw JsonException("Expected string value")
        }
    }

    public func asArray(): JsonArrayValue {
        match (this) {
            case value: JsonArrayValue => value
            case _ => throw JsonException("Expected array value")
        }
    }

    public func asObject(): JsonObjectValue {
        match (this) {
            case value: JsonObjectValue => value
            case _ => throw JsonException("Expected object value")
        }
    }

    public prop string: String {
        get() {
            asString().value
        }
    }

    public prop bool: Bool {
        get() {
            asBool().value
        }
    }

    public prop int64: Int64 {
        get() {
            asInt().value
        }
    }

    public prop float64: Float64 {
        get() {
            asFloat().value
        }
    }

    public prop numberText: String {
        get() {
            asNumberLiteral().literal
        }
    }

    public prop array: JsonArrayValue {
        get() {
            asArray()
        }
    }

    public prop object: JsonObjectValue {
        get() {
            asObject()
        }
    }

    public prop isNull: Bool {
        get() {
            match (this) {
                case _: JsonNullValue => true
                case _ => false
            }
        }
    }

    public operator func [](key: String): JsonNode {
        asObject().get(key).getOrThrow({
            => JsonException("Missing object key '${key}'", code: "missing_key")
        })
    }

    public operator func [](key: String, value!: JsonNode): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: Bool): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: Int64): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: Float64): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: Rune): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: String): Unit {
        asObject().put(key, value)
    }

    public operator func [](key: String, value!: Array<JsonNode>): Unit {
        asObject().put(key, YJson.value(value))
    }

    public operator func [](index: Int64): JsonNode {
        asArray().get(index).getOrThrow({
            => JsonException("Array index ${index} is out of bounds", code: "index_out_of_bounds")
        })
    }

    public operator func [](index: Int64, value!: JsonNode): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: Bool): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: Int64): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: Float64): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: Rune): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: String): Unit {
        asArray().set(index, value)
    }

    public operator func [](index: Int64, value!: Array<JsonNode>): Unit {
        asArray().set(index, YJson.value(value))
    }
}

public class JsonNullValue <: JsonNode {
    public func kind(): JsonKind {
        JsNull
    }

    public func toString(): String {
        "null"
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonBoolValue <: JsonNode {
    public let value: Bool

    public init(value: Bool) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsBool
    }

    public func toString(): String {
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonIntValue <: JsonNode {
    public let value: Int64

    public init(value: Int64) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsInt
    }

    public func toString(): String {
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonFloatValue <: JsonNode {
    public let value: Float64

    public init(value: Float64) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsFloat
    }

    public func toString(): String {
        ensureFiniteJsonFloat(value)
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonNumberLiteralValue <: JsonNode {
    public let literal: String

    public init(literal: String) {
        if (!isValidJsonNumberLiteral(literal)) {
            throw IllegalArgumentException("Invalid JSON number literal: ${literal}")
        }
        this.literal = literal
    }

    private init(literal: String, parsed: Bool) {
        let _ = parsed
        this.literal = literal
    }

    static func fromParsedLiteral(literal: String): JsonNumberLiteralValue {
        JsonNumberLiteralValue(literal, true)
    }

    public func kind(): JsonKind {
        JsNumberLiteral
    }

    public func toString(): String {
        literal
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        literal
    }
}

private func isValidJsonNumberLiteral(literal: String): Bool {
    unsafe {
        let bytes = literal.rawData()
        if (bytes.isEmpty()) { return false }
        var index: Int64 = 0
        if (bytes[index] == b'-') {
            index++
            if (index >= bytes.size) { return false }
        }
        if (bytes[index] == b'0') {
            index++
            if (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') {
                return false
            }
        } else {
            if (bytes[index] < b'1' || bytes[index] > b'9') { return false }
            index++
            while (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') { index++ }
        }
        if (index < bytes.size && bytes[index] == b'.') {
            index++
            if (index >= bytes.size || bytes[index] < b'0' || bytes[index] > b'9') { return false }
            while (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') { index++ }
        }
        if (index < bytes.size && (bytes[index] == b'e' || bytes[index] == b'E')) {
            index++
            if (index < bytes.size && (bytes[index] == b'+' || bytes[index] == b'-')) { index++ }
            if (index >= bytes.size || bytes[index] < b'0' || bytes[index] > b'9') { return false }
            while (index < bytes.size && bytes[index] >= b'0' && bytes[index] <= b'9') { index++ }
        }
        index == bytes.size
    }
}

public class JsonStringValue <: JsonNode {
    public let value: String

    public init(value: String) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsString
    }

    public func toString(): String {
        let writer = JsonDirectWriter()
        writer.writeRawString(value)
        writer.finishString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonArrayValue <: JsonNode {
    private let items: ArrayList<JsonNode>

    public init() {
        items = ArrayList<JsonNode>()
    }

    public init(items: ArrayList<JsonNode>) {
        this.items = items
    }

    public init(items: Array<JsonNode>) {
        this.items = ArrayList<JsonNode>(items)
    }

    public func kind(): JsonKind {
        JsArray
    }

    public func add(value: JsonNode): JsonArrayValue {
        items.add(value)
        this
    }

    public func add<T>(value: T): JsonArrayValue where T <: JsonCodecProvider {
        add(YJson.value(value))
    }

    public func set(index: Int64, value: JsonNode): JsonArrayValue {
        if (index < 0 || index >= items.size) {
            throw JsonException("Array index ${index} is out of bounds", code: "index_out_of_bounds")
        }
        items[index] = value
        this
    }

    public func set<T>(index: Int64, value: T): JsonArrayValue where T <: JsonCodecProvider {
        set(index, YJson.value(value))
    }

    public func insert(index: Int64, value: JsonNode): JsonArrayValue {
        if (index < 0 || index > items.size) {
            throw JsonException("Array index ${index} is out of bounds", code: "index_out_of_bounds")
        }
        items.add(value, at: index)
        this
    }

    public func removeAt(index: Int64): JsonNode {
        if (index < 0 || index >= items.size) {
            throw JsonException("Array index ${index} is out of bounds", code: "index_out_of_bounds")
        }
        items.remove(at: index)
    }

    public func size(): Int64 {
        items.size
    }

    public func values(): ArrayList<JsonNode> {
        items
    }

    public func get(index: Int64): Option<JsonNode> {
        items.get(index)
    }

    public func toString(): String {
        let writer = JsonDirectWriter()
        writeJsonValueCompact(writer, this)
        writer.finishString()
    }

    public func toPrettyString(indent: String): String {
        writeJsonValueToString(this, JsonWriteConfig("\n", indent, true, false))
    }
}

public class JsonObjectValue <: JsonNode {
    private let fields: HashMap<String, JsonNode>

    public init() {
        fields = HashMap<String, JsonNode>()
    }

    public init(fields: HashMap<String, JsonNode>) {
        this.fields = fields
    }

    public func kind(): JsonKind {
        JsObject
    }

    public func size(): Int64 {
        fields.size
    }

    public func contains(key: String): Bool {
        fields.contains(key)
    }

    public func put(key: String, value: JsonNode): JsonObjectValue {
        fields.add(key, value)
        this
    }

    public func put<T>(key: String, value: T): JsonObjectValue where T <: JsonCodecProvider {
        put(key, YJson.value(value))
    }

    public func get(key: String): Option<JsonNode> {
        fields.get(key)
    }

    public func remove(key: String): Option<JsonNode> {
        fields.remove(key)
    }

    public func entries(): HashMap<String, JsonNode> {
        fields
    }

    public func toString(): String {
        let writer = JsonDirectWriter()
        writeJsonValueCompact(writer, this)
        writer.finishString()
    }

    public func toPrettyString(indent: String): String {
        writeJsonValueToString(this, JsonWriteConfig("\n", indent, true, false))
    }
}

let JSON_HEX = "0123456789ABCDEF"

func isJsonHighSurrogate(value: Int64): Bool {
    value >= 0xD800 && value <= 0xDBFF
}

func isJsonLowSurrogate(value: Int64): Bool {
    value >= 0xDC00 && value <= 0xDFFF
}

func combineJsonSurrogates(high: Int64, low: Int64): UInt32 {
    UInt32(0x10000 + ((high - 0xD800) * 0x400) + (low - 0xDC00))
}

func ensureFiniteJsonFloat(value: Float64): Unit {
    if (value.isNaN() || value.isInf()) {
        throw JsonException("Cannot encode non-finite float value")
    }
}

func writeEscapedJsonString(builder: StringBuilder, value: String): Unit {
    builder.append("\"")
    for (r in value.toRuneArray()) {
        match (r) {
            case r'"' => builder.append("\\\"")
            case r'\\' => builder.append("\\\\")
            case r'\b' => builder.append("\\b")
            case r'\f' => builder.append("\\f")
            case r'\n' => builder.append("\\n")
            case r'\r' => builder.append("\\r")
            case r'\t' => builder.append("\\t")
            case _ =>
                if (UInt32(r) < UInt32(32)) {
                    let code = UInt32(r)
                    builder.append("\\u")
                    builder.append(JSON_HEX[Int64(code >> 12)].toString())
                    builder.append(JSON_HEX[Int64((code >> 8) & 0xF)].toString())
                    builder.append(JSON_HEX[Int64((code >> 4) & 0xF)].toString())
                    builder.append(JSON_HEX[Int64(code & 0xF)].toString())
                } else {
                    builder.append(r)
                }
        }
    }
    builder.append("\"")
}

func writeIndent(builder: StringBuilder, depth: Int64, indent: String): Unit {
    for (_ in 0..depth) {
        builder.append(indent)
    }
}

func writeJsonValueCompact(writer: JsonDirectWriter, value: JsonNode): Unit {
    match (value) {
        case _: JsonNullValue => writer.writeRawNull()
        case boolValue: JsonBoolValue => writer.writeRawBool(boolValue.value)
        case intValue: JsonIntValue => writer.writeRawInt64(intValue.value)
        case floatValue: JsonFloatValue =>
            ensureFiniteJsonFloat(floatValue.value)
            writer.writeRawNumberValue(floatValue.value.toString())
        case numberValue: JsonNumberLiteralValue => writer.writeRawNumberValue(numberValue.literal)
        case stringValue: JsonStringValue => writer.writeRawString(stringValue.value)
        case arrayValue: JsonArrayValue => writeJsonArrayValueCompact(writer, arrayValue)
        case objectValue: JsonObjectValue => writeJsonObjectValueCompact(writer, objectValue)
        case _ => throw JsonException("Unsupported JsonNode implementation")
    }
}

func writeJsonArrayValueCompact(writer: JsonDirectWriter, arrayValue: JsonArrayValue): Unit {
    writer.writeRawBeginArray()
    var first = true
    for (item in arrayValue.values()) {
        if (!first) {
            writer.writeRawByte(b',')
        }
        writeJsonValueCompact(writer, item)
        first = false
    }
    writer.writeRawEndArray()
}

func writeJsonObjectValueCompact(writer: JsonDirectWriter, objectValue: JsonObjectValue): Unit {
    writer.writeRawBeginObject()
    var first = true
    for ((key, item) in objectValue.entries()) {
        first = writeJsonObjectEntryCompact(writer, first, key, item)
    }
    writer.writeRawEndObject()
}

func writeJsonObjectEntryCompact(writer: JsonDirectWriter, first: Bool, key: String, item: JsonNode): Bool {
    match (item) {
        case _: JsonNullValue => writer.writeRawObjectEntryNameNull(first, key)
        case boolValue: JsonBoolValue => writer.writeRawObjectEntryNameBool(first, key, boolValue.value)
        case intValue: JsonIntValue => writer.writeRawObjectEntryNameInt64(first, key, intValue.value)
        case floatValue: JsonFloatValue =>
            ensureFiniteJsonFloat(floatValue.value)
            writer.writeRawObjectEntryNameNumberValue(first, key, floatValue.value.toString())
        case numberValue: JsonNumberLiteralValue => writer.writeRawObjectEntryNameNumberValue(first, key,
            numberValue.literal)
        case stringValue: JsonStringValue => writer.writeRawObjectEntryNameString(first, key, stringValue.value)
        case _ =>
            let nextFirst = writer.writeRawObjectEntryName(first, key)
            writeJsonValueCompact(writer, item)
            nextFirst
    }
}

func writeJsonNodeToCodecWriter(writer: JsonCodecWriter, value: JsonNode): Unit {
    match (value) {
        case _: JsonNullValue => writer.writeNull()
        case boolValue: JsonBoolValue => writer.writeBool(boolValue.value)
        case intValue: JsonIntValue => writer.writeInt64(intValue.value)
        case floatValue: JsonFloatValue => writer.writeFloat64(floatValue.value)
        case numberValue: JsonNumberLiteralValue => writer.writeRawNumber(numberValue.literal)
        case stringValue: JsonStringValue => writer.writeString(stringValue.value)
        case arrayValue: JsonArrayValue =>
            writer.startArray()
            for (item in arrayValue.values()) {
                writeJsonNodeToCodecWriter(writer, item)
            }
            writer.endArray()
        case objectValue: JsonObjectValue =>
            writer.startObject()
            for ((key, item) in objectValue.entries()) {
                writer.writeName(key)
                writeJsonNodeToCodecWriter(writer, item)
            }
            writer.endObject()
        case _ => throw JsonException("Unsupported JsonNode implementation")
    }
}

func writeJsonValue(builder: StringBuilder, value: JsonNode, depth: Int64, pretty: Bool, indent: String): Unit {
    match (value) {
        case _: JsonNullValue => builder.append("null")
        case boolValue: JsonBoolValue => builder.append(boolValue.value.toString())
        case intValue: JsonIntValue => builder.append(intValue.value.toString())
        case floatValue: JsonFloatValue =>
            ensureFiniteJsonFloat(floatValue.value)
            builder.append(floatValue.value.toString())
        case numberValue: JsonNumberLiteralValue => builder.append(numberValue.literal)
        case stringValue: JsonStringValue => writeEscapedJsonString(builder, stringValue.value)
        case arrayValue: JsonArrayValue =>
            builder.append("[")
            if (arrayValue.size() != 0) {
                var first = true
                for (item in arrayValue.values()) {
                    if (!first) {
                        builder.append(",")
                    }
                    if (pretty) {
                        builder.append("\n")
                        writeIndent(builder, depth + 1, indent)
                    }
                    writeJsonValue(builder, item, depth + 1, pretty, indent)
                    first = false
                }
                if (pretty) {
                    builder.append("\n")
                    writeIndent(builder, depth, indent)
                }
            }
            builder.append("]")
        case objectValue: JsonObjectValue =>
            builder.append("{")
            if (objectValue.size() != 0) {
                var first = true
                for ((key, item) in objectValue.entries()) {
                    if (!first) {
                        builder.append(",")
                    }
                    if (pretty) {
                        builder.append("\n")
                        writeIndent(builder, depth + 1, indent)
                    }
                    writeEscapedJsonString(builder, key)
                    builder.append(if (pretty) {
                        ": "
                    } else {
                        ":"
                    })
                    writeJsonValue(builder, item, depth + 1, pretty, indent)
                    first = false
                }
                if (pretty) {
                    builder.append("\n")
                    writeIndent(builder, depth, indent)
                }
            }
            builder.append("}")
        case _ => throw JsonException("Unsupported JsonNode implementation")
    }
}
