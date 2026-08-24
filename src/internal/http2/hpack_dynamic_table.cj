package wirestack.internal.http2

import std.collection.ArrayList

public enum HpackIndexingMode {
    | Incremental
    | WithoutIndexing
    | NeverIndexed
}

/**
 * RFC HPACK dynamic table with explicit current and allowed capacities.
 *
 * Entries are stored oldest-to-newest; wire index 62 always resolves to the
 * newest entry. Every mutation evicts synchronously until `usedBytes` is at or
 * below the current capacity.
 */
public class HpackDynamicTable {
    private let entries = ArrayList<HpackHeaderField>()
    private var allowedCapacityValue: UInt64
    private var capacityValue: UInt64
    private var usedBytesValue: UInt64 = 0u64

    public prop allowedCapacity: UInt64 { get() { allowedCapacityValue } }
    public prop capacity: UInt64 { get() { capacityValue } }
    public prop usedBytes: UInt64 { get() { usedBytesValue } }
    public prop entryCount: Int64 { get() { entries.size } }

    public init(allowedCapacity: UInt64) {
        allowedCapacityValue = allowedCapacity
        capacityValue = allowedCapacity
    }

    /** Applies a SETTINGS-derived hard ceiling and evicts immediately on shrink. */
    public func updateAllowedCapacity(value: UInt64): Unit {
        allowedCapacityValue = value
        if (capacityValue > value) { capacityValue = value }
        evictToCapacity()
    }

    /** Applies an HPACK dynamic-table-size update from a header block. */
    public func setCapacity(value: UInt64): Unit {
        if (value > allowedCapacityValue) {
            throw HpackException("HPACK dynamic table size update exceeds the peer limit")
        }
        capacityValue = value
        evictToCapacity()
    }

    /**
     * Records an entry only for incremental indexing.
     *
     * `NeverIndexed` and sensitive fields are kept out of shared compression
     * state so credentials cannot be recovered through later indexed fields.
     */
    public func record(field: HpackHeaderField, mode: HpackIndexingMode): Bool {
        match (mode) {
            case HpackIndexingMode.WithoutIndexing => return false
            case HpackIndexingMode.NeverIndexed => return false
            case HpackIndexingMode.Incremental => ()
        }
        if (field.sensitive) {
            throw HpackException("sensitive HPACK fields cannot use incremental indexing")
        }
        let size = field.tableSize
        if (size > capacityValue) {
            clear()
            return false
        }
        entries.add(HpackHeaderField(field.name, field.value))
        usedBytesValue += size
        evictToCapacity()
        true
    }

    /** Resolves the complete one-based static + dynamic index space. */
    public func get(index: UInt64): HpackHeaderField {
        if (index == 0u64) { throw HpackException("HPACK index zero is invalid") }
        if (index <= hpackStaticTableSize()) { return hpackStaticTableEntry(index) }
        let dynamicOffset = index - hpackStaticTableSize() - 1u64
        if (dynamicOffset >= UInt64(entries.size)) {
            throw HpackException("HPACK dynamic-table index is out of bounds")
        }
        let position = entries.size - 1 - Int64(dynamicOffset)
        let field = entries[position]
        HpackHeaderField(field.name, field.value, sensitive: field.sensitive)
    }

    /** Returns the lowest exact wire index, preferring the static table. */
    public func findExact(name: String, value: String): ?UInt64 {
        for (index in 1u64..(hpackStaticTableSize() + 1u64)) {
            let field = hpackStaticTableEntry(index)
            if (field.name == name && field.value == value) { return Some(index) }
        }
        for (offset in 0..entries.size) {
            let field = entries[entries.size - 1 - offset]
            if (field.name == name && field.value == value) {
                return Some(hpackStaticTableSize() + 1u64 + UInt64(offset))
            }
        }
        None<UInt64>
    }

    /** Returns the lowest name-only wire index, preferring the static table. */
    public func findName(name: String): ?UInt64 {
        for (index in 1u64..(hpackStaticTableSize() + 1u64)) {
            if (hpackStaticTableEntry(index).name == name) { return Some(index) }
        }
        for (offset in 0..entries.size) {
            if (entries[entries.size - 1 - offset].name == name) {
                return Some(hpackStaticTableSize() + 1u64 + UInt64(offset))
            }
        }
        None<UInt64>
    }

    public func clear(): Unit {
        entries.clear()
        usedBytesValue = 0u64
    }

    private func evictToCapacity(): Unit {
        while (usedBytesValue > capacityValue && !entries.isEmpty()) {
            let removed = entries.remove(at: 0)
            usedBytesValue -= removed.tableSize
        }
    }
}
