package wirestack.internal.transport

import std.sync.*

/**
 * Serialized Transport lifecycle with bounded exactly-once terminal cleanup.
 *
 * State mutation is complete before terminal cleanup runs. Cleanup therefore
 * executes without the lifecycle lock and may safely inspect or re-enter this
 * object. Terminal states never overwrite one another.
 */
public class TransportLifecycle {
    private let mutex = Mutex()
    private let completion: OperationCompletion
    private var current = TransportState.Created
    private var readActive = false
    private var writeActive = false

    public prop state: TransportState { get() { synchronized(mutex) { current } } }

    public prop isTerminal: Bool {
        get() { synchronized(mutex) { isTerminalTransportState(current) } }
    }

    public init(maxTerminalCleanups!: UInt32 = 16u32) {
        completion = OperationCompletion(maxCleanups: maxTerminalCleanups)
    }

    /** Registers a resource that every terminal transition releases once. */
    public func registerTerminalCleanup(cleanup: () -> Unit): OperationCleanupRegistration {
        completion.registerCleanup(cleanup)
    }

    public func markConnecting(): Unit {
        synchronized(mutex) {
            match (current) {
                case TransportState.Created => current = TransportState.Connecting
                case _ => throw invalidLifecycleTransition(NetworkPhase.TcpConnect)
            }
        }
    }

    public func markAccepted(): Unit {
        synchronized(mutex) {
            match (current) {
                case TransportState.Created => current = TransportState.Accepted
                case _ => throw invalidLifecycleTransition(NetworkPhase.ServerAccept)
            }
        }
    }

    public func markOpen(): Unit {
        synchronized(mutex) {
            match (current) {
                case TransportState.Connecting | TransportState.Accepted => current = TransportState.Open
                case _ => throw invalidLifecycleTransition(NetworkPhase.TcpConnect)
            }
        }
    }

    /**
     * Shuts down one direction. Repeating the same direction is idempotent;
     * shutting the remaining direction moves the transport to Closing.
     */
    public func shutdown(direction: ShutdownDirection): Bool {
        synchronized(mutex) {
            match ((current, direction)) {
                case (TransportState.Open, ShutdownDirection.Read) =>
                    current = TransportState.ReadHalfClosed
                    true
                case (TransportState.Open, ShutdownDirection.Write) =>
                    current = TransportState.WriteHalfClosed
                    true
                case (TransportState.ReadHalfClosed, ShutdownDirection.Read) => false
                case (TransportState.WriteHalfClosed, ShutdownDirection.Write) => false
                case (TransportState.ReadHalfClosed, ShutdownDirection.Write) |
                     (TransportState.WriteHalfClosed, ShutdownDirection.Read) =>
                    current = TransportState.Closing
                    true
                case (TransportState.Created, _) | (TransportState.Connecting, _) |
                     (TransportState.Accepted, _) =>
                    throw invalidLifecycleTransition(NetworkPhase.TransportClose)
                case _ => throw closedLifecycleOperation(
                    NetworkErrorCategory.Shutdown,
                    NetworkPhase.TransportClose
                )
            }
        }
    }

    /** Starts graceful close once from an open or half-closed transport. */
    public func beginClose(): Bool {
        synchronized(mutex) {
            match (current) {
                case TransportState.Open | TransportState.ReadHalfClosed |
                     TransportState.WriteHalfClosed =>
                    current = TransportState.Closing
                    true
                case TransportState.Closing | TransportState.Closed |
                     TransportState.Aborted | TransportState.Failed => false
                case _ => throw invalidLifecycleTransition(NetworkPhase.TransportClose)
            }
        }
    }

    /** Publishes Closed once and releases every registered terminal resource. */
    public func markClosed(): Bool {
        let changed = synchronized(mutex) {
            match (current) {
                case TransportState.Closing => current = TransportState.Closed; true
                case TransportState.Closed | TransportState.Aborted | TransportState.Failed => false
                case _ => throw invalidLifecycleTransition(NetworkPhase.TransportClose)
            }
        }
        if (changed) { let _ = completion.tryComplete() }
        changed
    }

    /** Publishes Aborted once. No existing terminal state is overwritten. */
    public func abort(): Bool {
        transitionToTerminal(TransportState.Aborted)
    }

    /** Publishes Failed once. No existing terminal state is overwritten. */
    public func fail(): Bool {
        transitionToTerminal(TransportState.Failed)
    }

    /** Rejects reads before Open and after the read direction closes. */
    public func requireReadable(): Unit {
        synchronized(mutex) {
            requireReadableLocked()
        }
    }

    /** Rejects writes before Open and after the write direction closes. */
    public func requireWritable(): Unit {
        synchronized(mutex) {
            requireWritableLocked()
        }
    }

    /** Atomically validates and claims the single allowed read operation. */
    internal func beginRead(): Unit {
        synchronized(mutex) {
            requireReadableLocked()
            if (readActive) {
                throw concurrentLifecycleOperation(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
            }
            readActive = true
        }
    }

    /** Releases the read claim acquired by beginRead. */
    internal func endRead(): Unit {
        synchronized(mutex) { readActive = false }
    }

    /** Atomically validates and claims the single allowed write operation. */
    internal func beginWrite(): Unit {
        synchronized(mutex) {
            requireWritableLocked()
            if (writeActive) {
                throw concurrentLifecycleOperation(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
            }
            writeActive = true
        }
    }

    /** Releases the write claim acquired by beginWrite. */
    internal func endWrite(): Unit {
        synchronized(mutex) { writeActive = false }
    }

    private func requireReadableLocked(): Unit {
        match (current) {
            case TransportState.Open | TransportState.WriteHalfClosed => ()
            case TransportState.Created | TransportState.Connecting | TransportState.Accepted =>
                throw invalidLifecycleOperation(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
            case _ => throw closedLifecycleOperation(NetworkErrorCategory.Read, NetworkPhase.TcpRead)
        }
    }

    private func requireWritableLocked(): Unit {
        match (current) {
            case TransportState.Open | TransportState.ReadHalfClosed => ()
            case TransportState.Created | TransportState.Connecting | TransportState.Accepted =>
                throw invalidLifecycleOperation(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
            case _ => throw closedLifecycleOperation(NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
        }
    }

    private func transitionToTerminal(target: TransportState): Bool {
        let changed = synchronized(mutex) {
            if (isTerminalTransportState(current)) {
                false
            } else {
                current = target
                true
            }
        }
        if (changed) { let _ = completion.tryComplete() }
        changed
    }
}

private func isTerminalTransportState(state: TransportState): Bool {
    match (state) {
        case TransportState.Closed | TransportState.Aborted | TransportState.Failed => true
        case _ => false
    }
}

private func invalidLifecycleTransition(phase: NetworkPhase): NetworkException {
    invalidLifecycleOperation(NetworkErrorCategory.System, phase)
}

private func invalidLifecycleOperation(
    category: NetworkErrorCategory,
    phase: NetworkPhase
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.InvalidState,
        "transport operation is invalid in the current lifecycle state",
        retryability: Retryability.Never
    )
}

private func closedLifecycleOperation(
    category: NetworkErrorCategory,
    phase: NetworkPhase
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.Closed,
        "transport direction is closed",
        retryability: Retryability.Never
    )
}

private func concurrentLifecycleOperation(
    category: NetworkErrorCategory,
    phase: NetworkPhase
): NetworkException {
    NetworkException(
        category,
        phase,
        NetworkErrorCode.ConcurrentOperation,
        "same-direction transport operation already active",
        retryability: Retryability.Never
    )
}
