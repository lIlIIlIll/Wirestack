package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.net.TcpStream

@Test
class HttpFacadeObservabilityTest {
    @TestCase
    func retriesRedirectsAndBodyKeepOneLogicalRequest(): Unit {
        let fixture = HttpObservationFixture()
        let server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16))
            .handler(fixture).serviceHook(fixture).build()
        fixture.server = Some(server)
        let serving = spawn { server.serve() }
        let connector = HttpObservationRetryConnector()
        let client = HttpClient.builder().connector(connector).poolHook(fixture)
            .requestTimeout(5 * Duration.second).retryPolicy(HttpRetryPolicy(maximumAttempts: 2)).build()
        fixture.client = Some(client)
        let events = api.NetworkEventBuffer(capacity: 256)
        let context = OperationContext(eventSink: Some<NetworkEventSink>(events)).withEventCorrelation(
            requestId: Some(177), attemptId: None<Int64>, connectionId: None<Int64>, streamId: None<Int64>)
        try {
            let response = client.get("http://127.0.0.1:${server.localEndpoint.port}/redirect", context: context)
            @Expect(response.status, 200)
            let live = client.observationSnapshot(observations: Some<api.NetworkEventStatistics>(events))
            @Expect(live.resources.activeRequests > 0)
            @Expect(live.pools.leasedConnections, 1)
            @Expect(live.observations.getOrThrow().queuedEvents > 0)
            let beforeBody = events.drain()
            var starts: Int64 = 0
            var completions: Int64 = 0
            let attempts = ArrayList<Int64>()
            var attemptCompletions: Int64 = 0
            for (event in beforeBody) {
                @Expect(event.requestId, Some(177))
                match (event.kind) {
                    case NetworkEventKind.RequestStarted => starts++
                    case NetworkEventKind.RequestCompleted => completions++
                    case NetworkEventKind.AttemptStarted => attempts.add(event.attemptId.getOrThrow())
                    case NetworkEventKind.AttemptCompleted => attemptCompletions++
                    case _ => ()
                }
            }
            @Expect(starts, 1)
            @Expect(completions, 1)
            @Expect(attempts.size, 3)
            @Expect(attemptCompletions, 3)
            @Expect(attempts[0] != attempts[1] && attempts[1] != attempts[2] && attempts[0] != attempts[2])
            let bytes = Array<Byte>(16, repeat: 0u8)
            @Expect(response.body.read(bytes), 7)
            @Expect(response.body.read(bytes), 0)
            response.close()
            @Expect(client.observationSnapshot().resources.activeRequests, 0)
            @Expect(client.observationSnapshot().pools.leasedConnections, 0)
            @Expect(fixture.correlated.load())
            @Expect(fixture.beforeCalls.load(), 2)
            @Expect(fixture.afterCalls.load(), 2)
            @Expect(fixture.poolCalls.load() > 0)
            let tail = events.drain()
            for (event in tail) {
                match (event.kind) {
                    case NetworkEventKind.RequestCompleted => @Fail("body completion duplicated logical completion")
                    case _ => ()
                }
            }
            let failed = client.get("http://127.0.0.1:${server.localEndpoint.port}/delegate-fails")
            @Expect(failed.status, 500)
            failed.close()
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
        }
        @Expect(server.observationSnapshot().resources.activeRequests, 0)
    }

    @TestCase
    func poolHookAloneKeepsRequestAndDistinctRedirectAttempts(): Unit {
        let fixture = HttpObservationFixture()
        let server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(fixture).build()
        fixture.server = Some(server)
        let serving = spawn { server.serve() }
        let client = HttpClient.builder().poolHook(fixture).requestTimeout(5 * Duration.second).build()
        fixture.client = Some(client)
        try {
            let response = client.get("http://127.0.0.1:${server.localEndpoint.port}/redirect")
            try {
                @Expect(response.status, 200)
                let bytes = Array<Byte>(16, repeat: 0u8)
                @Expect(response.body.read(bytes), 7)
                @Expect(response.body.read(bytes), 0)
            } finally { response.close() }
            let acquired = ArrayList<NetworkEvent>()
            for (event in fixture.poolEvents.drain()) {
                match (event.kind) { case NetworkEventKind.HttpConnectionAcquired => acquired.add(event); case _ => () }
            }
            @Expect(acquired.size, 2)
            @Assert(acquired[0].requestId.isSome() && acquired[0].attemptId.isSome())
            @Assert(acquired[1].requestId.isSome() && acquired[1].attemptId.isSome())
            @Expect(acquired[0].requestId, acquired[1].requestId)
            @Expect(acquired[0].attemptId != acquired[1].attemptId)
            @Expect(acquired[0].connectionId, acquired[1].connectionId)
            @Expect(fixture.correlated.load())
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
            server.close()
        }
    }
    @TestCase
    func inputCancellationCountsOnlyActualReclamation(): Unit {
        let client = HttpClient.builder().requestTimeout(Duration.second).build()
        let cancellation = HttpRequestCancellationHandle()
        let _ = cancellation.cancel()
        try {
            @ExpectThrows(client.getControlled("http://127.0.0.1:1/",
                HttpCancellationHandles(request: Some(cancellation))))
            let snapshot = client.observationSnapshot()
            @Expect(snapshot.resources.activeRequests, 0)
            @Expect(snapshot.resources.completedCancellations, 1)
            @Expect(snapshot.resources.lastCancellationCompletionLatency.isSome())
            @Expect(snapshot.resources.lastCancellationCompletionLatency.getOrThrow() >= Duration.Zero)
            @Expect(snapshot.resolvers.size, 1)
            @Expect(snapshot.unavailableResolvers, 0)
        } finally { client.close() }
    }

    @TestCase
    func customResolverUnavailableAndRotationObservationIsReentrant(): Unit {
        let resolver = HttpObservationUnknownResolver()
        let client = HttpClient.builder().resolver(resolver).build()
        let sink = HttpObservationRotationSink(client)
        try {
            let snapshot = client.observationSnapshot()
            @Expect(snapshot.resolvers.size, 0)
            @Expect(snapshot.unavailableResolvers, 1)
            let generation = client.rotateResolver(resolver,
                context: OperationContext(eventSink: Some<NetworkEventSink>(sink)))
            @Expect(generation, 2u64)
            @Expect(sink.rotations.load(), 1)
            @Expect(client.observationSnapshot().configuration.retainedGenerations <= 64)
        } finally { client.close() }
    }
    @TestCase
    func admissionTimeoutAndRetainedCancellationHaveRealCounters(): Unit {
        let fixture = HttpObservationFixture()
        let server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(fixture).build()
        let serving = spawn { server.serve() }
        let client = HttpClient.builder().resourceLimits(HttpResourceLimits(maximumRequests: 1,
            maximumRequestsPerRoute: 1, maximumRequestsPerOrigin: 1))
            .requestTimeout(5 * Duration.second).build()
        let request = HttpRequest.get("http://127.0.0.1:" + server.localEndpoint.port.toString() + "/result")
        let cancellation = HttpRequestCancellationHandle()
        let response = client.sendControlled(request, HttpCancellationHandles(request: Some(cancellation)))
        let events = api.NetworkEventBuffer(capacity: 128)
        try {
            @Expect(client.resourceSnapshot().completedCancellations, 0)
            let error = @AssertThrows[NetworkException](client.send(request,
                context: OperationContext(eventSink: Some<NetworkEventSink>(events),
                    timeoutPolicy: api.OperationTimeoutPolicy(requestAdmission: Some(20 * Duration.millisecond)))))
            @Expect(match (error.code) { case NetworkErrorCode.TimedOut => true; case _ => false })
            var failedStages: Int64 = 0
            var completedRequests: Int64 = 0
            var generatedId: Int64 = 0
            for (event in events.drain()) {
                match (event.kind) {
                    case NetworkEventKind.RequestStarted => generatedId = event.requestId.getOrThrow()
                    case NetworkEventKind.RequestCompleted =>
                        completedRequests++
                        @Expect(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.StageLimit) => true; case _ => false })
                    case NetworkEventKind.StageCompleted =>
                        failedStages++
                        @Expect(match (event.stage) { case Some(api.OperationTimeoutStage.RequestAdmission) => true; case _ => false })
                        @Expect(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.StageLimit) => true; case _ => false })
                    case _ => ()
                }
            }
            @Expect(generatedId > 0)
            @Expect(failedStages, 1)
            @Expect(completedRequests, 1)
            let _ = cancellation.cancel()
            @Expect(client.resourceSnapshot().completedCancellations, 0)
            response.close()
            @Expect(client.resourceSnapshot().activeRequests, 0)
            @Expect(client.resourceSnapshot().completedCancellations, 1)
            @Expect(client.resourceSnapshot().lastCancellationCompletionLatency.isSome())
        } finally {
            response.close(); client.close()
            let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
        }
    }
}

