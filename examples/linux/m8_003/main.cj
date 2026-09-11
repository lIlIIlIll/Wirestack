package wirestack_m8_003_native

import std.env.getVariable
import std.env.getStdOut
import wirestack as api
import wirestack.net.*

let profile = getVariable("WIRESTACK_UNIX_PROFILE").getOrThrow()
let prefix = getVariable("WIRESTACK_UNIX_PREFIX").getOrThrow()

func announce(value: String): Unit { println(value); getStdOut().flush() }
func require(value: Bool, message: String): Unit { if (!value) { throw Exception(message) } }
func context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(10 * Duration.second)))
}
func endpoint(label: String): api.UnixEndpoint {
    if (profile == "abstract") {
        let name = (prefix + "-" + label + "\0tailé").toArray()
        require(name.size <= 107, "native fixture name exceeded the endpoint bound")
        return api.UnixEndpoint.abstractName(Array<Byte>(107, { index =>
            if (index < name.size) { name[index] } else { 0x7Au8 }
        }))
    }
    api.UnixEndpoint.pathname(prefix + "/" + label)
}
func kind(value: api.UnixEndpoint): Int64 {
    match (value.kind) {
        case api.UnixEndpointKind.Pathname => 1
        case api.UnixEndpointKind.Abstract => 2
        case api.UnixEndpointKind.Unnamed => 3
    }
}
func assertEndpoint(actual: ?api.NetworkEndpoint, expected: api.UnixEndpoint): Unit {
    match (actual) {
        case Some(api.NetworkEndpoint.Unix(value)) =>
            require(kind(value) == kind(expected) && value.nameBytes() == expected.nameBytes(),
                "Unix endpoint form or bytes changed")
        case _ => throw Exception("Unix endpoint diagnostics are missing")
    }
}
func payload(size: Int64): Array<Byte> {
    Array<Byte>(size, { index => UInt8(index % 251) })
}
func errorCode(error: api.NetworkException): Int64 {
    match (error.code) {
        case api.NetworkErrorCode.Unsupported => 1
        case api.NetworkErrorCode.InvalidState => 2
        case api.NetworkErrorCode.ConcurrentOperation => 3
        case api.NetworkErrorCode.Cancelled => 4
        case api.NetworkErrorCode.Closed => 5
        case api.NetworkErrorCode.TimedOut => 6
        case _ => throw error
    }
}
func expectError(code: Int64, operation: () -> Unit): Unit {
    try {
        operation()
        throw Exception("operation unexpectedly succeeded")
    } catch (error: api.NetworkException) {
        require(errorCode(error) == code, "operation returned the wrong structured error")
    }
}
func checkpoint(label: String): Unit {
    announce("CHECKPOINT ${label}")
    require(readln() == "continue", "resource checkpoint was not acknowledged")
}
func waitAccept(): Unit {
    let listener = UnixListener.bind(endpoint("wait-listener"), context: context())
    let cancellation = api.CancellationSource()
    let pending = spawn {
        try {
            let accepted = listener.accept(context: api.OperationContext(cancellation: cancellation.token,
                deadline: Some(api.Deadline.after(10 * Duration.second))))
            accepted.close()
            false
        } catch (error: api.NetworkException) { errorCode(error) == 4 }
    }
    try {
        announce("WAIT_ACCEPT")
        require(readln() == "stop", "accept admission was not observed")
        expectError(3, { => let socket = listener.accept(context: context()); socket.close() })
        cancellation.cancel()
        require(pending.get(2 * Duration.second), "pending accept did not cancel")
        require(!listener.isClosed(), "accept cancellation closed its listener")
        announce("ACCEPT_REUSABLE")
        let accepted = listener.accept(context: context())
        try {
            let bytes = Array<Byte>(2, repeat: 0)
            accepted.readExact(api.MutableByteSpan(bytes), context: context())
            require(bytes == [0x6Fu8, 0x6Bu8], "listener did not accept after cancellation")
        } finally { accepted.close() }
        announce("ACCEPT_PASS")
        require(readln() == "next", "accept completion was not acknowledged")
    } finally { cancellation.cancel(); listener.close() }
}
func waitDatagram(cancel: Bool): Unit {
    let mode = if (cancel) { "cancel" } else { "close" }
    let socket = UnixDatagramSocket.bind(endpoint("wait-" + mode), context: context())
    let cancellation = api.CancellationSource()
    let pending = spawn {
        try {
            let _ = socket.receive(1, context: api.OperationContext(cancellation: cancellation.token,
                deadline: Some(api.Deadline.after(10 * Duration.second))))
            false
        } catch (error: api.NetworkException) {
            assertEndpoint(error.localEndpoint, endpoint("wait-" + mode))
            errorCode(error) == if (cancel) { 4 } else { 5 }
        }
    }
    try {
        announce("WAIT_DATAGRAM ${mode}")
        require(readln() == "stop", "datagram admission was not observed")
        if (cancel) {
            expectError(3, { => let _ = socket.receive(1, context: context()) })
            expectError(3, { => socket.connect(endpoint("peer-datagram"), context: context()) })
            require(socket.sendTo(endpoint("peer-datagram"), api.ByteSpan("live".toArray()),
                context: context()) == 4, "opposite-direction Unix send was blocked")
            cancellation.cancel()
        } else { socket.close() }
        require(pending.get(2 * Duration.second), "pending datagram wait did not terminate")
        require(socket.isClosed(), "terminal datagram operation retained its socket")
        match (socket.state) {
            case SocketState.Aborted => require(cancel, "graceful close became abortive")
            case SocketState.Closed => require(!cancel, "cancellation lost abort ownership")
            case _ => throw Exception("terminal datagram state missing")
        }
        socket.close(context: api.OperationContext(cancellation: cancellation.token,
            deadline: Some(api.Deadline.after(Duration.Zero))))
        announce("DATAGRAM_WAIT_PASS ${mode}")
        require(readln() == "next", "datagram completion was not acknowledged")
    } finally { cancellation.cancel(); socket.close() }
}
func waitStream(cancel: Bool): Unit {
    let mode = if (cancel) { "cancel" } else { "close" }
    let local = endpoint("wait-stream-" + mode)
    let listener = UnixListener.bind(local, context: context())
    let cancellation = api.CancellationSource()
    try {
        announce("WAIT_STREAM_LISTEN ${mode}")
        let socket = listener.accept(context: context())
        try {
            let pending = spawn {
                try {
                    let _ = socket.read(api.MutableByteSpan(Array<Byte>(1, repeat: 0)),
                        context: api.OperationContext(cancellation: cancellation.token,
                            deadline: Some(api.Deadline.after(10 * Duration.second))))
                    false
                } catch (error: api.NetworkException) {
                    assertEndpoint(error.localEndpoint, local)
                    errorCode(error) == if (cancel) { 4 } else { 5 }
                }
            }
            announce("WAIT_STREAM ${mode}")
            require(readln() == "stop", "stream admission was not observed")
            if (cancel) {
                expectError(3, { => let _ = socket.read(api.MutableByteSpan(Array<Byte>(1, repeat: 0)),
                    context: context()) })
                socket.writeAll(api.ByteSpan("live".toArray()), context: context())
                cancellation.cancel()
            } else { socket.close() }
            require(pending.get(2 * Duration.second), "pending Unix read did not terminate")
            match (socket.state) {
                case SocketState.Aborted => require(cancel, "graceful stream close became abortive")
                case SocketState.Closed => require(!cancel, "stream cancellation lost abort ownership")
                case _ => throw Exception("terminal Unix stream state missing")
            }
            socket.close(context: api.OperationContext(cancellation: cancellation.token,
                deadline: Some(api.Deadline.after(Duration.Zero))))
            announce("STREAM_WAIT_PASS ${mode}")
            require(readln() == "next", "stream completion was not acknowledged")
        } finally { cancellation.cancel(); socket.close() }
    } finally { listener.close() }
}
func backpressuredWrite(): Unit {
    let local = endpoint("write-timeout")
    let listener = UnixListener.bind(local, context: context())
    try {
        announce("WRITE_TIMEOUT_LISTEN")
        let socket = listener.accept(context: context())
        try {
            try {
                socket.writeAll(api.ByteSpan(payload(1048576)),
                    context: api.OperationContext(deadline: Some(api.Deadline.after(2 * Duration.second))))
                throw Exception("backpressured Unix write unexpectedly completed")
            } catch (error: api.NetworkException) {
                require(errorCode(error) == 6, "backpressured Unix write did not time out")
                match (error.category) {
                    case api.NetworkErrorCategory.Write => ()
                    case _ => throw Exception("write timeout category changed")
                }
                match (error.retryability) {
                    case api.Retryability.Never => ()
                    case _ => throw Exception("admitted write timeout became replayable")
                }
                assertEndpoint(error.localEndpoint, local)
                require(error.cause.isSome(), "native write timeout cause was lost")
            }
            announce("WRITE_TIMEOUT_PASS")
            require(readln() == "next", "write timeout was not acknowledged")
        } finally { socket.close() }
    } finally { listener.close() }
}
func connectedPathIdentity(): Unit {
    if (profile != "pathname") { return }
    let socket = UnixDatagramSocket.bind(endpoint("connected-identity"), context: context())
    try {
        announce("IDENTITY_BIND")
        require(readln() == "connect", "identity peer was not bound")
        socket.connect(endpoint("identity-peer"), context: context())
        announce("IDENTITY_SELECTED")
        require(readln() == "send", "identity path was not replaced")
        expectError(1, { => let _ = socket.send(api.ByteSpan("selected".toArray()), context: context()) })
        announce("IDENTITY_SEND_BLOCKED")
        let selected = socket.receive(8, context: context())
        require(selected.payload == "right".toArray(), "replacement peer bypassed connected receive filtering")
        require(socket.sendTo(endpoint("identity-peer"), api.ByteSpan("override".toArray()),
            context: context()) == 8, "explicit destination did not override the selected peer")
        announce("IDENTITY_PASS")
        require(readln() == "next", "identity proof was not acknowledged")
    } finally { socket.close() }
}
main(): Int64 {
    let rawName = Array<Byte>(107, repeat: 0x77u8)
    rawName[106] = 0xFFu8
    let unsupportedName = api.UnixEndpoint.abstractName(rawName)
    require(unsupportedName.nameBytes() == rawName, "shared byte-name model was narrowed")
    let shortName = api.UnixEndpoint.abstractName("short".toArray())
    require(shortName.nameBytes() == "short".toArray(), "short endpoint model was narrowed")
    expectError(1, { => let value = UnixListener.bind(shortName); value.close() })
    expectError(1, { => let value = UnixStream.connect(shortName); value.close() })
    expectError(1, { => let value = UnixDatagramSocket.bind(shortName); value.close() })
    expectError(1, { => let value = UnixListener.bind(unsupportedName); value.close() })
    expectError(1, { => let value = UnixStream.connect(unsupportedName); value.close() })
    expectError(1, { => let value = UnixDatagramSocket.bind(unsupportedName); value.close() })
    expectError(2, { => let value = UnixListener.bind(api.UnixEndpoint.unnamed()); value.close() })
    expectError(2, { => let value = UnixStream.connect(api.UnixEndpoint.unnamed()); value.close() })
    expectError(2, { => let value = UnixDatagramSocket.bind(api.UnixEndpoint.unnamed()); value.close() })
    for (domain in [RawSocketDomain.Ipv4, RawSocketDomain.Ipv6, RawSocketDomain.Packet, RawSocketDomain.Netlink]) {
        expectError(1, { => let _ = RawSocket.open(domain, RawSocketProtocol(1)) })
    }
    let listener = UnixListener.bind(endpoint("listener"), context: context())
    let socket = UnixDatagramSocket.bind(endpoint("datagram"), context: context())
    try {
        expectError(1, { => let _ = socket.sendTo(unsupportedName, api.ByteSpan("x".toArray()), context: context()) })
        expectError(1, { => let _ = socket.sendTo(shortName, api.ByteSpan("x".toArray()), context: context()) })
        expectError(2, { => let _ = socket.sendTo(api.UnixEndpoint.unnamed(), api.ByteSpan("x".toArray()), context: context()) })
        announce("READY")
        let accepted = listener.accept(context: context())
        try {
            assertEndpoint(accepted.localEndpoint, endpoint("listener"))
            assertEndpoint(accepted.remoteEndpoint, api.UnixEndpoint.unnamed())
            require(accepted.capabilities.nonBlocking && accepted.capabilities.closeOnExec,
                "accepted stream capabilities missing")
            let expected = payload(32768)
            let received = Array<Byte>(expected.size, repeat: 0)
            accepted.readExact(api.MutableByteSpan(received), context: context())
            require(received == expected, "accepted stream bytes differed")
            accepted.writeAll(api.ByteSpan(received), context: context())
        } finally { accepted.close() }
        listener.close()
        let outgoing = UnixStream.connect(endpoint("peer-stream"), context: context())
        try {
            assertEndpoint(outgoing.localEndpoint, api.UnixEndpoint.unnamed())
            assertEndpoint(outgoing.remoteEndpoint, endpoint("peer-stream"))
            let expected = payload(32768)
            outgoing.writeAll(api.ByteSpan(expected), context: context())
            let received = Array<Byte>(expected.size, repeat: 0)
            outgoing.readExact(api.MutableByteSpan(received), context: context())
            require(received == expected, "outgoing stream bytes differed")
            for (_ in 0..2) {
                match (outgoing.read(api.MutableByteSpan(Array<Byte>(1, repeat: 0)), context: context())) {
                    case ReadResult.EndOfStream => ()
                    case _ => throw Exception("Unix stream EOF was not stable")
                }
            }
            outgoing.writeAll(api.ByteSpan("after".toArray()), context: context())
        } finally { outgoing.close() }
        announce("STREAM_PASS")
        backpressuredWrite()
        assertEndpoint(socket.localEndpoint, endpoint("datagram"))
        require(socket.capabilities.nonBlocking && socket.capabilities.closeOnExec,
            "Unix datagram capabilities missing")
        require(!socket.capabilities.zeroLengthDatagramSend, "empty-send capability overclaimed")
        require(!socket.capabilities.connectedDatagramSend, "connected-send capability overclaimed")
        let empty = socket.receive(4, context: context())
        require(empty.payload.isEmpty() && !empty.truncated, "empty Unix packet was lost")
        assertEndpoint(empty.source, endpoint("peer-datagram"))
        let truncated = socket.receive(4, context: context())
        require(truncated.payload == [1u8, 2u8, 3u8, 4u8] && truncated.truncated, "truncation differed")
        let exact = socket.receive(4, context: context())
        require(exact.payload == [9u8, 10u8, 11u8, 12u8] && !exact.truncated, "exact packet differed")
        require(truncated.payload == [1u8, 2u8, 3u8, 4u8], "later receive mutated owned data")
        let arbitrary = socket.receive(4, context: context())
        require(arbitrary.payload == "raw".toArray() && !arbitrary.truncated,
            "arbitrary-source datagram bytes differed")
        let namePrefix = (prefix + "-arbitrary-").toArray()
        let sender = api.UnixEndpoint.abstractName(Array<Byte>(namePrefix.size + 1, { index =>
            if (index == namePrefix.size) { 0xFFu8 } else { namePrefix[index] }
        }))
        assertEndpoint(arbitrary.source, sender)
        socket.connect(endpoint("peer-datagram"), context: context())
        expectError(1, { => let _ = socket.send(api.ByteSpan("blocked".toArray()), context: context()) })
        expectError(1, { => let _ = socket.send(api.ByteSpan(Array<Byte>()), context: context()) })
        expectError(1, { => let _ = socket.sendTo(endpoint("peer-datagram"), api.ByteSpan(Array<Byte>()), context: context()) })
        require(!socket.isClosed(), "empty-send rejection disposed the socket")
        require(socket.sendTo(endpoint("peer-datagram"), api.ByteSpan("AB".toArray()), context: context()) == 2,
            "explicit send after connected-send rejection differed")
        announce("DATAGRAM_CONNECTED")
        let filtered = socket.receive(4, context: context())
        require(filtered.payload == [0x44u8], "connected Unix peer filter failed")
        let maximum = payload(65507)
        require(socket.sendTo(endpoint("peer-datagram"), api.ByteSpan(maximum), context: context()) == maximum.size,
            "maximum send differed")
        let reply = socket.receive(maximum.size, context: context())
        require(reply.payload == maximum && !reply.truncated, "maximum receive differed")
        expectError(6, { => let _ = socket.receive(4, context: api.OperationContext(
            deadline: Some(api.Deadline.after(50 * Duration.millisecond)))) })
        socket.close()
        announce("DATAGRAM_PASS")
    } finally { listener.close(); socket.close() }
    connectedPathIdentity()
    checkpoint("baseline")
    for (index in 0..64) {
        let listener = UnixListener.bind(endpoint("cycle-stream-${index}"), context: context())
        try {
            let socket = UnixDatagramSocket.bind(endpoint("cycle-datagram-${index}"), context: context())
            socket.close()
        } finally { listener.close() }
    }
    waitAccept()
    waitStream(true)
    waitStream(false)
    waitDatagram(true)
    waitDatagram(false)
    checkpoint("after")
    announce("NATIVE_UNIX_PASS")
    0
}
