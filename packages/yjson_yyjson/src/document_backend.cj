package yjson_yyjson

import yjson.*
import yjson_backends.*

/// Configurable yyjson implementation of the unified document facade.
public class YyjsonCompactJsonBackend <: JsonDocumentBackend {
    private let mode: YyjsonCompactMode
    private let numberStrategy: YyjsonNumberStrategy
    private let lookupIndexMode: YyjsonLookupIndexMode
    private let validationStrategy: YyjsonValidationStrategy

    public init(
        mode!: YyjsonCompactMode = YyjsonCompactMode.Direct,
        numberStrategy!: YyjsonNumberStrategy = YyjsonNumberStrategy.SemanticDispatch,
        lookupIndexMode!: YyjsonLookupIndexMode = YyjsonLookupIndexMode.Retained,
        validationStrategy!: YyjsonValidationStrategy = YyjsonValidationStrategy.Separate
    ) {
        this.mode = mode
        this.numberStrategy = numberStrategy
        this.lookupIndexMode = lookupIndexMode
        this.validationStrategy = validationStrategy
    }

    public func name(): String {
        match (mode) {
            case YyjsonCompactMode.Direct => "yyjson-direct"
            case YyjsonCompactMode.Transcode => "yyjson-transcode"
        }
    }

    public func parse(bytes: Array<Byte>, config: JsonReadConfig): BackendJsonDocument {
        YyjsonJsonDocumentAdapter(YyjsonCompactJsonDocument.parse(bytes,
            config: config,
            mode: mode,
            numberStrategy: numberStrategy,
            lookupIndexMode: lookupIndexMode,
            validationStrategy: validationStrategy))
    }
}

private class YyjsonJsonDocumentAdapter <: BackendJsonDocument {
    private let document: YyjsonCompactJsonDocument

    init(document: YyjsonCompactJsonDocument) {
        this.document = document
    }

    public func backendName(): String {
        match (document.mode()) {
            case YyjsonCompactMode.Direct => "yyjson-direct"
            case YyjsonCompactMode.Transcode => "yyjson-transcode"
        }
    }

    public func isClosed(): Bool { document.isClosed() }
    public func close(): Unit { document.close() }
    public func rootSize(): Int64 { document.rootSize() }
    public func getRootInt(name: String): Option<Int64> { document.getRootInt(name) }
    public func materialize(): JsonNode { document.materializeViaSerialization() }
    public func toString(): String { document.toString() }
}

/// Supported yyjson Direct backend for `YJson.parseDocument`.
public let YyjsonDocumentBackend: JsonDocumentBackend = YyjsonCompactJsonBackend()
