package yjson

import std.collection.*
import std.convert.Parsable

private let COMPACT_NULL: Int64 = 0
private let COMPACT_BOOL: Int64 = 1
private let COMPACT_INT: Int64 = 2
private let COMPACT_NUMBER: Int64 = 3
private let COMPACT_STRING: Int64 = 4
private let COMPACT_ARRAY: Int64 = 5
private let COMPACT_OBJECT: Int64 = 6
private let COMPACT_INT_ARRAY: Int64 = 7
private let COMPACT_STRING_ARRAY: Int64 = 8
private let COMPACT_NUMBER_ARRAY: Int64 = 9
private let COMPACT_MAX_INDEXED_KEYS: Int64 = 4096
private let COMPACT_OBJECT_NODE: Byte = 0xFFu8
private let COMPACT_KEY_OWNED_MASK: UInt64 = 1u64 << 63
private let COMPACT_KEY_PAYLOAD_MASK: UInt64 = 0x7FFF_FFFF_FFFF_FFFFu64
private let COMPACT_KEY_OFFSET_MASK: UInt64 = 0x7FFF_FFFFu64
private let COMPACT_KEY_LENGTH_MASK: UInt64 = 0xFFFF_FFFFu64
private let COMPACT_LINEAR_OBJECT_LIMIT: Int64 = 16
private let COMPACT_NUMERIC_BULK_CAP: Int64 = 1024
private let COMPACT_NUMERIC_BULK_MIN_BYTES: Int64 = 1024
private let COMPACT_TAPE_MIN_BYTES: Int64 = 64 * 1024
private let COMPACT_TAPE_PAGE_BYTES: Int64 = 64 * 1024
private let COMPACT_TAPE_CAP: Int64 = 4096
private let COMPACT_OPEN_INDEX_EMPTY: UInt64 = 0xFFFF_FFFF_FFFF_FFFFu64
private let COMPACT_DUPLICATE_REGION_SLOTS: Int64 = 4096
private let COMPACT_REGION_DOCUMENT_MIN_BYTES: Int64 = 16 * 1024 * 1024
private let COMPACT_WYHASH_SECRET0 = 0xa0761d6478bd642fu64
private let COMPACT_WYHASH_SECRET1 = 0xe7037ed1a0b428dbu64
private let COMPACT_WYHASH_SECRET2 = 0x8ebc6af09c88c6e3u64
private let COMPACT_WYHASH_SECRET3 = 0x589965cc75374cc3u64

// Byte-range form of the exact algorithm used by std.core.String.hashCode().
// Keeping the same seed and byte order lets source views and decoded Strings
// share one duplicate table without changing hash semantics.
@OverflowWrapping
private func compactWyhashRange(data: Array<Byte>, start: Int64, size: Int64): Int64 {
    var seed = compactWyhashMix(COMPACT_WYHASH_SECRET0, COMPACT_WYHASH_SECRET1)
    if (size == 0) { return Int64(seed) }
    var a: UInt64
    var b: UInt64
    match {
        case size < 4 =>
            a = (UInt64(data[start]) << 16) |
                (UInt64(data[start + (size >> 1)]) << 8) |
                UInt64(data[start + size - 1])
            b = 0
        case size == 4 =>
            a = compactWyhashRead4(data, start); b = a
        case size < 8 =>
            a = compactWyhashRead4(data, start)
            b = compactWyhashRead4(data, start + size - 4)
        case size <= 16 =>
            a = compactWyhashRead8(data, start)
            b = compactWyhashRead8(data, start + size - 8)
        case _ =>
            var position = start
            var remaining = size
            if (remaining > 48) {
                var seed1 = seed
                var seed2 = seed
                do {
                    seed = compactWyhashMix(compactWyhashRead8(data, position) ^ COMPACT_WYHASH_SECRET1,
                        compactWyhashRead8(data, position + 8) ^ seed)
                    seed1 = compactWyhashMix(compactWyhashRead8(data, position + 16) ^ COMPACT_WYHASH_SECRET2,
                        compactWyhashRead8(data, position + 24) ^ seed1)
                    seed2 = compactWyhashMix(compactWyhashRead8(data, position + 32) ^ COMPACT_WYHASH_SECRET3,
                        compactWyhashRead8(data, position + 40) ^ seed2)
                    position += 48
                    remaining -= 48
                } while (remaining > 48)
                seed = seed ^ seed1 ^ seed2
            }
            while (remaining > 16) {
                seed = compactWyhashMix(compactWyhashRead8(data, position) ^ COMPACT_WYHASH_SECRET1,
                    compactWyhashRead8(data, position + 8) ^ seed)
                remaining -= 16
                position += 16
            }
            a = compactWyhashRead8(data, position + remaining - 16)
            b = compactWyhashRead8(data, position + remaining - 8)
    }
    a ^= COMPACT_WYHASH_SECRET1
    b ^= seed
    Int64(compactWyhashMix(a ^ COMPACT_WYHASH_SECRET0 ^ UInt64(size), b ^ COMPACT_WYHASH_SECRET1))
}

@OverflowWrapping
private func compactWyhashMix(a: UInt64, b: UInt64): UInt64 {
    let highA = a >> 32
    let highB = b >> 32
    let lowA = UInt64(UInt32(a))
    let lowB = UInt64(UInt32(b))
    let high = highA * highB
    let middle0 = highA * lowB
    let middle1 = highB * lowA
    let low = lowA * lowB
    let first = low + (middle0 << 32)
    var carry: UInt64 = if (first < low) { 1 } else { 0 }
    let resultLow = first + (middle1 << 32)
    carry += if (resultLow < first) { 1 } else { 0 }
    let resultHigh = high + (middle0 >> 32) + (middle1 >> 32) + carry
    resultLow ^ resultHigh
}

private func compactWyhashRead4(data: Array<Byte>, position: Int64): UInt64 {
    (UInt64(data[position]) << 24) | (UInt64(data[position + 1]) << 16) |
        (UInt64(data[position + 2]) << 8) | UInt64(data[position + 3])
}

private func compactWyhashRead8(data: Array<Byte>, position: Int64): UInt64 {
    (UInt64(data[position]) << 56) | (UInt64(data[position + 1]) << 48) |
        (UInt64(data[position + 2]) << 40) | (UInt64(data[position + 3]) << 32) |
        (UInt64(data[position + 4]) << 24) | (UInt64(data[position + 5]) << 16) |
        (UInt64(data[position + 6]) << 8) | UInt64(data[position + 7])
}

/// Coarse storage counters for representation analysis.  These are logical
/// entry counts rather than allocated-byte measurements.
public struct CompactJsonStorageStats {
    public let nodes: Int64
    public let strings: Int64
    public let objectFields: Int64
    public let arrayEntries: Int64
    public let indexedKeys: Int64
    public let slicedKeys: Int64
    public let logicalCanonicalBytes: Int64
    public let duplicateLogicalBytes: Int64
    public let duplicateCapacityBytes: Int64
    public let duplicateGrowCount: Int64
    public let duplicatePeakOverlapBytes: Int64
    public let duplicateLargestOldBytes: Int64
    public let duplicateLargestNewBytes: Int64
    public let duplicateRehashEntries: Int64
    public let duplicateRehashNanos: Int64
    public let duplicateLookupCount: Int64
    public let duplicateInsertCount: Int64
    public let duplicateProbeCount: Int64
    public let duplicateExactEqualityCount: Int64
    public let duplicateMaxProbe: Int64
    public let duplicateGrowthTrace: String
    public let tapeCalls: Int64
    public let tapeClassifiedBytes: Int64
    public let tapeEvents: Int64
    public let tapeEarlyRefills: Int64
    public let sourceViewKeys: Int64
    public let ownedKeyViews: Int64
    public let keyRangeRecoveries: Int64
    public let keyHashCalculations: Int64
    public let keyDictionaryLookups: Int64
    public let keyDictionaryHits: Int64
    public let keyDictionaryMisses: Int64

