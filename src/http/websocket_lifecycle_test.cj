package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class WebSocketLifecycleTest {
    @TestCase
    func defaultReceiveAndQueuedReaderKeepHandshakeDeadline(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(
                deadline: Some(Deadline.after(Duration.second)), eventSink: Some<NetworkEventSink>(events)))
            try {
                let active = spawn { stoppedReceive(session, OperationContext.background()) }
                events.awaitRead()
                let queued = spawn { stoppedReceive(session, OperationContext.background()) }
                @Expect(active.get(3 * Duration.second))
                @Expect(queued.get(3 * Duration.second))
                @Expect(session.isClosed())
                @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func explicitFrameDeadlineCannotExtendSessionDeadline(): Unit {
        let fixture = WebSocketLifecycleFixture()
        try {
            let session = fixture.connect("/stall", OperationContext(deadline: Some(Deadline.after(Duration.second))))
            try {
                let result = spawn { stoppedReceive(session, OperationContext(
                    deadline: Some(Deadline.after(10 * Duration.second)))) }
                @Expect(result.get(3 * Duration.second))
                @Expect(session.isClosed())
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func parentCancellationStopsActiveAndQueuedDefaultReaders(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let source = api.CancellationSource()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(cancellation: source.token,
                eventSink: Some<NetworkEventSink>(events)))
            try {
                let active = spawn { stoppedReceive(session, OperationContext.background()) }
                events.awaitRead()
                let queued = spawn { stoppedReceive(session, OperationContext.background()) }
                source.cancel()
                @Expect(active.get(3 * Duration.second))
                @Expect(queued.get(3 * Duration.second))
                @Expect(session.isClosed())
                @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func perOperationCancellationStopsActiveReadAndReclaimsRequest(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let source = api.CancellationSource()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(eventSink: Some<NetworkEventSink>(events)))
            try {
                let active = spawn { stoppedReceive(session, OperationContext(cancellation: source.token)) }
                events.awaitRead()
                source.cancel()
                @Expect(active.get(3 * Duration.second))
                @Expect(session.isClosed())
                @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func preCancelledFrameCallsLeaveSessionReusable(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let source = api.CancellationSource()
        source.cancel()
        let stopped = OperationContext(cancellation: source.token)
        try {
            let session = fixture.connect("/echo", OperationContext.background())
            try {
                @Expect(stoppedReceive(session, stopped))
                @Expect(stoppedSend(session, WebSocketFrame(WebSocketOpcode.Binary, payload: [9u8]), stopped))
                @Expect(stoppedClose(session, stopped))
                let expired = OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
                @Expect(stoppedReceive(session, expired))
                @Expect(stoppedSend(session, WebSocketFrame(WebSocketOpcode.Binary), expired))
                @Expect(!session.isClosed())
                session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [7u8, 8u8]))
                @Expect(session.receive().payload, [7u8, 8u8])
                session.close(1000u16, "done")
                @Expect(session.isClosed())
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func repeatedImmediateCloseWakesActiveReadAndReclaimsRequest(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(eventSink: Some<NetworkEventSink>(events)))
            let active = spawn {
                try { let _ = session.receive(); false } catch (_: WebSocketException) { true }
            }
            events.awaitRead()
            session.close()
            session.close()
            @Expect(active.get(3 * Duration.second))
            @Expect(session.isClosed())
            @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
        } finally { fixture.close() }
    }

    @TestCase
    func inheritedReadIdleReportsRealCorrelationAndDeadlineOwner(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(eventSink: Some<NetworkEventSink>(events),
                timeoutPolicy: api.OperationTimeoutPolicy(streamReadIdle: Some(100 * Duration.millisecond))))
            try {
                @Expect(stoppedReceive(session, OperationContext.background()))
                let rows = events.snapshot()
                var physical = None<Int64>
                var attempt = None<Int64>
                var request = None<Int64>
                var timeoutSeen = false
                var starts: Int64 = 0
                var completions: Int64 = 0
                for (event in rows) {
                    match (event.kind) {
                        case NetworkEventKind.RequestStarted => starts++; request = event.requestId
                        case NetworkEventKind.RequestCompleted => completions++
                        case NetworkEventKind.AttemptStarted => attempt = event.attemptId
                        case NetworkEventKind.HttpConnectionAcquired => physical = event.connectionId
                        case _ => ()
                    }
                }
                @Expect(starts, 1)
                @Expect(completions, 1)
                @Expect(request.isSome() && attempt.isSome() && physical.isSome())
                for (event in rows) {
                    if (let Some(api.OperationTimeoutStage.StreamReadIdle) <- event.stage) {
                        @Expect(event.requestId, request)
                        @Expect(event.attemptId, attempt)
                        @Expect(event.connectionId, physical)
                        if (let Some(NetworkErrorCode.TimedOut) <- event.errorCode) {
                            @Expect(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.StageLimit) => true; case _ => false })
                            @Expect(match (event.timeoutStage) { case Some(api.OperationTimeoutStage.StreamReadIdle) => true; case _ => false })
                            timeoutSeen = true
                        }
                    }
                }
                @Expect(timeoutSeen)
                @Expect(session.isClosed())
                @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func http2ParentCancellationStopsBlockedSenderAndCloseWithoutClosingSibling(): Unit {
        let fixture = WebSocketLifecycleFixture(secure: true)
        let source = api.CancellationSource()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(cancellation: source.token,
                eventSink: Some<NetworkEventSink>(events)))
            try {
                let frame = WebSocketFrame(WebSocketOpcode.Binary, payload: Array<Byte>(1024 * 1024, repeat: 42u8))
                let sender = spawn { stoppedSend(session, frame, OperationContext.background()) }
                events.awaitBackpressure()
                let closer = spawn { stoppedClose(session, OperationContext.background()) }
                source.cancel()
                @Expect(sender.get(3 * Duration.second))
                @Expect(closer.get(3 * Duration.second))
                @Expect(session.isClosed())
                let sibling = fixture.client.get(fixture.httpBase + "/sibling")
                try { @Expect(sibling.status, 204); @Expect(sibling.version, HttpVersion.Http2) }
                finally { sibling.close() }
                @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
                var correlated = false
                for (event in events.snapshot()) {
                    if (let NetworkEventKind.LocalBackpressureStarted <- event.kind) {
                        @Expect(event.requestId.isSome() && event.attemptId.isSome() && event.connectionId.isSome())
                        @Expect(event.streamId.isSome())
                        correlated = true
                    }
                }
                @Expect(correlated)
            } finally { session.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func readersHaveOneBoundedWaiter(): Unit {
        let fixture = WebSocketLifecycleFixture()
        let source = api.CancellationSource()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(cancellation: source.token,
                eventSink: Some<NetworkEventSink>(events)))
            try { verifyBoundedWebSocketGate(session, source, events, false) }
            finally { session.close() }
            @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
        } finally { fixture.close() }
    }

    @TestCase
    func writersHaveOneBoundedWaiterAndPreserveHttp2Sibling(): Unit {
        let fixture = WebSocketLifecycleFixture(secure: true)
        let source = api.CancellationSource()
        let events = WebSocketLifecycleEvents()
        try {
            let session = fixture.connect("/stall", OperationContext(cancellation: source.token,
                eventSink: Some<NetworkEventSink>(events)))
            try { verifyBoundedWebSocketGate(session, source, events, true) }
            finally { session.close() }
            let sibling = fixture.client.get(fixture.httpBase + "/sibling")
            try { @Expect(sibling.status, 204); @Expect(sibling.version, HttpVersion.Http2) }
            finally { sibling.close() }
            @Expect(fixture.client.observationSnapshot().resources.activeRequests, 0)
        } finally { fixture.close() }
    }

    @TestCase
    func completedHeaderStageDoesNotBecomeSessionLifetime(): Unit {
        for (secure in [false, true]) {
            let fixture = WebSocketLifecycleFixture(secure: secure)
            try {
                let session = fixture.connect("/echo", OperationContext(
                    deadline: Some(Deadline.after(3 * Duration.second)),
                    timeoutPolicy: api.OperationTimeoutPolicy(responseHeaders: Some(100 * Duration.millisecond))))
                try {
                    sleep(200 * Duration.millisecond)
                    session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [4u8, 5u8]))
                    @Expect(session.receive().payload, [4u8, 5u8])
                    session.close(1000u16, "done")
                } finally { session.close() }
            } finally { fixture.close() }
        }
    }
}

private func stoppedReceive(session: WebSocketConnection, context: OperationContext): Bool {
    try { let _ = session.receive(context: context); false }
    catch (error: WebSocketException) {
        match (error.code) { case WebSocketErrorCode.ContextStopped => true; case _ => false }
    }
}
private func stoppedSend(session: WebSocketConnection, frame: WebSocketFrame, context: OperationContext): Bool {
    try { session.send(frame, context: context); false }
    catch (error: WebSocketException) {
        match (error.code) { case WebSocketErrorCode.ContextStopped => true; case _ => false }
    }
}
private func stoppedClose(session: WebSocketConnection, context: OperationContext): Bool {
    try { session.close(1000u16, "done", context: context); false }
    catch (error: WebSocketException) {
        match (error.code) { case WebSocketErrorCode.ContextStopped => true; case _ => false }
    }
}

private class WebSocketLifecycleEvents <: NetworkEventSink {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let rows = ArrayList<NetworkEvent>()
    private var readStarted = false
    private var backpressure = false
    public func emit(event: NetworkEvent): Unit {
        synchronized(mutex) {
            if (rows.size < 512) { rows.add(event) }
            match ((event.kind, event.stage)) {
                case (NetworkEventKind.StageStarted, Some(api.OperationTimeoutStage.StreamReadIdle)) => readStarted = true
                case (NetworkEventKind.LocalBackpressureStarted, _) => backpressure = true
                case _ => ()
            }
            changed.notifyAll()
        }
    }
    func snapshot(): Array<NetworkEvent> { synchronized(mutex) { rows.toArray() } }
    func awaitRead(): Unit { awaitEvent(false) }
    func awaitBackpressure(): Unit { awaitEvent(true) }
    private func awaitEvent(write: Bool): Unit {
        let deadline = Deadline.after(3 * Duration.second)
        synchronized(mutex) {
            while (!(if (write) { backpressure } else { readStarted })) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("WebSocket native operation did not reach its wait") }
                changed.wait(timeout: remaining)
            }
        }
    }
}

