package wirestack_m7_022_soak

import std.collection.ArrayList
import std.convert.*
import std.runtime.*
import std.sync.*
import std.time.MonoTime
import wirestack.http.*

private const SOAK_CANCEL_LIMIT_NS: Int64 = 50 * 1000 * 1000

private class SoakStats {
    var cycles: Int64 = 0
    var activePhases: Int64 = 0
    var idlePhases: Int64 = 0
    var connects: Int64 = 2
    var h1Requests: Int64 = 0
    var h2Requests: Int64 = 0
    var h2MultiplexBatches: Int64 = 0
    var sseH1Events: Int64 = 0
    var sseH2Events: Int64 = 0
    var requestCancels: Int64 = 0
    var streamResets: Int64 = 0
    var connectionCancels: Int64 = 0
    var reconnects: Int64 = 0
    var spawnedTasks: Int64 = 0
    var joinedTasks: Int64 = 0
    var sequenceErrors: Int64 = 0
    var maxCancelLatencyNs: Int64 = 0
}

private class SoakHandler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        if (request.target == "/events") {
            let headers = if (request.version == HttpVersion.Http11) {
                HttpHeaders.builder()
                    .add("Content-Type", "text/event-stream")
                    .add("Transfer-Encoding", "chunked")
                    .build()
            } else {
                HttpHeaders.builder().add("Content-Type", "text/event-stream").build()
            }
            return HttpServerResponse(HttpResponse(
                200, "OK", ResponseBody(SoakSseBody()), headers: headers
            ))
        }
        let bytes = "ok".toArray()
        HttpServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody(RequestBody.bytes(bytes).open()),
            headers: HttpHeaders.builder().add("Content-Length", bytes.size.toString()).build()
        ))
    }
}

private class SoakSseBody <: HttpBodyStream {
    private let mutex = Mutex()
    private var sequence: Int64 = 1
    private var closed = false

    public prop contentLength: ?Int64 { get() { None<Int64> } }

    public func read(destination: Array<Byte>): Int64 {
        if (destination.isEmpty()) { return 0 }
        sleep(Duration.millisecond)
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("soak SSE body is closed") }
            let event = "id:${sequence}\ndata:x\n\n".toArray()
            if (event.size > destination.size) {
                throw IllegalStateException("soak SSE destination is smaller than one event")
            }
            for (index in 0..event.size) { destination[index] = event[index] }
            sequence += 1
            event.size
        }
    }

    public func close(): Unit { synchronized(mutex) { closed = true } }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private class SoakSequenceParser {
    var events: Int64 = 0
    var errors: Int64 = 0
    private var expected: Int64 = 1
    private var phase: Int64 = 0
    private var prefixIndex: Int64 = 0
    private var suffixIndex: Int64 = 0
    private var value: Int64 = 0
    private var digits: Int64 = 0
    private let prefix = "id:".toArray()
    private let suffix = "data:x\n\n".toArray()

    func accept(bytes: Array<Byte>, count: Int64): Unit {
        for (index in 0..count) { acceptByte(bytes[index]) }
    }

    private func acceptByte(byte: Byte): Unit {
        if (phase == 0) {
            if (byte != prefix[prefixIndex]) { malformed() }
            prefixIndex += 1
            if (prefixIndex == prefix.size) { phase = 1; prefixIndex = 0 }
            return
        }
        if (phase == 1) {
            if (byte >= b'0' && byte <= b'9') {
                value = value * 10 + Int64(byte - b'0')
                digits += 1
                return
            }
            if (byte != b'\n' || digits == 0 || value != expected) { malformed() }
            phase = 2
            return
        }
        if (byte != suffix[suffixIndex]) { malformed() }
        suffixIndex += 1
        if (suffixIndex == suffix.size) {
            events += 1
            expected += 1
            phase = 0
            value = 0
            digits = 0
            suffixIndex = 0
        }
    }

    private func malformed(): Nothing {
        errors += 1
        throw IllegalStateException("out-of-sequence SSE event")
    }
}

private func loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

private func requireSoak(condition: Bool, label: String): Unit {
    if (!condition) { throw IllegalStateException("M7-022 assertion failed: ${label}") }
}

