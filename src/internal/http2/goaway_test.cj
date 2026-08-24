package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2GoAwayManagerTest {
    @TestCase
    func peerBoundaryRetiresOnlyDefinitelyUnprocessedStreams(): Unit {
        let fixture = GoAwayFixture()
        let firstListener = RecordingGoAwayListener()
        let secondListener = RecordingGoAwayListener()
        let thirdListener = RecordingGoAwayListener()
        let first = fixture.manager.openLocal(firstListener).stream.id
        let second = fixture.manager.openLocal(secondListener).stream.id
        let third = fixture.manager.openLocal(thirdListener).stream.id
        let secondWrite = fixture.writer.enqueue(goAwayData(second, 2u8))
        let thirdWrite = fixture.writer.enqueue(goAwayData(third, 3u8))
        let secondPermit = fixture.flow.reserveSend(second, 1)
        let thirdPermit = fixture.flow.reserveSend(third, 1)

        let result = fixture.machine.receive(goAwayFrameForTest(second.value, Http2ErrorCode.NoError))
        @Expect(fixture.manager.acceptPeer(result), 1)
        @Expect(!fixture.manager.acceptingNewStreams)
        @Expect(fixture.registry.stream(first).isSome())
        @Expect(fixture.registry.stream(second).isSome())
        @Expect(fixture.registry.stream(third).isNone())
        @Expect(isGoAwayWriteQueued(secondWrite.state))
        @Expect(isGoAwayWriteCancelled(thirdWrite.state))
        @Expect(isGoAwayPermitReserved(secondPermit.state))
        @Expect(isGoAwayPermitCancelled(thirdPermit.state))
        @Expect(firstListener.count, 0)
        @Expect(secondListener.count, 0)
        @Expect(thirdListener.count, 1)
        @Expect(thirdListener.last.getOrThrow().evidence.definitelyNotProcessed)
        @Expect(!fixture.manager.evidenceFor(second).getOrThrow().definitelyNotProcessed)
        @Expect(fixture.manager.evidenceFor(third).getOrThrow().definitelyNotProcessed)
        expectGoAwayAdmissionClosed({ => let _ = fixture.manager.openLocal(RecordingGoAwayListener()) })
    }

    @TestCase
    func narrowingBoundaryWakesEachNewlyExcludedOwnerExactlyOnce(): Unit {
        let fixture = GoAwayFixture()
        let listeners = ArrayList<RecordingGoAwayListener>()
        for (_ in 0..4) {
            let listener = RecordingGoAwayListener()
            listeners.add(listener)
            let _ = fixture.manager.openLocal(listener)
        }
        @Expect(fixture.manager.acceptPeer(
            fixture.machine.receive(goAwayFrameForTest(5u32, Http2ErrorCode.EnhanceYourCalm))
        ), 1)
        @Expect(listeners[3].count, 1)
        @Expect(fixture.manager.acceptPeer(
            fixture.machine.receive(goAwayFrameForTest(3u32, Http2ErrorCode.NoError))
        ), 1)
        @Expect(listeners[2].count, 1)
        @Expect(listeners[0].count, 0)
        @Expect(listeners[1].count, 0)
        @Expect(fixture.manager.activeListenerCount, 2)
    }

    @TestCase
    func localDrainQueuesGoAwayAndStopsAdmissionBeforeWriterRuns(): Unit {
        let fixture = GoAwayFixture()
        let _ = fixture.manager.openLocal(RecordingGoAwayListener())
        let ticket = fixture.manager.beginLocalDrain()
        @Expect(isGoAwayWriteQueued(ticket.state))
        @Expect(!fixture.manager.acceptingNewStreams)
        expectGoAwayAdmissionClosed({ => let _ = fixture.manager.openLocal(RecordingGoAwayListener()) })
    }

    @TestCase
    func fabricatedReceiveResultCannotDrainAnOpenCoordinator(): Unit {
        let fixture = GoAwayFixture()
        let fabricated = Http2ConnectionReceiveResult(
            [], peerGoAway: Some(Http2GoAway(Http2StreamId(0u32), Http2ErrorCode.NoError, []))
        )
        var matched = false
        try { let _ = fixture.manager.acceptPeer(fabricated) }
        catch (_: IllegalStateException) { matched = true }
        @Expect(matched)
        @Expect(fixture.manager.acceptingNewStreams)
        let _ = fixture.manager.openLocal(RecordingGoAwayListener())
    }

    @TestCase
    func racingAdmissionAndGoAwayNeverLeavesAnExcludedStreamActive(): Unit {
        for (_ in 0..64) {
            let fixture = GoAwayFixture()
            let listener = RecordingGoAwayListener()
            let admitted = AtomicInt64(0)
            let opener = spawn {
                try {
                    let _ = fixture.manager.openLocal(listener)
                    let _ = admitted.fetchAdd(1)
                } catch (_: IllegalStateException) {}
            }
            let drainer = spawn {
                let result = fixture.machine.receive(goAwayFrameForTest(0u32, Http2ErrorCode.NoError))
                let _ = fixture.manager.acceptPeer(result)
            }
            opener.get(Duration.second)
            drainer.get(Duration.second)
            @Expect(fixture.registry.activeCount, 0)
            @Expect(fixture.flow.activeStreamCount, 0)
            @Expect(fixture.manager.activeListenerCount, 0)
            @Expect(listener.count, admitted.load())
            expectGoAwayAdmissionClosed({ => let _ = fixture.manager.openLocal(RecordingGoAwayListener()) })
        }
    }
}

private class GoAwayFixture {
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
    let flow = Http2FlowController()
    let writer: Http2WriteScheduler
    let manager: Http2GoAwayManager
    private let transport: MemoryTransport

    init() {
        let (owned, _) = MemoryTransport.pair()
        transport = owned
        writer = Http2WriteScheduler(transport)
        manager = Http2GoAwayManager(machine, registry, flow, writer)
        let _ = machine.start()
        let _ = machine.receive(encodeHttp2Settings([]))
    }
}

private class RecordingGoAwayListener <: Http2GoAwayListener {
    private let mutex = Mutex()
    private var notifications: Int64 = 0
    private var retained: ?Http2GoAwayException = None<Http2GoAwayException>
    prop count: Int64 { get() { synchronized(mutex) { notifications } } }
    prop last: ?Http2GoAwayException { get() { synchronized(mutex) { retained } } }
    public func connectionGoAway(error: Http2GoAwayException): Unit {
        synchronized(mutex) { notifications += 1; retained = Some(error) }
    }
}

private func goAwayFrameForTest(last: UInt32, code: Http2ErrorCode): Http2Frame {
    encodeHttp2GoAway(Http2GoAway(Http2StreamId(last), code, []))
}

private func goAwayData(streamId: Http2StreamId, value: Byte): Http2Frame {
    Http2Frame(Http2FrameHeader(1u32, Http2FrameType.Data, Http2Flags(), streamId), [value])
}

private func expectGoAwayAdmissionClosed(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: IllegalStateException) { matched = true }
    @Expect(matched)
}

private func isGoAwayWriteQueued(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Queued => true; case _ => false }
}

private func isGoAwayWriteCancelled(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Cancelled => true; case _ => false }
}

private func isGoAwayPermitReserved(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Reserved => true; case _ => false }
}

private func isGoAwayPermitCancelled(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Cancelled => true; case _ => false }
}
