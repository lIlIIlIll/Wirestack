package wirestack.sse

import std.sync.*
import wirestack.*

/** Bounded SSE HTTP body producer with one active reader and one active producer.
 * Flush acknowledges consumption by read(), not delivery to the network peer.
 * A failed partial publication aborts the body so later events cannot complete it.
 */
public class SseWriter <: HttpBodyStream {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let encoder: SseEncoder
    private let lifetime: OperationContext
    private var ring: Array<Byte>
    private var head: Int64 = 0
    private var count: Int64 = 0
    private var reading = false
    private var writing = false
    private var completed = false
    private var closed = false

    /** Fixed queue capacity in bytes. */
    public let maximumBufferBytes: Int64
    /** Number of bytes not yet consumed by the body reader. */
    public prop queuedBytes: Int64 { get() { synchronized(mutex) { count } } }
    /** Streaming bodies do not declare a content length. */
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    /** Reports whether close has aborted this body. Completion alone is not close. */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    /** Creates a fixed-size byte ring without a timer or background task.
     * @param limits Bounds for each encoded event or comment.
     * @param maximumBufferBytes Queue capacity, from 1 through 1048576 bytes.
     * @param context Lifetime deadline and cancellation observed by all operations.
     */
    public init(limits!: SseLimits = SseLimits(), maximumBufferBytes!: Int64 = 64 * 1024,
        context!: OperationContext = OperationContext.background()) {
        if (maximumBufferBytes < 1 || maximumBufferBytes > 1024 * 1024) {
            throw IllegalArgumentException("SSE writer capacity must be from 1 through 1048576 bytes")
        }
        this.maximumBufferBytes = maximumBufferBytes
        encoder = SseEncoder(limits: limits)
        lifetime = context
        ring = Array<Byte>(maximumBufferBytes, repeat: 0u8)
    }

    /** Publishes one complete event with bounded backpressure.
     * Claims the sole producer before encoding, bounding transient encoded storage.
     * @param event Event to encode.
     * @param context Additional cancellation and deadline, never replacing the lifetime.
     * @param retryMilliseconds Optional bounded reconnect delay.
     */
    public func write(event: SseEvent, context!: OperationContext = OperationContext.background(),
        retryMilliseconds!: ?UInt64 = None<UInt64>): Unit {
        produce({ => encoder.encode(event, retryMilliseconds: retryMilliseconds) }, context)
    }

    /** Publishes bounded comment lines.
     * @param value LF-separated comment text without CR or NUL.
     * @param context Additional cancellation and deadline.
     */
    public func comment(value: String, context!: OperationContext = OperationContext.background()): Unit {
        produce({ => encoder.comment(value) }, context)
    }

    /** Waits until all previously published bytes have been consumed by read().
     * No later producer may publish while flush owns the producer direction.
     * @param context Additional cancellation and deadline.
     */
    public func flush(context!: OperationContext = OperationContext.background()): Unit {
        claimWriter(context, allowCompleted: true)
        let owner = lifetime.cancellation.register({ => wake() })
        let caller = context.cancellation.register({ => wake() })
        try {
            while (true) {
                let remaining = prepareWait(context)
                let drained = synchronized(mutex) {
                    checkCancellation(context); requireOpen()
                    if (count == 0) { true } else { waitChanged(remaining); false }
                }
                if (drained) { break }
            }
        } finally {
            caller.unregister(); owner.unregister()
            synchronized(mutex) { writing = false; changed.notifyAll() }
        }
    }

    /** Ends publication. Readers receive EOF only after draining queued bytes.
     * Idempotent after completion or close; rejects an active producer.
     */
    public func complete(): Unit {
        synchronized(mutex) {
            if (completed || closed) { return }
            if (writing) { throw SseException(SseErrorCode.ConcurrentOperation, "SSE producer is active") }
            completed = true
            if (count == 0) { ring = Array<Byte>() }
            changed.notifyAll()
        }
    }

