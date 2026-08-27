/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
 * This source file is part of the Cangjie project, licensed under Apache-2.0
 * with Runtime Library Exception.
 */

package yjson_benchmarks

import yjson.*

import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.overflow.*
import std.runtime.*
import std.unittest.*
import std.unittest.testmacro.*

private let STREAM_64K_RECORD_COUNT: Int64 = 1_024
private let STREAM_1M_RECORD_COUNT: Int64 = 16_384

private func streamProtocolPerson(): Person {
    let value = samplePerson()
    value.name = "Lin Stream Protocol Benchmark Payload"
    value.tags.add("incremental-stream")
    value
}

private class ProtocolChunkInputStream <: InputStream {
    private let bytes: Array<Byte>
    private let chunks: Array<Int64>
    private var offset: Int64 = 0
    private var chunkIndex: Int64 = 0

    public init(bytes: Array<Byte>, chunks: Array<Int64>) {
        this.bytes = bytes
        this.chunks = chunks
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (offset >= bytes.size) { return 0 }
        let requested = chunks[chunkIndex % chunks.size]
        chunkIndex++
        let remaining = bytes.size - offset
        let count = min(min(requested, remaining), buffer.size)
        bytes.copyTo(buffer, offset, 0, count)
        offset += count
        count
    }
}

private class ProtocolMemoryOutputStream <: OutputStream {
    private let bytes = ArrayList<Byte>()
    public func write(value: Array<Byte>): Unit { bytes.add(all: value) }
    public func flush(): Unit {}
    public prop size: Int64 { get() { bytes.size } }
}

private class ProtocolCountingOutputStream <: OutputStream {
    private var count: Int64 = 0
    private var checksum: UInt64 = 0u64

    public func write(value: Array<Byte>): Unit {
        count += value.size
        for (byte in value) {
            checksum = checksum.wrappingMul(1099511628211u64).wrappingAdd(UInt64(byte))
        }
    }

    public func flush(): Unit {}
    public prop size: Int64 { get() { count } }
    public prop digest: UInt64 { get() { checksum } }
}

private func fixedChunks(size: Int64): Array<Int64> { [size] }

private func deterministicRandomChunks(): Array<Int64> {
    let result = ArrayList<Int64>(256)
    var state: UInt64 = 0x6a09e667f3bcc909u64
    for (_ in 0..256) {
        state = state.wrappingMul(6364136223846793005u64).wrappingAdd(1442695040888963407u64)
        result.add(Int64(state % 8192u64) + 1)
    }
    result.toArray()
}

public class PersonDecodeInput {
    public let stream: InputStream
    public init(stream: InputStream) { this.stream = stream }
}

public class RecordsDecodeInput {
    public let stream: InputStream
    public init(stream: InputStream) { this.stream = stream }
}

public class PersonEncodeInput {
    public let output: OutputStream
    public init(output: OutputStream) { this.output = output }
}

public class RecordsEncodeInput {
    public let output: OutputStream
    public init(output: OutputStream) { this.output = output }
}

private func exportStreamProtocolPayload(name: String, bytes: Array<Byte>): Unit {
    if (let Some(directory) <- getVariable("YJSON_STREAM_PROTOCOL_ARTIFACT_DIR")) {
        try (file = File("${directory}/${name}.json", Write)) { file.write(bytes) }
    }
}

@Test
@Configure[
    batchSize: 1,
    warmup: Duration.millisecond * 500,
    minDuration: Duration.second * 3,
    minBatches: 30
]
class StreamProtocolBenchmarks {
    private let person = streamProtocolPerson()
    private let records64k = sampleLargeProfileRecords(count: STREAM_64K_RECORD_COUNT)
    private let records1m = sampleLargeProfileRecords(count: STREAM_1M_RECORD_COUNT)
    private let stdxPerson: StdxPerson
    private let stdxRecords64k: ArrayList<StdxProfileRecord>
    private let stdxRecords1m: ArrayList<StdxProfileRecord>
    private let personBytes: Array<Byte>
    private let records64kBytes: Array<Byte>
    private let records1mBytes: Array<Byte>
    private let randomChunks = deterministicRandomChunks()

