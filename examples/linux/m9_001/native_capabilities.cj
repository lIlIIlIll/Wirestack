package wirestack_m9_001_native_capabilities

import std.convert.Parsable
import std.env.getStdOut
import std.env.getVariable
import wirestack as api
import wirestack.net.*

func announce(value: String): Unit { println(value); getStdOut().flush() }
func require(value: Bool, message: String): Unit { if (!value) { throw Exception(message) } }
func context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(10 * Duration.second)))
}
func ipv4(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}
func ipv6(port: UInt16): api.SocketEndpoint {
    let bytes = Array<Byte>(16, repeat: 0u8)
    bytes[15] = 1u8
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv6, bytes), port)
}
func port(value: ?api.NetworkEndpoint): UInt16 {
    match (value) {
        case Some(api.NetworkEndpoint.Internet(endpoint)) => endpoint.port
        case _ => throw Exception("expected an Internet endpoint")
    }
}
func byte(value: UInt8): Array<Byte> { [value] }
func readByte(stream: StreamSocket, expected: UInt8): Unit {
    let value = Array<Byte>(1, repeat: 0u8)
    stream.readExact(api.MutableByteSpan(value), context: context())
    require(value == byte(expected), "stream peer returned the wrong byte")
}
func writeByte(stream: StreamSocket, value: UInt8): Unit {
    stream.writeAll(api.ByteSpan(byte(value)), context: context())
}
func exchangeOutgoing(stream: StreamSocket, value: UInt8): Unit {
    writeByte(stream, value)
    readByte(stream, value)
}
func exchangeAccepted(stream: StreamSocket, value: UInt8): Unit {
    if (value == 1u8) {
        readByte(stream, value)
        writeByte(stream, value)
    } else {
        writeByte(stream, value)
        readByte(stream, value)
    }
}

func emitCapabilities(className: String, instance: String, value: SocketCapabilities): Unit {
    announce("CAP ${className} ${instance} ${value.nonBlocking} ${value.closeOnExec} " +
        "${value.halfClose} ${value.broadcast} ${value.multicast} ${value.raw} " +
        "${value.ancillaryData} ${value.zeroLengthDatagramSend} ${value.connectedDatagramSend}")
}
func requireCapabilities(value: SocketCapabilities, connectedDatagramSend!: Bool = false,
    broadcast!: Bool = false, multicast!: Bool = false): Unit {
    require(value.nonBlocking, "non-blocking capability was not reported")
    require(value.closeOnExec, "close-on-exec capability was not reported")
    require(!value.halfClose, "half-close capability was overclaimed")
    require(value.broadcast == broadcast, "broadcast capability differs from the qualified address family")
    require(value.multicast == multicast, "multicast capability differs from the qualified backend")
    require(!value.raw, "raw capability was overclaimed")
    require(!value.ancillaryData, "ancillary-data capability was overclaimed")
    require(!value.zeroLengthDatagramSend, "zero-length-send capability was overclaimed")
    require(value.connectedDatagramSend == connectedDatagramSend,
        "connected datagram send capability differed")
}
func requireOpen(state: SocketState): Unit {
    match (state) {
        case SocketState.Open => ()
        case _ => throw Exception("unsupported operation changed an open socket state")
    }
}
func requireListening(state: SocketState): Unit {
    match (state) {
        case SocketState.Listening => ()
        case _ => throw Exception("unsupported operation changed a listener state")
    }
}