    public init(nodes: Int64, strings: Int64, objectFields: Int64, arrayEntries: Int64, indexedKeys: Int64,
        slicedKeys: Int64, logicalCanonicalBytes: Int64, duplicateLogicalBytes: Int64,
        duplicateCapacityBytes: Int64, duplicateGrowCount: Int64,
        duplicatePeakOverlapBytes!: Int64 = 0, duplicateLargestOldBytes!: Int64 = 0,
        duplicateLargestNewBytes!: Int64 = 0, duplicateRehashEntries!: Int64 = 0,
        duplicateRehashNanos!: Int64 = 0, duplicateLookupCount!: Int64 = 0,
        duplicateInsertCount!: Int64 = 0, duplicateProbeCount!: Int64 = 0,
        duplicateExactEqualityCount!: Int64 = 0, duplicateMaxProbe!: Int64 = 0,
        duplicateGrowthTrace!: String = "",
        tapeCalls!: Int64 = 0, tapeClassifiedBytes!: Int64 = 0,
        tapeEvents!: Int64 = 0, tapeEarlyRefills!: Int64 = 0,
        sourceViewKeys!: Int64 = 0, ownedKeyViews!: Int64 = 0,
        keyRangeRecoveries!: Int64 = 0, keyHashCalculations!: Int64 = 0,
        keyDictionaryLookups!: Int64 = 0, keyDictionaryHits!: Int64 = 0,
        keyDictionaryMisses!: Int64 = 0) {
        this.nodes = nodes
        this.strings = strings
        this.objectFields = objectFields
        this.arrayEntries = arrayEntries
        this.indexedKeys = indexedKeys
        this.slicedKeys = slicedKeys
        this.logicalCanonicalBytes = logicalCanonicalBytes
        this.duplicateLogicalBytes = duplicateLogicalBytes
        this.duplicateCapacityBytes = duplicateCapacityBytes
        this.duplicateGrowCount = duplicateGrowCount
        this.duplicatePeakOverlapBytes = duplicatePeakOverlapBytes
        this.duplicateLargestOldBytes = duplicateLargestOldBytes
        this.duplicateLargestNewBytes = duplicateLargestNewBytes
        this.duplicateRehashEntries = duplicateRehashEntries
        this.duplicateRehashNanos = duplicateRehashNanos
        this.duplicateLookupCount = duplicateLookupCount
        this.duplicateInsertCount = duplicateInsertCount
        this.duplicateProbeCount = duplicateProbeCount
        this.duplicateExactEqualityCount = duplicateExactEqualityCount
        this.duplicateMaxProbe = duplicateMaxProbe
        this.duplicateGrowthTrace = duplicateGrowthTrace
        this.tapeCalls = tapeCalls
        this.tapeClassifiedBytes = tapeClassifiedBytes
        this.tapeEvents = tapeEvents
        this.tapeEarlyRefills = tapeEarlyRefills
        this.sourceViewKeys = sourceViewKeys
        this.ownedKeyViews = ownedKeyViews
        this.keyRangeRecoveries = keyRangeRecoveries
        this.keyHashCalculations = keyHashCalculations
        this.keyDictionaryLookups = keyDictionaryLookups
        this.keyDictionaryHits = keyDictionaryHits
        this.keyDictionaryMisses = keyDictionaryMisses
    }
}

/// Immutable, index-based JSON DOM. Parsing allocates one document and dense
/// backing stores rather than one GC class for every JSON node. No-escape
/// object keys retain source ranges; string values and escaped keys remain
/// decoded/owned. Retaining the input establishes the source-view lifetime.
public class CompactJsonDocument {
    let source: Array<Byte>
    let kinds = ArrayList<Int64>()
    let first = ArrayList<Int64>()
    let second = ArrayList<Int64>()
    let strings = ArrayList<String>()
    let arrayChildren = ArrayList<Int64>()
    // Object entries carry the packed key reference directly.  The previous
    // key-id -> keyMetadata indirection duplicated eight persistent bytes per
    // field for unique-key objects and forced two independently growing large
    // backing arrays.
    let objectKeys = ArrayList<UInt64>()
    let objectKinds = ArrayList<Byte>()
    let objectValues = ArrayList<Int64>()
    // Each entry owns one packed key reference. No-escape keys always retain
    // their validated source range, including repeated keys, so parsing never
    // needs a transient String. Escaped keys retain their decoded semantic
    // String. The high bit selects an owned String id; otherwise bits 32..62
    // hold a checked source offset and bits 0..31 hold the byte length. Inputs
    // beyond this compact range safely use the owned representation.
    let intValues = ArrayList<Int64>()
    let numberKinds = ArrayList<Bool>()
    let numberPayloads = ArrayList<Int64>()
    // Only escaped/decoded keys use this bounded dictionary. Source views skip
    // String HashMap probing entirely; exact duplicate semantics are handled
    // by the parse-time byte-aware object index below.
    private let keyDictionary = HashMap<String, UInt64>()
    // Cache only queried entries for large objects. A full permanent key index
    // would reintroduce the memory amplification this document API avoids.
    private let lookupCache = HashMap<String, Int64>()
    var rootIndex: Int64 = -1
    var duplicateLogicalBytes: Int64 = 0
    var duplicateCapacityBytes: Int64 = 0
    var duplicateGrowCount: Int64 = 0
    var duplicatePeakOverlapBytes: Int64 = 0
    var duplicateLargestOldBytes: Int64 = 0
    var duplicateLargestNewBytes: Int64 = 0
    var duplicateRehashEntries: Int64 = 0
    var duplicateRehashNanos: Int64 = 0
    var duplicateLookupCount: Int64 = 0
    var duplicateInsertCount: Int64 = 0
    var duplicateProbeCount: Int64 = 0
    var duplicateExactEqualityCount: Int64 = 0
    var duplicateMaxProbe: Int64 = 0
    var duplicateGrowthTrace: String = ""
    var tapeCalls: Int64 = 0
    var tapeClassifiedBytes: Int64 = 0
    var tapeEvents: Int64 = 0
    var tapeEarlyRefills: Int64 = 0
    var sourceViewKeys: Int64 = 0
    var ownedKeyViews: Int64 = 0
    var keyRangeRecoveries: Int64 = 0
    var keyHashCalculations: Int64 = 0
    var keyDictionaryLookups: Int64 = 0
    var keyDictionaryHits: Int64 = 0
    var keyDictionaryMisses: Int64 = 0
    private init(source: Array<Byte>) { this.source = source }

    /// Parses without copying `bytes`. The caller must not mutate the array or
    /// write it concurrently while the returned document remains reachable.
    public static func parseBorrowed(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        validateJsonResourceLimits(bytes, config)
        let document = CompactJsonDocument(bytes)
        let parser = CompactJsonParser(document, JsonFastReader(bytes), config)
        document.rootIndex = parser.parse()
        document
    }

    /// Parses an owned copy of `bytes`; later caller mutation cannot affect the
    /// returned document.
    public static func parseOwned(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        let owned = Array<Byte>(bytes.size, repeat: 0)
        bytes.copyTo(owned, 0, 0, bytes.size)
        parseBorrowed(owned, config: config)
    }

    /// Compatibility alias for the zero-copy borrowed-input entry point.
    public static func parse(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        parseBorrowed(bytes, config: config)
    }

    public func root(): CompactJsonValue { CompactJsonValue(this, rootIndex) }
    public func nodeCount(): Int64 { kinds.size }
    public func sourceSize(): Int64 { source.size }
    public func storageStats(): CompactJsonStorageStats {
        CompactJsonStorageStats(
            kinds.size,
            strings.size,
            objectValues.size,
            arrayChildren.size + intValues.size + numberPayloads.size,
            keyDictionary.size,
            countSlicedKeys(),
            kinds.size * 24 + objectKeys.size * 8 + objectKinds.size + objectValues.size * 8 +
                arrayChildren.size * 8 + intValues.size * 8 +
                numberKinds.size + numberPayloads.size * 8,
            duplicateLogicalBytes,
            duplicateCapacityBytes,
            duplicateGrowCount,
            duplicatePeakOverlapBytes: duplicatePeakOverlapBytes,
            duplicateLargestOldBytes: duplicateLargestOldBytes,
            duplicateLargestNewBytes: duplicateLargestNewBytes,
            duplicateRehashEntries: duplicateRehashEntries,
            duplicateRehashNanos: duplicateRehashNanos,
            duplicateLookupCount: duplicateLookupCount,
            duplicateInsertCount: duplicateInsertCount,
            duplicateProbeCount: duplicateProbeCount,
            duplicateExactEqualityCount: duplicateExactEqualityCount,
            duplicateMaxProbe: duplicateMaxProbe,
            duplicateGrowthTrace: duplicateGrowthTrace,
            tapeCalls: tapeCalls,
            tapeClassifiedBytes: tapeClassifiedBytes,
            tapeEvents: tapeEvents,
            tapeEarlyRefills: tapeEarlyRefills,
            sourceViewKeys: sourceViewKeys,
            ownedKeyViews: ownedKeyViews,
            keyRangeRecoveries: keyRangeRecoveries,
            keyHashCalculations: keyHashCalculations,
            keyDictionaryLookups: keyDictionaryLookups,
            keyDictionaryHits: keyDictionaryHits,
            keyDictionaryMisses: keyDictionaryMisses
        )
    }
    /// Dense sequential walk used by analytical workloads without creating
    /// JsonNode nodes or CompactJsonValue views.
    public func traversalChecksum(): Int64 {
        var result: Int64 = 0
        for (index in 0..kinds.size) { result = result ^ kinds[index] ^ first[index] ^ second[index] }
        for (index in 0..objectValues.size) { result = result ^ Int64(objectKinds[index]) ^ objectValues[index] }
        result & 0x7FFF_FFFF
    }
    public func materialize(): JsonNode { materializeAt(rootIndex) }

    public func toString(): String {
        let writer = JsonDirectWriter()
        writeAt(rootIndex, writer)
        writer.finishString()
    }

    func addNode(kind: Int64, firstValue!: Int64 = 0, secondValue!: Int64 = 0): Int64 {
        let index = kinds.size
        kinds.add(kind); first.add(firstValue); second.add(secondValue)
        index
    }

    func addString(value: String): Int64 {
        let index = strings.size
        strings.add(value)
        index
    }

    private func countSlicedKeys(): Int64 {
        var count: Int64 = 0
        for (metadata in objectKeys) { if ((metadata & COMPACT_KEY_OWNED_MASK) == 0u64) { count++ } }
        count
    }

    func indexedKey(value: String): Option<UInt64> {
        keyDictionaryLookups++
        let result = keyDictionary.get(value)
        if (result.isSome()) { keyDictionaryHits++ } else { keyDictionaryMisses++ }
        result
    }

    func sourceKey(view: JsonObjectKeyView): UInt64 {
        if (!view.isSource()) { throw IllegalArgumentException("Expected source-backed object key") }
        if (UInt64(view.sourceStart) <= COMPACT_KEY_OFFSET_MASK &&
            UInt64(view.sourceLength) <= COMPACT_KEY_LENGTH_MASK) {
            return (UInt64(view.sourceStart) << 32) | UInt64(view.sourceLength)
        }
        // The compact format deliberately uses a checked 31-bit source offset.
        // Oversized documents preserve semantics through the owned fallback.
        addOwnedKey(keyViewText(view))
    }

