package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.Mutex
import std.time.*
import wirestack.internal as internal
import wirestack.internal.transport.*

public class Http1ConnectionPoolConfig {
    public let maximumConnections: Int64
    public let maximumConnectionsPerKey: Int64
    public let maximumIdleConnections: Int64
    public let maximumWaiters: Int64
    public let idleTimeout: Duration

    public init(
        maximumConnections!: Int64 = 128,
        maximumConnectionsPerKey!: Int64 = 16,
        maximumIdleConnections!: Int64 = 32,
        maximumWaiters!: Int64 = 256,
        idleTimeout!: Duration = 90 * Duration.second
    ) {
        if (maximumConnections <= 0 || maximumConnections > 65536 ||
            maximumConnectionsPerKey <= 0 || maximumConnectionsPerKey > maximumConnections ||
            maximumIdleConnections < 0 || maximumIdleConnections > maximumConnections ||
            maximumWaiters < 0 || maximumWaiters > 65536 || idleTimeout <= Duration.Zero) {
            throw IllegalArgumentException("HTTP/1 connection pool limits are invalid")
        }
        this.maximumConnections = maximumConnections
        this.maximumConnectionsPerKey = maximumConnectionsPerKey
        this.maximumIdleConnections = maximumIdleConnections
        this.maximumWaiters = maximumWaiters
        this.idleTimeout = idleTimeout
    }
}

public interface Http1ConnectionFactory {
    func create(
        key: HttpConnectionPoolKey,
        context: OperationContext,
        resourceLease: ?internal.HttpResourceLease
    ): Http1ClientConnection
}
/** A unique claim on one connection. It cannot be duplicated or returned twice. */
public class Http1PoolLease {
    public let connection: Http1ClientConnection
    internal let id: Int64
    internal let key: HttpConnectionPoolKey

    internal init(id: Int64, key: HttpConnectionPoolKey, connection: Http1ClientConnection) {
        this.id = id
        this.key = key
        this.connection = connection
    }
}

public struct Http1ConnectionPoolSnapshot {
    public let connections: Int64
    public let idleConnections: Int64
    public let reservations: Int64
    public let waiters: Int64
    public let closed: Bool

    public init(connections: Int64, idleConnections: Int64, reservations: Int64, waiters: Int64, closed: Bool) {
        this.connections = connections
        this.idleConnections = idleConnections
        this.reservations = reservations
        this.waiters = waiters
        this.closed = closed
    }
}

private class Http1PoolEntry {
    var id: Int64
    let key: HttpConnectionPoolKey
    let connection: Http1ClientConnection
    let resourceLease: ?internal.HttpResourceLease
    var leased: Bool
    var transferred = false
    var idleSince: MonoTime
    let createdAt: MonoTime

    init(id: Int64, key: HttpConnectionPoolKey, connection: Http1ClientConnection,
        resourceLease: ?internal.HttpResourceLease, leased: Bool, idleSince: MonoTime) {
        this.id = id
        this.key = key
        this.connection = connection
        this.resourceLease = resourceLease
        this.leased = leased
        this.idleSince = idleSince
        this.createdAt = idleSince
    }
}

private enum Http1PoolDecision {
    | Reuse(Http1PoolLease)
    | Reserve(Int64)
    | Discard(Http1ClientConnection, ?internal.HttpResourceLease)
}

/** Bounded, cancellation-aware HTTP/1 connection pool with complete-key isolation. */
public class Http1ConnectionPool <: Resource {
    private let config: Http1ConnectionPoolConfig
    private let clock: MonotonicClock
    private let resourceBudget: ?internal.HttpResourceBudget
    private let admissionQueue: HttpPoolAdmissionQueue
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entries = ArrayList<Http1PoolEntry>()
    private var reservations = ArrayList<HttpConnectionPoolKey>()
    private var nextId: Int64 = 1
    private var waiters: Int64 = 0
    private var closed = false
    private var retiring = false

