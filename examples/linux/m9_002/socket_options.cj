package wirestack_m9_002_socket_options

import std.env.getStdOut
import std.sync.*
import std.time.MonoTime
import wirestack as api
import wirestack.net.*
import wirestack.http.*

func require(value: Bool, reason: String): Unit { if (!value) { throw Exception(reason) } }
func announce(value: String): Unit { println(value); getStdOut().flush() }
func context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(5 * Duration.second)))
}
func endpoint(ipv6!: Bool = false): api.SocketEndpoint {
    let bytes = if (ipv6) { Array<Byte>(16, { i => if (i == 15) { 1u8 } else { 0u8 } }) }
        else { [127u8, 0u8, 0u8, 1u8] }
    api.SocketEndpoint(api.IpAddress(if (ipv6) { api.IpAddressFamily.Ipv6 } else { api.IpAddressFamily.Ipv4 }, bytes), 0)
}
func noDelay(stream: TcpStream, operation!: api.OperationContext = context()): Bool {
    match (stream.getOption(SocketOptionName.NoDelay, context: operation)) {
        case SocketOption.NoDelay(value) => value
        case _ => throw Exception("query returned the wrong option kind")
    }
}
func receiveBuffer(socket: UdpSocket): Int64 {
    match (socket.getOption(SocketOptionName.ReceiveBuffer, context: context())) {
        case SocketOption.ReceiveBuffer(value) => value
        case _ => throw Exception("query returned the wrong buffer kind")
    }
}

func runOptions(): Unit {
    for (ipv6 in [false, true]) {
        let local = endpoint(ipv6: ipv6)
        let listener = TcpListener.bind(local, options: [SocketOption.ReusePort(true)],
            acceptedOptions: [SocketOption.NoDelay(false), SocketOption.KeepAlive(true)], context: context())
        try {
            let client = TcpStream.connect(listener.localEndpoint, options: [SocketOption.NoDelay(false)], context: context())
            try {
                let accepted = listener.accept(context: context())
                try {
                    require(!noDelay(client) && !noDelay(accepted), "factory overrides did not take effect")
                    accepted.configure([SocketOption.NoDelay(true), SocketOption.KeepAlive(false)], context: context())
                    require(noDelay(accepted), "open stream option did not take effect")
                    client.writeAll(api.ByteSpan([41u8, 42u8]), context: context())
                    let bytes = Array<Byte>(2, repeat: 0u8)
                    accepted.readExact(api.MutableByteSpan(bytes), context: context())
                    require(bytes == [41u8, 42u8], "configured TCP stream changed payload")
                } finally { accepted.close() }
            } finally { client.close() }
        } finally { listener.close() }
        let sender = UdpSocket.bind(local, options: [SocketOption.ReceiveBuffer(4096)], context: context())
        let receiver = UdpSocket.bind(local, context: context())
        try {
            let effective = receiveBuffer(sender)
            require(effective > 0 && effective != 4096, "buffer query echoed the request rather than Linux's effective size")
            if (ipv6) {
                sender.configure([SocketOption.MulticastHopLimit(0), SocketOption.MulticastLoopback(false), SocketOption.MulticastInterface(0)], context: context())
                require(!sender.capabilities.broadcast, "IPv6 socket advertised IPv4 broadcast")
            } else {
                sender.configure([SocketOption.Broadcast(true), SocketOption.MulticastTtl(0), SocketOption.MulticastLoopback(false), SocketOption.MulticastInterface(0)], context: context())
                require(sender.capabilities.broadcast, "IPv4 broadcast configuration was not advertised")
                try {
                    let _ = sender.getOption(SocketOptionName.MulticastInterface, context: context())
                    throw Exception("IPv4 interface readback unexpectedly succeeded")
                } catch (error: api.NetworkException) {
                    match (error.code) {
                        case api.NetworkErrorCode.Unsupported => ()
                        case _ => throw error
                    }
                }
            }
            require(sender.sendTo(receiver.localEndpoint.getOrThrow(), api.ByteSpan([51u8]), context: context()) == 1, "UDP send length changed")
            require(receiver.receive(4, context: context()).payload == [51u8], "configured UDP payload changed")
            let family = if (ipv6) { "ipv6" } else { "ipv4" }
            announce("OPTIONS family=${family} requested-buffer=4096 effective-buffer=${effective}")
        } finally { sender.close(); receiver.close() }
    }
    announce("M9_002_OPTIONS_PASS")
}

class ConfiguredConnector <: HttpConnector & HttpServerHandler {
    let configured = AtomicInt64(0)

    public func connect(remote: api.SocketEndpoint, operation: api.OperationContext): api.DuplexTransport {
        let stream = TcpStream.connect(remote, options: [SocketOption.NoDelay(false)], context: operation)
        try {
            require(!noDelay(stream, operation: operation), "HttpConnector factory option was lost")
            stream.configure([SocketOption.NoDelay(true)], context: operation)
            require(noDelay(stream, operation: operation), "HttpConnector runtime configuration was lost")
            configured.fetchAdd(1)
            stream
        } catch (error: Exception) { stream.close(); throw error }
    }