private class WebSocketLifecycleFixture <: Resource {
    let client: HttpClient
    let httpBase: String
    private let wsBase: String
    private let server: HttpServer
    private let serving: Future<Unit>
    private let handler = WebSocketLifecycleHandler()
    private let serverTls: HttpServerTlsConfig
    private let clientTls: HttpClientTlsConfig
    init(secure!: Bool = false) {
        let certificate = publicTlsTestCertificateDer()
        serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        clientTls = HttpClientTlsConfig([certificate])
        let builder = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(handler)
        if (secure) { builder.tls(serverTls) }
        server = builder.build()
        let instance = server
        serving = spawn { instance.serve() }
        let clients = HttpClient.builder().resolver(StaticResolver(ResolveResult(
            [server.localEndpoint.address], HostName("example.com"), ResolverSource.Static))).requestTimeout(5 * Duration.second)
        if (secure) { clients.tls(clientTls) }
        client = clients.build()
        httpBase = "${if (secure) { "https" } else { "http" }}://example.com:${server.localEndpoint.port}"
        wsBase = "${if (secure) { "wss" } else { "ws" }}://example.com:${server.localEndpoint.port}"
    }
    func connect(path: String, context: OperationContext): WebSocketConnection {
        match (client.connectWebSocket(WebSocketUrl.parse(wsBase + path), context: context)) {
            case WebSocketConnectResult.Connected(value) => value
            case WebSocketConnectResult.Rejected(response) => response.close(); throw Exception("native WebSocket rejected")
        }
    }
    public func close(): Unit {
        handler.release()
        client.close()
        let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
        serving.get(5 * Duration.second)
        serverTls.close()
        clientTls.close()
    }
    public func isClosed(): Bool { client.isClosed() }
}

