package yjson_native

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
private let YJ_COMPACT_PRESERVE_NUMBERS: UInt32 = 2u32
private let YJ_COMPACT_MATERIALIZE_SOURCE: UInt32 = 4u32
private let YJ_COMPACT_DUPLICATE_LOAD_50: UInt32 = 8u32
private let YJ_COMPACT_DUPLICATE_LOAD_625: UInt32 = 16u32
private let YJ_COMPACT_DUPLICATE_LOAD_875: UInt32 = 32u32
private let YJ_COMPACT_DUPLICATE_PRESIZE: UInt32 = 64u32
private let YJ_COMPACT_DUPLICATE_STATS: UInt32 = 128u32

public enum NativeCompactSourceOwnership {
    | CopySource
    | MaterializeSlices
}

public enum NativeCompactDuplicateStrategy {
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

foreign func YJ_Compact_CopyOwnedBuffer(bufferHandle: UInt64, output: CPointer<UInt8>,
    outputCapacity: UInt64): Int32

foreign func YJ_Compact_FreeOwnedBuffer(bufferHandle: UInt64): Unit
@FastNative
foreign func YJ_Compact_Stats(handle: UInt64, stats: CPointer<UInt64>, capacity: UInt64): Int32
@FastNative
foreign func YJ_Compact_DuplicateStats(handle: UInt64, stats: CPointer<UInt64>, capacity: UInt64): Int32
@FastNative
foreign func YJ_Compact_Noop(value: UInt64): UInt64
@FastNative
foreign func YJ_Compact_ScalarProbe(value: UInt64, outValue: CPointer<UInt64>): Int32

foreign func YJ_Compact_CopyProbe(input: CPointer<UInt8>, length: UInt64,
    iterations: UInt64, outChecksum: CPointer<UInt64>): Int32

/// Native-owned memory counters. `persistentCommitted` includes C-owned input,
/// POD store capacities, and arena blocks; it is not Cangjie heap usage or RSS.
public struct NativeCompactStorageStats {
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

public struct NativeCompactDuplicateStats {
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
public struct NativeCompactObjectEntry {
    public let key: String
    public let value: NativeCompactJsonValue

    init(key: String, value: NativeCompactJsonValue) {
        this.key = key
        this.value = value
    }
}

/// Supported opt-in immutable Compact DOM backed entirely by C-owned memory.
///
/// Parsing is one coarse FFI call. This resource is not thread-safe: callers
/// must externally synchronize all access, `close()` requires exclusive
/// ownership, and it must never race lookup, traversal, or serialization.
/// Call `close()` (or use try-with-resource) to release large documents
/// deterministically; the destructor is only a leak safety net. Value views
/// retain their owner but become unusable after the owner is closed.
public class NativeCompactJsonDocument <: Resource {
    private var handle: UInt64
    private let rootNode: UInt32

    private init(handle: UInt64, rootNode: UInt32) {
        this.handle = handle
        this.rootNode = rootNode
    }

    public static func parse(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults,
        sourceOwnership!: NativeCompactSourceOwnership = NativeCompactSourceOwnership.CopySource,
        duplicateStrategy!: NativeCompactDuplicateStrategy = NativeCompactDuplicateStrategy.Baseline,
        collectDuplicateStats!: Bool = false
    ): NativeCompactJsonDocument {
        var flags: UInt32 = 0u32
        match (config.duplicateKeyPolicy) {
            case JsonDuplicateKeyPolicy.Reject => flags |= YJ_COMPACT_REJECT_DUPLICATES
            case _ => ()
        }
        match (config.numberPolicy) {
            case JsonNumberPolicy.PreserveLiteral => flags |= YJ_COMPACT_PRESERVE_NUMBERS
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
                if (config.maxBytes == 0 && config.maxStringBytes == 0 &&
                    config.maxPolymorphicObjectBytes == 0) {
                    status = YJ_Compact_Parse(inputHandle.pointer, bytes.size, flags, config.maxDepth,
                        handleHandle.pointer, rootHandle.pointer, errorHandle.pointer, offsetHandle.pointer)
                } else {
                    status = YJ_Compact_ParseWithLimits(inputHandle.pointer, bytes.size, flags,
                        config.maxDepth, config.maxBytes, config.maxStringBytes,
                        config.maxPolymorphicObjectBytes, handleHandle.pointer, rootHandle.pointer,
                        errorHandle.pointer, offsetHandle.pointer)
                }
            } finally {
                releaseArrayRawData(offsetHandle)
                releaseArrayRawData(errorHandle)
                releaseArrayRawData(rootHandle)
                releaseArrayRawData(handleHandle)
                releaseArrayRawData(inputHandle)
            }
        }
        if (status != YJ_COMPACT_OK) {
            throw nativeCompactParseError(bytes, Int32(outError[0]), outOffset[0], config.includeErrorLocation)
        }
        NativeCompactJsonDocument(outHandle[0], outRoot[0])
    }

