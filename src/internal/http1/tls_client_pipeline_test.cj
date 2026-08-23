package wirestack.internal.http1

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class Http1HttpsClientTest {
    @TestCase
    func partitionsHandshakesAndReusesHttpsAfterBodyCompletion(): Unit {
        let host = HostName("example.com")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])], host, ResolverSource.Static))
        let transports = HttpsPipelineTransportFactory()
        let handshaker = PassthroughHttp1TlsHandshaker()
        let client = Http1HttpsClient(resolver, transports, handshaker, attemptDelay: Duration.Zero)

        let first = client.execute(HttpRequest.get("https://example.com/one"))
        @Expect(readHttpsPipelineBody(first.body), "secure-one")
        @Expect(client.snapshot().idleConnections, 1)
        let secondRequest = HttpRequest(HttpMethod("GET"), HttpUrl.parse("https://example.com/two"),
            headers: HttpHeaders.builder().add("Connection", "close").build())
        let second = client.execute(secondRequest)
        @Expect(readHttpsPipelineBody(second.body), "secure-two")
        @Expect(transports.connectCount, 1)
        @Expect(handshaker.handshakeCount, 1)
        client.close()
        @Expect(handshaker.isClosed())
    }
}

private class PassthroughHttp1TlsHandshaker <: Http1TlsHandshaker {
    private let handshakes = AtomicInt64(0)
    private var closed = false
    prop handshakeCount: Int64 { get() { handshakes.load() } }
    public prop tlsContextIdentity: String { get() { "test-tls-context" } }
    public prop trustContextIdentity: String { get() { "test-trust" } }
    public prop clientIdentity: String { get() { "none" } }
    public prop providerIdentity: String { get() { "test-provider" } }
    public prop alpnPolicy: String { get() { "http/1.1" } }
    public func handshake(host: HostName, transport: DuplexTransport,
        context: OperationContext): DuplexTransport {
        let _ = host
        let _ = context
        handshakes.fetchAdd(1)
        transport
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class HttpsPipelineTransportFactory <: TransportFactory {
    private let connects = AtomicInt64(0)
    prop connectCount: Int64 { get() { connects.load() } }
    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        connects.fetchAdd(1)
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 4)
        spawn { let _ = serveHttp1Connection(server, HttpsPipelineHandler(), maximumRequests: 2) }
        client
    }
}

private class HttpsPipelineHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        let value = if (request.head.target == "/one") { "secure-one" } else { "secure-two" }
        Http1ServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string(value).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${value.toArray().size}").build()))
    }
}

private func readHttpsPipelineBody(body: ResponseBody): String {
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
