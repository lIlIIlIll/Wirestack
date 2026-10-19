package wirestack.internal.http2

import std.collection.*
import std.sync.*
import wirestack.internal.transport.*
import wirestack.internal as internal
private const HTTP2_MAX_CONTROL_BURST: Int64 = 8

public enum Http2WriteState {
    | Queued
    | Writing
    | Written
    | Cancelled
    | Failed
}

public enum Http2WriteSchedulerState {
    | Open
    | Closing
    | Closed
    | Failed
}

public class Http2WriteQueueFullException <: Exception {
    public init(message: String) { super(message) }
    protected override func getClassName(): String { "Http2WriteQueueFullException" }
}

/** One observable write claim. Cancellation only succeeds while still queued. */
public class Http2WriteTicket {
    public let id: Int64
    public let streamId: Http2StreamId
    private let scheduler: Http2WriteScheduler
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var current = Http2WriteState.Queued
    private var failureReason = ""
    private var completion: Option<(Http2WriteState) -> Unit> = None<(Http2WriteState) -> Unit>

    public prop state: Http2WriteState { get() { synchronized(mutex) { current } } }
    public prop failure: String { get() { synchronized(mutex) { failureReason } } }

    internal init(id: Int64, streamId: Http2StreamId, scheduler: Http2WriteScheduler) {
        this.id = id
        this.streamId = streamId
        this.scheduler = scheduler
    }

    public func cancel(): Bool { scheduler.cancel(id) }