    func addOwnedKey(value: String): UInt64 {
        let metadata = COMPACT_KEY_OWNED_MASK | UInt64(addString(value))
        if (keyDictionary.size < COMPACT_MAX_INDEXED_KEYS) { keyDictionary[value] = metadata }
        metadata
    }

    func keyText(metadata: UInt64): String {
        if ((metadata & COMPACT_KEY_OWNED_MASK) != 0u64) {
            return strings[Int64(metadata & COMPACT_KEY_PAYLOAD_MASK)]
        }
        let start = Int64((metadata >> 32) & COMPACT_KEY_OFFSET_MASK)
        let length = Int64(metadata & COMPACT_KEY_LENGTH_MASK)
        unsafe { String.fromUtf8Unchecked(source[start..start + length]) }
    }

    func keyEquals(metadata: UInt64, value: String): Bool {
        if ((metadata & COMPACT_KEY_OWNED_MASK) != 0u64) {
            return strings[Int64(metadata & COMPACT_KEY_PAYLOAD_MASK)] == value
        }
        let bytes = unsafe { value.rawData() }
        if (bytes.size != Int64(metadata & COMPACT_KEY_LENGTH_MASK)) { return false }
        let start = Int64((metadata >> 32) & COMPACT_KEY_OFFSET_MASK)
        for (offset in 0..bytes.size) {
            if (source[start + offset] != bytes[offset]) { return false }
        }
        true
    }

    func keyEquals(metadata: UInt64, view: JsonObjectKeyView): Bool {
        if (let Some(value) <- view.owned) { return keyEquals(metadata, value) }
        let length = view.sourceLength
        if ((metadata & COMPACT_KEY_OWNED_MASK) != 0u64) {
            let bytes = unsafe { strings[Int64(metadata & COMPACT_KEY_PAYLOAD_MASK)].rawData() }
            if (bytes.size != length) { return false }
            for (offset in 0..length) {
                if (bytes[offset] != source[view.sourceStart + offset]) { return false }
            }
            return true
        }
        if (Int64(metadata & COMPACT_KEY_LENGTH_MASK) != length) { return false }
        let storedStart = Int64((metadata >> 32) & COMPACT_KEY_OFFSET_MASK)
        for (offset in 0..length) {
            if (source[storedStart + offset] != source[view.sourceStart + offset]) { return false }
        }
        true
    }

    func keyViewText(view: JsonObjectKeyView): String {
        if (let Some(value) <- view.owned) { return value }
        unsafe { String.fromUtf8Unchecked(source[view.sourceStart..view.sourceStart + view.sourceLength]) }
    }

    func keyHash(view: JsonObjectKeyView): Int32 {
        keyHashCalculations++
        let hash = if (let Some(value) <- view.owned) {
            value.hashCode()
        } else {
            compactWyhashRange(source, view.sourceStart, view.sourceLength)
        }
        Int32(hash & 0x7FFF_FFFF)
    }

    func keyHash(metadata: UInt64): Int32 {
        keyHashCalculations++
        if ((metadata & COMPACT_KEY_OWNED_MASK) != 0u64) {
            return Int32(strings[Int64(metadata & COMPACT_KEY_PAYLOAD_MASK)].hashCode() & 0x7FFF_FFFF)
        }
        let start = Int64((metadata >> 32) & COMPACT_KEY_OFFSET_MASK)
        let length = Int64(metadata & COMPACT_KEY_LENGTH_MASK)
        Int32(compactWyhashRange(source, start, length) & 0x7FFF_FFFF)
    }

    func kindAt(index: Int64): JsonKind {
        let code = kinds[index]
        match {
            case code == COMPACT_NULL => JsNull
            case code == COMPACT_BOOL => JsBool
            case code == COMPACT_INT => JsInt
            case code == COMPACT_NUMBER => JsNumberLiteral
            case code == COMPACT_STRING => JsString
            case code == COMPACT_ARRAY || code == COMPACT_INT_ARRAY || code == COMPACT_STRING_ARRAY ||
                code == COMPACT_NUMBER_ARRAY => JsArray
            case _ => JsObject
        }
    }

    func sizeAt(index: Int64): Int64 {
        if (kinds[index] == COMPACT_ARRAY || kinds[index] == COMPACT_INT_ARRAY ||
            kinds[index] == COMPACT_STRING_ARRAY || kinds[index] == COMPACT_NUMBER_ARRAY ||
            kinds[index] == COMPACT_OBJECT) { second[index] } else { 0 }
    }

    func arrayValueAt(index: Int64, item: Int64): Option<CompactJsonValue> {
        if (item < 0 || item >= second[index]) {
            return None<CompactJsonValue>
        }
        if (kinds[index] == COMPACT_INT_ARRAY) {
            return Some(CompactJsonValue(this, -1, COMPACT_INT, intValues[first[index] + item]))
        }
        if (kinds[index] == COMPACT_STRING_ARRAY) {
            return Some(CompactJsonValue(this, -1, COMPACT_STRING, first[index] + item))
        }
        if (kinds[index] == COMPACT_NUMBER_ARRAY) {
            let position = first[index] + item
            return Some(CompactJsonValue(this, -1,
                if (numberKinds[position]) { COMPACT_INT } else { COMPACT_NUMBER }, numberPayloads[position]))
        }
        if (kinds[index] != COMPACT_ARRAY) { return None<CompactJsonValue> }
        Some(CompactJsonValue(this, arrayChildren[first[index] + item]))
    }

    func objectValueAt(index: Int64, name: String): Option<CompactJsonValue> {
        if (kinds[index] != COMPACT_OBJECT) { return None<CompactJsonValue> }
        let start = first[index]
        if (second[index] > COMPACT_LINEAR_OBJECT_LIMIT) {
            let cacheKey = index.toString() + "\u{0000}" + name
            if (let Some(position) <- lookupCache.get(cacheKey)) {
                if (position < 0) { return None<CompactJsonValue> }
                if (objectKinds[position] == COMPACT_OBJECT_NODE) {
                    return Some(CompactJsonValue(this, objectValues[position]))
                }
                return Some(CompactJsonValue(this, -1, Int64(objectKinds[position]), objectValues[position]))
            }
            for (offset in 0..second[index]) {
                if (keyEquals(objectKeys[start + offset], name)) {
                    let position = start + offset
                    lookupCache[cacheKey] = position
                    if (objectKinds[position] == COMPACT_OBJECT_NODE) {
                        return Some(CompactJsonValue(this, objectValues[position]))
                    }
                    return Some(CompactJsonValue(this, -1, Int64(objectKinds[position]), objectValues[position]))
                }
            }
            lookupCache[cacheKey] = -1
            return None<CompactJsonValue>
        }
        for (offset in 0..second[index]) {
            if (keyEquals(objectKeys[start + offset], name)) {
                let position = start + offset
                if (objectKinds[position] == COMPACT_OBJECT_NODE) {
                    return Some(CompactJsonValue(this, objectValues[position]))
                }
                return Some(CompactJsonValue(this, -1, Int64(objectKinds[position]), objectValues[position]))
            }
        }
        None<CompactJsonValue>
    }

    func stringAt(index: Int64): String {
        if (kinds[index] != COMPACT_STRING) { throw JsonException("Expected string value") }
        strings[first[index]]
    }

    func intAt(index: Int64): Int64 {
        if (kinds[index] != COMPACT_INT) { throw JsonException("Expected int value") }
        first[index]
    }

    func boolAt(index: Int64): Bool {
        if (kinds[index] != COMPACT_BOOL) { throw JsonException("Expected bool value") }
        first[index] != 0
    }

    func materializeAt(index: Int64): JsonNode {
        let code = kinds[index]
        match {
            case code == COMPACT_NULL => JsonNullValue()
            case code == COMPACT_BOOL => JsonBoolValue(first[index] != 0)
            case code == COMPACT_INT => JsonIntValue(first[index])
            case code == COMPACT_NUMBER => JsonNumberLiteralValue.fromParsedLiteral(strings[first[index]])
            case code == COMPACT_STRING => JsonStringValue(strings[first[index]])
            case code == COMPACT_ARRAY =>
                let result = JsonArrayValue()
                let start = first[index]
                for (offset in 0..second[index]) { result.add(materializeAt(arrayChildren[start + offset])) }
                result
            case code == COMPACT_INT_ARRAY =>
                let result = JsonArrayValue(); let start = first[index]
                for (offset in 0..second[index]) { result.add(JsonIntValue(intValues[start + offset])) }
                result
            case code == COMPACT_STRING_ARRAY =>
                let result = JsonArrayValue(); let start = first[index]
                for (offset in 0..second[index]) { result.add(JsonStringValue(strings[start + offset])) }
                result
            case code == COMPACT_NUMBER_ARRAY =>
                let result = JsonArrayValue(); let start = first[index]
                for (offset in 0..second[index]) {
                    let position = start + offset
                    if (numberKinds[position]) { result.add(JsonIntValue(numberPayloads[position])) }
                    else { result.add(JsonNumberLiteralValue.fromParsedLiteral(strings[numberPayloads[position]])) }
                }
                result
            case _ =>
                let result = JsonObjectValue()
                let start = first[index]
                for (offset in 0..second[index]) {
                    let position = start + offset
                    let value = if (objectKinds[position] == COMPACT_OBJECT_NODE) {
                        materializeAt(objectValues[position])
                    } else {
                        materializeInline(Int64(objectKinds[position]), objectValues[position])
                    }
                    result.put(keyText(objectKeys[position]), value)
                }
                result
        }
    }

