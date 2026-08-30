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
        @Expect(document.rootSize(), 2)
        @Expect(document.getRootInt("id").getOrThrow(), 42)
        @Expect(document.getRootInt("missing").isNone())
        @Expect(document.root().get("items").getOrThrow().size(), 2)
        @Expect(document.materialize().asObject().get("items").getOrThrow().asArray().size(), 2)
        @Expect(YJson.parse(document.toString()).asObject().get("id").getOrThrow().asInt().value, 42)
    }

    @TestCase
    func byteInputIsOwnedBeforeReturn(): Unit {
        let source = unsafe { "[1,2,3]".rawData() }
        let bytes = Array<Byte>(source.size, repeat: 0)
        source.copyTo(bytes, 0, 0, source.size)
        let document = YJson.parseDocument(bytes)
        for (index in 0..bytes.size) { bytes[index] = b' ' }
        @Expect(document.rootSize(), 3)
        @Expect(document.materialize().asArray().size(), 3)
    }

    @TestCase
    func stringInputOwnerLivesWithManagedDocument(): Unit {
        let document = documentFromTemporaryString()
        @Expect(document.root().get("owner").getOrThrow().asString(), "kept alive")
        @Expect(document.root().get("items").getOrThrow().size(), 3)
        @Expect(document.materialize().asObject().get("owner").getOrThrow().asString().value,
            "kept alive")
        @Expect(document.toString(), "{\"owner\":\"kept alive\",\"items\":[1,2,3]}")
    }
}
