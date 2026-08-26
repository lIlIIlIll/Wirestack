package wirestack.internal.transport

import std.collection.*
import std.sync.*

/**
 * Bounded FIFO scheduler for connection delivery in deterministic protocol
 * tests. Work runs only when a test calls runNext or runUntilIdle.
 */
public class MemoryTransportScheduler {
    private let maxPendingConnections: Int64
    private let mutex = Mutex()
    private let deliveries = ArrayList<MemoryScheduledDelivery>()
    private var nextDeliveryId: Int64 = 1

    public init(maxPendingConnections!: Int64 = 1024) {
        if (maxPendingConnections <= 0) {
            throw IllegalArgumentException("memory scheduler capacity must be positive")
        }
        this.maxPendingConnections = maxPendingConnections
    }

    public prop pendingCount: Int64 {
        get() { synchronized(mutex) { deliveries.size } }
    }

    /** Runs one queued delivery in FIFO order. */
    public func runNext(): Bool {
        var available = false
        var delivery: ?MemoryScheduledDelivery = None<MemoryScheduledDelivery>
        synchronized(mutex) {
            if (!deliveries.isEmpty()) {
                delivery = Some(deliveries.remove(at: 0))
                available = true
            }
        }
        match (delivery) {
            case Some(value) => value.run()
            case None => ()
        }
        available
    }

    /** Runs queued deliveries until the scheduler is empty. */
    public func runUntilIdle(): Int64 {
        var count: Int64 = 0
        while (runNext()) {
            count++
        }
        count
    }

    func prepare(delivery: () -> Unit): MemoryScheduledDelivery {
        synchronized(mutex) {
            let deliveryId = nextDeliveryId
            nextDeliveryId++
            MemoryScheduledDelivery(this, deliveryId, delivery)
        }
    }

    func schedule(delivery: MemoryScheduledDelivery): Unit {
        synchronized(mutex) {
            if (delivery.isCancelled()) { return }
            if (deliveries.size >= maxPendingConnections) {
                throw memoryListenerResourceExhausted("memory scheduler queue is full")
            }
            deliveries.add(delivery)
        }
    }

    func cancel(deliveryId: Int64): Unit {
        synchronized(mutex) {
            for (index in 0..deliveries.size) {
                if (deliveries[index].id == deliveryId) {
                    let _ = deliveries.remove(at: index)
                    return
                }
            }
        }
    }
}

/**
 * Bounded in-memory listener for deterministic TLS and HTTP tests. connect()
 * creates a paired client endpoint and queues the accepted endpoint either
 * immediately or through a MemoryTransportScheduler.
 */
public class MemoryTransportListener <: TransportListener {
    private let backlog: Int64
    private let transportCapacity: Int64
    private let maxChunk: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let scheduled = ArrayList<MemoryPendingConnection>()
    private let accepted = ArrayList<MemoryPendingConnection>()
    private let activeAccepts = AtomicInt64(0)
    private var nextConnectionId: Int64 = 1
    private var closed = false

    public init(
        backlog!: Int64 = 128,
        transportCapacity!: Int64 = 64 * 1024,
        maxChunk!: Int64 = 16 * 1024
    ) {
        if (backlog <= 0) {
            throw IllegalArgumentException("memory listener backlog must be positive")
        }
        if (transportCapacity <= 0) {
            throw IllegalArgumentException("memory listener transport capacity must be positive")
        }
        if (maxChunk <= 0) {
            throw IllegalArgumentException("memory listener maxChunk must be positive")
        }
        this.backlog = backlog
        this.transportCapacity = transportCapacity
        this.maxChunk = maxChunk
    }

    /** Number of accepted or scheduled connections owned by this listener. */
    public prop queuedConnectionCount: Int64 {
        get() { synchronized(mutex) { scheduled.size + accepted.size } }
    }

    /** Number of accept calls that have entered the listener. */
    public prop activeAcceptCount: Int64 {
        get() { activeAccepts.load() }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { closed }
    }

    /**
     * Creates the client side of a pair. With a scheduler, the server side is
     * invisible to accept until the scheduler advances.
     */
    public func connect(
        scheduler!: ?MemoryTransportScheduler = None<MemoryTransportScheduler>
    ): MemoryTransport {
        let (client, server) = MemoryTransport.pair(
            capacity: transportCapacity,
            maxChunk: maxChunk
        )
        let connection = MemoryPendingConnection(client, server)
        let connectionId: Int64
        try {
            connectionId = registerConnection(connection)
        } catch (error: Exception) {
            connection.abortBoth()
            throw error
        }

        match (scheduler) {
            case Some(value) =>
                let delivery = value.prepare { => deliverConnection(connectionId) }
                if (!attachDelivery(connectionId, delivery)) {
                    delivery.cancel()
                    return client
                }
                try {
                    value.schedule(delivery)
                } catch (error: Exception) {
                    discardConnection(connectionId)
                    throw error
                }
            case None => deliverConnection(connectionId)
        }
        client
    }

    public func accept(context: OperationContext): DuplexTransport {
        memoryListenerPreflight(context)
        activeAccepts.fetchAdd(1)
        let registration = context.cancellation.register { => wakeAccepts() }
        try {
            synchronized(mutex) {
                while (accepted.isEmpty() && !closed) {
                    memoryListenerPreflight(context)
                    waitForConnection(context)
                }
                memoryListenerPreflight(context)
                if (closed) {
                    throw memoryListenerClosed()
                }
                accepted.remove(at: 0).server
            }
        } finally {
            registration.unregister()
            activeAccepts.fetchSub(1)
        }
    }

