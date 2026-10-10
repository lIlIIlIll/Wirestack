package wirestack.observability

import std.sync.Mutex
import wirestack as api

/** Optional exporter invoked by one adapter worker, never by HTTP producers. */
public interface NetworkEventExporter {
    /** Delivers a FIFO batch. Exceptions drop this batch without retry.
     * @param events Secret-safe root events, at most the configured batch size.
     * @param context Cooperative export deadline and shutdown cancellation.
     */
    func export(events: Array<api.NetworkEvent>, context: api.OperationContext): Unit
}

/** Fixed queue, sampling and wait limits for an explicitly constructed adapter. */
public struct NetworkEventSinkConfig {
    /** Queue slots, excluding the active export batch. */
    public let capacity: Int64
    /** Maximum events passed to one export call. */
    public let batchSize: Int64
    /** Keep identifiers divisible by this value; uncorrelated events are kept. */
    public let sampleEvery: Int64
    /** Positive flush/close/export cap, never greater than five seconds. */
    public let shutdownCap: Duration
    /** Creates validated finite limits.
     * @param capacity Queue capacity from one through 4096.
     * @param batchSize Batch size from one through capacity.
     * @param sampleEvery Sampling denominator from one through 65536.
     * @param shutdownCap Wait cap from greater than zero through five seconds.
     */
    public init(capacity!: Int64 = 256, batchSize!: Int64 = 64,
        sampleEvery!: Int64 = 1, shutdownCap!: Duration = Duration.second) {
        if (capacity < 1 || capacity > 4096 || batchSize < 1 || batchSize > capacity ||
            sampleEvery < 1 || sampleEvery > 65536 || shutdownCap <= Duration.Zero ||
            shutdownCap > 5 * Duration.second) {
            throw IllegalArgumentException("invalid bounded event sink limits")
        }
        this.capacity = capacity; this.batchSize = batchSize
        this.sampleEvery = sampleEvery; this.shutdownCap = shutdownCap
    }
}

/** Atomic adapter-local counters. All cumulative counters saturate at Int64 max.
 * No identifier labels, exporter exceptions or arbitrary text are retained.
 */
public struct NetworkEventSinkSnapshot {
    /** Configured retained queue slots. */
    public let capacity: Int64
    /** Current queued events, excluding the active callback. */
    public let queuedEvents: Int64
    /** Events held by the current callback, including after close timeout. */
    public let inFlightEvents: Int64
    /** Whether the export worker has not yet exited. */
    public let workerRunning: Bool
    /** One lazy shutdown callback dispatcher, never more than one per adapter. */
    public let dispatcherRunning: Bool
    /** Whether canonical cancellation and all its callbacks have returned. */
    public let cancellationCompleted: Bool
    /** Whether further emits are rejected. */
    public let closed: Bool
    /** Events excluded by stable identifier sampling, not drops. */
    public let sampledOutEvents: Int64
    /** Newest events rejected by a full queue. */
    public let queueFullDroppedEvents: Int64
    /** Events emitted after close. */
    public let closedDroppedEvents: Int64
    /** Queued events discarded on close. */
    public let shutdownDroppedEvents: Int64
    /** Events discarded because their exporter threw. */
    public let exportFaultDroppedEvents: Int64
    /** Export callbacks that threw, without retaining error text. */
    public let exportFaults: Int64
    /** Events whose exporter returned normally. */
    public let exportedEvents: Int64
    internal init(capacity: Int64, queued: Int64, inFlight: Int64, running: Bool, closed: Bool,
        sampled: Int64, full: Int64, afterClose: Int64, shutdown: Int64, faultDrops: Int64,
        faults: Int64, exported: Int64, dispatcher: Bool, cancelled: Bool) {
        this.capacity = capacity; queuedEvents = queued; inFlightEvents = inFlight
        workerRunning = running; this.closed = closed; sampledOutEvents = sampled
        queueFullDroppedEvents = full; closedDroppedEvents = afterClose
        shutdownDroppedEvents = shutdown; exportFaultDroppedEvents = faultDrops
        exportFaults = faults; exportedEvents = exported
        dispatcherRunning = dispatcher; cancellationCompleted = cancelled
    }
}

/** Optional asynchronous adapter. Producers drop newest immediately when full.
 * One fixed ring is allocated at construction; only delivery allocates a batch.
 * Close discards pending events and never preempts arbitrary exporter code.
 * At most two tasks exist: one export worker and one lazy cancellation dispatcher.
 * Neither arbitrary export nor cancellation callbacks can be preempted.
 */
