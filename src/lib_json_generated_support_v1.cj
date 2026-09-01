package yjson

import std.collection.*
import std.math.numeric.*

/// Narrow semantic reader contract consumed by generated codecs. Implementors
/// remain runtime-owned; generated source never names a concrete parser class.
public interface GeneratedSupportV1Reader {
    func expectEnd(): Unit
    func startRawObject(): Unit
    func endRawObject(): Unit
    func hasRawObjectField(first: Bool): Bool
    func readRawName(first: Bool): String
    func readRawNameIdBytes(first: Bool, candidates: Array<Array<Byte>>): Int64
    func tryReadRawCompactNameTokenBytes(first: Bool, nameBytes: Array<Byte>): Bool

    func startRawArray(): Unit
    func endRawArray(): Unit
    func hasRawArrayItem(first: Bool): Bool
    func beforeRawArrayItem(first: Bool): Unit
    func suggestRawCollectionCapacity(): Int64
    func suggestRawArrayCapacity(): Int64
    func suggestRawObjectCapacity(): Int64

    func tryReadRawNull(): Bool
    func readRawBool(): Bool
    func readRawString(): String
    func readRawInt64(): Int64
    func readRawInt32(): Int32
    func readRawInt16(): Int16
    func readRawInt8(): Int8
    func readRawUInt64(): UInt64
    func readRawUInt32(): UInt32
    func readRawUInt16(): UInt16
    func readRawUInt8(): UInt8
    func skipRawWithDepth(maxDepth: Int64): Unit
}


/// Narrow semantic writer contract consumed by generated codecs. Structural
/// correctness remains owned by the core writer state machine.
public interface GeneratedSupportV1Writer <: JsonWriter & GeneratedBulkWriterV1 {
    func finishString(): String
    func generatedCursorV1(): GeneratedSupportV1WriteCursor
    func tryBeginGeneratedCompactRawValue(): Bool
    func writeRawBeginObject(): Unit
    func writeRawEndObject(): Unit
    func writeRawBeginArray(): Unit
    func writeRawEndArray(): Unit
    func writeRawByte(value: Byte): Unit
    func writeRawNull(): Unit
    func writeRawObjectEntryName(first: Bool, value: String): Bool
    func writeRawObjectEntryNameString(first: Bool, name: String, value: String): Bool
    func writeRawObjectEntryNameBool(first: Bool, name: String, value: Bool): Bool
    func writeRawObjectEntryNameInt64(first: Bool, name: String, value: Int64): Bool
}

/// Versioned, allocation-free view used after the runtime writer has been
/// resolved once. Generated source only depends on generated_support.v1 while
/// field loops avoid repeated interface dispatch.
public struct GeneratedSupportV1WriteCursor {
    private let writer: JsonDirectWriter

    init(writer: JsonDirectWriter) { this.writer = writer }


    public func writeRawBeginObject(): Unit { writer.writeRawBeginObject() }
    public func writeRawEndObject(): Unit { writer.writeRawEndObject() }
    public func writeRawBeginArray(): Unit { writer.writeRawBeginArray() }
    public func writeRawEndArray(): Unit { writer.writeRawEndArray() }
    public func writeRawByte(value: Byte): Unit { writer.writeRawByte(value) }
    public func reserveRawCollectionCapacity(count: Int64): Unit {
        writer.reserveRawCollectionCapacity(count)
    }
    public func writeRawObjectEntryName(first: Bool, value: String): Bool {
        writer.writeRawObjectEntryName(first, value)
    }
    public func writeRawObjectEntryNameString(first: Bool, name: String, value: String): Bool {
        writer.writeRawObjectEntryNameString(first, name, value)
    }
    public func writeRawObjectEntryNameBool(first: Bool, name: String, value: Bool): Bool {
        writer.writeRawObjectEntryNameBool(first, name, value)
    }
    public func writeRawObjectEntryNameInt64(first: Bool, name: String, value: Int64): Bool {
        writer.writeRawObjectEntryNameInt64(first, name, value)
    }
}

private class FastSemanticReadContext {
    let objectContext: Bool
    var first = true
    var expectingValue = false

    init(objectContext: Bool) {
        this.objectContext = objectContext
    }
}

// Ordinary/custom codecs reached from a generated fast path keep consuming
// the same runtime-owned cursor. This adapter is internal: it preserves the
// public generated_support.v1 surface while allowing nested capabilities to
// fall back without copying or reparsing the current JSON value.
class FastSemanticReaderAdapter <: JsonReader & GeneratedReadStateV1Owner {
    private let reader: JsonFastReader
    private let contexts = ArrayList<FastSemanticReadContext>()
    private var valuePrefixReady = false