    public init(
        config!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        clock!: MonotonicClock = SystemMonotonicClock(),
        resourceBudget!: ?internal.HttpResourceBudget = None<internal.HttpResourceBudget>
    ) {
        this.config = config
        this.clock = clock
        this.resourceBudget = resourceBudget
        this.admissionQueue = HttpPoolAdmissionQueue(config.maximumWaiters)
    }

    public func acquire(
        key: HttpConnectionPoolKey,
        factory: Http1ConnectionFactory,
        context!: OperationContext = OperationContext.background()
    ): Http1PoolLease {
        let poolContext = context.forStage(OperationTimeoutStage.ConnectionPool)
        let registration = poolContext.cancellation.register { => wake() }
        try {
            while (true) {
                match (decide(key, poolContext)) {
                    case Http1PoolDecision.Reuse(lease) =>
                        emitPoolAcquired(poolContext, lease.id, NetworkEventOutcome.Reused)
                        return lease
                    case Http1PoolDecision.Discard(connection, resourceLease) =>
                        closeQuietly(connection)
                        closeOptionalResourceLease(resourceLease)
                    case Http1PoolDecision.Reserve(id) =>
                        var reservationOutstanding = true
                        var resourceLease = None<internal.HttpResourceLease>
                        try {
                            resourceLease = match (resourceBudget) {
                                case Some(budget) => Some(budget.acquireConnection(
                                    httpResourceOwnerForPoolKey(key), poolContext
                                ))
                                case None => None<internal.HttpResourceLease>
                            }
                            let connection = factory.create(key, context, resourceLease)
                            if (let Some(value) <- resourceLease) { value.activate() }
                            let accepted = synchronized(mutex) {
                                removeReservation(key)
                                reservationOutstanding = false
                                if (closed) {
                                    changed.notifyAll()
                                    false
                                } else {
                                    entries.add(Http1PoolEntry(
                                        id, key, connection, resourceLease, true, clock.now()
                                    ))
                                    resourceLease = None<internal.HttpResourceLease>
                                    changed.notifyAll()
                                    true
                                }
                            }
                            if (!accepted) {
                                closeQuietly(connection)
                                closeOptionalResourceLease(resourceLease)
                                resourceLease = None<internal.HttpResourceLease>
                                throw poolClosed()
                            }
                            let lease = Http1PoolLease(id, key, connection)
                            emitPoolAcquired(poolContext, lease.id, NetworkEventOutcome.Succeeded)
                            return lease
                        } catch (error: Exception) {
                            closeOptionalResourceLease(resourceLease)
                            resourceLease = None<internal.HttpResourceLease>
                            if (reservationOutstanding) {
                                synchronized(mutex) {
                                    removeReservation(key)
                                    reservationOutstanding = false
                                    changed.notifyAll()
                                }
                            }
                            emitPoolAcquireFailed(poolContext, error)
                            throw error
                        }
                }
            }
            throw poolClosed()
        } finally {
            registration.unregister()
        }
    }

    /** Adopts one negotiated connection while preserving its aggregate lease. */
    public func adopt(
        key: HttpConnectionPoolKey,
        connection: Http1ClientConnection,
        context!: OperationContext = OperationContext.background(),
        resourceLease!: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
    ): Http1PoolLease {
        try {
            preflight(context.forStage(OperationTimeoutStage.ConnectionPool))
            if (let Some(value) <- resourceLease) { value.activate() }
            let lease = synchronized(mutex) {
                if (closed) { throw poolClosed() }
                if (entries.size + reservations.size >= config.maximumConnections ||
                    countForKey(key) >= config.maximumConnectionsPerKey) {
                    throw poolExhausted()
                }
                let id = nextId
                nextId++
                entries.add(Http1PoolEntry(id, key, connection, resourceLease, true, clock.now()))
                changed.notifyAll()
                Http1PoolLease(id, key, connection)
            }
            emitPoolAcquired(context, lease.id, NetworkEventOutcome.Succeeded)
            lease
        } catch (error: Exception) {
            closeOptionalResourceLease(resourceLease)
            throw error
        }
    }
    /** Transfers close ownership while retaining the aggregate lease until session cleanup. */
    public func transfer(lease: Http1PoolLease): Unit {
        synchronized(mutex) {
            let index = findEntry(lease.id)
            if (index < 0 || closed) { throw poolClosed() }
            let entry = entries[index]
            if (!entry.leased || entry.key != lease.key) { throw poolClosed() }
            match (entry.connection.currentState()) {
                case Http1ClientConnectionState.Upgraded => entry.transferred = true
                case _ => throw IllegalStateException("only upgraded HTTP/1 ownership can transfer")
            }
        }
    }


