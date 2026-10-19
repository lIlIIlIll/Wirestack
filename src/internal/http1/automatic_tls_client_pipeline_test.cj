package wirestack.internal.http1

import std.collection.*
import wirestack as api
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal as internal
import wirestack.internal.http2.*
import wirestack.internal.http_model.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class HttpAutomaticHttpsClientTest {
    @TestCase
    func cachedHttp11AlpnPathCanUpgradeToHttp2WithSharedResourceBudget(): Unit {
        let resolver = automaticResolver()
        let transports = AutomaticPipelineTransportFactory(
            HttpNegotiatedProtocol.Http11, 1, HttpNegotiatedProtocol.Http2, 1
        )
        let handshaker = PassthroughAlpnHandshaker(
            HttpNegotiatedProtocol.Http11, HttpNegotiatedProtocol.Http2
        )
        let budget = internal.HttpResourceBudget(internal.HttpResourceBudgetPolicy(
            2, 2, 2, 2, 2, 2, 2, 2, 2, 4194304u64, 65536u64, 4
        ))
        let client = HttpAutomaticHttpsClient(
            resolver, transports, handshaker, attemptDelay: Duration.Zero, resourceBudget: Some(budget)
        )

        let first = client.execute(HttpRequest.get("https://example.com/one"))
        let second = client.execute(HttpRequest.get("https://example.com/two"))
        @Expect(readAutomaticBody(first.body), "/one")
        @Expect(readAutomaticBody(second.body), "/two")
        first.close()
        second.close()

        @Expect(transports.connectCount, 2)
        @Expect(handshaker.handshakeCount, 2)
        @Expect(client.h2Snapshot().connections, 1)
        let snapshot = budget.snapshot()
        @Expect(snapshot.activeConnections, 2)
        @Expect(snapshot.activeRequests, 0)
        @Expect(snapshot.activeStreams, 0)
        @Expect(snapshot.owners.size, 1)
        @Expect(snapshot.owners[0].origin, "https://example.com:443")
        @Expect(snapshot.owners[0].route, "direct")
        @Expect(snapshot.owners[0].connections, 2)
        @Expect(snapshot.owners[0].requests, 0)
        @Expect(snapshot.owners[0].streams, 0)
        client.close()
        @Expect(budget.snapshot().activeConnections, 0)
        @Expect(budget.snapshot().owners.size, 0)
    }
    @TestCase
    func cachedHttp11AlpnPathCanUpgradeToHttp2WithoutResourceBudget(): Unit {
        let resolver = automaticResolver()
        let transports = AutomaticPipelineTransportFactory(
            HttpNegotiatedProtocol.Http11, 1, HttpNegotiatedProtocol.Http2, 1
        )
        let handshaker = PassthroughAlpnHandshaker(
            HttpNegotiatedProtocol.Http11, HttpNegotiatedProtocol.Http2
        )
        let client = HttpAutomaticHttpsClient(
            resolver, transports, handshaker, attemptDelay: Duration.Zero
        )

        let first = client.execute(HttpRequest.get("https://example.com/one"))
        let second = client.execute(HttpRequest.get("https://example.com/two"))
        @Expect(readAutomaticBody(first.body), "/one")
        @Expect(readAutomaticBody(second.body), "/two")
        first.close()
        second.close()

        @Expect(transports.connectCount, 2)
        @Expect(handshaker.handshakeCount, 2)
        @Expect(client.h2Snapshot().connections, 1)
        client.close()
    }

    @TestCase
    func h2NegotiationMultiplexesTenRequestsOnOneTlsConnection(): Unit {
        let resolver = automaticResolver()
        let transports = AutomaticPipelineTransportFactory(HttpNegotiatedProtocol.Http2, 10)
        let handshaker = PassthroughAlpnHandshaker(HttpNegotiatedProtocol.Http2)
        let client = HttpAutomaticHttpsClient(
            resolver, transports, handshaker, attemptDelay: Duration.Zero
        )

        let requests = ArrayList<Future<String>>()
        for (index in 0..10) {
            let captured = index
            requests.add(spawn {
                let response = client.execute(HttpRequest.get("https://example.com/${captured}"))
                try { readAutomaticBody(response.body) } finally { response.close() }
            })
        }
        for (index in 0..10) {
            @Expect(requests[index].get(Duration.second * 5), "/${index}")
        }

        @Expect(transports.connectCount, 1)
        @Expect(handshaker.handshakeCount, 1)
        @Expect(client.h2Snapshot().connections, 1)
        @Expect(client.h2Snapshot().activeStreams, 0)
        @Expect(client.h1Snapshot().connections, 0)
        client.close()
    }

    @TestCase
    func http11NegotiationFallsBackAndReusesTheAdoptedConnection(): Unit {
        let resolver = automaticResolver()
        let transports = AutomaticPipelineTransportFactory(HttpNegotiatedProtocol.Http11, 2)
        let handshaker = PassthroughAlpnHandshaker(HttpNegotiatedProtocol.Http11)
        let client = HttpAutomaticHttpsClient(
            resolver, transports, handshaker, attemptDelay: Duration.Zero
        )

        let sink = api.NetworkEventBuffer(capacity: 256)
        let first = client.execute(HttpRequest.get("https://example.com/one"),
            context: OperationContext(eventSink: Some(sink), requestId: Some(501), attemptId: Some(601)))
        @Expect(readAutomaticBody(first.body), "/one")
        first.close()
        let firstEvents = sink.drain()
        var connectionId = None<Int64>
        for (event in firstEvents) {
            match (event.kind) {
                case NetworkEventKind.DnsStarted => connectionId = event.connectionId
                case NetworkEventKind.HttpConnectionAcquired | NetworkEventKind.BodyStarted | NetworkEventKind.BodyCompleted =>
                    @Expect(event.connectionId, connectionId)
                case _ => ()
            }
        }
        @Expect(connectionId.isSome())
        let second = client.execute(HttpRequest.get("https://example.com/two"),
            context: OperationContext(eventSink: Some(sink), requestId: Some(501), attemptId: Some(602)))
        @Expect(readAutomaticBody(second.body), "/two")
        second.close()
        var skipped: Int64 = 0
        for (event in sink.drain()) {
            @Expect(event.attemptId, Some(602))
            match (event.kind) {
                case NetworkEventKind.DnsCompleted | NetworkEventKind.TlsHandshakeCompleted =>
                    @Expect(event.connectionId, connectionId)
                    match (event.outcome) { case NetworkEventOutcome.NotExecuted => skipped++; case _ => @Fail("reused security stage executed") }
                case NetworkEventKind.HttpConnectionAcquired | NetworkEventKind.BodyStarted | NetworkEventKind.BodyCompleted =>
                    @Expect(event.connectionId, connectionId)
                case _ => ()
            }
        }
        @Expect(skipped, 2)
        @Expect(client.observationSnapshot().idleConnections, 1)

        @Expect(transports.connectCount, 1)
        @Expect(handshaker.handshakeCount, 1)
        @Expect(client.h1Snapshot().connections, 1)
        @Expect(client.h1Snapshot().idleConnections, 1)
        @Expect(client.h2Snapshot().connections, 0)
        client.close()
    }

}