    public func accept(): DuplexTransport {
        accept(OperationContext.background())
    }

    public func close(): Unit {
        let owned = ArrayList<MemoryPendingConnection>()
        synchronized(mutex) {
            if (closed) { return }
            closed = true
            for (connection in scheduled) {
                owned.add(connection)
            }
            for (connection in accepted) {
                owned.add(connection)
            }
            scheduled.clear()
            accepted.clear()
            changed.notifyAll()
        }
        for (connection in owned) {
            connection.abortServer()
        }
    }

    private func registerConnection(connection: MemoryPendingConnection): Int64 {
        synchronized(mutex) {
            if (closed) {
                throw memoryListenerClosed()
            }
            if (scheduled.size + accepted.size >= backlog) {
                throw memoryListenerResourceExhausted("memory listener backlog is full")
            }
            let connectionId = nextConnectionId
            nextConnectionId++
            connection.id = connectionId
            scheduled.add(connection)
            connectionId
        }
    }

    private func deliverConnection(connectionId: Int64): Unit {
        synchronized(mutex) {
            let index = scheduledIndex(connectionId)
            if (index < 0) { return }
            let connection = scheduled.remove(at: index)
            connection.clearDelivery()
            if (closed) {
                connection.abortServer()
                return
            }
            accepted.add(connection)
            changed.notifyAll()
        }
    }

    private func attachDelivery(
        connectionId: Int64,
        delivery: MemoryScheduledDelivery
    ): Bool {
        synchronized(mutex) {
            let index = scheduledIndex(connectionId)
            if (index < 0) { return false }
            scheduled[index].setDelivery(delivery)
            true
        }
    }

    private func discardConnection(connectionId: Int64): Unit {
        var removed: ?MemoryPendingConnection = None<MemoryPendingConnection>
        synchronized(mutex) {
            let index = scheduledIndex(connectionId)
            if (index >= 0) {
                removed = Some(scheduled.remove(at: index))
            }
        }
        match (removed) {
            case Some(connection) => connection.abortBoth()
            case None => ()
        }
    }

    private func scheduledIndex(connectionId: Int64): Int64 {
        for (index in 0..scheduled.size) {
            if (scheduled[index].id == connectionId) {
                return index
            }
        }
        -1
    }

    private func wakeAccepts(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }

    private func waitForConnection(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) =>
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw memoryListenerTimedOut()
                }
                changed.wait(timeout: remaining)
            case None => changed.wait()
        }
    }
}

private class MemoryPendingConnection {
    var id: Int64 = 0
    let client: MemoryTransport
    let server: MemoryTransport
    private var delivery: ?MemoryScheduledDelivery = None<MemoryScheduledDelivery>

    init(client: MemoryTransport, server: MemoryTransport) {
        this.client = client
        this.server = server
    }

    func abortBoth(): Unit {
        cancelDelivery()
        client.abort()
        server.abort()
    }

    func abortServer(): Unit {
        cancelDelivery()
        server.abort()
    }

    func setDelivery(value: MemoryScheduledDelivery): Unit {
        delivery = Some(value)
    }

    func clearDelivery(): Unit {
        delivery = None<MemoryScheduledDelivery>
    }

    private func cancelDelivery(): Unit {
        match (delivery) {
            case Some(value) =>
                delivery = None<MemoryScheduledDelivery>
                value.cancel()
            case None => ()
        }
    }
}

class MemoryScheduledDelivery {
    let id: Int64
    private let scheduler: MemoryTransportScheduler
    private let action: () -> Unit
    private let cancelled = AtomicBool(false)

    init(
        scheduler: MemoryTransportScheduler,
        id: Int64,
        action: () -> Unit
    ) {
        this.scheduler = scheduler
        this.id = id
        this.action = action
    }

    func isCancelled(): Bool {
        cancelled.load()
    }

    func cancel(): Unit {
        if (cancelled.compareAndSwap(false, true)) {
            scheduler.cancel(id)
        }
    }

    func run(): Unit {
        if (!cancelled.load()) {
            action()
        }
    }
}

private func memoryListenerPreflight(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Accept,
            NetworkPhase.ServerAccept,
            NetworkErrorCode.Cancelled,
            "memory listener accept cancelled",
            retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw memoryListenerTimedOut()
    }
}

private func memoryListenerClosed(): NetworkException {
    NetworkException(
        NetworkErrorCategory.Accept,
        NetworkPhase.ServerAccept,
        NetworkErrorCode.Closed,
        "memory listener is closed",
        retryability: Retryability.Never
    )
}

private func memoryListenerTimedOut(): NetworkException {
    NetworkException(
        NetworkErrorCategory.Accept,
        NetworkPhase.ServerAccept,
        NetworkErrorCode.TimedOut,
        "memory listener accept deadline exceeded",
        retryability: Retryability.Temporary
    )
}

private func memoryListenerResourceExhausted(message: String): NetworkException {
    NetworkException(
        NetworkErrorCategory.ResourceExhausted,
        NetworkPhase.ServerAccept,
        NetworkErrorCode.ResourceExhausted,
        message,
        retryability: Retryability.Temporary
    )
}
