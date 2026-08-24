package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2StreamResetManagerTest {
    @TestCase
    func rstCodecPreservesKnownAndExtensionCodes(): Unit {
        let id = Http2StreamId(3u32)
        for (code in [Http2ErrorCode.Cancel, Http2ErrorCode.Unknown(0xfeedu32)]) {
            let frame = encodeHttp2RstStream(id, code)
            @Expect(frame.header.streamId.value, 3u32)
            @Expect(http2FrameTypeCode(frame.header.frameType), 3u8)
            @Expect(frame.payload.size, 4)
            @Expect(http2ErrorCodeToWire(decodeHttp2RstStream(frame)), http2ErrorCodeToWire(code))
        }
        expectResetConnectionProtocol({ => let _ = decodeHttp2RstStream(
            encodeHttp2WindowUpdate(Http2StreamId(0u32), 1u32)
        ) })
    }

    @TestCase
    func localCancelQueuesResetAndReleasesOnlyItsStream(): Unit {
        let fixture = ResetFixture()
        let first = fixture.openLocal()
        let second = fixture.openLocal()
        fixture.flow.receiveData(first, 3)
        let firstWrite = fixture.writer.enqueue(resetData(first, 1u8))
        let secondWrite = fixture.writer.enqueue(resetData(second, 2u8))
        let listener = RecordingResetListener()
        let _ = fixture.manager.register(first, listener)

        let reset = fixture.manager.cancelLocal(first).getOrThrow()
        @Expect(isResetCancelled(firstWrite.state))
        @Expect(isResetQueued(secondWrite.state))
        @Expect(isResetQueued(reset.state))
        @Expect(fixture.registry.activeCount, 1)
        @Expect(fixture.registry.stream(second).isSome())
        @Expect(fixture.flow.activeStreamCount, 1)
        @Expect(fixture.flow.bufferedReceiveBytes, 0)
        @Expect(listener.count, 1)
        @Expect(!listener.last.getOrThrow().peerInitiated)
        @Expect(fixture.manager.activeListenerCount, 0)
        @Expect(fixture.manager.cancelLocal(first).isNone())
    }

    @TestCase
    func peerResetCancelsQueuedDataPermitsAndWakesOwnerOnce(): Unit {
        let fixture = ResetFixture()
        let first = fixture.openLocal()
        let second = fixture.openLocal()
        let firstWrite = fixture.writer.enqueue(resetData(first, 1u8))
        let secondWrite = fixture.writer.enqueue(resetData(second, 2u8))
        let permit = fixture.flow.reserveSend(first, 5)
        let otherPermit = fixture.flow.reserveSend(second, 5)
        let listener = RecordingResetListener()
        let _ = fixture.manager.register(first, listener)
        let frame = encodeHttp2RstStream(first, Http2ErrorCode.RefusedStream)

        @Expect(fixture.manager.acceptPeer(frame))
        @Expect(!fixture.manager.acceptPeer(frame))
        @Expect(isResetCancelled(firstWrite.state))
        @Expect(isResetCancelledPermit(permit.state))
        @Expect(isResetQueued(secondWrite.state))
        @Expect(isResetReservedPermit(otherPermit.state))
        @Expect(fixture.registry.activeCount, 1)
        @Expect(fixture.flow.activeStreamCount, 1)
        @Expect(listener.count, 1)
        @Expect(listener.last.getOrThrow().peerInitiated)
        @Expect(http2ErrorCodeToWire(listener.last.getOrThrow().code), 7u32)

        expectResetConnectionProtocol({ =>
            let _ = fixture.manager.acceptPeer(encodeHttp2RstStream(Http2StreamId(99u32), Http2ErrorCode.Cancel))
        })
    }

    @TestCase
    func resetWakesBlockedServerBodyWithoutClosingConnection(): Unit {
        let (transport, _) = MemoryTransport.pair()
        let writer = Http2WriteScheduler(transport)
        let registry = Http2StreamRegistry(Http2ConnectionRole.Server)
        let flow = Http2FlowController()
        let sink = NoopResetControlSink()
        let exchange = Http2ServerExchange.open(
            Http2StreamId(1u32), resetRequestFields(), false, registry, flow, sink
        )
        let manager = Http2StreamResetManager(registry, flow, writer)
        let _ = manager.register(Http2StreamId(1u32), exchange)
        let waiting = spawn {
            try { let _ = exchange.request.body.read(Array<Byte>(1, repeat: 0)); false }
            catch (error: Http2ProtocolException) {
                http2ErrorCodeToWire(error.code) == 8u32
            }
        }
        @Expect(manager.acceptPeer(encodeHttp2RstStream(Http2StreamId(1u32), Http2ErrorCode.Cancel)))
        @Expect(waiting.get(Duration.second))
        @Expect(registry.activeCount, 0)
        @Expect(flow.activeStreamCount, 0)
        @Expect(isResetWriterOpen(writer.state))
    }

    @TestCase
    func racingLocalAndPeerResetCompletesEveryStreamExactlyOnce(): Unit {
        let limits = Http2Limits(maxConcurrentStreams: 64u32, maxPendingWrites: 128u32)
        let fixture = ResetFixture(limits: limits)
        let listeners = ArrayList<RecordingResetListener>()
        let tasks = ArrayList<Future<Unit>>()
        for (_ in 0..64) {
            let id = fixture.openLocal()
            let listener = RecordingResetListener()
            listeners.add(listener)
            let _ = fixture.manager.register(id, listener)
            tasks.add(spawn { let _ = fixture.manager.cancelLocal(id) })
            tasks.add(spawn {
                let _ = fixture.manager.acceptPeer(encodeHttp2RstStream(id, Http2ErrorCode.Cancel))
            })
        }
        for (task in tasks) { task.get(Duration.second) }
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
        @Expect(fixture.manager.activeListenerCount, 0)
        var notifications: Int64 = 0
        for (listener in listeners) { notifications += listener.count }
        @Expect(notifications, 64)
        @Expect(isResetWriterOpen(fixture.writer.state))
    }

    @TestCase
    func queuePressureIsAtomicAndCleanupCreditStaysBoundedForRetry(): Unit {
        let limits = Http2Limits(
            maxConcurrentStreams: 3u32, maxPendingWrites: 2u32, maxPendingWriteBytes: 1024u32
        )
        let fixture = ResetFixture(limits: limits)
        let target = fixture.openLocal()
        let second = fixture.openLocal()
        let third = fixture.openLocal()
        let secondWrite = fixture.writer.enqueue(resetData(second, 2u8))
        let _ = fixture.writer.enqueue(resetData(third, 3u8))
        expectResetQueueFull({ => let _ = fixture.manager.cancelLocal(target) })
        @Expect(fixture.registry.stream(target).isSome())
        @Expect(fixture.flow.activeStreamCount, 3)

        fixture.flow.receiveData(target, 3)
        @Expect(fixture.manager.acceptPeer(encodeHttp2RstStream(target, Http2ErrorCode.Cancel)))
        @Expect(fixture.manager.deferredCredit, 3u32)
        @Expect(secondWrite.cancel())
        @Expect(fixture.manager.flush())
        @Expect(fixture.manager.deferredCredit, 0u32)
        @Expect(fixture.registry.activeCount, 2)
        @Expect(fixture.flow.activeStreamCount, 2)
    }
}