    private func writeAt(index: Int64, writer: JsonDirectWriter): Unit {
        let code = kinds[index]
        match {
            case code == COMPACT_NULL => writer.writeNull()
            case code == COMPACT_BOOL => writer.writeBool(first[index] != 0)
            case code == COMPACT_INT => writer.writeInt64(first[index])
            case code == COMPACT_NUMBER => writer.writeRawNumber(strings[first[index]])
            case code == COMPACT_STRING => writer.writeString(strings[first[index]])
            case code == COMPACT_ARRAY =>
                writer.startArray()
                let start = first[index]
                for (offset in 0..second[index]) { writeAt(arrayChildren[start + offset], writer) }
                writer.endArray()
            case code == COMPACT_INT_ARRAY =>
                writer.startArray(); let start = first[index]
                for (offset in 0..second[index]) { writer.writeInt64(intValues[start + offset]) }
                writer.endArray()
            case code == COMPACT_STRING_ARRAY =>
                writer.startArray(); let start = first[index]
                for (offset in 0..second[index]) { writer.writeString(strings[start + offset]) }
                writer.endArray()
            case code == COMPACT_NUMBER_ARRAY =>
                writer.startArray(); let start = first[index]
                for (offset in 0..second[index]) {
                    let position = start + offset
                    if (numberKinds[position]) { writer.writeInt64(numberPayloads[position]) }
                    else { writer.writeRawNumber(strings[numberPayloads[position]]) }
                }
                writer.endArray()
            case _ =>
                writer.startObject()
                let start = first[index]
                for (offset in 0..second[index]) {
                    let position = start + offset
                    writer.writeName(keyText(objectKeys[position]))
                    if (objectKinds[position] == COMPACT_OBJECT_NODE) { writeAt(objectValues[position], writer) }
                    else { writeInline(Int64(objectKinds[position]), objectValues[position], writer) }
                }
                writer.endObject()
        }
    }

    private func materializeInline(kind: Int64, payload: Int64): JsonNode {
        match {
            case kind == COMPACT_NULL => JsonNullValue()
            case kind == COMPACT_BOOL => JsonBoolValue(payload != 0)
            case kind == COMPACT_INT => JsonIntValue(payload)
            case kind == COMPACT_NUMBER => JsonNumberLiteralValue.fromParsedLiteral(strings[payload])
            case _ => JsonStringValue(strings[payload])
        }
    }

    private func writeInline(kind: Int64, payload: Int64, writer: JsonDirectWriter): Unit {
        match {
            case kind == COMPACT_NULL => writer.writeNull()
            case kind == COMPACT_BOOL => writer.writeBool(payload != 0)
            case kind == COMPACT_INT => writer.writeInt64(payload)
            case kind == COMPACT_NUMBER => writer.writeRawNumber(strings[payload])
            case _ => writer.writeString(strings[payload])
        }
    }
}

/// A cheap value view. It contains only a document reference and node index;
/// parsing never creates one view per node.
public struct CompactJsonValue {
    private let document: CompactJsonDocument
    private let index: Int64
    private let inlineKind: Int64
    private let inlinePayload: Int64

    public init(document: CompactJsonDocument, index: Int64) {
        this.document = document; this.index = index; this.inlineKind = -1; this.inlinePayload = 0
    }

    init(document: CompactJsonDocument, index: Int64, inlineKind: Int64, inlinePayload: Int64) {
        this.document = document; this.index = index; this.inlineKind = inlineKind; this.inlinePayload = inlinePayload
    }

    public func kind(): JsonKind {
        if (inlineKind == COMPACT_NULL) { JsNull }
        else if (inlineKind == COMPACT_BOOL) { JsBool }
        else if (inlineKind == COMPACT_INT) { JsInt }
        else if (inlineKind == COMPACT_NUMBER) { JsNumberLiteral }
        else if (inlineKind == COMPACT_STRING) { JsString }
        else { document.kindAt(index) }
    }
    public func size(): Int64 { if (inlineKind >= 0) { 0 } else { document.sizeAt(index) } }
    public func get(item: Int64): Option<CompactJsonValue> {
        if (inlineKind >= 0) { None<CompactJsonValue> } else { document.arrayValueAt(index, item) }
    }
    public func get(name: String): Option<CompactJsonValue> {
        if (inlineKind >= 0) { None<CompactJsonValue> } else { document.objectValueAt(index, name) }
    }
    public func asString(): String { if (inlineKind == COMPACT_STRING) { document.strings[inlinePayload] } else { document.stringAt(index) } }
    public func asInt64(): Int64 { if (inlineKind == COMPACT_INT) { inlinePayload } else { document.intAt(index) } }
    public func asBool(): Bool { if (inlineKind == COMPACT_BOOL) { inlinePayload != 0 } else { document.boolAt(index) } }
    public func materialize(): JsonNode {
        if (inlineKind == COMPACT_NULL) { JsonNullValue() }
        else if (inlineKind == COMPACT_BOOL) { JsonBoolValue(inlinePayload != 0) }
        else if (inlineKind == COMPACT_INT) { JsonIntValue(inlinePayload) }
        else if (inlineKind == COMPACT_NUMBER) {
            JsonNumberLiteralValue.fromParsedLiteral(document.strings[inlinePayload])
        }
        else if (inlineKind == COMPACT_STRING) { JsonStringValue(document.strings[inlinePayload]) }
        else { document.materializeAt(index) }
    }
}

private class CompactJsonParser {
    private let document: CompactJsonDocument
    private let reader: JsonFastReader
    private let config: JsonReadConfig
    private var depth: Int64 = 0
    private var numericTape: Option<JsonNativeNumericTape> = None<JsonNativeNumericTape>

    public init(document: CompactJsonDocument, reader: JsonFastReader, config: JsonReadConfig) {
        this.document = document; this.reader = reader; this.config = config
    }

    public func parse(): Int64 {
        let result = parseValue()
        reader.expectEnd()
        if (let Some(tape) <- numericTape) {
            document.tapeCalls = tape.callCount()
            document.tapeClassifiedBytes = tape.classifiedByteCount()
            document.tapeEvents = tape.eventCount()
            document.tapeEarlyRefills = tape.earlyRefillCount()
        }
        result
    }

    private func parseValue(): Int64 {
        if (depth >= config.maxDepth) { throw JsonException("Maximum JSON depth ${config.maxDepth} exceeded", code: "max_depth") }
        depth++
        try {
            match (reader.peekRawKind()) {
                case JsNull => let _ = reader.tryReadRawNull(); document.addNode(COMPACT_NULL)
                case JsBool => document.addNode(COMPACT_BOOL, firstValue: if (reader.readRawBool()) { 1 } else { 0 })
                case JsString => document.addNode(COMPACT_STRING, firstValue: document.addString(reader.readRawString()))
                case JsArray => parseArray()
                case JsObject => parseObject()
                case _ => parseNumber()
            }
        } finally { depth-- }
    }

    private func parseNumber(): Int64 {
        if (!reader.tryReadRawNumberToken()) { throw JsonException("Expected number", code: "parse_error") }
        if (!jsonReadConfigPreservesNumberLiterals(config) && reader.currentRawTokenNumberScale() == 0 &&
            !reader.currentRawTokenNumberHasExponent() && reader.currentRawTokenNumberSmallUnscaledValid()) {
            let magnitude = reader.currentRawTokenNumberSmallUnscaled()
            let value = if (reader.currentRawTokenNumberNegative()) { -magnitude } else { magnitude }
            return document.addNode(COMPACT_INT, firstValue: value)
        }
        let literal = reader.currentRawTokenAsciiString()
        if (!jsonReadConfigPreservesNumberLiterals(config) && reader.currentRawTokenNumberScale() == 0 &&
            !reader.currentRawTokenNumberHasExponent()) {
            try { return document.addNode(COMPACT_INT, firstValue: Int64.parse(literal)) } catch (_: Exception) {}
        }
        document.addNode(COMPACT_NUMBER, firstValue: document.addString(literal))
    }

    private func tryReadNumberFromTape(): Bool {
        if (document.source.size < COMPACT_TAPE_MIN_BYTES) { return false }
        if (reader.peekRawKind() != JsNumberLiteral) { return false }
        if (numericTape.isNone()) { numericTape = Some(JsonNativeNumericTape(COMPACT_TAPE_CAP)) }
        let position = reader.position()
        match (numericTape) {
            case Some(tape) => match (tape.tokenAt(document.source, position, COMPACT_TAPE_PAGE_BYTES)) {
                case Some(token) =>
                    reader.adoptRawNumberToken(token[0], token[1], token[2], token[3])
                    true
                case None => false
            }
            case None => false
        }
    }

    private func parseArray(): Int64 {
        reader.startRawArray()
        let contentStart = reader.position()
        if (let Some(result) <- tryParseCompactNumericArray(contentStart)) { return result }
        if (let Some(result) <- tryParseCompactStringArray(contentStart)) { return result }
        let local = ArrayList<Int64>()
        var first = true
        while (reader.hasRawArrayItem(first)) {
            reader.beforeRawArrayItem(first)
            local.add(parseValue())
            first = false
        }
        reader.endRawArray()
        let start = document.arrayChildren.size
        document.arrayChildren.add(all: local)
        document.addNode(COMPACT_ARRAY, firstValue: start, secondValue: local.size)
    }