    /** Waits without polling and returns the retained terminal ticket state. */
    public func wait(context!: OperationContext = OperationContext.background()): Http2WriteState {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (!isTerminalWriteState(current)) {
                    checkTicketWaitContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                current
            }
        } finally {
            registration.unregister()
        }
    }

    /** Retains at most one pending observer and invokes it outside scheduler and ticket locks. */
    internal func whenTerminal(callback: (Http2WriteState) -> Unit): Unit {
        let finished = synchronized(mutex) {
            if (isTerminalWriteState(current)) { Some(current) }
            else {
                if (completion.isSome()) {
                    throw IllegalStateException("HTTP/2 write already has a completion observer")
                }
                completion = Some(callback)
                None<Http2WriteState>
            }
        }
        if (let Some(state) <- finished) { callback(state) }
    }

    internal func markWriting(): Unit { transition(Http2WriteState.Writing) }
    internal func markWritten(): Unit { transition(Http2WriteState.Written) }
    internal func markCancelled(): Unit { transition(Http2WriteState.Cancelled) }
    internal func markFailed(reason: String): Unit {
        transition(Http2WriteState.Failed, reason: reason)
    }

    private func transition(next: Http2WriteState, reason!: String = ""): Unit {
        let observer = synchronized(mutex) {
            if (isTerminalWriteState(current)) { None<(Http2WriteState) -> Unit> }
            else {
                current = next
                failureReason = reason
                let claimed = if (isTerminalWriteState(next)) {
                    let value = completion
                    completion = None<(Http2WriteState) -> Unit>
                    value
                } else { None<(Http2WriteState) -> Unit> }
                changed.notifyAll()
                claimed
            }
        }
        if (let Some(callback) <- observer) { callback(next) }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

/** Maps validated stream authorities to the aggregate owner of their DATA buffers. */
public class Http2StreamBufferOwners {
    private let mutex = Mutex()
    private let entries = ArrayList<Http2StreamBufferOwnerEntry>()

    public init() {}

    internal func bind(streamId: Int64, owner: internal.HttpResourceOwnerKey): Unit {
        synchronized(mutex) {
            unbindLocked(streamId)
            entries.add(Http2StreamBufferOwnerEntry(streamId, owner))
        }
    }

    internal func unbind(streamId: Int64): Unit {
        synchronized(mutex) { unbindLocked(streamId) }
    }

    internal func ownerFor(streamId: Int64): ?internal.HttpResourceOwnerKey {
        synchronized(mutex) {
            var found = None<internal.HttpResourceOwnerKey>
            for (entry in entries) {
                if (entry.streamId == streamId) { found = Some(entry.owner) }
            }
            found
        }
    }

    private func unbindLocked(streamId: Int64): Unit {
        for (index in 0..entries.size) {
            if (entries[index].streamId == streamId) {
                let _ = entries.remove(at: index)
                return
            }
        }
    }
}

private class Http2StreamBufferOwnerEntry {
    let streamId: Int64
    let owner: internal.HttpResourceOwnerKey

    init(streamId: Int64, owner: internal.HttpResourceOwnerKey) {
        this.streamId = streamId
        this.owner = owner
    }
}

/**
 * Bounded multi-producer, single-writer HTTP/2 frame scheduler.
 *
 * Control frames are selected ahead of DATA, but at most eight controls may be
 * emitted while DATA is pending. DATA queues rotate by stream id, preventing a
 * single busy stream from monopolizing the connection writer.
 */
public class Http2WriteScheduler {
    private let transport: DuplexTransport
    private let limits: Http2Limits
    private let resourceBudget: ?internal.HttpResourceBudget
    private let resourceOwner: ?internal.HttpResourceOwnerKey
    private let streamBufferOwners: ?Http2StreamBufferOwners
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let controls = ArrayList<Http2QueuedWrite>()
    private let dataStreams = ArrayList<Http2DataWriteQueue>()
    private var nextId: Int64 = 1
    private var queuedCount: Int64 = 0
    private var queuedBytes: UInt64 = 0u64
    private var reservedQueueCount: Int64 = 0
    private var reservedQueueBytes: UInt64 = 0u64
    private var cleanupQueueReserved = false
    private var cleanupQueueClaimed = false
    private var cleanupQueueQueued = false
    private var cleanupQueueBytes: UInt64 = 0u64
    private var schedulerState = Http2WriteSchedulerState.Open
    private var writerClaimed = false
    private var writerRunning = false
    private var controlBurst: Int64 = 0
    private var active: ?Http2QueuedWrite = None<Http2QueuedWrite>
    private var startedControlBatch: ?Int64 = None<Int64>
    private var maximumQueuedCount: Int64 = 0
    private var maximumQueuedBytes: UInt64 = 0u64
    // 0 = unclaimed, 1 = graceful close in progress, 2 = terminal. Abort may
    // upgrade state 1 exactly once to interrupt a blocked graceful close.
    private var transportTerminalState: Int64 = 0

    public prop state: Http2WriteSchedulerState { get() { synchronized(mutex) { schedulerState } } }
    public prop pendingWrites: Int64 { get() { synchronized(mutex) { queuedCount } } }
    public prop pendingBytes: UInt64 { get() { synchronized(mutex) { queuedBytes } } }
    public prop maximumPendingWrites: Int64 { get() { synchronized(mutex) { maximumQueuedCount } } }
    public prop maximumPendingBytes: UInt64 { get() { synchronized(mutex) { maximumQueuedBytes } } }
    public prop isWriterRunning: Bool { get() { synchronized(mutex) { writerRunning } } }

    public init(
        transport: DuplexTransport,
        limits!: Http2Limits = Http2Limits(),
        resourceBudget!: ?internal.HttpResourceBudget = None<internal.HttpResourceBudget>,
        resourceOwner!: ?internal.HttpResourceOwnerKey = None<internal.HttpResourceOwnerKey>,
        streamBufferOwners!: ?Http2StreamBufferOwners = None<Http2StreamBufferOwners>
    ) {
        if (resourceBudget.isSome() != resourceOwner.isSome()) {
            throw IllegalArgumentException("HTTP/2 writer budget and owner must be supplied together")
        }
        this.transport = transport
        this.limits = limits
        this.resourceBudget = resourceBudget
        this.resourceOwner = resourceOwner
        this.streamBufferOwners = streamBufferOwners
    }

    /** DATA buffers follow the validated stream authority; connection frames stay listener-owned. */
    private func streamBufferOwner(streamId: Int64): internal.HttpResourceOwnerKey {
        if (let Some(owners) <- streamBufferOwners) {
            if (let Some(value) <- owners.ownerFor(streamId)) { return value }
        }
        resourceOwner.getOrThrow()
    }

    private func reserveQueuedBuffer(
        bytes: UInt64,
        control: Bool,
        streamId: Int64,
        cleanup!: Bool = false
    ): ?internal.HttpResourceLease {
        if (let Some(budget) <- resourceBudget) {
            let owner = if (control) { resourceOwner.getOrThrow() } else { streamBufferOwner(streamId) }
            match (budget.tryAcquireManagedBuffer(owner, bytes, control)) {
                case Some(lease) => Some(lease)
                case None =>
                    if (cleanup && bytes <= 17u64) {
                        match (budget.tryAcquireManagedBuffer(owner, bytes, true, cleanup: true)) {
                            case Some(lease) => Some(lease)
                            case None => throw Http2WriteQueueFullException(
                                "HTTP aggregate control and cleanup buffer budgets are exhausted"
                            )
                        }
                    } else {
                        throw Http2WriteQueueFullException(
                            "HTTP aggregate managed-buffer budget is exhausted"
                        )
                    }
            }
        } else { None<internal.HttpResourceLease> }
    }

    private func waitForQueuedBuffer(
        bytes: UInt64, control: Bool, context: OperationContext
    ): ?internal.HttpResourceLease {
        if (let Some(budget) <- resourceBudget) {
            Some(budget.acquireManagedBuffer(
                resourceOwner.getOrThrow(), bytes, control, context
            ))
        } else { None<internal.HttpResourceLease> }
    }

    private func retainBufferLease(
        lease: ?internal.HttpResourceLease
    ): ?internal.HttpResourceLease {
        match (lease) {
            case Some(value) => Some(value.retain())
            case None => None<internal.HttpResourceLease>
        }
    }

    private func releaseBufferLease(lease: ?internal.HttpResourceLease): Unit {
        if (let Some(value) <- lease) { value.close() }
    }

    /** Reserves bounded queue capacity before serialization allocates retained bytes. */
    private func reserveQueueCapacityImmediately(
        count: Int64,
        bytes: UInt64,
        cleanup: Bool
    ): Bool {
        synchronized(mutex) {
            if (!isSchedulerOpen(schedulerState)) {
                throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
            }
            if (queueCapacityAvailableLocked(count, bytes)) {
                reservedQueueCount += count
                reservedQueueBytes += bytes
                return false
            }
            if (cleanup && count == 1 && bytes <= 17u64 && !cleanupQueueClaimed) {
                cleanupQueueReserved = true
                cleanupQueueClaimed = true
                return true
            }
            throw Http2WriteQueueFullException("HTTP/2 pending write limit reached")
        }
    }

    private func reserveQueueCapacityWaiting(
        count: Int64,
        bytes: UInt64,
        context: OperationContext
    ): Unit {
        let registration = context.cancellation.register { => wakeWriter() }
        try {
            synchronized(mutex) {
                while (true) {
                    checkWriterContext(context)
                    if (!isSchedulerOpen(schedulerState)) {
                        throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
                    }
                    if (queueCapacityAvailableLocked(count, bytes)) {
                        reservedQueueCount += count
                        reservedQueueBytes += bytes
                        return
                    }
                    waitWriterChange(context)
                }
                throw IllegalStateException("unreachable HTTP/2 queue reservation state")
            }
        } finally {
            registration.unregister()
        }
    }

    private func queueCapacityAvailableLocked(count: Int64, bytes: UInt64): Bool {
        let reservedSlotCount = if (cleanupQueueQueued) { 1 } else { 0 }
        let ordinaryCount = queuedCount - reservedSlotCount + reservedQueueCount
        let ordinaryBytes = queuedBytes - cleanupQueueBytes + reservedQueueBytes
        let maximumCount = Int64(limits.maxPendingWrites)
        let maximumBytes = UInt64(limits.maxPendingWriteBytes)
        count <= maximumCount - min(ordinaryCount, maximumCount) &&
            bytes <= maximumBytes - min(ordinaryBytes, maximumBytes)
    }

    private func commitQueueCapacityLocked(
        count: Int64,
        bytes: UInt64,
        cleanupSlot: Bool
    ): Unit {
        if (cleanupSlot) {
            if (!cleanupQueueReserved || !cleanupQueueClaimed) {
                throw IllegalStateException("HTTP/2 cleanup queue reservation was lost")
            }
            cleanupQueueReserved = false
            cleanupQueueQueued = true
            cleanupQueueBytes = bytes
        } else {
            if (reservedQueueCount < count || reservedQueueBytes < bytes) {
                throw IllegalStateException("HTTP/2 queue reservation accounting underflow")
            }
            reservedQueueCount -= count
            reservedQueueBytes -= bytes
        }
    }

    private func releaseQueueCapacity(
        count: Int64,
        bytes: UInt64,
        cleanupSlot: Bool
    ): Unit {
        synchronized(mutex) {
            if (cleanupSlot) {
                if (cleanupQueueReserved) {
                    cleanupQueueReserved = false
                    cleanupQueueClaimed = false
                }
            } else if (reservedQueueCount >= count && reservedQueueBytes >= bytes) {
                reservedQueueCount -= count
                reservedQueueBytes -= bytes
            }
            changed.notifyAll()
        }
    }

    private func releaseCleanupQueueSlotLocked(item: Http2QueuedWrite): Unit {
        if (item.reservedCleanupQueueSlot && cleanupQueueClaimed) {
            cleanupQueueReserved = false
            cleanupQueueClaimed = false
            cleanupQueueQueued = false
            cleanupQueueBytes = 0u64
        }
    }

    /** Fails immediately instead of exceeding either configured queue bound. */
    public func enqueue(frame: Http2Frame): Http2WriteTicket {
        enqueueOwned(frame, None<Http2SendPermit>)
    }

    /**
     * Couples one DATA frame to its reserved flow permit. The single writer
     * consumes credit immediately before the first transport byte, closing the
     * enqueue/beginSend race for concurrent streams.
     */
    public func enqueueReservedData(
        frame: Http2Frame,
        permit: Http2SendPermit
    ): Http2WriteTicket {
        if (!isDataFrame(frame.header.frameType) ||
            frame.header.streamId.value != permit.streamId.value ||
            Int64(frame.header.length) != permit.amount) {
            throw IllegalArgumentException("HTTP/2 DATA frame does not match its flow permit")
        }
        try { enqueueOwned(frame, Some(permit)) }
        catch (error: Exception) { let _ = permit.cancel(); throw error }
    }
    /**
     * Atomically admits one HPACK-bearing control sequence. Admission is
     * irrevocable because the encoder table has already advanced; the writer
     * retains the whole batch contiguously through its final CONTINUATION.
     */
    public func enqueueControlBatch(frames: Array<Http2Frame>): Array<Http2WriteTicket> {
        if (frames.isEmpty()) {
            abort(reason: AbortReason.ProtocolFailure)
            throw IllegalArgumentException("HTTP/2 control batch cannot be empty")
        }
        var totalBytes = 0u64
        for (frame in frames) {
            if (isDataFrame(frame.header.frameType)) {
                abort(reason: AbortReason.ProtocolFailure)
                throw IllegalArgumentException("HTTP/2 control batch cannot contain DATA")
            }
            totalBytes += UInt64(frame.header.length) + 9u64
        }
        if (frames.size > Int64(limits.maxPendingWrites) ||
            totalBytes > UInt64(limits.maxPendingWriteBytes)) {
            abort(reason: AbortReason.ProtocolFailure)
            throw Http2WriteQueueFullException("HTTP/2 control batch exceeds the configured queue bounds")
        }

        var bufferLease: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
        var queueReserved = false
        try {
            bufferLease = reserveQueuedBuffer(totalBytes, true, 0)
            let cleanupSlot = reserveQueueCapacityImmediately(frames.size, totalBytes, false)
            queueReserved = true
            let encoded = ArrayList<Array<Byte>>()
            for (frame in frames) { encoded.add(serializeHttp2Frame(frame)) }
            let tickets = synchronized(mutex) {
                if (!isSchedulerOpen(schedulerState)) {
                    throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
                }
                commitQueueCapacityLocked(frames.size, totalBytes, cleanupSlot)
                let output = ArrayList<Http2WriteTicket>()
                let batchId = nextId
                for (index in 0..frames.size) {
                    let frame = frames[index]
                    let ticket = Http2WriteTicket(nextId, frame.header.streamId, this)
                    controls.add(Http2QueuedWrite(
                        nextId, frame.header.streamId, encoded[index], ticket,
                        controlBatchId: Some(batchId),
                        endsControlBatch: index == frames.size - 1,
                        bufferLease: retainBufferLease(bufferLease)
                    ))
                    nextId++
                    queuedCount++
                    queuedBytes += UInt64(encoded[index].size)
                    recordQueueHighWaterLocked()
                    output.add(ticket)
                }
                changed.notifyAll()
                output.toArray()
            }
            queueReserved = false
            releaseBufferLease(bufferLease)
            tickets
        } catch (error: Exception) {
            if (queueReserved) {
                releaseQueueCapacity(frames.size, totalBytes, false)
            }
            releaseBufferLease(bufferLease)
            abort(reason: AbortReason.ProtocolFailure)
            throw error
        }
    }

    /** Waits for bounded queue capacity instead of turning small-read credit into a queue failure. */
    public func enqueueControlBatchWaiting(
        frames: Array<Http2Frame>,
        context!: OperationContext = OperationContext.background()
    ): Array<Http2WriteTicket> {
        if (frames.isEmpty()) { return [] }
        var totalBytes = 0u64
        for (frame in frames) {
            if (isDataFrame(frame.header.frameType)) {
                throw IllegalArgumentException("HTTP/2 control batch cannot contain DATA")
            }
            totalBytes += UInt64(frame.header.length) + 9u64
        }
        if (frames.size > Int64(limits.maxPendingWrites) ||
            totalBytes > UInt64(limits.maxPendingWriteBytes)) {
            throw Http2WriteQueueFullException("HTTP/2 control batch exceeds the configured queue bounds")
        }
        var bufferLease: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
        var queueReserved = false
        try {
            bufferLease = waitForQueuedBuffer(totalBytes, true, context)
            reserveQueueCapacityWaiting(frames.size, totalBytes, context)
            queueReserved = true
            let encoded = ArrayList<Array<Byte>>()
            for (frame in frames) { encoded.add(serializeHttp2Frame(frame)) }
            let tickets = synchronized(mutex) {
                checkWriterContext(context)
                if (!isSchedulerOpen(schedulerState)) {
                    throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
                }
                commitQueueCapacityLocked(frames.size, totalBytes, false)
                let output = ArrayList<Http2WriteTicket>()
                for (index in 0..frames.size) {
                    let frame = frames[index]
                    let ticket = Http2WriteTicket(nextId, frame.header.streamId, this)
                    controls.add(Http2QueuedWrite(
                        nextId, frame.header.streamId, encoded[index], ticket,
                        bufferLease: retainBufferLease(bufferLease)
                    ))
                    nextId++
                    queuedCount++
                    queuedBytes += UInt64(encoded[index].size)
                    recordQueueHighWaterLocked()
                    output.add(ticket)
                }
                changed.notifyAll()
                output.toArray()
            }
            queueReserved = false
            tickets
        } finally {
            if (queueReserved) { releaseQueueCapacity(frames.size, totalBytes, false) }
            releaseBufferLease(bufferLease)
        }
    }

    private func enqueueOwned(
        frame: Http2Frame,
        permit: ?Http2SendPermit
    ): Http2WriteTicket {
        let size = UInt64(frame.header.length) + 9u64
        let cleanup = isCleanupFrame(frame)
        let control = !isDataFrame(frame.header.frameType) || cleanup
        let bufferLease = reserveQueuedBuffer(
            size, control, Int64(frame.header.streamId.value), cleanup: cleanup
        )
        var cleanupSlot = false
        var queueReserved = false
        var transferred = false
        try {
            cleanupSlot = reserveQueueCapacityImmediately(1, size, cleanup)
            queueReserved = true
            let bytes = serializeHttp2Frame(frame)
            let ticket = synchronized(mutex) {
                if (!isSchedulerOpen(schedulerState)) {
                    throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
                }
                commitQueueCapacityLocked(1, size, cleanupSlot)
                let id = nextId
                nextId++
                let created = Http2WriteTicket(id, frame.header.streamId, this)
                let item = Http2QueuedWrite(
                    id, frame.header.streamId, bytes, created,
                    permit: permit, bufferLease: bufferLease,
                    reservedCleanupQueueSlot: cleanupSlot
                )
                if (isDataFrame(frame.header.frameType)) { enqueueDataLocked(item) }
                else { controls.add(item) }
                queuedCount++
                queuedBytes += size
                recordQueueHighWaterLocked()
                changed.notifyAll()
                created
            }
            queueReserved = false
            transferred = true
            ticket
        } finally {
            if (queueReserved) { releaseQueueCapacity(1, size, cleanupSlot) }
            if (!transferred) { releaseBufferLease(bufferLease) }
        }
    }

    private func recordQueueHighWaterLocked(): Unit {
        maximumQueuedCount = max(maximumQueuedCount, queuedCount)
        maximumQueuedBytes = max(maximumQueuedBytes, queuedBytes)
    }

    /** Idempotently stops admission; the writer drains every accepted frame. */
    public func close(): Unit {
        synchronized(mutex) {
            if (isSchedulerOpen(schedulerState)) {
                schedulerState = Http2WriteSchedulerState.Closing
                changed.notifyAll()
            }
        }
    }

    /** Immediately fails queued work and interrupts an active transport write. */
    public func abort(reason!: AbortReason = AbortReason.ApplicationAbort): Unit {
        let failed = synchronized(mutex) {
            if (isSchedulerTerminal(schedulerState)) {
                Array<Http2QueuedWrite>()
            } else {
                schedulerState = Http2WriteSchedulerState.Failed
                let claimed = drainQueuedLocked()
                changed.notifyAll()
                claimed
            }
        }
        for (item in failed) {
            item.releaseBuffer()
            item.ticket.markFailed("HTTP/2 write scheduler aborted")
        }
        abortTransportOnce(reason)
    }

    /** Waits without polling for either graceful drain or terminal failure. */
    public func waitUntilTerminal(
        context!: OperationContext = OperationContext.background()
    ): Http2WriteSchedulerState {
        let registration = context.cancellation.register { => wakeWriter() }
        try {
            synchronized(mutex) {
                while (!isSchedulerTerminal(schedulerState)) {
                    checkWriterContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                schedulerState
            }
        } finally {
            registration.unregister()
        }
    }

    /** Gracefully closes the owned transport once after every accepted frame drains. */
    public func finishTransport(context!: OperationContext = OperationContext.background()): Bool {
        let claimed = synchronized(mutex) {
            if (!isSchedulerClosed(schedulerState)) {
                throw IllegalStateException("HTTP/2 transport cannot close before writer drain")
            }
            if (transportTerminalState != 0) { false }
            else { transportTerminalState = 1; true }
        }
        if (!claimed) { return false }
        try {
            transport.close(context)
        } catch (error: Exception) {
            // A failed graceful close must still terminate the transport. If a
            // racing abort already upgraded state 1, that caller owns abort.
            abortTransportOnce(writerAbortReason(context))
            throw error
        } finally {
            synchronized(mutex) {
                if (transportTerminalState == 1) { transportTerminalState = 2 }
            }
        }
        true
    }

    /** Runs on exactly one caller task until graceful drain or terminal failure. */
    public func run(context!: OperationContext = OperationContext.background()): Http2WriteSchedulerState {
        synchronized(mutex) {
            if (writerClaimed) { throw IllegalStateException("HTTP/2 connection already has a writer loop") }
            writerClaimed = true
            writerRunning = true
        }
        let registration = context.cancellation.register { => wakeWriter() }
        try {
            runWriter(context)
        } catch (error: Exception) {
            failWriter(error.message)
        } finally {
            registration.unregister()
            synchronized(mutex) { writerRunning = false; changed.notifyAll() }
        }
        let result = state
        if (!isSchedulerClosed(result)) {
            abortTransportOnce(writerAbortReason(context))
        }
        result
    }

    internal func cancel(id: Int64): Bool {
        let removed = synchronized(mutex) {
            let items = removeQueuedGroupLocked(id)
            for (item in items) {
                queuedCount -= 1
                queuedBytes -= UInt64(item.bytes.size)
                releaseCleanupQueueSlotLocked(item)
            }
            if (!items.isEmpty()) { changed.notifyAll() }
            items
        }
        for (item in removed) {
            item.cancelPermit()
            item.releaseBuffer()
            item.ticket.markCancelled()
        }
        !removed.isEmpty()
    }

    /** Cancels queued stream work except irrevocable admitted HPACK batches and an optional RST ticket. */
    public func cancelStream(
        streamId: Http2StreamId,
        preservingTicketId!: ?Int64 = None<Int64>
    ): Int64 {
        let removed = synchronized(mutex) {
            let claimed = ArrayList<Http2QueuedWrite>()
            var controlIndex: Int64 = controls.size - 1
            while (controlIndex >= 0) {
                let item = controls[controlIndex]
                // Admitted header batches have already mutated the HPACK
                // encoder. They must reach the peer in full even after reset.
                if (item.controlBatchId.isNone() &&
                    item.streamId.value == streamId.value &&
                    !preservesWrite(item, preservingTicketId)) {
                    claimed.add(controls.remove(at: controlIndex))
                }
                controlIndex -= 1
            }
            var queueIndex: Int64 = dataStreams.size - 1
            while (queueIndex >= 0) {
                let queue = dataStreams[queueIndex]
                if (queue.streamId.value == streamId.value) {
                    for (item in queue.items) {
                        if (!preservesWrite(item, preservingTicketId)) { claimed.add(item) }
                    }
                    let _ = dataStreams.remove(at: queueIndex)
                }
                queueIndex -= 1
            }
            for (item in claimed) {
                queuedCount -= 1
                queuedBytes -= UInt64(item.bytes.size)
                releaseCleanupQueueSlotLocked(item)
            }
            if (!claimed.isEmpty()) { changed.notifyAll() }
            claimed.toArray()
        }
        for (item in removed) {
            item.cancelPermit()
            item.releaseBuffer()
            item.ticket.markCancelled()
        }
        removed.size
    }

    private func runWriter(context: OperationContext): Unit {
        while (true) {
            let item = takeNext(context)
            match (item) {
                case None => return
                case Some(value) =>
                    value.ticket.markWriting()
                    if (!value.beginPermit(context)) {
                        synchronized(mutex) {
                            active = None<Http2QueuedWrite>
                            releaseCleanupQueueSlotLocked(value)
                            changed.notifyAll()
                        }
                        value.releaseBuffer()
                        value.ticket.markCancelled()
                        continue
                    }
                    try { writeQueued(value, context) }
                    finally { value.releaseBuffer() }
                    let shouldFail = synchronized(mutex) {
                        active = None<Http2QueuedWrite>
                        releaseCleanupQueueSlotLocked(value)
                        if (value.endsControlBatch) {
                            startedControlBatch = None<Int64>
                        }
                        changed.notifyAll()
                        isSchedulerFailed(schedulerState)
                    }
                    if (shouldFail) {
                        value.ticket.markFailed("HTTP/2 write scheduler aborted during an active write")
                        return
                    }
                    value.ticket.markWritten()
            }
        }
    }

    private func takeNext(context: OperationContext): ?Http2QueuedWrite {
        synchronized(mutex) {
            while (queuedCount == 0 && isSchedulerOpen(schedulerState)) {
                checkWriterContext(context)
                waitWriterChange(context)
            }
            checkWriterContext(context)
            if (isSchedulerFailed(schedulerState)) { return None<Http2QueuedWrite> }
            if (queuedCount == 0 && isSchedulerClosing(schedulerState)) {
                schedulerState = Http2WriteSchedulerState.Closed
                return None<Http2QueuedWrite>
            }
            let item = selectNextLocked()
            queuedCount -= 1
            queuedBytes -= UInt64(item.bytes.size)
            if (item.reservedCleanupQueueSlot) {
                cleanupQueueQueued = false
                cleanupQueueBytes = 0u64
            }
            active = Some(item)
            changed.notifyAll()
            Some(item)
        }
    }

    private func selectNextLocked(): Http2QueuedWrite {
        if (startedControlBatch.isSome()) {
            if (controls.isEmpty() ||
                !controls[0].belongsToControlBatch(startedControlBatch.getOrThrow())) {
                throw IllegalStateException("HTTP/2 control batch lost wire contiguity")
            }
            controlBurst += 1
            return controls.remove(at: 0)
        }
        let selected = if (!controls.isEmpty() &&
            (controlBurst < HTTP2_MAX_CONTROL_BURST || dataStreams.isEmpty())) {
            controlBurst += 1
            controls.remove(at: 0)
        } else if (!dataStreams.isEmpty()) {
            controlBurst = 0
            let queue = dataStreams.remove(at: 0)
            let item = queue.items.remove(at: 0)
            if (!queue.items.isEmpty()) { dataStreams.add(queue) }
            item
        } else {
            controlBurst += 1
            controls.remove(at: 0)
        }
        if (selected.controlBatchId.isSome() && !selected.endsControlBatch) {
            startedControlBatch = selected.controlBatchId
        }
        selected
    }

    private func enqueueDataLocked(item: Http2QueuedWrite): Unit {
        for (queue in dataStreams) {
            if (queue.streamId.value == item.streamId.value) { queue.items.add(item); return }
        }
        let queue = Http2DataWriteQueue(item.streamId)
        queue.items.add(item)
        dataStreams.add(queue)
    }

    private func removeQueuedGroupLocked(id: Int64): Array<Http2QueuedWrite> {
        for (index in 0..controls.size) {
            let target = controls[index]
            if (target.id == id) {
                // HPACK-bearing control batches are irrevocable once admitted.
                if (target.controlBatchId.isSome()) { return [] }
                return [controls.remove(at: index)]
            }
        }
        for (queueIndex in 0..dataStreams.size) {
            let queue = dataStreams[queueIndex]
            for (itemIndex in 0..queue.items.size) {
                if (queue.items[itemIndex].id == id) {
                    let item = queue.items.remove(at: itemIndex)
                    if (queue.items.isEmpty()) { let _ = dataStreams.remove(at: queueIndex) }
                    return [item]
                }
            }
        }
        []
    }

    private func drainQueuedLocked(): Array<Http2QueuedWrite> {
        let output = ArrayList<Http2QueuedWrite>()
        for (item in controls) { output.add(item) }
        controls.clear()
        for (queue in dataStreams) { for (item in queue.items) { output.add(item) } }
        dataStreams.clear()
        for (item in output) { releaseCleanupQueueSlotLocked(item) }
        queuedCount = 0
        queuedBytes = 0u64
        startedControlBatch = None<Int64>
        output.toArray()
    }

    private func failWriter(reason: String): Unit {
        let (queued, writing) = synchronized(mutex) {
            schedulerState = Http2WriteSchedulerState.Failed
            let pending = drainQueuedLocked()
            let current = active
            if (let Some(item) <- current) { releaseCleanupQueueSlotLocked(item) }
            active = None<Http2QueuedWrite>
            changed.notifyAll()
            (pending, current)
        }
        for (item in queued) {
            item.cancelPermit()
            item.releaseBuffer()
            item.ticket.markFailed(reason)
        }
        if (let Some(item) <- writing) {
            item.cancelPermit()
            item.releaseBuffer()
            item.ticket.markFailed(reason)
        }
    }

    private func writeQueued(item: Http2QueuedWrite, context: OperationContext): Unit {
        var remaining = ByteSpan(item.bytes)
        while (!remaining.isEmpty()) {
            checkWriterContext(context)
            let count = transport.writeSome(remaining, context: context)
            if (count <= 0 || count > remaining.length) {
                throw NetworkException(
                    NetworkErrorCategory.Write,
                    NetworkPhase.HttpBody,
                    NetworkErrorCode.SystemFailure,
                    "HTTP/2 transport returned invalid write progress",
                    retryability: Retryability.Never
                )
            }
            remaining = remaining.advance(count)
        }
    }

    private func waitWriterChange(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) => changed.wait(timeout: deadline.remaining())
            case None => changed.wait()
        }
    }

    private func wakeWriter(): Unit { synchronized(mutex) { changed.notifyAll() } }

    private func abortTransportOnce(reason: AbortReason): Unit {
        let claimed = synchronized(mutex) {
            if (transportTerminalState == 2) { false }
            else { transportTerminalState = 2; true }
        }
        if (claimed) { try { transport.abort(reason: Some(reason)) } catch (_: Exception) {} }
    }
}