    init(reader: JsonFastReader) {
        this.reader = reader
    }

    public func generatedReadStateV1(): GeneratedReadStateV1 {
        reader.generatedReadStateV1()
    }

    func readConfig(): JsonReadOptions { JsonReadOptions.defaults }

    public func path(): String { generatedReadStateV1().currentPath() }
    public func location(): Option<JsonLocation> { reader.semanticLocation() }
    public func error(message: String, code: String): JsonException {
        reader.semanticError(message, code)
    }

    private func beforeValue(): Unit {
        if (valuePrefixReady) {
            valuePrefixReady = false
            return
        }
        if (contexts.isEmpty()) { return }
        let context = contexts[contexts.size - 1]
        if (context.objectContext) {
            if (!context.expectingValue) {
                throw error("Expected an object field name", "parse_error")
            }
            context.expectingValue = false
        } else {
            reader.beforeRawArrayItem(context.first)
            context.first = false
        }
    }

    public func startObject(): Unit {
        beforeValue()
        reader.startRawObject()
        contexts.add(FastSemanticReadContext(true))
    }

    public func endObject(): Unit {
        if (contexts.isEmpty() || !contexts[contexts.size - 1].objectContext) {
            throw error("Not reading an object", "parse_error")
        }
        if (contexts[contexts.size - 1].expectingValue) {
            throw error("Expected object field value", "parse_error")
        }
        reader.endRawObject()
        contexts.remove(at: contexts.size - 1)
    }

    public func hasObjectField(): Bool {
        if (contexts.isEmpty() || !contexts[contexts.size - 1].objectContext) {
            throw error("Not reading an object", "parse_error")
        }
        let context = contexts[contexts.size - 1]
        if (context.expectingValue) {
            throw error("Expected object field value", "parse_error")
        }
        reader.hasRawObjectField(context.first)
    }

    public func readName(): String {
        if (contexts.isEmpty() || !contexts[contexts.size - 1].objectContext) {
            throw error("Not reading an object", "parse_error")
        }
        let context = contexts[contexts.size - 1]
        if (context.expectingValue) {
            throw error("Expected object field value", "parse_error")
        }
        let name = reader.readRawName(context.first)
        context.first = false
        context.expectingValue = true
        name
    }

    public func startArray(): Unit {
        beforeValue()
        reader.startRawArray()
        contexts.add(FastSemanticReadContext(false))
    }

    public func endArray(): Unit {
        if (contexts.isEmpty() || contexts[contexts.size - 1].objectContext) {
            throw error("Not reading an array", "parse_error")
        }
        reader.endRawArray()
        contexts.remove(at: contexts.size - 1)
    }

    public func hasArrayItem(): Bool {
        if (contexts.isEmpty() || contexts[contexts.size - 1].objectContext) {
            throw error("Not reading an array", "parse_error")
        }
        let context = contexts[contexts.size - 1]
        reader.hasRawArrayItem(context.first)
    }

    public func tryReadNull(): Bool {
        beforeValue()
        if (reader.tryReadRawNull()) { return true }
        valuePrefixReady = true
        false
    }

    public func readNull(): Unit {
        beforeValue()
        if (!reader.tryReadRawNull()) {
            throw error("Expected null", "parse_error")
        }
    }

    public func readBool(): Bool { beforeValue(); reader.readRawBool() }
    public func readString(): String { beforeValue(); reader.readRawString() }
    public func readInt64(): Int64 { beforeValue(); reader.readRawInt64() }
    public func readUInt64(): UInt64 { beforeValue(); reader.readRawUInt64() }
    public func readFloat64(): Float64 { beforeValue(); jsonFastReadFloat64(reader) }
    public func readBigInt(): BigInt { beforeValue(); reader.readRawBigInt() }
    public func readDecimal(): Decimal { beforeValue(); reader.readRawDecimal() }
    public func readNumberLiteral(): String { beforeValue(); reader.readRawNumberLiteral() }

    public func skipValue(): Unit {
        beforeValue()
        reader.skipRawWithDepth(generatedReadStateV1().remainingDepth())
    }