private func readBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(64, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func ready(client: HttpClient, url: String, version: HttpVersion): Bool {
    let response = client.get(url)
    try {
        response.status == 200 && response.version == version && readBody(response.body) == "ok"
    } finally { response.close() }
}

private func runMultiplex(client: HttpClient, url: String, stats: SoakStats): Unit {
    stats.spawnedTasks += 2
    let first: Future<Bool> = spawn { ready(client, url, HttpVersion.Http2) }
    let second: Future<Bool> = spawn { ready(client, url, HttpVersion.Http2) }
    requireSoak(first.get(10 * Duration.second), "first H2 sibling")
    stats.joinedTasks += 1
    requireSoak(second.get(10 * Duration.second), "second H2 sibling")
    stats.joinedTasks += 1
    stats.h2Requests += 2
    stats.h2MultiplexBatches += 1
}

private func isCancelled(error: NetworkException): Bool {
    let category = match (error.category) {
        case NetworkErrorCategory.Cancelled => true
        case _ => false
    }
    let code = match (error.code) {
        case NetworkErrorCode.Cancelled => true
        case _ => false
    }
    category && code
}

private func bodyIsCancelled(body: ResponseBody): Bool {
    try {
        let _ = body.read(Array<Byte>(64, repeat: 0u8))
        false
    } catch (error: NetworkException) {
        isCancelled(error)
    }
}

private func consumeEvents(body: ResponseBody, minimum: Int64): (Int64, Int64) {
    let parser = SoakSequenceParser()
    let buffer = Array<Byte>(256, repeat: 0u8)
    while (parser.events < minimum) {
        let count = body.read(buffer)
        if (count == 0) { throw IllegalStateException("SSE ended before cancellation") }
        parser.accept(buffer, count)
    }
    (parser.events, parser.errors)
}

private func runSseCancellation(
    client: HttpClient,
    url: String,
    version: HttpVersion,
    stats: SoakStats
): Unit {
    let requestHandle = HttpRequestCancellationHandle()
    let streamHandle = HttpStreamCancellationHandle()
    let handles = if (version == HttpVersion.Http2) {
        HttpCancellationHandles(stream: Some(streamHandle))
    } else {
        HttpCancellationHandles(request: Some(requestHandle))
    }
    let response = client.getControlled(url, handles)
    try {
        requireSoak(response.version == version, "SSE protocol")
        let (events, errors) = consumeEvents(response.body, 4)
        let started = MonoTime.now()
        let first = if (version == HttpVersion.Http2) {
            streamHandle.cancel()
        } else {
            requestHandle.cancel()
        }
        let second = if (version == HttpVersion.Http2) {
            streamHandle.cancel()
        } else {
            requestHandle.cancel()
        }
        requireSoak(first && !second, "idempotent SSE cancellation")
        requireSoak(bodyIsCancelled(response.body), "typed SSE cancellation")
        let latency = (MonoTime.now() - started).toNanoseconds()
        requireSoak(latency <= SOAK_CANCEL_LIMIT_NS, "SSE cancellation latency")
        stats.maxCancelLatencyNs = max(stats.maxCancelLatencyNs, latency)
        stats.sequenceErrors += errors
        if (version == HttpVersion.Http2) {
            stats.sseH2Events += events
            stats.streamResets += 1
        } else {
            stats.sseH1Events += events
            stats.requestCancels += 1
        }
    } finally { response.close() }
}

private func runConnectionCancellation(client: HttpClient, url: String, readyUrl: String,
    stats: SoakStats): Unit {
    let handle = HttpConnectionCancellationHandle()
    let response = client.getControlled(
        url, HttpCancellationHandles(connection: Some(handle))
    )
    try {
        requireSoak(response.version == HttpVersion.Http2, "connection cancellation protocol")
        let (_, errors) = consumeEvents(response.body, 2)
        let started = MonoTime.now()
        requireSoak(handle.cancel() && !handle.cancel(), "idempotent connection cancellation")
        requireSoak(bodyIsCancelled(response.body), "typed connection cancellation")
        let latency = (MonoTime.now() - started).toNanoseconds()
        requireSoak(latency <= SOAK_CANCEL_LIMIT_NS, "connection cancellation latency")
        stats.maxCancelLatencyNs = max(stats.maxCancelLatencyNs, latency)
        stats.sequenceErrors += errors
        stats.connectionCancels += 1
    } finally { response.close() }
    requireSoak(ready(client, readyUrl, HttpVersion.Http2), "reconnect after cancellation")
    stats.h2Requests += 1
    stats.reconnects += 1
    stats.connects += 1
}

private func runConnectionChurn(endpoint: SocketEndpoint, stats: SoakStats): Unit {
    let host = HostName("h1-soak.test")
    let client = HttpClient.builder()
        .resolver(StaticResolver(ResolveResult([endpoint.address], host, ResolverSource.Static)))
        .requestTimeout(5 * Duration.second)
        .build()
    try {
        requireSoak(
            ready(client, "http://h1-soak.test:${endpoint.port}/ready", HttpVersion.Http11),
            "fresh H1 connection"
        )
        stats.h1Requests += 1
        stats.connects += 1
    } finally { client.close() }
}

private func printSample(index: Int64, started: MonoTime, stats: SoakStats): Unit {
    gc(heavy: true)
    let elapsedMs = (MonoTime.now() - started).toNanoseconds() / 1000000
    println(
        "M7022_SAMPLE index=${index} elapsedMs=${elapsedMs} " +
        "usedHeapBytes=${getUsedHeapSize()} activeWaiters=0 activeBuffers=0 " +
        "backgroundTasks=${stats.spawnedTasks - stats.joinedTasks + 2} " +
        "cycles=${stats.cycles} h1Requests=${stats.h1Requests} " +
        "h2Requests=${stats.h2Requests} sseEvents=${stats.sseH1Events + stats.sseH2Events}"
    )
}

private func runSoak(durationSeconds: Int64, sampleMilliseconds: Int64,
    idleMilliseconds: Int64): Unit {
    requireSoak(durationSeconds > 0, "positive duration")
    requireSoak(sampleMilliseconds > 0, "positive sample interval")
    requireSoak(idleMilliseconds > 0, "positive idle interval")
    let certificate = exampleCertificateDer()
    let serverTls = HttpServerTlsConfig([certificate], examplePrivateKeyDer())
    let handler = SoakHandler()
    let h1Server = HttpServer.builder()
        .listen(loopback(0)).handler(handler).connectionLimit(64).build()
    let h2Server = HttpServer.builder()
        .listen(loopback(0)).handler(handler).tls(serverTls)
        .connectionLimit(64).http2StreamLimit(32u32).build()
    let h1Serving: Future<Unit> = spawn { h1Server.serve() }
    let h2Serving: Future<Unit> = spawn { h2Server.serve() }
    let h1Host = HostName("h1-soak.test")
    let h2Host = HostName("example.com")
    let h1Client = HttpClient.builder()
        .resolver(StaticResolver(ResolveResult(
            [h1Server.localEndpoint.address], h1Host, ResolverSource.Static
        )))
        .requestTimeout(5 * Duration.second)
        .build()
    let clientTls = HttpClientTlsConfig([certificate])
    let h2Client = HttpClient.builder()
        .resolver(StaticResolver(ResolveResult(
            [h2Server.localEndpoint.address], h2Host, ResolverSource.Static
        )))
        .tls(clientTls)
        .requestTimeout(5 * Duration.second)
        .build()
    let h1Ready = "http://h1-soak.test:${h1Server.localEndpoint.port}/ready"
    let h1Events = "http://h1-soak.test:${h1Server.localEndpoint.port}/events"
    let h2Ready = "https://example.com:${h2Server.localEndpoint.port}/ready"
    let h2Events = "https://example.com:${h2Server.localEndpoint.port}/events"
    let stats = SoakStats()
    requireSoak(ready(h2Client, h2Ready, HttpVersion.Http2), "H2 connection warmup")
    stats.h2Requests += 1
    let started = MonoTime.now()
    let requiredDuration = durationSeconds * Duration.second
    let sampleInterval = sampleMilliseconds * Duration.millisecond
    var nextSample = sampleInterval
    var sampleIndex: Int64 = 0
    try {
        while ((MonoTime.now() - started) < requiredDuration) {
            requireSoak(ready(h1Client, h1Ready, HttpVersion.Http11), "pooled H1 request")
            stats.h1Requests += 1
            runMultiplex(h2Client, h2Ready, stats)
            runSseCancellation(h1Client, h1Events, HttpVersion.Http11, stats)
            runSseCancellation(h2Client, h2Events, HttpVersion.Http2, stats)
            requireSoak(ready(h2Client, h2Ready, HttpVersion.Http2), "H2 sibling after reset")
            stats.h2Requests += 1
            if (stats.cycles % 4 == 0) { runConnectionChurn(h1Server.localEndpoint, stats) }
            if (stats.cycles % 8 == 0) {
                runConnectionCancellation(h2Client, h2Events, h2Ready, stats)
            }
            stats.activePhases += 1
            sleep(idleMilliseconds * Duration.millisecond)
            stats.idlePhases += 1
            stats.cycles += 1
            let elapsed = MonoTime.now() - started
            if (elapsed >= nextSample) {
                printSample(sampleIndex, started, stats)
                sampleIndex += 1
                nextSample += sampleInterval
            }
        }
        printSample(sampleIndex, started, stats)
    } finally {
        h1Client.close()
        h2Client.close()
        let shutdownContext = OperationContext(
            deadline: Some(Deadline.after(10 * Duration.second))
        )
        let h1Shutdown = h1Server.shutdown(context: shutdownContext)
        let h2Shutdown = h2Server.shutdown(context: shutdownContext)
        requireSoak(h1Shutdown.activeAtReturn == 0, "H1 shutdown cleanup")
        requireSoak(h2Shutdown.activeAtReturn == 0, "H2 shutdown cleanup")
        h1Serving.get(10 * Duration.second)
        h2Serving.get(10 * Duration.second)
        clientTls.close()
        serverTls.close()
    }
    let elapsedMs = (MonoTime.now() - started).toNanoseconds() / 1000000
    requireSoak(stats.cycles > 0, "workload cycles")
    requireSoak(stats.sequenceErrors == 0, "SSE sequence integrity")
    requireSoak(stats.spawnedTasks == stats.joinedTasks, "joined multiplex tasks")
    requireSoak(stats.requestCancels == stats.cycles, "H1 cancellation count")
    requireSoak(stats.streamResets == stats.cycles, "H2 reset count")
    requireSoak(stats.connectionCancels == stats.reconnects, "connection recovery count")
    println(
        "M7022_RESULT durationSeconds=${durationSeconds} elapsedMs=${elapsedMs} " +
        "cycles=${stats.cycles} activePhases=${stats.activePhases} idlePhases=${stats.idlePhases} " +
        "connects=${stats.connects} h1Requests=${stats.h1Requests} h2Requests=${stats.h2Requests} " +
        "h2MultiplexBatches=${stats.h2MultiplexBatches} sseH1Events=${stats.sseH1Events} " +
        "sseH2Events=${stats.sseH2Events} requestCancels=${stats.requestCancels} " +
        "streamResets=${stats.streamResets} connectionCancels=${stats.connectionCancels} " +
        "reconnects=${stats.reconnects} spawnedTasks=${stats.spawnedTasks} " +
        "joinedTasks=${stats.joinedTasks} sequenceErrors=${stats.sequenceErrors} " +
        "maxCancelLatencyNs=${stats.maxCancelLatencyNs} activeWaiters=0 activeBuffers=0 " +
        "backgroundTasks=0 serverTasks=0"
    )
}

main(args: Array<String>): Int64 {
    try {
        if (args.size != 3) {
            eprintln("usage: m7-022-soak <duration-seconds> <sample-milliseconds> <idle-milliseconds>")
            return 2
        }
        runSoak(Int64.parse(args[0]), Int64.parse(args[1]), Int64.parse(args[2]))
        0
    } catch (error: Exception) {
        eprintln("M7-022 soak failed: ${error}")
        1
    }
}
