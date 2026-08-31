package yjson_yyjson

import std.io.*
import std.collection.*
import yjson.*

private class YyjsonStreamDecodeSession {
    private let readerValue: BackendTapeReaderV1
    private var closed: Bool = false

    init(input: InputStream, config: JsonReadOptions) {
        let bytes = readYyjsonWholeDocument(input, config)
        let document = YyjsonCompactJsonDocument.parse(bytes, config: config)
        let tape = try { document.exportStreamTape() } finally { document.close() }
        // Native preflight already enforced the polymorphic budget against the
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
        if (closed) { throw IllegalStateException("yyjson stream decode session is closed") }
    }
}

private func readYyjsonWholeDocument(input: InputStream, config: JsonReadOptions): Array<Byte> {
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

private class YyjsonStreamEncodeSession {
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

    public func close(): Unit { closed = true }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("yyjson stream encode session is closed") }
    }
}

func decodeYyjsonBackend<T>(codec: JsonCodec<T>, input: InputStream,
    options: JsonReadOptions): T {
    GeneratedSupportV1.requireProtocolVersion(1)
    let session = YyjsonStreamDecodeSession(input, options)
    try {
        let reader = session.reader()
        let value = codec.read(reader)
        GeneratedSupportV1.finishReader(reader)
        value
    } finally {
        session.close()
    }
}

func encodeYyjsonBackend<T>(codec: JsonCodec<T>, value: T, output: OutputStream,
    options: JsonWriteOptions): Unit {
    GeneratedSupportV1.requireProtocolVersion(1)
    let session = YyjsonStreamEncodeSession(output, options)
    try {
        codec.write(value, session.writer())
        session.finish()
    } finally {
        session.close()
    }
}

func encodeYyjsonView(value: JsonValueView, output: OutputStream,
    options: JsonWriteOptions): Unit {
    match (value) {
        case yyjson: YyjsonJsonValue =>
            match (yyjson.exportRootStreamTape()) {
                case Some(tape) =>
                    output.write(encodeYyjsonStreamTape(tape, options))
                    output.flush()
                    return
                case None => ()
            }
        case _ => ()
    }
    let session = YyjsonStreamEncodeSession(output, options)
    try {
        let _ = value.kind()
        writeYyjsonView(session.writer(), value)
        session.finish()
    } finally {
        session.close()
    }
}

private func writeYyjsonView(writer: JsonWriter, value: JsonValueView): Unit {
    match (value.kind()) {
        case JsonKind.Null => writer.writeNull()
        case JsonKind.Boolean => writer.writeBool(value.asBool())
        case JsonKind.Number => writer.writeNumberLiteral(value.asNumberText())
        case JsonKind.String => writer.writeString(value.asString())
        case JsonKind.Array =>
            writer.startArray()
            for (index in 0..value.size()) {
                writeYyjsonView(writer, value.element(index).getOrThrow({ =>
                    JsonException("Array view changed during traversal",
                        code: "view_contract")
                }))
            }
            writer.endArray()
        case JsonKind.Object =>
            writer.startObject()
            for (index in 0..value.size()) {
                writer.writeName(value.memberName(index))
                writeYyjsonView(writer, value.memberValue(index))
            }
            writer.endObject()
    }
}
