package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

@Test
class Http2ConnectionStateMachineTest {
    @TestCase
    func clientStartEmitsMagicAndSettingsThenPeerSettingsOpens(): Unit {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let bytes = machine.start(settings: [Http2Setting(Http2SettingId.EnablePush, 0u32)])
        let magic = http2ClientPreface()
        @Expect(bytes.size, magic.size + 15)
        for (index in 0..magic.size) { @Expect(bytes[index], magic[index]) }
        @Expect(isPrefacePhase(machine.phase))

        let received = machine.receive(encodeHttp2Settings([]))
        @Expect(received.outbound.size, 1)
        @Expect(received.outbound[0].header.flags.isAck())
        @Expect(isOpenPhase(machine.phase))
    }

    @TestCase
    func serverConsumesIncrementalMagicBeforeItsFirstSettings(): Unit {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        @Expect(machine.start().size, 9)
        let magic = http2ClientPreface()
        for (index in 0..magic.size) {
            @Expect(machine.acceptClientPreface([magic[index]]), 1)
        }
        let result = machine.receive(encodeHttp2Settings([]))
        @Expect(result.outbound.size, 1)
        @Expect(isOpenPhase(machine.phase))
    }

    @TestCase
    func invalidOrIncompletePrefaceFailsOnceWithProtocolEvidence(): Unit {
        let incomplete = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        expectConnectionFailure({ => let _ = incomplete.receive(encodeHttp2Settings([])) })
        @Expect(isClosedPhaseTest(incomplete.phase))
        @Expect(incomplete.completionCount, 1)
        @Expect(incomplete.takeTerminalGoAway().isSome())
        @Expect(incomplete.takeTerminalGoAway().isNone())

        let mismatch = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        expectConnectionFailure({ => let _ = mismatch.acceptClientPreface("X".toArray()) })
        @Expect(mismatch.completionCount, 1)
    }

    @TestCase
    func firstPeerFrameMustBeNonAcknowledgementSettings(): Unit {
        let wrongType = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        expectConnectionFailure({ => let _ = wrongType.receive(pingFrame()) })
        @Expect(wrongType.completionCount, 1)

        let acknowledgement = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        expectConnectionFailure({ => let _ = acknowledgement.receive(http2SettingsAck()) })
        @Expect(acknowledgement.completionCount, 1)
    }

    @TestCase
    func openConnectionAppliesSettingsAndCompletesHeaderBlocks(): Unit {
        let machine = openClient()
        let update = machine.receive(
            encodeHttp2Settings([Http2Setting(Http2SettingId.MaxConcurrentStreams, 7u32)])
        )
        @Expect(update.outbound.size, 1)
        @Expect(machine.peerSettings.maxConcurrentStreams, 7u32)

        let headers = machine.receive(connectionTestFrame(Http2FrameType.Headers, 1u32, [0x82], flags: 0x04u8))
        @Expect(headers.headerBlock.isSome())
        @Expect(headers.headerBlock.getOrThrow().bytes, [0x82u8])
    }

    @TestCase
    func peerGoAwayDrainsAndMayOnlyNarrowItsBoundary(): Unit {
        let machine = openClient()
        let first = machine.receive(goAwayFrame(9u32, Http2ErrorCode.NoError, [1, 2]))
        @Expect(isDrainingPhase(machine.phase))
        @Expect(first.peerGoAway.getOrThrow().lastStreamId.value, 9u32)
        @Expect(first.peerGoAway.getOrThrow().debugData, [1u8, 2u8])
        let _ = machine.receive(goAwayFrame(7u32, Http2ErrorCode.NoError, []))
        expectConnectionFailure({ => let _ = machine.receive(goAwayFrame(11u32, Http2ErrorCode.NoError, [])) })
        @Expect(isClosedPhaseTest(machine.phase))
    }

    @TestCase
    func localDrainUsesProcessedPeerBoundaryAndNeverIncreases(): Unit {
        let server = openServer()
        server.markPeerStreamProcessed(Http2StreamId(1u32))
        server.markPeerStreamProcessed(Http2StreamId(5u32))
        let first = decodeHttp2GoAway(server.beginDrain())
        @Expect(first.lastStreamId.value, 5u32)
        @Expect(isDrainingPhase(server.phase))
        let narrowed = decodeHttp2GoAway(server.beginDrain(lastStreamId: Some(Http2StreamId(3u32))))
        @Expect(narrowed.lastStreamId.value, 3u32)
        expectIllegalStateChange({ => let _ = server.beginDrain(lastStreamId: Some(Http2StreamId(5u32))) })
    }

    @TestCase
    func racingFinishTransitionsAndPublishesCompletionExactlyOnce(): Unit {
        for (_ in 0..100) {
            let machine = openClient()
            let winners = AtomicInt64(0)
            let tasks = ArrayList<Future<Unit>>()
            for (_ in 0..8) {
                tasks.add(spawn {
                    if (machine.finish()) { let _ = winners.fetchAdd(1) }
                })
            }
            for (task in tasks) { task.get(Duration.second) }
            @Expect(winners.load(), 1)
            @Expect(machine.completionCount, 1)
            @Expect(isClosedPhaseTest(machine.phase))
            @Expect(machine.completion.isSome())
        }
    }
}

private func openClient(): Http2ConnectionStateMachine {
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    let _ = machine.start()
    let _ = machine.receive(encodeHttp2Settings([]))
    machine
}

private func openServer(): Http2ConnectionStateMachine {
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    let _ = machine.start()
    let _ = machine.acceptClientPreface(http2ClientPreface())
    let _ = machine.receive(encodeHttp2Settings([]))
    machine
}

private func pingFrame(): Http2Frame {
    Http2Frame(
        Http2FrameHeader(8u32, Http2FrameType.Ping, Http2Flags(), Http2StreamId(0u32)),
        Array<Byte>(8, repeat: 0u8)
    )
}

private func goAwayFrame(last: UInt32, code: Http2ErrorCode, debug: Array<Byte>): Http2Frame {
    encodeHttp2GoAway(Http2GoAway(Http2StreamId(last), code, debug))
}

private func connectionTestFrame(
    frameType: Http2FrameType,
    streamId: UInt32,
    payload: Array<Byte>,
    flags!: Byte = 0u8
): Http2Frame {
    Http2Frame(
        Http2FrameHeader(UInt32(payload.size), frameType, Http2Flags(raw: flags), Http2StreamId(streamId)),
        payload
    )
}

private func expectConnectionFailure(action: () -> Unit): Unit {
    var failed = false
    try { action() } catch (_: Http2ProtocolException) { failed = true }
    @Expect(failed)
}

private func expectIllegalStateChange(action: () -> Unit): Unit {
    var failed = false
    try { action() } catch (_: IllegalArgumentException) { failed = true }
    @Expect(failed)
}

private func isPrefacePhase(value: Http2ConnectionPhase): Bool {
    match (value) { case Http2ConnectionPhase.Preface => true; case _ => false }
}

private func isOpenPhase(value: Http2ConnectionPhase): Bool {
    match (value) { case Http2ConnectionPhase.Open => true; case _ => false }
}

private func isDrainingPhase(value: Http2ConnectionPhase): Bool {
    match (value) { case Http2ConnectionPhase.Draining => true; case _ => false }
}

private func isClosedPhaseTest(value: Http2ConnectionPhase): Bool {
    match (value) { case Http2ConnectionPhase.Closed => true; case _ => false }
}
