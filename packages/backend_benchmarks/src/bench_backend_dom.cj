package yjson_backend_benchmarks

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_native.*
import yjson_yyjson.*

main(): Unit {}

let BACKEND_ENTRY_COUNT: Int64 = 16384
let BACKEND_TARGET: Int64 = 424242

func backendFixtureBytes(entryCount: Int64): Array<Byte> {
    let builder = StringBuilder()
    builder.append("{\"target\":${BACKEND_TARGET},\"items\":{")
    for (index in 0..entryCount) {
        if (index > 0) { builder.append(",") }
        builder.append("\"key_${index}\":${index}")
    }
    builder.append("}}")
    unsafe { builder.toString().rawData() }
}

func astTarget(root: JsonNode): Int64 {
    root.asObject().get("target").getOrThrow().asInt().value
}

class BackendDomFixture {
    let bytes: Array<Byte>
    let ast: JsonNode
    let compact: CompactJsonDocument
    let native: NativeCompactJsonDocument
    let yyjson: YyjsonCompactJsonDocument

    init(entryCount: Int64) {
        bytes = backendFixtureBytes(entryCount)
        ast = YJson.parse(bytes)
        compact = CompactJsonDocument.parse(bytes)
        native = NativeCompactJsonDocument.parse(bytes)
        yyjson = YyjsonCompactJsonDocument.parse(bytes)
    }

    func verify(): Unit {
        @Expect(astTarget(ast) == BACKEND_TARGET)
        @Expect(compact.root().get("target").getOrThrow().asInt64() == BACKEND_TARGET)
        @Expect(native.root().get("target").getOrThrow().asInt64() == BACKEND_TARGET)
        @Expect(yyjson.getRootInt("target").getOrThrow() == BACKEND_TARGET)
        @Expect(compact.traversalChecksum() != 0)
        @Expect(native.traversalChecksum() != 0)
        @Expect(yyjson.traversalChecksum() != 0)
        @Expect(astTarget(YJson.parse(compact.toString())) == BACKEND_TARGET)
        @Expect(astTarget(YJson.parse(native.toString())) == BACKEND_TARGET)
        @Expect(astTarget(YJson.parse(yyjson.toString())) == BACKEND_TARGET)
    }

    func close(): Unit {
        yyjson.close()
        native.close()
    }
}

@Test
class BackendDomContractTest {
    @TestCase
    func publicBackendsAgreeOnObservableFixture(): Unit {
        let fixture = BackendDomFixture(1024)
        try {
            fixture.verify()
        } finally {
            fixture.close()
        }
    }
}

@Test
@Configure[
    warmup: Duration.millisecond * 200,
    minDuration: Duration.second,
    minBatches: 12
]
class BackendDomBenchmarks {
    let fixture = BackendDomFixture(BACKEND_ENTRY_COUNT)
    var intSink: Int64 = 0
    var stringSink: String = ""

    @Bench
    func pureAstParseLifecycle(): Unit {
        intSink = astTarget(YJson.parse(fixture.bytes))
    }

    @Bench
    func pureCompactParseLifecycle(): Unit {
        intSink = CompactJsonDocument.parse(fixture.bytes).root()
            .get("target").getOrThrow().asInt64()
    }

    @Bench
    func customNativeParseLifecycle(): Unit {
        let document = NativeCompactJsonDocument.parse(fixture.bytes)
        try {
            intSink = document.root().get("target").getOrThrow().asInt64()
        } finally {
            document.close()
        }
    }

    @Bench
    func yyjsonDirectParseLifecycle(): Unit {
        let document = YyjsonCompactJsonDocument.parse(fixture.bytes)
        try {
            intSink = document.getRootInt("target").getOrThrow()
        } finally {
            document.close()
        }
    }

    @Bench
    func pureAstRootLookup(): Unit {
        intSink = astTarget(fixture.ast)
    }

    @Bench
    func pureCompactRootLookup(): Unit {
        intSink = fixture.compact.root().get("target").getOrThrow().asInt64()
    }

    @Bench
    func customNativeRootLookup(): Unit {
        intSink = fixture.native.root().get("target").getOrThrow().asInt64()
    }

    @Bench
    func yyjsonDirectRootLookup(): Unit {
        intSink = fixture.yyjson.getRootInt("target").getOrThrow()
    }

    @Bench
    func pureCompactTraversal(): Unit {
        intSink = fixture.compact.traversalChecksum()
    }

    @Bench
    func customNativeTraversal(): Unit {
        intSink = fixture.native.traversalChecksum()
    }

    @Bench
    func yyjsonDirectTraversal(): Unit {
        intSink = fixture.yyjson.traversalChecksum()
    }

    @Bench
    func pureAstSerialize(): Unit {
        stringSink = fixture.ast.toString()
    }

    @Bench
    func pureCompactSerialize(): Unit {
        stringSink = fixture.compact.toString()
    }

    @Bench
    func customNativeSerialize(): Unit {
        stringSink = fixture.native.toString()
    }

    @Bench
    func yyjsonDirectSerialize(): Unit {
        stringSink = fixture.yyjson.toString()
    }

    @Bench
    func pureAstRoundTrip(): Unit {
        stringSink = YJson.parse(fixture.bytes).toString()
    }

    @Bench
    func pureCompactRoundTrip(): Unit {
        stringSink = CompactJsonDocument.parse(fixture.bytes).toString()
    }

    @Bench
    func customNativeRoundTrip(): Unit {
        let document = NativeCompactJsonDocument.parse(fixture.bytes)
        try {
            stringSink = document.toString()
        } finally {
            document.close()
        }
    }

    @Bench
    func yyjsonDirectRoundTrip(): Unit {
        let document = YyjsonCompactJsonDocument.parse(fixture.bytes)
        try {
            stringSink = document.toString()
        } finally {
            document.close()
        }
    }
}
