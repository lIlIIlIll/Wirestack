package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http2.*
import wirestack.internal.transport.*
import wirestack.internal as internal
import wirestack as api

private class Http2PoolTestClock <: MonotonicClock {
    private var current: MonoTime
    init() { current = MonoTime.now() }
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

@Test
class Http2ConnectionPoolTest {
    @TestCase
    func throwingReentrantH2ObserverSeesAdmittedNotReservedStreams(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(8u32)
        let sink = ReentrantH2PoolObservationSink(pool)
        let context = OperationContext(eventSink: Some(sink))
        let key = poolKey("example.test", "h2")
        let first = pool.acquire(key, PoolNoopGoAwayListener(), factory, context: context)
        let second = pool.acquire(key, PoolNoopGoAwayListener(), factory, context: context)
        @Expect(sink.acquired.load(), 2)
        @Expect(sink.pendingAtAcquire.load(), 0)
        factory.connection(0).finish(first.admission.stream.id)
        pool.release(first, context: context)
        factory.connection(0).finish(second.admission.stream.id)
        pool.release(second, context: context)
        pool.retire(); pool.close()
        @Expect(pool.observationSnapshot().activeStreams, 0)
        @Expect(pool.observationSnapshot().idleConnections, 0)
    }

    @TestCase
    func observedSnapshotsTrackPhysicalOwnersAndConnectionLocalStreams(): Unit {
        let one = Http2ConnectionPool()
        let two = Http2ConnectionPool()
        let factory = PoolFakeFactory(8u32)
        let sink = api.NetworkEventBuffer(capacity: 64)
        let context = OperationContext(eventSink: Some(sink), requestId: Some(71), attemptId: Some(72))
        let key = poolKey("example.test", "h2")
        let first = one.acquire(key, PoolNoopGoAwayListener(), factory, context: context)
        let other = two.acquire(key, PoolNoopGoAwayListener(), factory, context: context)
        @Expect(first.connectionId != other.connectionId)
        @Expect(first.admission.stream.id.value, other.admission.stream.id.value)
        let shared = one.acquire(key, PoolNoopGoAwayListener(), factory, context: context)
        @Expect(shared.connectionId, first.connectionId)
        @Expect(shared.admission.stream.id.value != first.admission.stream.id.value)
        @Expect(one.observationSnapshot().leasedConnections, 1)
        @Expect(one.observationSnapshot().activeStreams, 2)
        @Expect(one.observationSnapshot().reservedStreams, 0)
        one.retire()
        @Expect(one.observationSnapshot().drainingConnections, 1)
        factory.connection(0).finish(first.admission.stream.id)
        one.release(first, context: context)
        @Expect(one.observationSnapshot().activeStreams, 1)
        factory.connection(0).finish(shared.admission.stream.id)
        one.release(shared, context: context)
        @Expect(one.observationSnapshot().leasedConnections, 0)
        @Expect(one.observationSnapshot().drainingConnections, 0)
        @Expect(one.observationSnapshot().activeStreams, 0)
        factory.connection(1).finish(other.admission.stream.id)
        two.release(other, context: context); two.close(); one.close()
        var acquired: Int64 = 0
        var released: Int64 = 0
        var closed: Int64 = 0
        for (event in sink.drain()) {
            match (event.kind) {
                case NetworkEventKind.HttpConnectionAcquired => acquired++
                case NetworkEventKind.HttpConnectionReleased => released++
                case NetworkEventKind.ConnectionClosed => closed++
                case NetworkEventKind.Http2StreamOpened | NetworkEventKind.Http2StreamClosed => @Fail("pool duplicated protocol stream events")
                case _ => ()
            }
        }
        @Expect(acquired, 3)
        @Expect(released, 3)
        @Expect(closed, 2)
    }

