package wirestack.net

import std.sync.*
import wirestack as api
import wirestack.internal.transport_stdnet as stdnet

private enum UnixListenerCloseOwner {
    | Unclaimed
    | Graceful
    | Abort
}

/**
 * A bounded Unix-domain stream listener.
 *
 * At most one accept is admitted at a time. Cancellation and deadlines stop
 * only that accept and leave the listener reusable. The listener exclusively
 * owns its backend; the first close or abort owns the single native close.
 * Closing a pathname listener does not unlink its filesystem node; pathname
 * cleanup remains the caller's responsibility.
 */
public class UnixListener <: Resource {
    private let delegate: stdnet.StdNetUnixTransportListener
    private let localEndpointValue: api.UnixEndpoint
    private let capabilityValue = SocketCapabilities(
        nonBlocking: true,
        closeOnExec: true,
        halfClose: false,
        broadcast: false,
        multicast: false,
        raw: false,
        ancillaryData: false,
        zeroLengthDatagramSend: false
    )
    private let lifecycleMutex = Mutex()
    private var lifecycleState = SocketState.Listening
    private var acceptActive = false
    private var closeOwner = UnixListenerCloseOwner.Unclaimed
    private var closeCoordination: ?SocketCloseCoordination = None<SocketCloseCoordination>

    private init(delegate: stdnet.StdNetUnixTransportListener) {
        this.delegate = delegate
        this.localEndpointValue = delegate.localEndpoint
    }

