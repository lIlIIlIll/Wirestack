package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http2.*
import wirestack.internal.transport.*

@Test
class Http2ConnectionPoolTest {
    @TestCase
    func alpnPrefersH2AndFallsBackOnlyToHttp11(): Unit {
        @Expect(httpClientAlpnProtocols(), ["h2", "http/1.1"])
        @Expect(isNegotiatedHttp2(selectHttpNegotiatedProtocol(Some("h2"))))
        @Expect(isNegotiatedHttp11(selectHttpNegotiatedProtocol(Some("http/1.1"))))
        @Expect(isNegotiatedHttp11(selectHttpNegotiatedProtocol(None<String>)))
        var rejected = false
        try { let _ = selectHttpNegotiatedProtocol(Some("acme/1")) }
        catch (_: IllegalArgumentException) { rejected = true }
        @Expect(rejected)
    }

    @TestCase
    func oneConnectionIsSharedUntilPeerStreamCapacityIsFull(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(10u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let leases = ArrayList<Http2PoolLease>()

        for (_ in 0..10) { leases.add(pool.acquire(key, PoolNoopGoAwayListener(), factory)) }

        @Expect(factory.createCalls.load(), 1)
        let full = pool.snapshot()
        @Expect(full.connections, 1)
        @Expect(full.activeStreams, 10)
        @Expect(full.availableStreamCapacity, 0)

        leases.add(pool.acquire(key, PoolNoopGoAwayListener(), factory))
        @Expect(factory.createCalls.load(), 2)
        @Expect(pool.snapshot().connections, 2)

        for (lease in leases) {
            factory.finish(lease)
            pool.release(lease)
        }
        @Expect(pool.snapshot().activeStreams, 0)
        pool.close()
    }

    @TestCase
    func concurrentFirstUseDoesNotCreateAConnectionStampede(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(32u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let pending = ArrayList<Future<Http2PoolLease>>()
        for (_ in 0..32) {
            pending.add(spawn { pool.acquire(key, PoolNoopGoAwayListener(), factory) })
        }
        let leases = ArrayList<Http2PoolLease>()
        for (future in pending) { leases.add(future.get(Duration.second)) }

        @Expect(factory.createCalls.load(), 1)
        @Expect(pool.snapshot().activeStreams, 32)
        for (lease in leases) { factory.finish(lease); pool.release(lease) }
        pool.close()
    }

    @TestCase
    func completeSecurityKeyPreventsCrossContextReuse(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(100u32)
        let first = pool.acquire(
            poolKey("origin.example", "h2,http/1.1"), PoolNoopGoAwayListener(), factory
        )
        let second = pool.acquire(
            poolKey("origin.example", "h2"), PoolNoopGoAwayListener(), factory
        )

        @Expect(factory.createCalls.load(), 2)
        @Expect(pool.snapshot().connections, 2)
        factory.finish(first); pool.release(first)
        factory.finish(second); pool.release(second)
        pool.close()
    }

    @TestCase
    func drainingConnectionRetainsExistingStreamButReceivesNoNewLease(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(8u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let existing = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        let firstConnection = factory.connection(0)
        firstConnection.beginDrain()

        let replacement = pool.acquire(key, PoolNoopGoAwayListener(), factory)

        @Expect(factory.createCalls.load(), 2)
        @Expect(existing.connectionId != replacement.connectionId)
        @Expect(firstConnection.activeStreamCount, 1)
        factory.finish(existing)
        pool.release(existing)
        @Expect(firstConnection.closeCalls.load(), 1)
        factory.finish(replacement)
        pool.release(replacement)
        pool.close()
    }

    @TestCase
    func fullBoundedPoolHonorsOneCallerDeadline(): Unit {
        let pool = Http2ConnectionPool(config: Http2ConnectionPoolConfig(
            maximumConnections: 1,
            maximumConnectionsPerKey: 1,
            maximumWaiters: 1
        ))
        let factory = PoolFakeFactory(1u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let lease = pool.acquire(key, PoolNoopGoAwayListener(), factory)

        var timedOut = false
        try {
            let _ = pool.acquire(
                key,
                PoolNoopGoAwayListener(),
                factory,
                context: OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
            )
        } catch (error: NetworkException) {
            timedOut = isPoolDeadline(error.category)
        }
        @Expect(timedOut)
        @Expect(factory.createCalls.load(), 1)
        factory.finish(lease)
        pool.release(lease)
        pool.close()
    }

    @TestCase
    func poolCloseAbortsEverySharedConnectionExactlyOnce(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(1u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let _ = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        let _ = pool.acquire(key, PoolNoopGoAwayListener(), factory)

        pool.close()
        pool.close()

        @Expect(factory.createCalls.load(), 2)
        for (connection in factory.connections()) { @Expect(connection.abortCalls.load(), 1) }
    }
}

private class PoolFakeFactory <: Http2MultiplexedConnectionFactory {
    private let capacity: UInt32
    private let mutex = Mutex()
    private let created = ArrayList<PoolFakeConnection>()
    let createCalls = AtomicInt64(0)

    init(capacity: UInt32) { this.capacity = capacity }

    public func create(_: HttpConnectionPoolKey, _: OperationContext): Http2MultiplexedConnection {
        let value = PoolFakeConnection(capacity)
        synchronized(mutex) { created.add(value) }
        let _ = createCalls.fetchAdd(1)
        value
    }

    func connection(index: Int64): PoolFakeConnection { synchronized(mutex) { created[index] } }
    func connections(): Array<PoolFakeConnection> { synchronized(mutex) { created.toArray() } }
    func finish(lease: Http2PoolLease): Unit {
        for (connection in connections()) {
            if (connection.has(lease.admission.stream.id)) {
                connection.finish(lease.admission.stream.id)
                return
            }
        }
        throw Exception("pooled HTTP/2 stream owner was not found")
    }
}

private class PoolFakeConnection <: Http2MultiplexedConnection {
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    private let registry: Http2StreamRegistry
    private let flow = Http2FlowController()
    private let writer = Http2WriteScheduler(PoolNoopTransport())
    private let goAway: Http2GoAwayManager
    private let mutex = Mutex()
    private var closed = false
    let closeCalls = AtomicInt64(0)
    let abortCalls = AtomicInt64(0)

    init(capacity: UInt32) {
        let limits = Http2Limits(maxConcurrentStreams: capacity)
        registry = Http2StreamRegistry(Http2ConnectionRole.Client, limits: limits)
        goAway = Http2GoAwayManager(machine, registry, flow, writer, limits: limits)
        let _ = machine.start()
        let _ = machine.receive(encodeHttp2Settings([]))
        registry.updatePeerMaxConcurrentStreams(capacity)
    }

    public prop activeStreamCount: Int64 { get() { registry.activeLocalCount } }
    public prop streamCapacity: UInt32 { get() { registry.peerMaxConcurrentStreams } }
    public prop acceptingNewStreams: Bool {
        get() { synchronized(mutex) { !closed } && goAway.acceptingNewStreams }
    }

    public func openStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2PoolStreamClaim {
        if (!acceptingNewStreams) { throw Http2StreamLimitException("fake connection is draining") }
        let value = goAway.openLocal(listener, endStream: endStream)
        Http2PoolStreamClaim(value.stream, value.registration)
    }

    public func close(): Unit {
        synchronized(mutex) { closed = true }
        let _ = closeCalls.fetchAdd(1)
    }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    public func abort(reason!: AbortReason): Unit {
        let _ = reason
        let claimed = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (claimed) { let _ = abortCalls.fetchAdd(1) }
    }

    func beginDrain(): Unit { let _ = machine.beginDrain() }
    func has(id: Http2StreamId): Bool { registry.stream(id).isSome() }
    func finish(id: Http2StreamId): Unit {
        registry.localEnd(id)
        registry.peerEnd(id)
        let _ = flow.closeStream(id)
    }
}

private class PoolNoopTransport <: DuplexTransport {
    public prop info: TransportInfo { get() { TransportInfo("http2-pool-test") } }
    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }
    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        source.length
    }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason }
}

private class PoolNoopGoAwayListener <: Http2GoAwayListener {
    public func connectionGoAway(_: Http2GoAwayException): Unit {}
}

private func poolKey(host: String, alpn: String): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", host, 443u16, None<String>, "default", "tls-context",
        "trust-context", "client-identity", "provider", alpn
    )
}

private func isNegotiatedHttp2(value: HttpNegotiatedProtocol): Bool {
    match (value) { case HttpNegotiatedProtocol.Http2 => true; case _ => false }
}
private func isNegotiatedHttp11(value: HttpNegotiatedProtocol): Bool {
    match (value) { case HttpNegotiatedProtocol.Http11 => true; case _ => false }
}
private func isPoolDeadline(value: NetworkErrorCategory): Bool {
    match (value) { case NetworkErrorCategory.DeadlineExceeded => true; case _ => false }
}