public class BoundedNetworkEventSink <: api.NetworkEventSink & api.NetworkEventStatistics {
    private let config: NetworkEventSinkConfig
    private let exporter: NetworkEventExporter
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let events: Array<?api.NetworkEvent>
    private let cancellation = api.CancellationSource()
    private var head: Int64 = 0
    private var count: Int64 = 0
    private var inFlight: Int64 = 0
    private var running = true
    private var closed = false
    private var workerId: Int64 = 0
    private var dispatcher = false
    private var cancelled = false
    private var dispatcherId: Int64 = 0
    private var sampled: Int64 = 0
    private var full: Int64 = 0
    private var afterClose: Int64 = 0
    private var shutdown: Int64 = 0
    private var faultDrops: Int64 = 0
    private var faults: Int64 = 0
    private var exported: Int64 = 0
    /** Starts exactly one worker for this explicitly enabled adapter.
     * @param exporter User callback, isolated from producers and owner locks.
     * @param config Validated queue, batch, sampling and budget bounds.
     */
    public init(exporter: NetworkEventExporter, config!: NetworkEventSinkConfig = NetworkEventSinkConfig()) {
        this.exporter = exporter; this.config = config
        events = Array<?api.NetworkEvent>(config.capacity, repeat: None<api.NetworkEvent>)
        spawn { runWorker() }
    }
    /** Records without waiting for exporter capacity or allocating queue storage.
     * @param event Root structured event, preserved without adding payload fields.
     */
    public func emit(event: api.NetworkEvent): Unit {
        synchronized(mutex) {
            if (closed) { afterClose = addCounter(afterClose, 1); return }
            let id = event.requestId ?? (event.attemptId ?? (event.connectionId ?? 0))
            if (id != 0 && id % config.sampleEvery != 0) {
                sampled = addCounter(sampled, 1); return
            }
            if (count == config.capacity) { full = addCounter(full, 1); return }
            events[(head + count) % config.capacity] = Some(event)
            count++; changed.notifyAll()
        }
    }
    /** Returns the shared queue/drop view, excluding sampling decisions. */
    public func snapshot(): api.NetworkEventBufferSnapshot {
        synchronized(mutex) {
            api.NetworkEventBufferSnapshot(config.capacity, count,
                addCounter(addCounter(full, afterClose), addCounter(shutdown, faultDrops)))
        }
    }
    /** Returns scalar detailed counters, atomically sampled within this adapter. */
    public func detailedSnapshot(): NetworkEventSinkSnapshot {
        synchronized(mutex) {
            NetworkEventSinkSnapshot(config.capacity, count, inFlight, running, closed,
                sampled, full, afterClose, shutdown, faultDrops, faults, exported, dispatcher, cancelled)
        }
    }
    /** Waits for an empty queue and no active export, shortened by caller budget.
     * Concurrent producers may postpone emptiness. Worker reentry returns false.
     * @param context Caller cancellation and absolute deadline, never extended.
     */
    public func flush(context: api.OperationContext): Bool { awaitIdle(context, false) }
    /** Idempotently rejects producers, discards pending events and cancels export.
     * Returns false while either worker or cancellation dispatcher remains active.
     * @param context Caller cancellation and absolute deadline, never extended.
     */
    public func close(context: api.OperationContext): Bool {
        let cap = api.Deadline.after(config.shutdownCap)
        let launch = synchronized(mutex) {
            if (closed) { false } else {
                closed = true; dispatcher = true; shutdown = addCounter(shutdown, count)
                for (index in 0..count) { events[(head + index) % config.capacity] = None<api.NetworkEvent> }
                head = 0; count = 0; changed.notifyAll()
                true
            }
        }
        if (launch) {
            spawn {
                synchronized(mutex) { dispatcherId = Thread.currentThread.id }
                try { cancellation.cancel() } finally {
                    synchronized(mutex) {
                        dispatcher = false; cancelled = true; dispatcherId = 0; changed.notifyAll()
                    }
                }
            }
        }
        awaitIdle(context.withEarlierDeadline(cap), true)
    }
    private func awaitIdle(context: api.OperationContext, requireStopped: Bool): Bool {
        // A real monotonic cap also bounds callers using a manually stalled clock.
        let cap = api.Deadline.after(config.shutdownCap)
        let bounded = context.withEarlierDeadline(cap)
        synchronized(mutex) {
            let currentId = Thread.currentThread.id
            if ((running && workerId == currentId) || (dispatcher && dispatcherId == currentId)) { return false }
            while (count != 0 || inFlight != 0 || (requireStopped && (running || dispatcher))) {
                if (bounded.isCancellationRequested() || bounded.isDeadlineExceeded() || cap.isExpired()) { return false }
                var remaining = bounded.deadline.getOrThrow().remaining()
                let realRemaining = cap.remaining()
                if (realRemaining < remaining) { remaining = realRemaining }
                // Poll cancellation without registering user code on caller tokens.
                if (remaining > 10 * Duration.millisecond) { remaining = 10 * Duration.millisecond }
                changed.wait(timeout: remaining)
            }
            !bounded.isCancellationRequested() && !bounded.isDeadlineExceeded() && !cap.isExpired()
        }
    }
    private func runWorker(): Unit {
        synchronized(mutex) { workerId = Thread.currentThread.id }
        try {
            while (true) {
                let batch = synchronized(mutex) {
                    while (count == 0 && !closed) { changed.wait() }
                    if (closed) { return }
                    let size = if (count < config.batchSize) { count } else { config.batchSize }
                    let result = Array<api.NetworkEvent>(size, { index => events[(head + index) % config.capacity].getOrThrow() })
                    for (index in 0..size) { events[(head + index) % config.capacity] = None<api.NetworkEvent> }
                    head = (head + size) % config.capacity; count -= size; inFlight = size
                    result
                }
                var failed = false
                try {
                    exporter.export(batch, api.OperationContext(cancellation: cancellation.token).shortenDeadline(config.shutdownCap))
                } catch (_: Exception) { failed = true }
                synchronized(mutex) {
                    if (failed) { faults = addCounter(faults, 1); faultDrops = addCounter(faultDrops, inFlight) }
                    else { exported = addCounter(exported, inFlight) }
                    inFlight = 0; changed.notifyAll()
                }
            }
        } finally {
            synchronized(mutex) { running = false; workerId = 0; changed.notifyAll() }
        }
    }
}

private func addCounter(value: Int64, increment: Int64): Int64 {
    if (value > 9223372036854775807 - increment) { 9223372036854775807 } else { value + increment }
}
