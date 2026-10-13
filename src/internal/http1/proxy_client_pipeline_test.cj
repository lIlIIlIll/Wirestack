package wirestack.internal.http1

import std.sync.AtomicInt64
import std.unittest.*
import wirestack as api
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*
import wirestack.ReferenceIdentity

@Test
class Http1ProxyClientPipelineTest {
    @TestCase
    func directProxyAddressHasNoDnsSpanAndOneCorrelatedConnectExchange(): Unit {
        let host = HostName("proxy.test")
        let resolver = StaticResolver(ResolveResult([IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8])], host, ResolverSource.Static))
        let factory = ConnectPipelineTransportFactory(SuccessfulConnectHandler())
        let sink = api.NetworkEventBuffer(capacity: 256)
        let client = Http1HttpsProxyClient(Http1ProxyEndpoint.address(
            IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8]), 3128, "proxy.test:3128"),
            resolver, factory, ProxyPassthroughHandshaker())
        let response = client.execute(HttpRequest.get("https://origin.test/one"), proxyAuthorization: Some("Basic first"),
            context: OperationContext(eventSink: Some(sink), requestId: Some(701), attemptId: Some(702)))
        @Expect(readProxyPipelineBody(response.body), "tunnel-one")
        response.close()
        var physical = None<Int64>
        var skipped: Int64 = 0
        var proxyStarts: Int64 = 0
        var proxyEnds: Int64 = 0
        for (event in sink.drain()) {
            @Expect(event.requestId, Some(701)); @Expect(event.attemptId, Some(702))
            match (event.kind) {
                case NetworkEventKind.DnsStarted => @Fail("typed proxy address started DNS")
                case NetworkEventKind.DnsCompleted =>
                    match (event.outcome) { case NetworkEventOutcome.NotExecuted => skipped++; case _ => @Fail("typed proxy DNS was executed") }
                case NetworkEventKind.ConnectAttemptStarted =>
                    physical = event.connectionId; @Expect(physical.isSome()); @Expect(event.connectionAttemptIndex, Some(1))
                case NetworkEventKind.ProxyTunnelEstablished | NetworkEventKind.HttpConnectionAcquired | NetworkEventKind.BodyCompleted =>
                    @Expect(event.connectionId, physical)
                case NetworkEventKind.StageStarted =>
                    match (event.stage) { case Some(OperationTimeoutStage.ProxyConnect) => proxyStarts++; case _ => () }
                case NetworkEventKind.StageCompleted =>
                    match (event.stage) { case Some(OperationTimeoutStage.ProxyConnect) => proxyEnds++; case _ => () }
                case _ => ()
            }
        }
        @Expect(skipped, 1); @Expect(proxyStarts, 1); @Expect(proxyEnds, 1)
        @Expect(client.observationSnapshot().idleConnections, 0)
        @Expect(client.observationSnapshot().leasedConnections, 0)
        @Expect(client.observationSnapshot().connectingConnections, 0)
        client.close()
        @Expect(client.observationSnapshot().idleConnections, 0)
    }

    @TestCase
    func dynamicConnectCredentialsNeverReuseAnAuthenticatedTunnel(): Unit {
        let proxyHost = HostName("proxy.test")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])],
            proxyHost, ResolverSource.Static
        ))
        let connectHandler = SuccessfulConnectHandler()
        let transports = ConnectPipelineTransportFactory(connectHandler)
        let handshaker = ProxyPassthroughHandshaker()
        let endpoint = Http1ProxyEndpoint.hostname(proxyHost, 3128, "proxy.test:3128")
        let client = Http1HttpsProxyClient(
            endpoint, resolver, transports, handshaker, attemptDelay: Duration.Zero
        )

        let first = client.execute(
            HttpRequest.get("https://origin.test/one"), proxyAuthorization: Some("Basic first")
        )
        @Expect(readProxyPipelineBody(first.body), "tunnel-one")
        let second = client.execute(
            HttpRequest.get("https://origin.test/two"), proxyAuthorization: Some("Basic rotated")
        )
        @Expect(readProxyPipelineBody(second.body), "tunnel-two")

        @Expect(transports.connectCount, 2)
        @Expect(connectHandler.calls.load(), 2)
        @Expect(connectHandler.valid.load(), 1)
        @Expect(handshaker.handshakeCount, 2)
        @Expect(handshaker.originWasUsed.load(), 1)
        client.close()
        @Expect(handshaker.isClosed())
    }

    @TestCase
    func rejectedConnectDrainsClosesAndReturnsStructuredNonRetryableFailure(): Unit {
        let proxyHost = HostName("proxy.test")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])],
            proxyHost, ResolverSource.Static
        ))
        let transports = RejectingConnectTransportFactory()
        let handshaker = ProxyPassthroughHandshaker()
        let client = Http1HttpsProxyClient(
            Http1ProxyEndpoint.hostname(proxyHost, 3128, "proxy.test:3128"),
            resolver,
            transports,
            handshaker,
            attemptDelay: Duration.Zero
        )
        var rejected = false
        try {
            let _ = client.execute(HttpRequest.get("https://origin.test/"))
        } catch (error: Http1ProxyConnectException) {
            rejected = error.status == 407 && error.reason == "Proxy Authentication Required" &&
                isProxyConnectPhase(error.phase) && isNeverRetryable(error.retryability) &&
                !error.message.contains("secret")
        } finally {
            client.close()
        }
        @Expect(rejected)
        @Expect(transports.connectCount, 1)
        @Expect(handshaker.handshakeCount, 0)
    }
}

