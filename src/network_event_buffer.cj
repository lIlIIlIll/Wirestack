package wirestack

import std.sync.Mutex

/** Atomic counters for one bounded event queue; no high-cardinality label map. */
public struct NetworkEventBufferSnapshot {
    /** Maximum retained event count. */
    public let capacity: Int64
    /** Events waiting for drain or export, excluding an active export batch. */
    public let queuedEvents: Int64
    /** Saturating count of dropped observations. */
    public let droppedEvents: Int64
    /** Creates validated queue counters.
     * @param capacity Maximum retained event count, from one through 4096.
     * @param queuedEvents Current retained event count.
     * @param droppedEvents Cumulative dropped event count.
     */
    public init(capacity: Int64, queuedEvents: Int64, droppedEvents: Int64) {
        if (capacity <= 0 || capacity > 4096 || queuedEvents < 0 || queuedEvents > capacity || droppedEvents < 0) {
            throw IllegalArgumentException("network event queue counters exceed their bounds")
        }
        this.capacity = capacity; this.queuedEvents = queuedEvents; this.droppedEvents = droppedEvents
    }
}

/** Optional queue statistics seam implemented by bounded observation adapters. */
public interface NetworkEventStatistics {
    /** Returns one atomic adapter-local sample, not a cross-module atomic view. */
    func snapshot(): NetworkEventBufferSnapshot
}

/** Fixed-capacity FIFO diagnostic sink. Full queues drop newest; no fallback
 * queue or user callback runs. Retained memory is allocated once at construction.
 */
public class NetworkEventBuffer <: NetworkEventSink & NetworkEventStatistics {
    private let capacity: Int64
    private let mutex = Mutex()
    private let events: Array<?NetworkEvent>
    private var count: Int64 = 0
    private var dropped: Int64 = 0
    /** Creates a bounded diagnostic FIFO.
     * @param capacity Maximum retained events, from one through 4096.
     */
    public init(capacity!: Int64 = 256) {
        if (capacity <= 0 || capacity > 4096) {
            throw IllegalArgumentException("network event capacity must be from one through 4096")
        }
        this.capacity = capacity
        events = Array<?NetworkEvent>(capacity, repeat: None<NetworkEvent>)
    }
    /** Records without callbacks or additional queue allocation.
     * @param event Structured observation to retain, or drop when full.
     */
    public func emit(event: NetworkEvent): Unit {
        synchronized(mutex) {
            if (count == capacity) {
                if (dropped < 9223372036854775807) { dropped++ }
            } else {
                events[count] = Some(event)
                count++
            }
        }
    }
    /** Returns retained events oldest-first and clears references atomically. */
    public func drain(): Array<NetworkEvent> {
        synchronized(mutex) {
            let result = Array<NetworkEvent>(count, { index => events[index].getOrThrow() })
            for (index in 0..count) { events[index] = None<NetworkEvent> }
            count = 0
            result
        }
    }
    /** Returns queue-local capacity, live occupancy and cumulative drops. */
    public func snapshot(): NetworkEventBufferSnapshot {
        synchronized(mutex) { NetworkEventBufferSnapshot(capacity, count, dropped) }
    }
}
