package wirestack.internal.http1

import std.sync.AtomicInt64
import wirestack as api
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class Http1CleartextClientTest {
    @TestCase
    func observedAttemptsReusePhysicalIdentityAndCompleteEachBodyOnce(): Unit {
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8])],
            HostName("example.test"), ResolverSource.Static))
        let transports = PipelineTestTransportFactory()
        let client = Http1CleartextClient(resolver, transports, attemptDelay: Duration.Zero)
        let sink = api.NetworkEventBuffer(capacity: 256)
        let firstContext = OperationContext(eventSink: Some(sink), requestId: Some(101), attemptId: Some(201))
        let first = client.execute(HttpRequest.get("http://example.test/one"), context: firstContext)
        @Expect(client.observationSnapshot().leasedConnections, 1)
        let initial = sink.drain()
        var physical = None<Int64>
        var starts: Int64 = 0
        for (event in initial) {
            @Expect(event.requestId, Some(101))
            @Expect(event.attemptId, Some(201))
            @Expect(event.occurredAt.isSome())
            match (event.kind) {
                case NetworkEventKind.DnsStarted | NetworkEventKind.ConnectAttemptStarted |
                    NetworkEventKind.TcpConnected | NetworkEventKind.HttpConnectionAcquired | NetworkEventKind.BodyStarted =>
                    @Expect(event.connectionId.isSome())
                    if (physical.isNone()) { physical = event.connectionId }
                    @Expect(event.connectionId, physical)
                case NetworkEventKind.BodyCompleted => @Fail("body completed before consumption")
                case _ => ()
            }
            match (event.kind) { case NetworkEventKind.BodyStarted => starts++; case _ => () }
        }
        @Expect(starts, 1)
        @Expect(readPipelineBody(first.body), "one")
        var completions: Int64 = 0
        for (event in sink.drain()) {
            match (event.kind) { case NetworkEventKind.BodyCompleted => completions++; case _ => () }
        }
        @Expect(completions, 1)
        @Expect(client.observationSnapshot().idleConnections, 1)
        let second = client.execute(HttpRequest.get("http://example.test/two"),
            context: OperationContext(eventSink: Some(sink), requestId: Some(101), attemptId: Some(202)))
        let reused = sink.drain()
        var skipped: Int64 = 0
        for (event in reused) {
            @Expect(event.attemptId, Some(202))
            match (event.kind) {
                case NetworkEventKind.DnsCompleted =>
                    match (event.outcome) { case NetworkEventOutcome.NotExecuted => skipped++; case _ => @Fail("reused DNS ran") }
                    @Expect(event.connectionId, physical)
                case NetworkEventKind.DnsStarted | NetworkEventKind.ConnectAttemptStarted => @Fail("reused connection was dialed")
                case NetworkEventKind.BodyStarted | NetworkEventKind.HttpConnectionAcquired => @Expect(event.connectionId, physical)
                case _ => ()
            }
        }
        @Expect(skipped, 1)
        @Expect(readPipelineBody(second.body), "two")
        @Expect(transports.connectCount, 1)
        client.close()
        @Expect(client.observationSnapshot().leasedConnections, 0)
        @Expect(client.observationSnapshot().idleConnections, 0)
    }

    @TestCase
    func resolvesConnectsAndReusesOnlyAfterBodyCompletion(): Unit {
        let host = HostName("example.com")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])],
            host,
            ResolverSource.Static
        ))
        let transports = PipelineTestTransportFactory()
        let client = Http1CleartextClient(resolver, transports, attemptDelay: Duration.Zero)

        let first = client.execute(HttpRequest.get("http://example.com/one"))
        @Expect(client.snapshot().idleConnections, 0)
        @Expect(readPipelineBody(first.body), "one")
        @Expect(client.snapshot().idleConnections, 1)

        let secondRequest = HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://example.com/two"),
            headers: HttpHeaders.builder().add("Connection", "close").build())
        let second = client.execute(secondRequest)
        @Expect(readPipelineBody(second.body), "two")
        @Expect(transports.connectCount, 1)
        @Expect(client.snapshot().connections, 0)
        client.close()
    }

    @TestCase
    func rejectsHttpsBeforeDnsOrPoolMutation(): Unit {
        let host = HostName("example.com")
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])], host, ResolverSource.Static))
        let transports = PipelineTestTransportFactory()
        let client = Http1CleartextClient(resolver, transports)
        var rejected = false
        try { let _ = client.execute(HttpRequest.get("https://example.com/")) }
        catch (_: IllegalArgumentException) { rejected = true }
        @Expect(rejected)
        @Expect(transports.connectCount, 0)
        @Expect(client.snapshot().connections, 0)
        client.close()
    }
}

private class PipelineTestTransportFactory <: TransportFactory {
    private let connects = AtomicInt64(0)
    prop connectCount: Int64 { get() { connects.load() } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        let _ = context
        connects.fetchAdd(1)
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 4)
        spawn {
            let _ = serveHttp1Connection(server, PipelineEchoHandler(), maximumRequests: 2)
        }
        client
    }
}

private class PipelineEchoHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let payload = if (request.head.target == "/one") { "one" } else { "two" }
        // Empty request framing is complete once the handler observes EOF.
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        Http1ServerResponse(HttpResponse(200, "OK",
            ResponseBody(RequestBody.string(payload).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${payload.toArray().size}").build()))
    }
}

private func readPipelineBody(body: ResponseBody): String {
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