private class Http2QueuedWrite {
    let id: Int64
    let streamId: Http2StreamId
    let bytes: Array<Byte>
    let ticket: Http2WriteTicket
    let controlBatchId: ?Int64
    let endsControlBatch: Bool
    let reservedCleanupQueueSlot: Bool
    private let permit: ?Http2SendPermit
    private let bufferLease: ?internal.HttpResourceLease
    init(
        id: Int64,
        streamId: Http2StreamId,
        bytes: Array<Byte>,
        ticket: Http2WriteTicket,
        permit!: ?Http2SendPermit = None<Http2SendPermit>,
        controlBatchId!: ?Int64 = None<Int64>,
        endsControlBatch!: Bool = false,
        bufferLease!: ?internal.HttpResourceLease = None<internal.HttpResourceLease>,
        reservedCleanupQueueSlot!: Bool = false
    ) {
        this.id = id
        this.streamId = streamId
        this.bytes = bytes
        this.ticket = ticket
        this.permit = permit
        this.controlBatchId = controlBatchId
        this.endsControlBatch = endsControlBatch
        this.reservedCleanupQueueSlot = reservedCleanupQueueSlot
        this.bufferLease = bufferLease
    }

    func belongsToControlBatch(batchId: Int64): Bool {
        match (controlBatchId) {
            case Some(value) => value == batchId
            case None => false
        }
    }

