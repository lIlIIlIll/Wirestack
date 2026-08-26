package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http2.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

private const HTTP_CLIENT_H2_ALPN: String = "h2"
private const HTTP_CLIENT_H1_ALPN: String = "http/1.1"

public enum HttpNegotiatedProtocol {
    | Http2
    | Http11
}

/** The immutable, preference-ordered ALPN offer used by the automatic client. */
public func httpClientAlpnProtocols(): Array<String> { [HTTP_CLIENT_H2_ALPN, HTTP_CLIENT_H1_ALPN] }

/** RFC 7301 absence falls back to HTTP/1.1; an unknown selected protocol fails closed. */
public func selectHttpNegotiatedProtocol(value: ?String): HttpNegotiatedProtocol {
    match (value) {
        case Some("h2") => HttpNegotiatedProtocol.Http2
        case Some("http/1.1") => HttpNegotiatedProtocol.Http11
        case None => HttpNegotiatedProtocol.Http11
        case Some(_) => throw IllegalArgumentException("TLS selected an unsupported HTTP ALPN protocol")
    }
}

/** Pool-facing view of one live HTTP/2 connection. */
public interface Http2MultiplexedConnection <: Resource {
    prop activeStreamCount: Int64
    prop streamCapacity: UInt32
    prop acceptingNewStreams: Bool
    func openStream(listener: Http2GoAwayListener, endStream: Bool): Http2PoolStreamClaim
    func abort(reason!: AbortReason): Unit
}

/** The lifecycle claim returned by one atomic HTTP/2 stream admission. */
public class Http2PoolStreamClaim {
    public let stream: Http2StreamStateMachine
    public let registration: Http2GoAwayRegistration

    internal init(stream: Http2StreamStateMachine, registration: Http2GoAwayRegistration) {
        this.stream = stream
        this.registration = registration
    }
}

/** Adapts the HTTP/2 lifecycle core without duplicating its admission lock. */
public class Http2CorePoolConnection <: Http2MultiplexedConnection {
    private let registry: Http2StreamRegistry
    private let goAway: Http2GoAwayManager
    private let closer: Http2ConnectionCloser

    public init(
        registry: Http2StreamRegistry,
        goAway: Http2GoAwayManager,
        closer: Http2ConnectionCloser
    ) {
        this.registry = registry
        this.goAway = goAway
        this.closer = closer
    }

    public prop activeStreamCount: Int64 { get() { registry.activeLocalCount } }
    public prop streamCapacity: UInt32 { get() { registry.peerMaxConcurrentStreams } }
    public prop acceptingNewStreams: Bool { get() { goAway.acceptingNewStreams && closer.result.isNone() } }

    public func openStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2PoolStreamClaim {
        if (!acceptingNewStreams) { throw Http2StreamLimitException("HTTP/2 connection is draining") }
        let admitted = goAway.openLocal(listener, endStream: endStream)
        Http2PoolStreamClaim(admitted.stream, admitted.registration)
    }

    public func close(): Unit { let _ = closer.close() }
    public func isClosed(): Bool { closer.result.isSome() }
    public func abort(reason!: AbortReason): Unit { let _ = closer.abort(reason: reason) }
}

/** Pool connection that can execute an already-admitted client stream. */
public interface Http2ExecutableConnection <: Http2MultiplexedConnection {
    func executeClaimed(
        request: HttpRequest,
        plan: Http2ClientRequestPlan,
        claim: Http2PoolStreamClaim,
        signal: Http2ClientExecutionSignal,
        context: OperationContext,
        connectionCancellation: CancellationToken,
        onTerminated: () -> Unit
    ): HttpResponse
}

/** Keeps HTTP/1 pool policy separate from the protocol-owned HTTP/2 connection. */
public class Http2ClientPoolConnection <: Http2ExecutableConnection {
    private let connection: Http2ClientConnection

    public init(connection: Http2ClientConnection) { this.connection = connection }

    public prop activeStreamCount: Int64 { get() { connection.activeStreamCount } }
    public prop streamCapacity: UInt32 { get() { connection.streamCapacity } }
    public prop acceptingNewStreams: Bool { get() { connection.acceptingNewStreams } }

    public func openStream(
        listener: Http2GoAwayListener,
        endStream: Bool
    ): Http2PoolStreamClaim {
        let admitted = connection.openStream(listener, endStream)
        Http2PoolStreamClaim(admitted.stream, admitted.registration)
    }

