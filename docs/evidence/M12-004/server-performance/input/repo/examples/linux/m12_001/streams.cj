package wirestack_m12_001

import std.fs.File
import std.sync.*
import std.time.MonoTime
import wirestack as api
import wirestack.http.*
import wirestack.sse.*
import wirestack.net.TcpStream
import wirestack.tls as tls

// H1 uses the public TLS connector with explicit ALPN because the HTTP facade
// otherwise prefers H2. The HTTP URL here describes framing, not transport security.
class StreamH1Tls <: HttpConnector {
    let config: tls.TlsClientContext
    let negotiated = AtomicBool(false)
    let connections = AtomicInt64(0)
    init(cert: Array<Byte>) {
        config = tls.TlsClientContext.builder().trust(tls.TrustPolicy.customRoots(
            tls.CertificateChain([tls.DerCertificate(cert)]))).alpn(["http/1.1"]).build()
    }
    public func connect(endpoint: api.SocketEndpoint, owner: api.OperationContext): api.DuplexTransport {
        let connection = config.handshake(TcpStream.connect(endpoint, context: owner), api.HostName("example.test"), context: owner)
        perfRequire(connection.handshakeInfo.negotiatedAlpn == Some("http/1.1"), "TLS H1 ALPN differs")
        negotiated.store(true); connections.fetchAdd(1)
        connection
    }
}
func streamNs(start: MonoTime): Int64 { (MonoTime.now() - start).toNanoseconds() }
func streamLimits(): WebSocketLimits {
    WebSocketLimits(maximumFrameBytes: 1024, maximumMessageBytes: 2048, ioBufferBytes: 1024,
        closeTimeout: 2 * Duration.second)
}
func streamResources(): HttpResourceLimits {
    HttpResourceLimits(maximumConnections: 2, maximumConnectionsPerRoute: 2, maximumConnectionsPerOrigin: 2,
        maximumRequests: 4, maximumRequestsPerRoute: 4, maximumRequestsPerOrigin: 4,
        maximumStreams: 4, maximumStreamsPerRoute: 4, maximumStreamsPerOrigin: 4,
        maximumManagedBufferBytes: 1048576u64, reservedControlBufferBytes: 65536u64,
        maximumManagedBufferBytesPerRoute: 983040u64, maximumManagedBufferBytesPerOrigin: 983040u64,
        maximumWaiters: 4, maximumOwners: 8)
}
func streamPayload(i: Int64): String { "sequence:${i}:native-stream-payload" }
func streamOpcode(actual: WebSocketOpcode, wanted: WebSocketOpcode): Bool {
    match ((actual, wanted)) {
        case (WebSocketOpcode.Binary, WebSocketOpcode.Binary) | (WebSocketOpcode.Continuation, WebSocketOpcode.Continuation) |
            (WebSocketOpcode.Ping, WebSocketOpcode.Ping) | (WebSocketOpcode.Pong, WebSocketOpcode.Pong) |
            (WebSocketOpcode.Close, WebSocketOpcode.Close) => true
        case _ => false
    }
}
class StreamFixture <: HttpServerHandler & WebSocketHandler {
    let scenario: String
    let total: Int64
    let h2: Bool
    let offered: Array<MonoTime>
    let published = AtomicInt64(0)
    let consumed = AtomicInt64(0)
    let stopping = AtomicBool(false)
    let producers = AtomicInt64(0)
    let negotiated = AtomicBool(false)
    let queueHigh = AtomicInt64(0)
    let fragments = AtomicInt64(0)
    let controls = AtomicInt64(0)
    let outstandingHigh = AtomicInt64(0)
    let backpressureNs = AtomicInt64(0)
    let mutex = Mutex()
    var failure = None<Exception>
    var task = None<Future<Unit>>
    init(scenario: String, total: Int64, h2: Bool) {
        this.scenario = scenario; this.total = total; this.h2 = h2
        offered = Array<MonoTime>(total, repeat: MonoTime.now())
    }
    func waitConsumed(i: Int64, owner: api.OperationContext): Unit {
        while (consumed.load() <= i && !stopping.load()) {
            perfRequire(!owner.isDeadlineExceeded(), "producer acknowledgement exceeded absolute deadline")
            sleep(100 * Duration.microsecond)
        }
    }
    func record(error: Exception): Unit { synchronized(mutex) { failure = Some(error) } }
    func checkFailure(): Unit { synchronized(mutex) { if (let Some(error) <- failure) { throw error } } }
    public func handle(request: HttpServerRequest, owner: api.OperationContext): HttpServerResponse {
        perfRequire(request.version == if (h2) { api.HttpVersion.Http2 } else { api.HttpVersion.Http11 }, "negotiated HTTP version differs")
        negotiated.store(true)
        if (!scenario.startsWith("sse")) { return HttpServerResponse.webSocket(request, this, limits: streamLimits()) }
        request.body.close()
        let writer = SseWriter(maximumBufferBytes: 128, context: owner)
        producers.fetchAdd(1)
        task = Some(spawn {
            try {
                for (i in 0..total) {
                    offered[i] = MonoTime.now(); published.store(i + 1)
                    outstandingHigh.store(max(outstandingHigh.load(), i + 1 - consumed.load()))
                    writer.write(SseEvent(streamPayload(i), lastEventId: "${i}"), context: owner)
                    queueHigh.store(max(queueHigh.load(), writer.queuedBytes))
                    perfRequire(writer.queuedBytes <= 128, "SSE writer ring exceeded capacity")
                    let waiting = MonoTime.now(); writer.flush(context: owner); waitConsumed(i, owner)
                    if (i >= 8) { backpressureNs.fetchAdd(streamNs(waiting)) }
                    if (i >= 8) { sleep(2 * Duration.millisecond) }
                }
                if (scenario == "sse_cancel") {
                    while (!stopping.load()) { perfRequire(!owner.isDeadlineExceeded(), "held SSE producer expired"); sleep(Duration.millisecond) }
                    writer.close()
                } else { writer.complete() }
            } catch (error: Exception) { record(error); writer.close() }
            finally { producers.fetchSub(1) }
        })
        HttpServerResponse(api.HttpResponse(200, "OK", api.ResponseBody(writer),
            headers: api.HttpHeaders.builder().add("Content-Type", "text/event-stream").build()))
    }
    public func serve(session: WebSocketConnection, owner: api.OperationContext): Unit {
        producers.fetchAdd(1)
        try {
            for (i in 0..total) {
                offered[i] = MonoTime.now(); published.store(i + 1)
                outstandingHigh.store(max(outstandingHigh.load(), i + 1 - consumed.load()))
                if (scenario == "websocket_fragmented") {
                    session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "sequence:${i}:".toArray(), finalFragment: false), context: owner)
                    fragments.fetchAdd(1)
                    session.send(WebSocketFrame(WebSocketOpcode.Ping, payload: [17u8]), context: owner)
                    let pong = session.receive(context: owner)
                    perfRequire(streamOpcode(pong.opcode, WebSocketOpcode.Pong) && pong.payload == [17u8], "interleaved automatic pong differs")
                    controls.fetchAdd(1)
                    session.send(WebSocketFrame(WebSocketOpcode.Continuation, payload: "native-stream-payload".toArray()), context: owner)
                    fragments.fetchAdd(1)
                } else { session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: streamPayload(i).toArray()), context: owner) }
                let waiting = MonoTime.now(); let ack = session.receive(context: owner)
                if (i >= 8) { backpressureNs.fetchAdd(streamNs(waiting)) }
                perfRequire(streamOpcode(ack.opcode, WebSocketOpcode.Binary) && String.fromUtf8(ack.payload) == "ack:${i}", "WebSocket sequence acknowledgement differs")
                consumed.store(i + 1)
                if (i >= 8) { sleep(2 * Duration.millisecond) }
            }
            while (!stopping.load()) { perfRequire(!owner.isDeadlineExceeded(), "held WebSocket producer expired"); sleep(Duration.millisecond) }
        } catch (error: Exception) { record(error) }
        finally { session.close(); producers.fetchSub(1) }
    }
    func join(owner: api.OperationContext): Unit {
        if (let Some(value) <- task) { value.get(owner.deadline.getOrThrow().remaining()) }
        while (producers.load() != 0) {
            perfRequire(!owner.isDeadlineExceeded(), "producer did not join"); sleep(Duration.millisecond)
        }
        checkFailure()
    }
}
func streamZero(row: HttpResourceSnapshot): Bool {
    row.activeConnections == 0 && row.reservedConnections == 0 && row.activeRequests == 0 &&
        row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 &&
        row.admissionWaiters == 0 && row.owners.isEmpty()
}
func streamSample(client: HttpClient, server: HttpServer): UInt64 {
    let c = client.resourceSnapshot(); let s = server.resourceSnapshot()
    perfRequire(c.highWaterManagedBufferBytes <= c.limits.maximumManagedBufferBytes &&
        s.highWaterManagedBufferBytes <= s.limits.maximumManagedBufferBytes, "managed storage exceeded configured ceiling")
    c.highWaterManagedBufferBytes + s.highWaterManagedBufferBytes
}
main(args: Array<String>): Int64 {
    perfRequire(args.size == 3, "usage: streams scenario certificate.der key.pk8")
    let scenario = args[0]
    perfRequire(["sse_h1", "sse_h2", "sse_slow", "sse_cancel", "websocket_h1", "websocket_h2",
        "websocket_fragmented", "websocket_slow", "websocket_disconnect"].contains(scenario), "unknown stream scenario")
    let isSse = scenario.startsWith("sse"); let h2 = scenario != "sse_h1" && scenario != "websocket_h1"
    let terminal = scenario == "sse_cancel" || scenario == "websocket_disconnect"
    let slow = scenario == "sse_slow" || scenario == "websocket_slow"
    let count: Int64 = if (terminal) { 8 } else if (scenario == "websocket_fragmented") { 200 } else { 256 }
    let total = count + 8; let owner = perfOwner()
    let cert = File.readFrom(args[1]); let serverTls = HttpServerTlsConfig([cert], File.readFrom(args[2]))
    let clientTls = HttpClientTlsConfig([cert]); let h1 = StreamH1Tls(cert)
    let fixture = StreamFixture(scenario, total, h2)
    let server = HttpServer.builder().listen(api.SocketEndpoint(perfLoopback(), 0u16)).handler(fixture).tls(serverTls)
        .resourceLimits(streamResources()).connectionLimit(2).http2StreamLimit(2u32).build()
    let serving = spawn { server.serve(context: owner) }
    let resolver = api.StaticResolver(api.ResolveResult([perfLoopback()], api.HostName("example.test"), api.ResolverSource.Static))
    let builder = HttpClient.builder().resolver(resolver).resourceLimits(streamResources()).retryPolicy(HttpRetryPolicy(maximumAttempts: 1))
    if (h2) { builder.tls(clientTls) } else { builder.connector(h1) }
    let client = builder.build(); let port = server.localEndpoint.port
    let latencies = Array<Int64>(count + if (terminal) { 1 } else { 0 }, repeat: 0)
    var first: Int64 = 0; var bytes: Int64 = 0; var checksum: Int64 = 0
    var high = streamSample(client, server); var activeHigh: UInt64 = 0u64; var cancelNs: Int64 = 0
    var measuredStart = MonoTime.now(); var duration: Int64 = 0; var cleanup = MonoTime.now()
    let openStart = MonoTime.now()
    try {
        if (isSse) {
            let source = api.CancellationSource()
            let session = SseSession.oneShot(client, api.HttpRequest(api.HttpMethod("GET"),
                api.HttpUrl.parse("${if (h2) { "https" } else { "http" }}://example.test:${port}/events")),
                limits: SseLimits(maximumLineBytes: 128, maximumEventBytes: 256, maximumIdBytes: 32),
                readBufferBytes: 128, context: owner.withCancellation(source.token))
            try {
                for (i in 0..total) {
                    if (i == 8) { measuredStart = MonoTime.now() }
                    if (i > 0) { while (fixture.published.load() <= i) { perfRequire(!owner.isDeadlineExceeded(), "event was not offered"); sleep(100 * Duration.microsecond) } }
                    if (slow && i >= 8) { sleep(Duration.millisecond) }
                    let event = session.receive().getOrThrow()
                    perfRequire(event.data == streamPayload(i) && event.lastEventId == "${i}", "SSE sequence content differs")
                    if (i == 0) { first = streamNs(openStart) }
                    if (i >= 8) { latencies[i - 8] = streamNs(fixture.offered[i]); bytes += event.data.size; for (b in event.data.toArray()) { checksum += Int64(b) } }
                    fixture.consumed.store(i + 1)
                    let row = client.resourceSnapshot(); activeHigh = max(activeHigh, row.managedBufferBytes)
                    high = max(high, streamSample(client, server))
                    perfRequire(row.managedBufferBytes >= session.reservedBufferBytes, "SSE live reservation missing")
                }
                if (terminal) {
                    let entered = AtomicBool(false)
                    let pendingStart = MonoTime.now()
                    let pending = spawn {
                        entered.store(true)
                        try { let _ = session.receive(); false }
                        catch (error: api.NetworkException) { match (error.code) { case api.NetworkErrorCode.Cancelled => true; case _ => false } }
                    }
                    while (!entered.load()) { perfRequire(!owner.isDeadlineExceeded(), "pending cancellation did not start"); sleep(100 * Duration.microsecond) }
                    sleep(5 * Duration.millisecond); let cancelling = MonoTime.now(); source.cancel()
                    perfRequire(pending.get(owner.deadline.getOrThrow().remaining()), "SSE cancellation code differs")
                    cancelNs = streamNs(cancelling); latencies[count] = streamNs(pendingStart)
                    fixture.stopping.store(true)
                } else { perfRequire(session.receive().isNone(), "SSE stream missing exact EOF") }
            } finally { session.close(); fixture.stopping.store(true) }
        } else {
            let session = match (client.connectWebSocket(WebSocketUrl.parse("${if (h2) { "wss" } else { "ws" }}://example.test:${port}/socket"),
                webSocketLimits: streamLimits(), context: owner)) {
                case WebSocketConnectResult.Connected(value) => value
                case WebSocketConnectResult.Rejected(response) => response.close(); throw IllegalStateException("unexpected WebSocket rejection")
            }
            try {
                for (i in 0..total) {
                    if (i == 8) { measuredStart = MonoTime.now() }
                    while (fixture.published.load() <= i) { perfRequire(!owner.isDeadlineExceeded(), "message was not offered"); sleep(100 * Duration.microsecond) }
                    if (slow && i >= 8) { sleep(Duration.millisecond) }
                    let frame = session.receive(context: owner)
                    perfRequire(streamOpcode(frame.opcode, WebSocketOpcode.Binary), "message opcode differs")
                    var payload = String.fromUtf8(frame.payload)
                    if (scenario == "websocket_fragmented") {
                        perfRequire(!frame.finalFragment, "first fragment unexpectedly final")
                        let ping = session.receive(context: owner)
                        perfRequire(streamOpcode(ping.opcode, WebSocketOpcode.Ping) && ping.payload == [17u8], "interleaved ping differs")
                        let last = session.receive(context: owner)
                        perfRequire(streamOpcode(last.opcode, WebSocketOpcode.Continuation) && last.finalFragment, "final continuation differs")
                        payload += String.fromUtf8(last.payload)
                    } else { perfRequire(frame.finalFragment, "complete message was fragmented") }
                    perfRequire(payload == streamPayload(i), "WebSocket full message sequence differs")
                    if (i == 0) { first = streamNs(openStart) }
                    if (i >= 8) { latencies[i - 8] = streamNs(fixture.offered[i]); bytes += payload.size; for (b in payload.toArray()) { checksum += Int64(b) } }
                    session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "ack:${i}".toArray()), context: owner)
                    activeHigh = max(activeHigh, client.resourceSnapshot().managedBufferBytes)
                    high = max(high, streamSample(client, server))
                }
                while (fixture.consumed.load() < total) { perfRequire(!owner.isDeadlineExceeded(), "last acknowledgement was not consumed"); sleep(100 * Duration.microsecond) }
                if (terminal) {
                    let entered = AtomicBool(false); let pendingStart = MonoTime.now()
                    let pending = spawn {
                        entered.store(true)
                        try { let _ = session.receive(context: owner); false }
                        catch (error: WebSocketException) { match (error.code) { case WebSocketErrorCode.TransportFailure => true; case _ => false } }
                    }
                    while (!entered.load()) { perfRequire(!owner.isDeadlineExceeded(), "pending disconnect did not start"); sleep(100 * Duration.microsecond) }
                    sleep(5 * Duration.millisecond); let cancelling = MonoTime.now(); fixture.stopping.store(true)
                    perfRequire(pending.get(owner.deadline.getOrThrow().remaining()) && !owner.isDeadlineExceeded(), "peer disconnect did not report TransportFailure")
                    cancelNs = streamNs(cancelling); latencies[count] = streamNs(pendingStart)
                }
            } finally { fixture.stopping.store(true); session.close() }
        }
        duration = streamNs(measuredStart)
        perfRequire(fixture.negotiated.load() && (h2 || h1.negotiated.load()), "native TLS protocol not proved")
        if (!terminal) { perfRequire(duration >= 250000000, "resident sample interval shorter than 250ms") }
    } finally { cleanup = MonoTime.now(); fixture.stopping.store(true); client.close() }
    fixture.join(owner)
    let shutdown = server.shutdown(context: owner)
    perfRequire(shutdown.activeAtReturn == 0, "server retained active tasks")
    serving.get(owner.deadline.getOrThrow().remaining()); server.close(); clientTls.close(); serverTls.close()
    perfRequire(streamZero(client.resourceSnapshot()) && streamZero(server.resourceSnapshot()), "terminal client/server ledger not zero")
    let cleanupNs = streamNs(cleanup)
    perfRequire(fixture.consumed.load() == total && fixture.producers.load() == 0 && fixture.outstandingHigh.load() == 1, "producer sequence/join/bounded flow differs")
    if (slow) { for (latency in latencies) { perfRequire(latency >= 1000000, "slow-consumer pause absent from offered latency") } }
    if (scenario == "websocket_fragmented") { perfRequire(fixture.fragments.load() == 2 * total && fixture.controls.load() == total, "fragment/control counts differ") }
    var metrics = "{\"cleanup_owners\":0,\"cleanup_ns\":${cleanupNs},\"managed_buffer_highwater_bytes\":${high},\"sampled_active_managed_buffer_bytes\":${activeHigh}," +
        "\"tls_negotiated\":true,\"h2_negotiated\":${h2},\"maximum_outstanding_messages\":${fixture.outstandingHigh.load()},\"consumer_pause_ns\":${if (slow) { 1000000 } else { 0 }}," +
        "\"${if (isSse) { "first_event_ns" } else { "first_message_ns" }}\":${first}"
    metrics += ",\"producer_backpressure_ns\":${fixture.backpressureNs.load()}"
    if (isSse) { metrics += ",\"writer_queue_highwater_bytes\":${fixture.queueHigh.load()},\"writer_capacity_bytes\":128" }
    if (!h2) { metrics += ",\"native_connection_count\":${h1.connections.load()}" }
    if (terminal) { metrics += ",\"cancel_ns\":${cancelNs}" }
    if (scenario == "websocket_fragmented") { metrics += ",\"fragmentation_count\":${fixture.fragments.load() - 16},\"control_frame_count\":${fixture.controls.load() - 8}" }
    metrics += "}"
    emitSample(scenario, if (slow) { "slow" } else if (terminal) { "cleanup" } else { "normal" }, duration,
        latencies, latencies.size, count, 0, bytes, checksum, metrics: metrics, expectedRejections: if (terminal) { 1 } else { 0 })
    0
}