    public func isClosed(): Bool { handle == 0u64 }

    public func close(): Unit {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            unsafe { YJ_Compact_Free(current) }
        }
    }

    ~init() {
        if (handle != 0u64) { unsafe { YJ_Compact_Free(handle) } }
    }

    public func root(): NativeCompactJsonValue {
        requireOpen()
        NativeCompactJsonValue(this, rootNode)
    }

    public func traversalChecksum(): Int64 {
        let current = requireOpen()
        @OverflowWrapping
        func convert(value: UInt64): Int64 { Int64(value) }
        convert(unsafe { YJ_Compact_TraversalChecksum(current) })
    }

    public func storageStats(): NativeCompactStorageStats {
        let current = requireOpen()
        let values = Array<UInt64>(12, repeat: 0u64)
        let status = unsafe {
            let valuesHandle = acquireArrayRawData(values)
            try { YJ_Compact_Stats(current, valuesHandle.pointer, 12u64) }
            finally { releaseArrayRawData(valuesHandle) }
        }
        checkStatus(status)
        NativeCompactStorageStats(values)
    }

    public func duplicateStats(): NativeCompactDuplicateStats {
        let current = requireOpen()
        let values = Array<UInt64>(16, repeat: 0u64)
        let status = unsafe {
            let valuesHandle = acquireArrayRawData(values)
            try { YJ_Compact_DuplicateStats(current, valuesHandle.pointer, 16u64) }
            finally { releaseArrayRawData(valuesHandle) }
        }
        checkStatus(status)
        NativeCompactDuplicateStats(values)
    }

    public func materialize(): JsonNode { root().materialize() }