    public init() {
        stdxPerson = toStdxPerson(person)
        stdxRecords64k = toStdxProfileList(records64k)
        stdxRecords1m = toStdxProfileList(records1m)
        personBytes = unsafe { YJson.toJson(person).rawData().clone() }
        records64kBytes = unsafe { YJson.toJson(records64k).rawData().clone() }
        records1mBytes = unsafe { YJson.toJson(records1m).rawData().clone() }
        exportStreamProtocolPayload("person", personBytes)
        exportStreamProtocolPayload("records-64k", records64kBytes)
        exportStreamProtocolPayload("records-1m", records1mBytes)

        assertJson(YJson.fromStream<Person>(
            ProtocolChunkInputStream(personBytes, fixedChunks(64))).id == person.id,
            "stream protocol person preflight")
        assertJson(YJson.fromStream<ArrayList<ProfileRecord>>(
            ProtocolChunkInputStream(records64kBytes, fixedChunks(4096))).size == records64k.size,
            "stream protocol 64 KiB preflight")
        assertJson(YJson.fromStream<ArrayList<ProfileRecord>>(
            ProtocolChunkInputStream(records1mBytes, randomChunks)).size == records1m.size,
            "stream protocol 1 MiB preflight")

        let memory = ProtocolMemoryOutputStream()
        YJson.toStream(records64k, memory)
        assertJson(memory.size == records64kBytes.size, "stream protocol memory sink preflight")
        let counting = ProtocolCountingOutputStream()
        YJson.toStream(records1m, counting)
        assertJson(counting.size == records1mBytes.size && counting.digest != 0u64,
            "stream protocol counting sink preflight")
    }

