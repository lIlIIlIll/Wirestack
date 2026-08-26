package wirestack.internal.transport

import std.collection.*
import std.sync.*

/** One deterministic action consumed by ScriptedTransport. */
public enum ScriptedTransportStep {
    /** Blocks until the supplied waiter is manually released or the context ends. */
    | Delay(VirtualWaiter)
    /** Limits one delegated operation to at most count bytes. */
    | Short(Int64)
    /** Returns peer EOF without consulting the delegated transport. */
    | EndOfStream
    /** Terminates the transport and raises a reset at the selected phase. */
    | Reset(NetworkPhase)
    /** Raises one structured, non-terminal injected failure. */
    | Failure(NetworkErrorCategory, NetworkPhase, NetworkErrorCode, Retryability)
}

/**
 * Bounded FIFO waiter controlled entirely by tests. No operation is released
 * until releaseNext or releaseAll is called, so delay scripts do not depend on
 * wall-clock sleeps or scheduler timing.
 */
public class VirtualWaiter {
    private let capacity: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let pending = ArrayList<VirtualWaitEntry>()
    private var nextId: Int64 = 1

    public init(capacity!: Int64 = 1024) {
        if (capacity <= 0) {
            throw IllegalArgumentException("virtual waiter capacity must be positive")
        }
        this.capacity = capacity
    }

    public prop pendingCount: Int64 {
        get() { synchronized(mutex) { pending.size } }
    }

    /** Releases the oldest blocked operation, if one exists. */
    public func releaseNext(): Bool {
        synchronized(mutex) {
            if (pending.isEmpty()) { return false }
            let entry = pending.remove(at: 0)
            entry.released = true
            changed.notifyAll()
            true
        }
    }

    /** Releases every currently blocked operation and returns their count. */
    public func releaseAll(): Int64 {
        synchronized(mutex) {
            let count = pending.size
            for (entry in pending) {
                entry.released = true
            }
            pending.clear()
            changed.notifyAll()
            count
        }
    }

    internal func wait(
        context: OperationContext,
        category: NetworkErrorCategory,
        phase: NetworkPhase
    ): Unit {
        scriptedPreflight(context, category, phase)
        let entry = synchronized(mutex) {
            if (pending.size >= capacity) {
                throw NetworkException(
                    NetworkErrorCategory.ResourceExhausted,
                    phase,
                    NetworkErrorCode.ResourceExhausted,
                    "virtual waiter queue is full",
                    retryability: Retryability.Never
                )
            }
            let value = VirtualWaitEntry(nextId)
            nextId++
            pending.add(value)
            value
        }
        let registration = context.cancellation.register { => wakeAll() }
        try {
            synchronized(mutex) {
                while (!entry.released) {
                    scriptedPreflight(context, category, phase)
                    match (context.deadline) {
                        case Some(deadline) =>
                            let remaining = deadline.remaining()
                            if (remaining <= Duration.Zero) {
                                throw scriptedDeadline(category, phase)
                            }
                            changed.wait(timeout: remaining)
                        case None => changed.wait()
                    }
                }
                scriptedPreflight(context, category, phase)
            }
        } finally {
            registration.unregister()
            remove(entry.id)
        }
    }

    private func wakeAll(): Unit {
        synchronized(mutex) { changed.notifyAll() }
    }

    private func remove(id: Int64): Unit {
        synchronized(mutex) {
            for (index in 0..pending.size) {
                if (pending[index].id == id) {
                    let _ = pending.remove(at: index)
                    return
                }
            }
        }
    }
}

private class VirtualWaitEntry {
    let id: Int64
    var released = false

    init(id: Int64) {
        this.id = id
    }
}

/**
 * Deterministic fault-injection wrapper around any DuplexTransport. Read and
 * write scripts are independent bounded FIFO queues. Empty I/O never consumes
 * a script step, and an exhausted script delegates normally.
 */
public class ScriptedTransport <: DuplexTransport {
    private let delegate: DuplexTransport
    private let mutex = Mutex()
    private let readSteps = ArrayList<ScriptedTransportStep>()
    private let writeSteps = ArrayList<ScriptedTransportStep>()
    private let waiters = ArrayList<VirtualWaiter>()
    private let lifecycle = TransportLifecycle()

    public init(
        delegate: DuplexTransport,
        readScript!: Array<ScriptedTransportStep> = [],
        writeScript!: Array<ScriptedTransportStep> = [],
        maxScriptSteps!: Int64 = 1024
    ) {
        if (maxScriptSteps <= 0) {
            throw IllegalArgumentException("script capacity must be positive")
        }
        if (readScript.size > maxScriptSteps || writeScript.size > maxScriptSteps) {
            throw IllegalArgumentException("transport script exceeds its bounded capacity")
        }
        this.delegate = delegate
        appendValidated(readSteps, readScript, true)
        appendValidated(writeSteps, writeScript, false)
        lifecycle.markAccepted()
        lifecycle.markOpen()
    }

    public prop info: TransportInfo {
        get() {
            let base = delegate.info
            TransportInfo(
                "scripted(${base.backend})",
                runtimeIoBackend: "deterministic",
                localEndpoint: base.localEndpoint,
                remoteEndpoint: base.remoteEndpoint,
                supportsHalfClose: base.supportsHalfClose,
                supportsAbort: base.supportsAbort
            )
        }
    }

