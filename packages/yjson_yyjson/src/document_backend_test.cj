package yjson_yyjson

import yjson.*
import yjson_backends.*
import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

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
    func concurrentReadsAndCloseAreLinearizable(): Unit {
        let document = YyjsonBackends.yyjson.parseDocument("{\"id\":42,\"items\":[1,2,3]}")
        let root = document.root()
        let readerCount: Int64 = 8
        let iterations: Int64 = 500
        let ready = AtomicInt64(0)
        let start = AtomicInt64(0)
        let readers = ArrayList<Future<Int64>>()
        for (_ in 0..readerCount) {
            readers.add(spawn {
                ready.fetchAdd(1)
                while (start.load() == 0) {}
                var completed: Int64 = 0
                try {
                    for (_ in 0..iterations) {
                        if (root.member("id").getOrThrow().asInt64() != 42) {
                            throw Exception("immutable yyjson view changed during concurrent read")
                        }
                        completed++
                    }
                } catch (error: JsonException) {
                    if (error.code != "resource_closed") { throw error }
                }
                completed
            })
        }
        while (ready.load() != readerCount) {}
        start.store(1)
        document.close()
        for (reader in readers) {
            let completed = reader.get()
            @Expect(completed >= 0 && completed <= iterations)
        }
        let error = @AssertThrows[JsonException](root.kind())
        @Expect(error.code, "resource_closed")
    }
}
