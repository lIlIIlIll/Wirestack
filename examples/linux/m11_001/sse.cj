package wirestack_m11_001_sse

import std.fs.File
import std.sync.*
import wirestack as api
import wirestack.http.*
import wirestack.sse.*

func require(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func context(events!: ?NetworkEventSink = None<NetworkEventSink>): OperationContext {
    OperationContext(deadline: Some(Deadline.after(10 * Duration.second)), eventSink: events)
}
func policy(): SseSessionPolicy {
    SseSessionPolicy(maximumReconnects: 2, initialRetryDelay: 50 * Duration.millisecond,
        minimumRetryDelay: 50 * Duration.millisecond, jitterPermille: 0)
}
class Handler <: HttpServerHandler {
    let requests = AtomicInt64(0)
    let reconnects = AtomicInt64(0)
    let posts = AtomicInt64(0)
    let redirects = AtomicInt64(0)
    let destinations = AtomicInt64(0)
    let flushed = AtomicInt64(0)
    let producers = AtomicInt64(0)
    let releaseSibling = AtomicBool(false)
    let sawCursor = AtomicBool(false)
    /** Serves bounded native SSE fixtures through public HTTP body ownership.
     * @param request Incoming request, counted before any fixture work.
     * @param owner Server operation lifetime shared by the streaming writer.
     */
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        require(requests.fetchAdd(1) < 30, "fixture request bound exceeded")
        if (request.target == "/stop") {
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        if (request.target == "/bad") {
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Content-Type", "application/json").build()))
        }
        if (request.target == "/post-redirect") {
            redirects.fetchAdd(1)
            return HttpServerResponse(HttpResponse(307, "Temporary Redirect", ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Location", "/destination").build()))
        }
        if (request.target == "/destination") { destinations.fetchAdd(1) }
        if (request.target == "/post") { posts.fetchAdd(1) }
        let bytes = Array<Byte>(64, repeat: 0u8)
        while (request.body.read(bytes) != 0) {}
        var attempt: Int64 = 0
        if (request.target == "/reconnect") {
            attempt = reconnects.fetchAdd(1)
            if (attempt > 0) {
                sawCursor.store(request.headers.getFirst("Last-Event-ID") == Some("cursor-1"))
            }
            if (attempt == 2) {
                return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
            }
        }
        let writer = SseWriter(maximumBufferBytes: 128, context: owner)
        producers.fetchAdd(1)
        let target = request.target
        spawn {
            try {
                writer.comment("heartbeat\ncomment")
                if (target == "/reconnect") {
                    writer.write(SseEvent("duplicate", lastEventId: "cursor-1"), retryMilliseconds: Some(0u64))
                } else {
                    writer.write(SseEvent("你好\n世界", eventType: "update", lastEventId: "unicode-1"),
                        retryMilliseconds: Some(50u64))
                }
                // Flush waits for HTTP body-reader consumption, not peer delivery.
                writer.flush(); flushed.fetchAdd(1)
                if (target == "/reconnect") { writer.close() }
                if (target == "/hold" || target == "/sibling") {
                    while (!releaseSibling.load() && !writer.isClosed() && !owner.isDeadlineExceeded()) {
                        sleep(Duration.millisecond)
                    }
                    if (target == "/sibling") { writer.write(SseEvent("sibling-alive")) }
                } else if (target != "/reconnect") {
                    writer.write(SseEvent("[DONE]")); writer.write(SseEvent("after-marker"))
                }
                writer.flush(); writer.complete()
            } catch (_: Exception) { writer.close() }
            finally { producers.fetchSub(1) }
        }
        let headers = HttpHeaders.builder().add("Content-Type", "text/event-stream; charset=utf-8")
        if (target == "/reconnect") { headers.add("Transfer-Encoding", "chunked") }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(writer),
            headers: headers.build()))
    }
}
func clean(client: HttpClient, name: String): Unit {
    let limit = Deadline.after(3 * Duration.second)
    while (true) {
        let sample = client.observationSnapshot()
        let row = sample.resources
        if (row.activeRequests == 0 && row.activeStreams == 0 && row.reservedStreams == 0 &&
            row.managedBufferBytes == 0u64 && row.admissionWaiters == 0 && sample.pools.queuedRequests == 0) {
            println("RESOURCE ${name} buffers=${row.managedBufferBytes} requests=${row.activeRequests} streams=${row.activeStreams} admission_waiters=${row.admissionWaiters} pool_waiters=${sample.pools.queuedRequests}")
            return
        }
        require(!limit.isExpired(), "terminal resources not reclaimed")
        sleep(5 * Duration.millisecond)
    }
}
func stream(client: HttpClient, base: String): Unit {
    let session = SseSession.eventSource(client, HttpUrl.parse("${base}/stream"), readBufferBytes: 1, context: context())
    try {
        let event = session.receive().getOrThrow()
        require(event.data == "你好\n世界" && event.eventType == "update" && event.lastEventId == "unicode-1", "unicode multiline event differs")
        let sample = client.observationSnapshot().resources
        require(sample.managedBufferBytes >= session.reservedBufferBytes && sample.managedBufferBytes > 0u64,
            "active session has no real buffer reservation")
        println("RESOURCE active buffers=${sample.managedBufferBytes} session_reservation=${session.reservedBufferBytes}")
        require(session.receive().getOrThrow().data == "[DONE]", "literal marker lost")
        require(session.receive().getOrThrow().data == "after-marker", "literal marker terminated session")
        require(session.receive().isNone(), "complete stream did not reach EOF")
    } finally { session.close() }
    clean(client, "stream")
    println("CHECK writer_unicode_literal PASS")
}
func cancel(client: HttpClient, base: String): Unit {
    let source = CancellationSource()
    let session = SseSession.eventSource(client, HttpUrl.parse("${base}/hold"),
        context: context().withCancellation(source.token))
    let _ = session.receive().getOrThrow()
    let pending = spawn {
        try { let _ = session.receive(); false }
        catch (error: api.NetworkException) {
            match (error.code) { case api.NetworkErrorCode.Cancelled => true; case _ => false }
        }
    }
    sleep(50 * Duration.millisecond); source.cancel()
    require(pending.get(2 * Duration.second), "pending receive did not report typed cancellation")
    require(session.isClosed(), "parent cancellation did not close session")
    session.close(); clean(client, "cancel")
}
func connection(events: api.NetworkEventBuffer, requestId: Int64, h2!: Bool = false): Int64 {
    var result: Int64 = 0
    var streamId: Int64 = 0
    for (event in events.drain()) {
        if (event.requestId == Some(requestId)) {
            match (event.kind) {
                case NetworkEventKind.HttpConnectionAcquired => result = event.connectionId.getOrThrow()
                case NetworkEventKind.Http2StreamOpened => streamId = event.streamId.getOrThrow()
                case _ => ()
            }
        }
    }
    require(result > 0, "missing physical connection event")
    if (h2) { require(streamId > 0, "missing actual H2 stream event") }
    println("EVENT request_id=${requestId} connection_id=${result} stream_id=${streamId}")
    result
}
func scopes(h1: HttpClient, h2: HttpClient, base1: String, base2: String, handler: Handler): Unit {
    let firstEvents = api.NetworkEventBuffer(capacity: 1024)
    let first = SseSession.eventSource(h1, HttpUrl.parse("${base1}/hold"), context: context(events: Some(firstEvents)))
    let _ = first.receive().getOrThrow()
    let old = connection(firstEvents, first.requestId)
    first.close()
    let next = SseSession.eventSource(h1, HttpUrl.parse("${base1}/stream"), context: context(events: Some(firstEvents)))
    let _ = next.receive().getOrThrow()
    let fresh = connection(firstEvents, next.requestId)
    require(old != fresh, "unread H1 connection was reused")
    next.close(); clean(h1, "h1-close")
    println("CONNECTION h1 old=${old} replacement=${fresh}")
    println("CHECK h1_unread_close PASS")
    let aEvents = api.NetworkEventBuffer(capacity: 1024)
    let bEvents = api.NetworkEventBuffer(capacity: 1024)
    let a = SseSession.eventSource(h2, HttpUrl.parse("${base2}/hold"), context: context(events: Some(aEvents)))
    let b = SseSession.eventSource(h2, HttpUrl.parse("${base2}/sibling"), context: context(events: Some(bEvents)))
    let _ = a.receive().getOrThrow(); let _ = b.receive().getOrThrow()
    let aId = connection(aEvents, a.requestId, h2: true); let bId = connection(bEvents, b.requestId, h2: true)
    require(aId == bId, "H2 siblings used different physical connections")
    a.close(); handler.releaseSibling.store(true)
    require(b.receive().getOrThrow().data == "sibling-alive", "H2 close killed sibling")
    require(b.receive().isNone(), "sibling EOF missing"); b.close(); clean(h2, "h2-close")
    println("CONNECTION h2 closed=${aId} surviving=${bId}")
    println("CHECK h2_sibling_close PASS")
}
func reconnect(client: HttpClient, base: String, handler: Handler): Unit {
    let session = SseSession.eventSource(client, HttpUrl.parse("${base}/reconnect"), policy: policy(), context: context())
    let first = session.receive().getOrThrow()
    // Deliberately do not process or acknowledge first. The dispatched block already
    // committed the cursor.
    require(session.lastEventId == "cursor-1", "cursor did not advance before application acknowledgement")
    let duplicate = session.receive().getOrThrow()
    require(first.data == duplicate.data && first.lastEventId == duplicate.lastEventId,
        "fixture did not demonstrate duplicate delivery")
    require(session.lastFailure.isSome(), "truncated response did not retain a disconnect failure")
    require(session.receive().isNone() && session.reconnectCount == 2 && handler.sawCursor.load(),
        "GET reconnect cursor or 204 stop differs")
    require(handler.reconnects.load() == 3, "GET request bound differs")
    session.close(); clean(client, "reconnect")
    println("CURSOR parsed=cursor-1 acknowledged=false duplicate=true last_event_id_received=${handler.sawCursor.load()} submissions=${handler.reconnects.load()}")
    println("CHECK reconnect_duplicate_cursor PASS")
}
func terminals(client: HttpClient, base: String, handler: Handler): Unit {
    let stopped = SseSession.eventSource(client, HttpUrl.parse("${base}/stop"), policy: policy(), context: context())
    require(stopped.receive().isNone() && stopped.reconnectCount == 0, "204 resubmitted")
    let bad = SseSession.eventSource(client, HttpUrl.parse("${base}/bad"), policy: policy(), context: context())
    var rejected = false
    try { let _ = bad.receive() } catch (error: SseException) { rejected = error.code == SseErrorCode.InvalidResponse }
    require(rejected && bad.isClosed() && bad.reconnectCount == 0, "bad MIME was not terminal")
    for (path in ["post", "post-redirect"]) {
        let request = HttpRequest.post("${base}/${path}", RequestBody.string("replayable"))
            .withHeaders(HttpHeaders.builder().add("Content-Length", "10").build())
            .withRetrySafety(HttpRetrySafety.ExplicitlySafe)
        let session = SseSession.oneShot(client, request, policy: policy(), context: context())
        if (path == "post") {
            while (session.receive().isSome()) {}
        } else {
            var failed = false
            try { let _ = session.receive() } catch (error: SseException) { failed = error.code == SseErrorCode.InvalidResponse }
            require(failed, "307 should be terminal, not followed")
        }
        require(session.reconnectCount == 0, "one-shot POST reconnected"); session.close()
    }
    require(handler.posts.load() == 1 && handler.redirects.load() == 1 && handler.destinations.load() == 0,
        "POST was replayed or redirected")
    clean(client, "terminal")
    println("POST eof_submissions=${handler.posts.load()} redirect_submissions=${handler.redirects.load()} destination_submissions=${handler.destinations.load()}")
    println("CHECK terminal_and_post_no_replay PASS")
}
main(args: Array<String>): Int64 {
    require(args.size == 2, "usage: sse certificate.der key.pk8")
    let cert = File.readFrom(args[0]); let key = File.readFrom(args[1])
    let serverTls = HttpServerTlsConfig([cert], key); let clientTls = HttpClientTlsConfig([cert])
    let handler = Handler()
    let server1 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).build()
    let server2 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).tls(serverTls).build()
    let serve1 = spawn { server1.serve() }; let serve2 = spawn { server2.serve() }
    let h1 = HttpClient.builder().requestTimeout(10 * Duration.second).retryPolicy(HttpRetryPolicy(maximumAttempts: 3)).build()
    let resolver = StaticResolver(ResolveResult([loopback()], HostName("example.test"), ResolverSource.Static))
    let h2 = HttpClient.builder().resolver(resolver).tls(clientTls).requestTimeout(10 * Duration.second).build()
    let base1 = "http://127.0.0.1:${server1.localEndpoint.port}"
    let base2 = "https://example.test:${server2.localEndpoint.port}"
    try {
        stream(h1, base1)
        cancel(h1, base1)
        scopes(h1, h2, base1, base2, handler)
        reconnect(h1, base1, handler)
        terminals(h1, base1, handler)
        // A new session recovers after the earlier request-scoped close.
        stream(h1, base1)
        println("CHECK cancel_then_new_request PASS")
        require(handler.flushed.load() > 0, "server never completed explicit flush")
    } finally {
        handler.releaseSibling.store(true); h1.close(); h2.close()
        let _ = server1.shutdown(context: context()); let _ = server2.shutdown(context: context())
        serve1.get(5 * Duration.second); serve2.get(5 * Duration.second)
        server1.close(); server2.close(); serverTls.close(); clientTls.close()
    }
    require(handler.producers.load() == 0, "server producer survived shutdown")
    println("SERVER requests=${handler.requests.load()} flushed=${handler.flushed.load()} producers=${handler.producers.load()}")
    println("CHECK native_shutdown PASS")
    println("M11_001_INSTALLED_SSE_PASS")
    0
}
