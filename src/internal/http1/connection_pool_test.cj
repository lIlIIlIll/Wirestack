package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*
import wirestack.internal as internal
private class PoolTestClock <: MonotonicClock {
    private var current: MonoTime
    init() { current = MonoTime.now() }
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

private class PoolTestFactory <: Http1ConnectionFactory {
    let calls = AtomicInt64(0)
    private let peers = ArrayList<MemoryTransport>()

    public func create(key: HttpConnectionPoolKey, context: OperationContext,
        resourceLease: ?internal.HttpResourceLease): Http1ClientConnection {
        let _ = key
        if (context.isCancellationRequested()) { throw Exception("factory called after cancellation") }
        calls.fetchAdd(1)
        let (client, peer) = MemoryTransport.pair()
        peers.add(peer)
        Http1ClientConnection(client)
    }
}

private class FailingPoolFactory <: Http1ConnectionFactory {
    public func create(key: HttpConnectionPoolKey, context: OperationContext,
        resourceLease: ?internal.HttpResourceLease): Http1ClientConnection {
        let _ = key
        let _ = context
        throw Exception("connect failed")
    }
}

private class PoolEventSink <: NetworkEventSink {
    let events = ArrayList<NetworkEvent>()
    public func emit(event: NetworkEvent): Unit { events.add(event) }
}

@Test
class Http1ConnectionPoolTest {
    @TestCase
    func retirementEvictsIdleAndDrainsClaimedConnectionsWithoutReuse(): Unit {
        let pool = Http1ConnectionPool()
        let factory = PoolTestFactory()
        let active = pool.acquire(poolTestKey(), factory)
        let idle = pool.acquire(poolTestKey(), factory)
        pool.release(idle)
        pool.retire()
        @Expect(idle.connection.isClosed())
        @Expect(!active.connection.isClosed())
        @Expect(pool.snapshot().connections, 1)
        @ExpectThrows[NetworkException](pool.acquire(poolTestKey(), factory))
        pool.release(active)
        @Expect(active.connection.isClosed())
        @Expect(pool.snapshot().connections, 0)
        pool.release(active)
        pool.close()
    }

    @TestCase
    func emitsSecretFreeAcquireAndReleaseLifecycle(): Unit {
        let pool = Http1ConnectionPool()
        let factory = PoolTestFactory()
        let sink = PoolEventSink()
        let context = OperationContext(
            trace: Some(NetworkTraceContext("pool-trace")), eventSink: Some(sink)
        )

        let first = pool.acquire(poolTestKey(), factory, context: context)
        pool.release(first, context: context)
        let second = pool.acquire(poolTestKey(), factory, context: context)
        pool.discard(second, context: context)

        @Expect(sink.events.size, 5)
        expectPoolEvent(sink.events[0], NetworkEventKind.HttpConnectionAcquired,
            NetworkEventOutcome.Succeeded, first.id)
        expectPoolEvent(sink.events[1], NetworkEventKind.HttpConnectionReleased,
            NetworkEventOutcome.Released, first.id)
        expectPoolEvent(sink.events[2], NetworkEventKind.HttpConnectionAcquired,
            NetworkEventOutcome.Reused, second.id)
        expectPoolEvent(sink.events[3], NetworkEventKind.HttpConnectionReleased,
            NetworkEventOutcome.Discarded, second.id)
        expectPoolEvent(sink.events[4], NetworkEventKind.ConnectionClosed,
            NetworkEventOutcome.Succeeded, second.id)
        pool.close()
    }

    @TestCase
    func reusesOnlyTheSameCompleteKey(): Unit {
        let pool = Http1ConnectionPool()
        let factory = PoolTestFactory()
        let first = pool.acquire(poolTestKey(), factory)
        pool.release(first)
        let second = pool.acquire(poolTestKey(), factory)
        @Expect(second.id != first.id)
        @Expect(factory.calls.load(), 1)
        // A stale duplicate return cannot revoke the current claim.
        pool.release(first)
        @Expect(pool.snapshot().idleConnections, 0)
        pool.release(second)
        pool.close()
    }

