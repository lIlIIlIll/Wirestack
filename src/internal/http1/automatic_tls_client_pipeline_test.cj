package wirestack.internal.http1

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.http2.*
import wirestack.internal.http_model.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class HttpAutomaticHttpsClientTest {
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

        let first = client.execute(HttpRequest.get("https://example.com/one"))
        @Expect(readAutomaticBody(first.body), "/one")
        first.close()
        let second = client.execute(HttpRequest.get("https://example.com/two"))
        @Expect(readAutomaticBody(second.body), "/two")
        second.close()

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
    private let handshakes = AtomicInt64(0)
    private var closed = false

    init(selected: HttpNegotiatedProtocol) { this.selected = selected }

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
        let _ = handshakes.fetchAdd(1)
        HttpNegotiatedTlsTransport(selected, transport)
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class AutomaticPipelineTransportFactory <: TransportFactory {
    private let protocol: HttpNegotiatedProtocol
    private let expectedRequests: Int64
    private let connects = AtomicInt64(0)

    init(protocol: HttpNegotiatedProtocol, expectedRequests: Int64) {
        this.protocol = protocol
        this.expectedRequests = expectedRequests
    }

    prop connectCount: Int64 { get() { connects.load() } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        let _ = connects.fetchAdd(1)
        let (client, server) = MemoryTransport.pair(capacity: 1024 * 1024, maxChunk: 29)
        match (protocol) {
            case HttpNegotiatedProtocol.Http2 =>
                spawn { let _ = AutomaticTestHttp2Peer(server).serveOutOfOrder(expectedRequests) }
            case HttpNegotiatedProtocol.Http11 =>
                spawn {
                    let _ = serveHttp1Connection(
                        server, AutomaticHttp1Handler(), maximumRequests: expectedRequests
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