private class ResetFixture {
    let registry: Http2StreamRegistry
    let flow: Http2FlowController
    let writer: Http2WriteScheduler
    let manager: Http2StreamResetManager
    private let transport: MemoryTransport

    init(limits!: Http2Limits = Http2Limits()) {
        let (owned, _) = MemoryTransport.pair()
        transport = owned
        registry = Http2StreamRegistry(Http2ConnectionRole.Client, limits: limits)
        flow = Http2FlowController(limits: limits)
        writer = Http2WriteScheduler(transport, limits: limits)
        manager = Http2StreamResetManager(registry, flow, writer, limits: limits)
    }

    func openLocal(): Http2StreamId {
        let id = registry.openLocal().id
        flow.openStream(id)
        id
    }
}

private class RecordingResetListener <: Http2StreamResetListener {
    private let mutex = Mutex()
    private var notifications: Int64 = 0
    private var retained: ?Http2StreamResetEvent = None<Http2StreamResetEvent>
    prop count: Int64 { get() { synchronized(mutex) { notifications } } }
    prop last: ?Http2StreamResetEvent { get() { synchronized(mutex) { retained } } }
    public func streamReset(event: Http2StreamResetEvent): Unit {
        synchronized(mutex) { notifications += 1; retained = Some(event) }
    }
}

private class NoopResetControlSink <: Http2ServerControlSink {
    public func submit(frames: Array<Http2Frame>): Unit { let _ = frames }
}

private func resetData(streamId: Http2StreamId, value: Byte): Http2Frame {
    Http2Frame(
        Http2FrameHeader(1u32, Http2FrameType.Data, Http2Flags(), streamId), [value]
    )
}

private func resetRequestFields(): Array<HpackHeaderField> {
    [
        HpackHeaderField(":method", "POST"), HpackHeaderField(":scheme", "https"),
        HpackHeaderField(":authority", "example.com"), HpackHeaderField(":path", "/")
    ]
}

private func expectResetConnectionProtocol(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        match (error.scope) { case Http2ErrorScope.Connection => matched = true; case _ => () }
    }
    @Expect(matched)
}

private func expectResetQueueFull(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: Http2WriteQueueFullException) { matched = true }
    @Expect(matched)
}

private func isResetQueued(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Queued => true; case _ => false }
}

private func isResetCancelled(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Cancelled => true; case _ => false }
}

private func isResetReservedPermit(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Reserved => true; case _ => false }
}

private func isResetCancelledPermit(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Cancelled => true; case _ => false }
}

private func isResetWriterOpen(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Open => true; case _ => false }
}
