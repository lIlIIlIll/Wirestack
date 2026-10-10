package wirestack.internal.http2

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2ObservabilityTest {
    @TestCase
    func independentStreamsRetainCorrelationAndThrowingReentrantHookCannotChangeBodies(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 65536)
        let server = Http2ServerConnection(serverTransport, ObservationHandler())
        let serving = spawn { server.serve() }
        let client = Http2ClientConnection.connect(clientTransport)
        let sink = ReentrantH2Sink(client)
        let pending = ArrayList<Future<Int64>>()
        try {
            for (index in 0..4) {
                let id = index + 1
                pending.add(spawn {
                    let response = client.execute(HttpRequest.get("https://example.test/secret-marker"),
                        context: OperationContext(eventSink: Some<NetworkEventSink>(sink),
                            requestId: Some(id), attemptId: Some(id + 100), connectionId: Some(900)))
                    try {
                        let bytes = Array<Byte>(16, repeat: 0u8)
                        var count: Int64 = 0
                        while (true) {
                            let next = response.body.read(bytes)
                            if (next == 0) { break }
                            count += next
                        }
                        count
                    } finally { response.close() }
                })
            }
            for (request in pending) { @Expect(request.get(5 * Duration.second), 7) }
            @Expect(client.ownedStreamCount, 0)
            @Expect(client.metrics().resetListeners, 0)
            @Expect(client.metrics().pendingFlowPermits, 0)
            let events = sink.events.drain()
            let streams = HashSet<Int64>()
            var opened: Int64 = 0
            var closed: Int64 = 0
            var bodies: Int64 = 0
            var ended: Int64 = 0
            for (event in events) {
                @Expect(event.connectionId.getOrThrow(), 900)
                @Expect(event.requestId.isSome())
                @Expect(event.attemptId.getOrThrow(), event.requestId.getOrThrow() + 100)
                @Expect(event.streamId.isSome())
                match (event.kind) {
                    case NetworkEventKind.Http2StreamOpened =>
                        opened += 1
                        let _ = streams.add(event.streamId.getOrThrow())
                    case NetworkEventKind.Http2StreamClosed => closed += 1
                    case NetworkEventKind.BodyStarted => bodies += 1
                    case NetworkEventKind.BodyCompleted => ended += 1
                    case _ => ()
                }
            }
            @Expect(opened, 4); @Expect(closed, 4)
            @Expect(bodies, 4); @Expect(ended, 4); @Expect(streams.size, 4)
        } finally {
            client.abort(); server.abort()
            try { serving.get(5 * Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func actualActiveBodyWaitReportsTimeoutAndCancellation(): Unit {
        for (cancel in [false, true]) {
            let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 65536)
            let body = HeldObservationBody()
            let server = Http2ServerConnection(serverTransport, HeldObservationHandler(body))
            let serving = spawn { server.serve() }
            let client = Http2ClientConnection.connect(clientTransport)
            let events = api.NetworkEventBuffer(capacity: 64)
            let cancellation = CancellationSource()
            let context = OperationContext(eventSink: Some<NetworkEventSink>(events),
                cancellation: cancellation.token,
                timeoutPolicy: OperationTimeoutPolicy(bodyReadIdle: Some(30 * Duration.millisecond)),
                connectionId: Some(901), requestId: Some(1), attemptId: Some(2))
            let response = client.execute(HttpRequest.get("https://example.test/held"), context: context)
            try {
                for (event in events.drain()) {
                    @Expect(match (event.stage) {
                        case Some(OperationTimeoutStage.BodyReadIdle) => false
                        case _ => true
                    })
                }
                if (cancel) { let _ = cancellation.cancel() }
                let error = @AssertThrows[NetworkException](response.body.read(Array<Byte>(1, repeat: 0u8)))
                @Expect(match (error.code) {
                    case NetworkErrorCode.Cancelled => cancel
                    case NetworkErrorCode.TimedOut => !cancel
                    case _ => false
                })
                response.close()
                @Expect(client.ownedStreamCount, 0)
                @Expect(client.metrics().pendingFlowPermits, 0)
                var failedRead = false
                for (event in events.drain()) {
                    if (match (event.kind) { case NetworkEventKind.StageCompleted => true; case _ => false }) {
                        if (match (event.stage) { case Some(OperationTimeoutStage.BodyReadIdle) => true; case _ => false }) {
                            failedRead = true
                            @Expect(event.errorCode.isSome())
                            if (!cancel) { @Expect(event.timeoutReason.isSome()) }
                        }
                    }
                }
                @Expect(failedRead)
            } finally {
                body.release(); response.close(); client.abort(); server.abort()
                try { serving.get(5 * Duration.second) } catch (_: Exception) {}
            }
        }
    }
    @TestCase
    func realZeroWindowWaitHasDistinctLocalBackpressureEvidence(): Unit {
        let flow = Http2FlowController()
        flow.applyPeerSettings(Http2SettingsUpdate(
            Http2SettingsSnapshot(4096u32, true, 100u32, 0u32, 16384u32, 65536u32),
            -65535, http2SettingsAck()))
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let sink = ReentrantFlowSink(flow)
        let context = OperationContext(eventSink: Some<NetworkEventSink>(sink), connectionId: Some(904),
            streamId: Some(1), timeoutPolicy: OperationTimeoutPolicy(requestWrite: Some(20 * Duration.millisecond)))
            .forStage(OperationTimeoutStage.RequestWrite)
        let error = @AssertThrows[NetworkException](flow.reserveSend(id, 1, context: context))
        @Expect(match (error.code) { case NetworkErrorCode.TimedOut => true; case _ => false })
        @Expect(flow.pendingPermitCount, 0)
        let events = sink.events.drain()
        @Expect(events.size, 2)
        @Expect(match (events[0].kind) { case NetworkEventKind.LocalBackpressureStarted => true; case _ => false })
        @Expect(match (events[1].kind) { case NetworkEventKind.LocalBackpressureCompleted => true; case _ => false })
        @Expect(events[1].timeoutReason.isSome())
        let _ = flow.closeStream(id)
        flow.close()
    }
    @TestCase
    func settingsShrinkReportsBlockedAdmittedPermitAndReleasesCreditOnTimeout(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let sink = ReentrantFlowSink(flow)
        let context = OperationContext(eventSink: Some<NetworkEventSink>(sink), connectionId: Some(905),
            streamId: Some(1), timeoutPolicy: OperationTimeoutPolicy(requestWrite: Some(20 * Duration.millisecond)))
            .forStage(OperationTimeoutStage.RequestWrite)
        let permit = flow.reserveSend(id, 1, context: context)
        flow.applyPeerSettings(Http2SettingsUpdate(
            Http2SettingsSnapshot(4096u32, true, 100u32, 0u32, 16384u32, 65536u32),
            -65535, http2SettingsAck()))
        @AssertThrows[NetworkException](permit.beginSend(context: context))
        @Expect(flow.pendingPermitCount, 0)
        @Expect(flow.snapshot(id).reservedSendBytes, 0)
        let events = sink.events.drain()
        @Expect(events.size, 2)
        @Expect(match (events[0].kind) { case NetworkEventKind.LocalBackpressureStarted => true; case _ => false })
        @Expect(match (events[1].kind) { case NetworkEventKind.LocalBackpressureCompleted => true; case _ => false })
        @Expect(events[1].timeoutReason.isSome())
        let _ = flow.closeStream(id)
        flow.close()
    }
}

private class ObservationHandler <: Http2ServerHandler {
    public func handle(_: Http2ServerRequest, _: OperationContext): Http2ServerResponse {
        Http2ServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("payload").open())))
    }
}