    /// One native export plus one Cangjie bulk construction. No per-node FFI.
    public func materializeBulk(): JsonNode {
        NativeCompactTapeReader(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_ExportTapeAlloc(handle, buffer, size) }
        })).readDocument()
    }

    /// Control path for the bulk materialization experiment.
    public func materializeViaSerialization(): JsonNode {
        YJson.parse(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_SerializeAlloc(handle, buffer, size) }
        }))
    }

    public func toString(): String {
        unsafe { String.fromUtf8Unchecked(copyOwnedBuffer({ handle, buffer, size =>
            unsafe { YJ_Compact_SerializeAlloc(handle, buffer, size) }
        })) }
    }

    private func copyOwnedBuffer(allocate: (UInt64, CPointer<UInt64>, CPointer<UInt64>) -> Int32): Array<Byte> {
        let current = requireOpen()
        let buffer = Array<UInt64>(1, repeat: 0u64)
        let size = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let bufferHandle = acquireArrayRawData(buffer)
            let sizeHandle = acquireArrayRawData(size)
            try { allocate(current, bufferHandle.pointer, sizeHandle.pointer) }
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
                try { YJ_Compact_CopyOwnedBuffer(buffer[0], outputHandle.pointer, UInt64(output.size)) }
                finally { releaseArrayRawData(outputHandle) }
            }
            checkStatus(copyStatus)
            output
        } finally {
            unsafe { YJ_Compact_FreeOwnedBuffer(buffer[0]) }
        }
    }

    func requireOpen(): UInt64 {
        if (handle == 0u64) { throw IllegalStateException("Native compact document is closed") }
        handle
    }

    func kindAt(node: UInt32): Int32 {
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = unsafe {
            let outHandle = acquireArrayRawData(out)
            try { YJ_Compact_Kind(requireOpen(), node, outHandle.pointer) }
            finally { releaseArrayRawData(outHandle) }
        }
        checkStatus(status)
        Int32(out[0])
    }

    func sizeAt(node: UInt32): Int64 {
        let out = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let outHandle = acquireArrayRawData(out)
            try { YJ_Compact_Size(requireOpen(), node, outHandle.pointer) }
            finally { releaseArrayRawData(outHandle) }
        }
        checkStatus(status)
        Int64(out[0])
    }

    func arrayAt(node: UInt32, index: Int64): Option<NativeCompactJsonValue> {
        if (index < 0 || index >= sizeAt(node)) { return None<NativeCompactJsonValue> }
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = unsafe {
            let outHandle = acquireArrayRawData(out)
            try { YJ_Compact_ArrayGet(requireOpen(), node, UInt64(index), outHandle.pointer) }
            finally { releaseArrayRawData(outHandle) }
        }
        checkStatus(status)
        Some(NativeCompactJsonValue(this, out[0]))
    }

    func objectAt(node: UInt32, name: String): Option<NativeCompactJsonValue> {
        let bytes = unsafe { name.rawData() }
        let outKind = Array<UInt32>(1, repeat: 0u32)
        let outPayload = Array<UInt64>(1, repeat: 0u64)
        let found = Array<UInt32>(1, repeat: 0u32)
        let status = unsafe {
            let bytesHandle = acquireArrayRawData(bytes)
            let kindHandle = acquireArrayRawData(outKind)
            let payloadHandle = acquireArrayRawData(outPayload)
            let foundHandle = acquireArrayRawData(found)
            try {
                YJ_Compact_ObjectLookup(requireOpen(), node, bytesHandle.pointer, UInt64(bytes.size),
                    kindHandle.pointer, payloadHandle.pointer, foundHandle.pointer)
            } finally {
                releaseArrayRawData(foundHandle)
                releaseArrayRawData(payloadHandle)
                releaseArrayRawData(kindHandle)
                releaseArrayRawData(bytesHandle)
            }
        }
        checkStatus(status)
        if (found[0] == 0u32) { None<NativeCompactJsonValue> }
        else { Some(valueFrom(Int32(outKind[0]), outPayload[0])) }
    }

    func objectEntryAt(node: UInt32, index: Int64): Option<NativeCompactObjectEntry> {
        if (index < 0 || index >= sizeAt(node)) { return None<NativeCompactObjectEntry> }
        let outKind = Array<UInt32>(1, repeat: 0u32)
        let outPayload = Array<UInt64>(1, repeat: 0u64)
        let keySize = Array<UInt64>(1, repeat: 0u64)
        var status = unsafe {
            let kindHandle = acquireArrayRawData(outKind)
            let payloadHandle = acquireArrayRawData(outPayload)
            let sizeHandle = acquireArrayRawData(keySize)
            try { YJ_Compact_ObjectEntry(requireOpen(), node, UInt64(index), kindHandle.pointer,
                payloadHandle.pointer, sizeHandle.pointer) }
            finally {
                releaseArrayRawData(sizeHandle)
                releaseArrayRawData(payloadHandle)
                releaseArrayRawData(kindHandle)
            }
        }
        checkStatus(status)
        let keyBytes = Array<Byte>(Int64(keySize[0]), repeat: 0)
        let written = Array<UInt64>(1, repeat: 0u64)
        status = unsafe {
            let keyHandle = acquireArrayRawData(keyBytes)
            let writtenHandle = acquireArrayRawData(written)
            try { YJ_Compact_CopyObjectKey(requireOpen(), node, UInt64(index), keyHandle.pointer,
                UInt64(keyBytes.size), writtenHandle.pointer) }
            finally {
                releaseArrayRawData(writtenHandle)
                releaseArrayRawData(keyHandle)
            }
        }
        checkStatus(status)
        Some(NativeCompactObjectEntry(unsafe { String.fromUtf8Unchecked(keyBytes) },
            valueFrom(Int32(outKind[0]), outPayload[0])))
    }

    func intAt(node: UInt32): Int64 {
        let out = Array<Int64>(1, repeat: 0)
        let status = unsafe {
            let outHandle = acquireArrayRawData(out)
            try { YJ_Compact_GetInt(requireOpen(), node, outHandle.pointer) }
            finally { releaseArrayRawData(outHandle) }
        }
        checkStatus(status)
        out[0]
    }

    func boolAt(node: UInt32): Bool {
        let out = Array<UInt32>(1, repeat: 0u32)
        let status = unsafe {
            let outHandle = acquireArrayRawData(out)
            try { YJ_Compact_GetBool(requireOpen(), node, outHandle.pointer) }
            finally { releaseArrayRawData(outHandle) }
        }
        checkStatus(status)
        out[0] != 0u32
    }

    func textAt(node: UInt32): String {
        let size = Array<UInt64>(1, repeat: 0u64)
        var status = unsafe {
            let sizeHandle = acquireArrayRawData(size)
            try { YJ_Compact_GetTextSize(requireOpen(), node, sizeHandle.pointer) }
            finally { releaseArrayRawData(sizeHandle) }
        }
        checkStatus(status)
        copyStringRefOrNode(size[0], { output, capacity, written =>
            unsafe { YJ_Compact_CopyText(requireOpen(), node, output, capacity, written) }
        })
    }

    func stringRefAt(reference: UInt64): String {
        let size = Array<UInt64>(1, repeat: 0u64)
        var status = unsafe {
            let sizeHandle = acquireArrayRawData(size)
            try { YJ_Compact_GetStringRefSize(requireOpen(), reference, sizeHandle.pointer) }
            finally { releaseArrayRawData(sizeHandle) }
        }
        checkStatus(status)
        copyStringRefOrNode(size[0], { output, capacity, written =>
            unsafe { YJ_Compact_CopyStringRef(requireOpen(), reference, output, capacity, written) }
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
            case status == YJ_COMPACT_CLOSED => throw IllegalStateException("Native compact document is closed")
            case status == YJ_COMPACT_TYPE_ERROR => throw JsonException("Native compact value type mismatch")
            case status == YJ_COMPACT_BOUNDS_ERROR => throw IndexOutOfBoundsException("Native compact value index out of bounds")
            case status == YJ_COMPACT_OUT_OF_MEMORY => throw JsonException("Native compact allocation failed", code: "out_of_memory")
            case _ => throw JsonException("Native compact operation failed (${status})")
        }
    }
}

