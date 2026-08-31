package yjson_backends

import yjson.*

public enum JsonStreamBufferingMode {
    | Incremental
    | WholeDocument
}

/// Immutable facts about the engine that actually owns a backend document.
public class JsonBackendMetadata {
    public let name: String
    public let version: String
    public let native: Bool
    public let decodeBuffering: JsonStreamBufferingMode
    public let encodeBuffering: JsonStreamBufferingMode

    public init(name: String, version: String, native: Bool,
        decodeBuffering: JsonStreamBufferingMode,
        encodeBuffering: JsonStreamBufferingMode) {
        this.name = name
        this.version = version
        this.native = native
        this.decodeBuffering = decodeBuffering
        this.encodeBuffering = encodeBuffering
    }
}

public interface BackendJsonDocument <: Resource {
    func metadata(): JsonBackendMetadata
    func isClosed(): Bool
    func close(): Unit
    func root(): JsonValueView
    func materialize(): JsonNode
    func materialize(maxNodes: Int64): JsonNode
}