    /** Returns only a ready connection. Unsafe and failed claims are discarded; stale claims are ignored. */
    public func release(lease: Http1PoolLease,
        context!: OperationContext = OperationContext.background()): Unit {
        var closeConnection: ?Http1ClientConnection = None<Http1ClientConnection>
        var closeResourceLease: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
        var outcome = None<NetworkEventOutcome>
        synchronized(mutex) {
            let index = findEntry(lease.id)
            if (index < 0) { return }
            let entry = entries[index]
            if (!entry.leased) { return }
            let ready = match (entry.connection.currentState()) {
                case Http1ClientConnectionState.Ready => true
                case _ => false
            }
            let now = clock.now()
            let nextWaitingKey = admissionQueue.firstEligibleKey({ candidate =>
                candidate == entry.key || findIdle(candidate) >= 0 ||
                    countForKey(candidate) < config.maximumConnectionsPerKey
            })
            let nextNeedsNewSlot = match (nextWaitingKey) {
                case Some(value) => value != entry.key && findIdle(value) < 0
                case None => false
            }
            let cedeFullSlot = entries.size + reservations.size >= config.maximumConnections &&
                nextNeedsNewSlot
            let expired = now - entry.createdAt >= HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second
            let reusable = entry.leased && entry.key == lease.key && ready && !closed && !retiring && !expired &&
                !cedeFullSlot && idleCount() < config.maximumIdleConnections
            if (reusable) {
                entry.leased = false
                entry.idleSince = clock.now()
                outcome = Some(NetworkEventOutcome.Released)
            } else {
                let removed = entries.remove(at: index)
                closeConnection = Some(removed.connection)
                closeResourceLease = removed.resourceLease
                outcome = Some(NetworkEventOutcome.Discarded)
            }
            changed.notifyAll()
        }
        if (let Some(connection) <- closeConnection) {
            closeQuietly(connection)
            closeOptionalResourceLease(closeResourceLease)
            emitPoolConnectionClosed(context, lease.id)
        }
        if (let Some(value) <- outcome) {
            emitPoolReleased(context, lease.id, value)
        }
    }

    /** Removes a lease after protocol/I/O failure without making it reusable. */
    public func discard(lease: Http1PoolLease,
        context!: OperationContext = OperationContext.background()): Unit {
        var connection: ?Http1ClientConnection = None<Http1ClientConnection>
        var resourceLease: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
        synchronized(mutex) {
            let index = findEntry(lease.id)
            if (index >= 0 && entries[index].leased) {
                let removed = entries.remove(at: index)
                connection = Some(removed.connection)
                resourceLease = removed.resourceLease
                changed.notifyAll()
            }
        }
        if (let Some(value) <- connection) {
            closeQuietly(value)
            closeOptionalResourceLease(resourceLease)
            emitPoolReleased(context, lease.id, NetworkEventOutcome.Discarded)
            emitPoolConnectionClosed(context, lease.id)
        }
    }

    public func snapshot(): Http1ConnectionPoolSnapshot {
        synchronized(mutex) {
            Http1ConnectionPoolSnapshot(entries.size, idleCount(), reservations.size, waiters, closed)
        }
    }