private class NativeCompactTapeReader {
    private let bytes: Array<Byte>
    private var position: Int64 = 0

    init(bytes: Array<Byte>) { this.bytes = bytes }

    func readDocument(): JsonNode {
        if (bytes.size < 5 || readByte() != b'Y' || readByte() != b'J' ||
            readByte() != b'T' || readByte() != b'1') {
            throw JsonException("Invalid native compact transfer tape")
        }
        let value = readValue()
        if (position != bytes.size) { throw JsonException("Trailing native compact transfer data") }
        value
    }

    private func readValue(): JsonNode {
        let kind = readByte()
        match {
            case Int32(kind) == YJ_COMPACT_NULL => JsonNullValue()
            case Int32(kind) == YJ_COMPACT_BOOL => JsonBoolValue(readByte() != b'\0')
            case Int32(kind) == YJ_COMPACT_INT => JsonIntValue(bitsToInt64(readUInt64()))
            case Int32(kind) == YJ_COMPACT_NUMBER => JsonNumberLiteralValue(readString())
            case Int32(kind) == YJ_COMPACT_STRING => JsonStringValue(readString())
            case Int32(kind) == YJ_COMPACT_ARRAY =>
                let result = JsonArrayValue()
                let count = Int64(readUInt32())
                for (_ in 0..count) { result.add(readValue()) }
                result
            case Int32(kind) == YJ_COMPACT_OBJECT =>
                let result = JsonObjectValue()
                let count = Int64(readUInt32())
                for (_ in 0..count) { result.put(readString(), readValue()) }
                result
            case _ => throw JsonException("Unknown native compact transfer kind ${kind}")
        }
    }

    private func readString(): String {
        let size = Int64(readUInt32())
        require(size)
        let value = Array<Byte>(size, repeat: 0)
        for (index in 0..size) { value[index] = bytes[position + index] }
        position += size
        unsafe { String.fromUtf8Unchecked(value) }
    }

    private func readByte(): Byte {
        require(1)
        let value = bytes[position]
        position++
        value
    }

    private func readUInt32(): UInt32 {
        var value = 0u32
        for (shift in 0..4) { value |= UInt32(readByte()) << (shift * 8) }
        value
    }

    private func readUInt64(): UInt64 {
        var value = 0u64
        for (shift in 0..8) { value |= UInt64(readByte()) << (shift * 8) }
        value
    }

    private func require(count: Int64): Unit {
        if (count < 0 || position > bytes.size - count) {
            throw JsonException("Truncated native compact transfer tape")
        }
    }

    @OverflowWrapping
    private func bitsToInt64(value: UInt64): Int64 { Int64(value) }
}

