package wirestack.net

import std.sync.*
import wirestack as api
import wirestack.NetworkEndpoint
import wirestack.internal.transport_stdnet as stdnet

private const UDP_PAYLOAD_LIMIT: Int64 = 65507

/**
 * Linux Internet datagram socket backed by the std.net UDP adapter.
 *
 * The socket retains resolved endpoints only. One send-like and one receive-like
 * operation may overlap, while same-direction overlap and connect races fail
 * with a structured concurrent-operation error.
 */
public class UdpSocket <: DatagramSocket {
    private let delegate: stdnet.StdNetUdpSocket
    private let localEndpointValue: NetworkEndpoint
    private let capabilityValue = SocketCapabilities(
        nonBlocking: true,
        closeOnExec: true,
        halfClose: false,
        broadcast: true,
        multicast: true,
        raw: false,
        ancillaryData: false,
        zeroLengthDatagramSend: false
    )
    private let lifecycleMutex = Mutex()
    private var lifecycleState = SocketState.Open
    private var remoteEndpointValue: ?NetworkEndpoint = None<NetworkEndpoint>
    private var closeActive = false
    private var closeCoordination: ?SocketCloseCoordination = None<SocketCloseCoordination>

    internal init(delegate: stdnet.StdNetUdpSocket) {
        this.delegate = delegate
        this.localEndpointValue = NetworkEndpoint.Internet(delegate.localEndpoint)
        this.remoteEndpointValue = match (delegate.remoteEndpoint) {
            case Some(endpoint) => Some(NetworkEndpoint.Internet(endpoint))
            case None => None<NetworkEndpoint>
        }
    }

