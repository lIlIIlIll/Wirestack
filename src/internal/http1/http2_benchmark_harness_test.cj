package wirestack.internal.http1

import std.collection.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http2.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

private const HTTP2_BENCH_WARMUP_ROUNDS: Int64 = 2
private const HTTP2_BENCH_MEASURED_ROUNDS: Int64 = 20

/** Machine-readable HTTP/2 benchmark harness; policy decisions live in tools/benchmarks. */
@Test
class Http2Streams1BenchmarkTest {
    @TestCase
    func benchmarkOneConcurrentStream(): Unit { runHttp2Benchmark(1) }
}

@Test
class Http2Streams10BenchmarkTest {
    @TestCase
    func benchmarkTenConcurrentStreams(): Unit { runHttp2Benchmark(10) }
}

@Test
class Http2Streams100BenchmarkTest {
    @TestCase
    func benchmarkHundredConcurrentStreams(): Unit { runHttp2Benchmark(100) }
}

@Test
class Http1HundredConnectionBaselineTest {
    @TestCase
    func benchmarkHundredConcurrentConnections(): Unit {
        let clients = ArrayList<Http1ClientConnection>()
        let servers = ArrayList<Future<Int64>>()
        for (_ in 0..100) {
            let (client, server) = MemoryTransport.pair(capacity: 64 * 1024)
            clients.add(Http1ClientConnection(client))
            servers.add(spawn {
                serveHttp1Connection(server, Http2BenchmarkHttp1Handler(), maximumRequests: 1).requestsServed
            })
        }

        let started = MonoTime.now()
        let requests = ArrayList<Future<Int64>>()
        for (index in 0..clients.size) {
            let captured = index
            requests.add(spawn {
                let response = clients[captured].execute(
                    HttpRequest.get("http://benchmark.test/${captured}")
                ).response
                try { response.status } finally { response.close(); clients[captured].close() }
            })
        }
        var checksum: Int64 = 0
        for (request in requests) { checksum += request.get(Duration.second * 10) }
        let duration = (MonoTime.now() - started).toNanoseconds()
        var served: Int64 = 0
        for (server in servers) { served += server.get(Duration.second * 10) }

        @Expect(served, 100)
        @Expect(checksum, 20000)
        @Expect(duration > 0)
        println(
            "HTTP2_BASELINE protocol=http1 concurrency=100 requests=100 durationNs=${duration} " +
            "connections=100 checksum=${checksum}"
        )
    }
}

private func runHttp2Benchmark(concurrency: Int64): Unit {
    let totalRounds = HTTP2_BENCH_WARMUP_ROUNDS + HTTP2_BENCH_MEASURED_ROUNDS
    let (clientTransport, serverTransport) = MemoryTransport.pair(
        capacity: 4 * 1024 * 1024, maxChunk: 4096
    )
    let serving = spawn {
        Http2BenchmarkPeer(serverTransport).serveBatches(concurrency, totalRounds)
    }
    let connection = Http2ClientConnection.connect(
        clientTransport,
        http2Limits: Http2Limits(
            maxPendingWrites: 256u32,
            maxPendingWriteBytes: 1048576u32,
            maxConcurrentStreams: 100u32
        )
    )

    for (round in 0..HTTP2_BENCH_WARMUP_ROUNDS) {
        let _ = runHttp2Batch(connection, concurrency, round, None<ArrayList<Int64>>)
        let warmupMetrics = connection.metrics()
        // The stream registry intentionally keeps one connection-level
        // termination listener while the connection remains open.
        @Expect(warmupMetrics.readerTerminationListeners, 1)
        @Expect(warmupMetrics.resetListeners, 0)
        @Expect(warmupMetrics.goAwayListeners, 0)
    }

    let latencies = ArrayList<Int64>()
    let started = MonoTime.now()
    var checksum: Int64 = 0
    for (round in 0..HTTP2_BENCH_MEASURED_ROUNDS) {
        checksum += runHttp2Batch(
            connection, concurrency, round + HTTP2_BENCH_WARMUP_ROUNDS, Some(latencies)
        )
    }
    let duration = (MonoTime.now() - started).toNanoseconds()
    @Expect(serving.get(Duration.second * 30), concurrency * totalRounds)
    let metrics = connection.metrics()
    let measuredRequests = concurrency * HTTP2_BENCH_MEASURED_ROUNDS

    @Expect(latencies.size, measuredRequests)
    @Expect(connection.activeStreamCount, 0)
    @Expect(metrics.pendingFlowPermits, 0)
    @Expect(metrics.readerTerminationListeners, 1)
    @Expect(metrics.resetListeners, 0)
    @Expect(metrics.goAwayListeners, 0)
    @Expect(metrics.pendingWrites <= 256)
    @Expect(metrics.maximumPendingWrites <= 256)
    @Expect(metrics.maximumPendingWriteBytes <= 1048576u64)
    @Expect(duration > 0)
    println(
        "HTTP2_BENCH scenario=streams_${concurrency} concurrency=${concurrency} " +
        "measuredRequests=${measuredRequests} durationNs=${duration} connections=1 " +
        "maxPendingWrites=${metrics.maximumPendingWrites} " +
        "maxPendingWriteBytes=${metrics.maximumPendingWriteBytes} " +
        "pendingWrites=${metrics.pendingWrites} pendingFlowPermits=${metrics.pendingFlowPermits} " +
        "flowControlStalls=${metrics.flowControlStalls} checksum=${checksum} " +
        "latenciesNs=${joinBenchmarkLatencies(latencies)}"
    )
    connection.abort()
    @Expect(connection.metrics().readerTerminationListeners, 0)
    serverTransport.abort()
}