    /** Reads queued bytes or waits for publication using the lifetime context.
     * @param destination Caller-owned output buffer. Empty buffers return zero.
     * @return Bytes consumed, or zero after complete() has drained.
     */
    public func read(destination: Array<Byte>): Int64 {
        synchronized(mutex) {
            requireOpen()
            if (reading) { throw SseException(SseErrorCode.ConcurrentOperation, "SSE body reader is active") }
            reading = true
        }
        let owner = lifetime.cancellation.register({ => wake() })
        try {
            let context = OperationContext.background()
            while (true) {
                // complete() with an empty ring is this body's terminal EOF. It is observed
                // before the lifetime context, so a cancellation or deadline that lands after
                // completion cannot rewrite an established end-of-stream as an abort/reset.
                let finished = synchronized(mutex) {
                    requireOpen()
                    drainedLocked()
                }
                if (finished) { return 0 }
                var remaining: ?Duration = None<Duration>
                var failure: ?Exception = None<Exception>
                try { remaining = prepareWait(context) } catch (error: Exception) { failure = Some(error) }
                let copied = synchronized(mutex) {
                    requireOpen()
                    if (drainedLocked()) {
                        // Completion may have drained while the deadline clock was sampled.
                        0
                    } else {
                        if (let Some(error) <- failure) { throw error }
                        checkCancellation(context)
                        if (destination.isEmpty()) { 0 }
                        else if (count == 0) { waitChanged(remaining); -1 }
                        else {
                            let size = min(count, destination.size)
                            for (i in 0..size) { destination[i] = ring[(head + i) % maximumBufferBytes] }
                            head = (head + size) % maximumBufferBytes
                            count -= size
                            if (completed && count == 0) { ring = Array<Byte>() }
                            changed.notifyAll()
                            size
                        }
                    }
                }
                if (copied >= 0) { return copied }
            }
            0
        } catch (error: Exception) {
            close()
            throw error
        } finally {
            owner.unregister()
            synchronized(mutex) { reading = false; changed.notifyAll() }
        }
    }

    // complete() with nothing left in the ring is this body's terminal EOF.
    private func drainedLocked(): Bool {
        completed && count == 0
    }

    /** Aborts immediately, discards queued bytes and wakes both directions.
     * Idempotent. Subsequent reads fail with Closed rather than EOF.
     */
    public func close(): Unit {
        synchronized(mutex) {
            if (closed) { return }
            closed = true; count = 0; head = 0; ring = Array<Byte>()
            changed.notifyAll()
        }
    }

    private func produce(encode: () -> Array<Byte>, context: OperationContext): Unit {
        claimWriter(context)
        let owner = lifetime.cancellation.register({ => wake() })
        let caller = context.cancellation.register({ => wake() })
        var published = false
        try {
            let bytes = encode()
            var offset: Int64 = 0
            while (offset < bytes.size) {
                let remaining = prepareWait(context)
                synchronized(mutex) {
                    checkCancellation(context); requireOpen()
                    if (count == maximumBufferBytes) { waitChanged(remaining) }
                    else {
                        let copied = min(maximumBufferBytes - count, bytes.size - offset)
                        for (i in 0..copied) { ring[(head + count + i) % maximumBufferBytes] = bytes[offset + i] }
                        count += copied; offset += copied; published = true
                        changed.notifyAll()
                    }
                }
            }
        } catch (error: Exception) {
            if (published) { close() }
            throw error
        } finally {
            caller.unregister(); owner.unregister()
            synchronized(mutex) { writing = false; changed.notifyAll() }
        }
    }

    private func claimWriter(context: OperationContext, allowCompleted!: Bool = false): Unit {
        check(context)
        synchronized(mutex) {
            checkCancellation(context); requireOpen()
            if (completed && !allowCompleted) { throw SseException(SseErrorCode.Closed, "SSE publication is complete") }
            if (writing) { throw SseException(SseErrorCode.ConcurrentOperation, "SSE producer is active") }
            writing = true
        }
    }
    private func requireOpen(): Unit {
        if (closed) { throw SseException(SseErrorCode.Closed, "SSE writer is closed") }
    }
    private func checkCancellation(context: OperationContext): Unit {
        if (lifetime.isCancellationRequested() || context.isCancellationRequested()) {
            throw NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody,
                NetworkErrorCode.Cancelled, "SSE body operation cancelled")
        }
    }
    private func check(context: OperationContext): Unit {
        checkCancellation(context)
        if (lifetime.isDeadlineExceeded() || context.isDeadlineExceeded()) {
            throw NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody,
                NetworkErrorCode.TimedOut, "SSE body operation deadline exceeded")
        }
    }
    // Deadline clocks may be caller implementations. Sample them outside the ring lock.
    private func prepareWait(context: OperationContext): ?Duration {
        check(context)
        var remaining: ?Duration = None<Duration>
        if (let Some(deadline) <- lifetime.deadline) { remaining = Some(deadline.remaining()) }
        if (let Some(deadline) <- context.deadline) {
            remaining = Some(match (remaining) { case Some(value) => min(value, deadline.remaining()); case None => deadline.remaining() })
        }
        remaining
    }
    private func waitChanged(remaining: ?Duration): Unit {
        match (remaining) {
            case Some(value) => changed.wait(timeout: value)
            case None => changed.wait()
        }
    }
    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}
