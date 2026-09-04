package yjson

/// Managed, immutable JSON document.
public interface JsonDocument {
    func root(): JsonValueView
    func materialize(): JsonNode
    func materialize(maxNodes: Int64): JsonNode
    func toString(): String
}

private class PureCompactJsonDocument <: JsonDocument {
    private let document: CompactJsonDocument

    init(document: CompactJsonDocument) {
        this.document = document
    }

    public func root(): JsonValueView { document.root() }

    public func materialize(): JsonNode { document.root().materialize() }

    public func materialize(maxNodes: Int64): JsonNode {
        document.root().materialize(maxNodes)
    }

    public func toString(): String {
        document.toString()
    }
}

func parseManagedJsonDocument(text: String, config: JsonReadOptions): JsonDocument {
    let compact = unsafe {
        CompactJsonDocument.parseBorrowed(text.rawData(), config, Some(text))
    }
    PureCompactJsonDocument(compact)
}

func parseManagedJsonDocument(bytes: Array<Byte>, config: JsonReadOptions): JsonDocument {
    PureCompactJsonDocument(CompactJsonDocument.parseOwned(bytes, config: config))
}