func expectedCategory(value: api.NetworkErrorCategory, kind: Int64): Bool {
    match (value) {
        case api.NetworkErrorCategory.Unsupported => kind == 1
        case api.NetworkErrorCategory.Write => kind == 3
        case _ => false
    }
}
func expectedPhase(value: api.NetworkPhase, kind: Int64): Bool {
    match (value) {
        case api.NetworkPhase.RawSocket => kind == 1
        case api.NetworkPhase.TransportClose => kind == 2
        case api.NetworkPhase.DatagramSend => kind == 3
        case api.NetworkPhase.UnixSocket => kind == 4
        case _ => false
    }
}
func isUnsupported(value: api.NetworkErrorCode): Bool {
    match (value) { case api.NetworkErrorCode.Unsupported => true; case _ => false }
}
func isPermissionDenied(value: api.NetworkErrorCode): Bool {
    match (value) { case api.NetworkErrorCode.PermissionDenied => true; case _ => false }
}
func isNever(value: api.Retryability): Bool {
    match (value) { case api.Retryability.Never => true; case _ => false }
}
func expectUnsupported(category: Int64, phase: Int64, operation: () -> Unit): Unit {
    try {
        operation()
        throw Exception("unsupported operation unexpectedly succeeded")
    } catch (error: api.NetworkException) {
        require(expectedCategory(error.category, category), "unsupported operation changed error category")
        require(expectedPhase(error.phase, phase), "unsupported operation changed error phase")
        require(isUnsupported(error.code), "unsupported operation changed error code")
        require(isNever(error.retryability), "unsupported operation changed retryability")
    }
}
func probeRaw(label: String, domain: RawSocketDomain, protocol: RawSocketProtocol): Bool {
    try {
        let _ = RawSocket.open(domain, protocol)
        throw Exception("raw socket unexpectedly opened")
    } catch (error: api.NetworkException) {
        if (isPermissionDenied(error.code)) {
            announce("RAW_ENVIRONMENT_FAILURE ${label}")
            return false
        }
        require(expectedCategory(error.category, 1), "raw rejection changed error category")
        require(expectedPhase(error.phase, 1), "raw rejection changed error phase")
        require(isUnsupported(error.code), "raw rejection changed error code")
        require(isNever(error.retryability), "raw rejection changed retryability")
        announce("RAW_UNSUPPORTED ${label}")
        true
    }
}
func checkDnsParser(): Unit {
    let parser = DnsMessageParser(limits: DnsParserLimits(maximumMessageBytes: 12))
    let message = [0x12u8, 0x34u8, 0x81u8, 0x80u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8]
    let parsed = parser.parse(message)
    require(parsed.transactionId == 0x1234u16 && parsed.isResponse && parsed.questionCount == 0 &&
        parsed.answerCount == 0 && parsed.records.isEmpty(), "bounded DNS parser changed a valid empty response")
    try {
        let _ = parser.parse(Array<Byte>(11, repeat: 0u8))
        throw Exception("bounded DNS parser accepted a truncated header")
    } catch (error: api.ResolveException) {
        match (error.resolveCode) {
            case api.ResolveErrorCode.SystemFailure => ()
            case _ => throw error
        }
    }
    announce("DNS_PARSER_PASS")
}

