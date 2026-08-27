package yjson_native

import yjson.*
import yjson_backends.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class NativeDocumentBackendTest {
    @TestCase
    func unifiedEntryUsesCustomNative(): Unit {
        let bytes = unsafe { "{\"id\":42,\"items\":[1,2]}".rawData() }
        try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, NativeCompactDocumentBackend)) {
            @Expect(document.backendName(), "custom-native")
            @Expect(document.rootSize(), 2)
            @Expect(document.getRootInt("id").getOrThrow(), 42)
            @Expect(document.getRootInt("missing").isNone())
            @Expect(document.materialize().asObject().get("items").getOrThrow().asArray().size(), 2)
        }
    }

    @TestCase
    func facadePreservesResourceLifecycle(): Unit {
        let document = YJsonAdvanced.parseDocumentWithBackend("[1,2]", NativeCompactDocumentBackend)
        document.close()
        document.close()
        @Expect(document.isClosed())
        @AssertThrows[IllegalStateException](document.rootSize())
    }
}
