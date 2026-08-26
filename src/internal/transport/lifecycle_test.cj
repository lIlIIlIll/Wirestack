package wirestack.internal.transport

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TransportLifecycleTest {
    @TestCase
    func connectingAndAcceptedPathsReachOpenOnlyInOrder(): Unit {
        let connecting = TransportLifecycle()
        connecting.markConnecting()
        @Expect(sameTransportState(connecting.state, TransportState.Connecting))
        connecting.markOpen()
        @Expect(sameTransportState(connecting.state, TransportState.Open))

        let accepted = TransportLifecycle()
        accepted.markAccepted()
        @Expect(sameTransportState(accepted.state, TransportState.Accepted))
        accepted.markOpen()
        @Expect(sameTransportState(accepted.state, TransportState.Open))
    }

    @TestCase
    func halfCloseIsDirectionalIdempotentAndConvergesOnClosing(): Unit {
        let readFirst = openLifecycle()
        @Expect(readFirst.shutdown(ShutdownDirection.Read))
        @Expect(sameTransportState(readFirst.state, TransportState.ReadHalfClosed))
        readFirst.requireWritable()
        @Expect(throwsLifecycleCode({ => readFirst.requireReadable() }, NetworkErrorCode.Closed))
        @Expect(!readFirst.shutdown(ShutdownDirection.Read))
        @Expect(readFirst.shutdown(ShutdownDirection.Write))
        @Expect(sameTransportState(readFirst.state, TransportState.Closing))
        @Expect(readFirst.markClosed())

        let writeFirst = openLifecycle()
        @Expect(writeFirst.shutdown(ShutdownDirection.Write))
        @Expect(sameTransportState(writeFirst.state, TransportState.WriteHalfClosed))
        writeFirst.requireReadable()
        @Expect(throwsLifecycleCode({ => writeFirst.requireWritable() }, NetworkErrorCode.Closed))
        @Expect(!writeFirst.shutdown(ShutdownDirection.Write))
        @Expect(writeFirst.shutdown(ShutdownDirection.Read))
        @Expect(writeFirst.markClosed())
    }

    @TestCase
    func gracefulCloseIsIdempotentAndCompletesOnlyFromClosing(): Unit {
        let lifecycle = openLifecycle()
        @Expect(lifecycle.beginClose())
        @Expect(sameTransportState(lifecycle.state, TransportState.Closing))
        @Expect(!lifecycle.beginClose())
        @Expect(lifecycle.markClosed())
        @Expect(lifecycle.isTerminal)
        @Expect(sameTransportState(lifecycle.state, TransportState.Closed))
        @Expect(!lifecycle.markClosed())
        @Expect(!lifecycle.beginClose())
        @Expect(!lifecycle.abort())
        @Expect(!lifecycle.fail())
        @Expect(sameTransportState(lifecycle.state, TransportState.Closed))

        let readHalfClosed = lifecycleAt(TransportState.ReadHalfClosed)
        @Expect(readHalfClosed.beginClose())
        @Expect(sameTransportState(readHalfClosed.state, TransportState.Closing))

        let writeHalfClosed = lifecycleAt(TransportState.WriteHalfClosed)
        @Expect(writeHalfClosed.beginClose())
        @Expect(sameTransportState(writeHalfClosed.state, TransportState.Closing))
    }

    @TestCase
    func abortAndFailReachEveryNonTerminalStateWithoutOverwritingTerminalEvidence(): Unit {
        for (state in nonTerminalStates()) {
            let aborted = lifecycleAt(state)
            @Expect(aborted.abort())
            @Expect(sameTransportState(aborted.state, TransportState.Aborted))
            @Expect(!aborted.abort())
            @Expect(!aborted.fail())

            let failed = lifecycleAt(state)
            @Expect(failed.fail())
            @Expect(sameTransportState(failed.state, TransportState.Failed))
            @Expect(!failed.fail())
            @Expect(!failed.abort())
        }
    }

    @TestCase
    func illegalTransitionsHaveStableCodesAndDoNotMutateState(): Unit {
        let created = TransportLifecycle()
        @Expect(throwsLifecycleCode({ => created.markOpen() }, NetworkErrorCode.InvalidState))
        for (state in [TransportState.Created, TransportState.Connecting, TransportState.Accepted]) {
            let preOpen = lifecycleAt(state)
            @Expect(throwsLifecycleCode(
                { => let _ = preOpen.shutdown(ShutdownDirection.Read) },
                NetworkErrorCode.InvalidState
            ))
            @Expect(throwsLifecycleCode({ => preOpen.requireReadable() }, NetworkErrorCode.InvalidState))
            @Expect(throwsLifecycleCode({ => preOpen.requireWritable() }, NetworkErrorCode.InvalidState))
            @Expect(throwsLifecycleCode({ => let _ = preOpen.beginClose() }, NetworkErrorCode.InvalidState))
            @Expect(throwsLifecycleCode({ => let _ = preOpen.markClosed() }, NetworkErrorCode.InvalidState))
            @Expect(sameTransportState(preOpen.state, state))
        }

        let open = openLifecycle()
        @Expect(throwsLifecycleCode({ => open.markAccepted() }, NetworkErrorCode.InvalidState))
        @Expect(throwsLifecycleCode({ => open.markConnecting() }, NetworkErrorCode.InvalidState))
        @Expect(throwsLifecycleCode({ => open.markOpen() }, NetworkErrorCode.InvalidState))
        @Expect(sameTransportState(open.state, TransportState.Open))
    }

    @TestCase
    func closingAndTerminalStatesRejectDataOperationsWithClosedCode(): Unit {
        for (state in [
            TransportState.ReadHalfClosed,
            TransportState.WriteHalfClosed,
            TransportState.Closing,
            TransportState.Closed,
            TransportState.Aborted,
            TransportState.Failed
        ]) {
            let lifecycle = lifecycleAt(state)
            let readClosed = !sameTransportState(state, TransportState.WriteHalfClosed)
            let writeClosed = !sameTransportState(state, TransportState.ReadHalfClosed)
            if (readClosed) {
                @Expect(throwsLifecycleCode({ => lifecycle.requireReadable() }, NetworkErrorCode.Closed))
            }
            if (writeClosed) {
                @Expect(throwsLifecycleCode({ => lifecycle.requireWritable() }, NetworkErrorCode.Closed))
            }
        }
    }

    @TestCase
    func operationClaimsAllowDuplexButRejectSameDirectionConcurrency(): Unit {
        let lifecycle = openLifecycle()
        lifecycle.beginRead()
        lifecycle.beginWrite()

        @Expect(throwsLifecycleCode({ => lifecycle.beginRead() }, NetworkErrorCode.ConcurrentOperation))
        @Expect(throwsLifecycleCode({ => lifecycle.beginWrite() }, NetworkErrorCode.ConcurrentOperation))

        lifecycle.endRead()
        lifecycle.endWrite()
        lifecycle.beginRead()
        lifecycle.beginWrite()
        lifecycle.endRead()
        lifecycle.endWrite()
    }

    @TestCase
    func everyTerminalModeReleasesRegisteredResourcesExactlyOnce(): Unit {
        for (mode in 0..3) {
            let lifecycle = openLifecycle()
            let calls = AtomicInt64(0)
            let removedCalls = AtomicInt64(0)
            let _ = lifecycle.registerTerminalCleanup { => calls.fetchAdd(1); () }
            let removed = lifecycle.registerTerminalCleanup { => removedCalls.fetchAdd(1); () }
            removed.unregister()

            if (mode == 0) {
                let _ = lifecycle.beginClose()
                let _ = lifecycle.markClosed()
            } else if (mode == 1) {
                let _ = lifecycle.abort()
            } else {
                let _ = lifecycle.fail()
            }
            let late = lifecycle.registerTerminalCleanup { => calls.fetchAdd(1); () }
            late.unregister()

            @Expect(calls.load(), 2)
            @Expect(removedCalls.load(), 0)
        }
    }

    @TestCase
    func racingTerminalTransitionsRetainOneWinnerAndOneCleanup(): Unit {
        for (_ in 0..100) {
            let lifecycle = openLifecycle()
            let cleanups = AtomicInt64(0)
            let winners = AtomicInt64(0)
            let _ = lifecycle.registerTerminalCleanup { => cleanups.fetchAdd(1); () }
            let _ = lifecycle.beginClose()
            let tasks = ArrayList<Future<Unit>>()
            for (index in 0..24) {
                tasks.add(spawn {
                    let won = if (index % 3 == 0) {
                        lifecycle.markClosed()
                    } else if (index % 3 == 1) {
                        lifecycle.abort()
                    } else {
                        lifecycle.fail()
                    }
                    if (won) { winners.fetchAdd(1); () }
                })
            }
            for (task in tasks) { task.get(Duration.second) }

            @Expect(winners.load(), 1)
            @Expect(cleanups.load(), 1)
            @Expect(lifecycle.isTerminal)
        }
    }

    @TestCase
    func terminalCleanupMayReenterAndItsRegistryRemainsBounded(): Unit {
        let lifecycle = TransportLifecycle(maxTerminalCleanups: 1u32)
        lifecycle.markConnecting()
        lifecycle.markOpen()
        let reentrantWins = AtomicInt64(0)
        let lateCalls = AtomicInt64(0)
        let _ = lifecycle.registerTerminalCleanup { =>
            if (lifecycle.abort()) { reentrantWins.fetchAdd(1); () }
            let late = lifecycle.registerTerminalCleanup { => lateCalls.fetchAdd(1); () }
            late.unregister()
        }
        var capacityRejected = false
        try {
            let _ = lifecycle.registerTerminalCleanup { => }
        } catch (_: IllegalStateException) {
            capacityRejected = true
        }
        @Expect(capacityRejected)
        @Expect(lifecycle.fail())
        @Expect(reentrantWins.load(), 0)
        @Expect(lateCalls.load(), 1)
        @Expect(sameTransportState(lifecycle.state, TransportState.Failed))
    }
}

