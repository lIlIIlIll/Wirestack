package wirestack.internal.transport_stdnet

import std.net as native
import std.sync.*
import wirestack as api

private const MAX_UDP_PAYLOAD: Int64 = 65507

/**
 * Synchronous Internet datagram adapter over the public std.net UDP surface.
 *
 * A send gate and a receive gate preserve datagram atomicity while allowing one
 * operation in each direction to overlap. Connect has exclusive admission
 * against both gates because native UDP connect changes receive filtering and
 * the destination used by send.
 */
public class StdNetUdpSocket <: Resource {
    private let socket: native.UdpSocket
    private let lifecycleMutex = Mutex()
    private var localEndpointValue: api.SocketEndpoint
    private var remoteEndpointValue: ?api.SocketEndpoint = None<api.SocketEndpoint>
    private var connectActive = false
    private var sendActive = false
    private var receiveActive = false
    private var nativeCloseOwned = false
    private var nativeCloseOwnedByAbort = false
    private var sendStaging = Array<Byte>()
    private var receiveScratch = Array<Byte>()

    private init(socket: native.UdpSocket, localEndpoint: api.SocketEndpoint) {
        this.socket = socket
        this.localEndpointValue = localEndpoint
    }

    /** Binds a UDP socket to an already-resolved Internet endpoint.
     * @param endpoint Local Internet endpoint, with port zero permitted.
     * @param context Absolute operation deadline and cancellation token.
     */
    public static func bind(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): StdNetUdpSocket {
        checkContext(
            context,
            api.NetworkErrorCategory.Address,
            api.NetworkPhase.AddressSelection,
            localEndpoint: Some(endpoint)
        )
        let nativeSocket = native.UdpSocket(bindAt: toStdEndpoint(endpoint))
        let adapter = StdNetUdpSocket(nativeSocket, endpoint)
        try {
            nativeSocket.bind()
            checkContext(
                context,
                api.NetworkErrorCategory.Address,
                api.NetworkPhase.AddressSelection,
                localEndpoint: Some(endpoint)
            )
            let actual = fromStdEndpoint(nativeSocket.localAddress)
            synchronized(adapter.lifecycleMutex) {
                adapter.localEndpointValue = actual
            }
            adapter
        } catch (error: native.SocketException) {
            let reported = adapter.mapSocketError(
                error,
                context,
                api.NetworkErrorCategory.Address,
                api.NetworkPhase.AddressSelection,
                remoteEndpoint: None<api.SocketEndpoint>
            )
            adapter.abortForCleanup()
            throw reported
        } catch (error: Exception) {
            adapter.abortForCleanup()
            throw error
        }
    }

    /** Bound local endpoint, including the kernel-selected port. */
    public prop localEndpoint: api.SocketEndpoint {
        get() { synchronized(lifecycleMutex) { localEndpointValue } }
    }

    /** Native-selected peer, or none before connect succeeds. */
    public prop remoteEndpoint: ?api.SocketEndpoint {
        get() { synchronized(lifecycleMutex) { remoteEndpointValue } }
    }

