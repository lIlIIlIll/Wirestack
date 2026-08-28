package wirestack.internal.transport

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private func waitForM124Waiter(
    waiter: VirtualWaiter,
    expected: Int64,
    timeout!: Duration = Duration.second
): Bool {
    let expiresAt = MonoTime.now() + timeout
    while (waiter.pendingCount != expected) {
        if (MonoTime.now() >= expiresAt) { return false }
        sleep(Duration.millisecond)
    }
    true
}

private func m124HasCode(error: NetworkException, code: NetworkErrorCode): Bool {
    match ((error.code, code)) {
        case (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) => true
        case (NetworkErrorCode.Closed, NetworkErrorCode.Closed) => true
        case _ => false
    }
}

@Test
class M124TransportRaceTest {
    @TestCase
    func readCloseReleasesBlockedOperationAndDrainsWaiter(): Unit {
        let waiter = VirtualWaiter()
        let (raw, peer) = MemoryTransport.pair()
        let transport = ScriptedTransport(
            raw,
            readScript: [ScriptedTransportStep.Delay(waiter)]
        )
        let result: Future<Bool> = spawn {
            try {
                let _ = transport.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
                false
            } catch (error: NetworkException) {
                m124HasCode(error, NetworkErrorCode.Closed)
            }
        }

        try {
            @Assert(waitForM124Waiter(waiter, 1))
            transport.close()

            @Expect(result.get(Duration.second), true)
            @Expect(waiter.pendingCount, 0)
            @Expect(transport.isClosed())
        } finally {
            transport.abort()
            peer.abort()
        }
    }

    @TestCase
    func writeAbortReleasesBlockedOperationAndDrainsWaiter(): Unit {
        let waiter = VirtualWaiter()
        let (raw, peer) = MemoryTransport.pair()
        let transport = ScriptedTransport(
            raw,
            writeScript: [ScriptedTransportStep.Delay(waiter)]
        )
        let result: Future<Bool> = spawn {
            try {
                let _ = transport.writeSome(ByteSpan([1]))
                false
            } catch (error: NetworkException) {
                m124HasCode(error, NetworkErrorCode.Closed)
            }
        }

        try {
            @Assert(waitForM124Waiter(waiter, 1))
            transport.abort(reason: Some(AbortReason.ApplicationAbort))

            @Expect(result.get(Duration.second), true)
            @Expect(waiter.pendingCount, 0)
            @Expect(transport.isClosed())
        } finally {
            transport.abort()
            peer.abort()
        }
    }

    @TestCase
    func successAndCancelOrderingsCompleteOnceWithoutDataLeak(): Unit {
        let successWaiter = VirtualWaiter()
        let successSource = CancellationSource()
        let (successRaw, successPeer) = MemoryTransport.pair()
        let successTransport = ScriptedTransport(
            successRaw,
            writeScript: [ScriptedTransportStep.Delay(successWaiter)]
        )
        let success: Future<Int64> = spawn {
            successTransport.writeSome(
                ByteSpan([7]),
                context: OperationContext(cancellation: successSource.token)
            )
        }

        try {
            @Assert(waitForM124Waiter(successWaiter, 1))
            @Expect(successWaiter.releaseNext())
            @Expect(success.get(Duration.second), 1)
            successSource.cancel()
            @Expect(successWaiter.pendingCount, 0)
            let received = Array<Byte>(1, repeat: 0)
            readExact(successPeer, MutableByteSpan(received))
            @Expect(received[0], 7)
        } finally {
            successTransport.abort()
            successPeer.abort()
        }

        let cancelledWaiter = VirtualWaiter()
        let cancelledSource = CancellationSource()
        let (cancelledRaw, cancelledPeer) = MemoryTransport.pair()
        let cancelledTransport = ScriptedTransport(
            cancelledRaw,
            writeScript: [ScriptedTransportStep.Delay(cancelledWaiter)]
        )
        let cancelled: Future<Bool> = spawn {
            try {
                let _ = cancelledTransport.writeSome(
                    ByteSpan([9]),
                    context: OperationContext(cancellation: cancelledSource.token)
                )
                false
            } catch (error: NetworkException) {
                m124HasCode(error, NetworkErrorCode.Cancelled)
            }
        }

        try {
            @Assert(waitForM124Waiter(cancelledWaiter, 1))
            cancelledSource.cancel()
            @Expect(cancelled.get(Duration.second), true)
            @Expect(cancelledWaiter.pendingCount, 0)
            @Expect(!cancelledWaiter.releaseNext())
            cancelledTransport.shutdown(ShutdownDirection.Write)
            match (cancelledPeer.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
                case ReadResult.EndOfStream => ()
                case ReadResult.Data(_) => @Fail("cancelled write produced peer data")
            }
        } finally {
            cancelledTransport.abort()
            cancelledPeer.abort()
        }
    }
}
