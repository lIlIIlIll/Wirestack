package wirestack_m9_003_udp_lifecycle

import std.convert.Parsable
import std.env.getStdOut
import std.env.getVariable
import std.sync.*
import wirestack as api
import wirestack.net.*

func require(value: Bool, reason: String): Unit { if (!value) { throw Exception(reason) } }
func announce(value: String): Unit { println(value); getStdOut().flush() }
func context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(4 * Duration.second)))
}
func ipv4(address: Array<Byte>, port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, address), port)
}
func ipv6(address: Array<Byte>, port: UInt16, zone!: ?String = None<String>): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv6, address, zone: zone), port)
}
func multicast4(): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv4, [239u8, 255u8, 250u8, 41u8])
}
func multicast6(): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv6,
        [0xFFu8, 0x02u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
         0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 42u8])
}
func internet(value: api.NetworkEndpoint): api.SocketEndpoint {
    match (value) {
        case api.NetworkEndpoint.Internet(endpoint) => endpoint
        case _ => throw Exception("expected an Internet endpoint")
    }
}
func sameInternetEndpoint(left: ?api.NetworkEndpoint, right: ?api.NetworkEndpoint): Bool {
    match ((left, right)) {
        case (Some(api.NetworkEndpoint.Internet(first)), Some(api.NetworkEndpoint.Internet(second))) => first == second
        case _ => false
    }
}
func codeIs(error: api.NetworkException, expected: api.NetworkErrorCode): Bool {
    match ((error.code, expected)) {
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) |
             (api.NetworkErrorCode.ConcurrentOperation, api.NetworkErrorCode.ConcurrentOperation) |
             (api.NetworkErrorCode.InvalidState, api.NetworkErrorCode.InvalidState) |
             (api.NetworkErrorCode.NotConnected, api.NetworkErrorCode.NotConnected) |
             (api.NetworkErrorCode.ResourceExhausted, api.NetworkErrorCode.ResourceExhausted) |
             (api.NetworkErrorCode.SystemFailure, api.NetworkErrorCode.SystemFailure) => true
        case _ => false
    }
}
func expectWriteCode(operation: () -> Unit, expected: api.NetworkErrorCode): Unit {
    try {
        operation()
        throw Exception("datagram send unexpectedly succeeded")
    } catch (error: api.NetworkException) {
        let writePhase = match ((error.category, error.phase)) {
            case (api.NetworkErrorCategory.Write, api.NetworkPhase.DatagramSend) => true
            case _ => false
        }
        require(writePhase && codeIs(error, expected), "datagram send returned the wrong structured error")
    }
}
func expectOptionCode(operation: () -> Unit, expected: api.NetworkErrorCode): Unit {
    try {
        operation()
        throw Exception("membership operation unexpectedly succeeded")
    } catch (error: api.NetworkException) {
        let optionPhase = match ((error.category, error.phase)) {
            case (api.NetworkErrorCategory.Option, api.NetworkPhase.DatagramSend) => true
            case _ => false
        }
        require(optionPhase && codeIs(error, expected), "membership operation returned the wrong structured error")
    }
}
func interfaceIndex(name: String): UInt32 {
    UInt32.parse(getVariable(name).getOrThrow())
}
func broadcastValue(socket: UdpSocket): Bool {
    match (socket.getOption(SocketOptionName.Broadcast, context: context())) {
        case SocketOption.Broadcast(value) => value
        case _ => throw Exception("broadcast readback returned the wrong option")
    }
}
func connectedDatagram(socket: UdpSocket, peer: api.NetworkEndpoint): Unit {
    socket.connect(peer, context: context())
}

func runDisconnect(): Unit {
    let first = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    let second = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    let sender = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    let original = sender.localEndpoint
    try {
        let firstPeer = first.localEndpoint.getOrThrow()
        let secondPeer = second.localEndpoint.getOrThrow()
        connectedDatagram(sender, firstPeer)
        require(sender.send(api.ByteSpan([61u8]), context: context()) == 1, "connected send length changed")
        require(first.receive(2, context: context()).payload == [61u8], "connected peer did not receive its datagram")
        sender.disconnect(context: context())
        require(sender.remoteEndpoint.isNone(), "disconnect retained the selected peer")
        require(sameInternetEndpoint(sender.localEndpoint, original), "disconnect changed the bound socket identity")
        sender.disconnect(context: context())
        expectWriteCode({ => let _ = sender.send(api.ByteSpan([62u8]), context: context()) },
            api.NetworkErrorCode.NotConnected)
        require(sender.sendTo(secondPeer, api.ByteSpan([63u8]), context: context()) == 1,
            "sendTo failed after disconnect")
        let received = second.receive(2, context: context())
        require(received.payload == [63u8] && sameInternetEndpoint(received.source, original), "sendTo did not reuse the original bind")
        require(sameInternetEndpoint(sender.localEndpoint, original), "sendTo changed the bound socket identity")
    } finally {
        sender.close()
        second.close()
        first.close()
    }
    announce("M9_003_DISCONNECT_PASS")
}

