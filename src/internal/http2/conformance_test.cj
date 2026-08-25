package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2ConformanceTest {
    @TestCase
    func invalidFrameOrderMatrixFailsAtConnectionScope(): Unit {
        let firstFrameViolations: Array<Http2Frame> = [
            conformanceFrame(Http2FrameType.Data, 1u32, []),
            conformanceFrame(Http2FrameType.Headers, 1u32, [], flags: 0x04u8),
            encodeHttp2RstStream(Http2StreamId(1u32), Http2ErrorCode.Cancel),
            encodeHttp2Ping([0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8]),
            encodeHttp2GoAway(Http2GoAway(Http2StreamId(0u32), Http2ErrorCode.NoError, [])),
            encodeHttp2WindowUpdate(Http2StreamId(0u32), 1u32),
            http2SettingsAck()
        ]
        for (frame in firstFrameViolations) {
            let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
            expectConformanceConnectionFailure({ => let _ = machine.receive(frame) })
            @Expect(machine.completionCount, 1)
        }

        let interleaved: Array<Http2Frame> = [
            conformanceFrame(Http2FrameType.Data, 3u32, []),
            conformanceFrame(Http2FrameType.Headers, 3u32, [], flags: 0x04u8),
            encodeHttp2Ping([0u8, 1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8]),
            encodeHttp2WindowUpdate(Http2StreamId(0u32), 1u32),
            conformanceFrame(Http2FrameType.Continuation, 3u32, [], flags: 0x04u8)
        ]
        for (frame in interleaved) {
            let machine = openConformanceClient()
            let _ = machine.receive(conformanceFrame(Http2FrameType.Headers, 1u32, [0x82u8]))
            expectConformanceConnectionFailure({ => let _ = machine.receive(frame) })
            @Expect(machine.completionCount, 1)
        }

        let continuationWithoutHeaders = openConformanceClient()
        expectConformanceConnectionFailure({ =>
            let _ = continuationWithoutHeaders.receive(
                conformanceFrame(Http2FrameType.Continuation, 1u32, [0x82u8], flags: 0x04u8)
            )
        })
    }

    @TestCase
    func continuationSequenceCompletesOnlyOnEndHeaders(): Unit {
        let machine = openConformanceClient()
        let start = machine.receive(conformanceFrame(Http2FrameType.Headers, 1u32, [0x82u8]))
        @Expect(start.headerBlock.isNone())
        let middle = machine.receive(conformanceFrame(Http2FrameType.Continuation, 1u32, [0x86u8]))
        @Expect(middle.headerBlock.isNone())
        let finish = machine.receive(
            conformanceFrame(Http2FrameType.Continuation, 1u32, [0x84u8], flags: 0x04u8)
        )
        @Expect(finish.headerBlock.getOrThrow().bytes, [0x82u8, 0x86u8, 0x84u8])
    }

    @TestCase
    func rstStreamAndGoAwayRaceCompletesOwnerOnceAndCleansRegistrations(): Unit {
        for (_ in 0..100) {
            let limits = Http2Limits(maxConcurrentStreams: 4u32)
            let (owned, _) = MemoryTransport.pair()
            let machine = openConformanceClient(limits: limits)
            let registry = Http2StreamRegistry(Http2ConnectionRole.Client, limits: limits)
            let flow = Http2FlowController(limits: limits)
            let writer = Http2WriteScheduler(owned, limits: limits)
            let reset = Http2StreamResetManager(registry, flow, writer, limits: limits)
            let goAway = Http2GoAwayManager(machine, registry, flow, writer, limits: limits)
            let owner = ConformanceRaceOwner()
            let admission = goAway.openLocal(owner)
            let resetRegistration = reset.register(admission.stream.id, owner)
            owner.bind(admission.registration, resetRegistration)

            let tasks = ArrayList<Future<Unit>>()
            tasks.add(spawn {
                let _ = reset.acceptPeer(encodeHttp2RstStream(admission.stream.id, Http2ErrorCode.Cancel))
            })
            tasks.add(spawn {
                let result = machine.receive(
                    encodeHttp2GoAway(Http2GoAway(Http2StreamId(0u32), Http2ErrorCode.NoError, []))
                )
                let _ = goAway.acceptPeer(result)
            })
            for (task in tasks) { task.get(Duration.second) }

            @Expect(owner.completionCount, 1)
            @Expect(registry.activeCount, 0)
            @Expect(flow.activeStreamCount, 0)
            @Expect(reset.activeListenerCount, 0)
            @Expect(goAway.activeListenerCount, 0)
        }
    }
}

private class ConformanceRaceOwner <: Http2StreamResetListener & Http2GoAwayListener {
    private let completed = AtomicBool(false)
    private let completions = AtomicInt64(0)
    private var goAwayRegistration: ?Http2GoAwayRegistration = None<Http2GoAwayRegistration>
    private var resetRegistration: ?Http2StreamResetRegistration = None<Http2StreamResetRegistration>

    prop completionCount: Int64 { get() { completions.load() } }

    func bind(goAway: Http2GoAwayRegistration, reset: Http2StreamResetRegistration): Unit {
        goAwayRegistration = Some(goAway)
        resetRegistration = Some(reset)
    }

    public func streamReset(event: Http2StreamResetEvent): Unit {
        let _ = event
        complete()
    }

    public func connectionGoAway(error: Http2GoAwayException): Unit {
        let _ = error
        complete()
    }

    private func complete(): Unit {
        if (completed.compareAndSwap(false, true)) { let _ = completions.fetchAdd(1) }
        if (let Some(value) <- goAwayRegistration) { value.unregister() }
        if (let Some(value) <- resetRegistration) { value.unregister() }
    }
}

private func openConformanceClient(limits!: Http2Limits = Http2Limits()): Http2ConnectionStateMachine {
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client, limits: limits)
    let _ = machine.start()
    let _ = machine.receive(encodeHttp2Settings([]))
    machine
}

private func conformanceFrame(
    frameType: Http2FrameType,
    streamId: UInt32,
    payload: Array<Byte>,
    flags!: Byte = 0u8
): Http2Frame {
    Http2Frame(
        Http2FrameHeader(
            UInt32(payload.size), frameType, Http2Flags(raw: flags), Http2StreamId(streamId)
        ),
        payload
    )
}

private func expectConformanceConnectionFailure(action: () -> Unit): Unit {
    var connectionFailure = false
    try { action() } catch (error: Http2ProtocolException) {
        match (error.scope) {
            case Http2ErrorScope.Connection => connectionFailure = true
            case _ => ()
        }
    }
    @Expect(connectionFailure)
}
