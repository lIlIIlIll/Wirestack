package wirestack_m12_001

import std.collection.ArrayList
import std.fs.File
import std.sync.*
import std.time.MonoTime
import wirestack as api
import wirestack.http.*
import wirestack.net.TcpStream

let bulkLength: Int64 = 8388608
let tinyLength: Int64 = 7
let tinyChecksum: Int64 = 746

// The producer fills the protocol-owned destination, never an 8 MiB array.
class PerfBody <: HttpBodyStream {
    let length: Int64
    let produced: AtomicInt64
    var offset: Int64 = 0
    var closed = false
    init(length: Int64, produced: AtomicInt64) { this.length = length; this.produced = produced }
    public prop contentLength: ?Int64 { get() { Some(length) } }
    public func read(destination: Array<Byte>): Int64 {
        perfRequire(!closed, "producer read after close")
        let count = min(destination.size, length - offset)
        for (i in 0..count) { destination[i] = 97u8 }
        offset += count; produced.fetchAdd(count)
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}
class PerfHandler <: HttpServerHandler {
    let produced = AtomicInt64(0)
    let held = AtomicBool(false)
    let release = AtomicBool(false)
    let requests = AtomicInt64(0)
    let closeEach: Bool
    init(closeEach: Bool) { this.closeEach = closeEach }
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        requests.fetchAdd(1)
        if (request.target == "/hold") {
            held.store(true)
            while (!release.load()) {
                perfRequire(!context.isDeadlineExceeded(), "held server request deadline")
                sleep(Duration.millisecond)
            }
        }
        if (request.target == "/bulk") {
            let source = RequestBody.replayableFactory(Some(bulkLength), { => PerfBody(bulkLength, produced) })
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(source.open()),
                headers: HttpHeaders.builder().add("Content-Length", "${bulkLength}").build()))
        }
        let headers = HttpHeaders.builder().add("Content-Length", "7")
        if (closeEach) { headers.add("Connection", "close") }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("payload").open()), headers: headers.build()))
    }
}
class PerfConnector <: HttpConnector {
    let count = AtomicInt64(0)
    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let stream = TcpStream.connect(endpoint, context: context)
        count.fetchAdd(1)
        stream
    }
}
func stageIndex(stage: api.OperationTimeoutStage): Int64 {
    match (stage) {
        case api.OperationTimeoutStage.RequestAdmission => 0
        case api.OperationTimeoutStage.ConnectionPool => 1
        case api.OperationTimeoutStage.Dns => 2
        case api.OperationTimeoutStage.TcpConnect => 3
        case api.OperationTimeoutStage.ProxyConnect => 4
        case api.OperationTimeoutStage.TlsHandshake => 5
        case api.OperationTimeoutStage.RequestWrite => 6
        case api.OperationTimeoutStage.ResponseHeaders => 7
        case api.OperationTimeoutStage.BodyReadIdle => 8
        case api.OperationTimeoutStage.StreamReadIdle => 9
    }
}
class PerfEvents {
    let ring = api.NetworkEventBuffer(capacity: 4096)
    let connections = ArrayList<Int64>()
    let stageNs = Array<Int64>(10, repeat: 0)
    let stageCounts = Array<Int64>(10, repeat: 0)
    var eventCount: Int64 = 0
    var queueHigh: Int64 = 0
    var reused: Int64 = 0
    var pressure: Int64 = 0
    var e2eNs: Int64 = 0
    var e2eCount: Int64 = 0
    var queueWaitNs: Int64 = 0
    var queueWaitCount: Int64 = 0
    let attributed: Bool
    init(attributed: Bool) { this.attributed = attributed }
    func drain(): Unit {
        let snapshot = ring.snapshot()
        queueHigh = max(queueHigh, snapshot.queuedEvents)
        perfRequire(snapshot.droppedEvents == 0, "bounded observation queue dropped required evidence")
        let events = ring.drain()
        eventCount += events.size
        // Attribute only correlated native events; never add overlapping stages to fabricate E2E.
        for (event in events) {
            let instant = event.occurredAt.getOrThrow()
            match (event.kind) {
                case api.NetworkEventKind.HttpConnectionAcquired =>
                    if (let Some(id) <- event.connectionId) {
                        if (!connections.contains(id)) { connections.add(id) }
                    }
                    match (event.outcome) { case api.NetworkEventOutcome.Reused => reused++; case _ => () }
                case api.NetworkEventKind.LocalBackpressureStarted => pressure++
                case api.NetworkEventKind.StageCompleted =>
                    if (attributed) {
                        let index = stageIndex(event.stage.getOrThrow())
                        var start = None<MonoTime>
                        for (candidate in events) {
                            match (candidate.kind) {
                                case api.NetworkEventKind.StageStarted =>
                                    let at = candidate.occurredAt.getOrThrow()
                                    if (candidate.requestId == event.requestId && candidate.attemptId == event.attemptId &&
                                        stageIndex(candidate.stage.getOrThrow()) == index && at <= instant &&
                                        (start.isNone() || at > start.getOrThrow())) { start = Some(at) }
                                case _ => ()
                            }
                        }
                        if (let Some(at) <- start) {
                            let elapsed = (instant - at).toNanoseconds()
                            stageNs[index] += elapsed; stageCounts[index]++
                            if (index == 0 && event.requestId == Some(900001)) { queueWaitNs += elapsed; queueWaitCount++ }
                        }
                    }
                case api.NetworkEventKind.BodyCompleted =>
                    if (attributed) {
                        for (candidate in events) {
                            match (candidate.kind) {
                                case api.NetworkEventKind.RequestStarted =>
                                    if (candidate.requestId == event.requestId) {
                                        e2eNs += (instant - candidate.occurredAt.getOrThrow()).toNanoseconds(); e2eCount++
                                    }
                                case _ => ()
                            }
                        }
                    }
                case _ => ()
            }
        }
    }
    func metrics(): String {
        var result = ",\"event_count\":${eventCount},\"event_queue_high_water\":${queueHigh}," +
            "\"pool_hits\":${reused},\"observed_connections\":${connections.size},\"flow_stall_events\":${pressure}"
        let names = ["admission", "pool", "dns", "connect", "proxy", "tls", "write", "headers", "body", "stream"]
        for (i in 0..10) {
            if (stageCounts[i] > 0) {
                result += ",\"stage_${names[i]}_ns\":${stageNs[i]},\"stage_${names[i]}_count\":${stageCounts[i]}"
            }
        }
        if (e2eCount > 0) { result += ",\"attributed_e2e_ns\":${e2eNs},\"attributed_e2e_count\":${e2eCount}" }
        if (queueWaitCount > 0) { result += ",\"queue_wait_ns\":${queueWaitNs},\"queue_wait_count\":${queueWaitCount}" }
        result
    }
}
func readPerf(response: HttpResponse, buffer: Array<Byte>, length: Int64, h2: Bool): (Int64, Int64, Int64) {
    try {
        perfRequire(response.status == 200, "unexpected HTTP status")
        perfRequire(response.version == if (h2) { HttpVersion.Http2 } else { HttpVersion.Http11 }, "native ALPN/protocol mismatch")
        var bytes: Int64 = 0; var sum: Int64 = 0; var calls: Int64 = 0
        while (true) {
            let n = response.body.read(buffer); calls++
            if (n == 0) { break }
            for (i in 0..n) { sum += Int64(buffer[i]) }
            bytes += n
            perfRequire(bytes <= length, "response exceeded declared workload")
        }
        perfRequire(bytes == length && sum == if (length == tinyLength) { tinyChecksum } else { length * 97 },
            "response byte/checksum mismatch")
        (bytes, sum, calls)
    } finally { response.close() }
}
func zeroPerf(s: HttpResourceSnapshot): Bool {
    s.activeConnections == 0 && s.reservedConnections == 0 && s.activeRequests == 0 &&
        s.activeStreams == 0 && s.reservedStreams == 0 && s.managedBufferBytes == 0u64 &&
        s.admissionWaiters == 0 && s.owners.isEmpty()
}
func waitPerf(context: OperationContext, predicate: () -> Bool): Unit {
    while (!predicate()) {
        perfRequire(!context.isDeadlineExceeded(), "bounded native wait expired")
        sleep(Duration.millisecond)
    }
}
func limitsPerf(connections: Int64, requests: Int64, waiters: Int64, singleRoute!: Bool = false): HttpResourceLimits {
    let routeConnections = if (singleRoute) { 1 } else { connections }
    HttpResourceLimits(maximumConnections: connections, maximumConnectionsPerRoute: routeConnections,
        maximumConnectionsPerOrigin: routeConnections, maximumRequests: requests, maximumRequestsPerRoute: requests,
        maximumRequestsPerOrigin: requests, maximumStreams: 128, maximumStreamsPerRoute: 128,
        maximumStreamsPerOrigin: 128, maximumManagedBufferBytes: 16777216u64,
        reservedControlBufferBytes: 65536u64, maximumManagedBufferBytesPerRoute: 16711680u64,
        maximumManagedBufferBytesPerOrigin: 16711680u64, maximumWaiters: waiters, maximumOwners: 8)
}
main(args: Array<String>): Int64 {
    // The runner reads the measured provider identity from this executable.
    if (isTlsIdentityRequest(args)) { println(tlsIdentityLine()); return 0 }
    perfRequire(args.size == 3 || args.size == 4, "usage: http scenario certificate.der key.pk8 [enabled|disabled]")
    let scenario = args[0]
    let cases = ["h1_short_reuse", "h1_new_connection", "h1_bulk_4096", "h1_bulk_32768", "h1_concurrent",
        "h1_early_close", "h2_streams_1", "h2_streams_10", "h2_streams_100", "h2_slow_consumer",
        "h2_stream_cancel", "http_overload", "http_observed"]
    perfRequire(cases.contains(scenario), "unknown HTTP workload")
    let h2 = scenario.startsWith("h2_")
    let overloaded = scenario == "http_overload"
    let observed = scenario == "http_observed" && (args.size == 3 || args[3] == "enabled")
    let bulk = scenario.startsWith("h1_bulk")
    let early = scenario == "h1_early_close"
    let slow = scenario == "h2_slow_consumer" || scenario == "h2_stream_cancel"
    let owner = perfOwner()
    let handler = PerfHandler(scenario == "h1_new_connection"); let connector = PerfConnector(); let evidence = PerfEvents(observed || overloaded)
    let certificate = File.readFrom(args[1]); let key = File.readFrom(args[2])
    let serverTls = HttpServerTlsConfig([certificate], key); let clientTls = HttpClientTlsConfig([certificate])
    let serverBuilder = HttpServer.builder().listen(SocketEndpoint(perfLoopback(), 0u16)).handler(handler)
        .connectionLimit(16).resourceLimits(limitsPerf(16, if (overloaded) { 1 } else { 256 }, if (overloaded) { 1 } else { 128 }))
        .requestsPerConnectionLimit(4096).http2StreamLimit(128u32)
    if (h2) { serverBuilder.tls(serverTls) }
    let server = serverBuilder.build()
    let serverContext = if (slow) { owner.withEventSink(Some<api.NetworkEventSink>(evidence.ring)) } else { owner }
    let serving = spawn { server.serve(context: serverContext) }
    let resolver = StaticResolver(ResolveResult([perfLoopback()], HostName("example.test"), ResolverSource.Static))
    // Partial reads return flow credit before releasing their whole frame allocation.
    // Reserve bounded room for sibling DATA while still asserting one actual connection.
    let clientConnectionCap: Int64 = if (scenario == "h2_slow_consumer") { 2 } else if (h2 || overloaded) { 1 } else { 16 }
    let clientBuilder = HttpClient.builder().resolver(resolver).connector(connector)
        .resourceLimits(limitsPerf(clientConnectionCap, if (overloaded) { 1 } else { 256 }, if (overloaded) { 1 } else { 128 }, singleRoute: scenario == "h2_slow_consumer"))
    if (h2) { clientBuilder.tls(clientTls) }
    let client = clientBuilder.build()
    let base = if (h2) { "https://example.test:${server.localEndpoint.port}" } else { "http://example.test:${server.localEndpoint.port}" }
    let context = if (observed || h2 || overloaded) { owner.withEventSink(Some<api.NetworkEventSink>(evidence.ring)) } else { owner }
    let bufferSize: Int64 = if (scenario == "h1_bulk_32768" || slow) { 32768 } else if (early) { 1 } else { 4096 }
    let buffer = Array<Byte>(bufferSize, repeat: 0u8)
    let slowPrefix = Array<Byte>(if (scenario == "h2_slow_consumer") { 4096 } else { 0 }, repeat: 0u8)
    let latencies = ArrayList<Int64>()
    var bytes: Int64 = 0; var checksum: Int64 = 0; var readCalls: Int64 = 0
    var rejects: Int64 = 0; var expectedFailures: Int64 = 0; var closeNs: Int64 = 0
    var queuedHigh: Int64 = 0; var bufferHigh: UInt64 = 0u64
    var measuredNs: Int64 = 0; var cancelNs: Int64 = 0
    var prefixReadNs: Int64 = 0
    var prefixManagedBytes: UInt64 = 0u64
    var phase = "warmup"
    try {
        for (_ in 0..10) { readPerf(client.get("${base}/tiny", context: context), buffer, tinyLength, h2) }
        if (bulk || slow || early) { readPerf(client.get("${base}/bulk", context: context), if (early) { Array<Byte>(32768, repeat: 0u8) } else { buffer }, bulkLength, h2) }
        evidence.drain()
        handler.produced.store(0)
        evidence.eventCount = 0; evidence.queueHigh = 0; evidence.reused = 0; evidence.pressure = 0
        evidence.e2eNs = 0; evidence.e2eCount = 0
        for (i in 0..10) { evidence.stageNs[i] = 0; evidence.stageCounts[i] = 0 }
        let started = MonoTime.now()
        phase = "measured"
        if (overloaded) {
            let heldStart = MonoTime.now()
            let held = client.get("${base}/tiny", context: context)
            let queuedStart = MonoTime.now()
            let queuedContext = context.withEventCorrelation(requestId: Some(900001), attemptId: None<Int64>, connectionId: None<Int64>, streamId: None<Int64>)
            let queued = spawn { readPerf(client.get("${base}/tiny", context: queuedContext), Array<Byte>(4096, repeat: 0u8), tinyLength, false) }
            phase = "client admission saturation"
            waitPerf(owner, { => client.resourceSnapshot().admissionWaiters == 1 })
            queuedHigh = client.resourceSnapshot().admissionWaiters
            let rejectStart = MonoTime.now()
            var rejected = false
            try { let unexpected = client.get("${base}/tiny", context: context); unexpected.close() }
            catch (error: HttpException) {
                match (error.code) { case HttpErrorCode.PoolExhausted => rejected = true; case _ => throw error }
            }
            perfRequire(rejected && client.resourceSnapshot().rejectedOperations == 1, "saturated client did not reject capacity")
            latencies.add((MonoTime.now() - rejectStart).toNanoseconds()); rejects++
            let first = readPerf(held, buffer, tinyLength, false)
            latencies.add((MonoTime.now() - heldStart).toNanoseconds())
            let second = queued.get(owner.deadline.getOrThrow().remaining())
            latencies.add((MonoTime.now() - queuedStart).toNanoseconds())
            bytes += first[0] + second[0]; checksum += first[1] + second[1]; readCalls += first[2] + second[2]
            // Saturate server admission with a handler-held request on a separate native connection.
            let other = HttpClient.builder().resolver(resolver).connector(connector).resourceLimits(limitsPerf(2, 4, 1)).build()
            try {
                let holdStart = MonoTime.now()
                let holdTask = spawn { readPerf(other.get("${base}/hold", context: context), Array<Byte>(4096, repeat: 0u8), tinyLength, false) }
                waitPerf(owner, { => handler.held.load() })
                let serverRejectStart = MonoTime.now()
                let rejectedResponse = other.get("${base}/tiny", context: context)
                try { perfRequire(rejectedResponse.status == 503, "server admission did not reject overload") }
                finally { rejectedResponse.close() }
                latencies.add((MonoTime.now() - serverRejectStart).toNanoseconds()); rejects++
                handler.release.store(true)
                let recovered = holdTask.get(owner.deadline.getOrThrow().remaining())
                latencies.add((MonoTime.now() - holdStart).toNanoseconds())
                bytes += recovered[0]; checksum += recovered[1]; readCalls += recovered[2]
            } finally { handler.release.store(true); other.close() }
            let recoveryStart = MonoTime.now()
            let recovery = readPerf(client.get("${base}/tiny", context: context), buffer, tinyLength, false)
            latencies.add((MonoTime.now() - recoveryStart).toNanoseconds())
            bytes += recovery[0]; checksum += recovery[1]; readCalls += recovery[2]
            evidence.drain()
            perfRequire(evidence.queueWaitCount == 1 && evidence.queueWaitNs > 0, "missing correlated queue-wait stage measurement")
        } else if (slow) {
            let heldStart = MonoTime.now()
            let cancellation = HttpStreamCancellationHandle()
            let held = client.getControlled("${base}/bulk", HttpCancellationHandles(stream: Some(cancellation)), context: context)
            perfRequire(held.version == HttpVersion.Http2, "slow stream did not negotiate native H2")
            try {
                phase = "held flow stall"
                waitPerf(owner, { => evidence.drain(); evidence.pressure > 0 })
                // Exhaust the held stream's initial window, then prove sibling completion without draining it.
                let before = handler.produced.load()
                sleep(20 * Duration.millisecond)
                let stalled = handler.produced.load()
                perfRequire(stalled < bulkLength, "held large stream was eagerly buffered")
                bufferHigh = client.resourceSnapshot().highWaterManagedBufferBytes
                perfRequire(bufferHigh <= client.resourceSnapshot().limits.maximumManagedBufferBytes, "managed buffers exceeded cap")
                if (scenario == "h2_stream_cancel") {
                    let siblingStart = MonoTime.now()
                    let sibling = spawn { readPerf(client.get("${base}/tiny", context: context), Array<Byte>(32768, repeat: 0u8), tinyLength, true) }
                    waitPerf(owner, { => client.resourceSnapshot().activeRequests == 2 })
                    let cancelStart = MonoTime.now()
                    perfRequire(cancellation.cancel(), "stream cancellation was not accepted")
                    var failed = false
                    readCalls++
                    try { held.body.read(buffer) } catch (error: api.NetworkException) {
                        match (error.code) { case api.NetworkErrorCode.Cancelled => failed = true; case _ => throw error }
                    } catch (error: HttpBodyException) {
                        match (error.code) { case HttpBodyErrorCode.Closed => failed = true; case _ => throw error }
                    }
                    perfRequire(failed, "cancelled stream remained readable")
                    held.close()
                    cancelNs = (MonoTime.now() - cancelStart).toNanoseconds(); expectedFailures++
                    let result = sibling.get(owner.deadline.getOrThrow().remaining())
                    latencies.add((MonoTime.now() - siblingStart).toNanoseconds())
                    bytes += result[0]; checksum += result[1]; readCalls += result[2]
                } else {
                    // Donate connection credit below the stream-credit coalescing threshold.
                    let prefixStart = MonoTime.now()
                    let prefixBytes = held.body.read(slowPrefix)
                    prefixReadNs = (MonoTime.now() - prefixStart).toNanoseconds()
                    perfRequire(prefixBytes == 4096, "slow consumer prefix progress mismatch")
                    for (i in 0..prefixBytes) { perfRequire(slowPrefix[i] == 97u8, "slow prefix checksum mismatch") }
                    latencies.add(prefixReadNs); bytes += prefixBytes; checksum += prefixBytes * 97; readCalls++
                    prefixManagedBytes = client.resourceSnapshot().managedBufferBytes
                    for (_ in 0..10) {
                        let siblingStart = MonoTime.now()
                        let result = readPerf(client.get("${base}/tiny", context: context), buffer, tinyLength, true)
                        latencies.add((MonoTime.now() - siblingStart).toNanoseconds())
                        bytes += result[0]; checksum += result[1]; readCalls += result[2]
                    }
                    perfRequire(handler.produced.load() < bulkLength && before <= stalled, "sibling progress drained held stream")
                    let result = readPerf(held, buffer, bulkLength - 4096, true)
                    bytes += result[0]; checksum += result[1]; readCalls += result[2]
                }
                latencies.add((MonoTime.now() - heldStart).toNanoseconds())
                let finalStart = MonoTime.now()
                let finalResult = readPerf(client.get("${base}/tiny", context: context), buffer, tinyLength, true)
                latencies.add((MonoTime.now() - finalStart).toNanoseconds())
                bytes += finalResult[0]; checksum += finalResult[1]; readCalls += finalResult[2]
                evidence.drain()
                perfRequire(evidence.connections.size == 1 && connector.count.load() == 1, "sibling moved to another physical connection")
                perfRequire(evidence.pressure > 0, "held native H2 stream did not report actual flow stall")
            } finally { held.close() }
        } else {
            let concurrent: Int64 = if (scenario == "h2_streams_100") { 100 } else if (scenario == "h2_streams_10" || scenario == "h1_concurrent") { 10 } else { 1 }
            let rounds: Int64 = if (concurrent > 1) { 10 } else if (bulk) { 1 } else { 200 }
            for (_ in 0..rounds) {
                let futures = ArrayList<Future<(Int64, Int64, Int64, Int64)>>()
                let admitted = AtomicInt64(0)
                let releaseRound = AtomicBool(false)
                for (_ in 0..concurrent) {
                    let task = spawn {
                        let ownBuffer = if (concurrent == 1) { buffer } else { Array<Byte>(bufferSize, repeat: 0u8) }
                        let begin = MonoTime.now()
                        let response = client.get("${base}/${if (bulk || early) { "bulk" } else { "tiny" }}", context: context)
                        admitted.fetchAdd(1)
                        waitPerf(owner, { => releaseRound.load() })
                        if (early) {
                            perfRequire(response.version == HttpVersion.Http11, "early close protocol")
                            let n = response.body.read(ownBuffer)
                            perfRequire(n > 0 && n <= ownBuffer.size, "early response made no progress")
                            var sum: Int64 = 0
                            for (i in 0..n) { perfRequire(ownBuffer[i] == 97u8, "early body byte mismatch"); sum += 97 }
                            response.close()
                            ((MonoTime.now() - begin).toNanoseconds(), n, sum, 1)
                        } else {
                            let result = readPerf(response, ownBuffer, if (bulk) { bulkLength } else { tinyLength }, h2)
                            ((MonoTime.now() - begin).toNanoseconds(), result[0], result[1], result[2])
                        }
                    }
                    futures.add(task)
                }
                if (concurrent > 1) {
                    waitPerf(owner, { => admitted.load() == concurrent })
                    perfRequire(client.resourceSnapshot().activeRequests == concurrent, "missing concurrent response owners")
                }
                // The coordinator opens every round, after concurrent owners are admitted.
                releaseRound.store(true)
                for (task in futures) {
                    let result = task.get(owner.deadline.getOrThrow().remaining())
                    latencies.add(result[0]); bytes += result[1]; checksum += result[2]; readCalls += result[3]
                }
                if (observed || h2) { evidence.drain() }
            }
        }
        measuredNs = (MonoTime.now() - started).toNanoseconds()
        bufferHigh = max(bufferHigh, client.resourceSnapshot().highWaterManagedBufferBytes)
        if (h2) { perfRequire(connector.count.load() == 1, "H2 workload opened more than one physical connection") }
        if (scenario == "h1_new_connection") { perfRequire(connector.count.load() == 210, "new-connection workload reused a connection") }
        if (scenario == "h1_short_reuse" || bulk || observed) { perfRequire(connector.count.load() == 1, "reuse workload lost its native connection") }
    } catch (error: Exception) {
        println("FAIL ${scenario} phase=${phase} produced=${handler.produced.load()} requests=${handler.requests.load()} " +
            "active=${client.resourceSnapshot().activeRequests} waiters=${client.resourceSnapshot().admissionWaiters} ${error}")
        throw error
    } finally {
        let closing = MonoTime.now()
        handler.release.store(true); client.close(); server.close()
        serving.get(owner.deadline.getOrThrow().remaining())
        waitPerf(owner, { => zeroPerf(client.resourceSnapshot()) && zeroPerf(server.resourceSnapshot()) })
        closeNs = (MonoTime.now() - closing).toNanoseconds()
        clientTls.close(); serverTls.close()
    }
    let s = client.resourceSnapshot(); let ss = server.resourceSnapshot()
    let receiveReserveBytes = min(UInt64(s.limits.maximumConnections) * 65535u64,
        s.limits.maximumManagedBufferBytes - min(s.limits.reservedControlBufferBytes, s.limits.maximumManagedBufferBytes))
    let metrics = "{\"cleanup_owners\":0,\"observation_enabled\":${observed},\"tls_enabled\":${h2},\"native_protocol\":${if (h2) { 2 } else { 1 }},\"native_connections\":${connector.count.load()},\"body_read_calls\":${readCalls},\"read_calls\":${readCalls}," +
        "\"connection_capacity\":${clientConnectionCap},\"effective_receive_reserve_bytes\":${receiveReserveBytes},\"client_route_connection_cap\":${s.limits.maximumConnectionsPerRoute}," +
        "\"read_buffer_bytes\":${bufferSize},\"managed_buffer_high_water\":${bufferHigh},\"queue_high_water\":${max(queuedHigh, s.highWaterAdmissionWaiters)}," +
        "\"client_rejected_capacity\":${s.rejectedOperations},\"server_rejected_capacity\":${ss.rejectedOperations}," +
        "\"client_request_high_water\":${s.highWaterRequests},\"client_stream_high_water\":${s.highWaterStreams}," +
        "\"server_request_high_water\":${ss.highWaterRequests},\"server_buffer_high_water\":${ss.highWaterManagedBufferBytes}," +
        "\"close_latency_ns\":${closeNs},\"expected_cancellations\":${expectedFailures}" +
        ",\"completed_cancellations\":${s.completedCancellations}" +
        (if (expectedFailures > 0) { ",\"cancel_latency_ns\":${cancelNs}" } else { "" }) +
        (if (prefixReadNs > 0) { ",\"slow_prefix_bytes\":4096,\"initial_read_latency_ns\":${prefixReadNs},\"managed_buffer_after_prefix\":${prefixManagedBytes}" } else { "" }) +
        if (observed || h2 || overloaded) { evidence.metrics() + "}" } else { "}" }
    if (observed) { perfRequire(evidence.e2eCount >= 200, "missing attributed E2E body completion timestamps") }
    emitSample(scenario, if (overloaded) { "overload" } else if (scenario == "h2_slow_consumer") { "slow" } else if (early || scenario == "h2_stream_cancel") { "cleanup" } else { "normal" }, measuredNs, latencies.toArray(), latencies.size,
        latencies.size - rejects - expectedFailures, 0, bytes, checksum, metrics: metrics, expectedRejections: rejects + expectedFailures)
    0
}