    private func tryParseCompactStringArray(contentStart: Int64): Option<Int64> {
        let start = document.strings.size
        var first = true
        while (reader.hasRawArrayItem(first)) {
            reader.beforeRawArrayItem(first)
            if (reader.peekRawKind() != JsString) {
                while (document.strings.size > start) { document.strings.remove(at: document.strings.size - 1) }
                reader.rewind(contentStart); return None<Int64>
            }
            document.strings.add(reader.readRawString()); first = false
        }
        if (document.strings.size == start) { reader.rewind(contentStart); return None<Int64> }
        reader.endRawArray()
        Some(document.addNode(COMPACT_STRING_ARRAY, firstValue: start, secondValue: document.strings.size - start))
    }

    private func tryParseCompactNumericArray(contentStart: Int64): Option<Int64> {
        if (let Some(result) <- tryParseNativeCompactNumericArray(contentStart)) { return Some(result) }
        let intStart = document.intValues.size
        let numberStart = document.numberPayloads.size
        let stringStart = document.strings.size
        var numberMode = false
        var first = true
        while (reader.hasRawArrayItem(first)) {
            reader.beforeRawArrayItem(first)
            if (!tryReadNumberFromTape() && !reader.tryReadRawNumberToken()) {
                while (document.intValues.size > intStart) { document.intValues.remove(at: document.intValues.size - 1) }
                while (document.numberPayloads.size > numberStart) {
                    document.numberPayloads.remove(at: document.numberPayloads.size - 1)
                    document.numberKinds.remove(at: document.numberKinds.size - 1)
                }
                while (document.strings.size > stringStart) { document.strings.remove(at: document.strings.size - 1) }
                reader.rewind(contentStart); return None<Int64>
            }
            var storedInt = false
            var payload: Int64 = 0
            if (!jsonReadConfigPreservesNumberLiterals(config) && reader.currentRawTokenNumberScale() == 0 &&
                !reader.currentRawTokenNumberHasExponent()) {
                if (reader.currentRawTokenNumberSmallUnscaledValid()) {
                    let magnitude = reader.currentRawTokenNumberSmallUnscaled()
                    payload = if (reader.currentRawTokenNumberNegative()) { -magnitude } else { magnitude }
                    storedInt = true
                } else {
                    try { payload = Int64.parse(reader.currentRawTokenAsciiString()); storedInt = true } catch (_: Exception) {}
                }
            }
            if (!storedInt) { payload = document.addString(reader.currentRawTokenAsciiString()) }
            if (!numberMode && storedInt) {
                document.intValues.add(payload)
            } else {
                if (!numberMode) {
                    for (position in intStart..document.intValues.size) {
                        document.numberKinds.add(true)
                        document.numberPayloads.add(document.intValues[position])
                    }
                    while (document.intValues.size > intStart) {
                        document.intValues.remove(at: document.intValues.size - 1)
                    }
                    numberMode = true
                }
                document.numberKinds.add(storedInt)
                document.numberPayloads.add(payload)
            }
            first = false
        }
        let count = if (numberMode) { document.numberPayloads.size - numberStart } else { document.intValues.size - intStart }
        if (count == 0) { reader.rewind(contentStart); return None<Int64> }
        reader.endRawArray()
        if (numberMode) {
            Some(document.addNode(COMPACT_NUMBER_ARRAY, firstValue: numberStart, secondValue: count))
        } else {
            Some(document.addNode(COMPACT_INT_ARRAY, firstValue: intStart, secondValue: count))
        }
    }

    private func tryParseNativeCompactNumericArray(contentStart: Int64): Option<Int64> {
        // The current bulk contract targets large standalone numeric documents.
        // Nested geometry arrays are deliberately left to the allocation-free
        // scalar reader until a future structural scanner can batch many arrays
        // in one call.
        if (depth != 1) { return None<Int64> }
        if (reader.peekRawKind() != JsNumberLiteral) { return None<Int64> }
        // The native contract amortizes one FFI call over many tokens. Canada
        // and similar geometry corpora contain millions of two-number arrays;
        // avoid allocating a chunk buffer for those deliberately short arrays.
        var probe = contentStart
        let probeEnd = if (contentStart + COMPACT_NUMERIC_BULK_MIN_BYTES < document.source.size) {
            contentStart + COMPACT_NUMERIC_BULK_MIN_BYTES
        } else { document.source.size }
        while (probe < probeEnd) {
            if (document.source[probe] == b']') { return None<Int64> }
            probe++
        }
        let intStart = document.intValues.size
        let numberStart = document.numberPayloads.size
        let stringStart = document.strings.size
        var numberMode = false
        var next = contentStart
        var total: Int64 = 0
        while (true) {
            let chunk = match (jsonNativeScanNumericArrayChunk(
                document.source, next, true, COMPACT_NUMERIC_BULK_CAP)) {
                case Some(value) => value
                case None =>
                    while (document.intValues.size > intStart) { document.intValues.remove(at: document.intValues.size - 1) }
                    while (document.numberPayloads.size > numberStart) {
                        document.numberPayloads.remove(at: document.numberPayloads.size - 1)
                        document.numberKinds.remove(at: document.numberKinds.size - 1)
                    }
                    while (document.strings.size > stringStart) { document.strings.remove(at: document.strings.size - 1) }
                    reader.rewind(contentStart)
                    return None<Int64>
            }
            for (offset in 0..chunk.count) {
                let flags = chunk.flags(offset)
                let scale = Int64((flags >> 8) & 0xFFFF_FFFFu64)
                let exponent = (flags & 2u64) != 0u64
                var storedInt = false
                var payload: Int64 = 0
                if (!jsonReadConfigPreservesNumberLiterals(config) && scale == 0 && !exponent) {
                    if ((flags & 4u64) != 0u64) {
                        let magnitude = chunk.magnitude(offset)
                        payload = if ((flags & 1u64) != 0u64) { -magnitude } else { magnitude }
                        storedInt = true
                    } else {
                        let literal = unsafe { String.fromUtf8Unchecked(
                            document.source[chunk.tokenStart(offset)..chunk.tokenEnd(offset)]) }
                        try { payload = Int64.parse(literal); storedInt = true } catch (_: Exception) {}
                    }
                }
                if (!storedInt) {
                    payload = document.addString(unsafe { String.fromUtf8Unchecked(
                        document.source[chunk.tokenStart(offset)..chunk.tokenEnd(offset)]) })
                }
                if (!numberMode && storedInt) {
                    document.intValues.add(payload)
                } else {
                    if (!numberMode) {
                        for (position in intStart..document.intValues.size) {
                            document.numberKinds.add(true)
                            document.numberPayloads.add(document.intValues[position])
                        }
                        while (document.intValues.size > intStart) {
                            document.intValues.remove(at: document.intValues.size - 1)
                        }
                        numberMode = true
                    }
                    document.numberKinds.add(storedInt)
                    document.numberPayloads.add(payload)
                }
            }
            total += chunk.count
            next = chunk.next
            if (chunk.fallback) {
                if (total == 0) { reader.rewind(contentStart); return None<Int64> }
                return Some(continueGenericArrayAfterNumericPrefix(
                    next, intStart, numberStart, numberMode, total))
            }
            if (chunk.done) { break }
        }
        if (total == 0) { reader.rewind(contentStart); return None<Int64> }
        reader.rewind(next)
        if (numberMode) {
            Some(document.addNode(COMPACT_NUMBER_ARRAY, firstValue: numberStart, secondValue: total))
        } else {
            Some(document.addNode(COMPACT_INT_ARRAY, firstValue: intStart, secondValue: total))
        }
    }

    private func continueGenericArrayAfterNumericPrefix(stop: Int64, intStart: Int64,
        numberStart: Int64, numberMode: Bool, total: Int64): Int64 {
        let local = ArrayList<Int64>()
        if (numberMode) {
            for (offset in numberStart..document.numberPayloads.size) {
                if (document.numberKinds[offset]) {
                    local.add(document.addNode(COMPACT_INT, firstValue: document.numberPayloads[offset]))
                } else {
                    local.add(document.addNode(COMPACT_NUMBER, firstValue: document.numberPayloads[offset]))
                }
            }
            while (document.numberPayloads.size > numberStart) {
                document.numberPayloads.remove(at: document.numberPayloads.size - 1)
                document.numberKinds.remove(at: document.numberKinds.size - 1)
            }
        } else {
            for (offset in intStart..document.intValues.size) {
                local.add(document.addNode(COMPACT_INT, firstValue: document.intValues[offset]))
            }
            while (document.intValues.size > intStart) {
                document.intValues.remove(at: document.intValues.size - 1)
            }
        }
        if (local.size != total) {
            throw IllegalStateException("Bulk numeric prefix size mismatch")
        }
        // The scanner consumed the separator before stop but not the first byte
        // of the non-numeric value. Continue exactly there; no prefix is read a
        // second time.
        reader.rewind(stop)
        local.add(parseValue())
        while (reader.hasRawArrayItem(false)) {
            reader.beforeRawArrayItem(false)
            local.add(parseValue())
        }
        reader.endRawArray()
        let childStart = document.arrayChildren.size
        document.arrayChildren.add(all: local)
        document.addNode(COMPACT_ARRAY, firstValue: childStart, secondValue: local.size)
    }

