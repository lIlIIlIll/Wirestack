package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public class Http1ServerConfig {
    public let maximumConnections: Int64
    public let maximumRequestsPerConnection: Int64
    public let limits: HttpLimits

    public init(maximumConnections!: Int64 = 1024,
        maximumRequestsPerConnection!: Int64 = 1000,
        limits!: HttpLimits = HttpLimits()) {
        if (maximumConnections <= 0 || maximumConnections > 65536 ||
            maximumRequestsPerConnection <= 0 || maximumRequestsPerConnection > 1000000) {
            throw IllegalArgumentException("HTTP/1 server connection limits are invalid")
        }
        this.maximumConnections = maximumConnections
        this.maximumRequestsPerConnection = maximumRequestsPerConnection
        this.limits = limits
    }
}

public struct Http1ServerShutdownResult {
    public let gracefullyCompleted: Int64
    public let aborted: Int64
    public let activeAtReturn: Int64

    public init(gracefullyCompleted: Int64, aborted: Int64, activeAtReturn: Int64) {
        this.gracefullyCompleted = gracefullyCompleted
        this.aborted = aborted
        this.activeAtReturn = activeAtReturn
    }
}

private class Http1ActiveConnection {
    let id: Int64
    let transport: DuplexTransport
    init(id: Int64, transport: DuplexTransport) { this.id = id; this.transport = transport }
}

/** Bounded listener owner with idempotent graceful-to-forced shutdown. */
public class Http1Server <: Resource {
    private let listener: TransportListener
    private let handler: Http1ServerHandler
    private let config: Http1ServerConfig
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let forceCancellation = CancellationSource()
    private var active = ArrayList<Http1ActiveConnection>()
    private var nextId: Int64 = 1
    private var stopping = false
    private var running = false
    private var completed: Int64 = 0

    public init(listener: TransportListener, handler: Http1ServerHandler,
        config!: Http1ServerConfig = Http1ServerConfig()) {
        this.listener = listener
        this.handler = handler
        this.config = config
    }

    /** Runs the accept loop on the caller. Accepted connections execute concurrently up to the hard bound. */
    public func serve(context!: OperationContext = OperationContext.background()): Unit {
        synchronized(mutex) {
            if (running || stopping) { throw IllegalStateException("HTTP/1 server cannot be started in its current state") }
            running = true
        }
        let registration = context.cancellation.register({ => requestStop() })
        try {
            while (true) {
                waitForCapacity(context)
                if (isStopping()) { return }
                let transport = try {
                    listener.accept(context)
                } catch (error: Exception) {
                    if (isStopping()) { return }
                    throw error
                }
                let entry = synchronized(mutex) {
                    if (stopping) {
                        None<Http1ActiveConnection>
                    } else {
                        let value = Http1ActiveConnection(nextId, transport)
                        nextId++
                        active.add(value)
                        Some(value)
                    }
                }
                match (entry) {
                    case Some(value) => spawn { serveAccepted(value, context) }
                    case None => transport.close()
                }
            }
        } finally {
            registration.unregister()
            synchronized(mutex) { running = false; changed.notifyAll() }
        }
    }

    /** Stops accept, waits within the caller budget, then aborts every remaining connection. */
    public func shutdown(context!: OperationContext = OperationContext.background()): Http1ServerShutdownResult {
        let completedBefore = synchronized(mutex) { completed }
        requestStop()
        let registration = context.cancellation.register({ => synchronized(mutex) { changed.notifyAll() } })
        var forced = ArrayList<DuplexTransport>()
        try {
            synchronized(mutex) {
                while (!active.isEmpty()) {
                    if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                        for (entry in active) { forced.add(entry.transport) }
                        break
                    }
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
            }
        } finally {
            registration.unregister()
        }
        if (!forced.isEmpty()) {
            forceCancellation.cancel()
            for (transport in forced) {
                transport.abort(reason: Some(AbortReason.ProtocolFailure))
            }
        }
        let (completedAfter, remaining) = synchronized(mutex) { (completed, active.size) }
        Http1ServerShutdownResult(completedAfter - completedBefore, forced.size, remaining)
    }

    public func close(): Unit {
        let _ = shutdown(context: OperationContext(deadline: Some(Deadline.after(Duration.Zero))))
    }

    public func isClosed(): Bool { isStopping() }

    private func serveAccepted(entry: Http1ActiveConnection, parent: OperationContext): Unit {
        let connectionContext = parent.withCancellation(forceCancellation.token)
        try {
            let result = serveHttp1Connection(
                entry.transport, handler, context: connectionContext,
                limits: config.limits, maximumRequests: config.maximumRequestsPerConnection
            )
            match (result.tunnelTransport) {
                case Some(transport) => transport.close()
                case None => ()
            }
        } catch (_: Exception) {
            entry.transport.abort(reason: Some(AbortReason.ProtocolFailure))
        } finally {
            synchronized(mutex) {
                let index = activeIndex(entry.id)
                if (index >= 0) { let _ = active.remove(at: index) }
                completed++
                changed.notifyAll()
            }
        }
    }

    private func waitForCapacity(context: OperationContext): Unit {
        var stopAfterWait = false
        synchronized(mutex) {
            while (!stopping && active.size >= config.maximumConnections) {
                if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                    stopAfterWait = true
                    break
                }
                match (context.deadline) {
                    case Some(deadline) => changed.wait(timeout: deadline.remaining())
                    case None => changed.wait()
                }
            }
        }
        if (stopAfterWait) { requestStop() }
    }

    private func requestStop(): Unit {
        let closeListener = synchronized(mutex) {
            if (stopping) { false } else { stopping = true; changed.notifyAll(); true }
        }
        if (closeListener) { listener.close() }
    }

    private func isStopping(): Bool { synchronized(mutex) { stopping } }

    private func activeIndex(id: Int64): Int64 {
        for (index in 0..active.size) { if (active[index].id == id) { return index } }
        -1
    }
}
