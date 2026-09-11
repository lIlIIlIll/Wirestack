package wirestack_m8_002_native

import std.convert.Parsable
import std.env.getVariable
import std.env.getStdOut
import wirestack as api
import wirestack.net.*

let nativeFamily = getVariable("WIRESTACK_NATIVE_FAMILY").getOrThrow()

func announce(value: String): Unit {
    println(value)
    getStdOut().flush()
}

func require(value: Bool, message: String): Unit {
    if (!value) { throw Exception(message) }
}

func context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(5 * Duration.second)))
}

func endpoint(port: UInt16): api.SocketEndpoint {
    if (nativeFamily == "ipv6") {
        let bytes = Array<Byte>(16, repeat: 0)
        bytes[15] = 1
        return api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv6, bytes), port)
    }
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

func port(value: ?api.NetworkEndpoint): UInt16 {
    match (value) {
        case Some(api.NetworkEndpoint.Internet(address)) => address.port
        case _ => throw Exception("native consumer expected an Internet endpoint")
    }
}

func payload(): Array<Byte> {
    let bytes = Array<Byte>(32 * 1024, repeat: 0)
    for (index in 0..bytes.size) { bytes[index] = UInt8(index % 251) }
    bytes
}

func unsupported(operation: () -> Unit): Unit {
    try {
        operation()
        throw Exception("empty send unexpectedly succeeded")
    } catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.Unsupported => ()
            case _ => throw error
        }
    }
}

func checkpoint(name: String): Unit {
    announce("CHECKPOINT ${name}")
    require(readln() == "continue", "native harness checkpoint was not acknowledged")
}

func concurrent(operation: () -> Unit): Unit {
    try {
        operation()
        throw Exception("overlapping operation was admitted")
    } catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.ConcurrentOperation => ()
            case _ => throw error
        }
    }
}

func waitingUdp(cancel: Bool): Unit {
    let socket = UdpSocket.bind(endpoint(0), context: context())
    let cancellation = api.CancellationSource()
    let mode = if (cancel) { "cancel" } else { "close" }
    let pending: Future<Bool> = spawn {
        try {
            let _ = socket.receive(1, context: api.OperationContext(
                cancellation: cancellation.token,
                deadline: Some(api.Deadline.after(5 * Duration.second))
            ))
            false
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.Cancelled => cancel
                case api.NetworkErrorCode.Closed => !cancel
                case _ => throw error
            }
        }
    }
    try {
        announce("WAIT_READY ${mode} ${port(socket.localEndpoint)}")
        require(readln() == "stop", "native wait was not acknowledged")
        if (cancel) {
            let peerPort = UInt16.parse(getVariable("WIRESTACK_UDP_PEER_PORT").getOrThrow())
            let peer = api.NetworkEndpoint.Internet(endpoint(peerPort))
            concurrent({ => socket.connect(peer, context: context()) })
            concurrent({ => let _ = socket.receive(1, context: context()) })
            require(socket.sendTo(peer, api.ByteSpan([0x6Cu8, 0x69u8, 0x76u8, 0x65u8]),
                context: context()) == 4, "opposite-direction UDP send was blocked")
            cancellation.cancel()
        } else {
            socket.close()
        }
        require(pending.get(Duration.second), "active UDP wait returned the wrong terminal error")
        require(socket.isClosed(), "active UDP wait retained its native socket")
        match (socket.state) {
            case SocketState.Aborted => require(cancel, "graceful close became abortive")
            case SocketState.Closed => require(!cancel, "active cancellation lost abort ownership")
            case _ => throw Exception("active UDP wait did not retain terminal state")
        }
        announce("WAIT_PASS ${mode}")
        require(readln() == "next", "native wait completion was not acknowledged")
    } finally {
        cancellation.cancel()
        socket.close()
    }
}