private class PassthroughAlpnHandshaker <: HttpAlpnTlsHandshaker {
    private let selected: HttpNegotiatedProtocol
    private let nextSelected: ?HttpNegotiatedProtocol
    private let handshakes = AtomicInt64(0)
    private var closed = false

    init(selected: HttpNegotiatedProtocol) {
        this.selected = selected
        this.nextSelected = None<HttpNegotiatedProtocol>
    }

    init(first: HttpNegotiatedProtocol, second: HttpNegotiatedProtocol) {
        this.selected = first
        this.nextSelected = Some(second)
    }

    prop handshakeCount: Int64 { get() { handshakes.load() } }
    public prop tlsContextIdentity: String { get() { "automatic-test-tls" } }
    public prop trustContextIdentity: String { get() { "automatic-test-trust" } }
    public prop clientIdentity: String { get() { "none" } }
    public prop providerIdentity: String { get() { "automatic-test-provider" } }
    public prop alpnPolicy: String { get() { "h2,http/1.1" } }

    public func handshakeNegotiated(
        host: HostName,
        transport: DuplexTransport,
        context: OperationContext
    ): HttpNegotiatedTlsTransport {
        let _ = host
        let _ = context
        let handshakeIndex = handshakes.fetchAdd(1)
        let negotiatedProtocol = if (handshakeIndex == 0) {
            selected
        } else {
            match (nextSelected) {
                case Some(protocol) => protocol
                case None => selected
            }
        }
        HttpNegotiatedTlsTransport(negotiatedProtocol, transport)
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class AutomaticPipelineTransportFactory <: TransportFactory {
    private let protocol: HttpNegotiatedProtocol
    private let expectedRequests: Int64
    private let nextProtocol: ?HttpNegotiatedProtocol
    private let nextExpectedRequests: Int64
    private let connects = AtomicInt64(0)

    init(protocol: HttpNegotiatedProtocol, expectedRequests: Int64) {
        this.protocol = protocol
        this.expectedRequests = expectedRequests
        this.nextProtocol = None<HttpNegotiatedProtocol>
        this.nextExpectedRequests = 0
    }

    init(
        first: HttpNegotiatedProtocol,
        firstExpectedRequests: Int64,
        second: HttpNegotiatedProtocol,
        secondExpectedRequests: Int64
    ) {
        this.protocol = first
        this.expectedRequests = firstExpectedRequests
        this.nextProtocol = Some(second)
        this.nextExpectedRequests = secondExpectedRequests
    }

    prop connectCount: Int64 { get() { connects.load() } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        let connectIndex = connects.fetchAdd(1)
        let selectedProtocol = if (connectIndex == 0) {
            protocol
        } else {
            match (nextProtocol) {
                case Some(value) => value
                case None => protocol
            }
        }
        let requestLimit = if (connectIndex == 0 || nextProtocol.isNone()) {
            expectedRequests
        } else {
            nextExpectedRequests
        }
        let (client, server) = MemoryTransport.pair(capacity: 1024 * 1024, maxChunk: 29)
        match (selectedProtocol) {
            case HttpNegotiatedProtocol.Http2 =>
                spawn { let _ = AutomaticTestHttp2Peer(server).serveOutOfOrder(requestLimit) }
            case HttpNegotiatedProtocol.Http11 =>
                spawn {
                    let _ = serveHttp1Connection(
                        server, AutomaticHttp1Handler(), maximumRequests: requestLimit
                    )
                }
        }
        client
    }
}

private class AutomaticHttp1Handler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        let value = request.head.target
        Http1ServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody(RequestBody.string(value).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${value.toArray().size}").build()
        ))
    }
}