private func openLifecycle(): TransportLifecycle {
    let lifecycle = TransportLifecycle()
    lifecycle.markConnecting()
    lifecycle.markOpen()
    lifecycle
}

private func lifecycleAt(target: TransportState): TransportLifecycle {
    let lifecycle = TransportLifecycle()
    match (target) {
        case TransportState.Created => ()
        case TransportState.Connecting => lifecycle.markConnecting()
        case TransportState.Accepted => lifecycle.markAccepted()
        case TransportState.Open => lifecycle.markConnecting(); lifecycle.markOpen()
        case TransportState.ReadHalfClosed =>
            lifecycle.markConnecting(); lifecycle.markOpen(); let _ = lifecycle.shutdown(ShutdownDirection.Read)
        case TransportState.WriteHalfClosed =>
            lifecycle.markConnecting(); lifecycle.markOpen(); let _ = lifecycle.shutdown(ShutdownDirection.Write)
        case TransportState.Closing => lifecycle.markConnecting(); lifecycle.markOpen(); let _ = lifecycle.beginClose()
        case TransportState.Closed =>
            lifecycle.markConnecting(); lifecycle.markOpen(); let _ = lifecycle.beginClose(); let _ = lifecycle.markClosed()
        case TransportState.Aborted => let _ = lifecycle.abort()
        case TransportState.Failed => let _ = lifecycle.fail()
    }
    lifecycle
}

