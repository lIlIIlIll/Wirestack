package yjson

import std.unittest.*
import std.unittest.testmacro.*

private func documentFromTemporaryString(): JsonDocument {
    let prefix = "{\"owner\":\""
    let suffix = "\",\"items\":[1,2,3]}"
    YJson.parseDocument(prefix + "kept alive" + suffix)
}

@Test
class JsonDocumentFacadeTest {
    @TestCase
    func documentIsManagedAndPortable(): Unit {
        let document = YJson.parseDocument("{\"id\":42,\"items\":[1,2]}")
        @Expect(document.root().size(), 2)
        @Expect(document.root().member("id").getOrThrow().asInt64(), 42)
        @Expect(document.root().member("missing").isNone())
        @Expect(document.root().member("items").getOrThrow().size(), 2)
        @Expect(document.materialize().asObject().get("items").getOrThrow().asArray().size(), 2)
        @Expect(JsonNode.parse(document.toString()).asObject().get("id").getOrThrow().asInt64(), 42)
    }

    @TestCase
    func byteInputIsOwnedBeforeReturn(): Unit {
        let source = unsafe { "[1,2,3]".rawData() }
        let bytes = Array<Byte>(source.size, repeat: 0)
        source.copyTo(bytes, 0, 0, source.size)
        let document = YJson.parseDocument(bytes)
        for (index in 0..bytes.size) { bytes[index] = b' ' }
        @Expect(document.root().size(), 3)
        @Expect(document.materialize().asArray().size(), 3)
    }

    @TestCase
    func stringInputOwnerLivesWithManagedDocument(): Unit {
        let document = documentFromTemporaryString()
        @Expect(document.root().member("owner").getOrThrow().asString(), "kept alive")
        @Expect(document.root().member("items").getOrThrow().size(), 3)
        @Expect(document.materialize().asObject().get("owner").getOrThrow().asString(),
            "kept alive")
        @Expect(document.toString(), "{\"owner\":\"kept alive\",\"items\":[1,2,3]}")
    }
}