    private func parseObject(): Int64 {
        reader.startRawObject()
        let keys = ArrayList<UInt64>()
        let valueKinds = ArrayList<Byte>()
        let values = ArrayList<Int64>()
        var positions = None<CompactObjectPositions>
        var first = true
        while (reader.hasRawObjectField(first)) {
            let keyView = reader.readRawObjectKeyView(first)
            // Source-backed keys deliberately bypass the String HashMap. Their
            // canonical metadata is already the minimal offset/length pair;
            // escaped keys keep the bounded owned-key dictionary.
            let key = if (keyView.isSource()) {
                document.sourceViewKeys++
                document.sourceKey(keyView)
            } else {
                document.ownedKeyViews++
                let name = keyView.owned.getOrThrow()
                match (document.indexedKey(name)) {
                    case Some(index) => index
                    case None => document.addOwnedKey(name)
                }
            }
            let value = parseValue()
            var valueKind = COMPACT_OBJECT_NODE
            var valuePayload = value
            if (value == document.kinds.size - 1) {
                let kind = document.kinds[value]
                if (kind <= COMPACT_STRING) {
                    valueKind = UInt8(kind)
                    valuePayload = document.first[value]
                    document.kinds.remove(at: value)
                    document.first.remove(at: value)
                    document.second.remove(at: value)
                }
            }
            var existing: Int64 = -1
            var duplicateHash: Int32 = 0
            var hasDuplicateHash = false
            var insertedByLookup = false
            if (let Some(index) <- positions) {
                duplicateHash = index.hashOf(keyView)
                hasDuplicateHash = true
                existing = index.findOrInsertWithHash(keyView, duplicateHash, keys, keys.size)
                insertedByLookup = existing < 0
            } else {
                for (offset in 0..keys.size) {
                    if (document.keyEquals(keys[offset], keyView)) { existing = offset; break }
                }
                if (keys.size == 8) {
                    let index = CompactObjectPositions(document)
                    for (offset in 0..keys.size) {
                        index.addWithHash(document.keyHash(keys[offset]), offset)
                    }
                    positions = Some(index)
                }
            }
            if (existing >= 0) {
                if (config.rejectsDuplicateKeys()) {
                    throw JsonException("Duplicate object key '${document.keyViewText(keyView)}'", code: "parse_error")
                }
                valueKinds[existing] = valueKind
                values[existing] = valuePayload
            } else {
                keys.add(key); valueKinds.add(valueKind); values.add(valuePayload)
                if (!insertedByLookup) {
                    if (let Some(index) <- positions) {
                        if (hasDuplicateHash) { index.addWithHash(duplicateHash, keys.size - 1) }
                        else { index.addWithHash(index.hashOf(keyView), keys.size - 1) }
                    }
                }
            }
            first = false
        }
        reader.endRawObject()
        if (let Some(index) <- positions) {
            document.duplicateLogicalBytes = max(document.duplicateLogicalBytes, index.logicalBytes())
            document.duplicateCapacityBytes = max(document.duplicateCapacityBytes, index.capacityBytes())
            document.duplicateGrowCount = max(document.duplicateGrowCount, index.growCount())
            document.duplicatePeakOverlapBytes = max(document.duplicatePeakOverlapBytes, index.peakOverlapBytes())
            document.duplicateLargestOldBytes = max(document.duplicateLargestOldBytes, index.largestOldBytes())
            document.duplicateLargestNewBytes = max(document.duplicateLargestNewBytes, index.largestNewBytes())
            document.duplicateRehashEntries = max(document.duplicateRehashEntries, index.rehashEntryCount())
            document.duplicateRehashNanos = max(document.duplicateRehashNanos, index.rehashTimeNanos())
            document.duplicateLookupCount = max(document.duplicateLookupCount, index.lookupCount())
            document.duplicateInsertCount = max(document.duplicateInsertCount, index.insertCount())
            document.duplicateProbeCount = max(document.duplicateProbeCount, index.probeCount())
            document.duplicateExactEqualityCount = max(document.duplicateExactEqualityCount, index.exactEqualityCount())
            document.duplicateMaxProbe = max(document.duplicateMaxProbe, index.maxProbeCount())
            document.duplicateGrowthTrace = index.growthTrace()
        }
        let start = document.objectKeys.size
        for (offset in 0..keys.size) {
            document.objectKeys.add(keys[offset]); document.objectKinds.add(valueKinds[offset]); document.objectValues.add(values[offset])
        }
        document.addNode(COMPACT_OBJECT, firstValue: start, secondValue: keys.size)
    }
}

// Parse-time duplicate index for large objects. Unlike HashMap<String, Int64>,
// it never owns the key text: only the hash, entry position, and collision link
// remain live. Equality is checked against the document-owned packed key range,
// so unique source-sliced keys do not become millions of temporary live Strings.
private class CompactPartitionSlots {
    private var slots = Array<UInt64>(16, repeat: COMPACT_OPEN_INDEX_EMPTY)
    private var count: Int64 = 0
    var grows: Int64 = 0
    var probes: Int64 = 0
    var exactEqualities: Int64 = 0
    var maxProbe: Int64 = 0
    var rehashEntries: Int64 = 0
    var peakOverlap: Int64 = 0
    var largestOld: Int64 = 0
    var largestNew: Int64 = 0

    func find(compactHash: Int32, name: String, keys: ArrayList<UInt64>, document: CompactJsonDocument): Int64 {
        var slot = Int64(compactHash) & (slots.size - 1)
        var localProbes: Int64 = 1
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            let packed = slots[slot]
            let position = Int64(packed & 0xFFFF_FFFFu64)
            if (Int32(packed >> 32) == compactHash) {
                exactEqualities++
                if (document.keyEquals(keys[position], name)) {
                    probes += localProbes; maxProbe = max(maxProbe, localProbes)
                    return position
                }
            }
            slot = (slot + 1) & (slots.size - 1); localProbes++
        }
        probes += localProbes; maxProbe = max(maxProbe, localProbes)
        -1
    }

    func add(compactHash: Int32, position: Int64): Unit {
        if ((count + 1) * 10 >= slots.size * 7) { grow() }
        insertPacked((UInt64(UInt32(compactHash)) << 32) | UInt64(UInt32(position)))
        count++
    }

    private func insertPacked(packed: UInt64): Unit {
        var slot = Int64(Int32(packed >> 32)) & (slots.size - 1)
        var localProbes: Int64 = 1
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            slot = (slot + 1) & (slots.size - 1); localProbes++
        }
        slots[slot] = packed; probes += localProbes; maxProbe = max(maxProbe, localProbes)
    }

    private func grow(): Unit {
        let old = slots
        let oldBytes = old.size * 8
        let newBytes = old.size * 16
        peakOverlap = max(peakOverlap, oldBytes + newBytes)
        largestOld = max(largestOld, oldBytes); largestNew = max(largestNew, newBytes)
        slots = Array<UInt64>(old.size * 2, repeat: COMPACT_OPEN_INDEX_EMPTY)
        var moved: Int64 = 0
        for (packed in old) {
            if (packed == COMPACT_OPEN_INDEX_EMPTY) { continue }
            insertPacked(packed); moved++
        }
        grows++; rehashEntries += moved
    }

    func logicalBytes(): Int64 { count * 8 }
    func capacityBytes(): Int64 { slots.size * 8 }
}

// Partitioning preserves the exact duplicate invariant while restricting a
// resize to one hash partition. The directory is lazy at the backing-array
// level: an object allocates a local table only for partitions it reaches.
private class CompactPartitionedObjectPositions {
    private let document: CompactJsonDocument
    private let partitionCount: Int64 = 1024
    private let partitions = ArrayList<Option<CompactPartitionSlots>>()
    private var count: Int64 = 0
    private var lookups: Int64 = 0
    private var inserts: Int64 = 0

    init(document: CompactJsonDocument) {
        this.document = document
        for (_ in 0..partitionCount) { partitions.add(None<CompactPartitionSlots>) }
    }

    func get(name: String, keys: ArrayList<UInt64>): Int64 {
        let compactHash = compactHashOf(name)
        let index = partitionFor(compactHash)
        if (let Some(partition) <- partitions[index]) {
            return partition.find(compactHash, name, keys, document)
        }
        -1
    }

    func add(name: String, position: Int64): Unit {
        if (position > Int64(Int32.Max)) {
            throw JsonException("Compact object has too many fields", code: "document_too_large")
        }
        inserts++
        let compactHash = compactHashOf(name)
        let index = partitionFor(compactHash)
        match (partitions[index]) {
            case Some(partition) => partition.add(compactHash, position)
            case None =>
                let partition = CompactPartitionSlots()
                partition.add(compactHash, position)
                partitions[index] = Some(partition)
        }
        count++
    }

    private func partitionFor(hash: Int32): Int64 {
        Int64((UInt32(hash) >> 21) & UInt32(partitionCount - 1))
    }

    private func compactHashOf(name: String): Int32 { Int32(name.hashCode() & 0x7FFF_FFFF) }

    func logicalBytes(): Int64 { count * 8 }
    func capacityBytes(): Int64 {
        var total: Int64 = partitionCount * 8
        for (partition in partitions) { if (let Some(value) <- partition) { total += value.capacityBytes() } }
        total
    }
    func growCount(): Int64 {
        var total: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { total += value.grows } }
        total
    }
    func peakOverlapBytes(): Int64 {
        var result: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { result = max(result, value.peakOverlap) } }
        result
    }
    func largestOldBytes(): Int64 {
        var result: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { result = max(result, value.largestOld) } }
        result
    }
    func largestNewBytes(): Int64 {
        var result: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { result = max(result, value.largestNew) } }
        result
    }
    func rehashEntryCount(): Int64 {
        var total: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { total += value.rehashEntries } }
        total
    }
    func rehashTimeNanos(): Int64 { 0 }
    func lookupCount(): Int64 { lookups }
    func insertCount(): Int64 { inserts }
    func probeCount(): Int64 {
        var total: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { total += value.probes } }
        total
    }
    func exactEqualityCount(): Int64 {
        var total: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { total += value.exactEqualities } }
        total
    }
    func maxProbeCount(): Int64 {
        var result: Int64 = 0
        for (partition in partitions) { if (let Some(value) <- partition) { result = max(result, value.maxProbe) } }
        result
    }
    func growthTrace(): String { "partitioned:${partitionCount}" }
}

