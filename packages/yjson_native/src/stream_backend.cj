package yjson_native

import std.io.*
import yjson.*

private class NativeStreamDecodeSession <: JsonStreamDecodeSession {
    private let readerValue: JsonStreamTapeReader
    private var closed: Bool = false

    init(input: InputStream, config: JsonReadConfig) {
        let bytes = readJsonWholeStream(input, config)
        let document = NativeCompactJsonDocument.parse(bytes, config: config)
        let tape = try { document.exportStreamTape() } finally { document.close() }
        // Native parse already enforced maxPolymorphicObjectBytes against the
        // original source span; tape overhead must not be counted again.
        readerValue = JsonStreamTapeReader(tape, config: config,
            replayBudgetPrevalidated: true)
    }

    public func reader(): JsonCodecReader {
        requireOpen()
        readerValue
    }

    public func isClosed(): Bool { closed }
    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("Native JSON stream decode session is closed") }
    }
}

private class NativeStreamEncodeSession <: JsonStreamEncodeSession {
    private let output: OutputStream
    private let config: JsonWriteConfig
    private let writerValue = JsonStreamTapeWriter()
    private var closed: Bool = false
    private var finished: Bool = false

    init(output: OutputStream, config: JsonWriteConfig) {
        this.output = output
        this.config = config
    }

    public func writer(): JsonCodecWriter {
        requireOpen()
        if (finished) { throw IllegalStateException("Native JSON stream encode session is finished") }
        writerValue
    }

    public func finish(): Unit {
        requireOpen()
        if (finished) { throw IllegalStateException("Native JSON stream encode session is already finished") }
        let encoded = encodeNativeStreamTape(writerValue.finishTape(), config)
        output.write(encoded)
        output.flush()
        finished = true
    }

    public func isClosed(): Bool { closed }
    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("Native JSON stream encode session is closed") }
    }
}

private class NativeCompactJsonStreamBackendImpl <: JsonStreamBackend {
    public func name(): String { "custom-native" }
    public func decodeBuffering(): JsonStreamBufferingMode { JsonStreamBufferingMode.WholeDocument }
    public func encodeBuffering(): JsonStreamBufferingMode { JsonStreamBufferingMode.WholeDocument }

    public func openDecoder(input: InputStream, config: JsonReadConfig): JsonStreamDecodeSession {
        NativeStreamDecodeSession(input, config)
    }

    public func openEncoder(output: OutputStream, config: JsonWriteConfig): JsonStreamEncodeSession {
        NativeStreamEncodeSession(output, config)
    }
}

/// Whole-document typed stream backend implemented by the Custom Native DOM
/// and the matching-version compact tape serializer.
public let NativeCompactStreamBackend: JsonStreamBackend = NativeCompactJsonStreamBackendImpl()
