package yjson_yyjson

import yjson.*
import yjson_backends.*
import std.collection.*
import std.env.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func deadlineReached(start: DateTime, timeoutNanos: Int64): Bool {
    let elapsed: Duration = DateTime.now() - start
    elapsed.toNanoseconds() >= timeoutNanos
}

@Test
class YyjsonDocumentBackendTest {
    @TestCase
    func namedFacadeUsesUnifiedReadOnlyView(): Unit {
        let bytes = unsafe { "{\"id\":42,\"items\":[1,2]}".rawData() }
        let json = YyjsonBackends.yyjson
        try (document = json.parseDocument(bytes)) {
            @Expect(document.metadata().name, "yyjson")
            @Expect(document.root().size(), 2)
            @Expect(document.root().member("id").getOrThrow().asInt64(), 42)
            @Expect(document.root().member("missing").isNone())
            @Expect(document.materialize().asObject().get("items").getOrThrow().asArray().size(), 2)
        }
    }

    @TestCase
    func facadeIsClosedAndDocumentLifecycleIsExplicit(): Unit {
        let document = YyjsonBackends.yyjson.parseDocument("[1,2]")
        let root = document.root()
        document.close()
        document.close()
        @Expect(document.isClosed())
        let error = @AssertThrows[JsonException](root.size())
        @Expect(error.code, "resource_closed")
    }

    @TestCase
    func rootBulkPathsPreserveOptionsSubviewsAndBudgets(): Unit {
        let json = YyjsonBackends.yyjson
        try (document = json.parseDocument("{\"html\":\"<tag>\",\"items\":[1,2]}")) {
            let root = document.root()
            let materialized = document.materialize()
            for (options in [JsonWriteOptions.defaults, JsonWriteOptions.pretty(),
                JsonWriteOptions(htmlSafe: true)]) {
                @Expect(json.toJson(root, options: options),
                    materialized.toJson(options: options))
            }
            @Expect(json.toJson(root.member("items").getOrThrow()), "[1,2]")
            @Expect(document.materialize(5).asObject()["items"].asArray().size(), 2)
            let budgetError = @AssertThrows[JsonException](document.materialize(4))
            @Expect(budgetError.code, "work_limit_exceeded")
            @AssertThrows[IllegalArgumentException](document.materialize(0))
            let outputError = @AssertThrows[JsonException](json.toJson(root,
                options: JsonWriteOptions(maxOutputBytes: 3)))
            @Expect(outputError.code, "output_too_large")
        }
    }

    @TestCase
    func concurrentMemberReadsAndCloseAreLinearizable(): Unit {
        // Readers must complete at least one successful read before close can
        // be triggered; afterwards every operation fails with resource_closed.
        // Polling is deadline-bounded, never an unbounded busy wait.
        let document = YyjsonBackends.yyjson.parseDocument("{\"id\":42,\"items\":[1,2,3]}")
        let root = document.root()
        let readerCount: Int64 = 8
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)
        let successfulReads = AtomicInt64(0)
        let closeTriggered = AtomicInt64(0)
        let readers = ArrayList<Future<Int64>>()
        for (_ in 0..readerCount) {
            readers.add(spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {
                    if (closeTriggered.load() != 0) { return 0 }
                }
                var completed: Int64 = 0
                try {
                    for (_ in 0..500) {
                        if (root.member("id").getOrThrow().asInt64() != 42) {
                            throw Exception("immutable yyjson view changed during concurrent read")
                        }
                        completed++
                        successfulReads.fetchAdd(1)
                    }
                } catch (error: JsonException) {
                    if (error.code != "resource_closed") { throw error }
                }
                completed
            })
        }
        while (ready.load() != readerCount) {
            sleep(1 * Duration.millisecond)
        }
        start.store(1)
        // Close only after at least one successful read is observed.
        let waitStart = DateTime.now()
        while (successfulReads.load() == 0 && !deadlineReached(waitStart, 10_000_000_000)) {
            sleep(1 * Duration.millisecond)
        }
        if (successfulReads.load() == 0) {
            throw Exception("reader never completed a successful read before close")
        }
        closeTriggered.store(1)
        document.close()
        for (reader in readers) {
            let completed = reader.get()
            @Expect(completed >= 0 && completed <= 500)
        }
        let error = @AssertThrows[JsonException](root.kind())
        @Expect(error.code, "resource_closed")
    }

    @TestCase
    func concurrentWideObjectMemberReadsAndClose(): Unit {
        // 300+ field object: concurrent member reads exercise the root index
        // build path while a close races in. Deterministic contract: all
        // reads before the close point succeed, everything after fails closed.
        let builder = StringBuilder("{")
        for (index in 0..320) {
            if (index != 0) { builder.append(",") }
            builder.append("\"k${index}\":${index}")
        }
        builder.append("}")
        let document = YyjsonCompactJsonDocument.parse(
            unsafe { builder.toString().rawData() },
            lookupIndexMode: YyjsonLookupIndexMode.Lazy)
        let root = document.root()
        let readerCount: Int64 = 6
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)
        let successfulReads = AtomicInt64(0)
        let readers = ArrayList<Future<Int64>>()
        for (_ in 0..readerCount) {
            readers.add(spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {}
                var completed: Int64 = 0
                try {
                    for (round in 0..200) {
                        let member = "k${(round * 7) % 320}"
                        if (root.member(member).getOrThrow().asInt64() !=
                            ((round * 7) % 320)) {
                            throw Exception("wide object read changed during concurrent access")
                        }
                        completed++
                        successfulReads.fetchAdd(1)
                    }
                } catch (error: JsonException) {
                    if (error.code != "resource_closed") { throw error }
                }
                completed
            })
        }
        while (ready.load() != readerCount) { sleep(1 * Duration.millisecond) }
        start.store(1)
        let waitStart = DateTime.now()
        while (successfulReads.load() == 0 && !deadlineReached(waitStart, 10_000_000_000)) {
            sleep(1 * Duration.millisecond)
        }
        if (successfulReads.load() == 0) {
            throw Exception("wide-object reader never completed a successful read")
        }
        document.close()
        for (reader in readers) {
            let completed = reader.get()
            @Expect(completed >= 0 && completed <= 200)
        }
        let error = @AssertThrows[JsonException](root.kind())
        @Expect(error.code, "resource_closed")
    }
}
