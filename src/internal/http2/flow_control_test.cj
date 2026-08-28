package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2FlowControllerTest {
    @TestCase
    func windowUpdateCodecIgnoresReservedBitAndRejectsZeroByScope(): Unit {
        let stream = encodeHttp2WindowUpdate(Http2StreamId(1u32), 123456u32)
        @Expect(decodeHttp2WindowUpdate(stream), 123456u32)
        let reserved = flowFrame(Http2StreamId(1u32), [0x80, 0, 0, 1])
        @Expect(decodeHttp2WindowUpdate(reserved), 1u32)
        expectFlowProtocol(Http2ErrorCode.ProtocolError, true, { =>
            let _ = decodeHttp2WindowUpdate(flowFrame(Http2StreamId(0u32), [0, 0, 0, 0]))
        })
        expectFlowProtocol(Http2ErrorCode.ProtocolError, false, { =>
            let _ = decodeHttp2WindowUpdate(flowFrame(Http2StreamId(3u32), [0, 0, 0, 0]))
        })
    }

    @TestCase
    func reservationsRespectConnectionStreamAndPeerFrameCredit(): Unit {
        let flow = Http2FlowController()
        flow.applyPeerSettings(flowUpdate(20000u32, maxFrameSize: 16384u32))
        let id = Http2StreamId(1u32)
        flow.openStream(id)

        let first = flow.reserveSend(id, 20000)
        @Expect(first.amount, 16384)
        @Expect(isPermitReservedTest(first.state))
        @Expect(flow.sendConnectionAvailable, 49151)
        @Expect(first.beginSend())
        @Expect(isPermitSendingTest(first.state))
        @Expect(flow.snapshot(id).sendWindow, 3616)
        @Expect(flow.pendingPermitCount, 0)
        @Expect(!first.cancel())

        flow.receiveWindowUpdate(encodeHttp2WindowUpdate(id, 7u32))
        let second = flow.tryReserveSend(id, 4).getOrThrow()
        @Expect(second.amount, 4)
        @Expect(second.cancel())
        @Expect(!second.cancel())
        @Expect(flow.snapshot(id).sendWindow, 3623)
    }

    @TestCase
    func settingsShrinkPausesReservedDataAndCancellationReleasesIt(): Unit {
        let flow = Http2FlowController()
        flow.applyPeerSettings(flowUpdate(1u32))
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let permit = flow.reserveSend(id, 1)
        flow.applyPeerSettings(flowUpdate(0u32))
        @Expect(flow.snapshot(id).sendWindow, 0)
        @Expect(flow.snapshot(id).reservedSendBytes, 1)

        let cancellation = CancellationSource()
        cancellation.cancel()
        var cancelled = false
        try {
            let _ = permit.beginSend(context: OperationContext(cancellation: cancellation.token))
        } catch (error: NetworkException) {
            cancelled = isCancelledFlowError(error)
        }
        @Expect(cancelled)
        @Expect(isPermitCancelledTest(permit.state))
        @Expect(flow.pendingPermitCount, 0)
        @Expect(flow.snapshot(id).reservedSendBytes, 0)
    }

    @TestCase
    func streamWindowUpdateWakesAReservedPermitAfterSettingsShrink(): Unit {
        let flow = Http2FlowController()
        flow.applyPeerSettings(flowUpdate(1u32))
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let permit = flow.reserveSend(id, 1)
        flow.applyPeerSettings(flowUpdate(0u32))
        let result = spawn { permit.beginSend() }
        flow.receiveWindowUpdate(encodeHttp2WindowUpdate(id, 1u32))
        @Expect(result.get(Duration.second))
        @Expect(flow.snapshot(id).sendWindow, 0)
    }

    @TestCase
    func concurrentTryReserveNeverOvercommitsOneStream(): Unit {
        let flow = Http2FlowController(limits: Http2Limits(maxPendingWrites: 16u32))
        flow.applyPeerSettings(flowUpdate(100u32))
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let admitted = AtomicInt64(0)
        let bytes = AtomicInt64(0)
        let tasks = ArrayList<Future<Unit>>()
        for (_ in 0..64) {
            tasks.add(spawn {
                if (let Some(permit) <- flow.tryReserveSend(id, 10)) {
                    let _ = admitted.fetchAdd(1)
                    let _ = bytes.fetchAdd(permit.amount)
                }
            })
        }
        for (task in tasks) { task.get(Duration.second) }
        @Expect(admitted.load(), 10)
        @Expect(bytes.load(), 100)
        @Expect(flow.snapshot(id).reservedSendBytes, 100)
        @Expect(flow.sendConnectionAvailable, 65435)
    }

    @TestCase
    func receiveCreditReturnsOnlyAfterApplicationConsumption(): Unit {
        let flow = Http2FlowController()
        flow.updateLocalInitialWindowSize(4u32)
        let id = Http2StreamId(2u32)
        flow.openStream(id)
        flow.receiveData(id, 4)
        @Expect(flow.snapshot(id).receiveWindow, 0)
        @Expect(flow.snapshot(id).bufferedReceiveBytes, 4)
        @Expect(flow.bufferedReceiveBytes, 4)

        let updates = flow.consumeReceived(id, 3)
        @Expect(updates.size, 1)
        @Expect(updates[0].header.streamId.value, 2u32)
        @Expect(decodeHttp2WindowUpdate(updates[0]), 3u32)
        @Expect(flow.snapshot(id).receiveWindow, 3)
        @Expect(flow.snapshot(id).bufferedReceiveBytes, 1)
        expectFlowProtocol(Http2ErrorCode.FlowControlError, false, { => flow.receiveData(id, 4) })
        @Expect(flow.consumeReceived(id, 1).isEmpty())
        expectIllegalArgumentFlow({ => let _ = flow.consumeReceived(id, 1) })
        let closeUpdates = flow.closeStream(id)
        @Expect(closeUpdates.size, 1)
        @Expect(closeUpdates[0].header.streamId.value, 0u32)
        @Expect(decodeHttp2WindowUpdate(closeUpdates[0]), 4u32)
    }

    @TestCase
    func smallReceiveReadsCoalesceWindowUpdates(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(2u32)
        flow.openStream(id)
        flow.receiveData(id, 32768)
        var updateCount: Int64 = 0
        for (_ in 0..128) { updateCount += flow.consumeReceived(id, 256).size }
        @Expect(updateCount, 2)
        @Expect(flow.snapshot(id).bufferedReceiveBytes, 0)
        @Expect(flow.snapshot(id).receiveWindow, 65535)
        @Expect(flow.receiveConnectionAvailable, 65535)
    }

    @TestCase
    func stalledConnectionCreditFlushesOnceWithoutChangingSmallReadCoalescing(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(2u32)
        flow.openStream(id)
        flow.receiveData(id, 65535)
        @Expect(flow.receiveConnectionAvailable, 0)
        @Expect(flow.consumeReceived(id, 4096).isEmpty())

        let updates = flow.flushStalledConnectionReceiveCredit()
        @Expect(updates.size, 1)
        @Expect(updates[0].header.streamId.value, 0u32)
        @Expect(decodeHttp2WindowUpdate(updates[0]), 4096u32)
        @Expect(flow.receiveConnectionAvailable, 4096)
        @Expect(flow.flushStalledConnectionReceiveCredit().isEmpty())
        flow.close()
        @Expect(flow.flushStalledConnectionReceiveCredit().isEmpty())
    }

    @TestCase
    func leastRecentlyServedStreamsReceiveCreditBeforeThePreviousOwner(): Unit {
        let flow = Http2FlowController(limits: Http2Limits(
            maxPendingWrites: 128u32, maxConcurrentStreams: 128u32
        ))
        let large = Http2StreamId(1u32)
        flow.openStream(large)
        for (_ in 0..3) { @Expect(flow.reserveSend(large, 16384).beginSend()) }
        @Expect(flow.reserveSend(large, 16383).beginSend())
        @Expect(flow.sendConnectionAvailable, 0)

        let largeCancellation = CancellationSource()
        let largeWaiter = spawn {
            try {
                let _ = flow.reserveSend(
                    large, 4096,
                    context: OperationContext(cancellation: largeCancellation.token)
                )
                false
            } catch (error: NetworkException) {
                isCancelledFlowError(error)
            }
        }
        waitForFlowReservations(flow, 1)
        let siblingWaiters = ArrayList<Future<Http2SendPermit>>()
        for (index in 0..100) {
            let id = Http2StreamId(UInt32(index * 2 + 3))
            flow.openStream(id)
            siblingWaiters.add(spawn { flow.reserveSend(id, 2) })
        }
        waitForFlowReservations(flow, 101)

        flow.receiveWindowUpdate(encodeHttp2WindowUpdate(Http2StreamId(0u32), 4096u32))
        let siblingPermits = ArrayList<Http2SendPermit>()
        for (index in 0..siblingWaiters.size) {
            let permit = siblingWaiters[index].get(Duration.second)
            @Expect(permit.streamId.value, UInt32(index * 2 + 3))
            @Expect(permit.amount, 2)
            siblingPermits.add(permit)
        }
        @Expect(flow.flowControlStalls, 101)
        let unrelatedProbe = Http2StreamId(203u32)
        flow.openStream(unrelatedProbe)
        let unrelatedPermit = flow.tryReserveSend(unrelatedProbe, 1).getOrThrow()
        @Expect(unrelatedPermit.cancel())
        largeCancellation.cancel()
        @Expect(largeWaiter.get(Duration.second))
        for (permit in siblingPermits) { @Expect(permit.cancel()) }
        let cleanupProbe = Http2StreamId(205u32)
        flow.openStream(cleanupProbe)
        let cleanupPermit = flow.tryReserveSend(cleanupProbe, 1).getOrThrow()
        @Expect(cleanupPermit.cancel())
        println(
            "M6_024_FLOW_RESULT siblings=100 connectionCredit=4096 " +
            "flowControlStalls=${flow.flowControlStalls} pendingReservations=" +
            "0 connectionWindowUpdateFrames=1"
        )
    }

    @TestCase
    func connectionSendWindowIsSharedAcrossStreams(): Unit {
        let flow = Http2FlowController()
        let first = Http2StreamId(1u32)
        let second = Http2StreamId(3u32)
        flow.openStream(first)
        flow.openStream(second)
        for (_ in 0..3) { @Expect(flow.reserveSend(first, 16384).beginSend()) }
        @Expect(flow.reserveSend(first, 16383).beginSend())
        @Expect(flow.sendConnectionAvailable, 0)
        @Expect(flow.tryReserveSend(second, 1).isNone())
        flow.receiveWindowUpdate(encodeHttp2WindowUpdate(Http2StreamId(0u32), 1u32))
        let permit = flow.tryReserveSend(second, 1).getOrThrow()
        @Expect(permit.beginSend())
        @Expect(flow.sendConnectionAvailable, 0)
    }

    @TestCase
    func connectionAndStreamWindowViolationsHaveCorrectScope(): Unit {
        let connection = Http2FlowController()
        let first = Http2StreamId(1u32)
        let second = Http2StreamId(3u32)
        connection.openStream(first)
        connection.openStream(second)
        for (_ in 0..3) { connection.receiveData(first, 16384) }
        connection.receiveData(first, 16383)
        expectFlowProtocol(Http2ErrorCode.FlowControlError, true, { => connection.receiveData(second, 1) })

        let stream = Http2FlowController()
        stream.updateLocalInitialWindowSize(2u32)
        stream.openStream(first)
        expectFlowProtocol(Http2ErrorCode.FlowControlError, false, { => stream.receiveData(first, 3) })
    }

    @TestCase
    func settingsAndWindowOverflowFailAtomically(): Unit {
        let connection = Http2FlowController()
        connection.receiveWindowUpdate(
            encodeHttp2WindowUpdate(Http2StreamId(0u32), UInt32(2147483647 - 65535))
        )
        expectFlowProtocol(Http2ErrorCode.FlowControlError, true, { =>
            connection.receiveWindowUpdate(encodeHttp2WindowUpdate(Http2StreamId(0u32), 1u32))
        })

        let streams = Http2FlowController()
        let first = Http2StreamId(1u32)
        let second = Http2StreamId(3u32)
        streams.openStream(first)
        streams.openStream(second)
        streams.receiveWindowUpdate(encodeHttp2WindowUpdate(first, UInt32(2147483647 - 65535)))
        let before = streams.snapshot(first).sendWindow
        expectFlowProtocol(Http2ErrorCode.FlowControlError, true, { =>
            streams.applyPeerSettings(flowUpdate(65536u32))
        })
        @Expect(streams.snapshot(first).sendWindow, before)
        @Expect(streams.snapshot(second).sendWindow, 65535)
    }

    @TestCase
    func streamCleanupCancelsPermitsAndRestoresOnlyConnectionReceiveCredit(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        flow.receiveData(id, 10)
        let permit = flow.reserveSend(id, 5)
        let updates = flow.closeStream(id)
        @Expect(updates.size, 1)
        @Expect(updates[0].header.streamId.value, 0u32)
        @Expect(decodeHttp2WindowUpdate(updates[0]), 10u32)
        @Expect(flow.activeStreamCount, 0)
        @Expect(flow.pendingPermitCount, 0)
        @Expect(flow.bufferedReceiveBytes, 0)
        @Expect(isPermitCancelledTest(permit.state))
        @Expect(!permit.beginSend())
        @Expect(flow.closeStream(id).isEmpty())
        flow.close()
        flow.close()
        expectIllegalFlow({ => flow.openStream(Http2StreamId(3u32)) })
    }

    @TestCase
    func dataAccountingUsesTheEntireFramePayload(): Unit {
        let frame = Http2Frame(
            Http2FrameHeader(5u32, Http2FrameType.Data, Http2Flags(raw: 0x08u8), Http2StreamId(1u32)),
            [2, 7, 8, 0, 0]
        )
        @Expect(http2DataFlowControlledBytes(frame), 5)
        expectIllegalArgumentFlow({ => let _ = http2DataFlowControlledBytes(encodeHttp2WindowUpdate(
            Http2StreamId(0u32), 1u32
        )) })
    }
}

