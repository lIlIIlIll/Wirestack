package wirestack.internal.http2

import std.collection.*
import std.sync.*
import wirestack.internal.transport.*

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

    internal func markWriting(): Unit { transition(Http2WriteState.Writing) }
    internal func markWritten(): Unit { transition(Http2WriteState.Written) }
    internal func markCancelled(): Unit { transition(Http2WriteState.Cancelled) }
    internal func markFailed(reason: String): Unit {
        synchronized(mutex) {
            if (isTerminalWriteState(current)) { return }
            failureReason = reason
            current = Http2WriteState.Failed
            changed.notifyAll()
        }
    }

    private func transition(next: Http2WriteState): Unit {
        synchronized(mutex) {
            if (isTerminalWriteState(current)) { return }
            current = next
            changed.notifyAll()
        }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
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
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let controls = ArrayList<Http2QueuedWrite>()
    private let dataStreams = ArrayList<Http2DataWriteQueue>()
    private var nextId: Int64 = 1
    private var queuedCount: Int64 = 0
    private var queuedBytes: UInt64 = 0u64
    private var schedulerState = Http2WriteSchedulerState.Open
    private var writerClaimed = false
    private var writerRunning = false
    private var controlBurst: Int64 = 0
    private var active: ?Http2QueuedWrite = None<Http2QueuedWrite>
    private var transportTerminalClaimed = false

    public prop state: Http2WriteSchedulerState { get() { synchronized(mutex) { schedulerState } } }
    public prop pendingWrites: Int64 { get() { synchronized(mutex) { queuedCount } } }
    public prop pendingBytes: UInt64 { get() { synchronized(mutex) { queuedBytes } } }
    public prop isWriterRunning: Bool { get() { synchronized(mutex) { writerRunning } } }

    public init(transport: DuplexTransport, limits!: Http2Limits = Http2Limits()) {
        this.transport = transport
        this.limits = limits
    }

    /** Fails immediately instead of exceeding either configured queue bound. */
    public func enqueue(frame: Http2Frame): Http2WriteTicket {
        let bytes = serializeHttp2Frame(frame)
        synchronized(mutex) {
            if (!isSchedulerOpen(schedulerState)) {
                throw IllegalStateException("HTTP/2 write scheduler is not accepting frames")
            }
            if (queuedCount >= Int64(limits.maxPendingWrites)) {
                throw Http2WriteQueueFullException("HTTP/2 pending write count reached the configured limit")
            }
            let size = UInt64(bytes.size)
            if (size > UInt64(limits.maxPendingWriteBytes) -
                min(queuedBytes, UInt64(limits.maxPendingWriteBytes))) {
                throw Http2WriteQueueFullException("HTTP/2 pending write bytes reached the configured limit")
            }
            let id = nextId
            nextId += 1
            let ticket = Http2WriteTicket(id, frame.header.streamId, this)
            let item = Http2QueuedWrite(id, frame.header.streamId, bytes, ticket)
            if (isDataFrame(frame.header.frameType)) { enqueueDataLocked(item) }
            else { controls.add(item) }
            queuedCount += 1
            queuedBytes += size
            changed.notifyAll()
            ticket
        }
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
            if (isSchedulerTerminal(schedulerState)) { return }
            schedulerState = Http2WriteSchedulerState.Failed
            let claimed = drainQueuedLocked()
            changed.notifyAll()
            claimed
        }
        for (item in failed) { item.ticket.markFailed("HTTP/2 write scheduler aborted") }
        abortTransportOnce(reason)
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
            let item = removeQueuedLocked(id)
            if (let Some(value) <- item) {
                queuedCount -= 1
                queuedBytes -= UInt64(value.bytes.size)
                changed.notifyAll()
            }
            item
        }
        match (removed) {
            case Some(item) => item.ticket.markCancelled(); true
            case None => false
        }
    }

    private func runWriter(context: OperationContext): Unit {
        while (true) {
            let item = takeNext(context)
            match (item) {
                case None => return
                case Some(value) =>
                    value.ticket.markWriting()
                    writeQueued(value, context)
                    let shouldFail = synchronized(mutex) {
                        active = None<Http2QueuedWrite>
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
            active = Some(item)
            Some(item)
        }
    }

    private func selectNextLocked(): Http2QueuedWrite {
        if (!controls.isEmpty() && (controlBurst < HTTP2_MAX_CONTROL_BURST || dataStreams.isEmpty())) {
            controlBurst += 1
            return controls.remove(at: 0)
        }
        if (!dataStreams.isEmpty()) {
            controlBurst = 0
            let queue = dataStreams.remove(at: 0)
            let item = queue.items.remove(at: 0)
            if (!queue.items.isEmpty()) { dataStreams.add(queue) }
            return item
        }
        controlBurst += 1
        controls.remove(at: 0)
    }

    private func enqueueDataLocked(item: Http2QueuedWrite): Unit {
        for (queue in dataStreams) {
            if (queue.streamId.value == item.streamId.value) { queue.items.add(item); return }
        }
        let queue = Http2DataWriteQueue(item.streamId)
        queue.items.add(item)
        dataStreams.add(queue)
    }

    private func removeQueuedLocked(id: Int64): ?Http2QueuedWrite {
        for (index in 0..controls.size) {
            if (controls[index].id == id) { return Some(controls.remove(at: index)) }
        }
        for (queueIndex in 0..dataStreams.size) {
            let queue = dataStreams[queueIndex]
            for (itemIndex in 0..queue.items.size) {
                if (queue.items[itemIndex].id == id) {
                    let item = queue.items.remove(at: itemIndex)
                    if (queue.items.isEmpty()) { let _ = dataStreams.remove(at: queueIndex) }
                    return Some(item)
                }
            }
        }
        None<Http2QueuedWrite>
    }

    private func drainQueuedLocked(): Array<Http2QueuedWrite> {
        let output = ArrayList<Http2QueuedWrite>()
        for (item in controls) { output.add(item) }
        controls.clear()
        for (queue in dataStreams) { for (item in queue.items) { output.add(item) } }
        dataStreams.clear()
        queuedCount = 0
        queuedBytes = 0u64
        output.toArray()
    }

    private func failWriter(reason: String): Unit {
        let (queued, writing) = synchronized(mutex) {
            schedulerState = Http2WriteSchedulerState.Failed
            let pending = drainQueuedLocked()
            let current = active
            active = None<Http2QueuedWrite>
            changed.notifyAll()
            (pending, current)
        }
        for (item in queued) { item.ticket.markFailed(reason) }
        if (let Some(item) <- writing) { item.ticket.markFailed(reason) }
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
            if (transportTerminalClaimed) { false }
            else { transportTerminalClaimed = true; true }
        }
        if (claimed) { try { transport.abort(reason: Some(reason)) } catch (_: Exception) {} }
    }

}

private class Http2QueuedWrite {
    let id: Int64
    let streamId: Http2StreamId
    let bytes: Array<Byte>
    let ticket: Http2WriteTicket
    init(id: Int64, streamId: Http2StreamId, bytes: Array<Byte>, ticket: Http2WriteTicket) {
        this.id = id
        this.streamId = streamId
        this.bytes = bytes
        this.ticket = ticket
    }
}

private class Http2DataWriteQueue {
    let streamId: Http2StreamId
    let items = ArrayList<Http2QueuedWrite>()
    init(streamId: Http2StreamId) { this.streamId = streamId }
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