private class ReentrantH2Sink <: NetworkEventSink {
    let events = api.NetworkEventBuffer(capacity: 256)
    private let connection: Http2ClientConnection
    init(connection: Http2ClientConnection) { this.connection = connection }
    public func emit(event: NetworkEvent): Unit {
        let _ = connection.metrics()
        let _ = connection.ownedStreamCount
        events.emit(event)
        throw Exception("hook fixture failure")
    }
}

private class HeldObservationHandler <: Http2ServerHandler {
    private let body: HeldObservationBody
    init(body: HeldObservationBody) { this.body = body }
    public func handle(_: Http2ServerRequest, _: OperationContext): Http2ServerResponse {
        Http2ServerResponse(HttpResponse(200, "OK", ResponseBody(body)))
    }
}

private class HeldObservationBody <: HttpBodyStream {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var released = false
    private var closed = false
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(_: Array<Byte>): Int64 {
        synchronized(mutex) {
            while (!released && !closed) { changed.wait() }
        }
        0
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
    public func close(): Unit { synchronized(mutex) { closed = true; changed.notifyAll() } }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private class ReentrantFlowSink <: NetworkEventSink {
    let events = api.NetworkEventBuffer(capacity: 8)
    private let flow: Http2FlowController
    init(flow: Http2FlowController) { this.flow = flow }
    public func emit(event: NetworkEvent): Unit {
        let _ = flow.pendingPermitCount
        events.emit(event)
        throw Exception("flow hook fixture failure")
    }
}