    func beginPermit(context: OperationContext): Bool {
        match (permit) { case Some(value) => value.beginSend(context: context); case None => true }
    }
    func cancelPermit(): Unit { if (let Some(value) <- permit) { let _ = value.cancel() } }
    func releaseBuffer(): Unit { if (let Some(value) <- bufferLease) { value.close() } }
}

private class Http2DataWriteQueue {
    let streamId: Http2StreamId
    let items = ArrayList<Http2QueuedWrite>()
    init(streamId: Http2StreamId) { this.streamId = streamId }
}

private func preservesWrite(item: Http2QueuedWrite, value: ?Int64): Bool {
    match (value) { case Some(id) => item.id == id; case None => false }
}

private func checkWriterContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 writer cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 writer deadline exceeded", retryability: Retryability.Temporary
        )
    }
}

private func checkTicketWaitContext(context: OperationContext): Unit { checkWriterContext(context) }

private func writerAbortReason(context: OperationContext): AbortReason {
    if (context.isCancellationRequested()) { AbortReason.Cancelled }
    else if (context.isDeadlineExceeded()) { AbortReason.DeadlineExceeded }
    else { AbortReason.ApplicationAbort }
}

private func isDataFrame(frameType: Http2FrameType): Bool {
    match (frameType) { case Http2FrameType.Data => true; case _ => false }
}

