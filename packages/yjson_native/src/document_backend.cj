package yjson_native

import yjson.*

/// Configurable Custom Native implementation of the unified document facade.
public class NativeCompactJsonBackend <: JsonDocumentBackend {
    private let sourceOwnership: NativeCompactSourceOwnership
    private let duplicateStrategy: NativeCompactDuplicateStrategy
    private let collectDuplicateStats: Bool

    public init(
        sourceOwnership!: NativeCompactSourceOwnership = NativeCompactSourceOwnership.CopySource,
        duplicateStrategy!: NativeCompactDuplicateStrategy = NativeCompactDuplicateStrategy.Baseline,
        collectDuplicateStats!: Bool = false
    ) {
        this.sourceOwnership = sourceOwnership
        this.duplicateStrategy = duplicateStrategy
        this.collectDuplicateStats = collectDuplicateStats
    }

    public func name(): String { "custom-native" }

    public func parse(bytes: Array<Byte>, config: JsonReadConfig): JsonDocument {
        NativeJsonDocumentAdapter(NativeCompactJsonDocument.parse(bytes,
            config: config,
            sourceOwnership: sourceOwnership,
            duplicateStrategy: duplicateStrategy,
            collectDuplicateStats: collectDuplicateStats))
    }
}

private class NativeJsonDocumentAdapter <: JsonDocument {
    private let document: NativeCompactJsonDocument

    init(document: NativeCompactJsonDocument) {
        this.document = document
    }

    public func backendName(): String { "custom-native" }
    public func isClosed(): Bool { document.isClosed() }
    public func close(): Unit { document.close() }
    public func rootSize(): Int64 { document.root().size() }

    public func getRootInt(name: String): Option<Int64> {
        match (document.root().get(name)) {
            case Some(value) => Some(value.asInt64())
            case None => None<Int64>
        }
    }

    public func materialize(): JsonNode { document.materialize() }
    public func toString(): String { document.toString() }
}

/// Default Custom Native backend for `YJson.parseDocument`.
public let NativeCompactBackend: JsonDocumentBackend = NativeCompactJsonBackend()
