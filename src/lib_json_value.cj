package yjson

import std.collection.*
import std.convert.Parsable

public enum JsonKind <: Equatable<JsonKind> {
    JsNull | JsBool | JsInt | JsFloat | JsNumberLiteral | JsString | JsArray | JsObject

    public operator func ==(other: JsonKind): Bool {
        match (this) {
            case JsNull => if (let JsNull <- other) { true } else { false }
            case JsBool => if (let JsBool <- other) { true } else { false }
            case JsInt => if (let JsInt <- other) { true } else { false }
            case JsFloat => if (let JsFloat <- other) { true } else { false }
            case JsNumberLiteral => if (let JsNumberLiteral <- other) { true } else { false }
            case JsString => if (let JsString <- other) { true } else { false }
            case JsArray => if (let JsArray <- other) { true } else { false }
            case JsObject => if (let JsObject <- other) { true } else { false }
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

public class JsonReadConfig {
    public let unknownFieldPolicy: JsonUnknownFieldPolicy
    public let duplicateKeyPolicy: JsonDuplicateKeyPolicy
    public let numberPolicy: JsonNumberPolicy
    public let includeErrorLocation: Bool
    public let maxDepth: Int64
    public let maxPolymorphicObjectBytes: Int64

    public init(
        unknownFieldPolicy!: JsonUnknownFieldPolicy = JsonUnknownFieldPolicy.Ignore,
        duplicateKeyPolicy!: JsonDuplicateKeyPolicy = JsonDuplicateKeyPolicy.LastWins,
        numberPolicy!: JsonNumberPolicy = JsonNumberPolicy.Int64WhenExact,
        includeErrorLocation!: Bool = true,
        maxDepth!: Int64 = 256,
        maxPolymorphicObjectBytes!: Int64 = 16 * 1024 * 1024
    ) {
        if (maxDepth <= 0) {
            throw IllegalArgumentException("maxDepth must be positive")
        }
        if (maxPolymorphicObjectBytes <= 0) {
            throw IllegalArgumentException("maxPolymorphicObjectBytes must be positive")
        }
        this.unknownFieldPolicy = unknownFieldPolicy
        this.duplicateKeyPolicy = duplicateKeyPolicy
        this.numberPolicy = numberPolicy
        this.includeErrorLocation = includeErrorLocation
        this.maxDepth = maxDepth
        this.maxPolymorphicObjectBytes = maxPolymorphicObjectBytes
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
    let unknownIsDefault = match (config.unknownFieldPolicy) {
        case Ignore => true
        case _ => false
    }
    let duplicateIsDefault = match (config.duplicateKeyPolicy) {
        case LastWins => true
        case _ => false
    }
    let numberIsDefault = match (config.numberPolicy) {
        case Int64WhenExact => true
        case _ => false
    }
    unknownIsDefault && duplicateIsDefault && numberIsDefault && config.includeErrorLocation &&
        config.maxDepth == 256 && config.maxPolymorphicObjectBytes == 16 * 1024 * 1024
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
    let limit = if (offset > data.size) { data.size } else { offset }
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
    let limit = if (offset > data.size) { data.size } else { offset }
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

public abstract class JsonValue <: ToString {
    public static func parse(text: String, config!: JsonReadConfig = JsonReadConfig.defaults): JsonValue {
        JsonParser(text, config: config).parse()
    }

    /// Parses raw UTF-8 JSON without first materializing the complete input as
    /// a String. String values and object keys are still materialized because
    /// they are part of the public JsonValue representation.
    public static func parse(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): JsonValue {
        parseJsonValueFromBytes(bytes, config: config)
    }

    public func kind(): JsonKind

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
}

public class JsonNullValue <: JsonValue {
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

public class JsonBoolValue <: JsonValue {
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

public class JsonIntValue <: JsonValue {
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

public class JsonFloatValue <: JsonValue {
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

public class JsonNumberLiteralValue <: JsonValue {
    public let literal: String

    public init(literal: String) {
        this.literal = literal
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

public class JsonStringValue <: JsonValue {
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

public class JsonArrayValue <: JsonValue {
    private let items: ArrayList<JsonValue>

    public init() {
        items = ArrayList<JsonValue>()
    }

    public init(items: ArrayList<JsonValue>) {
        this.items = items
    }

    public init(items: Array<JsonValue>) {
        this.items = ArrayList<JsonValue>(items)
    }

    public func kind(): JsonKind {
        JsArray
    }

    public func add(value: JsonValue): JsonArrayValue {
        items.add(value)
        this
    }

    public func size(): Int64 {
        items.size
    }

    public func values(): ArrayList<JsonValue> {
        items
    }

    public func get(index: Int64): Option<JsonValue> {
        items.get(index)
    }

    public operator func [](index: Int64): JsonValue {
        items[index]
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

public class JsonObjectValue <: JsonValue {
    private let fields: HashMap<String, JsonValue>

    public init() {
        fields = HashMap<String, JsonValue>()
    }

    public init(fields: HashMap<String, JsonValue>) {
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

    public func put(key: String, value: JsonValue): Unit {
        fields.add(key, value)
    }

    public func get(key: String): Option<JsonValue> {
        fields.get(key)
    }

    public func entries(): HashMap<String, JsonValue> {
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

func writeJsonValueCompact(writer: JsonDirectWriter, value: JsonValue): Unit {
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
        case _ => throw JsonException("Unsupported JsonValue implementation")
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

func writeJsonObjectEntryCompact(writer: JsonDirectWriter, first: Bool, key: String, item: JsonValue): Bool {
    match (item) {
        case _: JsonNullValue => writer.writeRawObjectEntryNameNull(first, key)
        case boolValue: JsonBoolValue => writer.writeRawObjectEntryNameBool(first, key, boolValue.value)
        case intValue: JsonIntValue => writer.writeRawObjectEntryNameInt64(first, key, intValue.value)
        case floatValue: JsonFloatValue =>
            ensureFiniteJsonFloat(floatValue.value)
            writer.writeRawObjectEntryNameNumberValue(first, key, floatValue.value.toString())
        case numberValue: JsonNumberLiteralValue => writer.writeRawObjectEntryNameNumberValue(first, key, numberValue.literal)
        case stringValue: JsonStringValue => writer.writeRawObjectEntryNameString(first, key, stringValue.value)
        case _ =>
            let nextFirst = writer.writeRawObjectEntryName(first, key)
            writeJsonValueCompact(writer, item)
            nextFirst
    }
}

func writeJsonValueDirect(writer: JsonDirectWriter, value: JsonValue): Unit {
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
                writeJsonValueDirect(writer, item)
            }
            writer.endArray()
        case objectValue: JsonObjectValue =>
            writer.startObject()
            for ((key, item) in objectValue.entries()) {
                writer.writeName(key)
                writeJsonValueDirect(writer, item)
            }
            writer.endObject()
        case _ => throw JsonException("Unsupported JsonValue implementation")
    }
}

func writeJsonValue(builder: StringBuilder, value: JsonValue, depth: Int64, pretty: Bool, indent: String): Unit {
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
                    builder.append(if (pretty) { ": " } else { ":" })
                    writeJsonValue(builder, item, depth + 1, pretty, indent)
                    first = false
                }
                if (pretty) {
                    builder.append("\n")
                    writeIndent(builder, depth, indent)
                }
            }
            builder.append("}")
        case _ => throw JsonException("Unsupported JsonValue implementation")
    }
}