/// A value-like, document-bound native view. It does not allocate a Cangjie
/// class per JSON node. Container payloads are native node indexes; object
/// scalar values remain inline in the native object-entry stores.
public struct NativeCompactJsonValue {
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
        if (inlineKind >= 0) { 0 } else { document.sizeAt(node) }
    }

    public func get(index: Int64): Option<NativeCompactJsonValue> {
        if (inlineKind >= 0) { None<NativeCompactJsonValue> } else { document.arrayAt(node, index) }
    }

    public func get(name: String): Option<NativeCompactJsonValue> {
        if (inlineKind >= 0) { None<NativeCompactJsonValue> } else { document.objectAt(node, name) }
    }

    public func entryAt(index: Int64): Option<NativeCompactObjectEntry> {
        if (inlineKind >= 0) { None<NativeCompactObjectEntry> } else { document.objectEntryAt(node, index) }
    }

    public func asInt64(): Int64 {
        if (inlineKind == YJ_COMPACT_INT) { nativeCompactBitsToInt64(inlinePayload) }
        else { document.intAt(node) }
    }

    public func asBool(): Bool {
        if (inlineKind == YJ_COMPACT_BOOL) { inlinePayload != 0u64 }
        else { document.boolAt(node) }
    }

    public func asString(): String {
        if (code() != YJ_COMPACT_STRING) { throw JsonException("Expected string value") }
        if (inlineKind >= 0) { document.stringRefAt(inlinePayload) } else { document.textAt(node) }
    }

    public func asNumberLiteral(): String {
        if (code() == YJ_COMPACT_INT) { return asInt64().toString() }
        if (code() != YJ_COMPACT_NUMBER) { throw JsonException("Expected numeric value") }
        if (inlineKind >= 0) { document.stringRefAt(inlinePayload) } else { document.textAt(node) }
    }

    public func materialize(): JsonNode {
        let valueKind = code()
        match {
            case valueKind == YJ_COMPACT_NULL => JsonNullValue()
            case valueKind == YJ_COMPACT_BOOL => JsonBoolValue(asBool())
            case valueKind == YJ_COMPACT_INT => JsonIntValue(asInt64())
            case valueKind == YJ_COMPACT_NUMBER => JsonNumberLiteralValue(asNumberLiteral())
            case valueKind == YJ_COMPACT_STRING => JsonStringValue(asString())
            case valueKind == YJ_COMPACT_ARRAY =>
                let result = JsonArrayValue()
                for (index in 0..size()) { result.add(get(index).getOrThrow().materialize()) }
                result
            case _ =>
                let result = JsonObjectValue()
                for (index in 0..size()) {
                    let entry = entryAt(index).getOrThrow()
                    result.put(entry.key, entry.value.materialize())
                }
                result
        }
    }

    private func code(): Int32 {
        if (inlineKind >= 0) { inlineKind } else { document.kindAt(node) }
    }
}

@OverflowWrapping
private func nativeCompactBitsToInt64(value: UInt64): Int64 { Int64(value) }

private func nativeCompactKind(code: Int32): JsonKind {
    match {
        case code == YJ_COMPACT_NULL => JsonKind.JsNull
        case code == YJ_COMPACT_BOOL => JsonKind.JsBool
        case code == YJ_COMPACT_INT => JsonKind.JsInt
        case code == YJ_COMPACT_NUMBER => JsonKind.JsNumberLiteral
        case code == YJ_COMPACT_STRING => JsonKind.JsString
        case code == YJ_COMPACT_ARRAY => JsonKind.JsArray
        case code == YJ_COMPACT_OBJECT => JsonKind.JsObject
        case _ => throw JsonException("Unknown native compact kind ${code}")
    }
}

private func nativeCompactParseError(bytes: Array<Byte>, code: Int32, offset: Int64,
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
        case code == YJ_COMPACT_OUT_OF_MEMORY => "Native compact allocation failed"
        case code == YJ_COMPACT_DOCUMENT_TOO_LARGE => "Native compact document is too large"
        case code == YJ_COMPACT_STRING_TOO_LARGE => "Native compact JSON string is too large"
        case code == YJ_COMPACT_VALUE_TOO_LARGE => "Native compact JSON value is too large"
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

/// Benchmark-only FFI probes. They do not access provider/network state.
public func nativeCompactNoopProbe(value: UInt64): UInt64 { unsafe { YJ_Compact_Noop(value) } }

public func nativeCompactScalarProbe(value: UInt64): UInt64 {
    let out = Array<UInt64>(1, repeat: 0u64)
    let status = unsafe {
        let outHandle = acquireArrayRawData(out)
        try { YJ_Compact_ScalarProbe(value, outHandle.pointer) }
        finally { releaseArrayRawData(outHandle) }
    }
    if (status != YJ_COMPACT_OK) { throw IllegalStateException("Native scalar probe failed") }
    out[0]
}

public func nativeCompactCopyProbe(bytes: Array<Byte>, iterations: UInt64): UInt64 {
    let checksum = Array<UInt64>(1, repeat: 0u64)
    let status = unsafe {
        let bytesHandle = acquireArrayRawData(bytes)
        let checksumHandle = acquireArrayRawData(checksum)
        try { YJ_Compact_CopyProbe(bytesHandle.pointer, UInt64(bytes.size), iterations, checksumHandle.pointer) }
        finally {
            releaseArrayRawData(checksumHandle)
            releaseArrayRawData(bytesHandle)
        }
    }
    if (status != YJ_COMPACT_OK) { throw IllegalStateException("Native copy probe failed: ${status}") }
    checksum[0]
}