main(): Int64 {
    let listener = TcpListener.bind(endpoint(0), context: context())
    let datagram = UdpSocket.bind(endpoint(0), context: context())
    try {
        announce("READY ${listener.localEndpoint.port} ${port(datagram.localEndpoint)}")
        let accepted = listener.accept(context: context())
        try {
            require(accepted.capabilities.nonBlocking && accepted.capabilities.closeOnExec,
                "accepted TCP descriptor capabilities were not reported")
            let expected = payload()
            let received = Array<Byte>(expected.size, repeat: 0)
            accepted.readExact(api.MutableByteSpan(received), context: context())
            require(received == expected, "independent TCP client payload differed")
            accepted.writeAll(api.ByteSpan(received), context: context())
        } finally {
            accepted.close()
        }
        listener.close()

        let peerPort = UInt16.parse(getVariable("WIRESTACK_TCP_PEER_PORT").getOrThrow())
        let outgoing = TcpStream.connect(endpoint(peerPort), context: context())
        try {
            require(outgoing.capabilities.nonBlocking && outgoing.capabilities.closeOnExec,
                "connected TCP descriptor capabilities were not reported")
            let expected = payload()
            outgoing.writeAll(api.ByteSpan(expected), context: context())
            let received = Array<Byte>(expected.size, repeat: 0)
            outgoing.readExact(api.MutableByteSpan(received), context: context())
            require(received == expected, "independent TCP server payload differed")
            match (outgoing.read(api.MutableByteSpan(Array<Byte>(1, repeat: 0)), context: context())) {
                case ReadResult.EndOfStream => ()
                case _ => throw Exception("independent TCP server did not reach EOF")
            }
            outgoing.writeAll(api.ByteSpan([0x61u8, 0x66u8, 0x74u8, 0x65u8, 0x72u8]), context: context())
        } finally {
            outgoing.close()
        }
        announce("TCP_NATIVE_PASS")

        require(datagram.capabilities.nonBlocking && datagram.capabilities.closeOnExec,
            "UDP descriptor capabilities were not reported")
        require(!datagram.capabilities.zeroLengthDatagramSend,
            "std.net backend overclaimed empty-send capability")
        let empty = datagram.receive(4, context: context())
        require(empty.payload.isEmpty() && !empty.truncated, "empty UDP packet was not preserved")
        let peer = empty.source.getOrThrow()
        let truncated = datagram.receive(4, context: context())
        require(truncated.payload == [1u8, 2u8, 3u8, 4u8] && truncated.truncated,
            "UDP truncation did not retain exactly the requested bytes")
        let exact = datagram.receive(4, context: context())
        require(exact.payload == [9u8, 10u8, 11u8, 12u8] && !exact.truncated,
            "exact-size UDP packet was mislabeled")
        require(truncated.payload == [1u8, 2u8, 3u8, 4u8], "later receive mutated an owned result")
        datagram.connect(peer, context: context())
        unsupported({ => let _ = datagram.send(api.ByteSpan(Array<Byte>()), context: context()) })
        unsupported({ => let _ = datagram.sendTo(peer, api.ByteSpan(Array<Byte>()), context: context()) })
        require(!datagram.isClosed(), "unsupported empty send closed the UDP socket")
        require(datagram.send(api.ByteSpan([0x41u8, 0x42u8]), context: context()) == 2,
            "connected datagram send was not atomic")
        announce("UDP_CONNECTED")
        let filtered = datagram.receive(4, context: context())
        require(filtered.payload == [0x44u8], "connected UDP accepted the wrong peer")
        let maximum = Array<Byte>(65507, repeat: 0u8)
        for (index in 0..maximum.size) { maximum[index] = UInt8(index % 251) }
        require(datagram.send(api.ByteSpan(maximum), context: context()) == maximum.size,
            "maximum UDP send was not atomic")
        let maximumReply = datagram.receive(maximum.size, context: context())
        require(maximumReply.payload == maximum && !maximumReply.truncated,
            "maximum UDP receive changed packet bytes or truncation")
        try {
            let _ = datagram.receive(4, context: api.OperationContext(
                deadline: Some(api.Deadline.after(50 * Duration.millisecond))))
            throw Exception("UDP deadline unexpectedly received a packet")
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => throw error
            }
        }
        datagram.close()
        announce("UDP_NATIVE_PASS")
    } finally {
        listener.close()
        datagram.close()
    }

    checkpoint("baseline")
    for (_ in 0..64) {
        let listener = TcpListener.bind(endpoint(0), context: context())
        try {
            let socket = UdpSocket.bind(endpoint(0), context: context())
            socket.close()
        } finally {
            listener.close()
        }
    }
    waitingUdp(true)
    waitingUdp(false)
    checkpoint("after")
    announce("NATIVE_NETWORK_PASS")
    0
}