    public func handle(request: HttpServerRequest, _: api.OperationContext): HttpServerResponse {
        request.body.close()
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("options-ok").open()),
            headers: HttpHeaders.builder().add("Content-Length", "10").build()))
    }
}

func runHttp(): Unit {
    let connector = ConfiguredConnector()
    let server = HttpServer.builder().listen(endpoint()).handler(connector).connectionLimit(4).build()
    let serving = spawn { server.serve() }
    let client = HttpClient.builder().resolver(api.StaticResolver(api.ResolveResult(
        [server.localEndpoint.address], api.HostName("options.test"), api.ResolverSource.Static)))
        .connector(connector).requestTimeout(5 * Duration.second).build()
    try {
        let response = client.get("http://options.test:${server.localEndpoint.port}/", context: context())
        try {
            let bytes = Array<Byte>(10, repeat: 0u8)
            let expected = "options-ok".toArray()
            var offset: Int64 = 0
            while (offset < expected.size) {
                let count = response.body.read(bytes)
                require(count > 0 && count <= expected.size - offset, "HTTP body length changed")
                for (i in 0..count) { require(bytes[i] == expected[offset + i], "HTTP response byte changed") }
                offset += count
            }
            require(response.body.read(bytes) == 0, "HTTP body exceeded its declared length")
            require(connector.configured.load() == 1, "HTTP did not use the configured public connector")
        } finally { response.close() }
    } finally {
        client.close()
        let result = server.shutdown(context: context())
        require(result.activeAtReturn == 0, "server retained active connections")
        serving.get(5 * Duration.second)
        server.close()
    }
    announce("M9_002_HTTP_CONNECTOR_PASS")
}

func requireRejected(action: () -> Unit): Unit {
    var rejected = false
    try { action() }
    catch (_: IllegalArgumentException) { rejected = true }
    catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.Unsupported | api.NetworkErrorCode.InvalidState => rejected = true
            case _ => throw error
        }
    }
    require(rejected, "invalid option was admitted")
}

func runInvalidAdmission(): Unit {
    for (value in [-1i64, 0i64, 2147483648i64]) {
        requireRejected({ => let _ = UdpSocket.bind(endpoint(), options: [SocketOption.ReceiveBuffer(value)]) })
        requireRejected({ => let _ = TcpStream.connect(endpoint(), options: [SocketOption.SendBuffer(value)]) })
        requireRejected({ => let _ = TcpListener.bind(endpoint(), acceptedOptions: [SocketOption.ReceiveBuffer(value)]) })
    }
    requireRejected({ => let _ = UdpSocket.bind(endpoint(), options: [SocketOption.MulticastInterface(2147483648)]) })
    requireRejected({ => let _ = UdpSocket.bind(endpoint(), options: [SocketOption.Broadcast(true)]) })
    requireRejected({ => let _ = TcpListener.bind(endpoint(), options: [SocketOption.NoDelay(true)]) })
    requireRejected({ => let _ = TcpStream.connect(endpoint(), options: [SocketOption.Ipv6Only(true)]) })
    requireRejected({ => let _ = TcpListener.bind(endpoint(), acceptedOptions: [SocketOption.NoDelay(true), SocketOption.NoDelay(false)]) })
    requireRejected({ => let _ = UdpSocket.bind(endpoint(), options: Array<SocketOption>(13, repeat: SocketOption.ReuseAddress(true))) })
    announce("M9_002_INVALID_ADMISSION_PASS")
}

func isConcurrent(action: () -> Unit): Bool {
    try { action(); false }
    catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.ConcurrentOperation => true
            case _ => throw error
        }
    }
}

func runSendControl(): Unit {
    let sender = UdpSocket.bind(endpoint())
    let peer = UdpSocket.bind(endpoint())
    try {
        let sending = spawn { sender.sendTo(peer.localEndpoint.getOrThrow(), api.ByteSpan([73u8]), context: context()) }
        let expires = MonoTime.now() + 5 * Duration.second
        var observed = false
        while (!observed && MonoTime.now() < expires) {
            observed = isConcurrent({ => let _ = sender.getOption(SocketOptionName.Broadcast, context: context()) })
            if (!observed) { sleep(Duration.millisecond) }
        }
        require(observed, "native send did not retain exclusive control exclusion")
        require(isConcurrent({ => sender.configure([SocketOption.Broadcast(true)], context: context()) }),
            "configure overlapped native send")
        require(sending.get(5 * Duration.second) == 1, "delayed send did not complete")
        require(peer.receive(1, context: context()).payload == [73u8], "control rejection damaged active send")
        match (sender.getOption(SocketOptionName.Broadcast, context: context())) {
            case SocketOption.Broadcast(value) => require(!value, "rejected control mutated the socket")
            case _ => throw Exception("broadcast query returned the wrong kind")
        }
    } finally { sender.close(); peer.close() }
    announce("M9_002_SEND_CONTROL_PASS")
}

main(args: Array<String>): Int64 {
    if (args.size != 1) { throw IllegalArgumentException("expected one consumer mode") }
    match (args[0]) {
        case "options" => runOptions()
        case "http" => runHttp()
        case "invalid" => runInvalidAdmission()
        case "send-control" => runSendControl()
        case _ => throw IllegalArgumentException("unknown consumer mode")
    }
    0
}