    /** Stops new claims, evicts idle entries, and lets reserved/leased exchanges finish. */
    public func retire(): Unit {
        let claimed = synchronized(mutex) {
            retiring = true
            let result = ArrayList<Http1PoolEntry>()
            var index: Int64 = entries.size
            while (index > 0) {
                index--
                if (!entries[index].leased) { result.add(entries.remove(at: index)) }
            }
            changed.notifyAll()
            result.toArray()
        }
        for (entry in claimed) {
            closeQuietly(entry.connection)
            closeOptionalResourceLease(entry.resourceLease)
        }
    }

    public func close(): Unit {
        let claimed = synchronized(mutex) {
            if (closed) {
                Array<Http1PoolEntry>()
            } else {
                closed = true
                let result = ArrayList<Http1PoolEntry>()
                let transferred = ArrayList<Http1PoolEntry>()
                for (entry in entries) {
                    if (entry.transferred) { transferred.add(entry) } else { result.add(entry) }
                }
                entries = transferred
                changed.notifyAll()
                result.toArray()
            }
        }
        for (entry in claimed) {
            closeQuietly(entry.connection)
            closeOptionalResourceLease(entry.resourceLease)
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func decide(key: HttpConnectionPoolKey, context: OperationContext): Http1PoolDecision {
        var waiterId: Int64 = 0
        try {
            synchronized(mutex) {
                while (true) {
                    preflight(context)
                    if (closed || retiring) { throw poolClosed() }

                    let stale = findStaleIdle(clock.now())
                    if (stale >= 0) {
                        let removed = entries.remove(at: stale)
                        changed.notifyAll()
                        return Http1PoolDecision.Discard(removed.connection, removed.resourceLease)
                    }

                    let idle = findIdle(key)
                    let canReuse = idle >= 0
                    let canReserve = entries.size + reservations.size < config.maximumConnections &&
                        countForKey(key) < config.maximumConnectionsPerKey
                    let next = admissionQueue.firstEligible({ candidate => canAcquire(candidate) })
                    let ownsTurn = match (next) {
                        case Some(waiter) => waiter.id == waiterId
                        case None => waiterId == 0
                    }
                    if ((canReuse || canReserve) && ownsTurn) {
                        if (waiterId != 0) {
                            removeWaiterLocked(waiterId, true)
                            waiterId = 0
                        }
                        if (canReuse) {
                            let entry = entries[idle]
                            entry.leased = true
                            entry.id = nextId
                            nextId++
                            return Http1PoolDecision.Reuse(
                                Http1PoolLease(entry.id, entry.key, entry.connection)
                            )
                        }
                        let id = nextId
                        nextId++
                        reservations.add(key)
                        return Http1PoolDecision.Reserve(id)
                    }

                    if (waiterId == 0) {
                        waiterId = match (admissionQueue.enqueue(key)) {
                            case Some(id) => id
                            case None => throw poolExhausted()
                        }
                        waiters++
                        changed.notifyAll()
                    }
                    waitForChange(context)
                }
                throw poolClosed()
            }
        } finally {
            if (waiterId != 0) {
                synchronized(mutex) { removeWaiterLocked(waiterId, false) }
            }
        }
    }

    private func removeWaiterLocked(id: Int64, granted: Bool): Unit {
        if (admissionQueue.remove(id, granted)) {
            waiters--
            changed.notifyAll()
        }
    }
    private func canAcquire(key: HttpConnectionPoolKey): Bool {
        findIdle(key) >= 0 ||
            (entries.size + reservations.size < config.maximumConnections &&
                countForKey(key) < config.maximumConnectionsPerKey)
    }

    private func waitForChange(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) =>
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw poolTimedOut() }
                changed.wait(timeout: remaining)
            case None => changed.wait()
        }
    }

    private func preflight(context: OperationContext): Unit {
        if (context.isCancellationRequested()) { throw poolCancelled() }
        if (context.isDeadlineExceeded()) { throw poolTimedOut() }
    }

    private func findIdle(key: HttpConnectionPoolKey): Int64 {
        for (index in 0..entries.size) {
            if (!entries[index].leased && entries[index].key == key) { return index }
        }
        -1
    }

    private func findStaleIdle(now: MonoTime): Int64 {
        for (index in 0..entries.size) {
            let entry = entries[index]
            if (!entry.leased && (entry.connection.isClosed() ||
                now - entry.idleSince >= config.idleTimeout ||
                now - entry.createdAt >= HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS * Duration.second)) {
                return index
            }
        }
        -1
    }

    private func findEntry(id: Int64): Int64 {
        for (index in 0..entries.size) { if (entries[index].id == id) { return index } }
        -1
    }

    private func idleCount(): Int64 {
        var count: Int64 = 0
        for (entry in entries) { if (!entry.leased) { count++ } }
        count
    }

    private func countForKey(key: HttpConnectionPoolKey): Int64 {
        var count: Int64 = 0
        for (entry in entries) { if (entry.key == key) { count++ } }
        for (reserved in reservations) { if (reserved == key) { count++ } }
        count
    }

    private func removeReservation(key: HttpConnectionPoolKey): Unit {
        for (index in 0..reservations.size) {
            if (reservations[index] == key) {
                let _ = reservations.remove(at: index)
                return
            }
        }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }

    internal func waitUntilWaiters(expected: Int64, timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        synchronized(mutex) {
            while (waiters < expected && !closed) {
                let remaining = expiresAt - MonoTime.now()
                if (remaining <= Duration.Zero) { return false }
                changed.wait(timeout: remaining)
            }
            waiters >= expected
        }
    }
}

