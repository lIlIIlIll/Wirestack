package yjson_yyjson

import std.convert.Parsable
import std.sync.*
import yjson.*

private let YJ_COMPACT_OK: Int32 = 0
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

private let YJ_COMPACT_NULL: Int32 = 0
private let YJ_COMPACT_BOOL: Int32 = 1
private let YJ_COMPACT_INT: Int32 = 2
private let YJ_COMPACT_NUMBER: Int32 = 3
private let YJ_COMPACT_STRING: Int32 = 4
private let YJ_COMPACT_ARRAY: Int32 = 5
private let YJ_COMPACT_OBJECT: Int32 = 6

private let YJ_YYJSON_DIRECT: UInt32 = 0u32
private let YJ_YYJSON_TRANSCODE: UInt32 = 1u32
private let YJ_YYJSON_REJECT_DUPLICATES: UInt32 = 1u32
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
foreign func YJ_Yyjson_Root(handle: UInt64, outNode: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_Kind(handle: UInt64, node: UInt64, outKind: CPointer<UInt32>): Int32
foreign func YJ_Yyjson_Size(handle: UInt64, node: UInt64, outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_GetInt(handle: UInt64, node: UInt64, outValue: CPointer<Int64>): Int32
foreign func YJ_Yyjson_GetBool(handle: UInt64, node: UInt64, outValue: CPointer<UInt32>): Int32
foreign func YJ_Yyjson_GetTextSize(handle: UInt64, node: UInt64,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_CopyText(handle: UInt64, node: UInt64, output: CPointer<UInt8>,
    outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_GetInlineTextSize(handle: UInt64, reference: UInt64,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_CopyInlineText(handle: UInt64, reference: UInt64,
    output: CPointer<UInt8>, outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_ArrayGet(handle: UInt64, node: UInt64, index: UInt64,
    outNode: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_ObjectEntry(handle: UInt64, node: UInt64, index: UInt64,
    outValueNode: CPointer<UInt64>, outInlineKind: CPointer<UInt32>,
    outInlinePayload: CPointer<UInt64>, outKeySize: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_CopyObjectKey(handle: UInt64, node: UInt64, index: UInt64,
    output: CPointer<UInt8>, outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
foreign func YJ_Yyjson_ObjectLookup(handle: UInt64, node: UInt64, key: CPointer<UInt8>,
    keyLength: UInt64, outValueNode: CPointer<UInt64>, outInlineKind: CPointer<UInt32>,
    outInlinePayload: CPointer<UInt64>, outFound: CPointer<UInt32>): Int32
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

func encodeYyjsonStreamTape(tape: Array<Byte>, config: JsonWriteOptions): Array<Byte> {
    let newlineText = if (config.indent.isEmpty()) { "" } else { "\n" }
    let newline = unsafe { newlineText.rawData() }
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
                UInt64(indent.size), if (config.indent.isEmpty()) { 0u32 } else { 1u32 },
                if (config.htmlSafe) { 1u32 } else { 0u32 }, config.maxDepth, config.maxOutputBytes,
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
                throw JsonException("Encoded JSON exceeds ${config.maxOutputBytes} bytes",
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

enum YyjsonCompactMode {
    | Direct
    | Transcode
}

enum YyjsonNumberStrategy {
    | SelectiveSource
    | SemanticDispatch
    | LegacyRaw
}

enum YyjsonLookupIndexMode {
    | Linear
    | Retained
    | Lazy
}

/// Qualification control for measuring semantic-pass fusion.
enum YyjsonValidationStrategy {
    | Fused
    | Separate
}

struct YyjsonCompactStorageStats {
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

struct YyjsonObjectEntry {
    let key: String
    let value: YyjsonJsonValue

    init(key: String, value: YyjsonJsonValue) {
        this.key = key
        this.value = value
    }
}

/// Supported opt-in yyjson 0.12.0 backed immutable native document.
///
/// The pure Cangjie backend remains the portable default. This type is for
/// callers that retain the native DOM and use coarse lookup, traversal, or
/// serialization operations; it is not an acceleration path for
/// `JsonNode.parse`, and materialization reparses serialized output.
///
/// Internal resource owner for the qualified yyjson backend. Immutable reads
/// may run concurrently; close is exclusive and every retained view fails
/// closed after the close point.
class YyjsonCompactJsonDocument <: Resource {
    private var handle: UInt64
    private let rootNode: UInt64
    private let selectedMode: YyjsonCompactMode
    private let accessLock = ReadWriteLock()

    private init(handle: UInt64, rootNode: UInt64, mode: YyjsonCompactMode) {
        this.handle = handle
        this.rootNode = rootNode
        selectedMode = mode
    }

    public static func parse(bytes: Array<Byte>,
        config!: JsonReadOptions = JsonReadOptions.defaults,
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
                YJ_Yyjson_ParseWithLimits(inputHandle.pointer, bytes.size, flags,
                    config.maxDepth, nativeMode, config.maxInputBytes, config.maxStringBytes,
                    config.maxBufferedValueBytes, handleHandle.pointer,
                    errorHandle.pointer, offsetHandle.pointer)
            } finally {
                releaseArrayRawData(offsetHandle)
                releaseArrayRawData(errorHandle)
                releaseArrayRawData(handleHandle)
                releaseArrayRawData(inputHandle)
            }
        }
        if (status != YJ_COMPACT_OK) {
            throw yyjsonParseError(bytes, Int32(outError[0]), outOffset[0])
        }
        let root = Array<UInt64>(1, repeat: 0u64)
        let rootStatus = unsafe {
            let rootHandle = acquireArrayRawData(root)
            try { YJ_Yyjson_Root(outHandle[0], rootHandle.pointer) }
            finally { releaseArrayRawData(rootHandle) }
        }
        if (rootStatus != YJ_COMPACT_OK) {
            unsafe { YJ_Yyjson_Free(outHandle[0]) }
            throw JsonException("yyjson root lookup failed", code: "backend_contract")
        }
        YyjsonCompactJsonDocument(outHandle[0], root[0], mode)
    }

    public func mode(): YyjsonCompactMode { selectedMode }
    public func isClosed(): Bool { synchronized(accessLock.readLock) { handle == 0u64 } }

    public func close(): Unit {
        synchronized(accessLock.writeLock) {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                unsafe { YJ_Yyjson_Free(current) }
            }
        }
    }

    ~init() {
        // Views retain this owner; an unreachable document has no concurrent
        // operation. Avoid blocking a GC helper during finalization.
        if (handle != 0u64) {
            let current = handle
            handle = 0u64
            unsafe { YJ_Yyjson_Free(current) }
        }
    }

    public func root(): JsonValueView {
        synchronized(accessLock.readLock) {
            let _ = requireOpenLocked()
            YyjsonJsonValue(this, rootNode)
        }
    }

    func ensureOpen(): Unit {
        synchronized(accessLock.readLock) { let _ = requireOpenLocked() }
    }

    public func traversalChecksum(): Int64 {
        @OverflowWrapping
        func convert(value: UInt64): Int64 { Int64(value) }
        synchronized(accessLock.readLock) {
            convert(unsafe { YJ_Yyjson_TraversalChecksum(requireOpenLocked()) })
        }
    }

    func kindAt(node: UInt64): Int32 {
        synchronized(accessLock.readLock) {
            let out = Array<UInt32>(1, repeat: 0u32)
            let status = unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Yyjson_Kind(requireOpenLocked(), node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
            checkStatus(status)
            Int32(out[0])
        }
    }

    func sizeAt(node: UInt64): Int64 {
        synchronized(accessLock.readLock) {
            let out = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Yyjson_Size(requireOpenLocked(), node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
            checkStatus(status)
            Int64(out[0])
        }
    }

    func arrayAt(node: UInt64, index: Int64): Option<YyjsonJsonValue> {
        if (index < 0) { return None<YyjsonJsonValue> }
        synchronized(accessLock.readLock) {
            let out = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let outHandle = acquireArrayRawData(out)
                try {
                    YJ_Yyjson_ArrayGet(requireOpenLocked(), node, UInt64(index),
                        outHandle.pointer)
                } finally { releaseArrayRawData(outHandle) }
            }
            if (status == YJ_COMPACT_BOUNDS_ERROR) { return None<YyjsonJsonValue> }
            checkStatus(status)
            Some(YyjsonJsonValue(this, out[0]))
        }
    }

    func objectAt(node: UInt64, name: String): Option<YyjsonJsonValue> {
        synchronized(accessLock.readLock) {
            let bytes = unsafe { name.rawData() }
            let outNode = Array<UInt64>(1, repeat: 0u64)
            let outKind = Array<UInt32>(1, repeat: 0xFFFFFFFFu32)
            let outPayload = Array<UInt64>(1, repeat: 0u64)
            let found = Array<UInt32>(1, repeat: 0u32)
            let status = unsafe {
                let bytesHandle = acquireArrayRawData(bytes)
                let nodeHandle = acquireArrayRawData(outNode)
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let foundHandle = acquireArrayRawData(found)
                try {
                    YJ_Yyjson_ObjectLookup(requireOpenLocked(), node,
                        bytesHandle.pointer, UInt64(bytes.size), nodeHandle.pointer,
                        kindHandle.pointer, payloadHandle.pointer, foundHandle.pointer)
                } finally {
                    releaseArrayRawData(foundHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                    releaseArrayRawData(nodeHandle)
                    releaseArrayRawData(bytesHandle)
                }
            }
            checkStatus(status)
            if (found[0] == 0u32) { None<YyjsonJsonValue> }
            else { Some(valueFrom(outNode[0], outKind[0], outPayload[0])) }
        }
    }

    func objectEntryAt(node: UInt64, index: Int64): Option<YyjsonObjectEntry> {
        if (index < 0) { return None<YyjsonObjectEntry> }
        synchronized(accessLock.readLock) {
            let outNode = Array<UInt64>(1, repeat: 0u64)
            let outKind = Array<UInt32>(1, repeat: 0xFFFFFFFFu32)
            let outPayload = Array<UInt64>(1, repeat: 0u64)
            let keySize = Array<UInt64>(1, repeat: 0u64)
            var status = unsafe {
                let nodeHandle = acquireArrayRawData(outNode)
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let sizeHandle = acquireArrayRawData(keySize)
                try {
                    YJ_Yyjson_ObjectEntry(requireOpenLocked(), node, UInt64(index),
                        nodeHandle.pointer, kindHandle.pointer, payloadHandle.pointer,
                        sizeHandle.pointer)
                } finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                    releaseArrayRawData(nodeHandle)
                }
            }
            if (status == YJ_COMPACT_BOUNDS_ERROR) { return None<YyjsonObjectEntry> }
            checkStatus(status)
            let keyBytes = Array<Byte>(Int64(keySize[0]), repeat: 0)
            let written = Array<UInt64>(1, repeat: 0u64)
            status = unsafe {
                let keyHandle = acquireArrayRawData(keyBytes)
                let writtenHandle = acquireArrayRawData(written)
                try {
                    YJ_Yyjson_CopyObjectKey(requireOpenLocked(), node, UInt64(index),
                        keyHandle.pointer, UInt64(keyBytes.size), writtenHandle.pointer)
                } finally {
                    releaseArrayRawData(writtenHandle)
                    releaseArrayRawData(keyHandle)
                }
            }
            checkStatus(status)
            Some(YyjsonObjectEntry(unsafe { String.fromUtf8Unchecked(keyBytes) },
                valueFrom(outNode[0], outKind[0], outPayload[0])))
        }
    }

    func objectValueAt(node: UInt64, index: Int64): Option<YyjsonJsonValue> {
        if (index < 0) { return None<YyjsonJsonValue> }
        synchronized(accessLock.readLock) {
            let outNode = Array<UInt64>(1, repeat: 0u64)
            let outKind = Array<UInt32>(1, repeat: 0xFFFFFFFFu32)
            let outPayload = Array<UInt64>(1, repeat: 0u64)
            let keySize = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let nodeHandle = acquireArrayRawData(outNode)
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let sizeHandle = acquireArrayRawData(keySize)
                try {
                    YJ_Yyjson_ObjectEntry(requireOpenLocked(), node, UInt64(index),
                        nodeHandle.pointer, kindHandle.pointer, payloadHandle.pointer,
                        sizeHandle.pointer)
                } finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                    releaseArrayRawData(nodeHandle)
                }
            }
            if (status == YJ_COMPACT_BOUNDS_ERROR) { return None<YyjsonJsonValue> }
            checkStatus(status)
            Some(valueFrom(outNode[0], outKind[0], outPayload[0]))
        }
    }

    func intAt(node: UInt64): Int64 {
        synchronized(accessLock.readLock) {
            let out = Array<Int64>(1, repeat: 0)
            let status = unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Yyjson_GetInt(requireOpenLocked(), node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
            checkStatus(status)
            out[0]
        }
    }

    func boolAt(node: UInt64): Bool {
        synchronized(accessLock.readLock) {
            let out = Array<UInt32>(1, repeat: 0u32)
            let status = unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Yyjson_GetBool(requireOpenLocked(), node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
            checkStatus(status)
            out[0] != 0u32
        }
    }

    func textAt(node: UInt64): String {
        synchronized(accessLock.readLock) {
            let size = Array<UInt64>(1, repeat: 0u64)
            var status = unsafe {
                let sizeHandle = acquireArrayRawData(size)
                try { YJ_Yyjson_GetTextSize(requireOpenLocked(), node, sizeHandle.pointer) }
                finally { releaseArrayRawData(sizeHandle) }
            }
            checkStatus(status)
            let bytes = Array<Byte>(Int64(size[0]), repeat: 0)
            let written = Array<UInt64>(1, repeat: 0u64)
            status = unsafe {
                let bytesHandle = acquireArrayRawData(bytes)
                let writtenHandle = acquireArrayRawData(written)
                try {
                    YJ_Yyjson_CopyText(requireOpenLocked(), node, bytesHandle.pointer,
                        UInt64(bytes.size), writtenHandle.pointer)
                } finally {
                    releaseArrayRawData(writtenHandle)
                    releaseArrayRawData(bytesHandle)
                }
            }
            checkStatus(status)
            unsafe { String.fromUtf8Unchecked(bytes) }
        }
    }

    func inlineTextAt(reference: UInt64): String {
        synchronized(accessLock.readLock) {
            let size = Array<UInt64>(1, repeat: 0u64)
            var status = unsafe {
                let sizeHandle = acquireArrayRawData(size)
                try {
                    YJ_Yyjson_GetInlineTextSize(requireOpenLocked(), reference,
                        sizeHandle.pointer)
                } finally { releaseArrayRawData(sizeHandle) }
            }
            checkStatus(status)
            let bytes = Array<Byte>(Int64(size[0]), repeat: 0)
            let written = Array<UInt64>(1, repeat: 0u64)
            status = unsafe {
                let bytesHandle = acquireArrayRawData(bytes)
                let writtenHandle = acquireArrayRawData(written)
                try {
                    YJ_Yyjson_CopyInlineText(requireOpenLocked(), reference,
                        bytesHandle.pointer, UInt64(bytes.size), writtenHandle.pointer)
                } finally {
                    releaseArrayRawData(writtenHandle)
                    releaseArrayRawData(bytesHandle)
                }
            }
            checkStatus(status)
            unsafe { String.fromUtf8Unchecked(bytes) }
        }
    }

    private func valueFrom(node: UInt64, inlineKind: UInt32,
        inlinePayload: UInt64): YyjsonJsonValue {
        if (inlineKind == 0xFFFFFFFFu32) { YyjsonJsonValue(this, node) }
        else { YyjsonJsonValue(this, 0u64, Int32(inlineKind), inlinePayload) }
    }

    public func storageStats(): YyjsonCompactStorageStats {
        synchronized(accessLock.readLock) {
            let values = Array<UInt64>(36, repeat: 0u64)
            let status = unsafe {
                let valuesHandle = acquireArrayRawData(values)
                try { YJ_Yyjson_Stats(requireOpenLocked(), valuesHandle.pointer, 36u64) }
                finally { releaseArrayRawData(valuesHandle) }
            }
            checkStatus(status)
            YyjsonCompactStorageStats(values)
        }
    }

    public func toBytes(): Array<Byte> {
        let buffer = Array<UInt64>(1, repeat: 0u64)
        let size = Array<UInt64>(1, repeat: 0u64)
        let status = synchronized(accessLock.readLock) {
            unsafe {
                let bufferHandle = acquireArrayRawData(buffer)
                let sizeHandle = acquireArrayRawData(size)
                try {
                    YJ_Yyjson_SerializeAlloc(requireOpenLocked(), bufferHandle.pointer,
                        sizeHandle.pointer)
                } finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(bufferHandle)
                }
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
        let status = synchronized(accessLock.readLock) {
            unsafe {
                let bufferHandle = acquireArrayRawData(buffer)
                let sizeHandle = acquireArrayRawData(size)
                try {
                    YJ_Yyjson_ExportTapeAlloc(requireOpenLocked(), bufferHandle.pointer,
                        sizeHandle.pointer)
                } finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(bufferHandle)
                }
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

    func exportRootStreamTape(node: UInt64, inlineKind: Int32): Option<Array<Byte>> {
        if (inlineKind >= 0 || node != rootNode) {
            ensureOpen()
            return None<Array<Byte>>
        }
        Some(exportStreamTape())
    }

    public func toString(): String { unsafe { String.fromUtf8Unchecked(toBytes()) } }

    public func materialize(): JsonNode { materializeBulk(100000) }

    public func materialize(maxNodes: Int64): JsonNode { materializeBulk(maxNodes) }

    private func materializeBulk(maxNodes: Int64): JsonNode {
        let reader = BackendTapeReaderV1(exportStreamTape())
        let value = reader.readNode(maxNodes)
        reader.expectEnd()
        value
    }

    func materializeViaSerialization(): JsonNode { JsonNode.parse(toBytes()) }

    private func requireOpenLocked(): UInt64 {
        if (handle == 0u64) {
            throw JsonException("yyjson document is closed", code: "resource_closed")
        }
        handle
    }

    private func checkStatus(status: Int32): Unit {
        if (status == YJ_COMPACT_OK) { return }
        match {
            case status == YJ_COMPACT_CLOSED =>
                throw JsonException("yyjson document is closed", code: "resource_closed")
            case status == YJ_COMPACT_TYPE_ERROR =>
                throw JsonException("yyjson value type mismatch", code: "type_mismatch")
            case status == YJ_COMPACT_BOUNDS_ERROR =>
                throw JsonException("yyjson value index is out of bounds", code: "index_out_of_bounds")
            case status == YJ_COMPACT_OUT_OF_MEMORY => throw JsonException("yyjson allocation failed", code: "out_of_memory")
            case _ => throw JsonException("yyjson compact operation failed (${status})")
        }
    }
}

struct YyjsonJsonValue <: JsonValueView {
    private let document: YyjsonCompactJsonDocument
    private let node: UInt64
    private let inlineKind: Int32
    private let inlinePayload: UInt64

    init(document: YyjsonCompactJsonDocument, node: UInt64) {
        this.document = document
        this.node = node
        inlineKind = -1
        inlinePayload = 0u64
    }

    init(document: YyjsonCompactJsonDocument, node: UInt64,
        inlineKind: Int32, inlinePayload: UInt64) {
        this.document = document
        this.node = node
        this.inlineKind = inlineKind
        this.inlinePayload = inlinePayload
    }

    public func kind(): JsonKind {
        document.ensureOpen()
        yyjsonKind(code())
    }

    public func size(): Int64 {
        if (inlineKind >= 0) {
            document.ensureOpen()
            0
        } else {
            document.sizeAt(node)
        }
    }

    public func element(index: Int64): Option<JsonValueView> {
        if (inlineKind >= 0) {
            document.ensureOpen()
            return None<JsonValueView>
        }
        match (document.arrayAt(node, index)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func member(name: String): Option<JsonValueView> {
        if (inlineKind >= 0) {
            document.ensureOpen()
            return None<JsonValueView>
        }
        match (document.objectAt(node, name)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func memberName(index: Int64): String {
        if (inlineKind >= 0) {
            document.ensureOpen()
            throw JsonException("Expected object value", code: "type_mismatch")
        }
        document.objectEntryAt(node, index).getOrThrow({ =>
            JsonException("Object member index is out of bounds", code: "index_out_of_bounds")
        }).key
    }

    public func memberValue(index: Int64): JsonValueView {
        if (inlineKind >= 0) {
            document.ensureOpen()
            throw JsonException("Expected object value", code: "type_mismatch")
        }
        document.objectValueAt(node, index).getOrThrow({ =>
            JsonException("Object member index is out of bounds", code: "index_out_of_bounds")
        })
    }

    public func asBool(): Bool {
        if (inlineKind == YJ_COMPACT_BOOL) {
            document.ensureOpen()
            inlinePayload != 0u64
        } else {
            document.boolAt(node)
        }
    }

    public func asString(): String {
        if (code() != YJ_COMPACT_STRING) {
            throw JsonException("Expected string value", code: "type_mismatch")
        }
        if (inlineKind >= 0) { document.inlineTextAt(inlinePayload) }
        else { document.textAt(node) }
    }

    public func asInt64(): Int64 {
        if (inlineKind == YJ_COMPACT_INT) {
            document.ensureOpen()
            yyjsonBitsToInt64(inlinePayload)
        } else if (code() == YJ_COMPACT_INT) {
            document.intAt(node)
        } else if (code() == YJ_COMPACT_NUMBER) {
            try { Int64.parse(asNumberText()) } catch (_: Exception) {
                throw JsonException("JSON number is outside Int64 range",
                    code: "number_out_of_range")
            }
        } else {
            throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asUInt64(): UInt64 {
        let text = asNumberText()
        try { UInt64.parse(text) } catch (_: Exception) {
            throw JsonException("JSON number is outside UInt64 range",
                code: "number_out_of_range")
        }
    }

    public func asFloat64(): Float64 {
        let text = asNumberText()
        try { Float64.parse(text) } catch (_: Exception) {
            throw JsonException("Expected number value", code: "type_mismatch")
        }
    }

    public func asNumberText(): String {
        let valueKind = code()
        if (valueKind == YJ_COMPACT_INT) {
            if (inlineKind >= 0) {
                document.ensureOpen()
                return yyjsonBitsToInt64(inlinePayload).toString()
            }
            return document.intAt(node).toString()
        }
        if (valueKind != YJ_COMPACT_NUMBER) {
            throw JsonException("Expected number value", code: "type_mismatch")
        }
        if (inlineKind >= 0) { document.inlineTextAt(inlinePayload) }
        else { document.textAt(node) }
    }

    public func materialize(): JsonNode {
        materializeYyjsonValue(this, 100000)
    }

    public func materialize(maxNodes: Int64): JsonNode {
        materializeYyjsonValue(this, maxNodes)
    }

    func exportRootStreamTape(): Option<Array<Byte>> {
        document.exportRootStreamTape(node, inlineKind)
    }

    private func code(): Int32 {
        if (inlineKind >= 0) {
            document.ensureOpen()
            inlineKind
        } else {
            document.kindAt(node)
        }
    }
}

private class YyjsonMaterializationBudget {
    private var remaining: Int64

    init(maxNodes: Int64) {
        if (maxNodes <= 0) {
            throw IllegalArgumentException("maxNodes must be positive")
        }
        remaining = maxNodes
    }

    func visit(depth: Int64): Unit {
        if (depth > 256) {
            throw JsonException("Maximum materialization depth exceeded",
                code: "max_depth")
        }
        if (remaining <= 0) {
            throw JsonException("Materialization work limit exceeded",
                code: "work_limit_exceeded")
        }
        remaining--
    }
}

private func materializeYyjsonValue(value: JsonValueView, maxNodes: Int64): JsonNode {
    let budget = YyjsonMaterializationBudget(maxNodes)
    func copy(current: JsonValueView, depth: Int64): JsonNode {
        budget.visit(depth)
        match (current.kind()) {
            case JsonKind.Null => JsonNode.nullValue
            case JsonKind.Boolean => JsonNode.boolean(current.asBool())
            case JsonKind.Number => JsonNode.number(current.asNumberText())
            case JsonKind.String => JsonNode.string(current.asString())
            case JsonKind.Array =>
                let result = JsonArray()
                for (index in 0..current.size()) {
                    result.add(copy(current.element(index).getOrThrow({ =>
                        JsonException("Array view changed during materialization",
                            code: "view_contract")
                    }), depth + 1))
                }
                result
            case JsonKind.Object =>
                let result = JsonObject()
                for (index in 0..current.size()) {
                    result.put(current.memberName(index),
                        copy(current.memberValue(index), depth + 1))
                }
                result
        }
    }
    copy(value, 0)
}

@OverflowWrapping
private func yyjsonBitsToInt64(value: UInt64): Int64 { Int64(value) }

private func yyjsonKind(code: Int32): JsonKind {
    match {
        case code == YJ_COMPACT_NULL => JsonKind.Null
        case code == YJ_COMPACT_BOOL => JsonKind.Boolean
        case code == YJ_COMPACT_INT || code == YJ_COMPACT_NUMBER => JsonKind.Number
        case code == YJ_COMPACT_STRING => JsonKind.String
        case code == YJ_COMPACT_ARRAY => JsonKind.Array
        case code == YJ_COMPACT_OBJECT => JsonKind.Object
        case _ => throw JsonException("Unknown yyjson value kind", code: "backend_contract")
    }
}

private func yyjsonParseError(bytes: Array<Byte>, code: Int32, offset: Int64): JsonException {
    let errorCode = match {
        case code == YJ_COMPACT_MAX_DEPTH => "max_depth"
        case code == YJ_COMPACT_DUPLICATE_KEY => "duplicate_key"
        case code == YJ_COMPACT_OUT_OF_MEMORY => "out_of_memory"
        case code == YJ_COMPACT_DOCUMENT_TOO_LARGE => "document_too_large"
        case code == YJ_COMPACT_STRING_TOO_LARGE => "string_too_large"
        case code == YJ_COMPACT_VALUE_TOO_LARGE => "buffered_value_too_large"
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
    var line: Int64 = 1
    var column: Int64 = 1
    let limit = if (offset < 0) { 0 } else if (offset > bytes.size) { bytes.size } else { offset }
    for (index in 0..limit) {
        if (bytes[index] == b'\n') { line++; column = 1 } else { column++ }
    }
    JsonException("${message} at byte ${offset}", code: errorCode,
        location: Some(JsonLocation(offset, line, column)))
}
