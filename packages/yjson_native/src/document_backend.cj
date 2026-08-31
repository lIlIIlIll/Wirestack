package yjson_native

import std.io.*
import yjson.*
import yjson_backends.*

private let CUSTOM_NATIVE_METADATA = JsonBackendMetadata(
    "custom-native",
    "0.1.0",
    true,
    JsonStreamBufferingMode.WholeDocument,
    JsonStreamBufferingMode.WholeDocument
)

/// Closed, immutable facade for the qualified Custom Native backend.
public class NativeBackendFacade {
    init() {}

    public func metadata(): JsonBackendMetadata { CUSTOM_NATIVE_METADATA }

    public func parseDocument(text: String,
        options!: JsonReadOptions = JsonReadOptions.defaults): BackendJsonDocument {
        parseDocument(unsafe { text.rawData() }, options: options)
    }

    public func parseDocument(bytes: Array<Byte>,
        options!: JsonReadOptions = JsonReadOptions.defaults): BackendJsonDocument {
        NativeJsonDocument(NativeCompactJsonDocument.parse(bytes, config: options))
    }

    public func toJson(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        let output = YJsonMemoryOutputStream()
        encodeNativeView(value, output, options)
        output.toUtf8String()
    }

    public func toJsonBytes(value: JsonValueView,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Array<Byte> {
        let output = YJsonMemoryOutputStream()
        encodeNativeView(value, output, options)
        output.toByteArray()
    }

    public func writeJson(value: JsonValueView, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        encodeNativeView(value, output, options)
    }

    public func toJson<T>(value: T,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String
        where T <: GeneratedCodecProviderV1<T> {
        toJson(value, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func toJson<T>(value: T, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): String {
        let output = YJsonMemoryOutputStream()
        encodeNativeBackend(codec, value, output, options)
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
        encodeNativeBackend(codec, value, output, options)
        output.toByteArray()
    }

    public func writeJson<T>(value: T, output: OutputStream,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit
        where T <: GeneratedCodecProviderV1<T> {
        writeJson(value, output, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func writeJson<T>(value: T, output: OutputStream, codec!: JsonCodec<T>,
        options!: JsonWriteOptions = JsonWriteOptions.defaults): Unit {
        encodeNativeBackend(codec, value, output, options)
    }

    public func fromJson<T>(text: String,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(text, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(text: String, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeNativeBackend(codec, YJsonByteArrayInputStream(text), options)
    }

    public func fromJson<T>(bytes: Array<Byte>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(bytes, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(bytes: Array<Byte>, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeNativeBackend(codec, YJsonByteArrayInputStream(bytes), options)
    }

    public func fromJson<T>(input: InputStream,
        options!: JsonReadOptions = JsonReadOptions.defaults): T
        where T <: GeneratedCodecProviderV1<T> {
        fromJson<T>(input, codec: generatedCodecV1Of<T>(), options: options)
    }

    public func fromJson<T>(input: InputStream, codec!: JsonCodec<T>,
        options!: JsonReadOptions = JsonReadOptions.defaults): T {
        decodeNativeBackend(codec, input, options)
    }
}

/// Qualified first-party backend handles. Callers cannot construct or inject
/// additional backend implementations.
public class NativeBackends {
    private static let qualified = NativeBackendFacade()

    private init() {}

    public static prop customNative: NativeBackendFacade {
        get() { qualified }
    }
}

private class NativeJsonDocument <: BackendJsonDocument {
    private let document: NativeCompactJsonDocument

    init(document: NativeCompactJsonDocument) {
        this.document = document
    }

    public func metadata(): JsonBackendMetadata { CUSTOM_NATIVE_METADATA }
    public func isClosed(): Bool { document.isClosed() }
    public func close(): Unit { document.close() }
    public func root(): JsonValueView { document.root() }
    public func materialize(): JsonNode { document.materialize() }
    public func materialize(maxNodes: Int64): JsonNode {
        document.materialize(maxNodes)
    }
}
