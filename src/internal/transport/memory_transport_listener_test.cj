package wirestack.internal.transport

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private func memoryAcceptCoordinates(error: NetworkException): Bool {
    let categoryMatches = match (error.category) {
        case NetworkErrorCategory.Accept => true
        case _ => false
    }
    let phaseMatches = match (error.phase) {
        case NetworkPhase.ServerAccept => true
        case _ => false
    }
    categoryMatches && phaseMatches
}

private func memoryAcceptCode(error: NetworkException, code: NetworkErrorCode): Bool {
    if (!memoryAcceptCoordinates(error)) { return false }
    match ((error.code, code)) {
        case (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) => true
        case (NetworkErrorCode.TimedOut, NetworkErrorCode.TimedOut) => true
        case (NetworkErrorCode.Closed, NetworkErrorCode.Closed) => true
        case _ => false
    }
}

private func memoryResourceExhausted(error: NetworkException): Bool {
    let categoryMatches = match (error.category) {
        case NetworkErrorCategory.ResourceExhausted => true
        case _ => false
    }
    let codeMatches = match (error.code) {
        case NetworkErrorCode.ResourceExhausted => true
        case _ => false
    }
    let phaseMatches = match (error.phase) {
        case NetworkPhase.ServerAccept => true
        case _ => false
    }
    categoryMatches && codeMatches && phaseMatches
}

private func waitForMemoryAccept(listener: MemoryTransportListener, timeout: Duration): Bool {
    let expiresAt = MonoTime.now() + timeout
    while (listener.activeAcceptCount == 0) {
        if (MonoTime.now() >= expiresAt) { return false }
        sleep(Duration.millisecond)
    }
    true
}

private func expectMemoryByte(transport: DuplexTransport, expected: Byte): Unit {
    let data = Array<Byte>(1, repeat: 0)
    readExact(transport, MutableByteSpan(data))
    @Expect(data[0], expected)
}

private func memoryClientObservesReset(client: MemoryTransport): Bool {
    try {
        let _ = client.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        false
    } catch (error: NetworkException) {
        match (error.code) {
            case NetworkErrorCode.ConnectionReset => true
            case _ => false
        }
    }
}

@Test
class MemoryTransportListenerTest {
    @TestCase
    func rejectsInvalidListenerAndSchedulerBounds(): Unit {
        @AssertThrows[IllegalArgumentException](MemoryTransportListener(backlog: 0))
        @AssertThrows[IllegalArgumentException](MemoryTransportListener(transportCapacity: 0))
        @AssertThrows[IllegalArgumentException](MemoryTransportListener(maxChunk: 0))
        @AssertThrows[IllegalArgumentException](MemoryTransportScheduler(maxPendingConnections: 0))
    }

    @TestCase
    func listenerDeliversConnectionsInFifoOrderAndBoundsBacklog(): Unit {
        let listener = MemoryTransportListener(backlog: 2, transportCapacity: 8, maxChunk: 1)
        try {
            let firstClient = listener.connect()
            let secondClient = listener.connect()
            @Expect(listener.queuedConnectionCount, 2)

            let full = @AssertThrows[NetworkException](listener.connect())
            @Expect(memoryResourceExhausted(full))

            @Expect(firstClient.writeSome(ByteSpan([1])), 1)
            @Expect(secondClient.writeSome(ByteSpan([2])), 1)
            let firstServer = listener.accept()
            expectMemoryByte(firstServer, 1)

            let thirdClient = listener.connect()
            @Expect(thirdClient.writeSome(ByteSpan([3])), 1)
            let secondServer = listener.accept()
            let thirdServer = listener.accept()
            expectMemoryByte(secondServer, 2)
            expectMemoryByte(thirdServer, 3)

            firstClient.close()
            secondClient.close()
            thirdClient.close()
            firstServer.close(OperationContext.background())
            secondServer.close(OperationContext.background())
            thirdServer.close(OperationContext.background())
        } finally {
            listener.close()
        }
    }

