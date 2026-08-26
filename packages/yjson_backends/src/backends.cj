package yjson_backends

import std.collection.*
import std.io.*
import yjson.*

public enum JsonStreamBufferingMode {
    | Incremental
    | WholeDocument
}

public interface JsonStreamDecodeSession <: Resource {
    func reader(): JsonCodecReader
}

public interface JsonStreamEncodeSession <: Resource {
    func writer(): JsonCodecWriter
    func finish(): Unit
}

public interface JsonStreamBackend {
    func name(): String
    func decodeBuffering(): JsonStreamBufferingMode
    func encodeBuffering(): JsonStreamBufferingMode
    func openDecoder(input: InputStream, config: JsonReadConfig): JsonStreamDecodeSession
    func openEncoder(output: OutputStream, config: JsonWriteConfig): JsonStreamEncodeSession
}

public interface BackendJsonDocument <: Resource {
    func backendName(): String
    func isClosed(): Bool
    func close(): Unit
    func rootSize(): Int64
    func getRootInt(name: String): Option<Int64>
    func materialize(): JsonNode
    func toString(): String
}

public interface JsonDocumentBackend {
    func name(): String
    func parse(bytes: Array<Byte>, config: JsonReadConfig): BackendJsonDocument
}

public class YJsonAdvanced {
    public static func parseDocumentWithBackend(text: String, backend: JsonDocumentBackend,
        config!: JsonReadConfig = JsonReadConfig.defaults): BackendJsonDocument {
        backend.parse(unsafe { text.rawData() }, config)
    }

    public static func parseDocumentWithBackend(bytes: Array<Byte>, backend: JsonDocumentBackend,
        config!: JsonReadConfig = JsonReadConfig.defaults): BackendJsonDocument {
        backend.parse(bytes, config)
    }

    public static func encodeToStreamWithBackend<T>(codec: JsonCodec<T>, value: T,
        output: OutputStream, backend: JsonStreamBackend,
        config!: JsonWriteConfig = JsonWriteConfig.compact): Unit {
        let session = backend.openEncoder(output, config)
        try {
            codec.write(value, session.writer(), JsonEncodeContext(config))
            session.finish()
        } finally { session.close() }
    }

    public static func decodeFromStreamWithBackend<T>(codec: JsonCodec<T>, input: InputStream,
        backend: JsonStreamBackend,
        config!: JsonReadConfig = JsonReadConfig.defaults): T {
        let session = backend.openDecoder(input, config)
        try {
            let reader = session.reader()
            let value = codec.read(reader, JsonDecodeContext(config))
            reader.expectEnd()
            value
        } finally { session.close() }
    }
}

/// Consumes a caller-owned stream to EOF for explicitly whole-document
/// advanced backends. The caller's stream is never closed.
public func readJsonWholeDocumentStream(input: InputStream, config: JsonReadConfig): Array<Byte> {
    let result = ArrayList<Byte>()
    let chunk = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = input.read(chunk)
        if (count <= 0) { break }
        if (config.maxBytes > 0 && result.size > config.maxBytes - count) {
            throw JsonException("JSON document exceeds ${config.maxBytes} bytes",
                code: "document_too_large",
                byteOffset: if (config.includeErrorLocation) { config.maxBytes } else { -1 })
        }
        result.add(all: chunk[0..count])
    }
    result.toArray()
}