private func nonTerminalStates(): Array<TransportState> {
    [
        TransportState.Created,
        TransportState.Connecting,
        TransportState.Accepted,
        TransportState.Open,
        TransportState.ReadHalfClosed,
        TransportState.WriteHalfClosed,
        TransportState.Closing
    ]
}

private func throwsLifecycleCode(action: () -> Unit, expected: NetworkErrorCode): Bool {
    try {
        action()
        false
    } catch (error: NetworkException) {
        sameLifecycleCode(error.code, expected) && sameRetryability(error.retryability, Retryability.Never)
    }
}

private func sameLifecycleCode(left: NetworkErrorCode, right: NetworkErrorCode): Bool {
    match ((left, right)) {
        case (NetworkErrorCode.InvalidState, NetworkErrorCode.InvalidState) |
             (NetworkErrorCode.Closed, NetworkErrorCode.Closed) |
             (NetworkErrorCode.ConcurrentOperation, NetworkErrorCode.ConcurrentOperation) => true
        case _ => false
    }
}

private func sameRetryability(left: Retryability, right: Retryability): Bool {
    match ((left, right)) {
        case (Retryability.Never, Retryability.Never) => true
        case _ => false
    }
}

private func sameTransportState(left: TransportState, right: TransportState): Bool {
    match ((left, right)) {
        case (TransportState.Created, TransportState.Created) |
             (TransportState.Connecting, TransportState.Connecting) |
             (TransportState.Accepted, TransportState.Accepted) |
             (TransportState.Open, TransportState.Open) |
             (TransportState.ReadHalfClosed, TransportState.ReadHalfClosed) |
             (TransportState.WriteHalfClosed, TransportState.WriteHalfClosed) |
             (TransportState.Closing, TransportState.Closing) |
             (TransportState.Closed, TransportState.Closed) |
             (TransportState.Aborted, TransportState.Aborted) |
             (TransportState.Failed, TransportState.Failed) => true
        case _ => false
    }
}
