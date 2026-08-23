package wirestack.internal.http1

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class Http1CleartextClientTest {
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
    let buffer = Array<Byte>(16, repeat: 0)
    let count = body.read(buffer)
    body.close()
    let bytes = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { bytes[index] = buffer[index] }
    String.fromUtf8(bytes)
}
