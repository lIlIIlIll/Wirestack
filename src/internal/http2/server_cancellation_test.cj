package wirestack.internal.http2

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*
import wirestack.internal as internal

@Test
class Http2ServerCancellationTest {
    @TestCase
    func cancellationCompletionWaitsForActualExchangeReclamation(): Unit {
        let owner = internal.HttpResourceOwnerKey("https://example.test:443", "direct")
        let budget = cancellationTestBudget()
        let requestLease = budget.tryAcquireRequest(owner).getOrThrow()
        let streamLease = budget.tryAcquireStream(owner).getOrThrow()
        streamLease.activate()
        let flow = Http2FlowController(resourceBudget: Some(budget), resourceOwner: Some(owner))
        let registry = Http2StreamRegistry(Http2ConnectionRole.Server)
        let (outbound, inbound) = MemoryTransport.pair(capacity: 65536)
        let control = GatedCancellationControl(outbound)
        let measurement = Http2ServerCancellationMeasurement(budget)
        let exchange = Http2ServerExchange.open(Http2StreamId(1u32), [
            HpackHeaderField(":method", "POST"), HpackHeaderField(":scheme", "https"),
            HpackHeaderField(":authority", "example.test"), HpackHeaderField(":path", "/held")
        ], false, registry, flow, control,
            onCancellationRequested: { => measurement.requested() },
            onOwnerTerminated: { => requestLease.close(); streamLease.close(); measurement.complete() })
        let parser = Http2FrameParser(Http2Limits(), Some(budget), Some(owner))
        let received = parser.feed(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(4u32, Http2FrameType.Data, Http2Flags(), Http2StreamId(1u32)),
            [1u8, 2u8, 3u8, 4u8])))
        exchange.acceptData(received[0])
        @Expect(budget.snapshot().managedBufferBytes, 4u64)
        @Expect(budget.snapshot().completedCancellations, 0)
        let cancelling = spawn { exchange.streamReset(Http2StreamResetEvent(
            Http2StreamId(1u32), Http2ErrorCode.Cancel, "peer stream cancellation", true)) }
        try {
            control.awaitCleanup()
            let held = budget.snapshot()
            @Expect(held.managedBufferBytes, 0u64)
            @Expect(held.activeRequests, 1)
            @Expect(held.activeStreams, 1)
            @Expect(held.completedCancellations, 0)
            @Expect(held.lastCancellationCompletionLatency.isNone())
            sleep(5 * Duration.millisecond)
            control.release()
            cancelling.get(5 * Duration.second)
            let reclaimed = budget.snapshot()
            @Expect(reclaimed.activeRequests, 0)
            @Expect(reclaimed.activeStreams, 0)
            @Expect(reclaimed.reservedStreams, 0)
            @Expect(reclaimed.managedBufferBytes, 0u64)
            @Expect(reclaimed.completedCancellations, 1)
            @Expect(reclaimed.lastCancellationCompletionLatency.getOrThrow() >= 5 * Duration.millisecond)
            exchange.completeOwner()
            @Expect(budget.snapshot().completedCancellations, 1)
            let bytes = Array<Byte>(13, repeat: 0u8)
            readExact(inbound, MutableByteSpan(bytes))
            @Expect(Http2FrameParser().feed(bytes).size, 1)
        } finally {
            control.release(); outbound.abort(); inbound.abort()
            try { cancelling.get(5 * Duration.second) } catch (_: Exception) {}
            exchange.completeOwner(); flow.close()
        }
    }

    @TestCase
    func productionServerMeasuresPublicLinkedAndPeerCancellationButNotOrdinaryCompletion(): Unit {
        for (mode in [0, 1, 2]) {
            let owner = internal.HttpResourceOwnerKey("https://example.test:443", "direct")
            let budget = cancellationTestBudget()
            let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 65536)
            let handler = HeldCancellationHandler()
            let parent = CancellationSource()
            let clientCancellation = CancellationSource()
            let server = Http2ServerConnection(serverTransport, handler,
                resourceBudget: Some(budget), resourceOwner: Some(owner))
            let serving = spawn { server.serve(context: OperationContext(cancellation: parent.token)) }
            let client = Http2ClientConnection.connect(clientTransport)
            let requesting = spawn {
                try {
                    let response = client.execute(HttpRequest(HttpMethod("POST"),
                        HttpUrl.parse("https://example.test/held"),
                        body: RequestBody.bytes(Array<Byte>(1024, repeat: b'x'))),
                        context: OperationContext(cancellation: clientCancellation.token))
                    response.close()
                    false
                } catch (_: Exception) { true }
            }
            try {
                let request = handler.awaitRequest()
                let limit = Deadline.after(5 * Duration.second)
                while (budget.snapshot().managedBufferBytes < 1024u64) {
                    if (limit.isExpired()) { throw Exception("server did not retain request DATA") }
                    sleep(Duration.millisecond)
                }
                @Expect(budget.snapshot().completedCancellations, 0)
                @Expect(budget.snapshot().lastCancellationCompletionLatency.isNone())
                if (mode == 1) { let _ = parent.cancel() }
                else if (mode == 2) { let _ = clientCancellation.cancel() }
                else { request.cancelStream() }
                @Expect(requesting.get(5 * Duration.second))
                let completionLimit = Deadline.after(5 * Duration.second)
                while (budget.snapshot().completedCancellations == 0) {
                    if (completionLimit.isExpired()) { throw Exception("server did not reclaim cancelled exchange") }
                    sleep(Duration.millisecond)
                }
                let reclaimed = budget.snapshot()
                @Expect(reclaimed.activeRequests, 0)
                @Expect(reclaimed.activeStreams, 0)
                @Expect(reclaimed.completedCancellations, 1)
                @Expect(reclaimed.lastCancellationCompletionLatency.isSome())
                request.cancelStream()
                @Expect(budget.snapshot().completedCancellations, 1)
            } finally {
                handler.release(); client.abort(); server.abort()
                try { serving.get(5 * Duration.second) } catch (_: Exception) {}
            }
            let limit = Deadline.after(5 * Duration.second)
            while (budget.snapshot().managedBufferBytes != 0u64) {
                if (limit.isExpired()) { throw Exception("server cancellation retained managed buffers") }
                sleep(Duration.millisecond)
            }
            @Expect(budget.snapshot().managedBufferBytes, 0u64)
            @Expect(budget.snapshot().completedCancellations, 1)
        }
        let owner = internal.HttpResourceOwnerKey("https://example.test:443", "direct")
        let budget = cancellationTestBudget()
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 65536)
        let server = Http2ServerConnection(serverTransport, OrdinaryCancellationHandler(),
            resourceBudget: Some(budget), resourceOwner: Some(owner))
        let serving = spawn { server.serve() }
        let client = Http2ClientConnection.connect(clientTransport)
        try {
            let response = client.execute(HttpRequest.get("https://example.test/ordinary"))
            let _ = response.body.read(Array<Byte>(1, repeat: 0u8))
            response.close()
            @Expect(budget.snapshot().completedCancellations, 0)
            @Expect(budget.snapshot().lastCancellationCompletionLatency.isNone())
        } finally {
            client.abort(); server.abort()
            try { serving.get(5 * Duration.second) } catch (_: Exception) {}
        }
        @Expect(budget.snapshot().completedCancellations, 0)
    }
}