private func runHttp2Batch(
    connection: Http2ClientConnection,
    concurrency: Int64,
    round: Int64,
    latencies: ?ArrayList<Int64>
): Int64 {
    let requests = ArrayList<Future<Http2BenchmarkRequestResult>>()
    for (index in 0..concurrency) {
        let captured = index
        requests.add(spawn {
            let started = MonoTime.now()
            let response = connection.execute(
                HttpRequest.get("https://benchmark.test/${round}/${captured}")
            )
            let body = try { readHttp2BenchmarkBody(response.body) } finally { response.close() }
            Http2BenchmarkRequestResult(
                (MonoTime.now() - started).toNanoseconds(), body.toArray().size
            )
        })
    }
    var checksum: Int64 = 0
    for (request in requests) {
        let result = request.get(Duration.second * 10)
        if (let Some(output) <- latencies) { output.add(result.latencyNs) }
        checksum += result.bodyBytes
    }
    checksum
}

private class Http2BenchmarkRequestResult {
    let latencyNs: Int64
    let bodyBytes: Int64
    init(latencyNs: Int64, bodyBytes: Int64) {
        this.latencyNs = latencyNs
        this.bodyBytes = bodyBytes
    }
}

private class Http2BenchmarkPeer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()
    private let encoder = HpackEncoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serveBatches(concurrency: Int64, batches: Int64): Int64 {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start(settings: [
            Http2Setting(Http2SettingId.MaxConcurrentStreams, UInt32(concurrency))
        ])))

        var served: Int64 = 0
        for (_ in 0..batches) {
            let pending = receiveBatch(concurrency)
            var index: Int64 = pending.size - 1
            while (index >= 0) {
                sendResponse(pending[index])
                served += 1
                index -= 1
            }
        }
        served
    }

    private func receiveBatch(expected: Int64): Array<Http2BenchmarkRequest> {
        let pending = ArrayList<Http2BenchmarkRequest>()
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        while (pending.size < expected) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("HTTP/2 benchmark peer ended early")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) {
                    pending.add(Http2BenchmarkRequest(
                        block.streamId, benchmarkRequestPath(decoder.decode(block.bytes))
                    ))
                }
            }
        }
        pending.toArray()
    }

    private func sendResponse(request: Http2BenchmarkRequest): Unit {
        let body = request.path.toArray()
        let block = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "${body.size}"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(block.size), Http2FrameType.Headers,
                Http2Flags(raw: 0x04u8), request.streamId
            ),
            block
        ))))
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(body.size), Http2FrameType.Data,
                Http2Flags(raw: 0x01u8), request.streamId
            ),
            body
        ))))
    }
}

private class Http2BenchmarkRequest {
    let streamId: Http2StreamId
    let path: String
    init(streamId: Http2StreamId, path: String) { this.streamId = streamId; this.path = path }
}

private class Http2BenchmarkHttp1Handler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        Http1ServerResponse(HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}

private func benchmarkRequestPath(fields: Array<HpackHeaderField>): String {
    for (field in fields) { if (field.name == ":path") { return field.value } }
    throw Exception("HTTP/2 benchmark request has no :path")
}

private func readHttp2BenchmarkBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(256, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func joinBenchmarkLatencies(values: ArrayList<Int64>): String {
    let output = ArrayList<Byte>()
    for (index in 0..values.size) {
        if (index > 0) { output.add(b',') }
        for (byte in "${values[index]}".toArray()) { output.add(byte) }
    }
    String.fromUtf8(output.toArray())
}
