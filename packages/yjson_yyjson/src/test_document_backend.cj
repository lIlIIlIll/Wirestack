package yjson_yyjson

import yjson.*
import yjson_backends.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class YyjsonDocumentBackendTest {
    @TestCase
    func unifiedEntryUsesYyjsonDirect(): Unit {
        let bytes = unsafe { "{\"id\":42,\"items\":[1,2]}".rawData() }
        try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, YyjsonDocumentBackend)) {
            @Expect(document.backendName(), "yyjson-direct")
            @Expect(document.rootSize(), 2)
            @Expect(document.getRootInt("id").getOrThrow(), 42)
            @Expect(document.getRootInt("missing").isNone())
            @Expect(document.materialize().asObject().get("items").getOrThrow().asArray().size(), 2)
        }
    }

    @TestCase
    func configurableBackendAndLifecycleRemainAvailable(): Unit {
        let backend = YyjsonCompactJsonBackend(mode: YyjsonCompactMode.Transcode)
        let document = YJsonAdvanced.parseDocumentWithBackend("[1,2]", backend)
        @Expect(document.backendName(), "yyjson-transcode")
        document.close()
        document.close()
        @Expect(document.isClosed())
        @AssertThrows[IllegalStateException](document.rootSize())
    }
}
