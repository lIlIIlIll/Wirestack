package yjson

import std.collection.*
import std.convert.Parsable
import std.deriving.Derive
import std.io.*

@Derive[Equatable]
public enum JsonKind {
    Null | Boolean | Number | String | Array | Object
}

/**
 * Source position attached to a JSON failure.
 *
 * byteOffset is zero-based and measured in UTF-8 bytes. line and column are one-based. Use the reported error position rather than reconstructing it from a string index.
 */
public struct JsonLocation {
    /**
     * Zero-based UTF-8 byte offset of the reported position.
     */
    public let byteOffset: Int64
    /**
     * One-based source line of the reported position.
     */
    public let line: Int64
    /**
     * One-based source column of the reported position.
     */
    public let column: Int64

    /**
     * Creates JsonLocation with the supplied values.
     *
     * @param byteOffset Zero-based UTF-8 byte offset; must not be negative.
     * @param line One-based source line; must be positive.
     * @param column One-based source column; must be positive.
     * @throws IllegalArgumentException The byte offset is negative, or line or column is nonpositive.
     */
    public init(byteOffset: Int64, line: Int64, column: Int64) {
        if (byteOffset < 0) { throw IllegalArgumentException("byteOffset must not be negative") }
        if (line <= 0) { throw IllegalArgumentException("line must be positive") }
        if (column <= 0) { throw IllegalArgumentException("column must be positive") }
        this.byteOffset = byteOffset
        this.line = line
        this.column = column
    }
}

/**
 * Exception carrying a JSON failure code, path, and optional source position.
 *
 * Use code for programmatic error handling. path is an RFC 6901 JSON Pointer; the empty string denotes the root. Message text is descriptive, not a compatibility contract. I/O failures and custom-codec exceptions are not necessarily wrapped in this type.
 */
public open class JsonException <: Exception {
    /**
     * Machine-readable category for programmatic error handling.
     */
    public let code: String
    /**
     * JSON Pointer for the failing value; the empty string denotes the root.
     */
    public let path: String
    /**
     * Source position when known; None when no position is available.
     */
    public let location: Option<JsonLocation>

    /**
     * Creates JsonException with the supplied values.
     *
     * @param message Human-readable diagnostic message; do not parse it for error handling.
     * @param code Machine-readable error code; defaults to json_error.
     * @param path JSON Pointer identifying the failing value; the empty string denotes the root.
     * @param location Source position when available; None when no position is known.
     * @throws IllegalArgumentException A nonempty path does not begin with a slash.
     */
    public init(
        message: String,
        code!: String = "json_error",
        path!: String = "",
        location!: Option<JsonLocation> = None<JsonLocation>
    ) {
        super(message)
        validateJsonExceptionPath(path)
        this.code = code
        this.path = path
        this.location = location
    }

    /**
     * Creates JsonException with the supplied values.
     *
     * @param message Human-readable diagnostic message; do not parse it for error handling.
     * @param causedBy Original exception to retain as the cause.
     * @param code Machine-readable error code; defaults to json_error.
     * @param path JSON Pointer identifying the failing value; the empty string denotes the root.
     * @param location Source position when available; None when no position is known.
     * @throws IllegalArgumentException A nonempty path does not begin with a slash.
     */
    public init(
        message: String,
        causedBy: Exception,
        code!: String = "json_error",
        path!: String = "",
        location!: Option<JsonLocation> = None<JsonLocation>
    ) {
        super(message, causedBy)
        validateJsonExceptionPath(path)
        this.code = code
        this.path = path
        this.location = location
    }

    protected open override func getClassName(): String {
        "JsonException"
    }
}

private func validateJsonExceptionPath(path: String): Unit {
    if (!path.isEmpty() && !path.startsWith("/")) {
        throw IllegalArgumentException("JSON error path must be an RFC 6901 JSON Pointer")
    }
}

/**
 * Policy for object fields not recognized by a typed codec.
 *
 * Ignore is the default; Reject requests an unknown-field error.
 */
public enum JsonUnknownFieldPolicy {
    Ignore | Reject
}

/**
 * Policy for duplicate member names within a JSON object.
 *
 * Reject is the default. LastWins explicitly selects the last occurrence.
 */