    public func readNode(): JsonNode {
        match (reader.peekRawKind()) {
            case JsonKind.Null => readNull(); JsonNullValue()
            case JsonKind.Boolean => JsonBoolValue(readBool())
            case JsonKind.String => JsonStringValue(readString())
            case JsonKind.Number => JsonNumberLiteralValue.fromParsedLiteral(readNumberLiteral())
            case JsonKind.Array =>
                let items = ArrayList<JsonNode>()
                startArray()
                while (hasArrayItem()) { items.add(readNode()) }
                endArray()
                JsonArray(items)
            case JsonKind.Object =>
                let fields = HashMap<String, JsonNode>()
                startObject()
                while (hasObjectField()) {
                    let name = readName()
                    fields[name] = readNode()
                }
                endObject()
                JsonObject(fields)
        }
    }

    func readReplayValue(maxBytes: Int64): GeneratedReplayValueV1 {
        if (maxBytes < 0) { throw IllegalArgumentException("maxBytes must not be negative") }
        let start = reader.position()
        let value = readNode()
        if (maxBytes > 0 && reader.position() - start > maxBytes) {
            throw JsonException("Polymorphic JSON object exceeds ${maxBytes} bytes",
                code: "buffered_value_too_large", path: path(), location: location())
        }
        JsonNodeReplayValue(value, readConfig())
    }

    func expectEnd(): Unit { reader.expectEnd() }
}

public class GeneratedSupportV1 {
    public static func protocolVersion(): Int64 { yJsonGeneratedProtocolVersion() }

    public static func requireProtocolVersion(expected: Int64): Unit {
        let actual = protocolVersion()
        if (actual != expected) {
            throw JsonException(
                "Generated codec protocol mismatch: expected ${expected}, runtime provides ${actual}",
                code: "generated_protocol_mismatch", path: "")
        }
    }

    public static func newFastReader(text: String): GeneratedSupportV1Reader {
        freezeYJsonRuntime()
        JsonFastReader(text)
    }
    public static func newFastReader(bytes: Array<Byte>): GeneratedSupportV1Reader {
        freezeYJsonRuntime()
        JsonFastReader(bytes)
    }
    public static func newWriter(): GeneratedSupportV1Writer {
        freezeYJsonRuntime()
        JsonDirectWriter()
    }
    public static func writeCursor(writer: GeneratedSupportV1Writer): GeneratedSupportV1WriteCursor {
        writer.generatedCursorV1()
    }

    public static func writeState(writer: JsonWriter): GeneratedWriteStateV1 {
        match (writer) {
            case owner: GeneratedWriteStateV1Owner => owner.generatedWriteStateV1()
            case _ => throw JsonException(
                "JsonWriter is not owned by the yjson runtime",
                code: "codec_contract"
            )
        }
    }

    public static func readState(reader: JsonReader): GeneratedReadStateV1 {
        match (reader) {
            case owner: GeneratedReadStateV1Owner => owner.generatedReadStateV1()
            case _ => throw JsonException(
                "JsonReader is not owned by the yjson runtime",
                code: "codec_contract"
            )
        }
    }

    public static func readState(reader: GeneratedSupportV1Reader): GeneratedReadStateV1 {
        match (reader) {
            case fast: JsonFastReader => fast.generatedReadStateV1()
            case owner: GeneratedReadStateV1Owner => owner.generatedReadStateV1()
            case _ => throw JsonException(
                "Generated reader is not owned by the yjson runtime",
                code: "generated_protocol_mismatch"
            )
        }
    }

    public static func readOptions(reader: JsonReader): JsonReadOptions {
        match (reader) {
            case direct: JsonDirectReader => direct.readConfig()
            case tape: BackendTapeReaderV1 => tape.readConfig()
            case fast: FastSemanticReaderAdapter => fast.readConfig()
            case _ => throw JsonException(
                "JsonReader is not owned by the yjson runtime",
                code: "codec_contract"
            )
        }
    }

    /// Returns whether a generated reader may use the compact fast path
    /// without constructing the general semantic reader. Generated exact
    /// overloads use this tiny public seam so they can keep their concrete
    /// codec call at the application call site instead of routing through a
    /// type-erased generic YJson wrapper.
    public static func usesDefaultFastReadOptions(options: JsonReadOptions): Bool {
        jsonReadOptionsUsesDefaultFastPath(options)
    }

    public static func captureValue(reader: JsonReader, maxBytes: Int64): GeneratedReplayValueV1 {
        match (reader) {
            case direct: JsonDirectReader => direct.readReplayValue(maxBytes)
            case tape: BackendTapeReaderV1 => tape.readReplayValue(maxBytes)
            case fast: FastSemanticReaderAdapter => fast.readReplayValue(maxBytes)
            case _ => throw JsonException(
                "JsonReader does not support generated replay",
                code: "codec_contract",
                path: reader.path(),
                location: reader.location()
            )
        }
    }