    @TestCase
    func retiringH2BlocksNewStreamsAndKeepsExistingClaimsUntilTermination(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(8u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let active = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        pool.retire()
        @Expect(!active.connection.isClosed())
        @ExpectThrows[NetworkException](pool.acquire(key, PoolNoopGoAwayListener(), factory))
        @Expect(factory.createCalls.load(), 1)
        factory.finish(active)
        pool.release(active)
        @Expect(active.connection.isClosed())
        @Expect(pool.snapshot().connections, 0)
        pool.release(active)
        pool.close()
    }

    @TestCase
    func retirementPreservesStartedH2AdmissionButCloseRejectsItsLateResult(): Unit {
        for (strict in [false, true]) {
            let pool = Http2ConnectionPool()
            let gate = PoolAdmissionGate()
            let factory = PoolGatedFactory(gate)
            let key = poolKey("origin.example", "h2,http/1.1")
            let pending = spawn {
                try { Some(pool.acquire(key, PoolNoopGoAwayListener(), factory)) }
                catch (_: NetworkException) { None<Http2PoolLease> }
            }
            gate.waitUntilEntered()
            @Expect(pool.observationSnapshot().connectingConnections, 1)
            @Expect(pool.observationSnapshot().reservedStreams, 1)
            if (strict) { pool.close() } else { pool.retire() }
            gate.release()
            let result = pending.get(Duration.second)
            if (strict) {
                @Expect(result.isNone())
                @Expect(factory.connectionClosed)
            } else {
                let lease = result.getOrThrow()
                @Expect(!factory.connectionClosed)
                factory.finish(lease); pool.release(lease)
                @Expect(factory.connectionClosed)
            }
            @Expect(pool.snapshot().connections, 0)
            @Expect(pool.snapshot().reservations, 0)
            pool.close()
        }
    }

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
    func newConnectionIsPublishedOnlyAfterItsFirstStreamIsAdmitted(): Unit {
        let pool = Http2ConnectionPool()
        let gate = PoolAdmissionGate()
        let factory = PoolGatedFactory(gate)
        let key = poolKey("origin.example", "h2,http/1.1")
        let pending = spawn { pool.acquire(key, PoolNoopGoAwayListener(), factory) }

        gate.waitUntilEntered()
        let beforePublication = pool.snapshot()
        gate.release()
        let lease = pending.get(Duration.second)

        @Expect(beforePublication.connections, 0)
        @Expect(beforePublication.reservations, 1)
        @Expect(pool.snapshot().activeStreams, 1)
        factory.finish(lease)
        pool.release(lease)
        pool.close()
    }

    @TestCase
    func closeRacingUnpublishedAdmissionReleasesConnectionOwners(): Unit {
        let pool = Http2ConnectionPool()
        let gate = PoolAdmissionGate()
        let factory = PoolGatedFactory(gate)
        let key = poolKey("origin.example", "h2,http/1.1")
        let pending = spawn { pool.acquire(key, PoolNoopGoAwayListener(), factory) }

        gate.waitUntilEntered()
        @Expect(factory.activeStreamCount, 1)
        @Expect(factory.ownedStreamCount, 1)
        try { pool.close() } finally { gate.release() }

        var rejectedAsClosed = false
        try {
            let _ = pending.get(Duration.second)
        } catch (error: NetworkException) {
            rejectedAsClosed = isPoolClosed(error.category)
        }

        @Expect(rejectedAsClosed)
        @Expect(factory.activeStreamCount, 0)
        @Expect(factory.ownedStreamCount, 0)
        @Expect(factory.connectionClosed)
        let terminal = pool.snapshot()
        @Expect(terminal.connections, 0)
        @Expect(terminal.reservations, 0)
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
    func drainingConnectionWaitsForNonLocalOwnersBeforeDiscard(): Unit {
        let pool = Http2ConnectionPool()
        let factory = PoolFakeFactory(8u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let lease = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        let draining = factory.connection(0)
        draining.retainOwner()
        draining.beginDrain()
        factory.finish(lease)
        pool.release(lease)

        @Expect(draining.activeStreamCount, 0)
        @Expect(draining.ownedStreamCount, 1)
        @Expect(draining.closeCalls.load(), 0)
        @Expect(pool.snapshot().ownedStreams, 1)

        draining.releaseOwner()
        let replacement = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        @Expect(draining.closeCalls.load(), 1)
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
    @TestCase
    func drainsExpiredHttp2ConnectionAfterActiveStreamCompletion(): Unit {
        let clock = Http2PoolTestClock()
        let pool = Http2ConnectionPool(
            config: Http2ConnectionPoolConfig(),
            resourceBudget: None<internal.HttpResourceBudget>,
            clock: clock
        )
        let factory = PoolFakeFactory(1u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let expired = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        let oldConnection = factory.connection(0)
        @Expect(oldConnection.activeStreamCount, 1)

        clock.advance(HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second)
        @Expect(oldConnection.closeCalls.load(), 0)
        factory.finish(expired)
        pool.release(expired)

        @Expect(oldConnection.closeCalls.load(), 1)
        @Expect(pool.snapshot().connections, 0)
        let replacement = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        @Expect(replacement.connectionId != expired.connectionId)
        @Expect(factory.createCalls.load(), 2)
        factory.finish(replacement)
        pool.release(replacement)
        pool.close()
    }

    @TestCase
    func expiresConnectionsAtMaximumLifetime(): Unit {
        let clock = Http2PoolTestClock()
        let pool = Http2ConnectionPool(
            config: Http2ConnectionPoolConfig(),
            resourceBudget: None<internal.HttpResourceBudget>,
            clock: clock
        )
        let factory = PoolFakeFactory(1u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let expired = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        factory.finish(expired)
        pool.release(expired)
        clock.advance(HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second)

        let replacement = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        @Expect(factory.createCalls.load(), 2)
        @Expect(pool.snapshot().connections, 1)
        factory.finish(replacement)
        pool.release(replacement)
        pool.close()
    }

    @TestCase
    func admissionRotatesOriginsAndYieldsAFullHttp2PoolSlot(): Unit {
        let pool = Http2ConnectionPool(config: Http2ConnectionPoolConfig(
            maximumConnections: 1, maximumConnectionsPerKey: 1, maximumWaiters: 2
        ))
        let factory = PoolFakeFactory(1u32)
        let key = poolKey("origin.example", "h2,http/1.1")
        let otherKey = poolKey("other.example", "h2,http/1.1")
        let first = pool.acquire(key, PoolNoopGoAwayListener(), factory)
        let sameOrigin = spawn { pool.acquire(key, PoolNoopGoAwayListener(), factory) }
        @Expect(pool.waitUntilWaiters(1, Duration.second))
        let otherOrigin = spawn { pool.acquire(otherKey, PoolNoopGoAwayListener(), factory) }
        @Expect(pool.waitUntilWaiters(2, Duration.second))

        factory.finish(first)
        pool.release(first)
        let second = sameOrigin.get(Duration.second)
        @Expect(factory.createCalls.load(), 1)
        @Expect(pool.snapshot().waiters, 1)

        factory.finish(second)
        pool.release(second)
        let third = otherOrigin.get(Duration.second)
        @Expect(factory.createCalls.load(), 2)
        factory.finish(third)
        pool.release(third)
        pool.close()
    }
}

private class ReentrantH2PoolObservationSink <: NetworkEventSink {
    private let pool: Http2ConnectionPool
    let acquired = AtomicInt64(0)
    let pendingAtAcquire = AtomicInt64(0)
    init(pool: Http2ConnectionPool) { this.pool = pool }
    public func emit(event: NetworkEvent): Unit {
        let snapshot = pool.observationSnapshot()
        match (event.kind) {
            case NetworkEventKind.HttpConnectionAcquired =>
                acquired.fetchAdd(1); pendingAtAcquire.fetchAdd(snapshot.reservedStreams)
            case _ => ()
        }
        throw Exception("fixture H2 observer failure")
    }
}

private class PoolFakeFactory <: Http2MultiplexedConnectionFactory {
    private let capacity: UInt32
    private let mutex = Mutex()
    private let created = ArrayList<PoolFakeConnection>()
    let createCalls = AtomicInt64(0)

    init(capacity: UInt32) { this.capacity = capacity }

    public func create(_: HttpConnectionPoolKey, _: OperationContext,
        _: ?internal.HttpResourceLease): Http2MultiplexedConnection {
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

private class PoolAdmissionGate {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false

    func enter(): Unit {
        synchronized(mutex) {
            entered = true
            changed.notifyAll()
            let deadline = Deadline.after(Duration.second)
            while (!released) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting to release first HTTP/2 stream admission")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func waitUntilEntered(): Unit {
        synchronized(mutex) {
            let deadline = Deadline.after(Duration.second)
            while (!entered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for first HTTP/2 stream admission")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}

private class PoolGatedFactory <: Http2MultiplexedConnectionFactory {
    private let connection: PoolGatedConnection

    init(gate: PoolAdmissionGate) { connection = PoolGatedConnection(gate) }

    public func create(_: HttpConnectionPoolKey, _: OperationContext,
        _: ?internal.HttpResourceLease): Http2MultiplexedConnection {
        connection
    }

    func finish(lease: Http2PoolLease): Unit { connection.finish(lease.admission.stream.id) }
    prop activeStreamCount: Int64 { get() { connection.activeStreamCount } }
    prop ownedStreamCount: Int64 { get() { connection.ownedStreamCount } }
    prop connectionClosed: Bool { get() { connection.isClosed() } }
}

private class PoolGatedConnection <: Http2MultiplexedConnection {
    private let delegate = PoolFakeConnection(1u32)
    private let gate: PoolAdmissionGate
    private let firstAdmission = AtomicBool(true)

    init(gate: PoolAdmissionGate) { this.gate = gate }

    public prop activeStreamCount: Int64 { get() { delegate.activeStreamCount } }
    public prop ownedStreamCount: Int64 { get() { delegate.ownedStreamCount } }
    public prop streamCapacity: UInt32 { get() { delegate.streamCapacity } }
    public prop acceptingNewStreams: Bool { get() { delegate.acceptingNewStreams } }

    public func openStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2PoolStreamClaim {
        let admitted = delegate.openStream(listener, endStream)
        if (firstAdmission.compareAndSwap(true, false)) { gate.enter() }
        admitted
    }

    public func close(): Unit { delegate.close() }
    public func isClosed(): Bool { delegate.isClosed() }
    public func abort(reason!: AbortReason): Unit { delegate.abort(reason: reason) }
    func finish(id: Http2StreamId): Unit { delegate.finish(id) }
}

private class PoolFakeConnection <: Http2MultiplexedConnection {
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    private let registry: Http2StreamRegistry
    private let flow = Http2FlowController()
    private let writer = Http2WriteScheduler(PoolNoopTransport())
    private let goAway: Http2GoAwayManager
    private let mutex = Mutex()
    private var closed = false
    private var retainedOwners: Int64 = 0
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
    public prop ownedStreamCount: Int64 {
        get() { registry.activeCount + synchronized(mutex) { retainedOwners } }
    }
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
        if (claimed) {
            let _ = machine.finish(
                code: Http2ErrorCode.InternalError, reason: "fake HTTP/2 connection aborted"
            )
            let _ = registry.closeConnection(machine.completion.getOrThrow())
            flow.close()
            let _ = abortCalls.fetchAdd(1)
        }
    }

    func beginDrain(): Unit { let _ = machine.beginDrain() }
    func retainOwner(): Unit { synchronized(mutex) { retainedOwners++ } }
    func releaseOwner(): Unit { synchronized(mutex) { retainedOwners-- } }
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
private func isPoolClosed(value: NetworkErrorCategory): Bool {
    match (value) { case NetworkErrorCategory.Closed => true; case _ => false }
}
