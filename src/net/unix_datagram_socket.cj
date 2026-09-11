package wirestack.net

import wirestack as api
import wirestack.NetworkEndpoint
import wirestack.internal.transport_stdnet as stdnet

/**
 * Linux Unix-domain datagram socket backed by the public std.net adapter.
 *
 * The shared Unix endpoint model preserves abstract names as arbitrary bytes,
 * including embedded NUL, and receive preserves abstract sender bytes delivered
 * by the SDK. The qualified std.net backend can encode outgoing abstract names
 * only when they contain exactly 107 bytes of valid UTF-8. Shorter names would
 * gain significant native padding, so they are rejected rather than renamed.
 * This restriction does not narrow `UnixEndpoint` itself.
 * The SDK receiveFrom conversion rejects packets
 * from unbound Unix senders before returning them, so this facade reports the
 * native failure rather than fabricating an unnamed source or recovered packet.
 * Connected sends are unavailable: SDK send re-resolves the peer address and
 * can deliver to a replacement socket. `connect` still selects the native
 * receive peer; `sendTo` always uses its explicit destination.
 *
 * Closing a pathname socket does not unlink its filesystem node. The caller
 * owns pathname cleanup after all users of that address have stopped.
 */
public class UnixDatagramSocket <: DatagramSocket {
    private let core: DatagramSocketFacadeCore
    private let capabilityValue = SocketCapabilities(
        nonBlocking: true,
        closeOnExec: true,
        halfClose: false,
        broadcast: false,
        multicast: false,
        raw: false,
        ancillaryData: false,
        zeroLengthDatagramSend: false,
        connectedDatagramSend: false
    )

    internal init(delegate: stdnet.StdNetDatagramSocket) {
        this.core = DatagramSocketFacadeCore(delegate)
    }

    /** Binds a named Linux Unix-domain datagram endpoint.
     *
     * Pathname nodes remain after close and are caller-owned. Abstract names
     * are byte values in the public model, but this backend requires exactly
     * 107 bytes of valid UTF-8 for outgoing abstract names. Other names fail
     * with `Unsupported` before native I/O.
     *
     * @param endpoint Local pathname or abstract endpoint; unnamed bind is invalid.
     * @param context Shared absolute deadline and cancellation token.
     * @return A bound Unix-domain datagram socket.
     */
    public static func bind(
        endpoint: api.UnixEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): UnixDatagramSocket {
        let local = Some(NetworkEndpoint.Unix(endpoint))
        try {
            let delegate = stdnet.StdNetDatagramSocket.bindUnix(endpoint, context: context)
            try {
                UnixDatagramSocket(delegate)
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
                api.NetworkPhase.UnixSocket,
                local,
                None<NetworkEndpoint>
            )
        }
    }

    /** Current lifecycle, including cancellation-owned abort. */
    public prop state: SocketState { get() { core.state } }

    /** Linux std.net Unix datagram capabilities qualified for this backend. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }

    /** Immutable bound Unix endpoint. */
    public prop localEndpoint: ?NetworkEndpoint { get() { Some(core.localEndpoint) } }

    /** Selected native Unix peer, or none before connect succeeds. */
    public prop remoteEndpoint: ?NetworkEndpoint { get() { core.remoteEndpoint } }

    /** Selects a Unix peer and installs native connected-peer receive filtering.
     * @param endpoint Named pathname or abstract Unix peer.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func connect(
        endpoint: api.UnixEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        core.connect(NetworkEndpoint.Unix(endpoint), context)
    }

    /** Selects a Unix peer through the shared datagram interface.
     * @param endpoint Unix peer; Internet endpoints are unsupported by this facade.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func connect(
        endpoint: NetworkEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        let unix = requireUnixDatagramEndpoint(endpoint, localEndpoint: Some(core.localEndpoint))
        connect(unix, context: context)
    }

    /** Rejects connected sending because the SDK does not preserve peer identity.
     * @param source Payload subject to the shared datagram bounds.
     * @param context Shared absolute deadline and cancellation token.
     * @return No count: this backend reports Unsupported. Use explicit sendTo instead.
     */
    public func send(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        core.send(source, context)
    }

    /** Sends one atomic datagram to a Unix destination without changing the peer.
     * @param endpoint Named pathname or abstract Unix destination.
     * @param source Non-empty payload of at most 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return Exactly `source.length` after native success.
     */
    public func sendTo(
        endpoint: api.UnixEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        core.sendTo(NetworkEndpoint.Unix(endpoint), source, context)
    }

    /** Sends through the shared datagram interface without changing the peer.
     * @param endpoint Unix destination; Internet endpoints are unsupported by this facade.
     * @param source Non-empty payload of at most 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return Exactly `source.length` after native success.
     */
    public func sendTo(
        endpoint: NetworkEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        let unix = requireUnixDatagramEndpoint(endpoint, localEndpoint: Some(core.localEndpoint))
        sendTo(unix, source, context: context)
    }

    /** Receives one datagram with an owned payload and the actual delivered Unix sender.
     *
     * Delivered abstract names retain their bytes. The qualified SDK cannot
     * return packets from an unbound Unix sender: that case is a structured
     * native receive failure, not a result with a fabricated source.
     * An empty payload from a supported sender is a valid packet, never EOF.
     *
     * @param capacity Retained payload capacity from 1 through 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return One bounded datagram result and its preserved source endpoint.
     */
    public func receive(
        capacity: Int64,
        context!: api.OperationContext = api.OperationContext.background()
    ): DatagramReceiveResult {
        core.receive(capacity, context)
    }

    /**
     * Closes idempotently. Once admitted, cleanup is not abandoned when the
     * caller's completion wait is cancelled or expires. A repeated terminal
     * close ignores a stopped context. Pathname nodes are not unlinked.
     * @param context Shared context for waiting on an already-owned close.
     */
    public func close(context!: api.OperationContext): Unit { core.close(context) }

    /** Closes with a background context for Resource callers. */
    public func close(): Unit { core.close(api.OperationContext.background()) }

    /** Aborts idempotently and wakes active native operations.
     * @param reason Optional local abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        core.abort(reason)
    }

    /** Whether this facade has reached a terminal lifecycle. */
    public func isClosed(): Bool { core.isClosed() }
}

private func requireUnixDatagramEndpoint(
    endpoint: NetworkEndpoint,
    localEndpoint!: ?NetworkEndpoint = None<NetworkEndpoint>
): api.UnixEndpoint {
    match (endpoint) {
        case NetworkEndpoint.Unix(value) => value
        case NetworkEndpoint.Internet(_) => throw api.NetworkException(
            api.NetworkErrorCategory.Unsupported,
            api.NetworkPhase.AddressSelection,
            api.NetworkErrorCode.Unsupported,
            "the Linux Unix datagram facade accepts Unix endpoints only",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: Some(endpoint)
        )
    }
}