    public func executeClaimed(
        request: HttpRequest,
        plan: Http2ClientRequestPlan,
        claim: Http2PoolStreamClaim,
        signal: Http2ClientExecutionSignal,
        context: OperationContext,
        connectionCancellation: CancellationToken,
        onTerminated: () -> Unit
    ): HttpResponse {
        connection.executeAdmitted(
            request, plan, claim.stream, claim.registration, signal,
            context: context, connectionCancellation: connectionCancellation,
            onTerminated: onTerminated
        )
    }

    public func close(): Unit { connection.close() }
    public func isClosed(): Bool { connection.isClosed() }
    public func abort(reason!: AbortReason = AbortReason.ApplicationAbort): Unit {
        connection.abort(reason: reason)
    }
}

public interface Http2MultiplexedConnectionFactory {
    func create(key: HttpConnectionPoolKey, context: OperationContext): Http2MultiplexedConnection
}

public class Http2ConnectionPoolConfig {
    public let maximumConnections: Int64
    public let maximumConnectionsPerKey: Int64
    public let maximumWaiters: Int64

    public init(
        maximumConnections!: Int64 = 128,
        maximumConnectionsPerKey!: Int64 = 16,
        maximumWaiters!: Int64 = 256
    ) {
        if (maximumConnections <= 0 || maximumConnections > 65536 ||
            maximumConnectionsPerKey <= 0 || maximumConnectionsPerKey > maximumConnections ||
            maximumWaiters < 0 || maximumWaiters > 65536) {
            throw IllegalArgumentException("HTTP/2 connection pool limits are invalid")
        }
        this.maximumConnections = maximumConnections
        this.maximumConnectionsPerKey = maximumConnectionsPerKey
        this.maximumWaiters = maximumWaiters
    }
}

/** One stream claim on a shared connection; it never grants exclusive connection ownership. */
public class Http2PoolLease {
    public let connection: Http2MultiplexedConnection
    public let admission: Http2PoolStreamClaim
    internal let connectionId: Int64
    internal let key: HttpConnectionPoolKey
    private let returned = AtomicBool(false)

    internal init(
        connectionId: Int64,
        key: HttpConnectionPoolKey,
        connection: Http2MultiplexedConnection,
        admission: Http2PoolStreamClaim
    ) {
        this.connectionId = connectionId
        this.key = key
        this.connection = connection
        this.admission = admission
    }

    internal func claimReturn(): Bool { returned.compareAndSwap(false, true) }
}

public struct Http2ConnectionPoolSnapshot {
    public let connections: Int64
    public let activeStreams: Int64
    public let availableStreamCapacity: Int64
    public let reservations: Int64
    public let waiters: Int64
    public let closed: Bool

    public init(
        connections: Int64,
        activeStreams: Int64,
        availableStreamCapacity: Int64,
        reservations: Int64,
        waiters: Int64,
        closed: Bool
    ) {
        this.connections = connections
        this.activeStreams = activeStreams
        this.availableStreamCapacity = availableStreamCapacity
        this.reservations = reservations
        this.waiters = waiters
        this.closed = closed
    }
}

private class Http2PoolEntry {
    let id: Int64
    let key: HttpConnectionPoolKey
    let connection: Http2MultiplexedConnection
    init(id: Int64, key: HttpConnectionPoolKey, connection: Http2MultiplexedConnection) {
        this.id = id
        this.key = key
        this.connection = connection
    }
}

private enum Http2PoolDecision {
    | Reuse(Http2PoolLease)
    | Reserve(Int64)
    | Discard(Http2MultiplexedConnection)
}

/**
 * Complete-key HTTP/2 pool. Connections remain shared and are selected by
 * current peer stream capacity. Draining/GOAWAY connections are never used for
 * new requests, while their existing streams may finish normally.
 */
public class Http2ConnectionPool <: Resource {
    private let config: Http2ConnectionPoolConfig
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entries = ArrayList<Http2PoolEntry>()
    private var reservations = ArrayList<HttpConnectionPoolKey>()
    private var nextId: Int64 = 1
    private var waiters: Int64 = 0
    private var closed = false

    public init(config!: Http2ConnectionPoolConfig = Http2ConnectionPoolConfig()) {
        this.config = config
    }

