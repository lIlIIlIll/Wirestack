package yjson

/// A selectable parser for the unified read-only document facade.
///
/// Optional packages provide their own backend values without making core
/// depend on Native implementations.
public interface JsonDocumentBackend {
    func name(): String
    /// The returned document must not observe later mutations of `bytes`.
    func parse(bytes: Array<Byte>, config: JsonReadConfig): JsonDocument
}

/// Common bulk operations shared by the Pure Compact and optional Native DOMs.
///
/// `materialize()` is the explicit bridge to arbitrary `JsonNode` traversal.
/// Values returned from it are detached from this document's lifecycle.
public interface JsonDocument <: Resource {
    func backendName(): String
    func isClosed(): Bool
    func close(): Unit
    func rootSize(): Int64
    func getRootInt(name: String): Option<Int64>
    func materialize(): JsonNode
    func toString(): String
}

private class PureCompactJsonDocument <: JsonDocument {
    private let document: CompactJsonDocument
    private var closed: Bool = false

    init(document: CompactJsonDocument) {
        this.document = document
    }

    public func backendName(): String { "pure-compact" }
    public func isClosed(): Bool { closed }
    public func close(): Unit { closed = true }

    public func rootSize(): Int64 {
        requireOpen()
        document.root().size()
    }

    public func getRootInt(name: String): Option<Int64> {
        requireOpen()
        match (document.root().get(name)) {
            case Some(value) => Some(value.asInt64())
            case None => None<Int64>
        }
    }

    public func materialize(): JsonNode {
        requireOpen()
        document.materialize()
    }

    public func toString(): String {
        requireOpen()
        document.toString()
    }

    private func requireOpen(): Unit {
        if (closed) { throw IllegalStateException("JSON document is closed") }
    }
}

private class PureCompactJsonBackendImpl <: JsonDocumentBackend {
    public func name(): String { "pure-compact" }

    public func parse(bytes: Array<Byte>, config: JsonReadConfig): JsonDocument {
        PureCompactJsonDocument(CompactJsonDocument.parseOwned(bytes, config: config))
    }
}

/// Portable default backend. Optional Native packages export additional
/// `JsonDocumentBackend` values that can be passed to the same YJson entry.
public let PureCompactBackend: JsonDocumentBackend = PureCompactJsonBackendImpl()