private class CompactRegionBucket {
    var localDepth: Int64
    var slots: Array<UInt64>
    var count: Int64 = 0
    var probes: Int64 = 0
    var exactEqualities: Int64 = 0
    var maxProbe: Int64 = 0
    var grows: Int64 = 0
    var rehashEntries: Int64 = 0
    var peakOverlap: Int64 = 0

    init(localDepth: Int64, capacity!: Int64 = 16) {
        this.localDepth = localDepth
        this.slots = Array<UInt64>(capacity, repeat: COMPACT_OPEN_INDEX_EMPTY)
    }

    func find(compactHash: Int32, name: String, keys: ArrayList<UInt64>, document: CompactJsonDocument): Int64 {
        let mixed = UInt32(compactHash) ^ (UInt32(compactHash) >> 16)
        var slot = Int64(mixed) & (slots.size - 1)
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            let packed = slots[slot]
            let position = Int64(packed & 0xFFFF_FFFFu64)
            if (Int32(packed >> 32) == compactHash) {
                exactEqualities++
                if (document.keyEquals(keys[position], name)) {
                    return position
                }
            }
            slot = (slot + 1) & (slots.size - 1)
        }
        -1
    }

    // False means the caller must split this fixed-size region.
    func prepareInsert(): Bool {
        if ((count + 1) * 10 < slots.size * 7) { return true }
        if (slots.size >= COMPACT_DUPLICATE_REGION_SLOTS) { return false }
        let old = slots
        let newBytes = old.size * 16
        peakOverlap = max(peakOverlap, old.size * 8 + newBytes)
        slots = Array<UInt64>(old.size * 2, repeat: COMPACT_OPEN_INDEX_EMPTY)
        for (packed in old) {
            if (packed != COMPACT_OPEN_INDEX_EMPTY) { insertPacked(packed) }
        }
        grows++
        true
    }

    func add(compactHash: Int32, position: Int64): Unit {
        insertPacked((UInt64(UInt32(compactHash)) << 32) | UInt64(UInt32(position)))
        count++
    }

    func resetForSplit(): Array<UInt64> {
        let old = slots
        slots = Array<UInt64>(old.size, repeat: COMPACT_OPEN_INDEX_EMPTY)
        count = 0
        peakOverlap = max(peakOverlap, old.size * 24)
        grows++
        old
    }

    func insertPacked(packed: UInt64): Unit {
        let compactHash = UInt32(Int32(packed >> 32))
        let mixed = compactHash ^ (compactHash >> 16)
        var slot = Int64(mixed) & (slots.size - 1)
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            slot = (slot + 1) & (slots.size - 1)
        }
        slots[slot] = packed
    }
}

// Extendible region index: the directory grows cheaply, while a full bucket
// splits independently. No operation allocates a replacement for the complete
// multi-million-slot table.
private class CompactRegionObjectPositions {
    private let document: CompactJsonDocument
    private let directory = ArrayList<CompactRegionBucket>()
    private let buckets = ArrayList<CompactRegionBucket>()
    private var globalDepth: Int64 = 0
    private var count: Int64 = 0
    private var lookups: Int64 = 0
    private var inserts: Int64 = 0

    init(document: CompactJsonDocument) {
        this.document = document
        let first = CompactRegionBucket(0)
        directory.add(first); buckets.add(first)
    }

    func get(name: String, keys: ArrayList<UInt64>): Int64 {
        let compactHash = compactHashOf(name)
        getWithHash(name, compactHash, keys)
    }

    func getWithHash(name: String, compactHash: Int32, keys: ArrayList<UInt64>): Int64 {
        directory[directoryIndex(compactHash)].find(compactHash, name, keys, document)
    }

    func add(name: String, position: Int64): Unit {
        let compactHash = compactHashOf(name)
        addWithHash(compactHash, position)
    }

    func addWithHash(compactHash: Int32, position: Int64): Unit {
        if (position > Int64(Int32.Max)) {
            throw JsonException("Compact object has too many fields", code: "document_too_large")
        }
        while (true) {
            let index = directoryIndex(compactHash)
            let bucket = directory[index]
            if (bucket.prepareInsert()) {
                bucket.add(compactHash, position); count++; return
            }
            split(index, bucket)
        }
    }

    private func split(selectedIndex: Int64, bucket: CompactRegionBucket): Unit {
        let oldDepth = bucket.localDepth
        if (oldDepth == globalDepth) {
            let oldSize = directory.size
            for (index in 0..oldSize) { directory.add(directory[index]) }
            globalDepth++
        }
        bucket.localDepth = oldDepth + 1
        let fresh = CompactRegionBucket(oldDepth + 1, capacity: bucket.slots.size)
        buckets.add(fresh)
        let prefixMask = (1 << oldDepth) - 1
        let prefix = selectedIndex & prefixMask
        for (index in 0..directory.size) {
            if ((index & prefixMask) == prefix && ((index >> oldDepth) & 1) == 1) {
                directory[index] = fresh
            }
        }
        let old = bucket.resetForSplit()
        for (packed in old) {
            if (packed == COMPACT_OPEN_INDEX_EMPTY) { continue }
            let compactHash = Int32(packed >> 32)
            let target = directory[directoryIndex(compactHash)]
            target.insertPacked(packed); target.count++
        }
    }

    private func directoryIndex(hash: Int32): Int64 {
        if (globalDepth == 0) { return 0 }
        Int64(hash) & (directory.size - 1)
    }
    private func compactHashOf(name: String): Int32 { Int32(name.hashCode() & 0x7FFF_FFFF) }
    func hashOf(name: String): Int32 { compactHashOf(name) }

    func logicalBytes(): Int64 { count * 8 }
    func capacityBytes(): Int64 {
        var total = directory.size * 8
        for (bucket in buckets) { total += bucket.slots.size * 8 }
        total
    }
    func growCount(): Int64 {
        var total: Int64 = 0
        for (bucket in buckets) { total += bucket.grows }
        total
    }
    func peakOverlapBytes(): Int64 {
        var result: Int64 = 0
        for (bucket in buckets) { result = max(result, bucket.peakOverlap) }
        result
    }
    func largestOldBytes(): Int64 { COMPACT_DUPLICATE_REGION_SLOTS * 8 }
    func largestNewBytes(): Int64 { COMPACT_DUPLICATE_REGION_SLOTS * 16 }
    func rehashEntryCount(): Int64 {
        var total: Int64 = 0
        for (bucket in buckets) { total += bucket.rehashEntries }
        total
    }
    func rehashTimeNanos(): Int64 { 0 }
    func lookupCount(): Int64 { lookups }
    func insertCount(): Int64 { inserts }
    func probeCount(): Int64 {
        var total: Int64 = 0
        for (bucket in buckets) { total += bucket.probes }
        total
    }
    func exactEqualityCount(): Int64 {
        var total: Int64 = 0
        for (bucket in buckets) { total += bucket.exactEqualities }
        total
    }
    func maxProbeCount(): Int64 {
        var result: Int64 = 0
        for (bucket in buckets) { result = max(result, bucket.maxProbe) }
        result
    }
    func growthTrace(): String { "extendible:${COMPACT_DUPLICATE_REGION_SLOTS}:buckets=${buckets.size}:directory=${directory.size}" }
}

private class CompactObjectPositions {
    private let document: CompactJsonDocument
    // One open-addressed slot packs the 31-bit fingerprint and 32-bit entry
    // position. Equality is still checked against the document key bytes.
    private var slots = Array<UInt64>(16, repeat: COMPACT_OPEN_INDEX_EMPTY)
    private var count: Int64 = 0
    private var grows: Int64 = 0
    private var lookups: Int64 = 0
    private var inserts: Int64 = 0
    private var probes: Int64 = 0
    private var exactEqualities: Int64 = 0
    private var maxProbe: Int64 = 0
    private var rehashEntries: Int64 = 0
    private var rehashNanos: Int64 = 0
    private var peakOverlap: Int64 = 0
    private var largestOld: Int64 = 0
    private var largestNew: Int64 = 0
    private var trace: String = ""

    init(document: CompactJsonDocument) { this.document = document }

    func get(name: String, keys: ArrayList<UInt64>): Int64 {
        lookups++
        let compactHash = compactHashOf(name)
        getWithHash(name, compactHash, keys)
    }