    public func acquire(
        key: HttpConnectionPoolKey,
        listener: Http2GoAwayListener,
        factory: Http2MultiplexedConnectionFactory,
        context!: OperationContext = OperationContext.background(),
        endStream!: Bool = false
    ): Http2PoolLease {
        let registration = context.cancellation.register { => wakeHttp2Pool() }
        try {
            while (true) {
                match (decide(key, listener, endStream, context)) {
                    case Http2PoolDecision.Reuse(lease) => return lease
                    case Http2PoolDecision.Discard(connection) => closeHttp2Quietly(connection)
                    case Http2PoolDecision.Reserve(id) =>
                        var reservationOutstanding = true
                        try {
                            let created = factory.create(key, context)
                            let admission = try {
                                created.openStream(listener, endStream)
                            } catch (_: Http2StreamLimitException) {
                                synchronized(mutex) {
                                    removeHttp2Reservation(key)
                                    reservationOutstanding = false
                                    changed.notifyAll()
                                }
                                closeHttp2Quietly(created)
                                continue
                            } catch (error: Exception) {
                                closeHttp2Quietly(created)
                                throw error
                            }
                            let accepted = synchronized(mutex) {
                                removeHttp2Reservation(key)
                                reservationOutstanding = false
                                if (closed || !created.acceptingNewStreams) {
                                    changed.notifyAll()
                                    false
                                } else {
                                    entries.add(Http2PoolEntry(id, key, created))
                                    changed.notifyAll()
                                    true
                                }
                            }
                            if (!accepted) {
                                admission.registration.unregister()
                                closeHttp2Quietly(created)
                                if (closed) { throw http2PoolClosed() }
                                continue
                            }
                            return Http2PoolLease(id, key, created, admission)
                        } catch (error: Exception) {
                            if (reservationOutstanding) {
                                synchronized(mutex) {
                                    removeHttp2Reservation(key)
                                    reservationOutstanding = false
                                    changed.notifyAll()
                                }
                            }
                            throw error
                        }
                }
            }
            throw http2PoolClosed()
        } finally {
            registration.unregister()
        }
    }

    /** Adopts one connection whose ALPN result was discovered by the HTTP/1 factory path. */
    public func adopt(
        key: HttpConnectionPoolKey,
        connection: Http2MultiplexedConnection,
        listener: Http2GoAwayListener,
        context!: OperationContext = OperationContext.background(),
        endStream!: Bool = false
    ): Http2PoolLease {
        checkHttp2PoolContext(context)
        synchronized(mutex) {
            if (closed) { throw http2PoolClosed() }
            if (entries.size + reservations.size >= config.maximumConnections ||
                countHttp2ForKey(key) >= config.maximumConnectionsPerKey) {
                throw http2PoolExhausted()
            }
            if (!connection.acceptingNewStreams || connection.isClosed()) {
                throw Http2StreamLimitException("adopted HTTP/2 connection is not accepting streams")
            }
            let id = nextId
            nextId++
            let admission = connection.openStream(listener, endStream)
            entries.add(Http2PoolEntry(id, key, connection))
            changed.notifyAll()
            Http2PoolLease(id, key, connection, admission)
        }
    }

    /** Signals stream completion; duplicate or foreign releases are ignored. */
    public func release(lease: Http2PoolLease): Unit {
        if (!lease.claimReturn()) { return }
        lease.admission.registration.unregister()
        var discard = None<Http2MultiplexedConnection>
        synchronized(mutex) {
            let index = findHttp2Entry(lease.connectionId)
            if (index >= 0) {
                let entry = entries[index]
                if (entry.key == lease.key &&
                    (!entry.connection.acceptingNewStreams || entry.connection.isClosed()) &&
                    entry.connection.activeStreamCount == 0) {
                    discard = Some(entries.remove(at: index).connection)
                }
            }
            changed.notifyAll()
        }
        if (let Some(value) <- discard) { closeHttp2Quietly(value) }
    }

    public func snapshot(): Http2ConnectionPoolSnapshot {
        synchronized(mutex) {
            var active: Int64 = 0
            var available: Int64 = 0
            for (entry in entries) {
                let current = entry.connection.activeStreamCount
                active += current
                if (entry.connection.acceptingNewStreams && !entry.connection.isClosed()) {
                    available += max(0, Int64(entry.connection.streamCapacity) - current)
                }
            }
            Http2ConnectionPoolSnapshot(
                entries.size, active, available, reservations.size, waiters, closed
            )
        }
    }

