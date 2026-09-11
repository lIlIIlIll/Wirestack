package yjson

/**
 * Managed immutable JSON document with read-only value views.
 *
 * The document is GC-managed and has no close operation. Views retain the storage they need. Use materialize to obtain a detached mutable tree. The default copy budget is 100,000 nodes with a maximum depth of 256.
 */
public interface JsonDocument {
    /**
     * Returns a read-only view of the document root.
     *
     * @return Root view retaining its underlying document storage.
     */
    func root(): JsonValueView
    /**
     * Copies the document into a detached mutable JsonNode tree.
     *
     * Copying is limited to 256 levels and, without maxNodes, 100,000 nodes.
     *
     * @return Mutable tree independent of the document storage.
     */
    func materialize(): JsonNode
    /**
     * Copies the document into a detached mutable JsonNode tree.
     *
     * Copying is limited to 256 levels and, without maxNodes, 100,000 nodes.
     *
     * @param maxNodes Positive maximum number of nodes to copy.
     * @return Mutable tree independent of the document storage.
     */
    func materialize(maxNodes: Int64): JsonNode
    /**
     * Returns the document as JSON text.
     *
     * @return JSON text representing the document.
     */
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