    @TestCase
    func schedulerDefersDeliveryAndReleasesFailedReservations(): Unit {
        let listener = MemoryTransportListener(backlog: 2)
        let scheduler = MemoryTransportScheduler(maxPendingConnections: 1)
        try {
            let firstClient = listener.connect(scheduler: Some(scheduler))
            @Expect(scheduler.pendingCount, 1)
            @Expect(listener.queuedConnectionCount, 1)

            let full = @AssertThrows[NetworkException](
                listener.connect(scheduler: Some(scheduler))
            )
            @Expect(memoryResourceExhausted(full))
            @Expect(listener.queuedConnectionCount, 1)

            let expired = OperationContext(deadline: Some(Deadline(MonoTime.now())))
            let timedOut = @AssertThrows[NetworkException](listener.accept(expired))
            @Expect(memoryAcceptCode(timedOut, NetworkErrorCode.TimedOut))

            @Expect(scheduler.runNext())
            @Expect(!scheduler.runNext())
            @Expect(scheduler.pendingCount, 0)
            let firstServer = listener.accept()
            @Expect(firstClient.writeSome(ByteSpan([9])), 1)
            expectMemoryByte(firstServer, 9)
            firstClient.close()
            firstServer.close(OperationContext.background())
        } finally {
            listener.close()
        }
    }

    @TestCase
    func schedulerRunsMultipleConnectionsInStableFifoOrder(): Unit {
        let listener = MemoryTransportListener(backlog: 3)
        let scheduler = MemoryTransportScheduler(maxPendingConnections: 3)
        try {
            let firstClient = listener.connect(scheduler: Some(scheduler))
            let secondClient = listener.connect(scheduler: Some(scheduler))
            @Expect(firstClient.writeSome(ByteSpan([4])), 1)
            @Expect(secondClient.writeSome(ByteSpan([5])), 1)

            @Expect(scheduler.runUntilIdle(), 2)
            @Expect(scheduler.pendingCount, 0)
            let firstServer = listener.accept()
            let secondServer = listener.accept()
            expectMemoryByte(firstServer, 4)
            expectMemoryByte(secondServer, 5)

            firstClient.close()
            secondClient.close()
            firstServer.close(OperationContext.background())
            secondServer.close(OperationContext.background())
        } finally {
            listener.close()
        }
    }

    @TestCase
    func cancellationWakesAcceptWithoutClosingListener(): Unit {
        let listener = MemoryTransportListener()
        let source = CancellationSource()
        let result: Future<Bool> = spawn {
            try {
                let _ = listener.accept(OperationContext(cancellation: source.token))
                false
            } catch (error: NetworkException) {
                memoryAcceptCode(error, NetworkErrorCode.Cancelled)
            }
        }
        @Assert(waitForMemoryAccept(listener, Duration.second))
        source.cancel()
        @Expect(result.get(Duration.second), true)
        @Expect(!listener.isClosed())

        let client = listener.connect()
        let server = listener.accept()
        client.close()
        server.close(OperationContext.background())
        listener.close()
    }

    @TestCase
    func deadlineBoundsBlockedAcceptWithoutClosingListener(): Unit {
        let listener = MemoryTransportListener()
        try {
            let error = @AssertThrows[NetworkException](
                listener.accept(
                    OperationContext(
                        deadline: Some(Deadline.after(20 * Duration.millisecond))
                    )
                )
            )
            @Expect(memoryAcceptCode(error, NetworkErrorCode.TimedOut))
            @Expect(!listener.isClosed())
        } finally {
            listener.close()
        }
    }

    @TestCase
    func closeWakesAcceptAndAbortsOwnedConnectionsIdempotently(): Unit {
        let blocked = MemoryTransportListener()
        let result: Future<Bool> = spawn {
            try {
                let _ = blocked.accept()
                false
            } catch (error: NetworkException) {
                memoryAcceptCode(error, NetworkErrorCode.Closed)
            }
        }
        @Assert(waitForMemoryAccept(blocked, Duration.second))
        blocked.close()
        blocked.close()
        @Expect(result.get(Duration.second), true)

        let owned = MemoryTransportListener(backlog: 2)
        let scheduler = MemoryTransportScheduler()
        let queuedClient = owned.connect()
        let scheduledClient = owned.connect(scheduler: Some(scheduler))
        owned.close()
        @Expect(owned.queuedConnectionCount, 0)
        @Expect(memoryClientObservesReset(queuedClient))
        @Expect(memoryClientObservesReset(scheduledClient))
        @Expect(scheduler.pendingCount, 0)
        @Expect(scheduler.runUntilIdle(), 0)
        @Expect(owned.queuedConnectionCount, 0)
    }
}
