package wirestack.internal.transport_stdnet

import std.net as native
import std.sync.*
import wirestack as api

private const MAX_UDP_PAYLOAD: Int64 = 65507

private enum StdNetDatagramKind {
    | Internet(native.UdpSocket)
    | Unix(native.UnixDatagramSocket)
}

/**
 * Synchronous Internet and Unix datagram adapter over the public std.net
 * DatagramSocket surface.
 *
 * A send gate and a receive gate preserve packet atomicity while allowing one
 * operation in each direction to overlap. Connect has exclusive admission
 * against both gates because native datagram connect changes receive filtering
 * and the destination used by send.
 */
public class StdNetDatagramSocket <: Resource {
    private let socket: native.DatagramSocket
    private let nativeKind: StdNetDatagramKind
    private let lifecycleMutex = Mutex()
    private var localEndpointValue: api.NetworkEndpoint
    private var remoteEndpointValue: ?api.NetworkEndpoint = None<api.NetworkEndpoint>
    private var connectActive = false
    private var sendActive = false
    private var receiveActive = false
    private var nativeCloseOwned = false
    private var nativeCloseOwnedByAbort = false
    private var sendStaging = Array<Byte>()
    private var receiveScratch = Array<Byte>()

    private init(
        socket: native.DatagramSocket,
        nativeKind: StdNetDatagramKind,
        localEndpoint: api.NetworkEndpoint
    ) {
        this.socket = socket
        this.nativeKind = nativeKind
        this.localEndpointValue = localEndpoint
    }