private func cancellationTestBudget(): internal.HttpResourceBudget {
    internal.HttpResourceBudget(internal.HttpResourceBudgetPolicy(
        4, 2, 4, 8, 4, 8, 8, 4, 8, 1024u64 * 1024u64, 65536u64, 8))
}

private class GatedCancellationControl <: Http2ServerControlSink {
    private let transport: DuplexTransport
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    init(transport: DuplexTransport) { this.transport = transport }
    public func submit(frames: Array<Http2Frame>): Unit {
        synchronized(mutex) {
            entered = true; changed.notifyAll()
            while (!released) { changed.wait() }
        }
        for (frame in frames) { writeAll(transport, ByteSpan(serializeHttp2Frame(frame))) }
    }
    func awaitCleanup(): Unit {
        let limit = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (!entered) {
                if (limit.isExpired()) { throw Exception("exchange did not enter cleanup") }
                changed.wait(timeout: limit.remaining())
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}

private class HeldCancellationHandler <: Http2ServerHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var request = None<Http2ServerRequest>
    private var released = false
    public func handle(value: Http2ServerRequest, _: OperationContext): Http2ServerResponse {
        synchronized(mutex) {
            request = Some(value); changed.notifyAll()
            while (!released) { changed.wait() }
        }
        Http2ServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
    }
    func awaitRequest(): Http2ServerRequest {
        let limit = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (request.isNone()) {
                if (limit.isExpired()) { throw Exception("server handler did not receive request") }
                changed.wait(timeout: limit.remaining())
            }
            request.getOrThrow()
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}

private class OrdinaryCancellationHandler <: Http2ServerHandler {
    public func handle(_: Http2ServerRequest, _: OperationContext): Http2ServerResponse {
        Http2ServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
    }
}