func runBroadcast(): Unit {
    let receiver = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0),
        options: [SocketOption.ReuseAddress(true)], context: context())
    let sender = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0), context: context())
    try {
        sender.configure([SocketOption.Broadcast(false)], context: context())
        require(!broadcastValue(sender), "broadcast disable did not take effect")
        expectWriteCode({ => let _ = sender.sendTo(
            api.NetworkEndpoint.Internet(ipv4([127u8, 255u8, 255u8, 255u8], internet(receiver.localEndpoint.getOrThrow()).port)),
            api.ByteSpan([71u8]), context: context()) }, api.NetworkErrorCode.SystemFailure)

        sender.configure([SocketOption.Broadcast(true)], context: context())
        require(broadcastValue(sender), "broadcast enable did not take effect")
        let target = api.NetworkEndpoint.Internet(
            ipv4([127u8, 255u8, 255u8, 255u8], internet(receiver.localEndpoint.getOrThrow()).port))
        require(sender.sendTo(target, api.ByteSpan([72u8]), context: context()) == 1,
            "enabled directed broadcast send failed")
        require(receiver.receive(2, context: context()).payload == [72u8],
            "directed broadcast datagram did not arrive on loopback")

        sender.configure([SocketOption.Broadcast(false)], context: context())
        require(!broadcastValue(sender), "broadcast disable after traffic did not take effect")
        expectWriteCode({ => let _ = sender.sendTo(target, api.ByteSpan([73u8]), context: context()) },
            api.NetworkErrorCode.SystemFailure)
    } finally {
        sender.close()
        receiver.close()
    }
    announce("M9_003_BROADCAST_PASS")
}

func runIpv4Multicast(): Unit {
    let index = interfaceIndex("WIRESTACK_M9_003_IPV4_INTERFACE_INDEX")
    let group = multicast4()
    let receiver = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0),
        options: [SocketOption.ReuseAddress(true)], context: context())
    let sender = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0), context: context())
    try {
        receiver.joinMulticastGroup(group, interfaceIndex: index, context: context())
        expectOptionCode({ => receiver.joinMulticastGroup(group, interfaceIndex: index, context: context()) },
            api.NetworkErrorCode.InvalidState)
        sender.configure([SocketOption.MulticastInterface(index), SocketOption.MulticastTtl(1u8),
            SocketOption.MulticastLoopback(true)], context: context())
        let target = api.NetworkEndpoint.Internet(ipv4(group.toOctets(), internet(receiver.localEndpoint.getOrThrow()).port))
        require(sender.sendTo(target, api.ByteSpan([81u8, 82u8]), context: context()) == 2,
            "IPv4 multicast send length changed")
        require(receiver.receive(4, context: context()).payload == [81u8, 82u8],
            "IPv4 multicast packet was not looped back to its joined membership")
        receiver.leaveMulticastGroup(group, interfaceIndex: index, context: context())
        expectOptionCode({ => receiver.leaveMulticastGroup(group, interfaceIndex: index, context: context()) },
            api.NetworkErrorCode.InvalidState)
        receiver.joinMulticastGroup(group, interfaceIndex: index, context: context())
        receiver.leaveMulticastGroup(group, interfaceIndex: index, context: context())
    } finally {
        sender.close()
        receiver.close()
    }
    announce("M9_003_IPV4_MULTICAST_PASS")
}

func runIpv6Multicast(): Unit {
    let index = interfaceIndex("WIRESTACK_M9_003_IPV6_INTERFACE_INDEX")
    let group = multicast6()
    let receiver = UdpSocket.bind(ipv6(Array<Byte>(16, repeat: 0u8), 0),
        options: [SocketOption.Ipv6Only(true), SocketOption.ReuseAddress(true)], context: context())
    let sender = UdpSocket.bind(ipv6(Array<Byte>(16, repeat: 0u8), 0),
        options: [SocketOption.Ipv6Only(true)], context: context())
    try {
        receiver.joinMulticastGroup(group, interfaceIndex: index, context: context())
        sender.configure([SocketOption.MulticastInterface(index), SocketOption.MulticastHopLimit(1u8),
            SocketOption.MulticastLoopback(true)], context: context())
        let destination = ipv6(group.toOctets(), internet(receiver.localEndpoint.getOrThrow()).port,
            zone: Some(index.toString()))
        require(sender.sendTo(api.NetworkEndpoint.Internet(destination), api.ByteSpan([91u8, 92u8]),
            context: context()) == 2, "IPv6 multicast send length changed")
        require(receiver.receive(4, context: context()).payload == [91u8, 92u8],
            "IPv6 multicast packet was not looped back to its joined membership")
        receiver.leaveMulticastGroup(group, interfaceIndex: index, context: context())
    } finally {
        sender.close()
        receiver.close()
    }
    announce("M9_003_IPV6_MULTICAST_PASS")
}

