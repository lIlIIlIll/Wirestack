package wirestack.internal.http2

import std.sync.Mutex
import wirestack.internal.transport.*

/** Bounded inbound byte owner used by one stream-scoped duplex transport. */
public interface Http2DuplexInbound {
    func readSome(destination: MutableByteSpan, context: OperationContext): ReadResult
    func discard(): Unit
    func awaitEnd(context: OperationContext): Unit
}

/**
 * A provider-neutral DuplexTransport backed by exactly one HTTP/2 stream.
 * The connection reader and writer scheduler remain the only transport I/O owners.
 */
public class Http2StreamTransport <: DuplexTransport {
    private let streamId: Http2StreamId
    private let inbound: Http2DuplexInbound
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let writer: Http2WriteScheduler
    private let reset: Http2StreamResetManager
    private let limits: Http2Limits
    private let onTerminated: () -> Unit
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var readActive = false
    private var writeActive = false
    private var readShutdown = false
    private var writeShutdown = false
    private var writeEnded = false
    private var peerEnded = false
    private var terminal = false

    public prop info: TransportInfo {
        get() { TransportInfo("http2-stream", runtimeIoBackend: "wirestack-h2") }
    }

    internal init(
        streamId: Http2StreamId,
        inbound: Http2DuplexInbound,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        writer: Http2WriteScheduler,
        reset: Http2StreamResetManager,
        limits: Http2Limits,
        onTerminated: () -> Unit
    ) {
        this.streamId = streamId
        this.inbound = inbound
        this.registry = registry
        this.flow = flow
        this.writer = writer
        this.reset = reset
        this.limits = limits
        this.onTerminated = onTerminated
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        if (destination.isEmpty()) { return ReadResult.Data(0) }
        synchronized(mutex) {
            if (terminal || readShutdown) { return ReadResult.EndOfStream }
            if (readActive) { throw IllegalStateException("HTTP/2 duplex stream already has an active reader") }
            readActive = true
        }
        try {
            let result = inbound.readSome(destination, context)
            match (result) {
                case ReadResult.EndOfStream => synchronized(mutex) { peerEnded = true }
                case _ => ()
            }
            completeIfFinished()
            result
        } catch (error: Exception) {
            if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                abort(reason: if (context.isCancellationRequested()) {
                    Some(AbortReason.Cancelled)
                } else {
                    Some(AbortReason.DeadlineExceeded)
                })
            }
            throw error
        } finally {
            synchronized(mutex) { readActive = false }
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        if (source.isEmpty()) { return 0 }
        synchronized(mutex) {
            if (terminal || writeShutdown) { throw IllegalStateException("HTTP/2 duplex stream write side is closed") }
            if (writeActive) { throw IllegalStateException("HTTP/2 duplex stream already has an active writer") }
            writeActive = true
        }
        try {
            let permit = flow.reserveSend(streamId, source.length, context: context)
            let payload = Array<Byte>(permit.amount, repeat: 0u8)
            for (index in 0..permit.amount) { payload[index] = source.bytes[source.offset + index] }
            let frame = Http2Frame(
                Http2FrameHeader(
                    UInt32(payload.size), Http2FrameType.Data, Http2Flags(), streamId, limits: limits
                ),
                payload
            )
            waitDuplexWrite(writer.enqueueReservedData(frame, permit), context)
            permit.amount
        } catch (error: Exception) {
            if (context.isCancellationRequested() || context.isDeadlineExceeded()) {
                abort(reason: if (context.isCancellationRequested()) {
                    Some(AbortReason.Cancelled)
                } else {
                    Some(AbortReason.DeadlineExceeded)
                })
            }
            throw error
        } finally {
            let sendEnd = synchronized(mutex) {
                writeActive = false
                writeShutdown && !terminal
            }
            if (sendEnd) {
                // A deferred half-close failure terminates the stream without
                // replacing the admitted DATA operation's result.
                try { enqueueWriteEnd() } catch (_: Exception) {}
            }
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit {
        match (direction) {
            case ShutdownDirection.Read => shutdownRead()
            case ShutdownDirection.Write => shutdownWrite()
        }
    }

    public func close(context: OperationContext): Unit {
        try {
            checkDuplexCloseContext(context)
            shutdownWrite()
            awaitWriteEnd(context)
            inbound.awaitEnd(context)
            synchronized(mutex) { peerEnded = true; readShutdown = true }
            completeIfFinished()
        } catch (error: Exception) {
            abort(reason: if (context.isCancellationRequested()) {
                Some(AbortReason.Cancelled)
            } else if (context.isDeadlineExceeded()) {
                Some(AbortReason.DeadlineExceeded)
            } else {
                Some(AbortReason.ApplicationAbort)
            })
            throw error
        }
    }

    /** Resource cleanup is prompt and stream-local. */
    public func close(): Unit { abort(reason: Some(AbortReason.ApplicationAbort)) }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        let won = synchronized(mutex) {
            if (terminal) { false } else {
                terminal = true
                readShutdown = true
                writeShutdown = true
                changed.notifyAll()
                true
            }
        }
        if (!won) { return }
        try { inbound.discard() } catch (_: Exception) {}
        try { let _ = reset.cancelLocal(streamId) } catch (_: Exception) {}
        onTerminated()
    }

    public func isClosed(): Bool { synchronized(mutex) { terminal } }

    /** Called by the serialized connection reader after END_STREAM or reset. */
    internal func peerTerminated(resetStream!: Bool = false): Unit {
        synchronized(mutex) {
            peerEnded = true
            if (resetStream) { readShutdown = true; writeShutdown = true }
        }
        if (resetStream) { complete(true) } else { completeIfFinished() }
    }

    private func shutdownRead(): Unit {
        let discard = synchronized(mutex) {
            if (terminal || readShutdown) { false } else { readShutdown = true; true }
        }
        if (discard) { inbound.discard() }
        completeIfFinished()
    }

    private func shutdownWrite(): Unit {
        let send = synchronized(mutex) {
            if (terminal || writeShutdown) { false } else {
                writeShutdown = true
                !writeActive
            }
        }
        if (send) { enqueueWriteEnd() }
    }

    private func enqueueWriteEnd(): Unit {
        try {
            let frame = Http2Frame(
                Http2FrameHeader(
                    0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8), streamId, limits: limits
                ),
                []
            )
            writer.enqueue(frame).whenTerminal { state => finishWriteEnd(state) }
        } catch (error: Exception) {
            try { abort(reason: Some(AbortReason.ApplicationAbort)) } catch (_: Exception) {}
            throw error
        }
    }