private class AutomaticTestHttp2Peer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()
    private let encoder = HpackEncoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serveOutOfOrder(expected: Int64): Int64 {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start(settings: [
            Http2Setting(Http2SettingId.MaxConcurrentStreams, UInt32(expected))
        ])))

        let pending = ArrayList<AutomaticTestHttp2Request>()
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        while (pending.size < expected) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("automatic h2 client ended early")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) {
                    pending.add(AutomaticTestHttp2Request(
                        block.streamId, automaticRequestPath(decoder.decode(block.bytes))
                    ))
                }
            }
        }
        var index: Int64 = pending.size - 1
        while (index >= 0) { sendResponse(pending[index]); index -= 1 }
        pending.size
    }

    private func sendResponse(request: AutomaticTestHttp2Request): Unit {
        let body = request.path.toArray()
        let block = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "${body.size}"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(block.size), Http2FrameType.Headers, Http2Flags(raw: 0x04u8), request.streamId
            ),
            block
        ))))
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(body.size), Http2FrameType.Data, Http2Flags(raw: 0x01u8), request.streamId
            ),
            body
        ))))
    }
}

private class AutomaticTestHttp2Request {
    let streamId: Http2StreamId
    let path: String
    init(streamId: Http2StreamId, path: String) { this.streamId = streamId; this.path = path }
}

private func automaticRequestPath(fields: Array<HpackHeaderField>): String {
    for (field in fields) { if (field.name == ":path") { return field.value } }
    throw Exception("automatic h2 request has no :path")
}

private func automaticResolver(): Resolver {
    let host = HostName("example.com")
    StaticResolver(ResolveResult(
        [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])],
        host,
        ResolverSource.Static
    ))
}

private func readAutomaticBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(3, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}
