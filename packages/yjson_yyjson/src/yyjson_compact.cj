package yjson_yyjson

import yjson.*

private let YJ_COMPACT_OK: Int32 = 0
private let YJ_COMPACT_PARSE_ERROR: Int32 = 1
private let YJ_COMPACT_INVALID_UTF8: Int32 = 2
private let YJ_COMPACT_MAX_DEPTH: Int32 = 3
private let YJ_COMPACT_DUPLICATE_KEY: Int32 = 4
private let YJ_COMPACT_OUT_OF_MEMORY: Int32 = 5
private let YJ_COMPACT_DOCUMENT_TOO_LARGE: Int32 = 6
private let YJ_COMPACT_CLOSED: Int32 = 7
private let YJ_COMPACT_TYPE_ERROR: Int32 = 8
private let YJ_COMPACT_BOUNDS_ERROR: Int32 = 9
private let YJ_COMPACT_STRING_TOO_LARGE: Int32 = 10
private let YJ_COMPACT_VALUE_TOO_LARGE: Int32 = 11

private let YJ_YYJSON_DIRECT: UInt32 = 0u32
private let YJ_YYJSON_TRANSCODE: UInt32 = 1u32
private let YJ_YYJSON_REJECT_DUPLICATES: UInt32 = 1u32
private let YJ_YYJSON_PRESERVE_NUMBERS: UInt32 = 2u32
private let YJ_YYJSON_NUMBER_DISPATCH_CUSTOM: UInt32 = 4u32
private let YJ_YYJSON_NUMBER_LEGACY_RAW: UInt32 = 8u32
private let YJ_YYJSON_RETAIN_ROOT_INDEX: UInt32 = 16u32
private let YJ_YYJSON_LAZY_ROOT_INDEX: UInt32 = 32u32
private let YJ_YYJSON_SEPARATE_VALIDATION: UInt32 = 64u32

foreign func YJ_Yyjson_Parse(input: CPointer<UInt8>, length: Int64, flags: UInt32,
    maxDepth: Int64, mode: UInt32, outHandle: CPointer<UInt64>,
    outErrorCode: CPointer<UInt32>, outErrorOffset: CPointer<Int64>): Int32
foreign func YJ_Yyjson_ParseWithLimits(input: CPointer<UInt8>, length: Int64,
    flags: UInt32, maxDepth: Int64, mode: UInt32, maxBytes: Int64,
    maxStringBytes: Int64, maxValueBytes: Int64, outHandle: CPointer<UInt64>,
    outErrorCode: CPointer<UInt32>, outErrorOffset: CPointer<Int64>): Int32
