package yjson_yyjson

import std.io.*
import yjson.*

private class YyjsonStreamDecodeSession <: JsonStreamDecodeSession {
    private let readerValue: JsonStreamTapeReader
    private var closed: Bool = false

    init(input: InputStream, config: JsonReadConfig) {
        let bytes = readJsonWholeStream(input, config)
        let document = YyjsonCompactJsonDocument.parse(bytes, config: config)
        let tape = try { document.exportStreamTape() } finally { document.close() }
        // Native preflight already enforced the polymorphic budget against the
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
        if (closed) { throw IllegalStateException("yyjson stream decode session is closed") }
    }
}

private class YyjsonStreamEncodeSession <: JsonStreamEncodeSession {
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
        if (finished) { throw IllegalStateException("yyjson stream encode session is finished") }
        writerValue
    }

    public func finish(): Unit {
        requireOpen()
        if (finished) { throw IllegalStateException("yyjson stream encode session is already finished") }
        let encoded = encodeYyjsonStreamTape(writerValue.finishTape(), config)
        output.write(encoded)
        output.flush()
        finished = true
    }

    public func isClosed(): Bool { closed }
    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("yyjson stream encode session is closed") }
    }
}

private class YyjsonJsonStreamBackendImpl <: JsonStreamBackend {
    public func name(): String { "yyjson-direct" }
    public func decodeBuffering(): JsonStreamBufferingMode { JsonStreamBufferingMode.WholeDocument }
    public func encodeBuffering(): JsonStreamBufferingMode { JsonStreamBufferingMode.WholeDocument }

    public func openDecoder(input: InputStream, config: JsonReadConfig): JsonStreamDecodeSession {
        YyjsonStreamDecodeSession(input, config)
    }

    public func openEncoder(output: OutputStream, config: JsonWriteConfig): JsonStreamEncodeSession {
        YyjsonStreamEncodeSession(output, config)
    }
}

/// Whole-document typed stream backend implemented by the supported yyjson
/// Direct mode and the matching-version compact tape bridge.
public let YyjsonStreamBackend: JsonStreamBackend = YyjsonJsonStreamBackendImpl()