func runMembershipErrorsAndCleanup(): Unit {
    let index = interfaceIndex("WIRESTACK_M9_003_IPV4_INTERFACE_INDEX")
    let socket = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0), context: context())
    try {
        expectOptionCode({ => socket.leaveMulticastGroup(multicast4(), interfaceIndex: index, context: context()) },
            api.NetworkErrorCode.InvalidState)
        expectOptionCode({ => socket.joinMulticastGroup(multicast4(), interfaceIndex: 2147483647u32,
            context: context()) }, api.NetworkErrorCode.SystemFailure)
        require(match (socket.state) { case SocketState.Open => true; case _ => false },
            "native membership failure changed socket lifecycle")
        socket.joinMulticastGroup(multicast4(), interfaceIndex: index, context: context())
    } finally { socket.close() }

    let replacement = UdpSocket.bind(ipv4([0u8, 0u8, 0u8, 0u8], 0), context: context())
    try {
        replacement.joinMulticastGroup(multicast4(), interfaceIndex: index, context: context())
        replacement.leaveMulticastGroup(multicast4(), interfaceIndex: index, context: context())
    } finally { replacement.close() }
    announce("M9_003_MEMBERSHIP_ERRORS_CLEANUP_PASS")
}

func runActiveReceiveControl(): Unit {
    let peer = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    let socket = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    try {
        let peerEndpoint = peer.localEndpoint.getOrThrow()
        socket.connect(peerEndpoint, context: context())
        let cancellation = api.CancellationSource()
        let receiving: Future<Bool> = spawn {
            try {
                let _ = socket.receive(1, context: api.OperationContext(cancellation: cancellation.token))
                false
            } catch (error: api.NetworkException) {
                codeIs(error, api.NetworkErrorCode.Cancelled)
            }
        }
        sleep(100 * Duration.millisecond)
        let conflict = try {
            socket.disconnect(context: context())
            false
        } catch (error: api.NetworkException) {
            codeIs(error, api.NetworkErrorCode.ConcurrentOperation)
        }
        require(conflict, "disconnect did not reject active receive")
        require(sameInternetEndpoint(socket.remoteEndpoint, Some(peerEndpoint)), "rejected disconnect changed the selected peer")
        cancellation.cancel()
        require(receiving.get(2 * Duration.second), "cancelled receive did not complete exactly once")
        require(match (socket.state) { case SocketState.Aborted => true; case _ => false },
            "receive cancellation did not own the abortive close")
        socket.close()
        socket.abort()
    } finally {
        socket.close()
        peer.close()
    }
    announce("M9_003_DISCONNECT_ACTIVE_RECEIVE_PASS")
}

func runActiveSendControl(): Unit {
    let peer = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    let socket = UdpSocket.bind(ipv4([127u8, 0u8, 0u8, 1u8], 0), context: context())
    try {
        let peerEndpoint = peer.localEndpoint.getOrThrow()
        socket.connect(peerEndpoint, context: context())
        let sending: Future<Bool> = spawn {
            socket.sendTo(peerEndpoint, api.ByteSpan([101u8]), context: context()) == 1
        }
        sleep(100 * Duration.millisecond)
        let conflict = try {
            socket.disconnect(context: context())
            false
        } catch (error: api.NetworkException) {
            codeIs(error, api.NetworkErrorCode.ConcurrentOperation)
        }
        require(conflict, "disconnect did not reject active send")
        require(sending.get(2 * Duration.second), "in-flight send did not complete")
        require(peer.receive(2, context: context()).payload == [101u8], "delayed send payload changed")
        socket.disconnect(context: context())
        require(socket.remoteEndpoint.isNone(), "disconnect did not complete after send admission ended")
    } finally {
        socket.close()
        peer.close()
    }
    announce("M9_003_DISCONNECT_ACTIVE_SEND_PASS")
}

main(): Int64 {
    match (getVariable("WIRESTACK_M9_003_MODE").getOrThrow()) {
        case "disconnect" => runDisconnect()
        case "broadcast" => runBroadcast()
        case "ipv4-multicast" => runIpv4Multicast()
        case "ipv6-multicast" => runIpv6Multicast()
        case "membership-cleanup" => runMembershipErrorsAndCleanup()
        case "active-receive" => runActiveReceiveControl()
        case "active-send" => runActiveSendControl()
        case _ => throw Exception("unknown M9-003 scenario")
    }
    0
}