private func isProxyConnectPhase(value: NetworkPhase): Bool {
    match (value) { case NetworkPhase.ProxyConnect => true; case _ => false }
}

private func isNeverRetryable(value: Retryability): Bool {
    match (value) { case Retryability.Never => true; case _ => false }
}

private class ProxyPassthroughHandshaker <: Http1TlsHandshaker {
    private let handshakes = AtomicInt64(0)
    let originWasUsed = AtomicInt64(0)
    private var closed = false
    prop handshakeCount: Int64 { get() { handshakes.load() } }
    public prop tlsContextIdentity: String { get() { "proxy-test-tls" } }
    public prop trustContextIdentity: String { get() { "proxy-test-trust" } }
    public prop clientIdentity: String { get() { "none" } }
    public prop providerIdentity: String { get() { "proxy-test-provider" } }
    public prop alpnPolicy: String { get() { "http/1.1" } }
    public func handshake(reference: ReferenceIdentity, transport: DuplexTransport,
        context: OperationContext): DuplexTransport {
        let _ = context
        handshakes.fetchAdd(1)
        match (reference) {
            case ReferenceIdentity.Dns(host) => if (host.ascii == "origin.test") { originWasUsed.store(1) }
            case ReferenceIdentity.Ip(_) => ()
        }
        transport
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class ConnectPipelineTransportFactory <: TransportFactory {
    private let connects = AtomicInt64(0)
    private let connectHandler: SuccessfulConnectHandler
    prop connectCount: Int64 { get() { connects.load() } }

    init(connectHandler: SuccessfulConnectHandler) { this.connectHandler = connectHandler }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        connects.fetchAdd(1)
        let (client, server) = MemoryTransport.pair(capacity: 8192, maxChunk: 3)
        spawn {
            let connected = serveHttp1Connection(server, connectHandler, maximumRequests: 1)
            let tunnel = connected.tunnelTransport.getOrThrow()
            let _ = serveHttp1Connection(tunnel, TunnelOriginHandler(), maximumRequests: 2)
        }
        client
    }
}

private class SuccessfulConnectHandler <: Http1ServerHandler {
    let calls = AtomicInt64(0)
    let valid = AtomicInt64(0)

    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        calls.fetchAdd(1)
        if (request.head.method == HttpMethod("CONNECT") &&
            request.head.target == "origin.test:443" &&
            request.head.headers.getFirst("host") == Some("origin.test:443") &&
            request.head.headers.getFirst("proxy-authorization") == Some("Basic first")) {
            valid.store(1)
        }
        Http1ServerResponse(HttpResponse(200, "Connection Established", ResponseBody.empty()))
    }
}

private class TunnelOriginHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        let value = if (request.head.target == "/one") { "tunnel-one" } else { "tunnel-two" }
        Http1ServerResponse(HttpResponse(
            200, "OK", ResponseBody(RequestBody.string(value).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${value.toArray().size}").build()
        ))
    }
}

private class RejectingConnectTransportFactory <: TransportFactory {
    private let connects = AtomicInt64(0)
    prop connectCount: Int64 { get() { connects.load() } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        connects.fetchAdd(1)
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 2)
        spawn { let _ = serveHttp1Connection(server, RejectingConnectHandler(), maximumRequests: 1) }
        client
    }
}

private class RejectingConnectHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        Http1ServerResponse(HttpResponse(
            407,
            "Proxy Authentication Required",
            ResponseBody(RequestBody.string("secret proxy body").open()),
            headers: HttpHeaders.builder().add("Content-Length", "17").build()
        ))
    }
}

private func readProxyPipelineBody(body: ResponseBody): String {
    let expected = body.contentLength.getOrThrow()
    let bytes = Array<Byte>(expected, repeat: 0)
    var offset: Int64 = 0
    while (offset < expected) {
        let buffer = Array<Byte>(expected - offset, repeat: 0)
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { bytes[offset + index] = buffer[index] }
        offset += count
    }
    body.close()
    String.fromUtf8(bytes)
}
