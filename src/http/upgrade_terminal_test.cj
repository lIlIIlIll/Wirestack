package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class HttpUpgradeTerminalOrderingTest {
    @TestCase
    func cancellationWinningBeforeTheWrapYieldsExactlyOneFailedCompletion(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        let handler = UpgradeRejectionHandler()
        let server = HttpServer.builder()
            .listen(SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16))
            .handler(handler)
            .tls(serverTls)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let clientTls = HttpClientTlsConfig([certificate])
        let source = api.CancellationSource()
        let sink = UpgradeTerminalSink(source)
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], HostName("example.com"), ResolverSource.Static)))
            .tls(clientTls)
            .http2Push(Http2PushConfig(SameOriginHttp2PushPolicy()))
            .requestTimeout(5 * Duration.second)
            .build()
        try {
            let url = HttpUrl.parse("https://example.com:${server.localEndpoint.port}/")
            var raised = false
            try {
                let _ = client.upgrade(HttpRequest(HttpMethod("CONNECT"), url),
                    context: OperationContext(cancellation: source.token,
                        eventSink: Some<NetworkEventSink>(sink)))
            } catch (error: api.NetworkException) {
                match (error.code) {
                    case api.NetworkErrorCode.Cancelled => raised = true
                    case _ => ()
                }
            }
            @Expect(raised)
            // The cancellation was requested after the response was published (AttemptCompleted
            // Succeeded) and before it could be wrapped, so the only terminal event is the failure.
            @Expect(sink.attemptsCancelled(), 1)
            var succeeded: Int64 = 0
            var failed: Int64 = 0
            for (event in sink.snapshot()) {
                match (event.kind) {
                    case NetworkEventKind.RequestCompleted =>
                        match (event.outcome) {
                            case NetworkEventOutcome.Succeeded => succeeded++
                            case NetworkEventOutcome.Failed => failed++
                            case _ => ()
                        }
                    case _ => ()
                }
            }
            @Expect(succeeded, 0)
            @Expect(failed, 1)
            @Expect(client.resourceSnapshot().activeRequests, 0)
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
            serverTls.close()
            clientTls.close()
        }
    }
}

/** Rejects the duplex handshake with an ordinary HTTP status and body ownership. */
private class UpgradeRejectionHandler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        request.body.close()
        return HttpServerResponse(HttpResponse(
            403,
            "Forbidden",
            ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}

/** Cancels the operation at the one point between response publication and the wrap. */
private class UpgradeTerminalSink <: NetworkEventSink {
    private let source: api.CancellationSource
    private let mutex = Mutex()
    private let rows = ArrayList<NetworkEvent>()
    private var cancelled = 0

    init(source: api.CancellationSource) {
        this.source = source
    }

    public func emit(event: NetworkEvent): Unit {
        synchronized(mutex) {
            if (rows.size < 128) { rows.add(event) }
            let completed = match (event.kind) {
                case NetworkEventKind.AttemptCompleted => match (event.outcome) {
                    case NetworkEventOutcome.Succeeded => true
                    case _ => false
                }
                case _ => false
            }
            if (completed && cancelled == 0) {
                cancelled++
                source.cancel()
            }
        }
    }

    func snapshot(): Array<NetworkEvent> { synchronized(mutex) { rows.toArray() } }
    func attemptsCancelled(): Int64 { synchronized(mutex) { cancelled } }
}
