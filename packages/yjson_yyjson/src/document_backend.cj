package yjson_yyjson

import std.io.*
import yjson.*
import yjson_backends.*

private let YYJSON_METADATA = JsonBackendMetadata(
    "yyjson",
    "0.12.0",
    true,
    JsonStreamBufferingMode.WholeDocument,
    JsonStreamBufferingMode.WholeDocument
)

private let YYJSON_FALLBACK_METADATA = JsonBackendMetadata(
    "custom-native-fallback",
    "0.1.0",
    true,
    JsonStreamBufferingMode.WholeDocument,
    JsonStreamBufferingMode.WholeDocument
)

/// Closed, immutable facade for the qualified yyjson backend.
public class YyjsonBackendFacade {
    init() {}

    public func metadata(): JsonBackendMetadata { YYJSON_METADATA }

    public func parseDocument(text: String,
        options!: JsonReadOptions = JsonReadOptions.defaults): BackendJsonDocument {
        parseDocument(unsafe { text.rawData() }, options: options)
    }

    public func parseDocument(bytes: Array<Byte>,
        options!: JsonReadOptions = JsonReadOptions.defaults): BackendJsonDocument {
        YyjsonJsonDocument(YyjsonCompactJsonDocument.parse(bytes, config: options))
    }

    public func toJson(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        let output = YJsonMemoryOutputStream()
        encodeYyjsonView(value, output, options)
        output.toUtf8String()
    }

    public func toJsonBytes(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        let output = YJsonMemoryOutputStream()
        encodeYyjsonView(value, output, options)
        output.toByteArray()
    }

    public func writeJson(value: JsonValueView, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        encodeYyjsonView(value, output, options)
    }

    public func toJson<T>(value: T,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String
        where T <: GeneratedCodecProviderV1<T> {
        toJson(value, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func toJson<T>(value: T, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        let output = YJsonMemoryOutputStream()
        encodeYyjsonBackend(codec, value, output, options)
        output.toUtf8String()
    }

    public func toJsonBytes<T>(value: T,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte>
        where T <: GeneratedCodecProviderV1<T> {
        toJsonBytes(value, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func toJsonBytes<T>(value: T, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        let output = YJsonMemoryOutputStream()
        encodeYyjsonBackend(codec, value, output, options)
        output.toByteArray()
    }

    public func writeJson<T>(value: T, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit
        where T <: GeneratedCodecProviderV1<T> {
        writeJson(value, output, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func writeJson<T>(value: T, output: OutputStream, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        encodeYyjsonBackend(codec, value, output, options)
    }

    public func fromJson<T>(text: String,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(text, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(text: String, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeYyjsonBackend(codec, YJsonByteArrayInputStream(text), options)
    }

    public func fromJson<T>(bytes: Array<Byte>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(bytes, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(bytes: Array<Byte>, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeYyjsonBackend(codec, YJsonByteArrayInputStream(bytes), options)
    }

    public func fromJson<T>(input: InputStream,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(input, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(input: InputStream, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeYyjsonBackend(codec, input, options)
    }
}

/// Qualified first-party backend handles. Callers cannot construct or inject
/// additional backend implementations.
public class YyjsonBackends {
    private static let qualified = YyjsonBackendFacade()

    private init() {}

    public static prop yyjson: YyjsonBackendFacade {
        get() { qualified }
    }
}

private class YyjsonJsonDocument <: BackendJsonDocument {
    private let document: YyjsonCompactJsonDocument
    private let actualMetadata: JsonBackendMetadata

    init(document: YyjsonCompactJsonDocument) {
        this.document = document
        actualMetadata = if (document.storageStats().customFallback) {
            YYJSON_FALLBACK_METADATA
        } else {
            YYJSON_METADATA
        }
    }

    public func metadata(): JsonBackendMetadata { actualMetadata }
    public func isClosed(): Bool { document.isClosed() }
    public func close(): Unit { document.close() }
    public func root(): JsonValueView { document.root() }
    public func materialize(): JsonNode { document.materialize() }
    public func materialize(maxNodes: Int64): JsonNode {
        document.materialize(maxNodes)
    }
}