private func isCleanupFrame(frame: Http2Frame): Bool {
    match (frame.header.frameType) {
        case Http2FrameType.RstStream => frame.header.length == 4u32
        case Http2FrameType.GoAway => frame.header.length == 8u32
        case Http2FrameType.Data =>
            frame.header.length == 0u32 && frame.header.flags.isEndStream() &&
                frame.header.streamId.isStream()
        case _ => false
    }
}

private func isTerminalWriteState(state: Http2WriteState): Bool {
    match (state) {
        case Http2WriteState.Written => true
        case Http2WriteState.Cancelled => true
        case Http2WriteState.Failed => true
        case _ => false
    }
}

private func isSchedulerOpen(state: Http2WriteSchedulerState): Bool {
    match (state) { case Http2WriteSchedulerState.Open => true; case _ => false }
}

private func isSchedulerClosing(state: Http2WriteSchedulerState): Bool {
    match (state) { case Http2WriteSchedulerState.Closing => true; case _ => false }
}

private func isSchedulerClosed(state: Http2WriteSchedulerState): Bool {
    match (state) { case Http2WriteSchedulerState.Closed => true; case _ => false }
}

private func isSchedulerFailed(state: Http2WriteSchedulerState): Bool {
    match (state) { case Http2WriteSchedulerState.Failed => true; case _ => false }
}

private func isSchedulerTerminal(state: Http2WriteSchedulerState): Bool {
    match (state) {
        case Http2WriteSchedulerState.Closed => true
        case Http2WriteSchedulerState.Failed => true
        case _ => false
    }
}
