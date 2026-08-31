package yjson_backend_benchmarks

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_backends.*
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
    root.asObject().get("target").getOrThrow().asInt64()
}

func viewTarget(root: JsonValueView): Int64 {
    root.member("target").getOrThrow().asInt64()
}

func traversalChecksum(value: JsonValueView): Int64 {
    var checksum: Int64 = 0
    match (value.kind()) {
        case JsonKind.Array =>
            for (index in 0..value.size()) {
                checksum = checksum ^ index ^ traversalChecksum(value.element(index).getOrThrow())
            }
        case JsonKind.Object =>
            for (index in 0..value.size()) {
                checksum = checksum ^ index ^ Int64(value.memberName(index).hashCode())
                checksum = checksum ^ traversalChecksum(value.memberValue(index))
            }
        case JsonKind.String => checksum = Int64(value.asString().hashCode())
        case JsonKind.Number => checksum = Int64(value.asNumberText().hashCode())
        case JsonKind.Boolean => checksum = if (value.asBool()) { 1 } else { 0 }
        case JsonKind.Null => checksum = -1
    }
    checksum
}

class BackendDomFixture {
    let bytes: Array<Byte>
    let ast: JsonNode
    let compact: JsonDocument
    let native: BackendJsonDocument
    let yyjson: BackendJsonDocument

    init(entryCount: Int64) {
        bytes = backendFixtureBytes(entryCount)
        ast = JsonNode.parse(bytes)
        compact = YJson.parseDocument(bytes)
        native = NativeBackends.customNative.parseDocument(bytes)
        yyjson = YyjsonBackends.yyjson.parseDocument(bytes)
        verify()
    }

    func verify(): Unit {
        @Expect(astTarget(ast) == BACKEND_TARGET)
        @Expect(viewTarget(compact.root()) == BACKEND_TARGET)
        @Expect(viewTarget(native.root()) == BACKEND_TARGET)
        @Expect(viewTarget(yyjson.root()) == BACKEND_TARGET)
        @Expect(traversalChecksum(compact.root()) != 0)
        @Expect(traversalChecksum(native.root()) != 0)
        @Expect(traversalChecksum(yyjson.root()) != 0)
        @Expect(astTarget(native.materialize()) == BACKEND_TARGET)
        @Expect(astTarget(yyjson.materialize()) == BACKEND_TARGET)
        @Expect(astTarget(JsonNode.parse(YJson.toJson(compact.root()))) == BACKEND_TARGET)
        @Expect(astTarget(JsonNode.parse(NativeBackends.customNative.toJson(native.root()))) == BACKEND_TARGET)
        @Expect(astTarget(JsonNode.parse(YyjsonBackends.yyjson.toJson(yyjson.root()))) == BACKEND_TARGET)
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
    var nodeSink: JsonNode = JsonNode.nullValue

    @Bench
    func pureAstParseLifecycle(): Unit {
        intSink = astTarget(JsonNode.parse(fixture.bytes))
    }

    @Bench
    func pureCompactParseLifecycle(): Unit {
        intSink = viewTarget(YJson.parseDocument(fixture.bytes).root())
    }

    @Bench
    func customNativeParseLifecycle(): Unit {
        let document = NativeBackends.customNative.parseDocument(fixture.bytes)
        try {
            intSink = viewTarget(document.root())
        } finally {
            document.close()
        }
    }

    @Bench
    func yyjsonDirectParseLifecycle(): Unit {
        let document = YyjsonBackends.yyjson.parseDocument(fixture.bytes)
        try {
            intSink = viewTarget(document.root())
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
        intSink = viewTarget(fixture.compact.root())
    }

    @Bench
    func customNativeRootLookup(): Unit {
        intSink = viewTarget(fixture.native.root())
    }

    @Bench
    func yyjsonDirectRootLookup(): Unit {
        intSink = viewTarget(fixture.yyjson.root())
    }

    @Bench
    func pureCompactTraversal(): Unit {
        intSink = traversalChecksum(fixture.compact.root())
    }

    @Bench
    func customNativeTraversal(): Unit {
        intSink = traversalChecksum(fixture.native.root())
    }

    @Bench
    func yyjsonDirectTraversal(): Unit {
        intSink = traversalChecksum(fixture.yyjson.root())
    }

    @Bench
    func customNativeFineViewMaterialize(): Unit {
        nodeSink = fixture.native.root().materialize()
    }

    @Bench
    func customNativeBulkMaterialize(): Unit {
        nodeSink = fixture.native.materialize()
    }

    @Bench
    func yyjsonFineViewMaterialize(): Unit {
        nodeSink = fixture.yyjson.root().materialize()
    }

    @Bench
    func yyjsonBulkMaterialize(): Unit {
        nodeSink = fixture.yyjson.materialize()
    }

    @Bench
    func pureAstSerialize(): Unit {
        stringSink = fixture.ast.toString()
    }

    @Bench
    func pureCompactSerialize(): Unit {
        stringSink = YJson.toJson(fixture.compact.root())
    }

    @Bench
    func customNativeSerialize(): Unit {
        stringSink = NativeBackends.customNative.toJson(fixture.native.root())
    }

    @Bench
    func yyjsonDirectSerialize(): Unit {
        stringSink = YyjsonBackends.yyjson.toJson(fixture.yyjson.root())
    }

    @Bench
    func pureAstRoundTrip(): Unit {
        stringSink = JsonNode.parse(fixture.bytes).toString()
    }

    @Bench
    func pureCompactRoundTrip(): Unit {
        stringSink = YJson.toJson(YJson.parseDocument(fixture.bytes).root())
    }

    @Bench
    func customNativeRoundTrip(): Unit {
        let document = NativeBackends.customNative.parseDocument(fixture.bytes)
        try {
            stringSink = NativeBackends.customNative.toJson(document.root())
        } finally {
            document.close()
        }
    }

    @Bench
    func yyjsonDirectRoundTrip(): Unit {
        let document = YyjsonBackends.yyjson.parseDocument(fixture.bytes)
        try {
            stringSink = YyjsonBackends.yyjson.toJson(document.root())
        } finally {
            document.close()
        }
    }
}