    @TestCase
    func enforcesTotalPerKeyIdleAndWaiterBounds(): Unit {
        let pool = Http1ConnectionPool(config: Http1ConnectionPoolConfig(
            maximumConnections: 2, maximumConnectionsPerKey: 1,
            maximumIdleConnections: 0, maximumWaiters: 0
        ))
        let factory = PoolTestFactory()
        let first = pool.acquire(poolTestKey(), factory)
        let second = pool.acquire(poolTestKey(host: "other.test"), factory)
        var exhausted = false
        try {
            let _ = pool.acquire(poolTestKey(), factory)
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.ResourceExhausted => exhausted = true
                case _ => ()
            }
        }
        @Expect(exhausted)
        pool.release(first)
        @Expect(pool.snapshot().connections, 1)
        pool.release(second)
        @Expect(pool.snapshot().connections, 0)
        pool.close()
    }

    @TestCase
    func activeWaitHonorsCancellationAndReleasesWaiterSlot(): Unit {
        let pool = Http1ConnectionPool(config: Http1ConnectionPoolConfig(
            maximumConnections: 1, maximumConnectionsPerKey: 1,
            maximumIdleConnections: 1, maximumWaiters: 1
        ))
        let factory = PoolTestFactory()
        let held = pool.acquire(poolTestKey(), factory)
        let cancellation = CancellationSource()
        let cancelled = AtomicBool(false)
        let future = spawn {
            try {
                let _ = pool.acquire(
                    poolTestKey(), factory,
                    context: OperationContext(cancellation: cancellation.token)
                )
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => cancelled.store(true)
                    case _ => ()
                }
            }
        }
        @Expect(pool.waitUntilWaiters(1, Duration.second))
        cancellation.cancel()
        future.get()
        @Expect(cancelled.load())
        @Expect(pool.snapshot().waiters, 0)
        pool.release(held)
        pool.close()
    }

    @TestCase
    func evictsExpiredAndClosedConnectionsInsteadOfReusingThem(): Unit {
        let clock = PoolTestClock()
        let pool = Http1ConnectionPool(
            config: Http1ConnectionPoolConfig(idleTimeout: Duration.second),
            clock: clock
        )
        let factory = PoolTestFactory()
        let expired = pool.acquire(poolTestKey(), factory)
        pool.release(expired)
        clock.advance(2 * Duration.second)
        let replacement = pool.acquire(poolTestKey(), factory)
        @Expect(replacement.id != expired.id)
        @Expect(factory.calls.load(), 2)
        replacement.connection.close()
        pool.release(replacement)
        @Expect(pool.snapshot().connections, 0)
        pool.close()
    }

    @TestCase
    func failedCreationRollsBackItsCapacityReservation(): Unit {
        let pool = Http1ConnectionPool(config: Http1ConnectionPoolConfig(
            maximumConnections: 1, maximumConnectionsPerKey: 1, maximumIdleConnections: 1
        ))
        var failed = false
        try { let _ = pool.acquire(poolTestKey(), FailingPoolFactory()) } catch (_: Exception) { failed = true }
        @Expect(failed)
        @Expect(pool.snapshot().reservations, 0)
        let factory = PoolTestFactory()
        let lease = pool.acquire(poolTestKey(), factory)
        pool.discard(lease)
        @Expect(pool.snapshot().connections, 0)
        pool.close()
    }

    @TestCase
    func evictsLeasedConnectionAtMaximumLifetimeOnRelease(): Unit {
        let clock = PoolTestClock()
        let pool = Http1ConnectionPool(
            config: Http1ConnectionPoolConfig(idleTimeout: 3600 * Duration.second),
            clock: clock
        )
        let factory = PoolTestFactory()
        let expired = pool.acquire(poolTestKey(), factory)
        clock.advance(HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second)
        pool.release(expired)

        @Expect(pool.snapshot().connections, 0)
        let replacement = pool.acquire(poolTestKey(), factory)
        @Expect(replacement.id != expired.id)
        @Expect(factory.calls.load(), 2)
        pool.release(replacement)
        pool.close()
    }

    @TestCase
    func expiresConnectionsAtMaximumLifetime(): Unit {
        let clock = PoolTestClock()
        let pool = Http1ConnectionPool(
            config: Http1ConnectionPoolConfig(idleTimeout: 3600 * Duration.second),
            clock: clock
        )
        let factory = PoolTestFactory()
        let expired = pool.acquire(poolTestKey(), factory)
        pool.release(expired)
        clock.advance(HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second)

        let replacement = pool.acquire(poolTestKey(), factory)
        @Expect(replacement.id != expired.id)
        @Expect(factory.calls.load(), 2)
        pool.release(replacement)
        pool.close()
    }

    @TestCase
    func admissionRotatesOriginsAndYieldsTheFullPoolSlot(): Unit {
        let pool = Http1ConnectionPool(config: Http1ConnectionPoolConfig(
            maximumConnections: 1, maximumConnectionsPerKey: 1,
            maximumIdleConnections: 1, maximumWaiters: 2
        ))
        let factory = PoolTestFactory()
        let first = pool.acquire(poolTestKey(), factory)
        let sameOrigin = spawn { pool.acquire(poolTestKey(), factory) }
        @Expect(pool.waitUntilWaiters(1, Duration.second))
        let otherOrigin = spawn { pool.acquire(poolTestKey(host: "other.test"), factory) }
        @Expect(pool.waitUntilWaiters(2, Duration.second))

        pool.release(first)
        let second = sameOrigin.get(Duration.second)
        @Expect(factory.calls.load(), 1)
        @Expect(pool.snapshot().waiters, 1)

        pool.release(second)
        let third = otherOrigin.get(Duration.second)
        @Expect(factory.calls.load(), 2)
        pool.release(third)
        pool.close()
    }
    @TestCase
    func retiringH1PreservesStartedFactoryAndCloseRejectsItsLateResult(): Unit {
        for (strict in [false, true]) {
            let pool = Http1ConnectionPool()
            let factory = RotationPoolFactory()
            let pending = spawn {
                try { Some(pool.acquire(poolTestKey(), factory)) }
                catch (_: NetworkException) { None<Http1PoolLease> }
            }
            factory.waitUntilEntered()
            if (strict) { pool.close() } else { pool.retire() }
            factory.release()
            let result = pending.get(Duration.second)
            if (strict) { @Expect(result.isNone()) }
            else {
                let lease = result.getOrThrow()
                @Expect(!lease.connection.isClosed())
                pool.release(lease)
                @Expect(lease.connection.isClosed())
            }
            @Expect(factory.connection.isClosed())
            @Expect(pool.snapshot().connections, 0)
            @Expect(pool.snapshot().reservations, 0)
            pool.close(); factory.peer.close()
        }
    }

}

