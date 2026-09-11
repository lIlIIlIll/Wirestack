package wirestack.net

import std.sync.*
import wirestack as api
import wirestack.internal.transport_stdnet as stdnet

private enum TcpListenerCloseOwner {
    | Unclaimed
    | Graceful
    | Abort
}

/**
 * A bounded Linux TCP listener over resolved Internet endpoints.
 *
 * At most one accept is admitted at a time. Cancellation and deadlines stop
 * only that accept and leave the listener reusable. The listener exclusively
 * owns its backend; the first close or abort owns the single native close.
 */
public class TcpListener <: Resource {
    private let delegate: stdnet.StdNetTransportListener
    private let localEndpointValue: api.SocketEndpoint
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
    private var closeOwner = TcpListenerCloseOwner.Unclaimed
    private var closeCoordination: ?SocketCloseCoordination = None<SocketCloseCoordination>

    private init(delegate: stdnet.StdNetTransportListener) {
        this.delegate = delegate
        this.localEndpointValue = delegate.localEndpoint
    }

    /**
     * Binds a listener to an already-resolved Internet endpoint.
     *
     * The backlog is bounded from 1 through 65,535. A stopped context fails
     * before native binding and does not create a listener.
     *
     * @param endpoint Resolved local Internet endpoint.
     * @param backlog Maximum pending connection backlog, from 1 through 65,535.
     * @param context Absolute deadline and cancellation token for bind admission.
     */
    public static func bind(
        endpoint: api.SocketEndpoint,
        backlog!: Int64 = 128,
        context!: api.OperationContext = api.OperationContext.background()
    ): TcpListener {
        let publicEndpoint = Some(api.NetworkEndpoint.Internet(endpoint))
        try {
            stdnet.checkContext(
                context,
                api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept,
                localEndpoint: Some(endpoint)
            )
            if (backlog <= 0 || backlog > 65535) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Accept,
                    api.NetworkPhase.ServerAccept,
                    api.NetworkErrorCode.InvalidState,
                    "TCP listener backlog must be between 1 and 65535",
                    retryability: api.Retryability.Never,
                    localEndpoint: publicEndpoint
                )
            }
            TcpListener(stdnet.StdNetTransportListener.bind(endpoint, backlog: backlog))
        } catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept,
                publicEndpoint,
                None<api.NetworkEndpoint>
            )
        }
    }

    /** Current retained listener lifecycle state. */
    public prop state: SocketState {
        get() { synchronized(lifecycleMutex) { lifecycleState } }
    }

    /** Advisory capabilities of descriptors created by the Linux listener backend. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }

    /** Actual resolved local endpoint, including an assigned ephemeral port. */
    public prop localEndpoint: api.SocketEndpoint { get() { localEndpointValue } }

    /**
     * Accepts one TCP stream without invoking DNS.
     *
     * A second overlapping accept fails with `ConcurrentOperation` instead of
     * joining a pending queue. Operation-local cancellation or deadline expiry
     * does not close the listener.
     *
     * @param context Absolute deadline and cancellation token for this accept.
     */
    public func accept(
        context!: api.OperationContext = api.OperationContext.background()
    ): TcpStream {
        let local = Some(api.NetworkEndpoint.Internet(localEndpointValue))
        try {
            stdnet.checkContext(
                context,
                api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept,
                localEndpoint: Some(localEndpointValue)
            )
            match (claimAccept()) {
                case 0 => ()
                case 1 => throw socketFailure(
                    stdnet.concurrent(
                        api.NetworkErrorCategory.Accept,
                        api.NetworkPhase.ServerAccept
                    ),
                    api.NetworkErrorCategory.Accept,
                    api.NetworkPhase.ServerAccept,
                    local,
                    None<api.NetworkEndpoint>
                )
                case _ => throw stdnet.closedError(
                    api.NetworkErrorCategory.Accept,
                    api.NetworkPhase.ServerAccept,
                    localEndpoint: Some(localEndpointValue)
                )
            }
            try {
                let accepted = delegate.accept(context)
                wrapAccepted(accepted)
            } finally {
                releaseAccept()
            }
        } catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.Accept,
                api.NetworkPhase.ServerAccept,
                local,
                None<api.NetworkEndpoint>
            )
        }
    }

    /**
     * Gracefully closes the listener and wakes an admitted accept.
     *
     * Terminal listeners return before consulting the caller context. A stopped
     * context rejects an unclaimed close without native effect. Once graceful
     * cleanup is admitted, later aborts cannot relabel or replace it.
     *
     * @param context Context for waiting for close completion.
     */
    public func close(
        context!: api.OperationContext
    ): Unit {
        let local = Some(api.NetworkEndpoint.Internet(localEndpointValue))
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
            throw socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                local,
                None<api.NetworkEndpoint>
            )
        }
    }

    /** Closes the listener with a background context for `Resource` callers. */
    public func close(): Unit { close(context: api.OperationContext.background()) }

    /** Reports whether the backend listener has reached its terminal lifecycle. */
    public func isClosed(): Bool { delegate.isClosed() }

    /**
     * Terminates the listener immediately and wakes an admitted accept.
     *
     * Abort publishes `Aborted` only when it wins the first native close.
     *
     * @param reason Optional stable reason for the local abort.
     */
    public func abort(
        reason!: ?api.AbortReason = None<api.AbortReason>
    ): Unit {
        let _ = reason
        let local = Some(api.NetworkEndpoint.Internet(localEndpointValue))
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
            throw socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                local,
                None<api.NetworkEndpoint>
            )
        }
    }

    private func wrapAccepted(accepted: api.DuplexTransport): TcpStream {
        try {
            match (accepted as stdnet.SocketTransport) {
                case Some(socket) => TcpStream(socket, nonBlocking: true, closeOnExec: true)
                case None => throw IllegalStateException(
                    "std.net listener returned a transport without socket ownership"
                )
            }
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
                case TcpListenerCloseOwner.Unclaimed =>
                    match (lifecycleState) {
                        case SocketState.Listening =>
                            let pending = if (coordinated) {
                                Some(SocketCloseCoordination())
                            } else {
                                None<SocketCloseCoordination>
                            }
                            closeOwner = TcpListenerCloseOwner.Graceful
                            lifecycleState = SocketState.Closing
                            closeCoordination = pending
                            (true, pending)
                        case _ => (false, closeCoordination)
                    }
                case TcpListenerCloseOwner.Graceful =>
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
                    case TcpListenerCloseOwner.Graceful => lifecycleState = SocketState.Closed
                    case _ => ()
                }
            }
            None<api.NetworkException>
        } catch (error: Exception) {
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                Some(api.NetworkEndpoint.Internet(localEndpointValue)),
                None<api.NetworkEndpoint>
            )
            failOwnedClose()
            Some(reported)
        }
    }

    private func claimAbort(): Bool {
        synchronized(lifecycleMutex) {
            match ((closeOwner, lifecycleState)) {
                case (TcpListenerCloseOwner.Unclaimed, SocketState.Listening) =>
                    closeOwner = TcpListenerCloseOwner.Abort
                    lifecycleState = SocketState.Closing
                    true
                case _ => false
            }
        }
    }

    private func finishAbort(): Unit {
        synchronized(lifecycleMutex) {
            match (closeOwner) {
                case TcpListenerCloseOwner.Abort => lifecycleState = SocketState.Aborted
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
                case TcpListenerCloseOwner.Abort => true
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
