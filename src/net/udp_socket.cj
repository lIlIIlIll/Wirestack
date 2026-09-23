package wirestack.net

import wirestack as api
import wirestack.NetworkEndpoint
import wirestack.internal.transport_stdnet as stdnet

/**
 * Linux Internet datagram socket backed by the shared std.net datagram adapter.
 *
 * The socket retains resolved endpoints only. One send-like and one receive-like
 * operation may overlap, while same-direction overlap and connect races fail
 * with a structured concurrent-operation error.
 */
public class UdpSocket <: DatagramSocket {
    private let core: DatagramSocketFacadeCore
    private let capabilityValue: SocketCapabilities

    internal init(delegate: stdnet.StdNetDatagramSocket) {
        this.core = DatagramSocketFacadeCore(delegate)
        let ipv4 = match (delegate.localEndpoint) {
            case NetworkEndpoint.Internet(endpoint) => match (endpoint.address.family) {
                case api.IpAddressFamily.Ipv4 => true
                case _ => false
            }
            case _ => false
        }
        this.capabilityValue = SocketCapabilities(nonBlocking: true, closeOnExec: true,
            halfClose: false, broadcast: ipv4, multicast: stdnet.multicastMembershipQualified(), raw: false, ancillaryData: false,
            zeroLengthDatagramSend: false, connectedDatagramSend: true)
    }

    /** Binds an Internet datagram socket without DNS.
     * @param endpoint Local resolved IP endpoint; port zero asks the kernel to allocate one.
     * @param options Pre-bind UDP options, in caller order.
     * @param context Shared absolute deadline and cancellation token.
     * @return A bound UDP socket.
     */
    public static func bind(
        endpoint: api.SocketEndpoint,
        options!: Array<SocketOption> = [],
        context!: api.OperationContext = api.OperationContext.background()
    ): UdpSocket {
        let encoded = encodeSocketOptions(options)

        let local = Some(NetworkEndpoint.Internet(endpoint))
        try {
            let delegate = stdnet.StdNetDatagramSocket.bind(endpoint, context: context, options: encoded)
            try {
                UdpSocket(delegate)
            } catch (error: Exception) {
                try {
                    delegate.close()
                } catch (_: Exception) {}
                throw error
            }
        } catch (error: IllegalArgumentException) { throw error }
        catch (error: Exception) {
            throw socketFailure(
                error,
                api.NetworkErrorCategory.Address,
                api.NetworkPhase.AddressSelection,
                local,
                None<NetworkEndpoint>
            )
        }
    }

    /** Applies an ordered UDP option list without overlapping I/O or connect.
     * @param options At most twelve distinct typed options.
     * @param context Absolute deadline and cancellation token.
     */
    public func configure(options: Array<SocketOption>, context!: api.OperationContext = api.OperationContext.background()): Unit {
        core.configureOptions(encodeSocketOptions(options), context)
    }

    /** Queries the effective kernel value. IPv4 interface-index readback is unsupported.
     * @param name UDP option kind.
     * @param context Absolute deadline and cancellation token.
     * @return The typed effective value.
     */
    public func getOption(name: SocketOptionName, context!: api.OperationContext = api.OperationContext.background()): SocketOption {
        decodeSocketOption(core.queryOption(encodeSocketOptionName(name), context))
    }

    /** Current lifecycle, including cancellation-owned abort. */
    public prop state: SocketState { get() { core.state } }

    /** Linux std.net Internet datagram capabilities qualified for this backend. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }

    /** Immutable bound endpoint, including a kernel-selected port. */
    public prop localEndpoint: ?NetworkEndpoint { get() { Some(core.localEndpoint) } }

    /** Selected native UDP peer, or none before connect succeeds. */
    public prop remoteEndpoint: ?NetworkEndpoint { get() { core.remoteEndpoint } }

    /** Selects a resolved Internet peer and installs the native receive filter.
     * @param endpoint Resolved Internet peer; Unix endpoints are unsupported by this facade.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func connect(
        endpoint: NetworkEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): Unit {
        let _ = requireUdpInternetEndpoint(endpoint, localEndpoint: Some(core.localEndpoint))
        core.connect(endpoint, context)
    }

    /** Disconnects the selected peer while preserving the bound UDP socket. Repeated calls are idempotent.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func disconnect(context!: api.OperationContext = api.OperationContext.background()): Unit {
        core.disconnect(context)
    }

    /** Joins an IPv4 or IPv6 multicast group on this socket family. At most sixteen memberships are tracked.
     * @param group Multicast IP address without a zone.
     * @param interfaceIndex Native interface index; zero selects the kernel default.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func joinMulticastGroup(group: api.IpAddress, interfaceIndex!: UInt32 = 0,
        context!: api.OperationContext = api.OperationContext.background()): Unit {
        core.joinMulticastGroup(group, interfaceIndex, context)
    }

    /** Leaves a previously joined group/interface pair; duplicate joins and unmatched leaves fail InvalidState.
     * @param group Multicast IP address without a zone.
     * @param interfaceIndex Native interface index used for the join.
     * @param context Shared absolute deadline and cancellation token.
     */
    public func leaveMulticastGroup(group: api.IpAddress, interfaceIndex!: UInt32 = 0,
        context!: api.OperationContext = api.OperationContext.background()): Unit {
        core.leaveMulticastGroup(group, interfaceIndex, context)
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
        core.send(source, context)
    }

    /** Sends one atomic datagram without changing the selected peer.
     * @param endpoint Resolved Internet destination; Unix endpoints are unsupported by this facade.
     * @param source Non-empty payload of at most 65,507 bytes.
     * @param context Shared absolute deadline and cancellation token.
     * @return Exactly `source.length` after native success.
     */
    public func sendTo(
        endpoint: NetworkEndpoint,
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        let _ = requireUdpInternetEndpoint(endpoint, localEndpoint: Some(core.localEndpoint))
        core.sendTo(endpoint, source, context)
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
        core.receive(capacity, context)
    }

    /**
     * Closes idempotently. Once admitted, cleanup is not abandoned when the
     * caller's completion wait is cancelled or expires. A repeated terminal
     * close ignores a stopped context.
     * @param context Shared context for waiting on an already-owned close.
     */
    public func close(context!: api.OperationContext): Unit { core.close(context) }

    /** Closes with a background context for Resource callers. */
    public func close(): Unit { core.close(api.OperationContext.background()) }

    /** Aborts idempotently; Aborted is published only if abort owns native close.
     * @param reason Optional local abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        core.abort(reason)
    }

    /** Whether this facade has reached a terminal lifecycle. */
    public func isClosed(): Bool { core.isClosed() }
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
            "the Linux UDP facade accepts Internet endpoints only",
            retryability: api.Retryability.Never,
            localEndpoint: localEndpoint,
            remoteEndpoint: Some(endpoint)
        )
    }
}
