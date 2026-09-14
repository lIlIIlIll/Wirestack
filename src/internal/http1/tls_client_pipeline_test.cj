package wirestack.internal.http1

import std.sync.*
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

    @TestCase
    func zeroLengthConnectionCloseDoesNotWaitForTlsPeerShutdown(): Unit {
        let host = HostName("example.com")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])], host, ResolverSource.Static))
        let transports = WithholdingTlsShutdownTransportFactory()
        let handshaker = PassthroughHttp1TlsHandshaker()
        let client = Http1HttpsClient(resolver, transports, handshaker, attemptDelay: Duration.Zero)
        let cancellation = CancellationSource()
        let pending: Future<Int64> = spawn {
            client.execute(
                HttpRequest.get("https://example.com/zero"),
                context: OperationContext(cancellation: cancellation.token)
            ).status
        }

        try {
            transports.waitUntilCleanupStarted()
            cancellation.cancel()
            @Expect(pending.get(Duration.second), 200)
            @Expect(client.snapshot().connections, 0)
            @Expect(client.snapshot().idleConnections, 0)
            @Expect(transports.waitForPeerTermination())
        } finally {
            transports.releaseGracefulShutdown()
            transports.abortPeer()
            try { let _ = pending.get(Duration.second) } catch (_: Exception) {}
            client.close()
        }
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

private class WithholdingTlsShutdownTransportFactory <: TransportFactory {
    private let client: WithholdingTlsShutdownTransport
    private let server: DuplexTransport
    private let serving: Future<Bool>

    init() {
        let (rawClient, rawServer) = MemoryTransport.pair(capacity: 4096, maxChunk: 4)
        client = WithholdingTlsShutdownTransport(rawClient)
        server = rawServer
        serving = spawn { serveWithholdingTlsShutdownPeer(rawServer) }
    }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        client
    }

    func waitUntilCleanupStarted(): Unit { client.waitUntilCleanupStarted() }
    func releaseGracefulShutdown(): Unit { client.releaseGracefulShutdown() }
    func waitForPeerTermination(): Bool { serving.get(Duration.second) }
    func abortPeer(): Unit { server.abort(reason: Some(AbortReason.ApplicationAbort)) }
}

private class WithholdingTlsShutdownTransport <: DuplexTransport {
    private let delegate: DuplexTransport
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var cleanupStarted = false
    private var gracefulReleased = false
    private var terminal = false

    init(delegate: DuplexTransport) { this.delegate = delegate }

    public prop info: TransportInfo { get() { delegate.info } }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        delegate.readSome(destination, context: context)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        delegate.writeSome(source, context: context)
    }

    public func shutdown(direction: ShutdownDirection): Unit { delegate.shutdown(direction) }

    public func close(context: OperationContext): Unit {
        let shouldClose = synchronized(mutex) {
            if (terminal) {
                false
            } else {
                cleanupStarted = true
                changed.notifyAll()
                while (!gracefulReleased && !terminal) { changed.wait() }
                if (terminal) { false } else { terminal = true; true }
            }
        }
        if (shouldClose) { delegate.close(context) }
    }

    public func close(): Unit { close(OperationContext.background()) }

    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let shouldAbort = synchronized(mutex) {
            cleanupStarted = true
            gracefulReleased = true
            changed.notifyAll()
            if (terminal) { false } else { terminal = true; true }
        }
        if (shouldAbort) { delegate.abort(reason: reason) }
    }

    public func isClosed(): Bool { synchronized(mutex) { terminal } }

    func waitUntilCleanupStarted(): Unit {
        synchronized(mutex) {
            let deadline = Deadline.after(Duration.second)
            while (!cleanupStarted) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for HTTPS response cleanup")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func releaseGracefulShutdown(): Unit {
        synchronized(mutex) {
            gracefulReleased = true
            changed.notifyAll()
        }
    }
}

private func serveWithholdingTlsShutdownPeer(transport: DuplexTransport): Bool {
    let request = readWithholdingTlsRequest(transport)
    writeAll(transport, ByteSpan(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toArray()
    ))
    try {
        let _ = transport.readSome(
            MutableByteSpan(Array<Byte>(1, repeat: 0)),
            context: OperationContext.background()
        )
    } catch (_: Exception) {}
    request.target == "/zero"
}

private func readWithholdingTlsRequest(transport: DuplexTransport): Http1RequestHead {
    let parser = Http1RequestHeadParser()
    while (true) {
        let buffer = Array<Byte>(32, repeat: 0)
        match (transport.readSome(
            MutableByteSpan(buffer), context: OperationContext.background()
        )) {
            case ReadResult.Data(count) =>
                let input = Array<Byte>(count, repeat: 0)
                for (index in 0..count) { input[index] = buffer[index] }
                if (let Some(parsed) <- parser.feed(input)) { return parsed.head }
            case ReadResult.EndOfStream => throw Exception("HTTPS client ended before request head")
        }
    }
    throw Exception("unreachable HTTPS request reader loop")
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