    func getWithHash(name: String, compactHash: Int32, keys: ArrayList<UInt64>): Int64 {
        var slot = bucketFor(Int64(compactHash), slots.size)
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            let packed = slots[slot]
            let position = Int64(packed & 0xFFFF_FFFFu64)
            if (Int32(packed >> 32) == compactHash) {
                if (document.keyEquals(keys[position], name)) {
                    return position
                }
            }
            slot = (slot + 1) & (slots.size - 1)
        }
        -1
    }

    func getWithHash(view: JsonObjectKeyView, compactHash: Int32, keys: ArrayList<UInt64>): Int64 {
        lookups++
        var slot = bucketFor(Int64(compactHash), slots.size)
        var localProbes: Int64 = 1
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            let packed = slots[slot]
            let position = Int64(packed & 0xFFFF_FFFFu64)
            if (Int32(packed >> 32) == compactHash) {
                exactEqualities++
                if (document.keyEquals(keys[position], view)) {
                    probes += localProbes
                    maxProbe = max(maxProbe, localProbes)
                    return position
                }
            }
            slot = (slot + 1) & (slots.size - 1)
            localProbes++
        }
        probes += localProbes
        maxProbe = max(maxProbe, localProbes)
        -1
    }

    // The common unique-key path used to probe once to prove absence and then
    // restart from the same bucket to insert. Retain the discovered empty slot
    // and insert there. A rare grow still needs a second probe in the new table.
    func findOrInsertWithHash(view: JsonObjectKeyView, compactHash: Int32,
        keys: ArrayList<UInt64>, position: Int64): Int64 {
        if (position > Int64(Int32.Max)) {
            throw JsonException("Compact object has too many fields", code: "document_too_large")
        }
        lookups++
        var slot = bucketFor(Int64(compactHash), slots.size)
        var localProbes: Int64 = 1
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            let packed = slots[slot]
            let existing = Int64(packed & 0xFFFF_FFFFu64)
            if (Int32(packed >> 32) == compactHash) {
                exactEqualities++
                if (document.keyEquals(keys[existing], view)) {
                    probes += localProbes
                    maxProbe = max(maxProbe, localProbes)
                    return existing
                }
            }
            slot = (slot + 1) & (slots.size - 1)
            localProbes++
        }
        if ((count + 1) * 10 >= slots.size * 7) {
            probes += localProbes
            maxProbe = max(maxProbe, localProbes)
            grow()
            slot = bucketFor(Int64(compactHash), slots.size)
            localProbes = 1
            while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
                slot = (slot + 1) & (slots.size - 1)
                localProbes++
            }
        }
        slots[slot] = (UInt64(UInt32(compactHash)) << 32) | UInt64(UInt32(position))
        count++
        inserts++
        probes += localProbes
        maxProbe = max(maxProbe, localProbes)
        -1
    }

    func add(name: String, position: Int64): Unit {
        addWithHash(compactHashOf(name), position)
    }

    func addWithHash(compactHash: Int32, position: Int64): Unit {
        if (position > Int64(Int32.Max)) {
            throw JsonException("Compact object has too many fields", code: "document_too_large")
        }
        if ((count + 1) * 10 >= slots.size * 7) { grow() }
        var slot = bucketFor(Int64(compactHash), slots.size)
        while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
            slot = (slot + 1) & (slots.size - 1)
        }
        slots[slot] = (UInt64(UInt32(compactHash)) << 32) | UInt64(UInt32(position))
        count++
        inserts++
    }

    private func grow(): Unit {
        let old = slots
        let oldBytes = old.size * 8
        let newBytes = old.size * 16
        peakOverlap = max(peakOverlap, oldBytes + newBytes)
        largestOld = max(largestOld, oldBytes)
        largestNew = max(largestNew, newBytes)
        slots = Array<UInt64>(old.size * 2, repeat: COMPACT_OPEN_INDEX_EMPTY)
        var moved: Int64 = 0
        for (packed in old) {
            if (packed == COMPACT_OPEN_INDEX_EMPTY) { continue }
            var slot = bucketFor(Int64(Int32(packed >> 32)), slots.size)
            while (slots[slot] != COMPACT_OPEN_INDEX_EMPTY) {
                slot = (slot + 1) & (slots.size - 1)
            }
            slots[slot] = packed
            moved++
        }
        // Remove references to the superseded large backing array as soon as
        // rehashing completes. This cannot change duplicate semantics: every
        // live slot has already been transferred to `slots`.
        grows++
        rehashEntries += moved
        if (!trace.isEmpty()) { trace += ";" }
        trace += "${count}:${old.size}->${slots.size}:${oldBytes}+${newBytes}:${moved}"
    }

    private func bucketFor(hash: Int64, count: Int64): Int64 {
        hash & (count - 1)
    }

    private func compactHashOf(name: String): Int32 {
        // Equality is always checked against the actual UTF-8 key, so retaining
        // 31 hash bits changes only collision frequency, never semantics.
        Int32(name.hashCode() & 0x7FFF_FFFF)
    }

    func hashOf(name: String): Int32 { compactHashOf(name) }
    func hashOf(view: JsonObjectKeyView): Int32 { document.keyHash(view) }
    func packedEntries(): Array<UInt64> { slots }


    func logicalBytes(): Int64 { count * 8 }
    func capacityBytes(): Int64 { slots.size * 8 }
    func growCount(): Int64 { grows }
    func peakOverlapBytes(): Int64 { peakOverlap }
    func largestOldBytes(): Int64 { largestOld }
    func largestNewBytes(): Int64 { largestNew }
    func rehashEntryCount(): Int64 { rehashEntries }
    func rehashTimeNanos(): Int64 { rehashNanos }
    func lookupCount(): Int64 { lookups }
    func insertCount(): Int64 { inserts }
    func probeCount(): Int64 { probes }
    func exactEqualityCount(): Int64 { exactEqualities }
    func maxProbeCount(): Int64 { maxProbe }
    func growthTrace(): String { trace }
}

// Small and normal objects retain the compact monolithic table. Huge objects
// switch once to independently split regions, bounding subsequent allocation
// overlap without imposing a directory on ordinary JSON objects.
private class CompactHybridObjectPositions {
    private var monolithic: Option<CompactObjectPositions>
    private var region = None<CompactRegionObjectPositions>
    private var count: Int64 = 0
    private let document: CompactJsonDocument

    init(document: CompactJsonDocument) {
        this.document = document
        if (document.source.size >= COMPACT_REGION_DOCUMENT_MIN_BYTES) {
            this.monolithic = None<CompactObjectPositions>
            this.region = Some(CompactRegionObjectPositions(document))
        } else {
            this.monolithic = Some(CompactObjectPositions(document))
        }
    }

    func hashOf(name: String): Int32 { Int32(name.hashCode() & 0x7FFF_FFFF) }

    func get(name: String, keys: ArrayList<UInt64>): Int64 {
        let hash = hashOf(name); getWithHash(name, hash, keys)
    }

    func getWithHash(name: String, hash: Int32, keys: ArrayList<UInt64>): Int64 {
        if (let Some(value) <- region) { return value.getWithHash(name, hash, keys) }
        monolithic.getOrThrow().getWithHash(name, hash, keys)
    }

    func add(name: String, position: Int64): Unit { addWithHash(hashOf(name), position) }

    func addWithHash(hash: Int32, position: Int64): Unit {
        if (let Some(value) <- region) { value.addWithHash(hash, position) }
        else { monolithic.getOrThrow().addWithHash(hash, position) }
        count++
    }

    func logicalBytes(): Int64 { if (let Some(value) <- region) { value.logicalBytes() } else { monolithic.getOrThrow().logicalBytes() } }
    func capacityBytes(): Int64 { if (let Some(value) <- region) { value.capacityBytes() } else { monolithic.getOrThrow().capacityBytes() } }
    func growCount(): Int64 { if (let Some(value) <- region) { value.growCount() } else { monolithic.getOrThrow().growCount() } }
    func peakOverlapBytes(): Int64 { if (let Some(value) <- region) { value.peakOverlapBytes() } else { monolithic.getOrThrow().peakOverlapBytes() } }
    func largestOldBytes(): Int64 { if (let Some(value) <- region) { value.largestOldBytes() } else { monolithic.getOrThrow().largestOldBytes() } }
    func largestNewBytes(): Int64 { if (let Some(value) <- region) { value.largestNewBytes() } else { monolithic.getOrThrow().largestNewBytes() } }
    func rehashEntryCount(): Int64 { if (let Some(value) <- region) { value.rehashEntryCount() } else { monolithic.getOrThrow().rehashEntryCount() } }
    func rehashTimeNanos(): Int64 { if (let Some(value) <- region) { value.rehashTimeNanos() } else { monolithic.getOrThrow().rehashTimeNanos() } }
    func lookupCount(): Int64 { if (let Some(value) <- region) { value.lookupCount() } else { monolithic.getOrThrow().lookupCount() } }
    func insertCount(): Int64 { if (let Some(value) <- region) { value.insertCount() } else { monolithic.getOrThrow().insertCount() } }
    func probeCount(): Int64 { if (let Some(value) <- region) { value.probeCount() } else { monolithic.getOrThrow().probeCount() } }
    func exactEqualityCount(): Int64 { if (let Some(value) <- region) { value.exactEqualityCount() } else { monolithic.getOrThrow().exactEqualityCount() } }
    func maxProbeCount(): Int64 { if (let Some(value) <- region) { value.maxProbeCount() } else { monolithic.getOrThrow().maxProbeCount() } }
    func growthTrace(): String { if (let Some(value) <- region) { "hybrid:" + value.growthTrace() } else { "monolithic:" + monolithic.getOrThrow().growthTrace() } }
}

extend YJson {
    public static func parseCompact(bytes: Array<Byte>, config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        CompactJsonDocument.parseBorrowed(bytes, config: config)
    }

    public static func parseCompactBorrowed(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        CompactJsonDocument.parseBorrowed(bytes, config: config)
    }

    public static func parseCompactOwned(bytes: Array<Byte>,
        config!: JsonReadConfig = JsonReadConfig.defaults): CompactJsonDocument {
        CompactJsonDocument.parseOwned(bytes, config: config)
    }
}
