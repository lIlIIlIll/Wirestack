package wirestack_m11_003_websocket

import std.convert.*
import std.fs.File
import std.sync.*
import wirestack as api
import wirestack.http.*
import wirestack.net.TcpStream
// No reconnect or replay is performed. After disconnect, an application message may be lost or
// duplicated by application recovery; exactly-once delivery requires an application protocol.
// Ping/Pong proves protocol responsiveness, not business progress, and never extends the deadline.

func require(value: Bool, message: String): Unit { if (!value) { throw IllegalStateException(message) } }
func context(): OperationContext { OperationContext(deadline: Some(Deadline.after(15 * Duration.second))) }
func ipv4(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func ipv6(): IpAddress { let bytes = Array<Byte>(16, repeat: 0u8); bytes[15] = 1u8; IpAddress(IpAddressFamily.Ipv6, bytes) }
func resolver(host: String): StaticResolver { StaticResolver(ResolveResult([ipv4()], HostName(host), ResolverSource.Static)) }
func check(label: String): Unit { println("CHECK ${label} PASS") }
func opcode(value: WebSocketOpcode, expected: WebSocketOpcode): Bool {
    match ((value, expected)) {
        case (WebSocketOpcode.Binary, WebSocketOpcode.Binary) | (WebSocketOpcode.Continuation, WebSocketOpcode.Continuation) |
            (WebSocketOpcode.Ping, WebSocketOpcode.Ping) | (WebSocketOpcode.Pong, WebSocketOpcode.Pong) |
            (WebSocketOpcode.Close, WebSocketOpcode.Close) => true
        case _ => false
    }
}
func connected(result: WebSocketConnectResult): WebSocketConnection {
    match (result) {
        case WebSocketConnectResult.Connected(value) => value
        case WebSocketConnectResult.Rejected(response) => response.close(); throw IllegalStateException("unexpected handshake rejection")
    }
}
func closedResources(client: HttpClient): Unit {
    clean(client)
    let resources = client.resourceSnapshot()
    require(client.isClosed() && resources.activeConnections == 0 && resources.reservedConnections == 0, "closed client retained physical connections")
    require(resources.highWaterManagedBufferBytes <= resources.limits.maximumManagedBufferBytes, "client exceeded aggregate buffer ceiling before terminal rollback")
}
func clean(client: HttpClient): Unit {
    let end = Deadline.after(5 * Duration.second)
    while (true) {
        let state = client.observationSnapshot()
        if (state.resources.activeRequests == 0 && state.resources.activeStreams == 0 && state.resources.reservedStreams == 0 &&
            state.resources.managedBufferBytes == 0u64 && state.resources.admissionWaiters == 0 && state.pools.queuedRequests == 0) { return }
        require(!end.isExpired(), "session retained resource reservations or waiters"); sleep(Duration.millisecond)
    }
}
// Default-port probes retain the URL authority but map the native connection to an ephemeral fixture port.
class PortMap <: HttpConnector {
    let port: UInt16
    let calls = AtomicInt64(0)
    init(port: UInt16) { this.port = port }
    public func connect(endpoint: SocketEndpoint, owner: OperationContext): api.DuplexTransport {
        require(endpoint.port == 80u16 || endpoint.port == 443u16, "default URL port not used by route planner")
        calls.fetchAdd(1)
        TcpStream.connect(SocketEndpoint(endpoint.address, port), context: owner)
    }
}
class Fixture <: HttpServerHandler & WebSocketHandler {
    let requests = AtomicInt64(0)
    let served = AtomicInt64(0)
    let assertionFailures = AtomicInt64(0)
    let bulkStarted = AtomicBool(false)
    let bulkFinished = AtomicBool(false)
    let bulkSendingFrame = AtomicInt64(0)
    let bulkSentFrames = AtomicInt64(0)
    let holdEntered = AtomicBool(false)
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        require(!request.headers.contains("Proxy-Authorization"), "proxy credential reached origin")
        if (request.target == "/sibling") { request.body.close(); return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty())) }
        if (request.target == "/sibling-held") {
            request.body.close()
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(Array<Byte>(131072, repeat: b's')).open()),
                headers: HttpHeaders.builder().add("Content-Length", "131072").build()))
        }
        if (request.target == "/reject") {
            return HttpServerResponse(HttpResponse(403, "Forbidden", ResponseBody(RequestBody.string("denied").open()),
                headers: HttpHeaders.builder().add("Content-Length", "6").build()))
        }
        let expectedAuthority = request.headers.getFirst("X-Expected-Authority").getOrThrow()
        require(request.authority == expectedAuthority, "native Host/:authority differs from canonical WebSocket authority")
        if (request.version == HttpVersion.Http11) { require(request.headers.getFirst("Host") == Some(expectedAuthority), "native H1 Host differs") }
        else { require(request.version == HttpVersion.Http2 && request.protocol == Some("websocket"), "native H2 extended CONNECT missing") }
        if (let Some(expected) <- request.headers.getFirst("X-Expected-Version")) {
            require(if (expected == "h2") { request.version == HttpVersion.Http2 } else { request.version == HttpVersion.Http11 }, "native negotiated protocol differs")
        }
        require(request.target == request.headers.getFirst("X-Expected-Target").getOrThrow(), "native encoded target changed")
        requests.fetchAdd(1)
        let valid = HttpServerResponse.webSocket(request, this)
        let selected = HttpHeaders.builder()
        for (entry in valid.response.headers.entries) { selected.add(entry.name, entry.value) }
        selected.add("Sec-WebSocket-Protocol", "echo")
        HttpServerResponse(HttpResponse(valid.response.status, valid.response.reason, ResponseBody.empty(),
            headers: selected.build(), version: valid.response.version), duplexHandler: valid.duplexHandler)
    }
    public func serve(session: WebSocketConnection, owner: OperationContext): Unit {
        try {
            let command = session.receive(context: owner)
            require(opcode(command.opcode, WebSocketOpcode.Binary), "command opcode differs")
            let mode = String.fromUtf8(command.payload)
            if (mode == "abrupt") { session.close(); return }
            if (mode == "hold") {
                holdEntered.store(true)
                try { let _ = session.receive(context: owner) } catch (_: Exception) {}
                return
            }
            if (mode == "bulk") {
                bulkSendingFrame.store(0); bulkSentFrames.store(0); bulkStarted.store(true)
                let block = Array<Byte>(32768, repeat: b'b')
                for (_ in 0..256) {
                    bulkSendingFrame.fetchAdd(1)
                    session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: block), context: owner)
                    bulkSentFrames.fetchAdd(1)
                }
                bulkFinished.store(true)
            } else {
                session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [0u8, 255u8], finalFragment: false), context: owner)
                session.send(WebSocketFrame(WebSocketOpcode.Ping, payload: [17u8]), context: owner)
                let pong = session.receive(context: owner)
                require(opcode(pong.opcode, WebSocketOpcode.Pong) && pong.payload == [17u8], "automatic Pong missing")
                session.send(WebSocketFrame(WebSocketOpcode.Continuation, payload: [128u8]), context: owner)
            }
            let closing = session.receive(context: owner)
            require(opcode(closing.opcode, WebSocketOpcode.Close) && closing.payload == [3u8, 232u8, b'd', b'o', b'n', b'e', 195u8, 169u8],
                "closing handshake did not retain code 1000 and UTF-8 reason doneé")
        } catch (error: IllegalStateException) { assertionFailures.fetchAdd(1); throw error }
        finally { served.fetchAdd(1); session.close() }
    }
}
func headers(url: WebSocketUrl): HttpHeaders {
    HttpHeaders.builder().add("X-Expected-Authority", url.authority).add("X-Expected-Target", url.requestTarget).build()
}
func open(client: HttpClient, url: WebSocketUrl): WebSocketConnection {
    connected(client.connectWebSocket(url, protocols: ["echo"], headers: headers(url), context: context(),
        webSocketLimits: WebSocketLimits(maximumFrameBytes: 32768, maximumMessageBytes: 65536, ioBufferBytes: 1024)))
}
func exchange(client: HttpClient, url: WebSocketUrl, authority: String, target!: String = "/socket", version!: String = "h1"): Unit {
    require(url.authority == authority && url.requestTarget == target, "URL differs from independently authored wire expectation")
    let expected = HttpHeaders.builder().add("X-Expected-Authority", authority).add("X-Expected-Target", target).add("X-Expected-Version", version).build()
    let session = connected(client.connectWebSocket(url, protocols: ["echo"], headers: expected, context: context()))
    try {
        require(session.subProtocol == Some("echo"), "selected subprotocol differs")
        session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "echo".toArray()), context: context())
        let first = session.receive(context: context()); let ping = session.receive(context: context()); let last = session.receive(context: context())
        require(opcode(first.opcode, WebSocketOpcode.Binary) && !first.finalFragment && first.payload == [0u8, 255u8], "first fragment differs")
        require(opcode(ping.opcode, WebSocketOpcode.Ping) && ping.payload == [17u8], "interleaved Ping differs")
        require(opcode(last.opcode, WebSocketOpcode.Continuation) && last.finalFragment && last.payload == [128u8], "final fragment differs")
        session.close(1000u16, "doneé", context: context()); require(session.isClosed(), "graceful close not terminal")
    } finally { session.close() }
    clean(client)
}
func reject(client: HttpClient, base: String, consume: Bool): Unit {
    match (client.connectWebSocket(WebSocketUrl.parse("${base}/reject"), context: context())) {
        case WebSocketConnectResult.Connected(session) => session.close(); throw IllegalStateException("rejection became session")
        case WebSocketConnectResult.Rejected(response) =>
            try {
                require(response.status == 403, "rejection status differs")
                if (consume) {
                    let body = Array<Byte>(6, repeat: 0u8); let byte = Array<Byte>(1, repeat: 0u8); var count: Int64 = 0
                    while (count < 6) { require(response.body.read(byte) == 1, "rejection body truncated"); body[count] = byte[0]; count++ }
                    require(String.fromUtf8(body) == "denied" && response.body.read(byte) == 0, "rejection body changed")
                }
            } finally { response.close() }
    }
    clean(client)
}
func failures(client: HttpClient, base: String): Unit {
    let url = WebSocketUrl.parse("${base}/socket")
    for (name in ["Host", "Connection", "Upgrade", "Content-Length", "Transfer-Encoding", "Sec-WebSocket-Key", "Sec-WebSocket-Version", "Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions"]) {
        var failed = false
        try { let _ = client.connectWebSocket(url, headers: HttpHeaders.builder().add(name, "conflict").build(), context: context()) }
        catch (_: IllegalArgumentException) { failed = true }
        require(failed, "managed handshake field accepted"); clean(client)
    }
    var mismatch = false
    try { let _ = client.connectWebSocket(url, protocols: ["other"], headers: headers(url), context: context()) }
    catch (error: WebSocketException) { mismatch = match (error.code) { case WebSocketErrorCode.ProtocolViolation => true; case _ => false } }
    require(mismatch, "unoffered subprotocol not typed ProtocolViolation"); clean(client)
    let abrupt = open(client, url)
    try {
        abrupt.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "abrupt".toArray()), context: context())
        var stopped = false
        try { let _ = abrupt.receive(context: context()) }
        catch (error: WebSocketException) { stopped = match (error.code) { case WebSocketErrorCode.TransportFailure => true; case _ => false } }
        require(stopped && abrupt.isClosed(), "abrupt disconnect not terminal TransportFailure")
    } finally { abrupt.close() }
    clean(client)
}
func sibling(client: HttpClient, base: String): Unit {
    let response = client.get(base.replace("wss://", "https://") + "/sibling", context: context())
    try { require(response.status == 204 && response.version == HttpVersion.Http2, "H2 sibling affected by WebSocket") } finally { response.close() }
}
// Keep this existing sibling stream alive across WebSocket abort. Its body exceeds the stream
// window, so a destroyed shared connection cannot pass by opening a replacement connection.
func heldSibling(client: HttpClient, base: String): HttpResponse {
    let response = client.get(base.replace("wss://", "https://") + "/sibling-held", context: context())
    try {
        require(response.status == 200 && response.version == HttpVersion.Http2 && client.resourceSnapshot().activeConnections == 1, "held sibling did not share the existing H2 connection")
        response
    } catch (error: Exception) { response.close(); throw error }
}
func consumeHeldSibling(response: HttpResponse): Unit {
    let buffer = Array<Byte>(4096, repeat: 0u8); var received: Int64 = 0
    while (true) {
        let count = response.body.read(buffer); if (count == 0) { break }
        require(received + count <= 131072, "held sibling exceeded its declared body bound")
        for (index in 0..count) { require(buffer[index] == b's', "held sibling body changed after WebSocket abort") }
        received += count
    }
    require(received == 131072, "existing sibling stream was reset or truncated by WebSocket abort")
}
func boundedH2(client: HttpClient, base: String, fixture: Fixture): Unit {
    let session = open(client, WebSocketUrl.parse("${base}/socket"))
    try {
        var oversized = false
        try { session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: Array<Byte>(32769, repeat: b'x')), context: context()) }
        catch (error: WebSocketException) { oversized = match (error.code) { case WebSocketErrorCode.InvalidFrame => true; case _ => false } }
        require(oversized && !session.isClosed(), "frame-boundary rejection changed usable session ownership")
        session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "bulk".toArray()), context: context())
        let end = Deadline.after(5 * Duration.second)
        while (!fixture.bulkStarted.load()) { require(!end.isExpired(), "bulk sender did not start"); sleep(Duration.millisecond) }
        // Two complete 32-KiB frames exceed the stream window, including frame headers.
        // Observe the second native send in flight; prior streams may retain coalesced connection credit.
        while (fixture.bulkSendingFrame.load() < 2 || client.resourceSnapshot().managedBufferBytes < 32768u64) {
            require(!end.isExpired(), "second native send did not reach bounded unread DATA"); sleep(Duration.millisecond)
        }
        require(fixture.bulkSendingFrame.load() == 2 && fixture.bulkSentFrames.load() == 1 && !fixture.bulkFinished.load(),
            "unread H2 stream failed to block the second native frame send")
        let retained = client.resourceSnapshot().managedBufferBytes
        let capacity = client.resourceSnapshot().limits.maximumManagedBufferBytes
        require(retained > 0u64 && retained <= capacity && client.resourceSnapshot().activeConnections == 1, "slow consumer lacks bounded accounted DATA on one physical H2 connection")
        println("CAPACITY frame_limit=32768 retained=${retained} high_water=${client.resourceSnapshot().highWaterManagedBufferBytes} capacity=${capacity} connections=${client.resourceSnapshot().activeConnections}")
        sibling(client, base)
        let expected = Array<Byte>(32768, repeat: b'b')
        for (_ in 0..256) {
            let frame = session.receive(context: context())
            require(opcode(frame.opcode, WebSocketOpcode.Binary) && frame.payload == expected, "backpressured payload changed")
        }
        session.close(1000u16, "doneé", context: context())
    } finally { session.close() }
    clean(client); require(fixture.bulkFinished.load(), "sender never resumed after consumption")
    require(client.resourceSnapshot().highWaterManagedBufferBytes <= client.resourceSnapshot().limits.maximumManagedBufferBytes, "bulk consumption exceeded lifetime buffer high-water ceiling")
    check("h2_bounded_backpressure_sibling")
    fixture.bulkStarted.store(false); fixture.bulkFinished.store(false)
    let blocked = open(client, WebSocketUrl.parse("${base}/socket"))
    blocked.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "bulk".toArray()), context: context())
    let started = Deadline.after(5 * Duration.second)
    while (!fixture.bulkStarted.load()) { require(!started.isExpired(), "blocked sender barrier not reached"); sleep(Duration.millisecond) }
    while (fixture.bulkSendingFrame.load() < 2 || client.resourceSnapshot().managedBufferBytes < 32768u64) {
        require(!started.isExpired(), "blocked native send did not reach accounted unread DATA"); sleep(Duration.millisecond)
    }
    require(fixture.bulkSendingFrame.load() == 2 && fixture.bulkSentFrames.load() == 1 && !fixture.bulkFinished.load(),
        "second native frame send did not block before close")
    let surviving = heldSibling(client, base)
    try {
        blocked.close(); require(blocked.isClosed(), "close did not stop backpressured session")
        consumeHeldSibling(surviving)
    } finally { surviving.close(); blocked.close() }
    clean(client)
    check("h2_blocked_sender_close_rollback")
    for (_ in 0..4) {
        fixture.holdEntered.store(false)
        let source = CancellationSource()
        let raced = connected(client.connectWebSocket(WebSocketUrl.parse("${base}/socket"), protocols: ["echo"],
            headers: headers(WebSocketUrl.parse("${base}/socket")), context: OperationContext(cancellation: source.token, deadline: Some(Deadline.after(15 * Duration.second)))))
        raced.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "hold".toArray()), context: context())
        let end = Deadline.after(5 * Duration.second)
        while (!fixture.holdEntered.load()) { require(!end.isExpired(), "hold barrier not reached"); sleep(Duration.millisecond) }
        let survivingRace = heldSibling(client, base)
        let reading = spawn {
            try { let _ = raced.receive(context: context()); false }
            catch (error: WebSocketException) { match (error.code) {
                case WebSocketErrorCode.Closed | WebSocketErrorCode.ContextStopped | WebSocketErrorCode.TransportFailure => true
                case _ => false
            } }
        }
        try {
            let cancel = spawn { source.cancel() }; let close = spawn { raced.close() }
            cancel.get(5 * Duration.second); close.get(5 * Duration.second)
            require(reading.get(5 * Duration.second) && raced.isClosed(), "cancel/close race did not release reader")
            consumeHeldSibling(survivingRace)
        } finally { survivingRace.close(); raced.close() }
        clean(client)
    }
    check("h2_cancel_close_races_sibling")
}
class ProxyAuth <: HttpProxyAuthorizationProvider {
    public func authorization(_: HttpProxyEndpoint, _: HttpUrl, _: OperationContext): ?String { Some("Basic dGVzdDp0ZXN0") }
}
main(args: Array<String>): Int64 {
    require(args.size == 3, "usage: websocket certificate.der key.pk8 proxy-port")
    let cert = File.readFrom(args[0]); let key = File.readFrom(args[1]); let proxyPort = UInt16.parse(args[2])
    let serverTls = HttpServerTlsConfig([cert], key); let clientTls = HttpClientTlsConfig([cert]); let fixture = Fixture()
    let s1 = HttpServer.builder().listen(SocketEndpoint(ipv4(), 0u16)).handler(fixture).build()
    let s2 = HttpServer.builder().listen(SocketEndpoint(ipv4(), 0u16)).handler(fixture).tls(serverTls).build()
    let s6 = HttpServer.builder().listen(SocketEndpoint(ipv6(), 0u16)).handler(fixture).build()
    let s26 = HttpServer.builder().listen(SocketEndpoint(ipv6(), 0u16)).handler(fixture).tls(serverTls).build()
    let f1 = spawn { s1.serve() }; let f2 = spawn { s2.serve() }; let f6 = spawn { s6.serve() }
    let f26 = spawn { s26.serve() }
    let c1 = HttpClient.builder().resolver(resolver("example.test")).build()
    let small = HttpResourceLimits(maximumConnections: 1, maximumConnectionsPerRoute: 1, maximumConnectionsPerOrigin: 1,
        maximumManagedBufferBytes: 262144u64, reservedControlBufferBytes: 65536u64,
        maximumManagedBufferBytesPerRoute: 196608u64, maximumManagedBufferBytesPerOrigin: 196608u64)
    let c2 = HttpClient.builder().resolver(resolver("example.test")).tls(clientTls).resourceLimits(small).build()
    let direct = HttpClient.builder().build()
    let directTls = HttpClient.builder().tls(clientTls).build()
    let base1 = "ws://example.test:${s1.localEndpoint.port}"; let base2 = "wss://example.test:${s2.localEndpoint.port}"
    try {
        exchange(c1, WebSocketUrl.parse("${base1}/a%2Fb?q=%25&x=1"), "example.test:${s1.localEndpoint.port}", target: "/a%2Fb?q=%25&x=1"); check("ws_h1_host_target_fragments_ping")
        exchange(c2, WebSocketUrl.parse("${base2}/a%2Fb?q=%25&x=1"), "example.test:${s2.localEndpoint.port}", target: "/a%2Fb?q=%25&x=1", version: "h2"); check("wss_h2_authority_target_fragments_ping")
        exchange(direct, WebSocketUrl.parse("ws://127.0.0.1:${s1.localEndpoint.port}/socket"), "127.0.0.1:${s1.localEndpoint.port}")
        for (secure in [false, true]) {
            let mapping = PortMap(if (secure) { s2.localEndpoint.port } else { s1.localEndpoint.port })
            let builder = HttpClient.builder().resolver(resolver("example.test")).connector(mapping)
            if (secure) { builder.tls(clientTls) }
            let client = builder.build()
            try {
                let scheme = if (secure) { "wss" } else { "ws" }; let port = if (secure) { "443" } else { "80" }
                let version = if (secure) { "h2" } else { "h1" }
                exchange(client, WebSocketUrl.parse("${scheme}://EXAMPLE.test/socket"), "example.test", version: version)
                exchange(client, WebSocketUrl.parse("${scheme}://example.test:${port}/socket"), "example.test:${port}", version: version)
                require(mapping.calls.load() > 0, "default port probe skipped native connect")
                let before = mapping.calls.load()
                for (invalid in ["http://example.test/socket", "ws://user@example.test/socket", "wss://example.test/socket#fragment", "ws://example.test/%GG", "ws://[::1/socket", "ws://example.test:0/"]) {
                    var rejected = false
                    try { let _ = client.connectWebSocket(WebSocketUrl.parse(invalid), context: context()) }
                    catch (_: IllegalArgumentException) { rejected = true }
                    require(rejected && mapping.calls.load() == before, "invalid WebSocket URL performed native connection I/O")
                }
            } finally { client.close() }
        }
        check("native_explicit_default_ports")
        for ((client, base, label) in [(c1, base1, "h1"), (c2, base2, "h2")]) {
            reject(client, base, true); reject(client, base, false); check("${label}_rejection_consume_close")
            failures(client, base); check("${label}_managed_subprotocol_abrupt_rollback")
        }
        let mismatch = HttpClient.builder().resolver(resolver("mismatch.test")).tls(clientTls).build()
        try {
            var typed = false
            try { let _ = mismatch.connectWebSocket(WebSocketUrl.parse("wss://mismatch.test:${s2.localEndpoint.port}/socket"), context: context()) }
            catch (error: api.TlsEngineException) { typed = match (error.tlsCode) { case api.TlsEngineErrorCode.IdentityMismatch => true; case _ => false } }
            require(typed, "TLS identity mismatch not typed IdentityMismatch"); clean(mismatch)
        } finally { mismatch.close() }
        check("tls_canonical_identity_mismatch")
        let proxy = HttpProxyConfig(HttpProxyEndpoint.address(ipv4(), proxyPort), resolver("proxy.test"), authorizationProvider: Some(ProxyAuth()))
        let p1 = HttpClient.builder().resolver(resolver("example.test")).proxy(proxy).build()
        let p2 = HttpClient.builder().resolver(resolver("example.test")).proxy(proxy).tls(clientTls).build()
        try {
            exchange(p1, WebSocketUrl.parse("${base1}/proxy%2Fpath?q=%25"), "example.test:${s1.localEndpoint.port}", target: "/proxy%2Fpath?q=%25")
            exchange(p2, WebSocketUrl.parse("${base2}/proxy%2Fpath?q=%25"), "example.test:${s2.localEndpoint.port}", target: "/proxy%2Fpath?q=%25")
            exchange(p2, WebSocketUrl.parse("wss://127.0.0.1:${s2.localEndpoint.port}/socket"), "127.0.0.1:${s2.localEndpoint.port}")
            exchange(p2, WebSocketUrl.parse("wss://[::1]:${s26.localEndpoint.port}/socket"), "[::1]:${s26.localEndpoint.port}")
        }
        finally { p1.close(); p2.close(); closedResources(p1); closedResources(p2) }
        check("native_proxy_auth_isolation")
        boundedH2(c2, base2, fixture)
        exchange(direct, WebSocketUrl.parse("ws://[::1]:${s6.localEndpoint.port}/socket"), "[::1]:${s6.localEndpoint.port}"); check("native_ipv4_ipv6")
        exchange(directTls, WebSocketUrl.parse("wss://127.0.0.1:${s2.localEndpoint.port}/socket"), "127.0.0.1:${s2.localEndpoint.port}", version: "h2")
        exchange(directTls, WebSocketUrl.parse("wss://[::1]:${s26.localEndpoint.port}/socket"), "[::1]:${s26.localEndpoint.port}", version: "h2")
        check("native_wss_ip_san_no_dns_sni")
    } finally {
        c1.close(); c2.close(); direct.close()
        directTls.close(); closedResources(directTls)
        closedResources(c1); closedResources(c2); closedResources(direct)
        let r1 = s1.shutdown(context: context()); let r2 = s2.shutdown(context: context()); let r6 = s6.shutdown(context: context())
        let r26 = s26.shutdown(context: context()); require(r26.activeAtReturn == 0, "secure IPv6 server retained active owners")
        require(r1.activeAtReturn == 0 && r2.activeAtReturn == 0 && r6.activeAtReturn == 0, "native server retained active owners")
        f1.get(5 * Duration.second); f2.get(5 * Duration.second); f6.get(5 * Duration.second)
        f26.get(5 * Duration.second); s26.close()
        s1.close(); s2.close(); s6.close(); serverTls.close(); clientTls.close()
    }
    require(fixture.served.load() > 0, "no actual WebSocket handlers ran")
    require(fixture.assertionFailures.load() == 0, "native peer assertion failed, including close code/reason")
    check("native_shutdown_resource_rollback"); println("M11_003_INSTALLED_WEBSOCKET_PASS"); 0
}
