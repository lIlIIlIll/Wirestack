package wirestack.internal.transport

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private func waitForVirtualWaiters(
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

private func scriptedErrorMatches(
    error: NetworkException,
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    code: NetworkErrorCode
): Bool {
    let categoryMatches = match ((error.category, category)) {
        case (NetworkErrorCategory.Read, NetworkErrorCategory.Read) => true
        case (NetworkErrorCategory.Write, NetworkErrorCategory.Write) => true
        case (NetworkErrorCategory.Connect, NetworkErrorCategory.Connect) => true
        case _ => false
    }
    let phaseMatches = match ((error.phase, phase)) {
        case (NetworkPhase.TcpRead, NetworkPhase.TcpRead) => true
        case (NetworkPhase.TcpWrite, NetworkPhase.TcpWrite) => true
        case (NetworkPhase.TlsHandshake, NetworkPhase.TlsHandshake) => true
        case (NetworkPhase.HttpBody, NetworkPhase.HttpBody) => true
        case _ => false
    }
    let codeMatches = match ((error.code, code)) {
        case (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) => true
        case (NetworkErrorCode.ConnectionReset, NetworkErrorCode.ConnectionReset) => true
        case (NetworkErrorCode.TimedOut, NetworkErrorCode.TimedOut) => true
        case (NetworkErrorCode.SystemFailure, NetworkErrorCode.SystemFailure) => true
        case _ => false
    }
    categoryMatches && phaseMatches && codeMatches
}

@Test
class ScriptedTransportTest {
    @TestCase
    func rejectsUnboundedOrInvalidScripts(): Unit {
        @AssertThrows[IllegalArgumentException](VirtualWaiter(capacity: 0))
        let (left, right) = MemoryTransport.pair()
        try {
            @AssertThrows[IllegalArgumentException](
                ScriptedTransport(left, readScript: [ScriptedTransportStep.Short(0)])
            )
            @AssertThrows[IllegalArgumentException](
                ScriptedTransport(left, writeScript: [ScriptedTransportStep.EndOfStream])
            )
            @AssertThrows[IllegalArgumentException](
                ScriptedTransport(
                    left,
                    readScript: [ScriptedTransportStep.EndOfStream, ScriptedTransportStep.EndOfStream],
                    maxScriptSteps: 1
                )
            )
        } finally {
            left.abort()
            right.abort()
        }
    }

    @TestCase
    func shortReadAndWriteStepsAreConsumedInOrder(): Unit {
        let (left, right) = MemoryTransport.pair(capacity: 8, maxChunk: 8)
        let scripted = ScriptedTransport(
            left,
            readScript: [ScriptedTransportStep.Short(1)],
            writeScript: [ScriptedTransportStep.Short(2), ScriptedTransportStep.Short(1)]
        )
        try {
            @Expect(scripted.writeSome(ByteSpan([1, 2, 3])), 2)
            @Expect(scripted.writeSome(ByteSpan([3])), 1)
            @Expect(scripted.remainingWriteSteps, 0)
            let written = Array<Byte>(3, repeat: 0)
            readExact(right, MutableByteSpan(written))
            @Expect(written[0], 1)
            @Expect(written[1], 2)
            @Expect(written[2], 3)

            writeAll(right, ByteSpan([4, 5]))
            let first = Array<Byte>(2, repeat: 0)
            match (scripted.readSome(MutableByteSpan(first))) {
                case ReadResult.Data(count) => @Expect(count, 1)
                case ReadResult.EndOfStream => @Fail("short read returned EOF")
            }
            @Expect(first[0], 4)
            @Expect(scripted.remainingReadSteps, 0)
        } finally {
            scripted.abort()
            right.abort()
        }
    }

    @TestCase
    func emptyIoDoesNotConsumeScriptAndEofIsExplicit(): Unit {
        let (left, right) = MemoryTransport.pair()
        let scripted = ScriptedTransport(
            left,
            readScript: [ScriptedTransportStep.EndOfStream],
            writeScript: [ScriptedTransportStep.Short(1)]
        )
        try {
            match (scripted.readSome(MutableByteSpan([]))) {
                case ReadResult.Data(count) => @Expect(count, 0)
                case ReadResult.EndOfStream => @Fail("empty read consumed scripted EOF")
            }
            @Expect(scripted.writeSome(ByteSpan([])), 0)
            @Expect(scripted.remainingReadSteps, 1)
            @Expect(scripted.remainingWriteSteps, 1)
            match (scripted.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
                case ReadResult.EndOfStream => ()
                case ReadResult.Data(_) => @Fail("scripted EOF returned data")
            }
        } finally {
            scripted.abort()
            right.abort()
        }
    }

    @TestCase
    func resetTerminatesTransportAtInjectedPhase(): Unit {
        let (left, right) = MemoryTransport.pair()
        let scripted = ScriptedTransport(
            left,
            readScript: [ScriptedTransportStep.Reset(NetworkPhase.TlsHandshake)]
        )
        let error = @AssertThrows[NetworkException](
            scripted.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        )
        @Expect(scriptedErrorMatches(
            error,
            NetworkErrorCategory.Read,
            NetworkPhase.TlsHandshake,
            NetworkErrorCode.ConnectionReset
        ))
        @Expect(scripted.isClosed())
        let peer = @AssertThrows[NetworkException](
            right.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        )
        @Expect(scriptedErrorMatches(
            peer,
            NetworkErrorCategory.Read,
            NetworkPhase.TcpRead,
            NetworkErrorCode.ConnectionReset
        ))
    }

    @TestCase
    func failurePreservesCoordinatesWithoutTerminatingTransport(): Unit {
        let (left, right) = MemoryTransport.pair()
        let scripted = ScriptedTransport(
            left,
            writeScript: [
                ScriptedTransportStep.Failure(
                    NetworkErrorCategory.Connect,
                    NetworkPhase.HttpBody,
                    NetworkErrorCode.SystemFailure,
                    Retryability.Never
                )
            ]
        )
        try {
            let error = @AssertThrows[NetworkException](scripted.writeSome(ByteSpan([1])))
            @Expect(scriptedErrorMatches(
                error,
                NetworkErrorCategory.Connect,
                NetworkPhase.HttpBody,
                NetworkErrorCode.SystemFailure
            ))
            @Expect(!scripted.isClosed())
            @Expect(scripted.writeSome(ByteSpan([2])), 1)
        } finally {
            scripted.abort()
            right.abort()
        }
    }

    @TestCase
    func virtualWaiterReleasesBlockedOperationsInFifoOrder(): Unit {
        let waiter = VirtualWaiter()
        let (firstRaw, firstPeer) = MemoryTransport.pair()
        let (secondRaw, secondPeer) = MemoryTransport.pair()
        let first = ScriptedTransport(
            firstRaw,
            writeScript: [ScriptedTransportStep.Delay(waiter)]
        )
        let second = ScriptedTransport(
            secondRaw,
            writeScript: [ScriptedTransportStep.Delay(waiter)]
        )
        let firstResult: Future<Int64> = spawn { first.writeSome(ByteSpan([1])) }
        @Assert(waitForVirtualWaiters(waiter, 1))
        let secondResult: Future<Int64> = spawn { second.writeSome(ByteSpan([2])) }
        @Assert(waitForVirtualWaiters(waiter, 2))

        @Expect(waiter.releaseNext())
        @Expect(firstResult.get(Duration.second), 1)
        @Expect(secondResult.tryGet().isNone())
        @Expect(waiter.releaseNext())
        @Expect(secondResult.get(Duration.second), 1)
        @Expect(!waiter.releaseNext())

        first.abort()
        second.abort()
        firstPeer.abort()
        secondPeer.abort()
    }

    @TestCase
    func cancellationWinsAReleaseRaceAndCleansWaiter(): Unit {
        let waiter = VirtualWaiter()
        let source = CancellationSource()
        let (raw, peer) = MemoryTransport.pair()
        let scripted = ScriptedTransport(
            raw,
            readScript: [ScriptedTransportStep.Delay(waiter)]
        )
        let result: Future<Bool> = spawn {
            try {
                let _ = scripted.readSome(
                    MutableByteSpan(Array<Byte>(1, repeat: 0)),
                    context: OperationContext(cancellation: source.token)
                )
                false
            } catch (error: NetworkException) {
                scriptedErrorMatches(
                    error,
                    NetworkErrorCategory.Read,
                    NetworkPhase.TcpRead,
                    NetworkErrorCode.Cancelled
                )
            }
        }
        @Assert(waitForVirtualWaiters(waiter, 1))
        source.cancel()
        let _ = waiter.releaseNext()
        @Expect(result.get(Duration.second), true)
        @Expect(waiter.pendingCount, 0)
        scripted.abort()
        peer.abort()
    }
}
