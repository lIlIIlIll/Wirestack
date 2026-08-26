package yjson

/// Stable generated-code protocol for yjson 2.x patch releases. The concrete
/// reader and writer aliases are confined to this versioned compatibility
/// layer; generated source names only this protocol.
public type GeneratedSupportV1Reader = JsonFastReader
public type GeneratedSupportV1Writer = JsonDirectWriter

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

    public static func newFastReader(text: String): GeneratedSupportV1Reader { JsonFastReader(text) }
    public static func newFastReader(bytes: Array<Byte>): GeneratedSupportV1Reader { JsonFastReader(bytes) }
    public static func newSemanticReader(text: String, config: JsonReadConfig): JsonCodecReader {
        JsonDirectReader(text, config: config)
    }
    public static func newSemanticReader(bytes: Array<Byte>, config: JsonReadConfig): JsonCodecReader {
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