private func flowUpdate(initialWindow: UInt32, maxFrameSize!: UInt32 = 16384u32): Http2SettingsUpdate {
    Http2SettingsUpdate(
        Http2SettingsSnapshot(4096u32, true, 100u32, initialWindow, maxFrameSize, 65536u32),
        0,
        http2SettingsAck()
    )
}

private func flowFrame(streamId: Http2StreamId, payload: Array<Byte>): Http2Frame {
    Http2Frame(
        Http2FrameHeader(4u32, Http2FrameType.WindowUpdate, Http2Flags(), streamId), payload
    )
}

private func expectFlowProtocol(code: Http2ErrorCode, connection: Bool, action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == http2ErrorCodeToWire(code) &&
            isConnectionFlowScope(error.scope) == connection
    }
    @Expect(matched)
}

private func expectIllegalFlow(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: IllegalStateException) { matched = true }
    @Expect(matched)
}

private func expectIllegalArgumentFlow(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: IllegalArgumentException) { matched = true }
    @Expect(matched)
}

private func isConnectionFlowScope(value: Http2ErrorScope): Bool {
    match (value) { case Http2ErrorScope.Connection => true; case _ => false }
}

private func isCancelledFlowError(value: NetworkException): Bool {
    match (value.code) { case NetworkErrorCode.Cancelled => true; case _ => false }
}

private func isPermitReservedTest(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Reserved => true; case _ => false }
}

private func isPermitSendingTest(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Sending => true; case _ => false }
}

private func isPermitCancelledTest(value: Http2SendPermitState): Bool {
    match (value) { case Http2SendPermitState.Cancelled => true; case _ => false }
}

private func waitForFlowReservations(flow: Http2FlowController, expected: Int64): Unit {
    let deadline = MonoTime.now() + Duration.second
    while (flow.flowControlStalls < expected) {
        if (MonoTime.now() >= deadline) {
            @Fail("HTTP/2 flow reservation waiters did not reach ${expected}")
        }
        sleep(Duration.millisecond)
    }
}
