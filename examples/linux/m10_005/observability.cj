package wirestack_m10_005_observation

import std.collection.ArrayList
import std.fs.File
import std.sync.*
import wirestack as api
import std.convert.Parsable
import std.time.MonoTime
import std.env.getStdOut
import wirestack.{OperationTimeoutPolicy, OperationTimeoutStage}
import wirestack.http.*
import wirestack.net.TcpStream
import wirestack.observability.*

func require(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func scope(sink: ?NetworkEventSink, policy!: OperationTimeoutPolicy = OperationTimeoutPolicy()): OperationContext {
    OperationContext(deadline: Some(Deadline.after(5 * Duration.second)), eventSink: sink, timeoutPolicy: policy)
}
func consume(response: HttpResponse): Unit {
    try { let bytes = Array<Byte>(8192, repeat: 0u8); while (response.body.read(bytes) != 0) {} }
    finally { response.close() }
}
func clean(client: HttpClient): Unit {
    let deadline = Deadline.after(3 * Duration.second)
    while (true) {
        let sample = client.observationSnapshot().resources
        if (sample.activeRequests == 0 && sample.activeStreams == 0 && sample.reservedStreams == 0 &&
            sample.managedBufferBytes == 0u64) { return }
        require(!deadline.isExpired(), "request/stream/buffer resources were not reclaimed")
        sleep(5 * Duration.millisecond)
    }
}
class Handler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        if (request.target == "/redirect") {
            return HttpServerResponse(HttpResponse(302, "Found", ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Location", "/result").add("Content-Length", "0").build()))
        }
        if (request.target == "/slow-headers" || request.target == "/backpressure") {
            sleep(600 * Duration.millisecond)
        }
        if (request.target == "/backpressure") {
            let bytes = Array<Byte>(8192, repeat: 0u8)
            while (request.body.read(bytes) != 0) {}
        }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("payload").open()),
            headers: HttpHeaders.builder().add("Content-Length", "7").build()))
    }
}
// The first failure is an actual refused TCP connection, not a synthetic exception.
class RetryConnector <: HttpConnector {
    private let calls = AtomicInt64(0)
    private let refused: SocketEndpoint
    init(port: UInt16) { refused = SocketEndpoint(loopback(), port) }
    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        TcpStream.connect(if (calls.fetchAdd(1) == 0) { refused } else { endpoint }, context: context)
    }
}
// A caller-owned resolver deliberately supplies no resource-owner interface.
class SlowResolver <: Resolver {
    public func resolve(_: HostName, _: ?String, _: ResolveOptions, context: OperationContext): ResolveResult {
        api.emitNetworkEvent(context, NetworkEvent(NetworkEventKind.DnsStarted, NetworkEventOutcome.Started))
        while (!context.isDeadlineExceeded()) { sleep(Duration.millisecond) }
        api.emitNetworkEvent(context, NetworkEvent(NetworkEventKind.DnsCompleted, NetworkEventOutcome.Failed,
            errorCode: Some(NetworkErrorCode.TimedOut)))
        throw NetworkException(NetworkErrorCategory.Resolve, NetworkPhase.Dns,
            NetworkErrorCode.TimedOut, "controlled resolver deadline expired")
    }
}
class Authorization <: HttpProxyAuthorizationProvider {
    public func authorization(_: HttpProxyEndpoint, _: HttpUrl, _: OperationContext): ?String {
        Some("Basic M10_005_SECRET_MARKER")
    }
}
// The exported collector is itself fixed-capacity and retains no identifier map.
class Collector <: NetworkEventExporter {
    let ring = api.NetworkEventBuffer(capacity: 4096)
    public func export(events: Array<NetworkEvent>, context: OperationContext): Unit {
        require(!context.isDeadlineExceeded(), "export deadline expired")
        for (event in events) { ring.emit(event) }
    }
}
func checkSecrecy(events: Array<NetworkEvent>): Unit {
    for (event in events) {
        if (let Some(trace) <- event.trace) {
            require(!trace.traceId.contains("M10_005_SECRET_MARKER") &&
                !trace.spanId.contains("M10_005_SECRET_MARKER"), "structured event exposed a fixture secret")
        }
        require(event.occurredAt.isSome(), "delivered event lacks actual timestamp")
    }
}
func failed(action: () -> Unit): Unit {
    var didFail = false
    try { action() } catch (error: Exception) {
        didFail = true
        require(!error.toString().contains("M10_005_SECRET_MARKER"), "default exception exposed fixture secret")
    }
    require(didFail, "controlled failure unexpectedly succeeded")
}
func stageName(stage: OperationTimeoutStage): String {
    match (stage) {
        case OperationTimeoutStage.RequestAdmission => "request_admission"
        case OperationTimeoutStage.ConnectionPool => "connection_pool"
        case OperationTimeoutStage.Dns => "dns"
        case OperationTimeoutStage.TcpConnect => "tcp_connect"
        case OperationTimeoutStage.ProxyConnect => "proxy_connect"
        case OperationTimeoutStage.TlsHandshake => "tls_handshake"
        case OperationTimeoutStage.RequestWrite => "request_write"
        case OperationTimeoutStage.ResponseHeaders => "response_headers"
        case OperationTimeoutStage.BodyReadIdle => "body_read_idle"
        case OperationTimeoutStage.StreamReadIdle => "stream_read_idle"
    }
}
func timeoutEvidence(name: String, events: Array<NetworkEvent>, stage: OperationTimeoutStage): Unit {
    checkSecrecy(events)
    var matches: Int64 = 0
    for (event in events) {
        if (let Some(reason) <- event.timeoutReason) {
            match (reason) {
                case api.NetworkTimeoutReason.StageLimit =>
                    require(stageName(event.timeoutStage.getOrThrow()) == stageName(stage), "wrong deadline owner")
                    require(event.requestId.getOrThrow() > 0, "timeout lacks logical correlation")
                    matches++
                case _ => ()
            }
        }
    }
    require(matches > 0, "actual stage timeout cause was not observed")
    println("CHECK ${name} PASS")
    println("TIMEOUT ${name} stage=${stageName(stage)} reason=stage_limit matched=${matches}")
}
func correlation(h1: HttpClient, h2: HttpClient, h1Base: String, h2Base: String): Unit {
    let events = api.NetworkEventBuffer(capacity: 4096)
    let context = scope(Some<NetworkEventSink>(events)).withEventCorrelation(requestId: Some(177),
        attemptId: None<Int64>, connectionId: None<Int64>, streamId: None<Int64>)
    let retained = h1.get("${h1Base}/redirect", context: context)
    try {
        let snapshot = h1.observationSnapshot(observations: Some<api.NetworkEventStatistics>(events))
        require(snapshot.resources.activeRequests == 1 && snapshot.pools.leasedConnections == 1,
            "retained H1 response is absent from actual counters")
        require(snapshot.observations.getOrThrow().queuedEvents > 0, "sink counters were not sampled")
        let before = events.drain()
        checkSecrecy(before)
        var starts: Int64 = 0; var completions: Int64 = 0; var attemptCompletions: Int64 = 0
        var activeBodies: Int64 = 0
        let attempts = ArrayList<Int64>()
        for (event in before) {
            require(event.requestId == Some(177), "explicit logical ID changed")
            match (event.kind) {
                case NetworkEventKind.RequestStarted => starts++
                case NetworkEventKind.RequestCompleted => completions++
                case NetworkEventKind.AttemptStarted => attempts.add(event.attemptId.getOrThrow())
                case NetworkEventKind.AttemptCompleted => attemptCompletions++
                case NetworkEventKind.BodyStarted => activeBodies++
                case NetworkEventKind.BodyCompleted => activeBodies--
                case _ => ()
            }
        }
        require(starts == 1 && completions == 1 && attempts.size == 3 && attemptCompletions == 3,
            "retry/redirect duplicated logical request or omitted actual attempt")
        require(attempts[0] > 0 && attempts[1] > 0 && attempts[2] > 0 &&
            attempts[0] != attempts[1] && attempts[0] != attempts[2] && attempts[1] != attempts[2], "attempt IDs are not fresh")
        require(activeBodies == 1, "header completion prematurely completed retained body")
    } finally { consume(retained) }
    var endedBodies: Int64 = 0
    for (event in events.drain()) {
        match (event.kind) {
            case NetworkEventKind.RequestCompleted => throw Exception("body duplicated header completion")
            case NetworkEventKind.BodyCompleted => endedBodies++
            case _ => ()
        }
    }
    require(endedBodies == 1, "retained body did not end exactly once")
    clean(h1)
    println("CHECK logical_retry_redirect PASS")
    for ((client, base, protocol) in [(h1, h1Base, "h1"), (h2, h2Base, "h2")]) {
        let seenConnections = ArrayList<Int64>()
        let streams = ArrayList<Int64>()
        for (_ in 0..2) {
            let response = client.get("${base}/result", context: scope(Some<NetworkEventSink>(events)))
            try {
                if (protocol == "h2") { require(response.version == HttpVersion.Http2, "native ALPN did not negotiate H2") }
                let retainedSample = client.observationSnapshot(observations: Some<api.NetworkEventStatistics>(events))
                require(retainedSample.resources.activeRequests > 0, "retained request missing")
                println("SNAPSHOT "+protocol+" phase=retained requests="+retainedSample.resources.activeRequests.toString()+
                    " streams="+retainedSample.resources.activeStreams.toString()+" buffers="+retainedSample.resources.managedBufferBytes.toString()+
                    " queued="+retainedSample.observations.getOrThrow().queuedEvents.toString())
                for (event in events.drain()) {
                    match (event.kind) {
                        case NetworkEventKind.HttpConnectionAcquired => seenConnections.add(event.connectionId.getOrThrow())
                        case NetworkEventKind.Http2StreamOpened => streams.add(event.streamId.getOrThrow())
                        case _ => ()
                    }
                }
            } finally { consume(response) }
            clean(client)
            let reclaimed = client.observationSnapshot().resources
            println("SNAPSHOT "+protocol+" phase=reclaimed requests="+reclaimed.activeRequests.toString()+
                " streams="+reclaimed.activeStreams.toString()+" buffers="+reclaimed.managedBufferBytes.toString())
        }
        require(seenConnections.size == 2 && seenConnections[0] > 0 && seenConnections[0] == seenConnections[1],
            "physical connection identity changed on actual reuse")
        if (protocol == "h2") {
            require(streams.size == 2 && streams[0] > 0 && streams[1] > streams[0], "actual H2 stream IDs missing")
            println("STREAM h2 first=${streams[0]} second=${streams[1]}")
        }
        println("CHECK ${protocol}_reuse_resources PASS")
        println("IDENTITY ${protocol} connection=${seenConnections[0]} streams=${streams.size}")
    }
    checkSecrecy(events.drain())
}
func diagnostics(h1Base: String, h2Base: String, h2: HttpClient, tls: HttpClientTlsConfig,
    silentPort: UInt16, proxyPort: UInt16): Unit {
    let buffer = api.NetworkEventBuffer(capacity: 4096)
    let sink = Some<NetworkEventSink>(buffer)
    let cap = Some(100 * Duration.millisecond)
    let pooled = HttpClient.builder().resourceLimits(HttpResourceLimits(maximumConnections: 1,
        maximumConnectionsPerRoute: 1, maximumConnectionsPerOrigin: 1)).requestTimeout(5 * Duration.second).build()
    try {
        let held = pooled.get("${h1Base}/result")
        try {
            failed { => consume(pooled.get("${h1Base}/result", context: scope(sink,
                policy: OperationTimeoutPolicy(connectionPool: cap)))) }
            timeoutEvidence("pool_wait", buffer.drain(), OperationTimeoutStage.ConnectionPool)
        } finally { consume(held) }
        clean(pooled)
    } finally { pooled.close() }
    let dns = HttpClient.builder().resolver(SlowResolver()).requestTimeout(5 * Duration.second).build()
    try {
        require(dns.observationSnapshot().unavailableResolvers == 1 && dns.observationSnapshot().resolvers.isEmpty(),
            "custom resolver fabricated available zero counters")
        failed { => consume(dns.get("http://example.test:80/", context: scope(sink,
            policy: OperationTimeoutPolicy(dns: cap)))) }
        timeoutEvidence("dns_cap", buffer.drain(), OperationTimeoutStage.Dns)
        println("CHECK custom_resolver_unknown PASS")
    } finally { dns.close() }
    let silent = HttpClient.builder().tls(tls).requestTimeout(5 * Duration.second).build()
    try {
        failed { => consume(silent.get("https://127.0.0.1:${silentPort}/", context: scope(sink,
            policy: OperationTimeoutPolicy(tlsHandshake: cap)))) }
        timeoutEvidence("tls_cap", buffer.drain(), OperationTimeoutStage.TlsHandshake)
    } finally { silent.close() }
    let headers = HttpClient.builder().requestTimeout(5 * Duration.second).build()
    try {
        failed { => consume(headers.get("${h1Base}/slow-headers", context: scope(sink,
            policy: OperationTimeoutPolicy(responseHeaders: cap)))) }
        timeoutEvidence("headers_cap", buffer.drain(), OperationTimeoutStage.ResponseHeaders)
    } finally { headers.close() }
    failed { => consume(h2.send(HttpRequest(HttpMethod("POST"), HttpUrl.parse("${h2Base}/backpressure"),
        body: RequestBody.bytes(Array<Byte>(2 * 1024 * 1024, repeat: 65u8))), context: scope(sink,
        policy: OperationTimeoutPolicy(requestWrite: Some(200 * Duration.millisecond))))) }
    let flow = buffer.drain()
    timeoutEvidence("h2_backpressure", flow, OperationTimeoutStage.RequestWrite)
    var waits: Int64 = 0
    for (event in flow) {
        match (event.kind) { case NetworkEventKind.LocalBackpressureStarted => waits++; case _ => () }
    }
    require(waits > 0, "H2 diagnostic never actually waited for local send flow capacity")
    clean(h2)
    let proxy = HttpClient.builder().proxy(HttpProxyConfig(HttpProxyEndpoint.address(loopback(), proxyPort),
        StaticResolver(ResolveResult([loopback()], HostName("example.test"), ResolverSource.Static)),
        authorizationProvider: Some<HttpProxyAuthorizationProvider>(Authorization()))).tls(tls).build()
    try {
        failed { => consume(proxy.send(HttpRequest(HttpMethod("POST"),
            HttpUrl.parse("https://example.test:443/path?key=M10_005_SECRET_MARKER"),
            headers: HttpHeaders.builder().add("Cookie", "fixture=M10_005_SECRET_MARKER")
                .add("X-Fixture", "M10_005_SECRET_MARKER").build(), body: RequestBody.string("M10_005_SECRET_MARKER")),
            context: scope(sink))) }
        checkSecrecy(buffer.drain())
    } finally { proxy.close() }
    consume(h2.send(HttpRequest(HttpMethod("POST"), HttpUrl.parse("${h2Base}/secret?key=M10_005_SECRET_MARKER"),
        headers: HttpHeaders.builder().add("Cookie", "fixture=M10_005_SECRET_MARKER")
            .add("X-Fixture", "M10_005_SECRET_MARKER").build(), body: RequestBody.string("M10_005_SECRET_MARKER")),
        context: scope(sink)))
    failed { => consume(h2.get(h2Base.replace("example.test", "127.0.0.1")+"/secret", context: scope(sink))) }
    checkSecrecy(buffer.drain())
    println("CHECK secret_safe_proxy_tls PASS")
}
func measure(client: HttpClient, base: String, record!: Bool = true): Unit {
    let collector = Collector()
    let asyncSink = BoundedNetworkEventSink(collector, config: NetworkEventSinkConfig(capacity: 4096, batchSize: 64))
    let root = api.NetworkEventBuffer(capacity: 4096)
    try {
        for ((mode, sink) in [("disabled", None<NetworkEventSink>), ("root_buffer", Some<NetworkEventSink>(root)),
            ("async_exporter", Some<NetworkEventSink>(asyncSink))]) {
            for (_ in 0..12) { consume(client.get("${base}/result", context: scope(sink))) }
            let _ = root.drain()
            require(asyncSink.flush(scope(None<NetworkEventSink>)), "warmup exporter did not flush")
            let _ = collector.ring.drain()
            for (sample in 0..3) {
                let before = asyncSink.detailedSnapshot()
                let started = MonoTime.now()
                for (_ in 0..30) { consume(client.get("${base}/result", context: scope(sink))) }
                let elapsed = (MonoTime.now() - started).toNanoseconds()
                require(asyncSink.flush(scope(None<NetworkEventSink>)), "measured exporter did not flush")
                let after = asyncSink.detailedSnapshot()
                let rootEvents = root.drain(); let exported = collector.ring.drain()
                checkSecrecy(rootEvents); checkSecrecy(exported)
                let eventCount = if (mode == "root_buffer") { rootEvents.size } else if (mode == "async_exporter") {
                    after.exportedEvents - before.exportedEvents } else { 0 }
                let drops = if (mode == "root_buffer") { root.snapshot().droppedEvents } else if (mode == "async_exporter") {
                    asyncSink.snapshot().droppedEvents + collector.ring.snapshot().droppedEvents } else { 0 }
                if (record) { println("SAMPLE mode=${mode} index=${sample} duration_ns=${elapsed} requests=30 events=${eventCount} drops=${drops}") }
            }
        }
    } finally {
        require(asyncSink.close(scope(None<NetworkEventSink>)), "exporter close did not complete within real deadline")
    }
    require(!asyncSink.detailedSnapshot().workerRunning, "exporter retained worker after successful close")
    clean(client)
    if (record) { println("CHECK bounded_exporter_measurement PASS") }
}
main(args: Array<String>): Int64 {
    require(args.size == 5, "usage: observability certificate.der key.pk8 silent-port proxy-port refused-port")
    let certificate = File.readFrom(args[0]); let key = File.readFrom(args[1])
    let serverTls = HttpServerTlsConfig([certificate], key)
    let clientTls = HttpClientTlsConfig([certificate])
    let handler = Handler()
    let h1Server = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).build()
    let h2Server = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).tls(serverTls).build()
    let serve1 = spawn { h1Server.serve() }; let serve2 = spawn { h2Server.serve() }
    let h1 = HttpClient.builder().connector(RetryConnector(UInt16.parse(args[4])))
        .retryPolicy(HttpRetryPolicy(maximumAttempts: 2)).requestTimeout(5 * Duration.second).build()
    let resolver = StaticResolver(ResolveResult([loopback()], HostName("example.test"), ResolverSource.Static))
    let h2 = HttpClient.builder().resolver(resolver).tls(clientTls).requestTimeout(5 * Duration.second).build()
    let base1 = "http://127.0.0.1:${h1Server.localEndpoint.port}"
    let base2 = "https://example.test:${h2Server.localEndpoint.port}"
    try {
        correlation(h1, h2, base1, base2)
        diagnostics(base1, base2, h2, clientTls, UInt16.parse(args[2]), UInt16.parse(args[3]))
        // Warm both native protocols before sampling stable OS ownership.
        measure(h1, base1, record: false)
        for (_ in 0..100) { consume(h2.get("${base2}/result")) }
        for (_ in 0..20) { consume(h1.get("${base1}/result")); consume(h2.get("${base2}/result")) }
        sleep(Duration.second)
        println("MARK baseline"); getStdOut().flush(); sleep(Duration.second)
        measure(h1, base1)
        for (_ in 0..100) { consume(h2.get("${base2}/result")) }
        sleep(Duration.second)
        println("MARK after_load"); getStdOut().flush(); sleep(Duration.second)
    } finally {
        h1.close(); h2.close()
        let _ = h1Server.shutdown(context: scope(None<NetworkEventSink>))
        let _ = h2Server.shutdown(context: scope(None<NetworkEventSink>))
        serve1.get(5 * Duration.second); serve2.get(5 * Duration.second)
        h1Server.close(); h2Server.close(); serverTls.close(); clientTls.close()
    }
    println("CHECK native_shutdown PASS")
    println("M10_005_INSTALLED_OBSERVATION_PASS")
    0
}
