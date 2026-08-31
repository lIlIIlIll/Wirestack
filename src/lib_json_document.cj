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
    // CompactJsonDocument may borrow a String's UTF-8 storage. Keeping the
    // owner in the facade makes the borrow valid for the facade's GC lifetime
    // without adding lifecycle work to the public document API.
    private let sourceTextOwner: Option<String>

    init(document: CompactJsonDocument, sourceTextOwner!: Option<String> = None<String>) {
        this.document = document
        this.sourceTextOwner = sourceTextOwner
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
        CompactJsonDocument.parseBorrowed(text.rawData(), config: config)
    }
    PureCompactJsonDocument(compact, sourceTextOwner: Some(text))
}

func parseManagedJsonDocument(bytes: Array<Byte>, config: JsonReadOptions): JsonDocument {
    PureCompactJsonDocument(CompactJsonDocument.parseOwned(bytes, config: config))
}