    public prop remainingReadSteps: Int64 {
        get() { synchronized(mutex) { readSteps.size } }
    }

    public prop remainingWriteSteps: Int64 {
        get() { synchronized(mutex) { writeSteps.size } }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        scriptedPreflight(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
        lifecycle.beginRead()
        try {
            if (destination.isEmpty()) { return ReadResult.Data(0) }
            while (true) {
                match (takeReadStep()) {
                    case None => return delegate.readSome(destination, context: context)
                    case Some(ScriptedTransportStep.Delay(waiter)) =>
                        waiter.wait(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
                        lifecycle.requireReadable()
                    case Some(ScriptedTransportStep.Short(count)) =>
                        let bounded = min(count, destination.length)
                        return delegate.readSome(destination.slice(0, length: bounded), context: context)
                    case Some(ScriptedTransportStep.EndOfStream) => return ReadResult.EndOfStream
                    case Some(ScriptedTransportStep.Reset(phase)) =>
                        failWithReset(NetworkErrorCategory.Read, phase)
                    case Some(ScriptedTransportStep.Failure(category, phase, code, retryability)) =>
                        throw scriptedFailure(category, phase, code, retryability)
                }
            }
            throw IllegalStateException("unreachable scripted read loop")
        } finally {
            lifecycle.endRead()
        }
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        scriptedPreflight(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
        lifecycle.beginWrite()
        try {
            if (source.isEmpty()) { return 0 }
            while (true) {
                match (takeWriteStep()) {
                    case None => return delegate.writeSome(source, context: context)
                    case Some(ScriptedTransportStep.Delay(waiter)) =>
                        waiter.wait(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
                        lifecycle.requireWritable()
                    case Some(ScriptedTransportStep.Short(count)) =>
                        let bounded = min(count, source.length)
                        return delegate.writeSome(source.slice(0, length: bounded), context: context)
                    case Some(ScriptedTransportStep.EndOfStream) =>
                        throw IllegalStateException("EndOfStream is not valid in a write script")
                    case Some(ScriptedTransportStep.Reset(phase)) =>
                        failWithReset(NetworkErrorCategory.Write, phase)
                    case Some(ScriptedTransportStep.Failure(category, phase, code, retryability)) =>
                        throw scriptedFailure(category, phase, code, retryability)
                }
            }
            throw IllegalStateException("unreachable scripted write loop")
        } finally {
            lifecycle.endWrite()
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit {
        if (!lifecycle.shutdown(direction)) { return }
        releaseWaiters()
        delegate.shutdown(direction)
    }

    public func close(context: OperationContext): Unit {
        if (lifecycle.beginClose()) {
            releaseWaiters()
            delegate.close(context)
            let _ = lifecycle.markClosed()
        }
    }

    public func close(): Unit {
        close(OperationContext.background())
    }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        if (lifecycle.abort()) {
            releaseWaiters()
            delegate.abort(reason: reason)
        }
    }

    public func isClosed(): Bool {
        lifecycle.isTerminal
    }

    private func takeReadStep(): ?ScriptedTransportStep {
        synchronized(mutex) {
            if (readSteps.isEmpty()) { None<ScriptedTransportStep> }
            else { Some(readSteps.remove(at: 0)) }
        }
    }

    private func takeWriteStep(): ?ScriptedTransportStep {
        synchronized(mutex) {
            if (writeSteps.isEmpty()) { None<ScriptedTransportStep> }
            else { Some(writeSteps.remove(at: 0)) }
        }
    }

    private func appendValidated(
        target: ArrayList<ScriptedTransportStep>,
        script: Array<ScriptedTransportStep>,
        reading: Bool
    ): Unit {
        for (step in script) {
            match (step) {
                case ScriptedTransportStep.Short(count) =>
                    if (count <= 0) {
                        throw IllegalArgumentException("short I/O count must be positive")
                    }
                case ScriptedTransportStep.EndOfStream =>
                    if (!reading) {
                        throw IllegalArgumentException("EndOfStream is only valid in a read script")
                    }
                case ScriptedTransportStep.Delay(waiter) => waiters.add(waiter)
                case _ => ()
            }
            target.add(step)
        }
    }

    private func releaseWaiters(): Unit {
        for (waiter in waiters) {
            let _ = waiter.releaseAll()
        }
    }

    private func failWithReset(category: NetworkErrorCategory, phase: NetworkPhase): Nothing {
        let _ = lifecycle.fail()
        releaseWaiters()
        delegate.abort(reason: None<AbortReason>)
        throw NetworkException(
            category,
            phase,
            NetworkErrorCode.ConnectionReset,
            "scripted transport reset",
            retryability: Retryability.SafeBeforeWrite
        )
    }
}

private func scriptedPreflight(
    context: OperationContext,
    category: NetworkErrorCategory,
    phase: NetworkPhase
): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            category,
            phase,
            NetworkErrorCode.Cancelled,
            "scripted operation cancelled",
            retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw scriptedDeadline(category, phase)
    }
}

private func scriptedDeadline(
    category: NetworkErrorCategory,
    phase: NetworkPhase
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.TimedOut,
        "scripted operation deadline exceeded",
        retryability: Retryability.Temporary
    )
}

private func scriptedFailure(
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    code: NetworkErrorCode,
    retryability: Retryability
): NetworkException {
    NetworkException(
        category,
        phase,
        code,
        "scripted transport failure",
        retryability: retryability
    )
}