main(): Int64 {
    let defaultCapabilities = SocketCapabilities()
    require(!defaultCapabilities.broadcast && !defaultCapabilities.multicast,
        "default capabilities falsely offered broadcast or multicast")
    announce("DEFAULT_CAPABILITIES_PASS")
    checkDnsParser()

    let tcpListener = TcpListener.bind(ipv4(0), context: context())
    let udp4 = UdpSocket.bind(ipv4(0), context: context())
    let udp6 = UdpSocket.bind(ipv6(0), context: context())
    let unixPrefix = getVariable("WIRESTACK_UNIX_PREFIX").getOrThrow()
    let unixListener = UnixListener.bind(api.UnixEndpoint.pathname(unixPrefix + "/listener"), context: context())
    let unixDatagram = UnixDatagramSocket.bind(api.UnixEndpoint.pathname(unixPrefix + "/datagram"), context: context())
    try {
        announce("READY ${tcpListener.localEndpoint.port}")
        let tcpAccepted = tcpListener.accept(context: context())
        let unixAccepted = unixListener.accept(context: context())
        let tcpOutgoing = TcpStream.connect(ipv4(UInt16.parse(
            getVariable("WIRESTACK_TCP_V4_PEER_PORT").getOrThrow())), context: context())
        let unixOutgoing = UnixStream.connect(api.UnixEndpoint.pathname(
            getVariable("WIRESTACK_UNIX_STREAM_PEER").getOrThrow()), context: context())
        try {
            exchangeAccepted(tcpAccepted, 1u8)
            exchangeAccepted(unixAccepted, 1u8)
            exchangeOutgoing(tcpOutgoing, 1u8)
            exchangeOutgoing(unixOutgoing, 1u8)

            let udp4Peer = api.NetworkEndpoint.Internet(ipv4(UInt16.parse(
                getVariable("WIRESTACK_UDP_V4_PEER_PORT").getOrThrow())))
            let udp6Peer = api.NetworkEndpoint.Internet(ipv6(UInt16.parse(
                getVariable("WIRESTACK_UDP_V6_PEER_PORT").getOrThrow())))
            udp4.connect(udp4Peer, context: context())
            udp6.connect(udp6Peer, context: context())
            require(udp4.send(api.ByteSpan(byte(1u8)), context: context()) == 1,
                "IPv4 connected datagram send failed")
            require(udp4.receive(1, context: context()).payload == byte(1u8), "IPv4 datagram echo differed")
            require(udp6.send(api.ByteSpan(byte(1u8)), context: context()) == 1,
                "IPv6 connected datagram send failed")
            require(udp6.receive(1, context: context()).payload == byte(1u8), "IPv6 datagram echo differed")

            let unixPeer = api.UnixEndpoint.pathname(getVariable("WIRESTACK_UNIX_DATAGRAM_PEER").getOrThrow())
            require(unixDatagram.sendTo(unixPeer, api.ByteSpan(byte(1u8)), context: context()) == 1,
                "Unix datagram sendTo failed")
            require(unixDatagram.receive(1, context: context()).payload == byte(1u8),
                "Unix datagram echo differed")
            unixDatagram.connect(unixPeer, context: context())

            requireCapabilities(tcpListener.capabilities)
            requireCapabilities(tcpAccepted.capabilities)
            requireCapabilities(tcpOutgoing.capabilities)
            requireCapabilities(udp4.capabilities, connectedDatagramSend: true, broadcast: true, multicast: true)
            requireCapabilities(udp6.capabilities, connectedDatagramSend: true, multicast: true)
            requireCapabilities(unixListener.capabilities)
            requireCapabilities(unixAccepted.capabilities)
            requireCapabilities(unixOutgoing.capabilities)
            requireCapabilities(unixDatagram.capabilities)
            emitCapabilities("TcpListener", "ipv4-listener", tcpListener.capabilities)
            emitCapabilities("TcpStream", "accepted-ipv4", tcpAccepted.capabilities)
            emitCapabilities("TcpStream", "outgoing-ipv4", tcpOutgoing.capabilities)
            emitCapabilities("UdpSocket", "ipv4", udp4.capabilities)
            emitCapabilities("UdpSocket", "ipv6", udp6.capabilities)
            emitCapabilities("UnixListener", "pathname-listener", unixListener.capabilities)
            emitCapabilities("UnixStream", "accepted-pathname", unixAccepted.capabilities)
            emitCapabilities("UnixStream", "outgoing-pathname", unixOutgoing.capabilities)
            emitCapabilities("UnixDatagramSocket", "pathname", unixDatagram.capabilities)

            announce("UNSUPPORTED_READY")
            require(readln() == "continue", "unsupported-operation checkpoint was not acknowledged")
            let raw4 = probeRaw("ipv4", RawSocketDomain.Ipv4, RawSocketProtocol.icmp())
            let raw6 = probeRaw("ipv6", RawSocketDomain.Ipv6, RawSocketProtocol.icmpv6())
            let rawPacket = probeRaw("packet", RawSocketDomain.Packet, RawSocketProtocol(0))
            let rawNetlink = probeRaw("netlink", RawSocketDomain.Netlink, RawSocketProtocol(0))
            expectUnsupported(1, 2, { => tcpAccepted.shutdown(api.ShutdownDirection.Write) })
            expectUnsupported(1, 2, { => tcpOutgoing.shutdown(api.ShutdownDirection.Write) })
            expectUnsupported(1, 2, { => unixAccepted.shutdown(api.ShutdownDirection.Write) })
            expectUnsupported(1, 2, { => unixOutgoing.shutdown(api.ShutdownDirection.Write) })
            expectUnsupported(1, 3, { => let _ = udp4.send(api.ByteSpan(Array<Byte>()), context: context()) })
            expectUnsupported(1, 3, { => let _ = udp6.send(api.ByteSpan(Array<Byte>()), context: context()) })
            expectUnsupported(1, 3, { => let _ = unixDatagram.sendTo(
                unixPeer, api.ByteSpan(Array<Byte>()), context: context()) })
            expectUnsupported(3, 3, { => let _ = unixDatagram.send(api.ByteSpan(byte(7u8)), context: context()) })

            let shortAbstract = api.UnixEndpoint.abstractName("short".toArray())
            let invalidBytes = Array<Byte>(107, repeat: 0x77u8)
            invalidBytes[106] = 0xFFu8
            let invalidAbstract = api.UnixEndpoint.abstractName(invalidBytes)
            for (endpoint in [shortAbstract, invalidAbstract]) {
                expectUnsupported(1, 4, { => let value = UnixListener.bind(endpoint, context: context()); value.close() })
                expectUnsupported(1, 4, { => let value = UnixStream.connect(endpoint, context: context()); value.close() })
                expectUnsupported(1, 4, { => let value = UnixDatagramSocket.bind(endpoint, context: context()); value.close() })
                expectUnsupported(1, 4, { => let _ = unixDatagram.sendTo(endpoint,
                    api.ByteSpan(byte(9u8)), context: context()) })
            }

            exchangeAccepted(tcpAccepted, 2u8)
            exchangeAccepted(unixAccepted, 2u8)
            exchangeOutgoing(tcpOutgoing, 2u8)
            exchangeOutgoing(unixOutgoing, 2u8)
            require(udp4.send(api.ByteSpan(byte(2u8)), context: context()) == 1,
                "IPv4 socket failed after unsupported operation")
            require(udp4.receive(1, context: context()).payload == byte(2u8),
                "IPv4 socket received the wrong recovery packet")
            require(udp6.send(api.ByteSpan(byte(2u8)), context: context()) == 1,
                "IPv6 socket failed after unsupported operation")
            require(udp6.receive(1, context: context()).payload == byte(2u8),
                "IPv6 socket received the wrong recovery packet")
            require(unixDatagram.sendTo(unixPeer, api.ByteSpan(byte(2u8)), context: context()) == 1,
                "Unix datagram failed after unsupported operation")
            require(unixDatagram.receive(1, context: context()).payload == byte(2u8),
                "Unix datagram received the wrong recovery packet")
            requireOpen(tcpAccepted.state)
            requireOpen(tcpOutgoing.state)
            requireOpen(udp4.state)
            requireOpen(udp6.state)
            requireOpen(unixAccepted.state)
            requireOpen(unixOutgoing.state)
            requireOpen(unixDatagram.state)
            requireListening(tcpListener.state)
            requireListening(unixListener.state)
            announce("UNSUPPORTED_DONE ${raw4} ${raw6} ${rawPacket} ${rawNetlink}")
            require(readln() == "continue", "unsupported-operation proof was not acknowledged")
        } finally {
            tcpAccepted.close()
            tcpOutgoing.close()
            unixAccepted.close()
            unixOutgoing.close()
        }
    } finally {
        tcpListener.close()
        udp4.close()
        udp6.close()
        unixListener.close()
        unixDatagram.close()
    }
    announce("CAPABILITY_CONTRACT_PASS")
    0
}
