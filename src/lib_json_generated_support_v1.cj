package yjson

import std.collection.*

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
public interface GeneratedSupportV1Writer <: JsonCodecWriter & JsonCodecBulkWriter {
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

public class GeneratedSupportV1 {
    public static func protocolVersion(): Int64 { yJsonGeneratedProtocolVersion() }

    public static func requireProtocolVersion(expected: Int64): Unit {
        let actual = protocolVersion()
        if (actual != expected) {
            throw JsonException(
                "Generated codec protocol mismatch: expected ${expected}, runtime provides ${actual}",
                code: "generated_protocol_mismatch", path: "$")
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
    public static func newSemanticReader(text: String, config: JsonReadConfig): JsonCodecReader {
        freezeYJsonRuntime()
        JsonDirectReader(text, config: config)
    }
    public static func newSemanticReader(bytes: Array<Byte>, config: JsonReadConfig): JsonCodecReader {
        freezeYJsonRuntime()
        JsonDirectReader(bytes, config: config)
    }

    public static func writeNested<T>(codec: JsonCodec<T>, value: T, writer: GeneratedSupportV1Writer,
        context: JsonEncodeContext): Unit {
        writeJsonDirectWith(codec, value, writer, context)
    }

    public static func readWith<T>(codec: JsonCodec<T>, reader: GeneratedSupportV1Reader,
        context: JsonDecodeContext): T {
        readJsonFastWith(codec, reader, context)
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
            code: "generated_protocol_mismatch", path: "$")
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
            code: "generated_protocol_mismatch", path: "$")
    }
}
