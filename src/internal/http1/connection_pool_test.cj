package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

private class PoolTestClock <: MonotonicClock {
    private var current: MonoTime
    init() { current = MonoTime.now() }
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

private class PoolTestFactory <: Http1ConnectionFactory {
    let calls = AtomicInt64(0)
    private let peers = ArrayList<MemoryTransport>()

    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        let _ = key
        if (context.isCancellationRequested()) { throw Exception("factory called after cancellation") }
        calls.fetchAdd(1)
        let (client, peer) = MemoryTransport.pair()
        peers.add(peer)
        Http1ClientConnection(client)
    }
}

private class FailingPoolFactory <: Http1ConnectionFactory {
    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        let _ = key
        let _ = context
        throw Exception("connect failed")
    }
}

@Test
class Http1ConnectionPoolTest {
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
}

private func poolTestKey(host!: String = "example.com"): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", host, 443, None<String>, "default-network", "tls", "trust",
        "client", "provider", "http/1.1"
    )
}
