package yjson_native

import std.io.*
import std.collection.*
import yjson.*

private class NativeStreamDecodeSession {
    private let readerValue: BackendTapeReaderV1
    private var closed: Bool = false

    init(input: InputStream, config: JsonReadOptions) {
        let bytes = readNativeWholeDocument(input, config)
        let document = NativeCompactJsonDocument.parse(bytes, config: config)
        let tape = try { document.exportStreamTape() } finally { document.close() }
        // Native parse already enforced maxPolymorphicObjectBytes against the
        // original source span; tape overhead must not be counted again.
        readerValue = BackendTapeReaderV1(tape, config: config,
            replayBudgetPrevalidated: true)
    }

    public func reader(): JsonReader {
        requireOpen()
        readerValue
    }

    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("Native JSON stream decode session is closed") }
    }
}

private func readNativeWholeDocument(input: InputStream, config: JsonReadOptions): Array<Byte> {
    let result = ArrayList<Byte>()
    let chunk = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = input.read(chunk)
        if (count <= 0) { break }
        if (result.size > config.maxInputBytes - count) {
            throw JsonException("JSON document exceeds ${config.maxInputBytes} bytes",
                code: "document_too_large",
                location: Some(JsonLocation(config.maxInputBytes, 1, config.maxInputBytes + 1)))
        }
        result.add(all: chunk[0..count])
    }
    result.toArray()
}

private class NativeStreamEncodeSession {
    private let output: OutputStream
    private let config: JsonWriteOptions
    private let writerValue: BackendTapeWriterV1
    private var closed: Bool = false
    private var finished: Bool = false

    init(output: OutputStream, config: JsonWriteOptions) {
        this.output = output
        this.config = config
        writerValue = BackendTapeWriterV1(config: config)
    }

    public func writer(): JsonWriter {
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

    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("Native JSON stream encode session is closed") }
    }
}

func decodeNativeBackend<T>(codec: JsonCodec<T>, input: InputStream,
    options: JsonReadOptions): T {
    GeneratedSupportV1.requireProtocolVersion(1)
    let session = NativeStreamDecodeSession(input, options)
    try {
        let reader = session.reader()
        let value = codec.read(reader)
        GeneratedSupportV1.finishReader(reader)
        value
    } finally {
        session.close()
    }
}

func encodeNativeBackend<T>(codec: JsonCodec<T>, value: T, output: OutputStream,
    options: JsonWriteOptions): Unit {
    GeneratedSupportV1.requireProtocolVersion(1)
    let session = NativeStreamEncodeSession(output, options)
    try {
        codec.write(value, session.writer())
        session.finish()
    } finally {
        session.close()
    }
}

func encodeNativeView(value: JsonValueView, output: OutputStream,
    options: JsonWriteOptions): Unit {
    match (value) {
        case native: NativeCompactJsonValue =>
            match (native.exportRootStreamTape()) {
                case Some(tape) =>
                    output.write(encodeNativeStreamTape(tape, options))
                    output.flush()
                    return
                case None => ()
            }
        case _ => ()
    }
    let session = NativeStreamEncodeSession(output, options)
    try {
        let _ = value.kind()
        writeNativeView(session.writer(), value)
        session.finish()
    } finally {
        session.close()
    }
}

private func writeNativeView(writer: JsonWriter, value: JsonValueView): Unit {
    match (value.kind()) {
        case JsonKind.Null => writer.writeNull()
        case JsonKind.Boolean => writer.writeBool(value.asBool())
        case JsonKind.Number => writer.writeNumberLiteral(value.asNumberText())
        case JsonKind.String => writer.writeString(value.asString())
        case JsonKind.Array =>
            writer.startArray()
            for (index in 0..value.size()) {
                writeNativeView(writer, value.element(index).getOrThrow({ =>
                    JsonException("Array view changed during traversal",
                        code: "view_contract")
                }))
            }
            writer.endArray()
        case JsonKind.Object =>
            writer.startObject()
            for (index in 0..value.size()) {
                writer.writeName(value.memberName(index))
                writeNativeView(writer, value.memberValue(index))
            }
            writer.endObject()
    }
}
