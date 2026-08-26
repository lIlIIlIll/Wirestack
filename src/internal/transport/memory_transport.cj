package wirestack.internal.transport

import std.collection.*
import std.sync.*

/** A deterministic, bounded in-memory full-duplex transport pair. */
public class MemoryTransport <: DuplexTransport {
    private let incoming: MemoryBytePipe
    private let outgoing: MemoryBytePipe
    private let maxChunk: Int64
    private let lifecycle = TransportLifecycle()

    private init(incoming: MemoryBytePipe, outgoing: MemoryBytePipe, maxChunk: Int64) {
        this.incoming = incoming
        this.outgoing = outgoing
        this.maxChunk = maxChunk
        lifecycle.markAccepted()
        lifecycle.markOpen()
        let _ = lifecycle.registerTerminalCleanup { =>
            match (lifecycle.state) {
                case TransportState.Closed =>
                    outgoing.closeWriter()
                    incoming.closeReader()
                case TransportState.Aborted | TransportState.Failed =>
                    incoming.abort()
                    outgoing.abort()
                case _ => ()
            }
        }
    }

    public static func pair(
        capacity!: Int64 = 64 * 1024,
        maxChunk!: Int64 = 16 * 1024
    ): (MemoryTransport, MemoryTransport) {
        if (capacity <= 0) {
            throw IllegalArgumentException("memory transport capacity must be positive")
        }
        if (maxChunk <= 0) {
            throw IllegalArgumentException("memory transport maxChunk must be positive")
        }
        let leftToRight = MemoryBytePipe(capacity)
        let rightToLeft = MemoryBytePipe(capacity)
        (
            MemoryTransport(rightToLeft, leftToRight, maxChunk),
            MemoryTransport(leftToRight, rightToLeft, maxChunk)
        )
    }

    public prop info: TransportInfo {
        get() {
            TransportInfo("memory", runtimeIoBackend: "deterministic")
        }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        preflight(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
        lifecycle.beginRead()
        try {
            if (destination.isEmpty()) {
                return ReadResult.Data(0)
            }
            incoming.read(destination, context)
        } finally {
            lifecycle.endRead()
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        preflight(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
        lifecycle.beginWrite()
        try {
            if (source.isEmpty()) {
                return 0
            }
            outgoing.write(source, min(maxChunk, source.length), context)
        } finally {
            lifecycle.endWrite()
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit {
        if (!lifecycle.shutdown(direction)) { return }
        match (direction) {
            case ShutdownDirection.Read => incoming.closeReader()
            case ShutdownDirection.Write => outgoing.closeWriter()
        }
        match (lifecycle.state) {
            case TransportState.Closing => let _ = lifecycle.markClosed()
            case _ => ()
        }
    }

    public func close(context: OperationContext): Unit {
        // Closing this in-memory transport never waits. It must remain usable
        // as cleanup even when the operation budget has already expired.
        let _ = context
        if (lifecycle.beginClose()) {
            let _ = lifecycle.markClosed()
        }
    }

    public func close(): Unit {
        close(OperationContext.background())
    }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        let _ = lifecycle.abort()
    }

    public func isClosed(): Bool {
        lifecycle.isTerminal
    }
}

private class MemoryBytePipe {
    private let capacity: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let bytes = ArrayList<Byte>()
    private var writerClosed = false
    private var readerClosed = false
    private var aborted = false

    init(capacity: Int64) {
        this.capacity = capacity
    }

    func read(destination: MutableByteSpan, context: OperationContext): ReadResult {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (bytes.isEmpty() && !writerClosed && !readerClosed && !aborted) {
                    checkWaitContext(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                    waitForChange(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                }
                checkWaitContext(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                if (aborted) {
                    throw resetOperation(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                }
                if (readerClosed) {
                    throw closedOperation(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                }
                if (bytes.isEmpty() && writerClosed) {
                    return ReadResult.EndOfStream
                }

                let count = min(destination.length, bytes.size)
                for (index in 0..count) {
                    destination.bytes[destination.offset + index] = bytes.remove(at: 0)
                }
                changed.notifyAll()
                ReadResult.Data(count)
            }
        } finally {
            registration.unregister()
        }
    }

    func write(source: ByteSpan, requested: Int64, context: OperationContext): Int64 {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                while (bytes.size >= capacity && !readerClosed && !writerClosed && !aborted) {
                    checkWaitContext(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                    waitForChange(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                }
                checkWaitContext(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                if (aborted) {
                    throw resetOperation(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                }
                if (readerClosed) {
                    throw NetworkException(
                        NetworkErrorCategory.Write,
                        NetworkPhase.TcpWrite,
                        NetworkErrorCode.BrokenPipe,
                        "peer has shut down reading",
                        retryability: Retryability.Never
                    )
                }
                if (writerClosed) {
                    throw closedOperation(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                }

                let count = min(requested, capacity - bytes.size)
                for (index in 0..count) {
                    bytes.add(source.bytes[source.offset + index])
                }
                changed.notifyAll()
                count
            }
        } finally {
            registration.unregister()
        }
    }

    func closeWriter(): Unit {
        synchronized(mutex) {
            writerClosed = true
            changed.notifyAll()
        }
    }

    func closeReader(): Unit {
        synchronized(mutex) {
            readerClosed = true
            bytes.clear()
            changed.notifyAll()
        }
    }

    func abort(): Unit {
        synchronized(mutex) {
            aborted = true
            bytes.clear()
            changed.notifyAll()
        }
    }

    private func wake(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }

    private func waitForChange(
        context: OperationContext,
        category: NetworkErrorCategory,
        phase: NetworkPhase
    ): Unit {
        match (context.deadline) {
            case Some(deadline) =>
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw deadlineOperation(category, phase)
                }
                changed.wait(timeout: remaining)
            case None => changed.wait()
        }
    }
}

private func preflight(context: OperationContext, category: NetworkErrorCategory, phase: NetworkPhase): Unit {
    if (context.isCancellationRequested()) {
        throw cancelledOperation(category, phase)
    }
    if (context.isDeadlineExceeded()) {
        throw deadlineOperation(category, phase)
    }
}

private func checkWaitContext(
    context: OperationContext,
    category: NetworkErrorCategory,
    phase: NetworkPhase
): Unit {
    preflight(context, category, phase)
}

private func closedOperation(category: NetworkErrorCategory, phase: NetworkPhase): NetworkException {
    NetworkException(category, phase, NetworkErrorCode.Closed, "transport direction is closed", retryability: Retryability.Never)
}

private func cancelledOperation(category: NetworkErrorCategory, phase: NetworkPhase): NetworkException {
    NetworkException(category, phase, NetworkErrorCode.Cancelled, "operation cancelled", retryability: Retryability.Never)
}

private func deadlineOperation(category: NetworkErrorCategory, phase: NetworkPhase): NetworkException {
    NetworkException(category, phase, NetworkErrorCode.TimedOut, "operation deadline exceeded", retryability: Retryability.Temporary)
}

private func resetOperation(category: NetworkErrorCategory, phase: NetworkPhase): NetworkException {
    NetworkException(category, phase, NetworkErrorCode.ConnectionReset, "peer aborted transport", retryability: Retryability.SafeBeforeWrite)
}
