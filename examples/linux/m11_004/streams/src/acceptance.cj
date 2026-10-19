package wirestack_m11_004_streams

import std.sync.*
import wirestack as api
import wirestack.http.*
import wirestack.sse.*

func check(label: String): Unit { println("CHECK streams_${label} PASS") }
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func clean(client: HttpClient): Unit {
    let end = Deadline.after(5 * Duration.second)
    while (true) {
        let s = client.observationSnapshot()
        if (s.resources.activeRequests == 0 && s.resources.activeStreams == 0 && s.resources.reservedStreams == 0 &&
            s.resources.managedBufferBytes == 0u64 && s.resources.admissionWaiters == 0 && s.pools.queuedRequests == 0) { return }
        require(!end.isExpired()); sleep(Duration.millisecond)
    }
}
class StreamFixture <: HttpServerHandler & WebSocketHandler {
    let posts = AtomicInt64(0)
    let reconnects = AtomicInt64(0)
    let cursorSeen = AtomicBool(false)
    let producers = AtomicInt64(0)
    let bulkSent = AtomicInt64(0)
    let wsCommands = AtomicInt64(0)
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        if (request.target == "/socket") { return HttpServerResponse.webSocket(request, this) }
        let bodyBuffer = Array<Byte>(64, repeat: 0u8)
        var requestBytes: Int64 = 0
        try {
            while (true) { let count = request.body.read(bodyBuffer); if (count == 0) { break }; requestBytes += count; require(requestBytes <= 65536) }
        } finally { request.body.close() }
        if (request.target == "/sibling") {
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(Array<Byte>(131072, repeat: b's')).open()),
                headers: HttpHeaders.builder().add("Content-Length", "131072").build()))
        }
        let target = request.target
        if (target == "/post") { posts.fetchAdd(1) }
        if (target == "/recover") {
            let attempt = reconnects.fetchAdd(1)
            if (attempt > 0) { cursorSeen.store(request.headers.getFirst("Last-Event-ID") == Some("cursor-1")) }
            if (attempt == 2) { return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty())) }
        }
        let writer = SseWriter(maximumBufferBytes: 4096, context: context)
        producers.fetchAdd(1)
        spawn {
            try {
                writer.write(SseEvent("event", lastEventId: "cursor-1")); writer.flush()
                if (target == "/post" || target == "/recover") { writer.close(); return }
                if (target == "/hold") {
                    while (!writer.isClosed() && !context.isDeadlineExceeded() && !context.isCancellationRequested()) {
                        writer.comment("heartbeat"); writer.flush(); sleep(10 * Duration.millisecond)
                    }
                    return
                }
                if (target == "/bulk") {
                    let data = String.fromUtf8(Array<Byte>(1024, repeat: b'b'))
                    for (_ in 0..256) { writer.write(SseEvent(data)); writer.flush(); bulkSent.fetchAdd(1) }
                }
                writer.complete()
            } catch (_: Exception) { writer.close() }
            finally { producers.fetchSub(1) }
        }
        let headers = HttpHeaders.builder().add("Content-Type", "text/event-stream")
        if (target == "/post" || target == "/recover") { headers.add("Transfer-Encoding", "chunked") }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(writer), headers: headers.build()))
    }
    public func serve(session: WebSocketConnection, context: OperationContext): Unit {
        try {
            let command = String.fromUtf8(session.receive(context: context).payload)
            if (command == "disconnect") { wsCommands.fetchAdd(1); return }
            if (command == "hold") { let _ = session.receive(context: context); return }
            session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "reply".toArray()), context: context)
            let _ = session.receive(context: context)
        } finally { session.close() }
    }
}
func heldSibling(client: HttpClient, base: String): HttpResponse {
    let response = client.get(base + "/sibling", context: owner())
    try { require(response.version == HttpVersion.Http2 && client.resourceSnapshot().activeConnections == 1); response }
    catch (error: Exception) { response.close(); throw error }
}
func drainSibling(response: HttpResponse): Unit {
    let buffer = Array<Byte>(4096, repeat: 0u8); var received: Int64 = 0
    while (true) {
        let count = response.body.read(buffer); if (count == 0) { break }
        require(received + count <= 131072)
        for (index in 0..count) { require(buffer[index] == b's') }
        received += count
    }
    require(received == 131072)
}
func stoppedSse(client: HttpClient, base: String, deadline: Bool): Unit {
    let cancel = CancellationSource(); let context = owner(ms: if (deadline) { 300 } else { 10000 }).withCancellation(cancel.token)
    let session = sseOpen(client, base + "/hold", false, 0, context)
    try {
        require(session.receive().isSome())
        let pending = spawn {
            try { let _ = session.receive(); false }
            catch (error: api.NetworkException) {
                match (error.code) {
                    case api.NetworkErrorCode.Cancelled => !deadline && context.isCancellationRequested()
                    case api.NetworkErrorCode.TimedOut => deadline && context.isDeadlineExceeded()
                    case _ => false
                }
            }
        }
        if (!deadline) { cancel.cancel() }
        require(pending.get(3 * Duration.second) && session.isClosed())
    } finally { session.close() }
    clean(client)
}
func stoppedWs(client: HttpClient, url: String, deadline: Bool): Unit {
    let cancel = CancellationSource(); let context = owner(ms: if (deadline) { 300 } else { 10000 }).withCancellation(cancel.token)
    let session = wsOpen(client, url, context)
    try {
        session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: "hold".toArray()), context: context)
        let pending = spawn {
            try { let _ = session.receive(context: context); false }
            catch (error: WebSocketException) { match (error.code) {
                case WebSocketErrorCode.ContextStopped => if (deadline) { context.isDeadlineExceeded() } else { context.isCancellationRequested() }
                case WebSocketErrorCode.Closed => !deadline && context.isCancellationRequested()
                case _ => false
            } }
        }
        if (!deadline) { cancel.cancel() }
        require(pending.get(3 * Duration.second))
    } finally { session.close() }
    clean(client)
}
func selfCheck(certPath: String, keyPath: String, untrustedPath: String): Unit {
    let cert = boundedFile(certPath); let key = boundedFile(keyPath); let untrusted = boundedFile(untrustedPath)
    let fixture = StreamFixture()
    let server1 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(fixture).build()
    let server2 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(fixture).tls(HttpServerTlsConfig([cert], key)).build()
    let serving1 = spawn { server1.serve() }; let serving2 = spawn { server2.serve() }
    let resolver = StaticResolver(ResolveResult([loopback()], HostName("example.test"), ResolverSource.Static))
    let limits = HttpResourceLimits(maximumConnections: 1, maximumConnectionsPerRoute: 1, maximumConnectionsPerOrigin: 1,
        maximumManagedBufferBytes: 262144u64, reservedControlBufferBytes: 65536u64,
        maximumManagedBufferBytesPerRoute: 196608u64, maximumManagedBufferBytesPerOrigin: 196608u64)
    let h1 = HttpClient.builder().retryPolicy(HttpRetryPolicy(maximumAttempts: 3)).build()
    let h2 = HttpClient.builder().resolver(resolver).tls(HttpClientTlsConfig([cert])).resourceLimits(limits).build()
    let base1 = "http://127.0.0.1:${server1.localEndpoint.port}"; let base2 = "https://example.test:${server2.localEndpoint.port}"
    let ws1 = "ws://127.0.0.1:${server1.localEndpoint.port}/socket"; let ws2 = "wss://example.test:${server2.localEndpoint.port}/socket"
    try {
        for ((client, base, socket) in [(h1, base1, ws1), (h2, base2, ws2)]) {
            require(consumeSse(client, base + "/stream", false, 0, 3, owner())[0] == 1)
            require(consumeWebSocket(client, socket, 1, 0, "echo", owner())[0] == 1); clean(client)
        }
        check("success")
        let recover = sseOpen(h1, base1 + "/recover", false, 2, owner())
        try {
            let first = recover.receive().getOrThrow(); require(recover.lastEventId == "cursor-1")
            let duplicate = recover.receive().getOrThrow(); require(first.data == duplicate.data && first.lastEventId == duplicate.lastEventId)
            require(recover.receive().isNone() && recover.reconnectCount == 2 && fixture.cursorSeen.load() && fixture.reconnects.load() == 3)
            require(recover.lastFailure.isSome())
        } finally { recover.close() }
        check("cursor_duplicate_explicit_recover")
        // Adversarial opt-in belongs only to acceptance. The operational POST retains default retry safety.
        let post = SseSession.oneShot(h1, HttpRequest.post(base1 + "/post", RequestBody.string("submit"))
            .withHeaders(HttpHeaders.builder().add("Content-Length", "6").build()).withRetrySafety(HttpRetrySafety.ExplicitlySafe),
            limits: codec(), policy: policy(2), readBufferBytes: 1024, context: owner())
        var peerFailed = false
        try {
            require(post.receive().isSome())
            try { let _ = post.receive() }
            catch (error: api.NetworkException) { peerFailed = match (error.code) {
                case api.NetworkErrorCode.UnexpectedEof | api.NetworkErrorCode.ConnectionReset => true
                case _ => false
            } }
            catch (error: SseException) {
                require(error.code == SseErrorCode.ReconnectLimit)
                peerFailed = match (error.cause.getOrThrow()) {
                    case value: api.NetworkException => match (value.code) {
                        case api.NetworkErrorCode.UnexpectedEof | api.NetworkErrorCode.ConnectionReset => true
                        case _ => false
                    }
                    case _ => false
                }
            }
            println("POST submissions=${fixture.posts.load()} recoveries=${post.reconnectCount} peer_failure=${if (peerFailed) { 1 } else { 0 }}")
            require(peerFailed && post.reconnectCount == 0 && fixture.posts.load() == 1)
        } finally { post.close() }
        require(consumeSse(h1, base1 + "/stream", false, 0, 1, owner())[0] == 1)
        require(consumeWebSocket(h1, ws1, 1, 1, "disconnect", owner()) == (1, 1) && fixture.wsCommands.load() == 1)
        check("peer_disconnect"); check("post_exactly_once_after_peer_failure")
        for ((client, base, socket) in [(h1, base1, ws1), (h2, base2, ws2)]) {
            stoppedSse(client, base, false); stoppedWs(client, socket, false)
        }
        check("active_cancel")
        stoppedSse(h2, base2, true); stoppedWs(h2, ws2, true); check("deadline")
        let cancel = CancellationSource(); cancel.cancel(); let context = owner().withCancellation(cancel.token)
        var preSse = false; let pre = sseOpen(h1, base1 + "/stream", false, 0, context)
        try { let _ = pre.receive() } catch (error: api.NetworkException) { preSse = match (error.code) { case api.NetworkErrorCode.Cancelled => true; case _ => false } }
        finally { pre.close() }
        var preWs = false
        try { let value = wsOpen(h1, ws1, context); value.close() }
        catch (error: api.NetworkException) { preWs = match (error.code) { case api.NetworkErrorCode.Cancelled => true; case _ => false } }
        require(preSse && preWs); check("pre_cancel")
        let bulkCancel = CancellationSource()
        let bulk = sseOpen(h2, base2 + "/bulk", false, 0, owner().withCancellation(bulkCancel.token))
        try {
            require(bulk.receive().isSome()); let end = Deadline.after(5 * Duration.second)
            while (h2.resourceSnapshot().managedBufferBytes < bulk.reservedBufferBytes + 32768u64) { require(!end.isExpired()); sleep(Duration.millisecond) }
            let snapshot = h2.resourceSnapshot()
            require(snapshot.managedBufferBytes > bulk.reservedBufferBytes && snapshot.managedBufferBytes <= snapshot.limits.maximumManagedBufferBytes && fixture.bulkSent.load() < 256)
            println("CAPACITY retained=${snapshot.managedBufferBytes} high_water=${snapshot.highWaterManagedBufferBytes} capacity=${snapshot.limits.maximumManagedBufferBytes}")
            let sibling = heldSibling(h2, base2)
            try { bulkCancel.cancel(); require(bulk.isClosed()); drainSibling(sibling); require(h2.resourceSnapshot().activeConnections == 1) }
            finally { sibling.close() }
            require(bulk.isClosed())
        } finally { bulk.close() }
        clean(h2); check("bounded_slow_consumer_h2_sibling")
        let explicit = sseOpen(h1, base1 + "/hold", false, 0, owner())
        try { require(explicit.receive().isSome()); explicit.close(); require(explicit.isClosed()) } finally { explicit.close() }
        clean(h1)
        let tiny = HttpClient.builder().resourceLimits(limits).build()
        try {
            let session = SseSession.eventSource(tiny, HttpUrl.parse(base1 + "/stream"), context: owner()); var capacity = false
            try { let _ = session.receive() } catch (_: IllegalArgumentException) { capacity = true }
            finally { session.close() }
            require(capacity && tiny.resourceSnapshot().managedBufferBytes == 0u64); clean(tiny)
        } finally { tiny.close() }
        let limited = wsOpen(h2, ws2, owner())
        try {
            var rejected = false
            try { limited.send(WebSocketFrame(WebSocketOpcode.Binary, payload: Array<Byte>(32769, repeat: b'x')), context: owner()) }
            catch (error: WebSocketException) { rejected = match (error.code) { case WebSocketErrorCode.InvalidFrame => true; case _ => false } }
            require(rejected && !limited.isClosed())
        } finally { limited.close() }
        require(limited.isClosed()); check("explicit_close")
        clean(h2); check("capacity")
        let badTrust = HttpClient.builder().resolver(resolver).tls(HttpClientTlsConfig([untrusted])).build()
        try {
            var rejected = false
            try { let session = wsOpen(badTrust, ws2, owner()); session.close() }
            catch (error: api.TlsEngineException) { rejected = match (error.tlsCode) { case api.TlsEngineErrorCode.CertificateUntrusted => true; case _ => false } }
            require(rejected); clean(badTrust)
        } finally { badTrust.close() }
        check("untrusted_chain")
    } finally {
        h1.close(); h2.close(); clean(h1); clean(h2)
        let closedEnd = Deadline.after(3 * Duration.second)
        while (h1.resourceSnapshot().activeConnections != 0 || h2.resourceSnapshot().activeConnections != 0) { require(!closedEnd.isExpired()); sleep(Duration.millisecond) }
        let stop1 = server1.shutdown(context: owner()); let stop2 = server2.shutdown(context: owner())
        println("CLEANUP active_h1=${stop1.activeAtReturn} active_h2=${stop2.activeAtReturn} producers=${fixture.producers.load()}")
        require(stop1.activeAtReturn == 0 && stop2.activeAtReturn == 0)
        serving1.get(5 * Duration.second); serving2.get(5 * Duration.second)
        let end = Deadline.after(3 * Duration.second)
        while (fixture.producers.load() != 0) { require(!end.isExpired()); sleep(Duration.millisecond) }
    }
    check("cleanup"); println("APP_ACCEPTANCE_PASS")
}
