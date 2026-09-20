package wirestack.net

import std.sync.*
import wirestack as api
import wirestack.NetworkEndpoint
import wirestack.internal.transport_stdnet as stdnet

private const DATAGRAM_PAYLOAD_LIMIT: Int64 = 65507

/** Shared lifecycle and operation ownership for public datagram facades. */
internal class DatagramSocketFacadeCore {
    private let delegate: stdnet.StdNetDatagramSocket
    private let localEndpointValue: NetworkEndpoint
    private let lifecycleMutex = Mutex()
    private var lifecycleState = SocketState.Open
    private var remoteEndpointValue: ?NetworkEndpoint = None<NetworkEndpoint>
    private var closeActive = false
    private var closeCoordination: ?SocketCloseCoordination = None<SocketCloseCoordination>

    init(delegate: stdnet.StdNetDatagramSocket) {
        this.delegate = delegate
        this.localEndpointValue = delegate.localEndpoint
        this.remoteEndpointValue = delegate.remoteEndpoint
    }

    prop state: SocketState {
        get() {
            retainAbortOwnership()
            synchronized(lifecycleMutex) { lifecycleState }
        }
    }

    prop localEndpoint: NetworkEndpoint { get() { localEndpointValue } }

    prop remoteEndpoint: ?NetworkEndpoint {
        get() { synchronized(lifecycleMutex) { remoteEndpointValue } }
    }

    func connect(
        endpoint: NetworkEndpoint,
        context: api.OperationContext
    ): Unit {
        beginConnect(endpoint)
        try {
            delegate.connect(endpoint, context: context)
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

    func send(source: api.ByteSpan, context: api.OperationContext): Int64 {
        validatePayload(source, remoteEndpoint)
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

    func sendTo(
        endpoint: NetworkEndpoint,
        source: api.ByteSpan,
        context: api.OperationContext
    ): Int64 {
        validatePayload(source, Some(endpoint))
        requireOpen(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend)
        try {
            delegate.sendTo(endpoint, source, context: context)
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

    func receive(capacity: Int64, context: api.OperationContext): DatagramReceiveResult {
        if (capacity <= 0 || capacity > DATAGRAM_PAYLOAD_LIMIT) {
            throw IllegalArgumentException("datagram receive capacity must be between 1 and 65507")
        }
        requireOpen(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive)
        try {
            let (owned, source, truncated) = delegate.receive(capacity, context: context)
            DatagramReceiveResult(Some(source), truncated, ownedPayload: owned)
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

    func close(context: api.OperationContext): Unit {
        try {
            // A terminal socket ignores a stopped context: no ownership remains
            // to acquire or completion wait to interrupt.
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

    func abort(reason: ?api.AbortReason): Unit {
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

    func isClosed(): Bool {
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
            "datagram socket is closed",
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

    private func validatePayload(
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
        if (source.length > DATAGRAM_PAYLOAD_LIMIT) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.MessageTooLarge,
                "datagram payload exceeds 65507 bytes",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpointValue),
                remoteEndpoint: diagnosticPeer
            )
        }
    }
}
