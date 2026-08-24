package wirestack.internal.http1

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class Http1ProxyClientPipelineTest {
    @TestCase
    func connectAuthenticatesProxyThenHandshakesTheOriginAndReusesTunnel(): Unit {
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

        @Expect(transports.connectCount, 1)
        @Expect(connectHandler.calls.load(), 1)
        @Expect(connectHandler.valid.load(), 1)
        @Expect(handshaker.handshakeCount, 1)
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
    public func handshake(host: HostName, transport: DuplexTransport,
        context: OperationContext): DuplexTransport {
        let _ = context
        handshakes.fetchAdd(1)
        if (host.ascii == "origin.test") { originWasUsed.store(1) }
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
