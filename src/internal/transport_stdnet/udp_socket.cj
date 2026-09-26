package wirestack.internal.transport_stdnet

import std.net as native
import std.sync.*
import std.time.MonoTime
import wirestack as api

private const MAX_UDP_PAYLOAD: Int64 = 65507
private const MAX_UDP_MULTICAST_MEMBERSHIPS: Int64 = 16

private struct UdpMulticastMembershipKey {
    let group: api.IpAddress
    let interfaceIndex: UInt32
    init(group: api.IpAddress, interfaceIndex: UInt32) {
        this.group = group
        this.interfaceIndex = interfaceIndex
    }
}

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
    private var multicastMembershipSlots: ?Array<?UdpMulticastMembershipKey> = None<Array<?UdpMulticastMembershipKey>>
    private var multicastMembershipCount: Int64 = 0
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
        options!: Array<StdSocketOption> = [],
        context!: api.OperationContext = api.OperationContext.background()
    ): StdNetDatagramSocket {
        bindConfigured(endpoint, options, context, applyNativeOption)
    }

    internal static func bindConfigured(endpoint: api.SocketEndpoint, options: Array<StdSocketOption>,
        context: api.OperationContext, execute: (NativeOptionSocket, StdSocketOption, Bool) -> Unit): StdNetDatagramSocket {
        let local = api.NetworkEndpoint.Internet(endpoint)
        checkNetworkContext(
            context,
            api.NetworkErrorCategory.Address,
            api.NetworkPhase.AddressSelection,
            localEndpoint: Some(local)
        )
        let ipv6 = match (endpoint.address.family) { case api.IpAddressFamily.Ipv6 => true case _ => false }
        validateSocketOptions(options, StdSocketOptionTarget.Udp, ipv6, true, api.NetworkPhase.DatagramSend)
        let concrete = native.UdpSocket(bindAt: toStdEndpoint(endpoint))
        let nativeSocket: native.DatagramSocket = concrete
        bindNative(
            nativeSocket,
            StdNetDatagramKind.Internet(concrete),
            local,
            context,
            options: options, execute: execute
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
        context: api.OperationContext,
        options!: Array<StdSocketOption> = [],
        execute!: (NativeOptionSocket, StdSocketOption, Bool) -> Unit = applyNativeOption
    ): StdNetDatagramSocket {
        let adapter = StdNetDatagramSocket(nativeSocket, nativeKind, requested)
        try {
            match (nativeKind) {
                case StdNetDatagramKind.Internet(value) =>
                    applySocketOptionList(options, StdSocketOptionTarget.Udp, context, api.NetworkPhase.DatagramSend, false,
                        { option => execute(NativeOptionSocket.Udp(value), option, adapter.optionIpv6()) })
                    value.bind()
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

    private func optionIpv6(): Bool {
        match (localEndpoint) {
            case api.NetworkEndpoint.Internet(endpoint) => match (endpoint.address.family) {
                case api.IpAddressFamily.Ipv6 => true
                case _ => false
            }
            case _ => throw optionError(api.NetworkErrorCode.Unsupported, api.NetworkPhase.DatagramSend)
        }
    }

    private func optionSocket(): NativeOptionSocket {
        match (nativeKind) {
            case StdNetDatagramKind.Internet(value) => NativeOptionSocket.Udp(value)
            case _ => throw optionError(api.NetworkErrorCode.Unsupported, api.NetworkPhase.DatagramSend)
        }
    }

    private func beginOptionControl(context: api.OperationContext): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
            if (connectActive || sendActive || receiveActive) {
                throw networkConcurrent(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend,
                    localEndpoint: Some(localEndpointValue), remoteEndpoint: remoteEndpointValue)
            }
            checkNetworkContext(context, api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend,
                localEndpoint: Some(localEndpointValue), remoteEndpoint: remoteEndpointValue)
            connectActive = true
        }
    }

    private func requireOptionOpen(): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
        }
    }

    /** Applies UDP options using the same exclusive gate as connect. */
    public func configureOptions(options: Array<StdSocketOption>, context: api.OperationContext): Unit {
        configureOptionsUsing(options, context, applyNativeOption)
    }

    internal func configureOptionsUsing(options: Array<StdSocketOption>, context: api.OperationContext,
        execute: (NativeOptionSocket, StdSocketOption, Bool) -> Unit): Unit {
        let ipv6 = optionIpv6()
        validateSocketOptions(options, StdSocketOptionTarget.Udp, ipv6, false, api.NetworkPhase.DatagramSend)
        beginOptionControl(context)
        try {
            let selected = optionSocket()
            applySocketOptionList(options, StdSocketOptionTarget.Udp, context, api.NetworkPhase.DatagramSend, false,
                { option => requireOptionOpen(); execute(selected, option, ipv6) })
            requireOptionOpen()
        } catch (error: Exception) {
            requireOptionOpen()
            throw error
        } finally { endConnect() }
    }

    /** Queries a qualified native value without overlapping send or receive. */
    public func queryOption(name: StdSocketOptionName, context: api.OperationContext): StdSocketOption {
        queryOptionUsing(name, context, queryNativeOption)
    }

    internal func queryOptionUsing(name: StdSocketOptionName, context: api.OperationContext,
        query: (NativeOptionSocket, StdSocketOptionName, Bool) -> StdSocketOption): StdSocketOption {
        beginOptionControl(context)
        try {
            let ipv6 = optionIpv6()
            validateOptionName(name, StdSocketOptionTarget.Udp, ipv6, false, true, api.NetworkPhase.DatagramSend)
            let value = query(optionSocket(), name, ipv6)
            requireOptionOpen()
            value
        } catch (error: native.SocketException) {
            requireOptionOpen()
            throw mapSocketError(error, context, api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpoint: remoteEndpoint)
        } finally { endConnect() }
    }

    /** Joins one bounded Internet multicast membership through std.net. */
    public func joinMulticastGroup(group: api.IpAddress, interfaceIndex: UInt32,
        context: api.OperationContext): Unit {
        validateMulticastGroup(group, interfaceIndex)
        beginOptionControl(context)
        try {
            let socket = internetSocket()
            let (table, slot) = prepareMembershipJoin(group, interfaceIndex)
            try {
                setNativeMulticastMembership(socket, group, interfaceIndex, true)
            } catch (error: native.SocketException) {
                requireOptionOpen()
                throw mapSocketError(error, context, api.NetworkErrorCategory.Option,
                    api.NetworkPhase.DatagramSend, remoteEndpoint: remoteEndpoint)
            }
            synchronized(lifecycleMutex) {
                ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
                let key = UdpMulticastMembershipKey(group, interfaceIndex)
                match (multicastMembershipSlots) {
                    case Some(slots) => slots[slot] = Some(key)
                    case None =>
                        table[slot] = Some(key)
                        multicastMembershipSlots = Some(table)
                }
                multicastMembershipCount += 1
            }
        } finally { endConnect() }
    }

    /** Leaves one membership previously joined on this socket. */
    public func leaveMulticastGroup(group: api.IpAddress, interfaceIndex: UInt32,
        context: api.OperationContext): Unit {
        validateMulticastGroup(group, interfaceIndex)
        beginOptionControl(context)
        try {
            let socket = internetSocket()
            let (table, slot) = prepareMembershipLeave(group, interfaceIndex)
            try {
                setNativeMulticastMembership(socket, group, interfaceIndex, false)
            } catch (error: native.SocketException) {
                requireOptionOpen()
                throw mapSocketError(error, context, api.NetworkErrorCategory.Option,
                    api.NetworkPhase.DatagramSend, remoteEndpoint: remoteEndpoint)
            }
            synchronized(lifecycleMutex) {
                ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
                match (multicastMembershipSlots) {
                    case Some(slots) => slots[slot] = None<UdpMulticastMembershipKey>
                    case None => table[slot] = None<UdpMulticastMembershipKey>
                }
                multicastMembershipCount -= 1
                if (multicastMembershipCount == 0) {
                    multicastMembershipSlots = None<Array<?UdpMulticastMembershipKey>>
                }
            }
        } finally { endConnect() }
    }

    private func internetSocket(): native.UdpSocket {
        match (nativeKind) {
            case StdNetDatagramKind.Internet(value) => value
            case _ => throw optionError(api.NetworkErrorCode.Unsupported, api.NetworkPhase.DatagramSend)
        }
    }

    private func validateMulticastGroup(group: api.IpAddress, interfaceIndex: UInt32): Unit {
        let familyMatches = match ((group.family, optionIpv6())) {
            case (api.IpAddressFamily.Ipv4, false) | (api.IpAddressFamily.Ipv6, true) => true
            case _ => false
        }
        if (!familyMatches) { throw optionError(api.NetworkErrorCode.Unsupported, api.NetworkPhase.DatagramSend) }
        if (Int64(interfaceIndex) > 2147483647) {
            throw IllegalArgumentException("multicast interface index exceeds the native index range")
        }
        if (let Some(_) <- group.zone) {
            throw IllegalArgumentException("multicast group zones must be selected with interfaceIndex")
        }
        let octets = group.toOctets()
        let isMulticast = match (group.family) {
            case api.IpAddressFamily.Ipv4 => octets[0] >= 224u8 && octets[0] <= 239u8
            case api.IpAddressFamily.Ipv6 => octets[0] == 255u8
        }
        if (!isMulticast) { throw IllegalArgumentException("address is not an IP multicast group") }
    }

    private func prepareMembershipJoin(group: api.IpAddress, interfaceIndex: UInt32):
        (Array<?UdpMulticastMembershipKey>, Int64) {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
            let table = match (multicastMembershipSlots) {
                case Some(value) => value
                case None => Array<?UdpMulticastMembershipKey>(MAX_UDP_MULTICAST_MEMBERSHIPS,
                    repeat: None<UdpMulticastMembershipKey>)
            }
            var freeSlot: Int64 = -1
            for (index in 0..MAX_UDP_MULTICAST_MEMBERSHIPS) {
                match (table[index]) {
                    case Some(key) =>
                        if (key.group == group && key.interfaceIndex == interfaceIndex) {
                            throw membershipError(api.NetworkErrorCode.InvalidState,
                                "multicast group is already joined")
                        }
                    case None => if (freeSlot < 0) { freeSlot = index }
                }
            }
            if (multicastMembershipCount >= MAX_UDP_MULTICAST_MEMBERSHIPS) {
                throw membershipError(api.NetworkErrorCode.ResourceExhausted,
                    "multicast membership limit is reached")
            }
            (table, freeSlot)
        }
    }

    private func prepareMembershipLeave(group: api.IpAddress, interfaceIndex: UInt32):
        (Array<?UdpMulticastMembershipKey>, Int64) {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, remoteEndpointValue)
            let table = match (multicastMembershipSlots) {
                case Some(value) => value
                case None => throw membershipError(api.NetworkErrorCode.InvalidState,
                    "multicast group is not joined")
            }
            for (index in 0..MAX_UDP_MULTICAST_MEMBERSHIPS) {
                match (table[index]) {
                    case Some(key) =>
                        if (key.group == group && key.interfaceIndex == interfaceIndex) { return (table, index) }
                    case None => ()
                }
            }
            throw membershipError(api.NetworkErrorCode.InvalidState, "multicast group is not joined")
        }
    }

    private func membershipError(code: api.NetworkErrorCode, message: String): api.NetworkException {
        api.NetworkException(api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend, code, message,
            retryability: api.Retryability.Never, localEndpoint: Some(localEndpointValue),
            remoteEndpoint: remoteEndpointValue)
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

    /** Removes the connected UDP peer without replacing the bound socket. */
    public func disconnect(context!: api.OperationContext = api.OperationContext.background()): Unit {
        let peer = remoteEndpoint
        checkNetworkContext(context, api.NetworkErrorCategory.Connect, api.NetworkPhase.DatagramSend,
            localEndpoint: Some(localEndpoint), remoteEndpoint: peer)
        beginDisconnect(peer)
        let gate = OperationGate()
        let registration = context.cancellation.register {
            => gate.interrupt { => abort(reason: Some(api.AbortReason.Cancelled)) }
        }
        try {
            try {
                match (nativeKind) {
                    case StdNetDatagramKind.Internet(value) => value.disconnect()
                    case StdNetDatagramKind.Unix(_) =>
                        throw optionError(api.NetworkErrorCode.Unsupported, api.NetworkPhase.DatagramSend)
                }
                if (!gate.complete()) {
                    throw contextOrTerminalError(context, api.NetworkErrorCategory.Connect,
                        api.NetworkPhase.DatagramSend, remoteEndpoint: peer)
                }
                synchronized(lifecycleMutex) { remoteEndpointValue = None<api.NetworkEndpoint> }
            } catch (error: native.SocketException) {
                let _ = gate.complete()
                throw mapSocketError(error, context, api.NetworkErrorCategory.Connect,
                    api.NetworkPhase.DatagramSend, remoteEndpoint: peer)
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
    /** Waits until receive admission is active for deterministic lifecycle tests. */
    func waitUntilReceiveActive(timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        while (!synchronized(lifecycleMutex) { receiveActive } && !isClosed()) {
            if (MonoTime.now() >= expiresAt) { return false }
            sleep(Duration.millisecond)
        }
        synchronized(lifecycleMutex) { receiveActive }
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

    private func beginDisconnect(remote: ?api.NetworkEndpoint): Unit {
        synchronized(lifecycleMutex) {
            ensureOpenLocked(api.NetworkErrorCategory.Connect, api.NetworkPhase.DatagramSend, remote)
            if (connectActive || sendActive || receiveActive) {
                throw networkConcurrent(api.NetworkErrorCategory.Connect, api.NetworkPhase.DatagramSend,
                    localEndpoint: Some(localEndpointValue), remoteEndpoint: remote)
            }
            connectActive = true
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
                multicastMembershipSlots = None<Array<?UdpMulticastMembershipKey>>
                multicastMembershipCount = 0
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