private func expectPoolEvent(event: NetworkEvent, kind: NetworkEventKind,
    outcome: NetworkEventOutcome, id: Int64): Unit {
    @Expect(samePoolEventKind(event.kind, kind))
    @Expect(samePoolEventOutcome(event.outcome, outcome))
    @Expect(event.connectionId, Some(id))
    @Expect(event.trace.getOrThrow().traceId, "pool-trace")
    @Expect(event.errorCode.isNone())
}

private func samePoolEventKind(left: NetworkEventKind, right: NetworkEventKind): Bool {
    match ((left, right)) {
        case (NetworkEventKind.HttpConnectionAcquired, NetworkEventKind.HttpConnectionAcquired) => true
        case (NetworkEventKind.HttpConnectionReleased, NetworkEventKind.HttpConnectionReleased) => true
        case (NetworkEventKind.ConnectionClosed, NetworkEventKind.ConnectionClosed) => true
        case _ => false
    }
}

private func samePoolEventOutcome(left: NetworkEventOutcome, right: NetworkEventOutcome): Bool {
    match ((left, right)) {
        case (NetworkEventOutcome.Succeeded, NetworkEventOutcome.Succeeded) => true
        case (NetworkEventOutcome.Reused, NetworkEventOutcome.Reused) => true
        case (NetworkEventOutcome.Released, NetworkEventOutcome.Released) => true
        case (NetworkEventOutcome.Discarded, NetworkEventOutcome.Discarded) => true
        case _ => false
    }
}

private func poolTestKey(host!: String = "example.com"): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", host, 443, None<String>, "default-network", "tls", "trust",
        "client", "provider", "http/1.1"
    )
}

private class RotationPoolFactory <: Http1ConnectionFactory {
    let connection: Http1ClientConnection
    let peer: MemoryTransport
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    init() {
        let (stream, peer) = MemoryTransport.pair()
        connection = Http1ClientConnection(stream)
        this.peer = peer
    }
    public func create(_: HttpConnectionPoolKey, _: OperationContext,
        _: ?internal.HttpResourceLease): Http1ClientConnection {
        synchronized(mutex) {
            entered = true; changed.notifyAll()
            let deadline = Deadline.after(Duration.second)
            while (!released) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("H1 rotation factory gate timed out") }
                changed.wait(timeout: remaining)
            }
        }
        connection
    }
    func waitUntilEntered(): Unit {
        synchronized(mutex) {
            let deadline = Deadline.after(Duration.second)
            while (!entered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("H1 rotation factory did not enter") }
                changed.wait(timeout: remaining)
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}
