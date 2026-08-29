package yjson

/// Common bulk operations shared by the Pure Compact and optional Native DOMs.
///
/// `materialize()` is the explicit bridge to arbitrary `JsonNode` traversal.
/// Values returned from it are detached from this document's lifecycle.
public interface JsonDocument {
    func root(): CompactJsonValue
    func rootSize(): Int64
    func getRootInt(name: String): Option<Int64>
    func materialize(): JsonNode
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

    public func root(): CompactJsonValue { document.root() }

    public func rootSize(): Int64 {
        document.root().size()
    }

    public func getRootInt(name: String): Option<Int64> {
        match (document.root().get(name)) {
            case Some(value) => Some(value.asInt64())
            case None => None<Int64>
        }
    }

    public func materialize(): JsonNode {
        document.materialize()
    }

    public func toString(): String {
        document.toString()
    }
}

func parseManagedJsonDocument(text: String, config: JsonReadConfig): JsonDocument {
    let compact = unsafe {
        CompactJsonDocument.parseBorrowed(text.rawData(), config: config)
    }
    PureCompactJsonDocument(compact, sourceTextOwner: Some(text))
}

func parseManagedJsonDocument(bytes: Array<Byte>, config: JsonReadConfig): JsonDocument {
    PureCompactJsonDocument(CompactJsonDocument.parseOwned(bytes, config: config))
}
