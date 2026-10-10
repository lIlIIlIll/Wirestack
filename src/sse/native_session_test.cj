package wirestack.sse

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.*
import wirestack.http.{HttpClient, HttpServer, HttpServerHandler, HttpServerRequest, HttpServerResponse, HttpResourceLimits}

@Test
class SseNativeSessionTest {
    @TestCase
    func reconnectDuplicatesParsedCursorButNeverAcknowledgesApplicationProcessing(): Unit {
        let fixture = NativeSseFixture()
        let events = NetworkEventBuffer(capacity: 256)
        let session = SseSession.eventSource(fixture.client, fixture.url("/duplicate"),
            policy: nativeSseFastPolicy(3), readBufferBytes: 1,
            context: OperationContext(eventSink: Some(events)))
        try {
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            let first = session.receive().getOrThrow()
            @Expect(first.data, "重复")
            @Expect(first.lastEventId, "7")
            @Expect(fixture.handler.duplicateRequests.load(), 1)
            @Expect(session.lastEventId, "7")
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes >= session.reservedBufferBytes)
            // Deliberately no application acknowledgement before reconnect.
            let duplicate = session.receive().getOrThrow()
            @Expect(duplicate.data, first.data)
            @Expect(duplicate.lastEventId, first.lastEventId)
            @Expect(fixture.handler.duplicateRequests.load(), 2)
            @Expect(fixture.handler.lastCursor, Some("7"))
            @Expect(session.receive().isNone())
            @Expect(session.receive().isNone())
            @Expect(session.reconnectCount, 2)
            @Expect(fixture.handler.duplicateRequests.load(), 3)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            @Expect(fixture.client.resourceSnapshot().activeRequests, 0)
            var attempts = ArrayList<Int64>()
            for (event in events.drain()) {
                match (event.kind) {
                    case NetworkEventKind.AttemptStarted =>
                        @Expect(event.requestId, Some(session.requestId))
                        let id = event.attemptId.getOrThrow()
                        for (previous in attempts) { @Expect(id != previous) }
                        attempts.add(id)
                    case _ => ()
                }
            }
            @Expect(attempts.size, 3)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func postIsNotReplayedOnEofOr307EvenWithExplicitRetrySafety(): Unit {
        let fixture = NativeSseFixture()
        try {
            let post = HttpRequest(HttpMethod("POST"), fixture.url("/post"),
                body: RequestBody.string("payload"),
                headers: HttpHeaders.builder().add("Content-Length", "7").build(),
                retrySafety: HttpRetrySafety.ExplicitlySafe)
            let session = SseSession.oneShot(fixture.client, post, policy: nativeSseFastPolicy(5))
            try {
                @Expect(session.receive().getOrThrow().data, "ack")
                @Expect(session.receive().isNone())
                @Expect(session.reconnectCount, 0)
                @Expect(fixture.handler.postRequests.load(), 1)
            } finally { session.close() }
            let redirect = SseSession.oneShot(fixture.client,
                HttpRequest(HttpMethod("POST"), fixture.url("/post307"),
                    body: RequestBody.string("payload"),
                    headers: HttpHeaders.builder().add("Content-Length", "7").build(),
                    retrySafety: HttpRetrySafety.ExplicitlySafe), policy: nativeSseFastPolicy(5))
            try { @Expect(nativeSseCode({ => let _ = redirect.receive() }), SseErrorCode.InvalidResponse) }
            finally { redirect.close() }
            @Expect(fixture.handler.redirectRequests.load(), 1)
            @Expect(fixture.handler.redirectTargets.load(), 0)
            @Expect(fixture.client.resourceSnapshot().activeRequests, 0)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
        } finally { fixture.close() }
    }

    @TestCase
    func explicitCloseParentCancellationAndEofRemainDistinct(): Unit {
        let fixture = NativeSseFixture()
        try {
            let local = SseSession.eventSource(fixture.client, fixture.url("/post"))
            local.close(); local.close()
            @Expect(nativeSseCode({ => let _ = local.receive() }), SseErrorCode.Closed)
            let source = CancellationSource()
            let cancelled = SseSession.eventSource(fixture.client, fixture.url("/post"),
                context: OperationContext(cancellation: source.token))
            source.cancel()
            @Expect(nativeSseCancelled({ => let _ = cancelled.receive() }))
            @Expect(fixture.handler.postRequests.load(), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func cancellationInterruptsBackoffWithoutAnotherSubmission(): Unit {
        let fixture = NativeSseFixture()
        let source = CancellationSource()
        let policy = SseSessionPolicy(maximumReconnects: 5, initialRetryDelay: Duration.second,
            minimumRetryDelay: Duration.second, maximumRetryDelay: Duration.second, jitterPermille: 0)
        let session = SseSession.eventSource(fixture.client, fixture.url("/eof"), policy: policy,
            context: OperationContext(cancellation: source.token))
        try {
            let receiving = spawn { nativeSseCancelled({ => let _ = session.receive() }) }
            nativeSseAwait({ => fixture.handler.eofRequests.load() == 1 &&
                fixture.client.resourceSnapshot().activeRequests == 0 })
            let started = MonoTime.now()
            source.cancel()
            @Expect(receiving.get(Duration.second))
            @Expect(MonoTime.now() - started < Duration.second)
            @Expect(fixture.handler.eofRequests.load(), 1)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            @Expect(fixture.client.resourceSnapshot().admissionWaiters, 0)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func parentAbsoluteDeadlineCapsBackoffAndDurationAcrossReconnects(): Unit {
        let fixture = NativeSseFixture()
        let policy = SseSessionPolicy(maximumReconnects: 5, maximumDuration: Duration.second,
            initialRetryDelay: Duration.second, minimumRetryDelay: Duration.second,
            maximumRetryDelay: Duration.second, jitterPermille: 0)
        let session = SseSession.eventSource(fixture.client, fixture.url("/eof"), policy: policy,
            context: OperationContext(deadline: Some(Deadline.after(100 * Duration.millisecond))))
        try {
            @Expect(nativeSseTimedOut({ => let _ = session.receive() }))
            @Expect(fixture.handler.eofRequests.load(), 1)
            @Expect(session.reconnectCount, 0)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func activeBodyIdleUsesCanonicalTimerButConsumerPauseDoesNot(): Unit {
        let fixture = NativeSseFixture()
        let session = SseSession.eventSource(fixture.client, fixture.url("/idle"),
            policy: SseSessionPolicy(bodyReadIdle: Some(50 * Duration.millisecond)), readBufferBytes: 1)
        try {
            @Expect(session.receive().getOrThrow().data, "first")
            sleep(100 * Duration.millisecond)
            @Expect(!session.isClosed())
            @Expect(fixture.client.resourceSnapshot().activeRequests, 1)
            let started = MonoTime.now()
            @Expect(nativeSseTimedOut({ => let _ = session.receive() }))
            @Expect(MonoTime.now() - started >= 30 * Duration.millisecond)
            @Expect(MonoTime.now() - started < Duration.second)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func noProgressAndInvalidMimeReleaseOwnedBodies(): Unit {
        let fixture = NativeSseFixture()
        let session = SseSession.eventSource(fixture.client, fixture.url("/comments"),
            limits: SseLimits(maximumLineBytes: 16, maximumEventBytes: 128,
                maximumBytesWithoutEvent: 24, maximumIdBytes: 8))
        try {
            @Expect(nativeSseCode({ => let _ = session.receive() }), SseErrorCode.NoProgress)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            @Expect(fixture.client.resourceSnapshot().activeRequests, 0)
            let bad = SseSession.eventSource(fixture.client, fixture.url("/mime"), policy: nativeSseFastPolicy(3))
            try { @Expect(nativeSseCode({ => let _ = bad.receive() }), SseErrorCode.InvalidResponse) }
            finally { bad.close() }
            let good = SseSession.eventSource(fixture.client, fixture.url("/post"))
            try { @Expect(good.receive().getOrThrow().data, "ack") }
            finally { good.close() }
            @Expect(fixture.handler.mimeRequests.load(), 1)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func reconnectStormStopsAtCountAndRetainsNoWaitOrBodyOwners(): Unit {
        let fixture = NativeSseFixture()
        let session = SseSession.eventSource(fixture.client, fixture.url("/eof"), policy: nativeSseFastPolicy(3))
        try {
            @Expect(nativeSseCode({ => let _ = session.receive() }), SseErrorCode.ReconnectLimit)
            @Expect(fixture.handler.eofRequests.load(), 4)
            @Expect(session.reconnectCount, 3)
            @Expect(fixture.client.resourceSnapshot().activeRequests, 0)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            @Expect(fixture.client.resourceSnapshot().admissionWaiters, 0)
        } finally { session.close(); fixture.close() }
    }

    @TestCase
    func unadmittableBufferFailsWithoutWaiterOrRequest(): Unit {
        let fixture = NativeSseFixture()
        try {
            let url = fixture.url("/post")
            let _ = @AssertThrows[IllegalArgumentException](
                fixture.client.reserveResponseBuffer(url, 0u64))
            let _ = @AssertThrows[IllegalArgumentException](
                fixture.client.reserveResponseBuffer(url, 0xffffffffffffffffu64))
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
            @Expect(fixture.client.resourceSnapshot().admissionWaiters, 0)
            @Expect(fixture.handler.postRequests.load(), 0)
        } finally { fixture.close() }
    }

    @TestCase
    func managedBufferAdmissionCancellationReleasesRealWaiterWithoutSending(): Unit {
        let resourceLimits = HttpResourceLimits(maximumConnections: 8, maximumConnectionsPerRoute: 8,
            maximumConnectionsPerOrigin: 8, maximumManagedBufferBytes: 8u64 * 1024u64 * 1024u64,
            maximumManagedBufferBytesPerRoute: 8u64 * 1024u64 * 1024u64,
            maximumManagedBufferBytesPerOrigin: 8u64 * 1024u64 * 1024u64)
        let fixture = NativeSseFixture(resourceLimits: resourceLimits)
        let url = fixture.url("/post")
        let lease = fixture.client.reserveResponseBuffer(url, 6u64 * 1024u64 * 1024u64)
        let source = CancellationSource()
        let session = SseSession.eventSource(fixture.client, url,
            context: OperationContext(cancellation: source.token))
        try {
            let receiving = spawn { nativeSseCancelled({ => let _ = session.receive() }) }
            nativeSseAwait({ => fixture.client.resourceSnapshot().admissionWaiters == 1 })
            source.cancel()
            @Expect(receiving.get(Duration.second))
            @Expect(fixture.client.resourceSnapshot().admissionWaiters, 0)
            @Expect(fixture.handler.postRequests.load(), 0)
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 6u64 * 1024u64 * 1024u64)
            lease.close(); lease.close()
            @Expect(fixture.client.resourceSnapshot().managedBufferBytes, 0u64)
        } finally { session.close(); lease.close(); fixture.close() }
    }
}

private func nativeSseFastPolicy(reconnects: Int64): SseSessionPolicy {
    SseSessionPolicy(maximumReconnects: reconnects, initialRetryDelay: 10 * Duration.millisecond,
        minimumRetryDelay: 10 * Duration.millisecond, maximumRetryDelay: 10 * Duration.millisecond,
        jitterPermille: 0)
}
private func nativeSseCode(action: () -> Unit): SseErrorCode {
    try { action(); @Fail("expected SSE failure"); SseErrorCode.Closed }
    catch (error: SseException) { error.code }
}
private func nativeSseCancelled(action: () -> Unit): Bool {
    try { action(); false } catch (error: NetworkException) {
        match (error.code) { case NetworkErrorCode.Cancelled => true; case _ => false }
    }
}
private func nativeSseTimedOut(action: () -> Unit): Bool {
    try { action(); false } catch (error: NetworkException) {
        match (error.code) { case NetworkErrorCode.TimedOut => true; case _ => false }
    }
}
private func nativeSseAwait(ready: () -> Bool): Unit {
    let end = MonoTime.now() + 2 * Duration.second
    while (!ready()) {
        if (MonoTime.now() >= end) { @Fail("native SSE fixture did not reach its expected state") }
        sleep(Duration.millisecond)
    }
}

private class NativeSseFixture <: Resource {
    let handler = NativeSseHandler()
    let client: HttpClient
    private let server: HttpServer
    private let serving: Future<Unit>
    init(resourceLimits!: HttpResourceLimits = HttpResourceLimits()) {
        server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(handler).build()
        let owner = server
        serving = spawn { owner.serve() }
        client = HttpClient.builder().resolver(StaticResolver(ResolveResult([server.localEndpoint.address],
            HostName("example.com"), ResolverSource.Static))).resourceLimits(resourceLimits).build()
        // A real response proves serve() started; close-only tests otherwise race startup.
        let ready = client.send(HttpRequest(HttpMethod("GET"), url("/fixture-ready")), context:
            OperationContext(deadline: Some(Deadline.after(2 * Duration.second))))
        ready.close()
    }
    func url(target: String): HttpUrl { HttpUrl.parse("http://example.com:${server.localEndpoint.port}${target}") }
    public func close(): Unit {
        handler.close(); client.close()
        if (!server.isClosed()) { let _ = server.shutdown(context: OperationContext(
            deadline: Some(Deadline.after(Duration.second)))) }
        serving.get(2 * Duration.second)
    }
    public func isClosed(): Bool { client.isClosed() }
}

private class NativeSseHandler <: HttpServerHandler {
    let duplicateRequests = AtomicInt64(0)
    let postRequests = AtomicInt64(0)
    let eofRequests = AtomicInt64(0)
    let mimeRequests = AtomicInt64(0)
    let redirectRequests = AtomicInt64(0)
    let redirectTargets = AtomicInt64(0)
    private let mutex = Mutex()
    private var writer: ?SseWriter = None<SseWriter>
    private var receivedCursor: ?String = None<String>
    prop lastCursor: ?String { get() { synchronized(mutex) { receivedCursor } } }
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = request.body.drain(1024)
        if (request.target == "/duplicate") {
            let count = duplicateRequests.fetchAdd(1) + 1
            synchronized(mutex) { receivedCursor = request.headers.getFirst("last-event-id") }
            if (count == 3) { return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty())) }
            return reply("id:7\ndata:重复\n\nid:unfinished\n")
        }
        if (request.target == "/post") { postRequests.fetchAdd(1); return reply("data:ack\n\n") }
        if (request.target == "/post307") {
            redirectRequests.fetchAdd(1)
            return reply("", status: 307, extra: HttpHeaders.builder().add("Location", "/post307-target").build())
        }
        if (request.target == "/post307-target") { redirectTargets.fetchAdd(1); return reply("data:replayed\n\n") }
        if (request.target == "/eof") { eofRequests.fetchAdd(1); return reply("") }
        if (request.target == "/mime") { mimeRequests.fetchAdd(1); return reply("not-sse", mime: "text/plain") }
        if (request.target == "/comments") { return reply(":x\n:x\n:x\n:x\n:x\n:x\n:x\n:x\n:x\n:x\n") }
        if (request.target == "/idle") {
            let value = SseWriter(context: context)
            value.write(SseEvent("first"))
            synchronized(mutex) { writer = Some(value) }
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(value),
                headers: HttpHeaders.builder().add("Content-Type", "text/event-stream")
                    .add("Transfer-Encoding", "chunked").build()))
        }
        reply("", status: 404)
    }
    private func reply(data: String, status!: Int64 = 200, mime!: String = "text/event-stream",
        extra!: HttpHeaders = HttpHeaders()): HttpServerResponse {
        let bytes = data.toArray()
        let headers = HttpHeaders.builder().add("Content-Type", mime).add("Content-Length", bytes.size.toString())
        for (entry in extra.entries) { headers.add(entry.name, entry.value) }
        HttpServerResponse(HttpResponse(status, "fixture", ResponseBody(RequestBody.bytes(bytes).open()), headers: headers.build()))
    }
    func close(): Unit { if (let Some(value) <- synchronized(mutex) { writer }) { value.close() } }
}