private class WebSocketLifecycleHandler <: HttpServerHandler & WebSocketHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var released = false
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        if (request.target == "/sibling") { return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty())) }
        if (request.target == "/echo") { return HttpServerResponse.webSocket(request, WebSocketLifecycleEcho()) }
        HttpServerResponse.webSocket(request, this)
    }
    public func serve(_: WebSocketConnection, _: OperationContext): Unit {
        synchronized(mutex) { while (!released) { changed.wait() } }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}
private class WebSocketLifecycleEcho <: WebSocketHandler {
    public func serve(connection: WebSocketConnection, _: OperationContext): Unit {
        while (!connection.isClosed()) {
            let frame = connection.receive()
            match (frame.opcode) {
                case WebSocketOpcode.Close => return
                case WebSocketOpcode.Binary => connection.send(WebSocketFrame(WebSocketOpcode.Binary, payload: frame.payload))
                case _ => ()
            }
        }
    }
}

private func verifyBoundedWebSocketGate(session: WebSocketConnection, source: api.CancellationSource,
    events: WebSocketLifecycleEvents, writer: Bool): Unit {
    let active = spawn {
        if (writer) {
            stoppedSend(session, WebSocketFrame(WebSocketOpcode.Binary,
                payload: Array<Byte>(1024 * 1024, repeat: 42u8)), OperationContext.background())
        } else { stoppedReceive(session, OperationContext.background()) }
    }
    if (writer) { events.awaitBackpressure() } else { events.awaitRead() }
    let capacity = WebSocketCapacityResults()
    let callers = Array<Future<Int64>>(16, { _ => spawn {
        try {
            if (writer) { session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [7u8])) }
            else { let _ = session.receive() }
            2
        } catch (error: WebSocketException) {
            match (error.code) {
                case WebSocketErrorCode.CapacityExceeded => capacity.reject(); 1
                case WebSocketErrorCode.ContextStopped => 0
                case _ => 2
            }
        }
    } })
    try {
        capacity.awaitRejections(15)
        source.cancel()
        @Expect(active.get(3 * Duration.second))
        var rejected: Int64 = 0
        var stopped: Int64 = 0
        for (caller in callers) {
            match (caller.get(3 * Duration.second)) {
                case 1 => rejected++
                case 0 => stopped++
                case _ => @Expect(false)
            }
        }
        @Expect(rejected, 15)
        @Expect(stopped, 1)
    } finally { source.cancel() }
}

private class WebSocketCapacityResults {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var rejected: Int64 = 0
    func reject(): Unit { synchronized(mutex) { rejected++; changed.notifyAll() } }
    func awaitRejections(count: Int64): Unit {
        let deadline = Deadline.after(3 * Duration.second)
        synchronized(mutex) {
            while (rejected < count) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("WebSocket admission did not enforce its capacity") }
                changed.wait(timeout: remaining)
            }
        }
    }
}