public enum JsonDuplicateKeyPolicy {
    LastWins | Reject
}

/**
 * Immutable parsing and typed-decoding policies with bounded resource use.
 *
 * Defaults ignore unknown typed fields, reject duplicate object keys, and allow 64 MiB input, 16 MiB strings, 8 MiB captured-value buffers, and 256 nesting levels. All read budgets must be positive; zero does not mean unlimited.
 */
public class JsonReadOptions {
    /**
     * Policy for unknown object fields encountered during typed decoding.
     */
    public let unknownFieldPolicy: JsonUnknownFieldPolicy
    /**
     * Policy for repeated member names in a JSON object.
     */
    public let duplicateKeyPolicy: JsonDuplicateKeyPolicy
    /**
     * Maximum input size in bytes; must be positive.
     */
    public let maxInputBytes: Int64
    /**
     * Maximum JSON string size in bytes; must be positive.
     */
    public let maxStringBytes: Int64
    /**
     * Maximum captured-value buffer size in bytes; must be positive.
     */
    public let maxBufferedValueBytes: Int64
    /**
     * Maximum permitted nesting depth; must be positive.
     */
    public let maxDepth: Int64
    let defaultFastPath: Bool

    /**
     * Creates JsonReadOptions with the supplied values.
     *
     * @param unknownFieldPolicy Whether typed decoding ignores or rejects unknown object fields.
     * @param duplicateKeyPolicy Whether duplicate object keys are rejected or the last value wins.
     * @param maxInputBytes Positive input byte limit; defaults to 64 MiB.
     * @param maxStringBytes Positive string byte limit; defaults to 16 MiB.
     * @param maxBufferedValueBytes Positive captured-value buffer limit; defaults to 8 MiB.
     * @param maxDepth Positive nesting-depth limit; defaults to 256.
     * @throws IllegalArgumentException A read budget is zero or negative.
     */
    public init(
        unknownFieldPolicy!: JsonUnknownFieldPolicy = JsonUnknownFieldPolicy.Ignore,
        duplicateKeyPolicy!: JsonDuplicateKeyPolicy = JsonDuplicateKeyPolicy.Reject,
        maxInputBytes!: Int64 = 64 * 1024 * 1024,
        maxStringBytes!: Int64 = 16 * 1024 * 1024,
        maxBufferedValueBytes!: Int64 = 8 * 1024 * 1024,
        maxDepth!: Int64 = 256
    ) {
        if (maxDepth <= 0) { throw IllegalArgumentException("maxDepth must be positive") }
        if (maxInputBytes <= 0) { throw IllegalArgumentException("maxInputBytes must be positive") }
        if (maxStringBytes <= 0) { throw IllegalArgumentException("maxStringBytes must be positive") }
        if (maxBufferedValueBytes <= 0) { throw IllegalArgumentException("maxBufferedValueBytes must be positive") }
        this.unknownFieldPolicy = unknownFieldPolicy
        this.duplicateKeyPolicy = duplicateKeyPolicy
        this.maxInputBytes = maxInputBytes
        this.maxStringBytes = maxStringBytes
        this.maxBufferedValueBytes = maxBufferedValueBytes
        this.maxDepth = maxDepth
        let unknownIsDefault = match (unknownFieldPolicy) {
            case Ignore => true
            case _ => false
        }
        let duplicateIsDefault = match (duplicateKeyPolicy) {
            case Reject => true
            case _ => false
        }
        this.defaultFastPath = unknownIsDefault && duplicateIsDefault && maxDepth == 256 &&
            maxInputBytes == 64 * 1024 * 1024 && maxStringBytes == 16 * 1024 * 1024 &&
            maxBufferedValueBytes == 8 * 1024 * 1024
    }

    /**
     * Shared immutable default configuration.
     */
    public static let defaults: JsonReadOptions = JsonReadOptions()

    /**
     * Reports whether unknown typed fields are rejected.
     *
     * @return True when the corresponding policy is Reject.
     */
    public func rejectsUnknownFields(): Bool {
        match (unknownFieldPolicy) {
            case Reject => true
            case _ => false
        }
    }