private func closeQuietly(connection: Http1ClientConnection): Unit {
    try { connection.close() } catch (_: Exception) {}
}

private func closeOptionalResourceLease(lease: ?internal.HttpResourceLease): Unit {
    match (lease) {
        case Some(value) => value.close()
        case None => ()
    }
}
private func emitPoolAcquired(context: OperationContext, id: Int64,
    outcome: NetworkEventOutcome): Unit {
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.HttpConnectionAcquired,
        outcome,
        trace: context.trace,
        phase: Some(NetworkPhase.PoolAcquire),
        connectionId: Some(id)
    ))
}

private func emitPoolAcquireFailed(context: OperationContext, error: Exception): Unit {
    let code = match (error) {
        case value: NetworkException => Some(value.code)
        case _ => Some(NetworkErrorCode.SystemFailure)
    }
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.HttpConnectionAcquired,
        NetworkEventOutcome.Failed,
        trace: context.trace,
        phase: Some(NetworkPhase.PoolAcquire),
        errorCode: code
    ))
}

private func emitPoolReleased(context: OperationContext, id: Int64,
    outcome: NetworkEventOutcome): Unit {
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.HttpConnectionReleased,
        outcome,
        trace: context.trace,
        phase: Some(NetworkPhase.PoolAcquire),
        connectionId: Some(id)
    ))
}

private func emitPoolConnectionClosed(context: OperationContext, id: Int64): Unit {
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.ConnectionClosed,
        NetworkEventOutcome.Succeeded,
        trace: context.trace,
        phase: Some(NetworkPhase.TransportClose),
        connectionId: Some(id)
    ))
}

private func poolClosed(): NetworkException {
    NetworkException(NetworkErrorCategory.Closed, NetworkPhase.PoolAcquire, NetworkErrorCode.Closed,
        "HTTP/1 connection pool is closed", retryability: Retryability.Never)
}

private func poolExhausted(): NetworkException {
    NetworkException(NetworkErrorCategory.ResourceExhausted, NetworkPhase.PoolAcquire,
        NetworkErrorCode.ResourceExhausted, "HTTP/1 connection pool waiter limit exceeded",
        retryability: Retryability.Temporary)
}

private func poolCancelled(): NetworkException {
    NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.PoolAcquire, NetworkErrorCode.Cancelled,
        "HTTP/1 connection acquisition cancelled", retryability: Retryability.Never)
}

private func poolTimedOut(): NetworkException {
    NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.PoolAcquire, NetworkErrorCode.TimedOut,
        "HTTP/1 connection acquisition deadline exceeded", retryability: Retryability.Temporary)
}