    private func finishWriteEnd(state: Http2WriteState): Unit {
        try {
            match (state) {
                case Http2WriteState.Written =>
                    if (synchronized(mutex) { terminal }) { return }
                    registry.localEnd(streamId)
                    synchronized(mutex) {
                        if (!terminal) { writeEnded = true }
                        changed.notifyAll()
                    }
                    completeIfFinished()
                case _ => abort(reason: Some(AbortReason.ApplicationAbort))
            }
        } catch (_: Exception) {
            // Completion runs on the connection writer or a reset caller.
            // Stream-local cleanup must not poison that connection owner.
            try { abort(reason: Some(AbortReason.ApplicationAbort)) } catch (_: Exception) {}
        }
    }

    private func awaitWriteEnd(context: OperationContext): Unit {
        let registration = context.cancellation.register { =>
            synchronized(mutex) { changed.notifyAll() }
        }
        try {
            synchronized(mutex) {
                while (!writeEnded) {
                    checkDuplexCloseContext(context)
                    if (terminal) {
                        throw IllegalStateException("HTTP/2 duplex stream closed before END_STREAM completed")
                    }
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
            }
        } finally { registration.unregister() }
    }

    private func completeIfFinished(): Unit {
        let finished = synchronized(mutex) { writeEnded && peerEnded }
        if (finished) { complete(false) }
    }

    private func complete(force: Bool): Unit {
        let won = synchronized(mutex) {
            if (terminal) { false } else if (!force && !(writeEnded && peerEnded)) { false } else {
                terminal = true
                readShutdown = true
                writeShutdown = true
                changed.notifyAll()
                true
            }
        }
        if (!won) { return }
        try { inbound.discard() } catch (_: Exception) {}
        onTerminated()
    }
}

private func waitDuplexWrite(ticket: Http2WriteTicket, context: OperationContext): Unit {
    match (ticket.wait(context: context)) {
        case Http2WriteState.Written => ()
        case Http2WriteState.Cancelled => throw IllegalStateException("HTTP/2 duplex write was cancelled")
        case Http2WriteState.Failed => throw IllegalStateException("HTTP/2 duplex write failed: ${ticket.failure}")
        case _ => throw IllegalStateException("HTTP/2 duplex write did not terminate")
    }
}

private func checkDuplexCloseContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 duplex close cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 duplex close deadline exceeded", retryability: Retryability.Never
        )
    }
}