    public static func finishReader(reader: JsonReader): Unit {
        match (reader) {
            case direct: JsonDirectReader => direct.expectEnd()
            case tape: BackendTapeReaderV1 => tape.expectEnd()
            case fast: FastSemanticReaderAdapter => fast.expectEnd()
            case _ => throw JsonException(
                "JsonReader is not owned by the yjson runtime",
                code: "codec_contract"
            )
        }
    }
    public static func newSemanticReader(text: String, config: JsonReadOptions): JsonReader {
        freezeYJsonRuntime()
        JsonDirectReader(text, config: config)
    }
    public static func newSemanticReader(bytes: Array<Byte>, config: JsonReadOptions): JsonReader {
        freezeYJsonRuntime()
        JsonDirectReader(bytes, config: config)
    }

    public static func writeNested<T>(codec: JsonCodec<T>, value: T, writer: GeneratedSupportV1Writer): Unit {
        writeJsonDirectWith(codec, value, writer)
    }

    public static func writeValue(value: JsonNode, writer: JsonWriter): Unit {
        writeJsonNodeToCodecWriter(writer, value)
    }

    public static func writeValue<T>(value: T, writer: JsonWriter): Unit
        where T <: GeneratedCodecProviderV1<T> {
        generatedCodecV1Of<T>().write(value, writer)
    }

    public static func nodeValue(value: JsonNode): JsonNode { value }
    public static func nodeValue(value: Bool): JsonNode { JsonBoolValue(value) }
    public static func nodeValue(value: Int64): JsonNode { JsonIntValue(value) }
    public static func nodeValue(value: Float64): JsonNode { JsonFloatValue(value) }
    public static func nodeValue(value: Rune): JsonNode { JsonStringValue(value.toString()) }
    public static func nodeValue(value: String): JsonNode { JsonStringValue(value) }
    public static func nodeValue(value: Array<JsonNode>): JsonNode { JsonArray(value) }
    public static func nodeValue<T>(value: T): JsonNode where T <: GeneratedCodecProviderV1<T> {
        JsonNode.parse(YJson.toJson(value))
    }

    public static func readWith<T>(codec: JsonCodec<T>, reader: GeneratedSupportV1Reader): T {
        readJsonNestedFastWith(codec, reader)
    }

    public static func tryBeginCompactValue(writer: GeneratedSupportV1Writer): Bool {
        jsonTryBeginGeneratedCompactRawValue(writer)
    }
    public static func writeCompactObjectBegin(writer: GeneratedSupportV1Writer): Unit {
        jsonWriteGeneratedCompactObjectBegin(writer)
    }
    public static func writeCompactObjectEnd(writer: GeneratedSupportV1Writer): Unit {
        jsonWriteGeneratedCompactObjectEnd(writer)
    }
    public static func writeCompactEntryString(writer: GeneratedSupportV1Writer, first: Bool,
        name: String, value: String): Bool {
        jsonWriteGeneratedCompactObjectEntryString(writer, first, name, value)
    }
    public static func writeCompactEntryBool(writer: GeneratedSupportV1Writer, first: Bool,
        name: String, value: Bool): Bool {
        jsonWriteGeneratedCompactObjectEntryBool(writer, first, name, value)
    }
    public static func writeCompactEntryInt64(writer: GeneratedSupportV1Writer, first: Bool,
        name: String, value: Int64): Bool {
        jsonWriteGeneratedCompactObjectEntryInt64(writer, first, name, value)
    }
}

func yJsonGeneratedReaderV1(reader: GeneratedSupportV1Reader): JsonFastReader {
    match (reader) {
        case concrete: JsonFastReader => concrete
        case _ => throw JsonException("Unsupported generated reader implementation",
            code: "generated_protocol_mismatch", path: "")
    }
}

func yJsonSemanticReaderV1(reader: GeneratedSupportV1Reader): JsonReader {
    match (reader) {
        case concrete: JsonFastReader => FastSemanticReaderAdapter(concrete)
        case _ => throw JsonException("Unsupported generated reader implementation",
            code: "generated_protocol_mismatch", path: "")
    }
}

func yJsonTryReadNativeInt64ArrayListV1(
    reader: GeneratedSupportV1Reader
): Option<ArrayList<Int64>> {
    yJsonGeneratedReaderV1(reader).tryReadNativeInt64ArrayList()
}

func yJsonGeneratedWriterV1(writer: GeneratedSupportV1Writer): JsonDirectWriter {
    match (writer) {
        case concrete: JsonDirectWriter => concrete
        case _ => throw JsonException("Unsupported generated writer implementation",
            code: "generated_protocol_mismatch", path: "")
    }
}