    /** Selects a native UDP peer and receive filter.
     * @param endpoint Already-resolved Internet peer.
     * @param context Absolute operation deadline and cancellation token.
     */
    public func connect(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        let nativeEndpoint = toStdEndpoint(endpoint)
        checkContext(
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
                socket.connect(nativeEndpoint)
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
        checkContext(
            context,
            api.NetworkErrorCategory.Write,
            api.NetworkPhase.DatagramSend,
            localEndpoint: Some(localEndpoint),
            remoteEndpoint: remoteEndpoint
        )
        let selectedPeer = beginSend(requireConnected: true).getOrThrow()
        try {
            sendPayload(source, context, Some(selectedPeer)) { payload => socket.send(payload) }
        } finally {
            endSend()
        }
    }

    /** Sends one complete non-empty datagram without changing the selected peer.
     * @param endpoint Already-resolved destination.
     * @param source Datagram bytes, bounded to 65,507 bytes.
     * @param context Absolute operation deadline and cancellation token.
     * @return The complete datagram length.
     */
    public func sendTo(
        endpoint: api.SocketEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        validatePayload(source)
        let nativeEndpoint = toStdEndpoint(endpoint)
        checkContext(
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
    ): (Array<Byte>, api.SocketEndpoint, Bool) {
        if (capacity <= 0 || capacity > MAX_UDP_PAYLOAD) {
            throw IllegalArgumentException("UDP receive capacity must be between 1 and 65507")
        }
        checkContext(
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
                    throw timedOut(
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
                        throw deadlineExceeded(
                            api.NetworkErrorCategory.Read,
                            api.NetworkPhase.DatagramReceive,
                            cause: Some(error),
                            localEndpoint: Some(localEndpoint),
                            remoteEndpoint: remoteEndpoint
                        )
                    }
                    throw timedOut(
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
    ): (Array<Byte>, api.SocketEndpoint, Bool) {
        if (count < 0) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Read,
                api.NetworkPhase.DatagramReceive,
                api.NetworkErrorCode.SystemFailure,
                "std.net returned a negative datagram length",
                retryability: api.Retryability.Never,
                localEndpoint: internetEndpoint(Some(localEndpoint)),
                remoteEndpoint: internetEndpoint(remoteEndpoint)
            )
        }
        let retained = min(count, capacity)
        let owned = Array<Byte>(retained, repeat: 0u8)
        for (index in 0..retained) { owned[index] = scratch[index] }
        // Ownership is detached from reusable scratch before the receive gate
        // is released by the caller's finally.
        (owned, fromStdEndpoint(address), count > capacity)
    }


    /** Claims graceful native close ownership; the caller context owns no cleanup deadline.
     * @param context Trace-bearing context retained for facade symmetry.
     */
    public func close(context: api.OperationContext): Unit {
        let _ = context
        if (claimNativeClose(false)) { performOwnedClose() }
    }

    /** Resource close using a background context. */
    public func close(): Unit { close(api.OperationContext.background()) }

    /** Claims abortive terminal ownership without inventing a separate error code.
     * @param reason Optional local abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        if (claimNativeClose(true)) { performOwnedClose() }
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
        diagnosticPeer: ?api.SocketEndpoint,
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
        diagnosticPeer: ?api.SocketEndpoint
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
            localEndpoint: internetEndpoint(Some(localEndpoint)),
            remoteEndpoint: internetEndpoint(diagnosticPeer),
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
                localEndpoint: internetEndpoint(Some(localEndpoint)),
                remoteEndpoint: internetEndpoint(remoteEndpoint)
            )
        }
        if (source.length > MAX_UDP_PAYLOAD) {
            throw api.NetworkException(
                api.NetworkErrorCategory.Write,
                api.NetworkPhase.DatagramSend,
                api.NetworkErrorCode.MessageTooLarge,
                "UDP datagram payload exceeds 65507 bytes",
                retryability: api.Retryability.Never,
                localEndpoint: internetEndpoint(Some(localEndpoint)),
                remoteEndpoint: internetEndpoint(remoteEndpoint)
            )
        }
    }

    private func beginConnect(endpoint: api.SocketEndpoint): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(
                api.NetworkErrorCategory.Connect,
                api.NetworkPhase.DatagramSend,
                Some(endpoint)
            )
            if (connectActive || sendActive || receiveActive) {
                throw concurrent(api.NetworkErrorCategory.Connect, api.NetworkPhase.DatagramSend)
            }
            connectActive = true
        }
    }

    private func endConnect(): Unit {
        synchronized(lifecycleMutex) { connectActive = false }
    }

    private func beginSend(requireConnected!: Bool): ?api.SocketEndpoint {
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
                    localEndpoint: internetEndpoint(Some(localEndpointValue)),
                    remoteEndpoint: internetEndpoint(remoteEndpointValue)
                )
            }
            if (sendActive) {
                throw concurrent(api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend)
            }
            if (requireConnected && remoteEndpointValue.isNone()) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.DatagramSend,
                    api.NetworkErrorCode.NotConnected,
                    "UDP socket has no selected peer",
                    retryability: api.Retryability.Never,
                    localEndpoint: internetEndpoint(Some(localEndpointValue))
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
                    localEndpoint: internetEndpoint(Some(localEndpointValue)),
                    remoteEndpoint: internetEndpoint(remoteEndpointValue)
                )
            }
            if (receiveActive) {
                throw concurrent(api.NetworkErrorCategory.Read, api.NetworkPhase.DatagramReceive)
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
        remote: ?api.SocketEndpoint
    ): Unit {
        if (nativeCloseOwned) {
            throw closedError(
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

    private func performOwnedClose(): Unit {
        try {
            socket.close()
        } catch (primary: Exception) {
            // The same close owner makes one idempotent cleanup attempt. It
            // never transfers ownership or changes graceful close into abort.
            try {
                socket.close()
            } catch (_: Exception) {}
            throw primary
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
        remoteEndpoint!: ?api.SocketEndpoint = None<api.SocketEndpoint>
    ): api.NetworkException {
        if (context.isCancellationRequested()) {
            return cancelled(
                category,
                phase,
                cause: cause,
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return deadlineExceeded(
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
        closedError(
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
        remoteEndpoint!: ?api.SocketEndpoint
    ): api.NetworkException {
        if (context.isCancellationRequested()) {
            return cancelled(
                category,
                phase,
                cause: Some(error),
                localEndpoint: Some(localEndpoint),
                remoteEndpoint: remoteEndpoint
            )
        }
        if (context.isDeadlineExceeded()) {
            return deadlineExceeded(
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
            return closedError(
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
            localEndpoint: internetEndpoint(Some(localEndpoint)),
            remoteEndpoint: internetEndpoint(remoteEndpoint),
            cause: Some(error)
        )
    }
}