    @Strategy
    func person64Input(): BatchSizeOneInputProvider<PersonDecodeInput> {
        BatchSizeOneInputProvider { => PersonDecodeInput(ProtocolChunkInputStream(personBytes, fixedChunks(64))) }
    }
    @Strategy
    func person4kInput(): BatchSizeOneInputProvider<PersonDecodeInput> {
        BatchSizeOneInputProvider { => PersonDecodeInput(ProtocolChunkInputStream(personBytes, fixedChunks(4096))) }
    }
    @Strategy
    func personRandomInput(): BatchSizeOneInputProvider<PersonDecodeInput> {
        BatchSizeOneInputProvider { => PersonDecodeInput(ProtocolChunkInputStream(personBytes, randomChunks)) }
    }
    @Strategy
    func records64k64Input(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records64kBytes, fixedChunks(64))) }
    }
    @Strategy
    func records64k4kInput(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records64kBytes, fixedChunks(4096))) }
    }
    @Strategy
    func records64kRandomInput(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records64kBytes, randomChunks)) }
    }
    @Strategy
    func records1m64Input(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records1mBytes, fixedChunks(64))) }
    }
    @Strategy
    func records1m4kInput(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records1mBytes, fixedChunks(4096))) }
    }
    @Strategy
    func records1mRandomInput(): BatchSizeOneInputProvider<RecordsDecodeInput> {
        BatchSizeOneInputProvider { => RecordsDecodeInput(ProtocolChunkInputStream(records1mBytes, randomChunks)) }
    }

    @Bench[input in person64Input]
    func decodePersonChunk64(input: PersonDecodeInput): Unit { blackBox(YJson.fromStream<Person>(input.stream)) }
    @Bench[input in person4kInput]
    func decodePersonChunk4k(input: PersonDecodeInput): Unit { blackBox(YJson.fromStream<Person>(input.stream)) }
    @Bench[input in personRandomInput]
    func decodePersonChunkRandom(input: PersonDecodeInput): Unit { blackBox(YJson.fromStream<Person>(input.stream)) }
    @Bench[input in records64k64Input]
    func decodeRecords64kChunk64(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }
    @Bench[input in records64k4kInput]
    func decodeRecords64kChunk4k(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }
    @Bench[input in records64kRandomInput]
    func decodeRecords64kChunkRandom(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }
    @Bench[input in records1m64Input]
    func decodeRecords1mChunk64(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }
    @Bench[input in records1m4kInput]
    func decodeRecords1mChunk4k(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }
    @Bench[input in records1mRandomInput]
    func decodeRecords1mChunkRandom(input: RecordsDecodeInput): Unit {
        blackBox(YJson.fromStream<ArrayList<ProfileRecord>>(input.stream))
    }

    @Strategy
    func personMemoryOutput(): BatchSizeOneInputProvider<PersonEncodeInput> {
        BatchSizeOneInputProvider { => PersonEncodeInput(ProtocolMemoryOutputStream()) }
    }
    @Strategy
    func personCountingOutput(): BatchSizeOneInputProvider<PersonEncodeInput> {
        BatchSizeOneInputProvider { => PersonEncodeInput(ProtocolCountingOutputStream()) }
    }
    @Strategy
    func records64kMemoryOutput(): BatchSizeOneInputProvider<RecordsEncodeInput> {
        BatchSizeOneInputProvider { => RecordsEncodeInput(ProtocolMemoryOutputStream()) }
    }
    @Strategy
    func records64kCountingOutput(): BatchSizeOneInputProvider<RecordsEncodeInput> {
        BatchSizeOneInputProvider { => RecordsEncodeInput(ProtocolCountingOutputStream()) }
    }
    @Strategy
    func records1mMemoryOutput(): BatchSizeOneInputProvider<RecordsEncodeInput> {
        BatchSizeOneInputProvider { => RecordsEncodeInput(ProtocolMemoryOutputStream()) }
    }
    @Strategy
    func records1mCountingOutput(): BatchSizeOneInputProvider<RecordsEncodeInput> {
        BatchSizeOneInputProvider { => RecordsEncodeInput(ProtocolCountingOutputStream()) }
    }

    @Bench[input in personMemoryOutput]
    func encodePersonMemory(input: PersonEncodeInput): Unit { YJson.toStream(person, input.output) }
    @Bench[input in personCountingOutput]
    func encodePersonCounting(input: PersonEncodeInput): Unit { YJson.toStream(person, input.output) }
    @Bench[input in records64kMemoryOutput]
    func encodeRecords64kMemory(input: RecordsEncodeInput): Unit { YJson.toStream(records64k, input.output) }
    @Bench[input in records64kCountingOutput]
    func encodeRecords64kCounting(input: RecordsEncodeInput): Unit { YJson.toStream(records64k, input.output) }
    @Bench[input in records1mMemoryOutput]
    func encodeRecords1mMemory(input: RecordsEncodeInput): Unit { YJson.toStream(records1m, input.output) }
    @Bench[input in records1mCountingOutput]
    func encodeRecords1mCounting(input: RecordsEncodeInput): Unit { YJson.toStream(records1m, input.output) }

    @Bench[input in person64Input]
    func decodeStdxPersonChunk64(input: PersonDecodeInput): Unit {
        blackBox(decodeStdxFromStream<StdxPerson>(input.stream))
    }
    @Bench[input in person4kInput]
    func decodeStdxPersonChunk4k(input: PersonDecodeInput): Unit {
        blackBox(decodeStdxFromStream<StdxPerson>(input.stream))
    }
    @Bench[input in personRandomInput]
    func decodeStdxPersonChunkRandom(input: PersonDecodeInput): Unit {
        blackBox(decodeStdxFromStream<StdxPerson>(input.stream))
    }
    @Bench[input in records64k64Input]
    func decodeStdxRecords64kChunk64(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }
    @Bench[input in records64k4kInput]
    func decodeStdxRecords64kChunk4k(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }
    @Bench[input in records64kRandomInput]
    func decodeStdxRecords64kChunkRandom(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }
    @Bench[input in records1m64Input]
    func decodeStdxRecords1mChunk64(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }
    @Bench[input in records1m4kInput]
    func decodeStdxRecords1mChunk4k(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }
    @Bench[input in records1mRandomInput]
    func decodeStdxRecords1mChunkRandom(input: RecordsDecodeInput): Unit {
        blackBox(decodeStdxFromStream<ArrayList<StdxProfileRecord>>(input.stream))
    }

    @Bench[input in personMemoryOutput]
    func encodeStdxPersonMemory(input: PersonEncodeInput): Unit {
        encodeStdxToStream<StdxPerson>(stdxPerson, input.output)
    }
    @Bench[input in personCountingOutput]
    func encodeStdxPersonCounting(input: PersonEncodeInput): Unit {
        encodeStdxToStream<StdxPerson>(stdxPerson, input.output)
    }
    @Bench[input in records64kMemoryOutput]
    func encodeStdxRecords64kMemory(input: RecordsEncodeInput): Unit {
        encodeStdxToStream<ArrayList<StdxProfileRecord>>(stdxRecords64k, input.output)
    }
    @Bench[input in records64kCountingOutput]
    func encodeStdxRecords64kCounting(input: RecordsEncodeInput): Unit {
        encodeStdxToStream<ArrayList<StdxProfileRecord>>(stdxRecords64k, input.output)
    }
    @Bench[input in records1mMemoryOutput]
    func encodeStdxRecords1mMemory(input: RecordsEncodeInput): Unit {
        encodeStdxToStream<ArrayList<StdxProfileRecord>>(stdxRecords1m, input.output)
    }
    @Bench[input in records1mCountingOutput]
    func encodeStdxRecords1mCounting(input: RecordsEncodeInput): Unit {
        encodeStdxToStream<ArrayList<StdxProfileRecord>>(stdxRecords1m, input.output)
    }
}
