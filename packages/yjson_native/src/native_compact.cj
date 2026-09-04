package yjson_native

import std.convert.Parsable
import std.sync.*
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

private let YJ_COMPACT_NULL: Int32 = 0
private let YJ_COMPACT_BOOL: Int32 = 1
private let YJ_COMPACT_INT: Int32 = 2
private let YJ_COMPACT_NUMBER: Int32 = 3
private let YJ_COMPACT_STRING: Int32 = 4
private let YJ_COMPACT_ARRAY: Int32 = 5
private let YJ_COMPACT_OBJECT: Int32 = 6

private let YJ_COMPACT_REJECT_DUPLICATES: UInt32 = 1u32
private let YJ_COMPACT_MATERIALIZE_SOURCE: UInt32 = 4u32
private let YJ_COMPACT_DUPLICATE_LOAD_50: UInt32 = 8u32
private let YJ_COMPACT_DUPLICATE_LOAD_625: UInt32 = 16u32
private let YJ_COMPACT_DUPLICATE_LOAD_875: UInt32 = 32u32
private let YJ_COMPACT_DUPLICATE_PRESIZE: UInt32 = 64u32
private let YJ_COMPACT_DUPLICATE_STATS: UInt32 = 128u32

enum NativeCompactSourceOwnership {
    | CopySource
    | MaterializeSlices
}

enum NativeCompactDuplicateStrategy {
    | Baseline
    | Load50
    | Load625
    | Load875
    | Presized
    | PresizedLoad625
}

foreign func YJ_Compact_Parse(input: CPointer<UInt8>, length: Int64, flags: UInt32,
    maxDepth: Int64, outHandle: CPointer<UInt64>, outRoot: CPointer<UInt32>,
    outErrorCode: CPointer<UInt32>, outErrorOffset: CPointer<Int64>): Int32
foreign func YJ_Compact_ParseWithLimits(input: CPointer<UInt8>, length: Int64,
    flags: UInt32, maxDepth: Int64, maxBytes: Int64, maxStringBytes: Int64,
    maxValueBytes: Int64, outHandle: CPointer<UInt64>, outRoot: CPointer<UInt32>,
    outErrorCode: CPointer<UInt32>, outErrorOffset: CPointer<Int64>): Int32