    /** Binds a datagram socket to an already-resolved Internet endpoint.
     * @param endpoint Local Internet endpoint, with port zero permitted.
     * @param context Absolute operation deadline and cancellation token.
     */
    public static func bind(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): StdNetDatagramSocket {
        let local = api.NetworkEndpoint.Internet(endpoint)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Address,
            api.NetworkPhase.AddressSelection,
            localEndpoint: Some(local)
        )
        let concrete = native.UdpSocket(bindAt: toStdEndpoint(endpoint))
        let nativeSocket: native.DatagramSocket = concrete
        bindNative(
            nativeSocket,
            StdNetDatagramKind.Internet(concrete),
            local,
            context
        )
    }

    /** Binds a Linux Unix-domain datagram socket.
     *
     * Outgoing abstract names must be valid UTF-8 for this std.net backend.
     * The shared Unix endpoint model and delivered abstract sender names remain
     * byte preserving; the restriction is applied only while encoding this
     * bind. The qualified SDK rejects receiveFrom for an unbound Unix sender.
     * @param endpoint Named pathname or abstract local endpoint.
     * @param context Absolute operation deadline and cancellation token.
     */
    public static func bindUnix(
        endpoint: api.UnixEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): StdNetDatagramSocket {
        let local = api.NetworkEndpoint.Unix(endpoint)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Address,
            api.NetworkPhase.UnixSocket,
            localEndpoint: Some(local)
        )
        let concrete = native.UnixDatagramSocket(
            bindAt: toStdUnixEndpoint(endpoint, local: true)
        )
        let nativeSocket: native.DatagramSocket = concrete
        bindNative(
            nativeSocket,
            StdNetDatagramKind.Unix(concrete),
            local,
            context
        )
    }

    private static func bindNative(
        nativeSocket: native.DatagramSocket,
        nativeKind: StdNetDatagramKind,
        requested: api.NetworkEndpoint,
        context: api.OperationContext
    ): StdNetDatagramSocket {
        let adapter = StdNetDatagramSocket(nativeSocket, nativeKind, requested)
        try {
            match (nativeKind) {
                case StdNetDatagramKind.Internet(value) => value.bind()
                case StdNetDatagramKind.Unix(value) => value.bind()
            }
            checkNetworkContext(
                context,
                api.NetworkErrorCategory.Address,
                datagramAddressPhase(requested),
                localEndpoint: Some(requested)
            )
            let actual = fromNativeDatagramEndpoint(nativeSocket.localAddress)
            synchronized(adapter.lifecycleMutex) {
                adapter.localEndpointValue = actual
            }
            adapter
        } catch (error: native.SocketException) {
            let reported = adapter.mapSocketError(
                error,
                context,
                api.NetworkErrorCategory.Address,
                datagramAddressPhase(requested),
                remoteEndpoint: None<api.NetworkEndpoint>
            )
            adapter.abortForCleanup()
            throw reported
        } catch (error: Exception) {
            adapter.abortForCleanup()
            throw error
        }
    }

    private func connectNative(address: native.SocketAddress): Unit {
        match (nativeKind) {
            case StdNetDatagramKind.Internet(value) => value.connect(address)
            case StdNetDatagramKind.Unix(value) => value.connect(address)
        }
    }


    /** Bound local endpoint, including a kernel-selected Internet port. */
    public prop localEndpoint: api.NetworkEndpoint {
        get() { synchronized(lifecycleMutex) { localEndpointValue } }
    }

    /** Native-selected peer, or none before connect succeeds. */
    public prop remoteEndpoint: ?api.NetworkEndpoint {
        get() { synchronized(lifecycleMutex) { remoteEndpointValue } }
    }

    /** Selects a native datagram peer and receive filter.
     * @param endpoint Resolved Internet or Unix peer matching the socket family.
     * @param context Absolute operation deadline and cancellation token.
     */
    public func connect(
        endpoint: api.NetworkEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        let nativeEndpoint = toNativeDatagramEndpoint(endpoint)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Connect,
            api.NetworkPhase.DatagramSend,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: Some(endpoint)
        )
        beginConnect(endpoint)
        let gate = OperationGate()
        let registration = context.cancellation.register {
            => gate.interrupt { => abort(reason: Some(api.AbortReason.Cancelled)) }
        }
        try {
            try {
                connectNative(nativeEndpoint)
                if (!gate.complete()) {
                    throw contextOrTerminalError(
                        context,
                        api.NetworkErrorCategory.Connect,
                        api.NetworkPhase.DatagramSend,
                        remoteEndpoint: Some(endpoint)
                    )
                }
                synchronized(lifecycleMutex) { remoteEndpointValue = Some(endpoint) }
            } catch (error: native.SocketException) {
                let _ = gate.complete()
                throw mapSocketError(
                    error,
                    context,
                    api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend,
                    remoteEndpoint: Some(endpoint)
                )
            }
        } finally {
            registration.unregister()
            endConnect()
        }
    }

    /** Sends one complete non-empty datagram to the connected peer.
     * @param source Datagram bytes, bounded to 65,507 bytes.
     * @param context Absolute operation deadline and cancellation token.
     * @return The complete datagram length.
     */
    public func send(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        validatePayload(source)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Write,
            api.NetworkPhase.DatagramSend,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: remoteEndpoint
        )
        let selectedPeer = beginSend(requireConnected: true).getOrThrow()
        try {
            let sender = match (nativeKind) {
                case StdNetDatagramKind.Internet(value) => value
                case StdNetDatagramKind.Unix(_) => throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.Unsupported,
                    "std.net Unix datagram sends re-resolve peer addresses; use an explicit sendTo destination",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpoint),
                    remoteEndpoint: Some(selectedPeer)
                )
            }
            sendPayload(source, context, Some(selectedPeer)) {
                payload => sender.send(payload)
            }
        } finally {
            endSend()
        }
    }

    /** Sends one complete non-empty datagram without changing the selected peer.
     * @param endpoint Resolved Internet or Unix destination matching the socket family.
     * @param source Datagram bytes, bounded to 65,507 bytes.
     * @param context Absolute operation deadline and cancellation token.
     * @return The complete datagram length.
     */
    public func sendTo(
        endpoint: api.NetworkEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        validatePayload(source)
        let nativeEndpoint = toNativeDatagramEndpoint(endpoint)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Write,
            api.NetworkPhase.DatagramSend,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: Some(endpoint)
        )
        let _ = beginSend(requireConnected: false)
        try {
            sendPayload(source, context, Some(endpoint)) {
                payload => socket.sendTo(nativeEndpoint, payload)
            }
        } finally {
            endSend()
        }
    }

    /** Receives exactly one datagram and returns an owned payload.
     * @param capacity Maximum retained bytes, from 1 through 65,507.
     * @param context Absolute operation deadline and cancellation token.
     * @return Owned payload, original source endpoint, and truncation flag.
     */
    public func receive(
        capacity: Int64,
        context!: api.OperationContext = api.OperationContext.background()
    ): (Array<Byte>, api.NetworkEndpoint, Bool) {
        if (capacity <= 0 || capacity > MAX_UDP_PAYLOAD) {
            throw IllegalArgumentException("datagram receive capacity must be between 1 and 65507")
        }
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.DatagramReceive,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: remoteEndpoint
        )
        beginReceive()
        try {
            let scratch = synchronized(lifecycleMutex) {
                let required = capacity + 1
                if (receiveScratch.size != required) {
                    receiveScratch = Array<Byte>(required, repeat: 0u8)
                }
                receiveScratch
            }
            if (isBackgroundContext(context)) {
                try {
                    socket.receiveTimeout = None<Duration>
                    let (address, count) = socket.receiveFrom(scratch)
                    return finishReceivedDatagram(scratch, address, count, capacity)
                } catch (error: native.SocketTimeoutException) {
                    throw networkTimedOut(
                        api.NetworkErrorCategory.Read,
                        api.NetworkPhase.DatagramReceive,
                        error,
                        localEndpoint: Some(localEndpoint),
                        remoteEndpoint: remoteEndpoint
                    )
                } catch (error: native.SocketException) {
                    throw mapSocketError(
                        error,
                        context,
                        api.NetworkErrorCategory.Read,
                        api.NetworkPhase.DatagramReceive,
                        remoteEndpoint: remoteEndpoint
                    )
                }
            }
            let gate = OperationGate()
            let registration = context.cancellation.register {
                => gate.interrupt { => abort(reason: Some(api.AbortReason.Cancelled)) }
            }
            try {
                try {
                    socket.receiveTimeout = remaining(context)
                    let (address, count) = socket.receiveFrom(scratch)
                    if (!gate.complete()) {
                        throw contextOrTerminalError(
                            context,
                            api.NetworkErrorCategory.Read,
                            api.NetworkPhase.DatagramReceive,
                            remoteEndpoint: remoteEndpoint
                        )
                    }
                    finishReceivedDatagram(scratch, address, count, capacity)
                } catch (error: native.SocketTimeoutException) {
                    let completed = gate.complete()
                    if (!completed) {
                        throw contextOrTerminalError(
                            context,
                            api.NetworkErrorCategory.Read,
                            api.NetworkPhase.DatagramReceive,
                            cause: Some(error),
                            remoteEndpoint: remoteEndpoint
                        )
                    }
                    if (context.isDeadlineExceeded()) {
                        throw networkDeadlineExceeded(
                            api.NetworkErrorCategory.Read,
                            api.NetworkPhase.DatagramReceive,
                            cause: Some(error),
                            localEndpoint: Some(localEndpoint),
                            remoteEndpoint: remoteEndpoint
                        )
                    }
                    throw networkTimedOut(
                        api.NetworkErrorCategory.Read,
                        api.NetworkPhase.DatagramReceive,
                        error,
                        localEndpoint: Some(localEndpoint),
                        remoteEndpoint: remoteEndpoint
                    )
                } catch (error: native.SocketException) {
                    let _ = gate.complete()
                    throw mapSocketError(
                        error,
                        context,
                        api.NetworkErrorCategory.Read,
                        api.NetworkPhase.DatagramReceive,
                        remoteEndpoint: remoteEndpoint
                    )
                }
            } finally {
                registration.unregister()
            }
        } finally {
            endReceive()
        }
    }

    private func finishReceivedDatagram(
        scratch: Array<Byte>,
        address: native.SocketAddress,
        count: Int64,
        capacity: Int64
    ): (Array<Byte>, api.NetworkEndpoint, Bool) {
        if (count < 0) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Read,
                api.NetworkPhase.DatagramReceive,
                api.NetworkErrorCode.SystemFailure,
                "std.net returned a negative datagram length",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        let retained = min(count, capacity)
        let owned = Array<Byte>(retained, repeat: 0u8)
        for (index in 0..retained) { owned[index] = scratch[index] }
        // Ownership is detached from reusable scratch before the receive gate
        // is released by the caller's finally. A zero count is a valid packet.
        (owned, fromNativeDatagramEndpoint(address), count > capacity)
    }


    /** Claims graceful native close ownership; the caller context owns no cleanup deadline.
     * @param context Trace-bearing context retained for facade symmetry.
     */
    public func close(context: api.OperationContext): Unit {
        let _ = context
        if (claimNativeClose(false)) { socket.close() }
    }

    /** Resource close using a background context. */
    public func close(): Unit { close(api.OperationContext.background()) }

    /** Claims abortive terminal ownership without inventing a separate error code.
     * @param reason Optional local abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        if (claimNativeClose(true)) { socket.close() }
    }

    /** Whether native close ownership has made further operations inadmissible. */
    public func isClosed(): Bool {
        synchronized(lifecycleMutex) { nativeCloseOwned }
    }

    /** True only when abort won the first native close claim. */
    public func wasClosedByAbort(): Bool {
        synchronized(lifecycleMutex) { nativeCloseOwnedByAbort }
    }


    private func sendPayload(
        source: api.ByteSpan,
        context: api.OperationContext,
        diagnosticPeer: ?api.NetworkEndpoint,
        operation: (Array<Byte>) -> Unit
    ): Int64 {
        let payload = synchronized(lifecycleMutex) {
            if (source.offset == 0 && source.length == source.bytes.size) {
                source.bytes
            } else {
                if (sendStaging.size != source.length) {
                    sendStaging = Array<Byte>(source.length, repeat: 0u8)
                }
                for (index in 0..source.length) {
                    sendStaging[index] = source.bytes[source.offset + index]
                }
                sendStaging
            }
        }
        if (isBackgroundContext(context)) {
            try {
                socket.sendTimeout = None<Duration>
                operation(payload)
                return source.length
            } catch (error: native.SocketTimeoutException) {
                throw sendTimeoutError(error, context, diagnosticPeer)
            } catch (error: native.SocketException) {
                throw mapSocketError(
                    error,
                    context,
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    remoteEndpoint: diagnosticPeer
                )
            }
        }
        let gate = OperationGate()
        let registration = context.cancellation.register {
            => gate.interrupt { => abort(reason: Some(api.AbortReason.Cancelled)) }
        }
        try {
            try {
                socket.sendTimeout = remaining(context)
                operation(payload)
                if (!gate.complete()) {
                    throw contextOrTerminalError(
                        context,
                        api.NetworkErrorCategory.Write,
                        api.NetworkPhase.DatagramSend,
                        remoteEndpoint: diagnosticPeer
                    )
                }
                source.length
            } catch (error: native.SocketTimeoutException) {
                let completed = gate.complete()
                if (!completed) {
                    throw contextOrTerminalError(
                        context,
                        api.NetworkErrorCategory.Write,
                        api.NetworkPhase.DatagramSend,
                        cause: Some(error),
                        remoteEndpoint: diagnosticPeer
                    )
                }
                throw sendTimeoutError(error, context, diagnosticPeer)
            } catch (error: native.SocketException) {
                let _ = gate.complete()
                throw mapSocketError(
                    error,
                    context,
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    remoteEndpoint: diagnosticPeer
                )
            }
        } finally {
            registration.unregister()
        }
    }
    private func sendTimeoutError(
        error: native.SocketTimeoutException,
        context: api.OperationContext,
        diagnosticPeer: ?api.NetworkEndpoint
    ): api.NetworkException {
        let message = if (context.isDeadlineExceeded()) {
            "datagram send deadline exceeded with unknown physical commit state"
        } else {
            "std.net datagram send timed out with unknown physical commit state"
        }
        api.NetworkException(
            api.NetworkErrorCategory.Write,
            api.NetworkPhase.DatagramSend,
            api.NetworkErrorCode.TimedOut,
            message,
            retryability: api.Retryability.Never,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: diagnosticPeer,
            cause: Some(error)
        )
    }


    private func validatePayload(source: api.ByteSpan): Unit {
        if (source.isEmpty()) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Unsupported,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.Unsupported,
                "the current std.net backend cannot send zero-length datagrams",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (source.length > MAX_UDP_PAYLOAD) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.MessageTooLarge,
                "datagram payload exceeds 65507 bytes",
                retryability: api.Retryability.Never,
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
    }

    private func beginConnect(endpoint: api.NetworkEndpoint): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(
                api.NetworkErrorCategory.Connect,
                api.NetworkPhase.DatagramSend,
                Some(endpoint)
            )
            if (connectActive || sendActive || receiveActive) {
                throw networkConcurrent(
                    api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: Some(endpoint)
                )
            }
            connectActive = true
        }
    }

    private func endConnect(): Unit {
        synchronized(lifecycleMutex) { connectActive = false }
    }

    private func beginSend(requireConnected!: Bool): ?api.NetworkEndpoint {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                remoteEndpointValue
            )
            if (connectActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "datagram connect is active",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: remoteEndpointValue
                )
            }
            if (sendActive) {
                throw networkConcurrent(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: remoteEndpointValue
                )
            }
            if (requireConnected && remoteEndpointValue.isNone()) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.NotConnected,
                    "datagram socket has no selected peer",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpointValue)
                )
            }
            sendActive = true
            remoteEndpointValue
        }
    }

    private func endSend(): Unit {
        synchronized(lifecycleMutex) { sendActive = false }
    }

    private func beginReceive(): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(
                api.NetworkErrorCategory.Read,
                api.NetworkPhase.DatagramReceive,
                remoteEndpointValue
            )
            if (connectActive) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Read,
                    api.NetworkPhase.DatagramReceive,
                    api.NetworkErrorCode.ConcurrentOperation,
                    "datagram connect is active",
                    retryability: api.Retryability.Never,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: remoteEndpointValue
                )
            }
            if (receiveActive) {
                throw networkConcurrent(
                    api.NetworkErrorCategory.Read,
                    api.NetworkPhase.DatagramReceive,
                    localEndpoint: Some(localEndpointValue),
                    remoteEndpoint: remoteEndpointValue
                )
            }
            receiveActive = true
        }
    }

    private func endReceive(): Unit {
        synchronized(lifecycleMutex) { receiveActive = false }
    }

    private func ensureOpenLocked(
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase,
        remote: ?api.NetworkEndpoint
    ): Unit {
        if (nativeCloseOwned) {
            throw networkClosedError(
                category,
                phase,
                localEndpoint: Some(localEndpointValue),
                remoteEndpoint: remote
            )
        }
    }

    private func claimNativeClose(abortive: Bool): Bool {
        synchronized(lifecycleMutex) {
            if (nativeCloseOwned) {
                false
            } else {
                nativeCloseOwned = true
                nativeCloseOwnedByAbort = abortive
                true
            }
        }
    }

    private func abortForCleanup(): Unit {
        try {
            abort(reason: Some(api.AbortReason.ProtocolFailure))
        } catch (_: Exception) {}
    }

    private func contextOrTerminalError(
        context: api.OperationContext,
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase,
        cause!: ?Exception = None<Exception>,
        remoteEndpoint!: ?api.NetworkEndpoint = None<api.NetworkEndpoint>
    ): api.NetworkException {
        if (context.isCancellationRequested()) {
            return networkCancelled(
                category,
                phase,
                cause: cause,
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return networkDeadlineExceeded(
                category,
                phase,
                cause: cause,
                retryability: match (phase) {
                    case api.NetworkPhase.DatagramSend => api.Retryability.Never
                    case _ => api.Retryability.Temporary
                },
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        networkClosedError(
            category,
            phase,
            cause: cause,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: remoteEndpoint
        )
    }

    private func mapSocketError(
        error: native.SocketException,
        context: api.OperationContext,
        category: api.NetworkErrorCategory,
        phase: api.NetworkPhase,
        remoteEndpoint!: ?api.NetworkEndpoint
    ): api.NetworkException {
        if (context.isCancellationRequested()) {
            return networkCancelled(
                category,
                phase,
                cause: Some(error),
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return networkDeadlineExceeded(
                category,
                phase,
                cause: Some(error),
                retryability: match (phase) {
                    case api.NetworkPhase.DatagramSend => api.Retryability.Never
                    case _ => api.Retryability.Temporary
                },
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (isClosed()) {
            return networkClosedError(
                category,
                phase,
                cause: Some(error),
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        api.NetworkException(
            category,
            phase,
            api.NetworkErrorCode.SystemFailure,
            "std.net datagram operation failed without a public native error code",
            retryability: match (phase) {
                case api.NetworkPhase.DatagramSend => api.Retryability.Never
                case _ => api.Retryability.Unknown
            },
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: remoteEndpoint,
            cause: Some(error)
        )
    }
}

private func toNativeDatagramEndpoint(endpoint: api.NetworkEndpoint): native.SocketAddress {
    match (endpoint) {
        case api.NetworkEndpoint.Internet(value) => toStdEndpoint(value)
        case api.NetworkEndpoint.Unix(value) => toStdUnixEndpoint(value)
    }
}

private func fromNativeDatagramEndpoint(address: native.SocketAddress): api.NetworkEndpoint {
    match (address) {
        case _: native.UnixSocketAddress =>
            api.NetworkEndpoint.Unix(fromStdUnixEndpoint(address))
        case _ => api.NetworkEndpoint.Internet(fromStdEndpoint(address))
    }
}

private func datagramAddressPhase(endpoint: api.NetworkEndpoint): api.NetworkPhase {
    match (endpoint) {
        case api.NetworkEndpoint.Internet(_) => api.NetworkPhase.AddressSelection
        case api.NetworkEndpoint.Unix(_) => api.NetworkPhase.UnixSocket
    }
}
