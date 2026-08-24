package yjson

import std.collection.*
import std.io.*

/// Matching-version bridge used by whole-document backends. It consumes the
/// caller stream to EOF without closing it and enforces the configured input
/// budget while accumulating bytes.
public func readJsonWholeStream(input: InputStream, config: JsonReadConfig): Array<Byte> {
    let result = ArrayList<Byte>()
    let chunk = Array<Byte>(JSON_STREAM_BUFFER_CAPACITY, repeat: 0)
    while (true) {
        let count = input.read(chunk)
        if (count <= 0) { break }
        if (config.maxBytes > 0 && result.size > config.maxBytes - count) {
            throw JsonException(
                "JSON document exceeds ${config.maxBytes} bytes",
                code: "document_too_large",
                byteOffset: if (config.includeErrorLocation) { config.maxBytes } else { -1 }
            )
        }
        result.add(all: chunk[0..count])
    }
    result.toArray()
}

private class PureStreamDecodeSession <: JsonStreamDecodeSession {
    private let readerValue: JsonDirectReader
    private var closed: Bool = false

    init(input: InputStream, config: JsonReadConfig) {
        // A memory-backed stream is already wholly resident, so the Pure
        // backend can consume its unread slice with the byte-native reader.
        // This optimization lives inside the selected backend and therefore
        // cannot bypass a caller-provided custom backend.
        readerValue = match (input) {
            case memory: YJsonByteArrayInputStream =>
                JsonDirectReader(memory.readRemainingBytes(), config: config)
            case _ => JsonDirectReader(input, config: config)
        }
    }

    public func reader(): JsonCodecReader {
        requireOpen()
        readerValue
    }

    public func isClosed(): Bool { closed }

    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("JSON stream decode session is closed") }
    }
}

private class PureStreamEncodeSession <: JsonStreamEncodeSession {
    private let writerValue: JsonDirectWriter
    private var closed: Bool = false
    private var finished: Bool = false

    init(output: OutputStream, config: JsonWriteConfig) {
        writerValue = JsonDirectWriter(output, config: config)
    }

    public func writer(): JsonCodecWriter {
        requireOpen()
        if (finished) { throw IllegalStateException("JSON stream encode session is finished") }
        writerValue
    }

    public func finish(): Unit {
        requireOpen()
        if (finished) { throw IllegalStateException("JSON stream encode session is already finished") }
        writerValue.finish()
        finished = true
    }

    public func isClosed(): Bool { closed }

    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("JSON stream encode session is closed") }
    }
}

private class PureJsonStreamBackend <: JsonStreamBackend {
    public func name(): String { "pure-incremental" }

    public func decodeBuffering(): JsonStreamBufferingMode {
        JsonStreamBufferingMode.Incremental
    }

    public func encodeBuffering(): JsonStreamBufferingMode {
        JsonStreamBufferingMode.Incremental
    }

    public func openDecoder(input: InputStream, config: JsonReadConfig): JsonStreamDecodeSession {
        PureStreamDecodeSession(input, config)
    }

    public func openEncoder(output: OutputStream, config: JsonWriteConfig): JsonStreamEncodeSession {
        PureStreamEncodeSession(output, config)
    }
}

/// Portable incremental backend used by default for caller-owned streams.
public let PureStreamBackend: JsonStreamBackend = PureJsonStreamBackend()
