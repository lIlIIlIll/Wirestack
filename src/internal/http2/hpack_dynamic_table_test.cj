package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HpackDynamicTableTest {
    @TestCase
    func newestEntryUsesIndexSixtyTwoAndOlderEntriesShift(): Unit {
        let table = HpackDynamicTable(256u64)
        @Expect(table.record(HpackHeaderField("custom-key", "custom-value"), HpackIndexingMode.Incremental))
        @Expect(table.record(HpackHeaderField("other-key", "other-value"), HpackIndexingMode.Incremental))
        expectDynamicField(table.get(62u64), "other-key", "other-value")
        expectDynamicField(table.get(63u64), "custom-key", "custom-value")
        @Expect(table.entryCount, 2)
    }

    @TestCase
    func exactRfcAccountingEvictsOldestEntriesFirst(): Unit {
        let first = HpackHeaderField("a", "1") // 34 bytes
        let second = HpackHeaderField("b", "22") // 35 bytes
        let table = HpackDynamicTable(68u64)
        @Expect(table.record(first, HpackIndexingMode.Incremental))
        @Expect(table.record(second, HpackIndexingMode.Incremental))
        @Expect(table.entryCount, 1)
        @Expect(table.usedBytes, second.tableSize)
        expectDynamicField(table.get(62u64), "b", "22")
        expectHpackTableFailure({ => let _ = table.get(63u64) })
    }

    @TestCase
    func oversizedEntryClearsTheEntireTableWithoutInsertion(): Unit {
        let table = HpackDynamicTable(64u64)
        @Expect(table.record(HpackHeaderField("a", "1"), HpackIndexingMode.Incremental))
        @Expect(!table.record(HpackHeaderField("long", "012345678901234567890123456789"), HpackIndexingMode.Incremental))
        @Expect(table.entryCount, 0)
        @Expect(table.usedBytes, 0u64)
    }

    @TestCase
    func capacityShrinkEvictsImmediatelyAndPeerLimitIsHard(): Unit {
        let table = HpackDynamicTable(128u64)
        let _ = table.record(HpackHeaderField("a", "1"), HpackIndexingMode.Incremental)
        let _ = table.record(HpackHeaderField("b", "2"), HpackIndexingMode.Incremental)
        table.setCapacity(34u64)
        @Expect(table.capacity, 34u64)
        @Expect(table.entryCount, 1)
        expectDynamicField(table.get(62u64), "b", "2")

        table.updateAllowedCapacity(16u64)
        @Expect(table.capacity, 16u64)
        @Expect(table.entryCount, 0)
        expectHpackTableFailure({ => table.setCapacity(17u64) })
    }

    @TestCase
    func withoutIndexingNeverIndexedAndSensitiveNeverEnterState(): Unit {
        let table = HpackDynamicTable(256u64)
        @Expect(!table.record(HpackHeaderField("cache-control", "no-cache"), HpackIndexingMode.WithoutIndexing))
        @Expect(!table.record(HpackHeaderField("authorization", "secret", sensitive: true), HpackIndexingMode.NeverIndexed))
        @Expect(table.entryCount, 0)
        expectHpackTableFailure({ =>
            let _ = table.record(
                HpackHeaderField("authorization", "secret", sensitive: true),
                HpackIndexingMode.Incremental
            )
        })
        @Expect(table.entryCount, 0)
    }

    @TestCase
    func staticAndDynamicSearchReturnCanonicalLowestIndexes(): Unit {
        let table = HpackDynamicTable(256u64)
        let _ = table.record(HpackHeaderField("x-name", "one"), HpackIndexingMode.Incremental)
        let _ = table.record(HpackHeaderField("x-name", "two"), HpackIndexingMode.Incremental)
        @Expect(table.findExact(":method", "GET"), Some(2u64))
        @Expect(table.findName("content-type"), Some(31u64))
        @Expect(table.findExact("x-name", "two"), Some(62u64))
        @Expect(table.findExact("x-name", "one"), Some(63u64))
        @Expect(table.findName("x-name"), Some(62u64))
        @Expect(table.findName("missing"), None<UInt64>)
    }

    @TestCase
    func zeroCapacityRetainsNoEntries(): Unit {
        let table = HpackDynamicTable(0u64)
        @Expect(!table.record(HpackHeaderField("a", "b"), HpackIndexingMode.Incremental))
        @Expect(table.entryCount, 0)
        @Expect(table.usedBytes, 0u64)
    }
}

private func expectDynamicField(field: HpackHeaderField, name: String, value: String): Unit {
    @Expect(field.name, name)
    @Expect(field.value, value)
}

private func expectHpackTableFailure(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: HpackException) { rejected = true }
    @Expect(rejected)
}