    public func close(): Unit {
        let claimed = synchronized(mutex) {
            if (closed) { Array<Http2MultiplexedConnection>() }
            else {
                closed = true
                let result = ArrayList<Http2MultiplexedConnection>()
                for (entry in entries) { result.add(entry.connection) }
                entries = ArrayList<Http2PoolEntry>()
                changed.notifyAll()
                result.toArray()
            }
        }
        for (connection in claimed) { connection.abort(reason: AbortReason.ApplicationAbort) }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func decide(
        key: HttpConnectionPoolKey,
        listener: Http2GoAwayListener,
        endStream: Bool,
        context: OperationContext
    ): Http2PoolDecision {
        var countedWaiter = false
        try {
            synchronized(mutex) {
                while (true) {
                    checkHttp2PoolContext(context)
                    if (closed) { throw http2PoolClosed() }
                    let unusable = findUnusableEmptyConnection()
                    if (unusable >= 0) {
                        return Http2PoolDecision.Discard(entries.remove(at: unusable).connection)
                    }
                    for (entry in entries) {
                        if (entry.key == key && entry.connection.acceptingNewStreams &&
                            !entry.connection.isClosed() &&
                            entry.connection.activeStreamCount < Int64(entry.connection.streamCapacity)) {
                            try {
                                let admission = entry.connection.openStream(listener, endStream)
                                return Http2PoolDecision.Reuse(Http2PoolLease(
                                    entry.id, entry.key, entry.connection, admission
                                ))
                            } catch (_: Http2StreamLimitException) {
                                // SETTINGS or GOAWAY may race the observed capacity.
                            }
                        }
                    }
                    if (!hasHttp2Reservation(key) &&
                        entries.size + reservations.size < config.maximumConnections &&
                        countHttp2ForKey(key) < config.maximumConnectionsPerKey) {
                        let id = nextId
                        nextId++
                        reservations.add(key)
                        return Http2PoolDecision.Reserve(id)
                    }
                    if (!countedWaiter) {
                        if (waiters >= config.maximumWaiters) { throw http2PoolExhausted() }
                        waiters++
                        countedWaiter = true
                    }
                    waitForHttp2PoolChange(context)
                }
                throw http2PoolClosed()
            }
        } finally {
            if (countedWaiter) { synchronized(mutex) { waiters--; changed.notifyAll() } }
        }
    }

    private func findUnusableEmptyConnection(): Int64 {
        for (index in 0..entries.size) {
            let connection = entries[index].connection
            if ((!connection.acceptingNewStreams || connection.isClosed()) &&
                connection.activeStreamCount == 0) { return index }
        }
        -1
    }

    private func findHttp2Entry(id: Int64): Int64 {
        for (index in 0..entries.size) {
            if (entries[index].id == id) { return index }
        }
        -1
    }

    private func countHttp2ForKey(key: HttpConnectionPoolKey): Int64 {
        var result: Int64 = 0
        for (entry in entries) { if (entry.key == key) { result++ } }
        for (reserved in reservations) { if (reserved == key) { result++ } }
        result
    }

    private func hasHttp2Reservation(key: HttpConnectionPoolKey): Bool {
        for (reserved in reservations) { if (reserved == key) { return true } }
        false
    }

    private func removeHttp2Reservation(key: HttpConnectionPoolKey): Unit {
        for (index in 0..reservations.size) {
            if (reservations[index] == key) { let _ = reservations.remove(at: index); return }
        }
    }

    private func waitForHttp2PoolChange(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) =>
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw http2PoolTimedOut() }
                changed.wait(timeout: remaining)
            case None => changed.wait()
        }
    }

    private func checkHttp2PoolContext(context: OperationContext): Unit {
        if (context.isCancellationRequested()) { throw http2PoolCancelled() }
        if (context.isDeadlineExceeded()) { throw http2PoolTimedOut() }
    }

    private func wakeHttp2Pool(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private func closeHttp2Quietly(connection: Http2MultiplexedConnection): Unit {
    try { connection.close() } catch (_: Exception) { connection.abort(reason: AbortReason.ApplicationAbort) }
}

private func http2PoolClosed(): NetworkException {
    NetworkException(NetworkErrorCategory.Closed, NetworkPhase.PoolAcquire, NetworkErrorCode.Closed,
        "HTTP/2 connection pool is closed", retryability: Retryability.Never)
}

private func http2PoolExhausted(): NetworkException {
    NetworkException(NetworkErrorCategory.ResourceExhausted, NetworkPhase.PoolAcquire,
        NetworkErrorCode.ResourceExhausted, "HTTP/2 connection pool waiter limit exceeded",
        retryability: Retryability.Temporary)
}

private func http2PoolCancelled(): NetworkException {
    NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.PoolAcquire, NetworkErrorCode.Cancelled,
        "HTTP/2 connection acquisition cancelled", retryability: Retryability.Never)
}

private func http2PoolTimedOut(): NetworkException {
    NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.PoolAcquire,
        NetworkErrorCode.TimedOut, "HTTP/2 connection acquisition deadline exceeded",
        retryability: Retryability.Temporary)
}