    /** Binds an Internet datagram socket without DNS.
     * @param endpoint Local resolved IP endpoint; port zero asks the kernel to allocate one.
     * @param context Shared absolute deadline and cancellation token.
     * @return A bound UDP socket.
     */
    public static func bind(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): UdpSocket {
        let local = Some(NetworkEndpoint.Internet(endpoint))
        try {
            let delegate = stdnet.StdNetUdpSocket.bind(endpoint, context: context)
            try {
                UdpSocket(delegate)
            } catch (error: Exception) {
                try {
                    delegate.close()
                } catch (_: Exception) {}
                throw error
            }
        } catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.Address,
                api.NetworkPhase.AddressSelection,
                local,
                None<NetworkEndpoint>
            )
        }
    }

    /** Current lifecycle, including cancellation-owned abort. */
    public prop state: SocketState {
        get() {
            retainAbortOwnership()
            synchronized(lifecycleMutex) { lifecycleState }
        }
    }

    /** Linux std.net datagram capabilities qualified for this backend. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }

    /** Immutable bound endpoint, including a kernel-selected port. */
    public prop localEndpoint: ?NetworkEndpoint { get() { Some(localEndpointValue) } }

    /** Selected native UDP peer, or none before connect succeeds. */
    public prop remoteEndpoint: ?NetworkEndpoint {
        get() { synchronized(lifecycleMutex) { remoteEndpointValue } }
    }

    /** Selects a resolved Internet peer and installs the native receive filter.
     * @param endpoint Resolved peer; Unix endpoints are unsupported by this adapter.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func connect(
        endpoint: NetworkEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        let internet = requireUdpInternetEndpoint(
            endpoint,
            localEndpoint: Some(localEndpointValue)
        )
        beginConnect(endpoint)
        try {
            delegate.connect(internet, context: context)
            let completed = synchronized(lifecycleMutex) {
                match (lifecycleState) {
                    case SocketState.Connecting =>
                        remoteEndpointValue = Some(endpoint)
                        lifecycleState = SocketState.Open
                        true
                    case _ => false
                }
            }
            if (!completed) {
                throw closedFacadeError(
                    api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend,
                    Some(endpoint)
                )
            }
        } catch (error: Exception) {
            finishConnectFailure()
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.Connect,
                api.NetworkPhase.DatagramSend,
                Some(localEndpointValue),
                Some(endpoint)
            )
            retainAbortOwnership()
            throw reported
        }
    }

    /** Sends one atomic datagram to the selected peer.
     * @param source Non-empty payload of at most 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return Exactly `source.length` after native success.
     */
    public func send(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        validatePublicPayload(source, remoteEndpoint)
        requireOpen(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend)
        try {
            delegate.send(source, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                Some(localEndpointValue),
                remoteEndpoint
            )
            retainAbortOwnership()
            throw reported
        }
    }

    /** Sends one atomic datagram without changing the selected peer.
     * @param endpoint Resolved destination; Unix endpoints are unsupported by this adapter.
     * @param source Non-empty payload of at most 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return Exactly `source.length` after native success.
     */
    public func sendTo(
        endpoint: NetworkEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        let internet = requireUdpInternetEndpoint(
            endpoint,
            localEndpoint: Some(localEndpointValue)
        )
        validatePublicPayload(source, Some(endpoint))
        requireOpen(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend)
        try {
            delegate.sendTo(internet, source, context: context)
        } catch (error: Exception) {
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                Some(localEndpointValue),
                Some(endpoint)
            )
            retainAbortOwnership()
            throw reported
        }
    }

    /** Receives one datagram with an owned payload and preserved source.
     * @param capacity Retained payload capacity from 1 through 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return One datagram; an empty payload is a valid packet, never EOF.
     */
    public func receive(
        capacity: Int64,
        context!: api.OperationContext = api.OperationContext.background()
    ): DatagramReceiveResult {
        if (capacity <= 0 || capacity > UDP_PAYLOAD_LIMIT) {
            throw IllegalArgumentException("UDP receive capacity must be between 1 and 65507")
        }
        requireOpen(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive)
        try {
            let (owned, source, truncated) = delegate.receive(capacity, context: context)
            DatagramReceiveResult(
                Some(NetworkEndpoint.Internet(source)),
                truncated,
                ownedPayload: owned
            )
        } catch (error: Exception) {
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.Read,
                api.NetworkPhase.DatagramReceive,
                Some(localEndpointValue),
                remoteEndpoint
            )
            retainAbortOwnership()
            throw reported
        }
    }

    /**
     * Closes idempotently. Once admitted, cleanup is not abandoned when the
     * caller's completion wait is cancelled or expires.
     * @param context Shared context for waiting on an already-owned close.
     */
    public func close(
        context!: api.OperationContext
    ): Unit {
        try {
            if (isTerminalLifecycle()) { return }
            if (retainAbortOwnership()) { return }
            checkCloseContext(context, Some(localEndpointValue), remoteEndpoint)
            let coordinated = requiresCloseCoordination(context)
            let (ownsClose, coordination) = beginClose(coordinated)
            if (!ownsClose) {
                match (coordination) {
                    case Some(pending) => pending.wait(context, Some(localEndpointValue), remoteEndpoint)
                    case None => ()
                }
                return
            }
            if (!coordinated) {
                let result = runClose(context)
                publishCloseResult(result)
                match (result) {
                    case Some(error) => throw error
                    case None => ()
                }
                return
            }
            let pending = coordination.getOrThrow()
            let cleanupContext = api.OperationContext(
                trace: context.trace,
                eventSink: context.eventSink
            )
            try {
                spawn {
                    let result = runClose(cleanupContext)
                    publishCloseResult(result)
                }
            } catch (error: Exception) {
                let reported = socketFailure(
                    error,
                    api.NetworkErrorCategory.System,
                    api.NetworkPhase.TransportClose,
                    Some(localEndpointValue),
                    remoteEndpoint
                )
                failClose()
                publishCloseResult(Some(reported))
                throw reported
            }
            pending.wait(context, Some(localEndpointValue), remoteEndpoint)
        } catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                Some(localEndpointValue),
                remoteEndpoint
            )
        }
    }

    /** Closes with a background context for Resource callers. */
    public func close(): Unit { close(context: api.OperationContext.background()) }

    /** Aborts idempotently; Aborted is published only if abort owns native close.
     * @param reason Optional local abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        try {
            if (isTerminalLifecycle()) { return }
            try {
                delegate.abort(reason: reason)
            } catch (error: Exception) {
                retainAbortOwnership()
                throw error
            }
            retainAbortOwnership()
        } catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                Some(localEndpointValue),
                remoteEndpoint
            )
        }
    }

    /** Whether this facade has reached a terminal lifecycle. */
    public func isClosed(): Bool {
        match (state) {
            case SocketState.Closed | SocketState.Aborted | SocketState.Failed => true
            case _ => false
        }
    }

    private func beginConnect(endpoint: NetworkEndpoint): Unit {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open => lifecycleState = SocketState.Connecting
                case SocketState.Connecting => throw api.NetworkException(
                    api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "datagram connect is already active",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: Some(endpoint)
                )
                case _ => throw closedFacadeError(
                    api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend,
                    Some(endpoint)
                )
            }
        }
    }

    private func finishConnectFailure(): Unit {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Connecting => lifecycleState = SocketState.Open
                case _ => ()
            }
        }
    }

    private func requireOpen(
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase
    ): Unit {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open => ()
                case SocketState.Connecting => throw api.NetworkException(
                    category,
                    phase,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "datagram connect is active",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: remoteEndpointValue
                )
                case _ => throw closedFacadeError(category, phase, remoteEndpointValue)
            }
        }
    }

    private func closedFacadeError(
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase,
        remote: ?NetworkEndpoint
    ): api.NetworkException {
        api.NetworkException(
            category,
            phase,
            api.NetworkErrorCode.Closed,
            "UDP socket is closed",
            retryability: api.Retryability.Never,
            localEndpoint: Some(localEndpointValue),
            remoteEndpoint: remote
        )
    }

    private func beginClose(coordinated: Bool): (Bool, ?SocketCloseCoordination) {
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Open | SocketState.Connecting | SocketState.Closing =>
                    if (closeActive) {
                        if (closeCoordination.isNone()) {
                            closeCoordination = Some(SocketCloseCoordination())
                        }
                        (false, closeCoordination)
                    } else {
                        let pending = if (coordinated) {
                            Some(SocketCloseCoordination())
                        } else {
                            None<SocketCloseCoordination>
                        }
                        lifecycleState = SocketState.Closing
                        closeActive = true
                        closeCoordination = pending
                        (true, pending)
                    }
                case _ => (false, closeCoordination)
            }
        }
    }

    private func runClose(context: api.OperationContext): ?api.NetworkException {
        try {
            delegate.close(context)
            finishClose()
            None<api.NetworkException>
        } catch (error: Exception) {
            let reported = socketFailure(
                error,
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                Some(localEndpointValue),
                remoteEndpoint
            )
            failClose()
            Some(reported)
        }
    }

    private func finishClose(): Unit {
        let aborted = delegate.wasClosedByAbort()
        synchronized(lifecycleMutex) {
            closeActive = false
            match (lifecycleState) {
                case SocketState.Closing =>
                    lifecycleState = if (aborted) { SocketState.Aborted } else { SocketState.Closed }
                case _ => ()
            }
        }
    }

    private func failClose(): Unit {
        if (retainAbortOwnership()) {
            synchronized(lifecycleMutex) { closeActive = false }
            return
        }
        if (!delegate.isClosed()) {
            try {
                delegate.abort(reason: Some(api.AbortReason.ProtocolFailure))
            } catch (_: Exception) {}
            if (retainAbortOwnership()) {
                synchronized(lifecycleMutex) { closeActive = false }
                return
            }
        }
        synchronized(lifecycleMutex) {
            closeActive = false
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => ()
                case _ => lifecycleState = SocketState.Failed
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

    private func isTerminalLifecycle(): Bool {
        retainAbortOwnership()
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => true
                case _ => false
            }
        }
    }

    private func retainAbortOwnership(): Bool {
        if (!delegate.wasClosedByAbort()) { return false }
        synchronized(lifecycleMutex) {
            match (lifecycleState) {
                case SocketState.Closed | SocketState.Aborted | SocketState.Failed => ()
                case _ => lifecycleState = SocketState.Aborted
            }
        }
        true
    }

    private func validatePublicPayload(
        source: api.ByteSpan,
        diagnosticPeer: ?NetworkEndpoint
    ): Unit {
        if (source.isEmpty()) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Unsupported,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.Unsupported,
                "the current std.net backend cannot send zero-length datagrams",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpointValue),
                remoteEndpoint: diagnosticPeer
            )
        }
        if (source.length > UDP_PAYLOAD_LIMIT) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.MessageTooLarge,
                "UDP datagram payload exceeds 65507 bytes",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpointValue),
                remoteEndpoint: diagnosticPeer
            )
        }
    }
}

private func requireUdpInternetEndpoint(
    endpoint: NetworkEndpoint,
    localEndpoint!: ?NetworkEndpoint = None<NetworkEndpoint>
): api.SocketEndpoint {
    match (endpoint) {
        case NetworkEndpoint.Internet(value) => value
        case NetworkEndpoint.Unix(_) => throw api.NetworkException(
            api.NetworkErrorCategory.Unsupported,
            api.NetworkPhase.AddressSelection,
            api.NetworkErrorCode.Unsupported,
            "the Linux UDP adapter accepts Internet endpoints only",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: Some(endpoint)
        )
    }
}