private class HttpObservationFixture <: HttpServerHandler & HttpServiceHook & HttpConnectionPoolHook {
    var server: ?HttpServer = None<HttpServer>
    var client: ?HttpClient = None<HttpClient>
    let beforeCalls = AtomicInt64(0)
    let afterCalls = AtomicInt64(0)
    let poolCalls = AtomicInt64(0)
    let correlated = AtomicBool(true)
    let poolEvents = api.NetworkEventBuffer(capacity: 16)
    public func before(_: HttpServerRequest, context: OperationContext): Unit {
        let _ = beforeCalls.fetchAdd(1)
        if (context.requestId.isNone() || context.connectionId.isNone()) { correlated.store(false) }
        let _ = server.getOrThrow().observationSnapshot()
        throw Exception("observation failure")
    }
    public func after(_: HttpServerResponse, _: OperationContext): Unit {
        let _ = afterCalls.fetchAdd(1)
        let _ = server.getOrThrow().observationSnapshot()
        throw Exception("observation failure")
    }
    public func acquired(event: NetworkEvent, context: OperationContext): Unit {
        poolEvents.emit(event)
        if (context.requestId != event.requestId || context.attemptId != event.attemptId ||
            context.connectionId != event.connectionId) { correlated.store(false) }
        let _ = poolCalls.fetchAdd(1)
        let _ = client.getOrThrow().observationSnapshot()
        throw Exception("observation failure")
    }
    public func released(_: NetworkEvent, _: OperationContext): Unit {
        let _ = poolCalls.fetchAdd(1)
        let _ = client.getOrThrow().observationSnapshot()
        throw Exception("observation failure")
    }
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        if (request.target == "/delegate-fails") { throw Exception("delegate failed") }
        if (request.target == "/redirect") {
            return HttpServerResponse(HttpResponse(302, "Found", ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Location", "/result").add("Content-Length", "0").build()))
        }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("payload").open()),
            headers: HttpHeaders.builder().add("Content-Length", "7").build()))
    }
}
private class HttpObservationRetryConnector <: HttpConnector {
    private let calls = AtomicInt64(0)
    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        if (calls.fetchAdd(1) == 0) {
            throw NetworkException(NetworkErrorCategory.Connect, NetworkPhase.TcpConnect,
                NetworkErrorCode.ConnectRefused, "fixture refusal", retryability: Retryability.Temporary)
        }
        TcpStream.connect(endpoint, context: context)
    }
}
private class HttpObservationUnknownResolver <: Resolver {
    public func resolve(_: HostName, _: ?String, _: ResolveOptions, _: OperationContext): ResolveResult {
        throw Exception("fixture resolver is not used")
    }
}
private class HttpObservationRotationSink <: NetworkEventSink {
    private let client: HttpClient
    let rotations = AtomicInt64(0)
    init(client: HttpClient) { this.client = client }
    public func emit(event: NetworkEvent): Unit {
        let _ = client.observationSnapshot()
        match (event.kind) { case NetworkEventKind.ConfigurationRotated => let _ = rotations.fetchAdd(1); case _ => () }
        throw Exception("observer failure")
    }
}
