package yjson_benchmarks

import std.env.*
import std.fs.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private var documentLifecycleSink: Option<JsonDocument> = None<JsonDocument>

private func readDocumentCorpus(name: String): Array<Byte> {
    let directory = getVariable("YJSON_CROSSLANG_CORPUS_DIR").getOrThrow({ =>
        Exception("YJSON_CROSSLANG_CORPUS_DIR is required")
    })
    var result: Option<Array<Byte>> = None<Array<Byte>>
    try (file = File("${directory}/${name}.json", OpenMode.Read)) {
        result = Some(readToEnd(file))
    }
    result.getOrThrow({ => Exception("failed to read corpus ${name}") })
}

@Test
@Configure[
    warmup: Duration.millisecond * 500,
    minDuration: Duration.second,
    minBatches: 12
]
class DocumentLifecycleBenchmarks {
    private let records64kBytes = readDocumentCorpus("records-64k")
    private let records1mBytes = readDocumentCorpus("records-1m")
    private let records64kText = String.fromUtf8(records64kBytes)
    private let records1mText = String.fromUtf8(records1mBytes)

    @Bench
    func parseStringRecords64k(): Unit {
        documentLifecycleSink = Some(YJson.parseDocument(records64kText))
    }

    @Bench
    func parseBytesRecords64k(): Unit {
        documentLifecycleSink = Some(YJson.parseDocument(records64kBytes))
    }

    @Bench
    func parseStringRecords1m(): Unit {
        documentLifecycleSink = Some(YJson.parseDocument(records1mText))
    }

    @Bench
    func parseBytesRecords1m(): Unit {
        documentLifecycleSink = Some(YJson.parseDocument(records1mBytes))
    }
}