foreign func YJ_Yyjson_Free(handle: UInt64): Unit
foreign func YJ_Yyjson_TraversalChecksum(handle: UInt64): UInt64
@FastNative
foreign func YJ_Yyjson_RootSize(handle: UInt64, outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_ObjectLookupInt(handle: UInt64, key: CPointer<UInt8>, keyLength: UInt64,
    outValue: CPointer<Int64>, outFound: CPointer<UInt32>): Int32
foreign func YJ_Yyjson_SerializeAlloc(handle: UInt64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_ExportTapeAlloc(handle: UInt64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_EncodeTapeAlloc(tape: CPointer<UInt8>, tapeLength: UInt64,
    newline: CPointer<UInt8>, newlineLength: UInt64, indent: CPointer<UInt8>,
    indentLength: UInt64, useSpaceAfterSeparators: UInt32, htmlSafe: UInt32,
    maxDepth: Int64, maxBytes: Int64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>, outErrorCode: CPointer<UInt32>): Int32
foreign func YJ_Yyjson_CopyOwnedBuffer(bufferHandle: UInt64, output: CPointer<UInt8>,
    outputCapacity: UInt64): Int32
foreign func YJ_Yyjson_FreeOwnedBuffer(bufferHandle: UInt64): Unit
@FastNative
foreign func YJ_Yyjson_Stats(handle: UInt64, stats: CPointer<UInt64>, capacity: UInt64): Int32

func encodeYyjsonStreamTape(tape: Array<Byte>, config: JsonWriteConfig): Array<Byte> {
    let newline = unsafe { config.newline.rawData() }
    let indent = unsafe { config.indent.rawData() }
    let buffer = Array<UInt64>(1, repeat: 0u64)
    let size = Array<UInt64>(1, repeat: 0u64)
    let error = Array<UInt32>(1, repeat: 0u32)
    let status = unsafe {
        let tapeHandle = acquireArrayRawData(tape)
        let newlineHandle = acquireArrayRawData(newline)
        let indentHandle = acquireArrayRawData(indent)
        let bufferHandle = acquireArrayRawData(buffer)
        let sizeHandle = acquireArrayRawData(size)
        let errorHandle = acquireArrayRawData(error)
        try {
            YJ_Yyjson_EncodeTapeAlloc(tapeHandle.pointer, UInt64(tape.size),
                newlineHandle.pointer, UInt64(newline.size), indentHandle.pointer,
                UInt64(indent.size), if (config.useSpaceAfterSeparators) { 1u32 } else { 0u32 },
                if (config.htmlSafe) { 1u32 } else { 0u32 }, config.maxDepth, config.maxBytes,
                bufferHandle.pointer, sizeHandle.pointer, errorHandle.pointer)
        } finally {
            releaseArrayRawData(errorHandle)
            releaseArrayRawData(sizeHandle)
            releaseArrayRawData(bufferHandle)
            releaseArrayRawData(indentHandle)
            releaseArrayRawData(newlineHandle)
            releaseArrayRawData(tapeHandle)
        }
    }
    if (status != YJ_COMPACT_OK) {
        match {
            case Int32(error[0]) == YJ_COMPACT_VALUE_TOO_LARGE =>
                throw JsonException("Encoded JSON exceeds ${config.maxBytes} bytes",
                    code: "output_too_large")
            case Int32(error[0]) == YJ_COMPACT_MAX_DEPTH =>
                throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth")
            case Int32(error[0]) == YJ_COMPACT_OUT_OF_MEMORY =>
                throw JsonException("yyjson stream encode allocation failed", code: "out_of_memory")
            case _ => throw JsonException("Invalid JSON stream tape", code: "codec_contract")
        }
    }
    let output = Array<Byte>(Int64(size[0]), repeat: 0)
    try {
        let copyStatus = unsafe {
            let outputHandle = acquireArrayRawData(output)
            try { YJ_Yyjson_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
            finally { releaseArrayRawData(outputHandle) }
        }
        if (copyStatus != YJ_COMPACT_OK) {
            throw JsonException("yyjson stream output copy failed", code: "codec_contract")
        }
        output
    } finally {
        unsafe { YJ_Yyjson_FreeOwnedBuffer(buffer[0]) }
    }
}

public enum YyjsonCompactMode {
    | Direct
    | Transcode
}

public enum YyjsonNumberStrategy {
    | SelectiveSource
    | SemanticDispatch
    | LegacyRaw
}

public enum YyjsonLookupIndexMode {
    | Linear
    | Retained
    | Lazy
}

/// Qualification control for measuring semantic-pass fusion.
public enum YyjsonValidationStrategy {
    | Fused
    | Separate
}

public struct YyjsonCompactStorageStats {
    public let allocatorCurrent: UInt64
    public let allocatorPeak: UInt64
    public let allocatorTotalRequested: UInt64
    public let validationScratchPeak: UInt64
    public let persistentUsed: UInt64
    public let persistentCommitted: UInt64
    public let nodes: UInt64
    public let objectFields: UInt64
    public let arrayEntries: UInt64
    public let strings: UInt64
    public let mode: UInt64
    public let customFallback: Bool
    public let validationProbes: UInt64
    public let validationMaxProbe: UInt64
    public let validationHashes: UInt64
    public let validationFingerprintMatches: UInt64
    public let validationMemcmpCalls: UInt64
    public let validationMemcmpBytes: UInt64
    public let validationSmallLinearObjects: UInt64
    public let validationHashedObjects: UInt64
    public let validationWalks: UInt64
    public let literalEntries: UInt64
    public let literalBytes: UInt64
    public let sourceReplayBytes: UInt64
    public let sourceCopyBytes: UInt64
    public let safeIntNumbers: UInt64
    public let rawRequiredNumbers: UInt64
    public let rootIndexBytes: UInt64
    public let rootIndexBuilds: UInt64
    public let rootIndexProbes: UInt64
    public let rootIndexMaxProbe: UInt64
    public let validationP50Probe: UInt64
    public let validationP95Probe: UInt64
    public let validationP99Probe: UInt64

    init(values: Array<UInt64>) {
        allocatorCurrent = values[0]
        allocatorPeak = values[1]
        allocatorTotalRequested = values[2]
        validationScratchPeak = values[3]
        persistentUsed = values[4]
        persistentCommitted = values[5]
        nodes = values[6]
        objectFields = values[7]
        arrayEntries = values[8]
        strings = values[9]
        mode = values[10]
        customFallback = values[11] != 0u64
        validationProbes = values[12]
        validationMaxProbe = values[13]
        validationHashes = values[14]
        validationFingerprintMatches = values[15]
        validationMemcmpCalls = values[16]
        validationMemcmpBytes = values[17]
        validationSmallLinearObjects = values[18]
        validationHashedObjects = values[19]
        validationWalks = values[20]
        literalEntries = values[21]
        literalBytes = values[22]
        sourceReplayBytes = values[23]
        sourceCopyBytes = values[24]
        safeIntNumbers = values[25]
        rawRequiredNumbers = values[26]
        rootIndexBytes = values[27]
        rootIndexBuilds = values[28]
        rootIndexProbes = values[29]
        rootIndexMaxProbe = values[30]
        validationP50Probe = values[31]
        validationP95Probe = values[32]
        validationP99Probe = values[33]
    }
}

/// Supported opt-in yyjson 0.12.0 backed immutable native document.
///
/// The pure Cangjie backend remains the portable default. This type is for
/// callers that retain the native DOM and use coarse lookup, traversal, or
/// serialization operations; it is not an acceleration path for
/// `JsonNode.parse`, and materialization reparses serialized output.
///
/// This resource is intentionally bulk-first. It is not thread-safe: read/read
/// is supported only when the caller externally guarantees the document stays
/// open, and `close()` must never race lookup, traversal, or serialization.
/// Call `close()` deterministically; the destructor is only a leak safety net.
public class YyjsonCompactJsonDocument <: Resource {
    private var handle: UInt64
    private let selectedMode: YyjsonCompactMode

    private init(handle: UInt64, mode: YyjsonCompactMode) {
        this.handle = handle
        selectedMode = mode
    }

    public static func parse(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults,
        // The remaining selectors are qualification controls. Only Direct,
        // SemanticDispatch, Retained, and Separate form the supported RC path.
        mode!: YyjsonCompactMode = YyjsonCompactMode.Direct,
        numberStrategy!: YyjsonNumberStrategy = YyjsonNumberStrategy.SemanticDispatch,
        lookupIndexMode!: YyjsonLookupIndexMode = YyjsonLookupIndexMode.Retained,
        validationStrategy!: YyjsonValidationStrategy = YyjsonValidationStrategy.Separate
    ): YyjsonCompactJsonDocument {
        var flags: UInt32 = 0u32
        match (config.duplicateKeyPolicy) {
            case JsonDuplicateKeyPolicy.Reject => flags |= YJ_YYJSON_REJECT_DUPLICATES
            case _ => ()
        }
        match (config.numberPolicy) {
            case JsonNumberPolicy.PreserveLiteral => flags |= YJ_YYJSON_PRESERVE_NUMBERS
            case _ => ()
        }
        match (numberStrategy) {
            case YyjsonNumberStrategy.SelectiveSource => ()
            case YyjsonNumberStrategy.SemanticDispatch =>
                flags |= YJ_YYJSON_NUMBER_DISPATCH_CUSTOM
                flags |= YJ_YYJSON_NUMBER_LEGACY_RAW
            case YyjsonNumberStrategy.LegacyRaw => flags |= YJ_YYJSON_NUMBER_LEGACY_RAW
        }
        match (lookupIndexMode) {
            case YyjsonLookupIndexMode.Linear => ()
            case YyjsonLookupIndexMode.Retained => flags |= YJ_YYJSON_RETAIN_ROOT_INDEX
            case YyjsonLookupIndexMode.Lazy => flags |= YJ_YYJSON_LAZY_ROOT_INDEX
        }
        match (validationStrategy) {
            case YyjsonValidationStrategy.Fused => ()
            case YyjsonValidationStrategy.Separate => flags |= YJ_YYJSON_SEPARATE_VALIDATION
        }
        let outHandle = Array<UInt64>(1, repeat: 0u64)
        let outError = Array<UInt32>(1, repeat: 0u32)
        let outOffset = Array<Int64>(1, repeat: -1)
        let nativeMode = match (mode) {
            case YyjsonCompactMode.Direct => YJ_YYJSON_DIRECT
            case YyjsonCompactMode.Transcode => YJ_YYJSON_TRANSCODE
        }
        let status = unsafe {
            let inputHandle = acquireArrayRawData(bytes)
            let handleHandle = acquireArrayRawData(outHandle)
            let errorHandle = acquireArrayRawData(outError)
            let offsetHandle = acquireArrayRawData(outOffset)
            try {
                if (config.maxBytes == 0 && config.maxStringBytes == 0 &&
                    config.maxPolymorphicObjectBytes == 0) {
                    YJ_Yyjson_Parse(inputHandle.pointer, bytes.size, flags, config.maxDepth,
                        nativeMode, handleHandle.pointer, errorHandle.pointer, offsetHandle.pointer)
                } else {
                    YJ_Yyjson_ParseWithLimits(inputHandle.pointer, bytes.size, flags,
                        config.maxDepth, nativeMode, config.maxBytes, config.maxStringBytes,
                        config.maxPolymorphicObjectBytes, handleHandle.pointer,
                        errorHandle.pointer, offsetHandle.pointer)
                }
            } finally {
                releaseArrayRawData(offsetHandle)
                releaseArrayRawData(errorHandle)
                releaseArrayRawData(handleHandle)
                releaseArrayRawData(inputHandle)
            }
        }
        if (status != YJ_COMPACT_OK) {
            throw yyjsonParseError(bytes, Int32(outError[0]), outOffset[0], config.includeErrorLocation)
        }
        YyjsonCompactJsonDocument(outHandle[0], mode)
    }

    public func mode(): YyjsonCompactMode { selectedMode }
    public func isClosed(): Bool { handle == 0u64 }

    public func close(): Unit {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            unsafe { YJ_Yyjson_Free(current) }
        }
    }

    ~init() {
        if (handle != 0u64) { unsafe { YJ_Yyjson_Free(handle) } }
    }

    public func rootSize(): Int64 {
        let value = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let valueHandle = acquireArrayRawData(value)
            try { YJ_Yyjson_RootSize(requireOpen(), valueHandle.pointer) }
            finally { releaseArrayRawData(valueHandle) }
        }
        checkStatus(status)
        Int64(value[0])
    }

    public func traversalChecksum(): Int64 {
        @OverflowWrapping
        func convert(value: UInt64): Int64 { Int64(value) }
        convert(unsafe { YJ_Yyjson_TraversalChecksum(requireOpen()) })
    }

    public func getRootInt(name: String): Option<Int64> {
        let bytes = unsafe { name.rawData() }
        let value = Array<Int64>(1, repeat: 0)
        let found = Array<UInt32>(1, repeat: 0u32)
        let status = unsafe {
            let bytesHandle = acquireArrayRawData(bytes)
            let valueHandle = acquireArrayRawData(value)
            let foundHandle = acquireArrayRawData(found)
            try {
                YJ_Yyjson_ObjectLookupInt(requireOpen(), bytesHandle.pointer, UInt64(bytes.size),
                    valueHandle.pointer, foundHandle.pointer)
            } finally {
                releaseArrayRawData(foundHandle)
                releaseArrayRawData(valueHandle)
                releaseArrayRawData(bytesHandle)
            }
        }
        checkStatus(status)
        if (found[0] == 0u32) { None<Int64> } else { Some(value[0]) }
    }

    public func storageStats(): YyjsonCompactStorageStats {
        let values = Array<UInt64>(36, repeat: 0u64)
        let status = unsafe {
            let valuesHandle = acquireArrayRawData(values)
            try { YJ_Yyjson_Stats(requireOpen(), valuesHandle.pointer, 36u64) }
            finally { releaseArrayRawData(valuesHandle) }
        }
        checkStatus(status)
        YyjsonCompactStorageStats(values)
    }

    public func toBytes(): Array<Byte> {
        let buffer = Array<UInt64>(1, repeat: 0u64)
        let size = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let bufferHandle = acquireArrayRawData(buffer)
            let sizeHandle = acquireArrayRawData(size)
            try { YJ_Yyjson_SerializeAlloc(requireOpen(), bufferHandle.pointer, sizeHandle.pointer) }
            finally {
                releaseArrayRawData(sizeHandle)
                releaseArrayRawData(bufferHandle)
            }
        }
        checkStatus(status)
        let output = Array<Byte>(Int64(size[0]), repeat: 0)
        try {
            let copyStatus = unsafe {
                let outputHandle = acquireArrayRawData(output)
                try { YJ_Yyjson_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
                finally { releaseArrayRawData(outputHandle) }
            }
            checkStatus(copyStatus)
        } finally {
            unsafe { YJ_Yyjson_FreeOwnedBuffer(buffer[0]) }
        }
        output
    }

    func exportStreamTape(): Array<Byte> {
        let buffer = Array<UInt64>(1, repeat: 0u64)
        let size = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let bufferHandle = acquireArrayRawData(buffer)
            let sizeHandle = acquireArrayRawData(size)
            try { YJ_Yyjson_ExportTapeAlloc(requireOpen(), bufferHandle.pointer, sizeHandle.pointer) }
            finally {
                releaseArrayRawData(sizeHandle)
                releaseArrayRawData(bufferHandle)
            }
        }
        checkStatus(status)
        let output = Array<Byte>(Int64(size[0]), repeat: 0)
        try {
            let copyStatus = unsafe {
                let outputHandle = acquireArrayRawData(output)
                try { YJ_Yyjson_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
                finally { releaseArrayRawData(outputHandle) }
            }
            checkStatus(copyStatus)
            output
        } finally {
            unsafe { YJ_Yyjson_FreeOwnedBuffer(buffer[0]) }
        }
    }

    public func toString(): String { unsafe { String.fromUtf8Unchecked(toBytes()) } }

    /// Coarse control path: one native serialization, then one Cangjie AST parse.
    /// This deliberately avoids per-node FFI and is benchmarked separately.
    public func materializeViaSerialization(): JsonNode { YJson.parse(toBytes()) }

    private func requireOpen(): UInt64 {
        if (handle == 0u64) { throw IllegalStateException("yyjson compact document is closed") }
        handle
    }

    private func checkStatus(status: Int32): Unit {
        if (status == YJ_COMPACT_OK) { return }
        match {
            case status == YJ_COMPACT_CLOSED => throw IllegalStateException("yyjson compact document is closed")
            case status == YJ_COMPACT_TYPE_ERROR => throw JsonException("yyjson compact value type mismatch")
            case status == YJ_COMPACT_BOUNDS_ERROR => throw IndexOutOfBoundsException("yyjson compact index out of bounds")
            case status == YJ_COMPACT_OUT_OF_MEMORY => throw JsonException("yyjson allocation failed", code: "out_of_memory")
            case _ => throw JsonException("yyjson compact operation failed (${status})")
        }
    }
}

private func yyjsonParseError(bytes: Array<Byte>, code: Int32, offset: Int64,
    includeLocation: Bool): JsonException {
    let errorCode = match {
        case code == YJ_COMPACT_MAX_DEPTH => "max_depth"
        case code == YJ_COMPACT_OUT_OF_MEMORY => "out_of_memory"
        case code == YJ_COMPACT_DOCUMENT_TOO_LARGE => "document_too_large"
        case code == YJ_COMPACT_STRING_TOO_LARGE => "string_too_large"
        case code == YJ_COMPACT_VALUE_TOO_LARGE => "polymorphic_object_too_large"
        case _ => "parse_error"
    }
    let message = match {
        case code == YJ_COMPACT_INVALID_UTF8 => "Invalid UTF-8 in JSON string"
        case code == YJ_COMPACT_MAX_DEPTH => "Maximum JSON depth exceeded"
        case code == YJ_COMPACT_DUPLICATE_KEY => "Duplicate object key"
        case code == YJ_COMPACT_OUT_OF_MEMORY => "yyjson allocation failed"
        case code == YJ_COMPACT_DOCUMENT_TOO_LARGE => "yyjson document is too large"
        case code == YJ_COMPACT_STRING_TOO_LARGE => "yyjson JSON string is too large"
        case code == YJ_COMPACT_VALUE_TOO_LARGE => "yyjson JSON value is too large"
        case _ => "Invalid JSON"
    }
    if (!includeLocation) { return JsonException(message, code: errorCode) }
    var line: Int64 = 1
    var column: Int64 = 1
    let limit = if (offset < 0) { 0 } else if (offset > bytes.size) { bytes.size } else { offset }
    for (index in 0..limit) {
        if (bytes[index] == b'\n') { line++; column = 1 } else { column++ }
    }
    JsonException("${message} at byte ${offset}", code: errorCode, byteOffset: offset,
        line: line, column: column)
}
