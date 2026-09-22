package wirestack.net

import wirestack.internal.transport_stdnet as stdnet

/** Typed options applied by TCP and UDP factories or configure operations. */
public enum SocketOption {
    /** Enables address reuse before bind. */
    | ReuseAddress(Bool)
    /** Enables port reuse before bind. */
    | ReusePort(Bool)
    /** Enables TCP no-delay. */
    | NoDelay(Bool)
    /** Enables TCP probes with idle 45s, interval 5s and count 5. */
    | KeepAlive(Bool)
    /** Enables IPv4 datagram broadcast. */
    | Broadcast(Bool)
    /** Requests a positive receive buffer size; query returns the kernel value. */
    | ReceiveBuffer(Int64)
    /** Requests a positive send buffer size; query returns the kernel value. */
    | SendBuffer(Int64)
    /** Sets the IPv4 multicast TTL. */
    | MulticastTtl(UInt8)
    /** Restricts an IPv6 socket to IPv6 before bind. */
    | Ipv6Only(Bool)
    /** Selects the multicast interface index; zero selects the default. */
    | MulticastInterface(UInt32)
    /** Sets the IPv6 multicast hop limit. */
    | MulticastHopLimit(UInt8)
    /** Enables multicast loopback for the socket address family. */
    | MulticastLoopback(Bool)
}

/** Identifies an option whose effective backend value is requested. */
public enum SocketOptionName {
    /** Enables address reuse before bind. */
    | ReuseAddress
    /** Enables port reuse before bind. */
    | ReusePort
    /** Enables TCP no-delay. */
    | NoDelay
    /** Enables TCP probes with idle 45s, interval 5s and count 5. */
    | KeepAlive
    /** Enables IPv4 datagram broadcast. */
    | Broadcast
    /** Requests a positive receive buffer size; query returns the kernel value. */
    | ReceiveBuffer
    /** Requests a positive send buffer size; query returns the kernel value. */
    | SendBuffer
    /** Sets the IPv4 multicast TTL. */
    | MulticastTtl
    /** Restricts an IPv6 socket to IPv6 before bind. */
    | Ipv6Only
    /** Selects the multicast interface index; zero selects the default. */
    | MulticastInterface
    /** Sets the IPv6 multicast hop limit. */
    | MulticastHopLimit
    /** Enables multicast loopback for the socket address family. */
    | MulticastLoopback
}

internal func encodeSocketOptions(options: Array<SocketOption>): Array<stdnet.StdSocketOption> {
    if (options.size > 12) { throw IllegalArgumentException("at most twelve socket options are permitted") }
    Array<stdnet.StdSocketOption>(options.size, { index =>
        match (options[index]) {
            case SocketOption.ReuseAddress(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.ReuseAddress, if (value) { 1 } else { 0 })
            case SocketOption.ReusePort(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.ReusePort, if (value) { 1 } else { 0 })
            case SocketOption.NoDelay(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.NoDelay, if (value) { 1 } else { 0 })
            case SocketOption.KeepAlive(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.KeepAlive, if (value) { 1 } else { 0 })
            case SocketOption.Broadcast(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.Broadcast, if (value) { 1 } else { 0 })
            case SocketOption.ReceiveBuffer(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.ReceiveBuffer, Int64(value))
            case SocketOption.SendBuffer(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.SendBuffer, Int64(value))
            case SocketOption.MulticastTtl(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.MulticastTtl, Int64(value))
            case SocketOption.Ipv6Only(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.Ipv6Only, if (value) { 1 } else { 0 })
            case SocketOption.MulticastInterface(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.MulticastInterface, Int64(value))
            case SocketOption.MulticastHopLimit(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.MulticastHopLimit, Int64(value))
            case SocketOption.MulticastLoopback(value) => stdnet.StdSocketOption(stdnet.StdSocketOptionName.MulticastLoopback, if (value) { 1 } else { 0 })
        }
    })
}

internal func encodeSocketOptionName(name: SocketOptionName): stdnet.StdSocketOptionName {
    match (name) {
        case SocketOptionName.ReuseAddress => stdnet.StdSocketOptionName.ReuseAddress
        case SocketOptionName.ReusePort => stdnet.StdSocketOptionName.ReusePort
        case SocketOptionName.NoDelay => stdnet.StdSocketOptionName.NoDelay
        case SocketOptionName.KeepAlive => stdnet.StdSocketOptionName.KeepAlive
        case SocketOptionName.Broadcast => stdnet.StdSocketOptionName.Broadcast
        case SocketOptionName.ReceiveBuffer => stdnet.StdSocketOptionName.ReceiveBuffer
        case SocketOptionName.SendBuffer => stdnet.StdSocketOptionName.SendBuffer
        case SocketOptionName.MulticastTtl => stdnet.StdSocketOptionName.MulticastTtl
        case SocketOptionName.Ipv6Only => stdnet.StdSocketOptionName.Ipv6Only
        case SocketOptionName.MulticastInterface => stdnet.StdSocketOptionName.MulticastInterface
        case SocketOptionName.MulticastHopLimit => stdnet.StdSocketOptionName.MulticastHopLimit
        case SocketOptionName.MulticastLoopback => stdnet.StdSocketOptionName.MulticastLoopback
    }
}

internal func decodeSocketOption(option: stdnet.StdSocketOption): SocketOption {
    match (option.name) {
        case stdnet.StdSocketOptionName.ReuseAddress => SocketOption.ReuseAddress(option.value != 0)
        case stdnet.StdSocketOptionName.ReusePort => SocketOption.ReusePort(option.value != 0)
        case stdnet.StdSocketOptionName.NoDelay => SocketOption.NoDelay(option.value != 0)
        case stdnet.StdSocketOptionName.KeepAlive => SocketOption.KeepAlive(option.value != 0)
        case stdnet.StdSocketOptionName.Broadcast => SocketOption.Broadcast(option.value != 0)
        case stdnet.StdSocketOptionName.ReceiveBuffer => SocketOption.ReceiveBuffer(option.value)
        case stdnet.StdSocketOptionName.SendBuffer => SocketOption.SendBuffer(option.value)
        case stdnet.StdSocketOptionName.MulticastTtl => SocketOption.MulticastTtl(UInt8(option.value))
        case stdnet.StdSocketOptionName.Ipv6Only => SocketOption.Ipv6Only(option.value != 0)
        case stdnet.StdSocketOptionName.MulticastInterface => SocketOption.MulticastInterface(UInt32(option.value))
        case stdnet.StdSocketOptionName.MulticastHopLimit => SocketOption.MulticastHopLimit(UInt8(option.value))
        case stdnet.StdSocketOptionName.MulticastLoopback => SocketOption.MulticastLoopback(option.value != 0)
    }
}