foreign func YJ_Compact_Free(handle: UInt64): Unit
@FastNative
foreign func YJ_Compact_Kind(handle: UInt64, node: UInt32, outKind: CPointer<UInt32>): Int32
@FastNative
foreign func YJ_Compact_Size(handle: UInt64, node: UInt32, outSize: CPointer<UInt64>): Int32
@FastNative
foreign func YJ_Compact_GetInt(handle: UInt64, node: UInt32, outValue: CPointer<Int64>): Int32
@FastNative
foreign func YJ_Compact_GetBool(handle: UInt64, node: UInt32, outValue: CPointer<UInt32>): Int32
@FastNative
foreign func YJ_Compact_GetTextSize(handle: UInt64, node: UInt32, outSize: CPointer<UInt64>): Int32
foreign func YJ_Compact_CopyText(handle: UInt64, node: UInt32, output: CPointer<UInt8>,
    outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
@FastNative
foreign func YJ_Compact_ArrayGet(handle: UInt64, node: UInt32, index: UInt64,
    outNode: CPointer<UInt32>): Int32
@FastNative
foreign func YJ_Compact_ObjectEntry(handle: UInt64, node: UInt32, index: UInt64,
    outValueKind: CPointer<UInt32>, outValuePayload: CPointer<UInt64>,
    outKeySize: CPointer<UInt64>): Int32
foreign func YJ_Compact_CopyObjectKey(handle: UInt64, node: UInt32, index: UInt64,
    output: CPointer<UInt8>, outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
foreign func YJ_Compact_ObjectLookup(handle: UInt64, node: UInt32, key: CPointer<UInt8>,
    keyLength: UInt64, outValueKind: CPointer<UInt32>, outValuePayload: CPointer<UInt64>,
    outFound: CPointer<UInt32>): Int32
@FastNative
foreign func YJ_Compact_GetStringRefSize(handle: UInt64, stringRef: UInt64,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Compact_CopyStringRef(handle: UInt64, stringRef: UInt64,
    output: CPointer<UInt8>, outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32
foreign func YJ_Compact_TraversalChecksum(handle: UInt64): UInt64
foreign func YJ_Compact_Serialize(handle: UInt64, output: CPointer<UInt8>,
    outputCapacity: UInt64, outWritten: CPointer<UInt64>): Int32

foreign func YJ_Compact_SerializeAlloc(handle: UInt64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Compact_ExportTapeAlloc(handle: UInt64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>): Int32
foreign func YJ_Stream_EncodeTapeAlloc(tape: CPointer<UInt8>, tapeLength: UInt64,
    newline: CPointer<UInt8>, newlineLength: UInt64, indent: CPointer<UInt8>,
    indentLength: UInt64, useSpaceAfterSeparators: UInt32, htmlSafe: UInt32,
    maxDepth: Int64, maxBytes: Int64, outBufferHandle: CPointer<UInt64>,
    outSize: CPointer<UInt64>, outErrorCode: CPointer<UInt32>): Int32

foreign func YJ_Compact_CopyOwnedBuffer(bufferHandle: UInt64, output: CPointer<UInt8>,
    outputCapacity: UInt64): Int32

foreign func YJ_Compact_FreeOwnedBuffer(bufferHandle: UInt64): Unit
@FastNative
foreign func YJ_Compact_Stats(handle: UInt64, stats: CPointer<UInt64>, capacity: UInt64): Int32
@FastNative
foreign func YJ_Compact_DuplicateStats(handle: UInt64, stats: CPointer<UInt64>, capacity: UInt64): Int32

func encodeNativeStreamTape(tape: Array<Byte>, config: JsonWriteOptions): Array<Byte> {
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
            YJ_Stream_EncodeTapeAlloc(tapeHandle.pointer, UInt64(tape.size),
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
                throw JsonException("Native stream encode allocation failed", code: "out_of_memory")
            case _ => throw JsonException("Invalid JSON stream tape", code: "codec_contract")
        }
    }
    let output = Array<Byte>(Int64(size[0]), repeat: 0)
    try {
        let copyStatus = unsafe {
            let outputHandle = acquireArrayRawData(output)
            try { YJ_Compact_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
            finally { releaseArrayRawData(outputHandle) }
        }
        if (copyStatus != YJ_COMPACT_OK) {
            throw JsonException("Native stream output copy failed", code: "codec_contract")
        }
        output
    } finally {
        unsafe { YJ_Compact_FreeOwnedBuffer(buffer[0]) }
    }
}

/// Native-owned memory counters. `persistentCommitted` includes C-owned input,
/// POD store capacities, and arena blocks; it is not Cangjie heap usage or RSS.
struct NativeCompactStorageStats {
    public let sourceBytes: UInt64
    public let persistentUsed: UInt64
    public let persistentCommitted: UInt64
    public let arenaUsed: UInt64
    public let arenaCommitted: UInt64
    public let scratchCurrent: UInt64
    public let scratchPeak: UInt64
    public let duplicateScratchPeak: UInt64
    public let nodes: UInt64
    public let objectFields: UInt64
    public let arrayEntries: UInt64
    public let stringRefs: UInt64

    init(values: Array<UInt64>) {
        sourceBytes = values[0]
        persistentUsed = values[1]
        persistentCommitted = values[2]
        arenaUsed = values[3]
        arenaCommitted = values[4]
        scratchCurrent = values[5]
        scratchPeak = values[6]
        duplicateScratchPeak = values[7]
        nodes = values[8]
        objectFields = values[9]
        arrayEntries = values[10]
        stringRefs = values[11]
    }
}

struct NativeCompactDuplicateStats {
    public let lookups: UInt64
    public let inserts: UInt64
    public let probes: UInt64
    public let exactEqualities: UInt64
    public let maxProbe: UInt64
    public let growCount: UInt64
    public let rehashedEntries: UInt64
    public let finalCapacity: UInt64
    public let largestCapacity: UInt64
    public let p50Probe: UInt64
    public let p95Probe: UInt64
    public let p99Probe: UInt64
    public let occupied: UInt64
    public let loadPpm: UInt64
    public let presized: Bool

    init(values: Array<UInt64>) {
        lookups = values[0]
        inserts = values[1]
        probes = values[2]
        exactEqualities = values[3]
        maxProbe = values[4]
        growCount = values[5]
        rehashedEntries = values[6]
        finalCapacity = values[7]
        largestCapacity = values[8]
        p50Probe = values[9]
        p95Probe = values[10]
        p99Probe = values[11]
        occupied = values[12]
        loadPpm = values[13]
        presized = values[14] != 0u64
    }
}

/// One object entry returned as a document-bound value view.
struct NativeCompactObjectEntry {
    public let key: String
    public let value: NativeCompactJsonValue

    init(key: String, value: NativeCompactJsonValue) {
        this.key = key
        this.value = value
    }
}

/// Supported opt-in immutable Compact DOM backed entirely by C-owned memory.
///
/// Parsing is one coarse FFI call. Concurrent reads are supported. Explicit
/// close is idempotent and waits for active reads; each racing read either
/// completes or fails with resource_closed, without accessing released memory.
class NativeCompactJsonDocument <: Resource {
    private var handle: UInt64
    private let rootNode: UInt32
    private let accessLock = ReadWriteLock()

    private init(handle: UInt64, rootNode: UInt32) {
        this.handle = handle
        this.rootNode = rootNode
    }

    public static func parse(bytes: Array<Byte>,
        config!: JsonReadOptions = JsonReadOptions.defaults,
        sourceOwnership!: NativeCompactSourceOwnership = NativeCompactSourceOwnership.CopySource,
        duplicateStrategy!: NativeCompactDuplicateStrategy = NativeCompactDuplicateStrategy.Baseline,
        collectDuplicateStats!: Bool = false
    ): NativeCompactJsonDocument {
        var flags: UInt32 = 0u32
        match (config.duplicateKeyPolicy) {
            case JsonDuplicateKeyPolicy.Reject => flags |= YJ_COMPACT_REJECT_DUPLICATES
            case _ => ()
        }
        match (sourceOwnership) {
            case NativeCompactSourceOwnership.MaterializeSlices => flags |= YJ_COMPACT_MATERIALIZE_SOURCE
            case _ => ()
        }
        match (duplicateStrategy) {
            case NativeCompactDuplicateStrategy.Load50 => flags |= YJ_COMPACT_DUPLICATE_LOAD_50
            case NativeCompactDuplicateStrategy.Load625 => flags |= YJ_COMPACT_DUPLICATE_LOAD_625
            case NativeCompactDuplicateStrategy.Load875 => flags |= YJ_COMPACT_DUPLICATE_LOAD_875
            case NativeCompactDuplicateStrategy.Presized => flags |= YJ_COMPACT_DUPLICATE_PRESIZE
            case NativeCompactDuplicateStrategy.PresizedLoad625 =>
                flags |= YJ_COMPACT_DUPLICATE_PRESIZE | YJ_COMPACT_DUPLICATE_LOAD_625
            case _ => ()
        }
        if (collectDuplicateStats) { flags |= YJ_COMPACT_DUPLICATE_STATS }
        let outHandle = Array<UInt64>(1, repeat: 0u64)
        let outRoot = Array<UInt32>(1, repeat: 0u32)
        let outError = Array<UInt32>(1, repeat: 0u32)
        let outOffset = Array<Int64>(1, repeat: -1)
        var status: Int32 = YJ_COMPACT_PARSE_ERROR
        unsafe {
            let inputHandle = acquireArrayRawData(bytes)
            let handleHandle = acquireArrayRawData(outHandle)
            let rootHandle = acquireArrayRawData(outRoot)
            let errorHandle = acquireArrayRawData(outError)
            let offsetHandle = acquireArrayRawData(outOffset)
            try {
                status = YJ_Compact_ParseWithLimits(inputHandle.pointer, bytes.size, flags,
                    config.maxDepth, config.maxInputBytes, config.maxStringBytes,
                    config.maxBufferedValueBytes, handleHandle.pointer, rootHandle.pointer,
                    errorHandle.pointer, offsetHandle.pointer)
            } finally {
                releaseArrayRawData(offsetHandle)
                releaseArrayRawData(errorHandle)
                releaseArrayRawData(rootHandle)
                releaseArrayRawData(handleHandle)
                releaseArrayRawData(inputHandle)
            }
        }
        if (status != YJ_COMPACT_OK) {
            throw nativeCompactParseError(bytes, Int32(outError[0]), outOffset[0])
        }
        NativeCompactJsonDocument(outHandle[0], outRoot[0])
    }

    public func isClosed(): Bool {
        let lock = accessLock.readLock
        lock.lock()
        try { handle == 0u64 } finally { lock.unlock() }
    }

    public func close(): Unit {
        let lock = accessLock.writeLock
        lock.lock()
        try {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                unsafe { YJ_Compact_Free(current) }
            }
        } finally {
            lock.unlock()
        }
    }

    ~init() {
        // A view retains this owner, so finalization implies no operation can
        // still reach the handle. Do not block a GC helper on a lock here.
        if (handle != 0u64) {
            let current = handle
            handle = 0u64
            unsafe { YJ_Compact_Free(current) }
        }
    }

    public func root(): NativeCompactJsonValue {
        withOpen({ _ => NativeCompactJsonValue(this, rootNode) })
    }

    public func traversalChecksum(): Int64 {
        @OverflowWrapping
        func convert(value: UInt64): Int64 { Int64(value) }
        withOpen({ current => convert(unsafe { YJ_Compact_TraversalChecksum(current) }) })
    }

    public func storageStats(): NativeCompactStorageStats {
        withOpen({ current =>
            let values = Array<UInt64>(12, repeat: 0u64)
            let status = unsafe {
                let valuesHandle = acquireArrayRawData(values)
                try { YJ_Compact_Stats(current, valuesHandle.pointer, 12u64) }
                finally { releaseArrayRawData(valuesHandle) }
            }
            checkStatus(status)
            NativeCompactStorageStats(values)
        })
    }

    public func duplicateStats(): NativeCompactDuplicateStats {
        withOpen({ current =>
            let values = Array<UInt64>(16, repeat: 0u64)
            let status = unsafe {
                let valuesHandle = acquireArrayRawData(values)
                try { YJ_Compact_DuplicateStats(current, valuesHandle.pointer, 16u64) }
                finally { releaseArrayRawData(valuesHandle) }
            }
            checkStatus(status)
            NativeCompactDuplicateStats(values)
        })
    }

    public func materialize(): JsonNode { materializeBulk(maxNodes: 100000) }

    public func materialize(maxNodes: Int64): JsonNode {
        materializeBulk(maxNodes: maxNodes)
    }

    /// One native export plus one Cangjie bulk construction. No per-node FFI.
    func materializeBulk(maxNodes!: Int64 = 100000): JsonNode {
        let reader = BackendTapeReaderV1(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_ExportTapeAlloc(handle, buffer, size) }
        }))
        let value = reader.readNode(maxNodes)
        reader.expectEnd()
        value
    }

    func exportStreamTape(): Array<Byte> {
        copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_ExportTapeAlloc(handle, buffer, size) }
        })
    }

    func exportRootStreamTape(node: UInt32, inlineKind: Int32): Option<Array<Byte>> {
        if (inlineKind >= 0 || node != rootNode) {
            ensureOpen()
            return None<Array<Byte>>
        }
        Some(exportStreamTape())
    }

    /// Control path for the bulk materialization experiment.
    func materializeViaSerialization(): JsonNode {
        JsonNode.parse(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_SerializeAlloc(handle, buffer, size) }
        }))
    }

    public func toString(): String {
        unsafe { String.fromUtf8Unchecked(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_SerializeAlloc(handle, buffer, size) }
        })) }
    }

    private func copyOwnedBuffer(allocate: (UInt64, CPointer<UInt64>, CPointer<UInt64>) -> Int32): Array<Byte> {
        let buffer = Array<UInt64>(1, repeat: 0u64)
        let size = Array<UInt64>(1, repeat: 0u64)
        let status = withOpen({ current =>
            unsafe {
                let bufferHandle = acquireArrayRawData(buffer)
                let sizeHandle = acquireArrayRawData(size)
                try { allocate(current, bufferHandle.pointer, sizeHandle.pointer) }
                finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(bufferHandle)
                }
            }
        })
        checkStatus(status)
        let output = Array<Byte>(Int64(size[0]), repeat: 0)
        try {
            let copyStatus = unsafe {
                let outputHandle = acquireArrayRawData(output)
                try { YJ_Compact_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
                finally { releaseArrayRawData(outputHandle) }
            }
            checkStatus(copyStatus)
            output
        } finally {
            unsafe { YJ_Compact_FreeOwnedBuffer(buffer[0]) }
        }
    }

    func ensureOpen(): Unit {
        withOpen({ _ => () })
    }

    private func withOpen<T>(operation: (UInt64) -> T): T {
        let lock = accessLock.readLock
        lock.lock()
        try {
            if (handle == 0u64) {
                throw JsonException("Native document is closed", code: "resource_closed")
            }
            operation(handle)
        } finally {
            lock.unlock()
        }
    }

    func kindAt(node: UInt32): Int32 {
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = withOpen({ current =>
            unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Compact_Kind(current, node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
        })
        checkStatus(status)
        Int32(out[0])
    }

    func sizeAt(node: UInt32): Int64 {
        let out = Array<UInt64>(1, repeat: 0u64)
        let status = withOpen({ current =>
            unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Compact_Size(current, node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
        })
        checkStatus(status)
        Int64(out[0])
    }

    func arrayAt(node: UInt32, index: Int64): Option<NativeCompactJsonValue> {
        if (index < 0 || index >= sizeAt(node)) { return None<NativeCompactJsonValue> }
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = withOpen({ current =>
            unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Compact_ArrayGet(current, node, UInt64(index), outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
        })
        checkStatus(status)
        Some(NativeCompactJsonValue(this, out[0]))
    }

    func objectAt(node: UInt32, name: String): Option<NativeCompactJsonValue> {
        let bytes = unsafe { name.rawData() }
        let outKind = Array<UInt32>(1, repeat: 0u32)
        let outPayload = Array<UInt64>(1, repeat: 0u64)
        let found = Array<UInt32>(1, repeat: 0u32)
        let status = withOpen({ current =>
            unsafe {
                let bytesHandle = acquireArrayRawData(bytes)
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let foundHandle = acquireArrayRawData(found)
                try {
                    YJ_Compact_ObjectLookup(current, node, bytesHandle.pointer, UInt64(bytes.size),
                        kindHandle.pointer, payloadHandle.pointer, foundHandle.pointer)
                } finally {
                    releaseArrayRawData(foundHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                    releaseArrayRawData(bytesHandle)
                }
            }
        })
        checkStatus(status)
        if (found[0] == 0u32) { None<NativeCompactJsonValue> }
        else { Some(valueFrom(Int32(outKind[0]), outPayload[0])) }
    }

    func objectEntryAt(node: UInt32, index: Int64): Option<NativeCompactObjectEntry> {
        if (index < 0 || index >= sizeAt(node)) { return None<NativeCompactObjectEntry> }
        let outKind = Array<UInt32>(1, repeat: 0u32)
        let outPayload = Array<UInt64>(1, repeat: 0u64)
        let keySize = Array<UInt64>(1, repeat: 0u64)
        var status = withOpen({ current =>
            unsafe {
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let sizeHandle = acquireArrayRawData(keySize)
                try { YJ_Compact_ObjectEntry(current, node, UInt64(index), kindHandle.pointer,
                    payloadHandle.pointer, sizeHandle.pointer) }
                finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                }
            }
        })
        checkStatus(status)
        let keyBytes = Array<Byte>(Int64(keySize[0]), repeat: 0)
        let written = Array<UInt64>(1, repeat: 0u64)
        status = withOpen({ current =>
            unsafe {
                let keyHandle = acquireArrayRawData(keyBytes)
                let writtenHandle = acquireArrayRawData(written)
                try { YJ_Compact_CopyObjectKey(current, node, UInt64(index), keyHandle.pointer,
                    UInt64(keyBytes.size), writtenHandle.pointer) }
                finally {
                    releaseArrayRawData(writtenHandle)
                    releaseArrayRawData(keyHandle)
                }
            }
        })
        checkStatus(status)
        Some(NativeCompactObjectEntry(unsafe { String.fromUtf8Unchecked(keyBytes) },
            valueFrom(Int32(outKind[0]), outPayload[0])))
    }

    func objectValueAt(node: UInt32, index: Int64): Option<NativeCompactJsonValue> {
        if (index < 0 || index >= sizeAt(node)) { return None<NativeCompactJsonValue> }
        let outKind = Array<UInt32>(1, repeat: 0u32)
        let outPayload = Array<UInt64>(1, repeat: 0u64)
        let keySize = Array<UInt64>(1, repeat: 0u64)
        let status = withOpen({ current =>
            unsafe {
                let kindHandle = acquireArrayRawData(outKind)
                let payloadHandle = acquireArrayRawData(outPayload)
                let sizeHandle = acquireArrayRawData(keySize)
                try {
                    YJ_Compact_ObjectEntry(current, node, UInt64(index),
                        kindHandle.pointer, payloadHandle.pointer, sizeHandle.pointer)
                } finally {
                    releaseArrayRawData(sizeHandle)
                    releaseArrayRawData(payloadHandle)
                    releaseArrayRawData(kindHandle)
                }
            }
        })
        checkStatus(status)
        Some(valueFrom(Int32(outKind[0]), outPayload[0]))
    }

    func intAt(node: UInt32): Int64 {
        let out = Array<Int64>(1, repeat: 0)
        let status = withOpen({ current =>
            unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Compact_GetInt(current, node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
        })
        checkStatus(status)
        out[0]
    }

    func boolAt(node: UInt32): Bool {
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = withOpen({ current =>
            unsafe {
                let outHandle = acquireArrayRawData(out)
                try { YJ_Compact_GetBool(current, node, outHandle.pointer) }
                finally { releaseArrayRawData(outHandle) }
            }
        })
        checkStatus(status)
        out[0] != 0u32
    }

    func textAt(node: UInt32): String {
        let size = Array<UInt64>(1, repeat: 0u64)
        var status = withOpen({ current =>
            unsafe {
                let sizeHandle = acquireArrayRawData(size)
                try { YJ_Compact_GetTextSize(current, node, sizeHandle.pointer) }
                finally { releaseArrayRawData(sizeHandle) }
            }
        })
        checkStatus(status)
        copyStringRefOrNode(size[0], { output, capacity, written =>
            withOpen({ current =>
                unsafe { YJ_Compact_CopyText(current, node, output, capacity, written) }
            })
        })
    }

    func stringRefAt(reference: UInt64): String {
        let size = Array<UInt64>(1, repeat: 0u64)
        var status = withOpen({ current =>
            unsafe {
                let sizeHandle = acquireArrayRawData(size)
                try { YJ_Compact_GetStringRefSize(current, reference, sizeHandle.pointer) }
                finally { releaseArrayRawData(sizeHandle) }
            }
        })
        checkStatus(status)
        copyStringRefOrNode(size[0], { output, capacity, written =>
            withOpen({ current =>
                unsafe { YJ_Compact_CopyStringRef(current, reference, output, capacity, written) }
            })
        })
    }

    private func copyStringRefOrNode(size: UInt64,
        copy: (CPointer<UInt8>, UInt64, CPointer<UInt64>) -> Int32): String {
        let bytes = Array<Byte>(Int64(size), repeat: 0)
        let written = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let bytesHandle = acquireArrayRawData(bytes)
            let writtenHandle = acquireArrayRawData(written)
            try { copy(bytesHandle.pointer, UInt64(bytes.size), writtenHandle.pointer) }
            finally {
                releaseArrayRawData(writtenHandle)
                releaseArrayRawData(bytesHandle)
            }
        }
        checkStatus(status)
        unsafe { String.fromUtf8Unchecked(bytes) }
    }

    func valueFrom(kind: Int32, payload: UInt64): NativeCompactJsonValue {
        if (kind == YJ_COMPACT_ARRAY || kind == YJ_COMPACT_OBJECT) {
            NativeCompactJsonValue(this, UInt32(payload))
        } else {
            NativeCompactJsonValue(this, 0u32, kind, payload)
        }
    }

    func checkStatus(status: Int32): Unit {
        if (status == YJ_COMPACT_OK) { return }
        match {
            case status == YJ_COMPACT_CLOSED =>
                throw JsonException("Native document is closed", code: "resource_closed")
            case status == YJ_COMPACT_TYPE_ERROR =>
                throw JsonException("Native value type mismatch", code: "type_mismatch")
            case status == YJ_COMPACT_BOUNDS_ERROR =>
                throw JsonException("Native value index is out of bounds", code: "index_out_of_bounds")
            case status == YJ_COMPACT_OUT_OF_MEMORY => throw JsonException("Native compact allocation failed", code: "out_of_memory")
            case _ => throw JsonException("Native compact operation failed (${status})")
        }
    }
}

/// A value-like, document-bound native view. It does not allocate a Cangjie
/// class per JSON node. Container payloads are native node indexes; object
/// scalar values remain inline in the native object-entry stores.
struct NativeCompactJsonValue <: JsonValueView {
    private let document: NativeCompactJsonDocument
    private let node: UInt32
    private let inlineKind: Int32
    private let inlinePayload: UInt64

    init(document: NativeCompactJsonDocument, node: UInt32) {
        this.document = document
        this.node = node
        inlineKind = -1
        inlinePayload = 0u64
    }

    init(document: NativeCompactJsonDocument, node: UInt32, inlineKind: Int32, inlinePayload: UInt64) {
        this.document = document
        this.node = node
        this.inlineKind = inlineKind
        this.inlinePayload = inlinePayload
    }

    public func kind(): JsonKind { nativeCompactKind(code()) }

    public func size(): Int64 {
        if (inlineKind >= 0) {
            document.ensureOpen()
            0
        } else { document.sizeAt(node) }
    }

    public func get(index: Int64): Option<NativeCompactJsonValue> {
        if (inlineKind >= 0) {
            document.ensureOpen()
            None<NativeCompactJsonValue>
        } else { document.arrayAt(node, index) }
    }

    public func get(name: String): Option<NativeCompactJsonValue> {
        if (inlineKind >= 0) {
            document.ensureOpen()
            None<NativeCompactJsonValue>
        } else { document.objectAt(node, name) }
    }

    public func element(index: Int64): Option<JsonValueView> {
        match (get(index)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func member(name: String): Option<JsonValueView> {
        match (get(name)) {
            case Some(value) => Some<JsonValueView>(value)
            case None => None<JsonValueView>
        }
    }

    public func memberName(index: Int64): String {
        entryAt(index).getOrThrow({ =>
            JsonException("Object member index ${index} is out of bounds", code: "index_out_of_bounds")
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

    public func entryAt(index: Int64): Option<NativeCompactObjectEntry> {
        if (inlineKind >= 0) {
            document.ensureOpen()
            None<NativeCompactObjectEntry>
        } else { document.objectEntryAt(node, index) }
    }

    public func asInt64(): Int64 {
        if (inlineKind == YJ_COMPACT_INT) {
            document.ensureOpen()
            nativeCompactBitsToInt64(inlinePayload)
        }
        else { document.intAt(node) }
    }

    public func asBool(): Bool {
        if (inlineKind == YJ_COMPACT_BOOL) {
            document.ensureOpen()
            inlinePayload != 0u64
        }
        else { document.boolAt(node) }
    }

    public func asString(): String {
        if (code() != YJ_COMPACT_STRING) { throw JsonException("Expected string value") }
        if (inlineKind >= 0) { document.stringRefAt(inlinePayload) } else { document.textAt(node) }
    }

    public func asUInt64(): UInt64 {
        let text = asNumberText()
        try { UInt64.parse(text) } catch (_: Exception) {
            throw JsonException("Expected unsigned integer value", code: "type_mismatch")
        }
    }

    public func asFloat64(): Float64 {
        try { Float64.parse(asNumberText()) } catch (_: Exception) {
            throw JsonException("Expected numeric value", code: "type_mismatch")
        }
    }

    public func asNumberText(): String {
        if (code() == YJ_COMPACT_INT) { return asInt64().toString() }
        if (code() != YJ_COMPACT_NUMBER) { throw JsonException("Expected numeric value") }
        if (inlineKind >= 0) { document.stringRefAt(inlinePayload) } else { document.textAt(node) }
    }

    public func materialize(): JsonNode {
        materializeNativeCompactValue(this, 100000)
    }

    public func materialize(maxNodes: Int64): JsonNode {
        materializeNativeCompactValue(this, maxNodes)
    }

    func exportRootStreamTape(): Option<Array<Byte>> {
        document.exportRootStreamTape(node, inlineKind)
    }

    private func code(): Int32 {
        if (inlineKind >= 0) {
            document.ensureOpen()
            inlineKind
        } else { document.kindAt(node) }
    }
}

private class NativeMaterializationBudget {
    private var remaining: Int64

    init(maxNodes: Int64) {
        if (maxNodes <= 0) {
            throw IllegalArgumentException("maxNodes must be positive")
        }
        remaining = maxNodes
    }

    func consume(depth: Int64): Unit {
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

private func materializeNativeCompactValue(value: JsonValueView,
    maxNodes: Int64): JsonNode {
    let budget = NativeMaterializationBudget(maxNodes)
    func copy(current: JsonValueView, depth: Int64): JsonNode {
        budget.consume(depth)
        match (current.kind()) {
            case JsonKind.Null => JsonNode.nullValue
            case JsonKind.Boolean => JsonNode.boolean(current.asBool())
            case JsonKind.Number => JsonNode.number(current.asNumberText())
            case JsonKind.String => JsonNode.string(current.asString())
            case JsonKind.Array =>
                let array = JsonArray()
                for (index in 0..current.size()) {
                    array.add(copy(current.element(index).getOrThrow({ =>
                        JsonException("Array view changed during materialization",
                            code: "view_contract")
                    }), depth + 1))
                }
                array
            case JsonKind.Object =>
                let object = JsonObject()
                for (index in 0..current.size()) {
                    object.put(current.memberName(index),
                        copy(current.memberValue(index), depth + 1))
                }
                object
        }
    }
    copy(value, 0)
}

@OverflowWrapping
private func nativeCompactBitsToInt64(value: UInt64): Int64 { Int64(value) }

private func nativeCompactKind(code: Int32): JsonKind {
    match {
        case code == YJ_COMPACT_NULL => JsonKind.Null
        case code == YJ_COMPACT_BOOL => JsonKind.Boolean
        case code == YJ_COMPACT_INT => JsonKind.Number
        case code == YJ_COMPACT_NUMBER => JsonKind.Number
        case code == YJ_COMPACT_STRING => JsonKind.String
        case code == YJ_COMPACT_ARRAY => JsonKind.Array
        case code == YJ_COMPACT_OBJECT => JsonKind.Object
        case _ => throw JsonException("Unknown native compact kind ${code}")
    }
}

private func nativeCompactParseError(bytes: Array<Byte>, code: Int32, offset: Int64): JsonException {
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
        case code == YJ_COMPACT_OUT_OF_MEMORY => "Native compact allocation failed"
        case code == YJ_COMPACT_DOCUMENT_TOO_LARGE => "Native compact document is too large"
        case code == YJ_COMPACT_STRING_TOO_LARGE => "Native compact JSON string is too large"
        case code == YJ_COMPACT_VALUE_TOO_LARGE => "Native compact JSON value is too large"
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