    /**
     * Reports whether duplicate keys are rejected.
     *
     * @return True when the corresponding policy is Reject.
     */
    public func rejectsDuplicateKeys(): Bool {
        match (duplicateKeyPolicy) {
            case Reject => true
            case _ => false
        }
    }
}

func jsonReadOptionsUsesDefaultFastPath(options: JsonReadOptions): Bool {
    options.defaultFastPath
}

func jsonReadOptionsRejectsUnknownFields(options: JsonReadOptions): Bool {
    match (options.unknownFieldPolicy) {
        case Reject => true
        case _ => false
    }
}

func jsonReadOptionsRejectsDuplicateKeys(options: JsonReadOptions): Bool {
    match (options.duplicateKeyPolicy) {
        case Reject => true
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

/**
 * Read-only access to a JSON value, independent of its storage representation.
 *
 * Read-only access does not make a mutable JsonNode immutable or thread-safe. Managed document views retain their storage; resource-backed views remain subject to their owning backend document's lifetime. Use materialize for a detached mutable copy.
 */
public interface JsonValueView {
    func kind(): JsonKind
    func size(): Int64
    func element(index: Int64): Option<JsonValueView>
    func member(name: String): Option<JsonValueView>
    func memberName(index: Int64): String
    func memberValue(index: Int64): JsonValueView
    func asBool(): Bool
    func asString(): String
    func asInt64(): Int64
    func asUInt64(): UInt64
    func asFloat64(): Float64
    func asNumberText(): String
    func materialize(): JsonNode
    func materialize(maxNodes: Int64): JsonNode
}

/**
 * Base type for GC-managed JSON tree nodes.
 *
 * Arrays and objects can be modified. Parsing and writing honor their read and write options. deepCopy and materialize create detached trees rather than sharing mutable children. A JsonValueView of a mutable node does not provide a frozen snapshot.
 */
public abstract class JsonNode <: ToString & JsonValueView {
    public static prop nullValue: JsonNode {
        get() {
            freezeYJsonRuntime()
            JsonNullValue()
        }
    }
    public static func boolean(value: Bool): JsonNode { JsonBoolValue(value) }
    public static func int64(value: Int64): JsonNode { JsonIntValue(value) }
    public static func uint64(value: UInt64): JsonNode { JsonUIntValue(value) }
    public static func float64(value: Float64): JsonNode { JsonFloatValue(value) }
    public static func number(text: String): JsonNode { JsonNumberLiteralValue(text) }
    public static func string(value: String): JsonNode { JsonStringValue(value) }
    public static func array(): JsonArray { JsonArray() }
    public static func array(items: Array<JsonNode>): JsonArray { JsonArray(items) }
    public static func object(): JsonObject { JsonObject() }

    /**
     * Parses exactly one JSON document into a mutable tree.
     *
     * @param text One complete JSON document as a string.
     * @param config Parsing policies and positive resource limits for this document.
     * @return Parsed JSON node.
     */
    public static func parse(text: String, config!: JsonReadOptions = JsonReadOptions.defaults): JsonNode {
        JsonParser(text, config: config).parse()
    }

    /**
     * Parses exactly one JSON document into a mutable tree.
     *
     * @param bytes One complete JSON document encoded as UTF-8 bytes.
     * @param config Parsing policies and positive resource limits for this document.
     * @return Parsed JSON node.
     */
    public static func parse(bytes: Array<Byte>, config!: JsonReadOptions = JsonReadOptions.defaults): JsonNode {
        parseJsonValueFromBytes(bytes, config: config)
    }

    /**
     * Serializes this node as JSON text.
     *
     * @param options Read or write policies and resource limits for this call.
     * @return JSON text.
     */
    public func toJson(options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        freezeYJsonRuntime()
        writeJsonValueToString(this, options)
    }

    /**
     * Serializes this node to a caller-owned output stream.
     *
     * The stream is not closed. A failure may leave an already-written prefix.
     *
     * @param output Caller-owned output stream. This operation does not close it.
     * @param options Read or write policies and resource limits for this call.
     */
    public func writeJson(output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        freezeYJsonRuntime()
        writeJsonValueToStream(this, output, options)
    }

    public func kind(): JsonKind
    public func size(): Int64

    /**
     * Creates a detached mutable copy of this tree.
     *
     * The operation is bounded to 256 levels and, unless maxNodes is supplied, 100,000 visited nodes.
     *
     * @return Detached tree.
     */
    public func deepCopy(): JsonNode {
        deepCopyJsonNode(this)
    }

    /**
     * Creates a detached mutable copy of this tree.
     *
     * The operation is bounded to 256 levels and, unless maxNodes is supplied, 100,000 visited nodes.
     *
     * @return Detached tree.
     */
    public func materialize(): JsonNode { deepCopyJsonNode(this) }

    /**
     * Creates a detached mutable copy of this tree.
     *
     * The operation is bounded to 256 levels and, unless maxNodes is supplied, 100,000 visited nodes.
     *
     * @param maxNodes Positive maximum number of nodes to copy.
     * @return Detached tree.
     */
    public func materialize(maxNodes: Int64): JsonNode {
        deepCopyJsonNode(this, maxNodes)
    }

    /**
     * Compares JSON data-model equality, including numeric equality across different number spellings.
     *
     * The operation is bounded to 256 levels and, unless maxNodes is supplied, 100,000 visited nodes.
     *
     * @param other Tree to compare using JSON data-model equality.
     * @return Whether the two trees are equivalent.
     */
    public func equivalentTo(other: JsonNode): Bool {
        jsonNodesEquivalent(this, other)
    }

    public func toPrettyString(): String {
        toPrettyString("  ")
    }

    public func toPrettyString(indent: String): String

    public func asBool(): Bool {
        match (this) {
            case value: JsonBoolValue => value.value
            case _ => throw JsonException("Expected boolean value", code: "type_mismatch")
        }
    }

    public func asInt64(): Int64 {
        match (this) {
            case value: JsonIntValue => value.value
            case value: JsonUIntValue =>
                if (value.value > UInt64(Int64.Max)) {
                    throw JsonException("JSON number is outside Int64 range", code: "number_out_of_range")
                }
                Int64(value.value)
            case value: JsonNumberLiteralValue =>
                try { Int64.parse(value.literal) } catch (_: Exception) {
                    throw JsonException("Expected an exact Int64 value", code: "number_out_of_range")
                }
            case _ => throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asUInt64(): UInt64 {
        match (this) {
            case value: JsonUIntValue => value.value
            case value: JsonIntValue =>
                if (value.value < 0) {
                    throw JsonException("JSON number is outside UInt64 range", code: "number_out_of_range")
                }
                UInt64(value.value)
            case value: JsonNumberLiteralValue =>
                try { UInt64.parse(value.literal) } catch (_: Exception) {
                    throw JsonException("Expected an exact UInt64 value", code: "number_out_of_range")
                }
            case _ => throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asFloat64(): Float64 {
        match (this) {
            case value: JsonFloatValue => value.value
            case value: JsonIntValue => Float64(value.value)
            case value: JsonUIntValue => Float64(value.value)
            case value: JsonNumberLiteralValue => Float64.parse(value.literal)
            case _ => throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asNumberText(): String {
        match (this) {
            case value: JsonIntValue => value.value.toString()
            case value: JsonUIntValue => value.value.toString()
            case value: JsonFloatValue => ensureFiniteJsonFloat(value.value); value.value.toString()
            case value: JsonNumberLiteralValue => value.literal
            case _ => throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asString(): String {
        match (this) {
            case value: JsonStringValue => value.value
            case _ => throw JsonException("Expected string value", code: "type_mismatch")
        }
    }

    public func asArray(): JsonArray {
        match (this) {
            case value: JsonArray => value
            case _ => throw JsonException("Expected array value", code: "type_mismatch")
        }
    }

    public func asObject(): JsonObject {
        match (this) {
            case value: JsonObject => value
            case _ => throw JsonException("Expected object value", code: "type_mismatch")
        }
    }

    public func element(index: Int64): Option<JsonValueView> {
        match (asArray().get(index)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func member(name: String): Option<JsonValueView> {
        match (asObject().get(name)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func memberName(index: Int64): String { asObject().nameAt(index) }
    public func memberValue(index: Int64): JsonValueView { asObject().valueAt(index) }

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
        asObject().put(key, jsonNodeValue(value))
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
        asArray().set(index, jsonNodeValue(value))
    }
}

func jsonNodeValue(value: JsonNode): JsonNode { value }
func jsonNodeValue(value: Bool): JsonNode { JsonBoolValue(value) }
func jsonNodeValue(value: Int64): JsonNode { JsonIntValue(value) }
func jsonNodeValue(value: UInt64): JsonNode { JsonUIntValue(value) }
func jsonNodeValue(value: Float64): JsonNode { JsonFloatValue(value) }
func jsonNodeValue(value: Rune): JsonNode { JsonStringValue(value.toString()) }
func jsonNodeValue(value: String): JsonNode { JsonStringValue(value) }
func jsonNodeValue(value: Array<JsonNode>): JsonNode { JsonArray(value) }
func jsonNodeValue<T>(value: T): JsonNode where T <: GeneratedCodecProviderV1<T> {
    JsonNode.parse(YJson.toJson(value))
}

class JsonNullValue <: JsonNode {
    public func kind(): JsonKind {
        JsonKind.Null
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        "null"
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

class JsonBoolValue <: JsonNode {
    public let value: Bool

    public init(value: Bool) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsonKind.Boolean
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

class JsonIntValue <: JsonNode {
    public let value: Int64

    public init(value: Int64) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsonKind.Number
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

class JsonUIntValue <: JsonNode {
    public let value: UInt64

    public init(value: UInt64) {
        this.value = value
    }

    public func kind(): JsonKind { JsonKind.Number }
    public func size(): Int64 { 0 }
    public func toString(): String { value.toString() }
    public func toPrettyString(indent: String): String { let _ = indent; toString() }
}

class JsonFloatValue <: JsonNode {
    public let value: Float64

    public init(value: Float64) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsonKind.Number
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        ensureFiniteJsonFloat(value)
        value.toString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

class JsonNumberLiteralValue <: JsonNode {
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
        JsonKind.Number
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        literal
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        literal
    }
}

func isValidJsonNumberLiteral(literal: String): Bool {
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

class JsonStringValue <: JsonNode {
    public let value: String

    public init(value: String) {
        this.value = value
    }

    public func kind(): JsonKind {
        JsonKind.String
    }

    public func size(): Int64 { 0 }

    public func toString(): String {
        let writer = JsonDirectWriter()
        writer.writeString(value)
        writer.finishString()
    }

    public func toPrettyString(indent: String): String {
        let _ = indent
        toString()
    }
}

public class JsonArray <: JsonNode {
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
        JsonKind.Array
    }

    public func add(value: JsonNode): JsonArray {
        items.add(value)
        this
    }

    public func add<T>(value: T): JsonArray where T <: GeneratedCodecProviderV1<T> {
        add(jsonNodeValue(value))
    }

    public func set(index: Int64, value: JsonNode): JsonArray {
        if (index < 0 || index >= items.size) {
            throw JsonException("Array index ${index} is out of bounds", code: "index_out_of_bounds")
        }
        items[index] = value
        this
    }

    public func set<T>(index: Int64, value: T): JsonArray where T <: GeneratedCodecProviderV1<T> {
        set(index, jsonNodeValue(value))
    }

    public func insert(index: Int64, value: JsonNode): JsonArray {
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

    func values(): ArrayList<JsonNode> {
        items
    }

    public func get(index: Int64): Option<JsonNode> {
        items.get(index)
    }

    public func toString(): String {
        freezeYJsonRuntime()
        writeJsonValueToString(this, JsonWriteOptions.compact)
    }

    public func toPrettyString(indent: String): String {
        freezeYJsonRuntime()
        writeJsonValueToString(this, JsonWriteOptions.pretty(indent: indent))
    }
}

public class JsonObject <: JsonNode {
    private let fields: HashMap<String, JsonNode>
    private let names: ArrayList<String>

    public init() {
        fields = HashMap<String, JsonNode>()
        names = ArrayList<String>()
    }

    public init(fields: HashMap<String, JsonNode>) {
        this.fields = HashMap<String, JsonNode>()
        names = ArrayList<String>()
        for ((name, value) in fields) { put(name, value) }
    }

    public func kind(): JsonKind {
        JsonKind.Object
    }

    public func size(): Int64 {
        fields.size
    }

    public func contains(key: String): Bool {
        fields.contains(key)
    }

    public func put(key: String, value: JsonNode): JsonObject {
        if (!fields.contains(key)) { names.add(key) }
        fields.add(key, value)
        this
    }

    public func put<T>(key: String, value: T): JsonObject where T <: GeneratedCodecProviderV1<T> {
        put(key, jsonNodeValue(value))
    }

    public func get(key: String): Option<JsonNode> {
        fields.get(key)
    }

    public func remove(key: String): Option<JsonNode> {
        let removed = fields.remove(key)
        if (removed.isSome()) {
            for (index in 0..names.size) {
                if (names[index] == key) { names.remove(at: index); break }
            }
        }
        removed
    }

    public func nameAt(index: Int64): String {
        names.get(index).getOrThrow({ =>
            JsonException("Object member index ${index} is out of bounds", code: "index_out_of_bounds")
        })
    }

    public func valueAt(index: Int64): JsonNode {
        fields.get(nameAt(index)).getOrThrow({ =>
            JsonException("Object member index ${index} is out of bounds", code: "index_out_of_bounds")
        })
    }

    func entries(): HashMap<String, JsonNode> {
        fields
    }

    public func toString(): String {
        freezeYJsonRuntime()
        writeJsonValueToString(this, JsonWriteOptions.compact)
    }

    public func toPrettyString(indent: String): String {
        freezeYJsonRuntime()
        writeJsonValueToString(this, JsonWriteOptions.pretty(indent: indent))
    }
}


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


func writeJsonNodeToCodecWriter(writer: JsonWriter, value: JsonNode): Unit {
    writeJsonNodeToCodecWriterGuarded(writer, value, ArrayList<JsonNode>())
}

private func writeJsonNodeToCodecWriterGuarded(
    writer: JsonWriter,
    value: JsonNode,
    ancestors: ArrayList<JsonNode>
): Unit {
    match (value) {
        case _: JsonNullValue => writer.writeNull()
        case boolValue: JsonBoolValue => writer.writeBool(boolValue.value)
        case intValue: JsonIntValue => writer.writeInt64(intValue.value)
        case uintValue: JsonUIntValue => writer.writeUInt64(uintValue.value)
        case floatValue: JsonFloatValue => writer.writeFloat64(floatValue.value)
        case numberValue: JsonNumberLiteralValue => writer.writeNumberLiteral(numberValue.literal)
        case stringValue: JsonStringValue => writer.writeString(stringValue.value)
        case arrayValue: JsonArray =>
            enterJsonNodeAncestor(arrayValue, ancestors)
            writer.startArray()
            try {
                for (item in arrayValue.values()) {
                    writeJsonNodeToCodecWriterGuarded(writer, item, ancestors)
                }
                writer.endArray()
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
        case objectValue: JsonObject =>
            enterJsonNodeAncestor(objectValue, ancestors)
            writer.startObject()
            try {
                for (index in 0..objectValue.size()) {
                    writer.writeName(objectValue.nameAt(index))
                    writeJsonNodeToCodecWriterGuarded(writer, objectValue.valueAt(index), ancestors)
                }
                writer.endObject()
            } finally {
                ancestors.remove(at: ancestors.size - 1)
            }
        case _ => throw JsonException("Unsupported JsonNode implementation")
    }
}

func enterJsonNodeAncestor(value: JsonNode, ancestors: ArrayList<JsonNode>): Unit {
    ensureJsonNodeNotAncestor(value, ancestors)
    ancestors.add(value)
}

func ensureJsonNodeNotAncestor(value: JsonNode, ancestors: ArrayList<JsonNode>): Unit {
    for (ancestor in ancestors) {
        if (refEq(value, ancestor)) {
            throw JsonException("Cyclic JsonNode graph is not supported", code: "cyclic_json_node")
        }
    }
}