    /**
     * Binds a pathname or Linux abstract listener.
     *
     * Unnamed endpoints are rejected. The backlog is bounded from 1 through
     * 65,535. This std.net backend supports only abstract names of exactly
     * 107 bytes with valid UTF-8, including embedded NUL. Other abstract
     * names fail with Unsupported rather than changing their native identity.
     * A stopped context fails before native binding.
     *
     * @param endpoint Named local Unix endpoint.
     * @param backlog Maximum pending connection backlog, from 1 through 65,535.
     * @param context Absolute deadline and cancellation token for bind admission.
     */
    public static func bind(
        endpoint: api.UnixEndpoint,
        backlog!: Int64 = 128,
        context!: api.OperationContext = api.OperationContext.background()
    ): UnixListener {
        let local = Some(api.NetworkEndpoint.Unix(endpoint))
        try {
            stdnet.checkNetworkContext(context, api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, localEndpoint: local)
            if (backlog <= 0 || backlog > 65535) {
                throw api.NetworkException(api.NetworkErrorCategory.Accept,
                    api.NetworkPhase.ServerAccept, api.NetworkErrorCode.InvalidState,
                    "Unix listener backlog must be between 1 and 65535",
                    retryability: api.Retryability.Never, localEndpoint: local)
            }
            UnixListener(stdnet.StdNetUnixTransportListener.bind(endpoint,
                backlog: backlog))
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, local, None<api.NetworkEndpoint>)
        }
    }

    /** Current retained listener lifecycle state. */
    public prop state: SocketState {
        get() { synchronized(lifecycleMutex) { lifecycleState } }
    }

    /** Advisory capabilities of streams accepted by this Linux backend. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }

    /** Actual bound Unix endpoint reported by the native listener. */
    public prop localEndpoint: api.UnixEndpoint { get() { localEndpointValue } }

    /**
     * Accepts one Unix stream.
     *
     * A second overlapping accept fails with `ConcurrentOperation`. Operation-
     * local cancellation or deadline expiry leaves the listener reusable. A
     * connection completed after its cancelled waiter left is disposed.
     *
     * @param context Absolute deadline and cancellation token for this accept.
     */
    public func accept(
        context!: api.OperationContext = api.OperationContext.background()
    ): UnixStream {
        let local = Some(api.NetworkEndpoint.Unix(localEndpointValue))
        try {
            stdnet.checkNetworkContext(context, api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, localEndpoint: local)
            match (claimAccept()) {
                case 0 => ()
                case 1 => throw socketFailure(
                    stdnet.networkConcurrent(api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept, localEndpoint: local),
                    api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                    local, None<api.NetworkEndpoint>)
                case _ => throw stdnet.networkClosedError(
                    api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept,
                    localEndpoint: local)
            }
            try {
                let accepted = delegate.accept(context)
                wrapAccepted(accepted)
            } finally {
                releaseAccept()
            }
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept, local, None<api.NetworkEndpoint>)
        }
    }

    /**
     * Gracefully closes and wakes an admitted accept.
     *
     * Terminal listeners return before consulting the context. Once graceful
     * cleanup is admitted, a later abort cannot replace or relabel it.
     *
     * @param context Context for waiting for close completion.
     */
    public func close(context!: api.OperationContext): Unit {
        let local = Some(api.NetworkEndpoint.Unix(localEndpointValue))
        try {
            if (isTerminalLifecycle() || abortOwnsClose()) { return }
            checkCloseContext(context, local, None<api.NetworkEndpoint>)
            let coordinated = requiresCloseCoordination(context)
            let (ownsClose, pending) = beginClose(coordinated)
            if (!ownsClose) {
                match (pending) {
                    case Some(value) => value.wait(context, local, None<api.NetworkEndpoint>)
                    case None => ()
                }
                return
            }
            if (!coordinated) {
                let result = runClose()
                publishCloseResult(result)
                match (result) {
                    case Some(error) => throw error
                    case None => ()
                }
                return
            }
            let completion = pending.getOrThrow()
            try {
                spawn {
                    let result = runClose()
                    publishCloseResult(result)
                }
            } catch (_: Exception) {
                let result = runClose()
                publishCloseResult(result)
            }
            completion.wait(context, local, None<api.NetworkEndpoint>)
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose, local, None<api.NetworkEndpoint>)
        }
    }

    /** Closes with a background context for `Resource` callers. */
    public func close(): Unit { close(context: api.OperationContext.background()) }

    /** Reports whether the backend listener has reached its terminal lifecycle. */
    public func isClosed(): Bool { delegate.isClosed() }

    /**
     * Terminates immediately and wakes an admitted accept. Abort publishes
     * `Aborted` only when it wins the first native close.
     * @param reason Optional stable reason for the local abort.
     */
    public func abort(
        reason!: ?api.AbortReason = None<api.AbortReason>
    ): Unit {
        let _ = reason
        let local = Some(api.NetworkEndpoint.Unix(localEndpointValue))
        try {
            if (!claimAbort()) { return }
            try {
                delegate.close()
                finishAbort()
            } catch (error: Exception) {
                failOwnedClose()
                throw error
            }
        } catch (error: Exception) {
            throw socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose, local, None<api.NetworkEndpoint>)
        }
    }

    private func wrapAccepted(accepted: stdnet.SocketTransport): UnixStream {
        try {
            UnixStream(accepted)
        } catch (error: Exception) {
            disposeAccepted(accepted)
            throw error
        }
    }

    private func disposeAccepted(accepted: api.DuplexTransport): Unit {
        try {
            accepted.abort(reason: Some(api.AbortReason.ProtocolFailure))
        } catch (_: Exception) {
            try {
                accepted.close(api.OperationContext.background())
            } catch (_: Exception) {}
        }
    }

    private func claimAccept(): Int64 {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Listening =>
                    if (acceptActive) {
                        1
                    } else {
                        acceptActive = true
                        0
                    }
                case _ => 2
            }
        }
    }

    private func releaseAccept(): Unit {
        synchronized(lifecycleMutex) { acceptActive = false }
    }

    private func beginClose(
        coordinated: Bool
    ): (Bool, ?SocketCloseCoordination) {
        synchronized(lifecycleMutex) {
            match (closeOwner) {
                case UnixListenerCloseOwner.Unclaimed =>
                    match (lifecycleState) {
                        case SocketState.Listening =>
                            let pending = if (coordinated) {
                                Some(SocketCloseCoordination())
                            } else {
                                None<SocketCloseCoordination>
                            }
                            closeOwner = UnixListenerCloseOwner.Graceful
                            lifecycleState = SocketState.Closing
                            closeCoordination = pending
                            (true, pending)
                        case _ => (false, closeCoordination)
                    }
                case UnixListenerCloseOwner.Graceful =>
                    match (lifecycleState) {
                        case SocketState.Closing =>
                            if (closeCoordination.isNone()) {
                                closeCoordination = Some(SocketCloseCoordination())
                            }
                        case _ => ()
                    }
                    (false, closeCoordination)
                case _ => (false, closeCoordination)
            }
        }
    }

    private func runClose(): ?api.NetworkException {
        try {
            delegate.close()
            synchronized(lifecycleMutex) {
                match (closeOwner) {
                    case UnixListenerCloseOwner.Graceful => lifecycleState = SocketState.Closed
                    case _ => ()
                }
            }
            None<api.NetworkException>
        } catch (error: Exception) {
            let reported = socketFailure(error, api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                Some(api.NetworkEndpoint.Unix(localEndpointValue)),
                None<api.NetworkEndpoint>)
            failOwnedClose()
            Some(reported)
        }
    }

    private func claimAbort(): Bool {
        synchronized(lifecycleMutex) {
            match ((closeOwner, lifecycleState)) {
                case (UnixListenerCloseOwner.Unclaimed, SocketState.Listening) =>
                    closeOwner = UnixListenerCloseOwner.Abort
                    lifecycleState = SocketState.Closing
                    true
                case _ => false
            }
        }
    }

    private func finishAbort(): Unit {
        synchronized(lifecycleMutex) {
            match (closeOwner) {
                case UnixListenerCloseOwner.Abort => lifecycleState = SocketState.Aborted
                case _ => ()
            }
        }
    }

    private func failOwnedClose(): Unit {
        synchronized(lifecycleMutex) { lifecycleState = SocketState.Failed }
    }

    private func abortOwnsClose(): Bool {
        synchronized(lifecycleMutex) {
            match (closeOwner) {
                case UnixListenerCloseOwner.Abort => true
                case _ => false
            }
        }
    }

    private func isTerminalLifecycle(): Bool {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => true
                case _ => false
            }
        }
    }

    private func publishCloseResult(result: ?api.NetworkException): Unit {
        let pending = synchronized(lifecycleMutex) {
            let value = closeCoordination
            closeCoordination = None<SocketCloseCoordination>
            value
        }
        match (pending) {
            case Some(value) => value.complete(result)
            case None => ()
        }
    }
}
