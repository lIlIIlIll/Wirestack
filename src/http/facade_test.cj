package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http1 as http1test
import wirestack.internal.transport_stdnet as stdnettest

private func publicLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

@Test
class HttpFacadeTest {
    @TestCase
    func typedCancellationHandlesAreScopedIdempotentAndStopBeforeNetworkIo(): Unit {
        let requestCancellation = HttpRequestCancellationHandle()
        let connectionCancellation = HttpConnectionCancellationHandle()
        let streamCancellation = HttpStreamCancellationHandle()
        @Expect(requestCancellation.scope, HttpCancellationScope.Request)
        @Expect(connectionCancellation.scope, HttpCancellationScope.Connection)
        @Expect(streamCancellation.scope, HttpCancellationScope.Stream)
        @Expect(requestCancellation.cancel())
        @Expect(!requestCancellation.cancel())
        @Expect(requestCancellation.isCancellationRequested)
        let raceHandle = HttpStreamCancellationHandle()
        let raceWinners = AtomicInt64(0)
        let racers = ArrayList<Future<Unit>>()
        for (_ in 0..64) {
            racers.add(spawn {
                if (raceHandle.cancel()) { let _ = raceWinners.fetchAdd(1) }
            })
        }
        for (racer in racers) { racer.get(3 * Duration.second) }
        @Expect(raceWinners.load(), 1)
        @Expect(!raceHandle.cancel())

        let handler = PublicCancellationHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("cancel.test")
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .requestTimeout(3 * Duration.second)
            .build()
        var cancelled = false
        try {
            let warmup = client.get(
                "http://cancel.test:${server.localEndpoint.port}/small"
            )
            @Expect(readPublicBody(warmup.body), "ok")
            warmup.close()
            let _ = client.getControlled(
                "http://cancel.test:${server.localEndpoint.port}/small",
                HttpCancellationHandles(request: Some(requestCancellation))
            )
        } catch (error: NetworkException) {
            match (error.category) {
                case NetworkErrorCategory.Cancelled => cancelled = true
                case _ => ()
            }
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(3 * Duration.second))
            ))
            serving.get(3 * Duration.second)
        }
        @Expect(cancelled)
        @Expect(handler.calls.load(), 1)
        @Expect(connectionCancellation.cancel())
        @Expect(!connectionCancellation.cancel())
        @Expect(streamCancellation.cancel())
        @Expect(!streamCancellation.cancel())
    }

    @TestCase
    func publicHttp1ConnectionHandleCancelsBodyAndLeavesClientReusable(): Unit {
        let handler = PublicCancellationHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("cancel.test")
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .requestTimeout(5 * Duration.second)
            .build()
        try {
            let connectionCancellation = HttpConnectionCancellationHandle()
            let response = client.getControlled(
                "http://cancel.test:${server.localEndpoint.port}/large",
                HttpCancellationHandles(connection: Some(connectionCancellation))
            )
            @Expect(response.version, HttpVersion.Http11)
            @Expect(response.body.read(Array<Byte>(4096, repeat: 0u8)), 4096)
            @Expect(connectionCancellation.cancel())
            @Expect(!connectionCancellation.cancel())
            @Expect(publicBodyReadWasCancelled(response.body))
            response.close()

            let next = client.get("http://cancel.test:${server.localEndpoint.port}/small")
            @Expect(readPublicBody(next.body), "ok")
            next.close()
            @Expect(handler.http1HandleChecks.load() >= 2)
            client.close()
            let result = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
            @Expect(result.activeAtReturn, 0)
            serving.get(5 * Duration.second)
        } finally {
            client.close()
            if (!server.isClosed()) {
                let _ = server.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(5 * Duration.second))
                ))
                serving.get(5 * Duration.second)
            }
        }
    }

    @TestCase
    func publicHttp2StreamAndConnectionHandlesRespectTheirScopes(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        let handler = PublicCancellationHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .tls(serverTls)
            .http2StreamLimit(8u32)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("example.com")
        let clientTls = HttpClientTlsConfig([certificate])
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .tls(clientTls)
            .requestTimeout(5 * Duration.second)
            .build()
        try {
            let streamCancellation = HttpStreamCancellationHandle()
            let first = client.getControlled(
                "https://example.com:${server.localEndpoint.port}/large",
                HttpCancellationHandles(stream: Some(streamCancellation))
            )
            @Expect(first.version, HttpVersion.Http2)
            @Expect(first.body.read(Array<Byte>(4096, repeat: 0u8)), 4096)
            let sibling = client.get(
                "https://example.com:${server.localEndpoint.port}/small"
            )
            // Keep the sibling open across cancellation; the cancelled stream
            // must return enough connection credit for its body to complete.
            @Expect(streamCancellation.cancel())
            @Expect(!streamCancellation.cancel())
            @Expect(publicBodyReadWasCancelled(first.body))
            first.close()
            @Expect(readPublicBody(sibling.body), "ok")
            sibling.close()

            let stillUsable = client.get(
                "https://example.com:${server.localEndpoint.port}/small"
            )
            @Expect(readPublicBody(stillUsable.body), "ok")
            stillUsable.close()

            let requestCancellation = HttpRequestCancellationHandle()
            let wholeRequest = client.getControlled(
                "https://example.com:${server.localEndpoint.port}/large",
                HttpCancellationHandles(request: Some(requestCancellation))
            )
            @Expect(wholeRequest.body.read(Array<Byte>(4096, repeat: 0u8)), 4096)
            @Expect(requestCancellation.cancel())
            @Expect(!requestCancellation.cancel())
            @Expect(publicBodyReadWasCancelled(wholeRequest.body))
            wholeRequest.close()

            let afterRequestCancel = client.get(
                "https://example.com:${server.localEndpoint.port}/small"
            )
            @Expect(readPublicBody(afterRequestCancel.body), "ok")
            afterRequestCancel.close()

            let connectionCancellation = HttpConnectionCancellationHandle()
            let onConnection = client.getControlled(
                "https://example.com:${server.localEndpoint.port}/large",
                HttpCancellationHandles(connection: Some(connectionCancellation))
            )
            let otherStream = client.get(
                "https://example.com:${server.localEndpoint.port}/large"
            )
            @Expect(connectionCancellation.cancel())
            @Expect(!connectionCancellation.cancel())
            @Expect(publicBodyReadWasCancelled(onConnection.body))
            @Expect(publicBodyReadWasCancelled(otherStream.body))
            onConnection.close()
            otherStream.close()
            @Expect(handler.http2HandleChecks.load() >= 7)
            let result = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
            @Expect(result.activeAtReturn, 0)
            serving.get(5 * Duration.second)
        } finally {
            client.close()
            clientTls.close()
            if (!server.isClosed()) {
                let _ = server.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(5 * Duration.second))
                ))
                serving.get(5 * Duration.second)
            }
            serverTls.close()
        }
    }

    @TestCase
    func publicHttp2SlowStreamCannotStarveOneTenOrHundredSiblings(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        let handler = PublicSiblingFairnessHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .tls(serverTls)
            .http2StreamLimit(8u32)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("example.com")
        let clientTls = HttpClientTlsConfig([certificate])
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .tls(clientTls)
            .requestTimeout(5 * Duration.second)
            .build()
        var first: ?HttpResponse = None<HttpResponse>
        try {
            let slow = client.get(
                "https://example.com:${server.localEndpoint.port}/large-stall"
            )
            first = Some(slow)
            @Expect(slow.version, HttpVersion.Http2)
            handler.waitUntilConnectionWindowExhausted()
            @Expect(slow.body.read(Array<Byte>(4096, repeat: 0u8)), 4096)

            let siblingsStarted = MonoTime.now()
            var latency1Ns: Int64 = 0
            var latency10Ns: Int64 = 0
            var latency100Ns: Int64 = 0
            var completed: Int64 = 0
            for (_ in 0..100) {
                let sibling = client.get(
                    "https://example.com:${server.localEndpoint.port}/small"
                )
                try {
                    @Expect(sibling.version, HttpVersion.Http2)
                    @Expect(readPublicBody(sibling.body), "ok")
                    completed++
                    if (completed == 1) {
                        latency1Ns = (MonoTime.now() - siblingsStarted).toNanoseconds()
                    } else if (completed == 10) {
                        latency10Ns = (MonoTime.now() - siblingsStarted).toNanoseconds()
                    } else if (completed == 100) {
                        latency100Ns = (MonoTime.now() - siblingsStarted).toNanoseconds()
                    }
                } finally {
                    sibling.close()
                }
            }
            @Expect(completed, 100)
            @Expect(handler.siblingCalls.load(), 100)
            println(
                "M6_024_RESULT protocol=h2 exhaustedBytes=65535 consumedBytes=4096 " +
                "siblings=${completed} latency1Ns=${latency1Ns} latency10Ns=${latency10Ns} " +
                "latency100Ns=${latency100Ns} siblingTimeouts=0 connectionAborts=0"
            )
        } finally {
            handler.releaseLargeBody()
            if (let Some(slow) <- first) { slow.close() }
            client.close()
            clientTls.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
            serving.get(5 * Duration.second)
            serverTls.close()
        }
    }

    @TestCase
    func tlsHttp2StreamLimitIsAppliedAcrossConcurrentPublicRequests(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig(
            [certificate], publicTlsTestPrivateKeyDer()
        )
        let handler = PublicHttp2LimitHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .tls(serverTls)
            .http2StreamLimit(1u32)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("example.com")
        let clientTls = HttpClientTlsConfig([certificate])
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .tls(clientTls)
            .requestTimeout(5 * Duration.second)
            .build()
        try {
            let first = spawn {
                client.get("https://example.com:${server.localEndpoint.port}/limit/first")
            }
            handler.waitForFirst()
            let second = spawn {
                client.get("https://example.com:${server.localEndpoint.port}/limit/second")
            }
            let secondResponse = second.get(5 * Duration.second)
            let firstResponse = first.get(5 * Duration.second)
            @Expect(secondResponse.status, 204)
            @Expect(firstResponse.status, 204)
            secondResponse.close()
            firstResponse.close()
            @Expect(handler.maximumActive.load(), 2)

            let result = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
            @Expect(result.gracefullyCompleted, 2)
            @Expect(result.aborted, 0)
            @Expect(result.activeAtReturn, 0)
            serving.get(5 * Duration.second)
        } finally {
            client.close()
            clientTls.close()
            if (!server.isClosed()) {
                let _ = server.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(5 * Duration.second))
                ))
                serving.get(5 * Duration.second)
            }
            serverTls.close()
        }
    }

    @TestCase
    func tlsFacadeNegotiatesHttp2AndMapsBodyTrailersAndResponse(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig(
            [certificate], publicTlsTestPrivateKeyDer()
        )
        let handler = PublicHttp2EchoHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .tls(serverTls)
            .http2StreamLimit(4u32)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("example.com")
        let clientTls = HttpClientTlsConfig([certificate])
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .tls(clientTls)
            .requestTimeout(3 * Duration.second)
            .build()
        try {
            let response = client.send(
                HttpRequest.post(
                    "https://example.com:${server.localEndpoint.port}/h2",
                    RequestBody.string("request-body")
                ),
                trailer: HttpTrailer(
                    headers: HttpHeaders.builder().add("X-Request-Trailer", "done").build()
                )
            )
            @Expect(response.status, 201)
            @Expect(readPublicBody(response.body), "response-body")
            @Expect(response.body.trailer.getOrThrow().headers.getFirst("x-response-trailer"), Some("done"))
            @Expect(handler.http2Calls.load(), 1)
            response.close()

            let h1Context = OperationContext(
                deadline: Some(Deadline.after(3 * Duration.second))
            )
            let h1Handshaker = http1test.AwsLcHttp1TlsHandshaker.createWithDer([certificate])
            let h1Transport = stdnettest.StdNetTransportFactory().connect(
                server.localEndpoint, h1Context
            )
            let h1Connection = http1test.Http1ClientConnection(
                h1Handshaker.handshake(HostName("example.com"), h1Transport, h1Context)
            )
            try {
                let h1Response = h1Connection.execute(
                    HttpRequest.get(
                        "https://example.com:${server.localEndpoint.port}/h1"
                    ),
                    context: h1Context
                ).response
                @Expect(h1Response.status, 200)
                h1Response.close()
                @Expect(handler.http1Calls.load(), 1)
            } finally {
                h1Connection.close()
                h1Handshaker.close()
            }

            var structuredReset = false
            try {
                let _ = client.get(
                    "https://example.com:${server.localEndpoint.port}/fail"
                )
            } catch (error: HttpException) {
                match (error.code) {
                    case HttpErrorCode.StreamReset => structuredReset = true
                    case _ => ()
                }
            }
            @Expect(structuredReset)

            let result = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(3 * Duration.second))
            ))
            @Expect(result.gracefullyCompleted, 1)
            @Expect(result.aborted, 0)
            @Expect(result.activeAtReturn, 0)
            serving.get(3 * Duration.second)
        } finally {
            client.close()
            clientTls.close()
            if (!server.isClosed()) {
                let _ = server.shutdown(context: OperationContext(
                    deadline: Some(Deadline.after(3 * Duration.second))
                ))
                serving.get(3 * Duration.second)
            }
            serverTls.close()
        }
    }

    @TestCase
    func explicitResolverConnectsPublicClientAndServer(): Unit {
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(PublicEmptyHandler())
            .connectionLimit(4)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("loopback.test")
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .requestTimeout(Duration.second)
            .build()
        try {
            let response = client.get("http://loopback.test:${server.localEndpoint.port}/ready")
            @Expect(response.status, 200)
            @Expect(response.headers.getFirst("content-length"), Some("0"))
            @Expect(response.body.read(Array<Byte>(1, repeat: 0)), 0)
            response.close()
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
        }
    }

    @TestCase
    func defaultSystemResolverConnectsPublicClientAndServer(): Unit {
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(PublicEmptyHandler())
            .connectionLimit(4)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let client = HttpClient.default()
        try {
            let response = client.get(
                "http://localhost:${server.localEndpoint.port}/ready",
                context: OperationContext(
                    deadline: Some(Deadline.after(Duration.second))
                )
            )
            @Expect(response.status, 200)
            @Expect(response.body.read(Array<Byte>(1, repeat: 0)), 0)
            response.close()
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
        }
    }

    @TestCase
    func clientFollowsOriginRelativeRedirectEndToEnd(): Unit {
        let handler = PublicRedirectHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("redirect.test")
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .requestTimeout(Duration.second)
            .build()
        try {
            let response = client.get("http://redirect.test:${server.localEndpoint.port}/start")
            @Expect(response.status, 200)
            @Expect(handler.calls.load(), 2)
            response.close()
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
        }
    }

    @TestCase
    func clientRetriesOneTemporaryDnsFailureWithinTheSameDeadline(): Unit {
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(PublicEmptyHandler())
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let host = HostName("retry.test")
        let resolver = FlakyPublicResolver(ResolveResult(
            [server.localEndpoint.address], host, ResolverSource.Static
        ))
        let client = HttpClient.builder()
            .resolver(resolver)
            .requestTimeout(Duration.second)
            .retryPolicy(HttpRetryPolicy(maximumAttempts: 2))
            .build()
        try {
            let response = client.get("http://retry.test:${server.localEndpoint.port}/ready")
            @Expect(response.status, 200)
            @Expect(resolver.calls.load(), 2)
            response.close()
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
        }
    }

    @TestCase
    func forwardProxyUsesAbsoluteFormIndependentDnsAndHookCredentials(): Unit {
        let handler = PublicForwardProxyHandler()
        let server = HttpServer.builder()
            .listen(publicLoopback(0))
            .handler(handler)
            .build()
        let serving: Future<Unit> = spawn { server.serve() }
        let proxyHost = HostName("proxy.test")
        let proxyResolver = CountingPublicResolver(ResolveResult(
            [server.localEndpoint.address], proxyHost, ResolverSource.Static
        ))
        let originResolver = RejectingPublicResolver()
        let authorization = PublicProxyAuthorization()
        let proxy = HttpProxyConfig(
            HttpProxyEndpoint.hostname("proxy.test", server.localEndpoint.port),
            proxyResolver,
            authorizationProvider: Some(authorization)
        )
        let client = HttpClient.builder()
            .resolver(originResolver)
            .proxy(proxy)
            .requestTimeout(Duration.second)
            .build()
        try {
            let request = HttpRequest(
                HttpMethod("GET"),
                HttpUrl.parse("http://origin.test:8081/path?q=1"),
                headers: HttpHeaders.builder()
                    .add("Proxy-Authorization", "Caller value must be replaced")
                    .build()
            )
            let response = client.send(request)
            @Expect(response.status, 200)
            response.close()
            @Expect(handler.valid.load(), 1)
            @Expect(proxyResolver.calls.load(), 1)
            @Expect(originResolver.calls.load(), 0)
            @Expect(authorization.calls.load(), 1)
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))
            ))
            serving.get(Duration.second)
        }
    }

    @TestCase
    func serverBuilderRequiresEndpointAndHandler(): Unit {
        var missingEndpoint = false
        try {
            let _ = HttpServer.builder().handler(PublicEmptyHandler()).build()
        } catch (_: IllegalStateException) {
            missingEndpoint = true
        }
        @Expect(missingEndpoint)

        var missingHandler = false
        try {
            let _ = HttpServer.builder().listen(publicLoopback(0)).build()
        } catch (_: IllegalStateException) {
            missingHandler = true
        }
        @Expect(missingHandler)
    }

    @TestCase
    func tlsServerConfigFailsClosedBeforeBinding(): Unit {
        let invalid = HttpServerTlsConfig([], [1u8, 2u8, 3u8])
        var invalidRejected = false
        try {
            let _ = HttpServer.builder()
                .listen(publicLoopback(0))
                .handler(PublicEmptyHandler())
                .tls(invalid)
                .build()
        } catch (_: Exception) {
            invalidRejected = true
        } finally {
            invalid.close()
        }
        @Expect(invalidRejected)

        let closed = HttpServerTlsConfig([], [])
        closed.close()
        var closedRejected = false
        try {
            let _ = HttpServer.builder()
                .listen(publicLoopback(0))
                .handler(PublicEmptyHandler())
                .tls(closed)
                .build()
        } catch (_: IllegalStateException) {
            closedRejected = true
        }
        @Expect(closedRejected)

        let clientTls = HttpClientTlsConfig([])
        clientTls.close()
        var clientClosedRejected = false
        try {
            let _ = HttpClient.builder().tls(clientTls).build()
        } catch (_: IllegalStateException) {
            clientClosedRejected = true
        }
        @Expect(clientClosedRejected)
    }
}

private class PublicHttp2LimitHandler <: HttpServerHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var arrivals: Int64 = 0
    private var active: Int64 = 0
    let maximumActive = AtomicInt64(0)

    func waitForFirst(): Unit {
        synchronized(mutex) {
            while (arrivals == 0) { changed.wait(timeout: 5 * Duration.second) }
        }
    }

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        @Expect(request.version, HttpVersion.Http2)
        synchronized(mutex) {
            arrivals++
            active++
            maximumActive.store(max(maximumActive.load(), active))
            changed.notifyAll()
            while (arrivals < 2) { changed.wait(timeout: 5 * Duration.second) }
        }
        let response = HttpServerResponse(HttpResponse(
            204, "No Content", ResponseBody.empty()
        ))
        synchronized(mutex) { active--; changed.notifyAll() }
        response
    }
}

private class PublicHttp2EchoHandler <: HttpServerHandler {
    let http2Calls = AtomicInt64(0)
    let http1Calls = AtomicInt64(0)

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        if (request.target == "/h1") {
            @Expect(request.version, HttpVersion.Http11)
            http1Calls.fetchAdd(1)
            return HttpServerResponse(HttpResponse(
                200, "OK", ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Content-Length", "0").build()
            ))
        }
        @Expect(request.version, HttpVersion.Http2)
        if (request.target == "/fail") {
            throw Exception("scripted public HTTP/2 handler failure")
        }
        @Expect(request.target, "/h2")
        @Expect(readPublicBody(request.body), "request-body")
        @Expect(
            request.body.trailer.getOrThrow().headers.getFirst("x-request-trailer"),
            Some("done")
        )
        http2Calls.fetchAdd(1)
        HttpServerResponse(
            HttpResponse(
                201, "Created", ResponseBody(RequestBody.string("response-body").open()),
                headers: HttpHeaders.builder().add("Content-Length", "13").build()
            ),
            trailer: HttpTrailer(
                headers: HttpHeaders.builder().add("X-Response-Trailer", "done").build()
            )
        )
    }
}

private class PublicCancellationHandler <: HttpServerHandler {
    let calls = AtomicInt64(0)
    let http1HandleChecks = AtomicInt64(0)
    let http2HandleChecks = AtomicInt64(0)

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        calls.fetchAdd(1)
        @Expect(request.requestCancellation.scope, HttpCancellationScope.Request)
        @Expect(request.connectionCancellation.scope, HttpCancellationScope.Connection)
        match (request.version) {
            case HttpVersion.Http2 =>
                @Expect(
                    request.streamCancellation.getOrThrow().scope,
                    HttpCancellationScope.Stream
                )
                http2HandleChecks.fetchAdd(1)
            case _ =>
                @Expect(request.streamCancellation.isNone())
                http1HandleChecks.fetchAdd(1)
        }
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        let bytes = if (request.target == "/large") {
            Array<Byte>(256 * 1024, repeat: b'x')
        } else {
            "ok".toArray()
        }
        HttpServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody(RequestBody.bytes(bytes).open()),
            headers: HttpHeaders.builder()
                .add("Content-Length", bytes.size.toString())
                .build()
        ))
    }
}

private class PublicSiblingFairnessHandler <: HttpServerHandler {
    private let largeBody = PublicConnectionWindowBody()
    let siblingCalls = AtomicInt64(0)

    func waitUntilConnectionWindowExhausted(): Unit { largeBody.waitUntilBlocked() }
    func releaseLargeBody(): Unit { largeBody.release() }

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        @Expect(request.version, HttpVersion.Http2)
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        if (request.target == "/large-stall") {
            return HttpServerResponse(HttpResponse(
                200, "OK", ResponseBody(largeBody),
                headers: HttpHeaders.builder()
                    .add("Content-Type", "application/octet-stream")
                    .build()
            ))
        }
        @Expect(request.target, "/small")
        siblingCalls.fetchAdd(1)
        HttpServerResponse(HttpResponse(
            200, "OK", ResponseBody(RequestBody.string("ok").open()),
            headers: HttpHeaders.builder().add("Content-Length", "2").build()
        ))
    }
}

private class PublicConnectionWindowBody <: HttpBodyStream {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var remaining: Int64 = 65535
    private var blocked = false
    private var released = false
    private var closed = false

    public prop contentLength: ?Int64 { get() { None<Int64> } }

    func waitUntilBlocked(): Unit {
        synchronized(mutex) {
            while (!blocked) {
                changed.wait(timeout: 5 * Duration.second)
                if (!blocked) { @Fail("large HTTP/2 body did not exhaust the connection window") }
            }
        }
    }

    func release(): Unit {
        synchronized(mutex) { released = true; changed.notifyAll() }
    }

    public func read(destination: Array<Byte>): Int64 {
        synchronized(mutex) {
            if (closed || destination.isEmpty()) { return 0 }
            if (remaining > 0) {
                let count = min(destination.size, remaining)
                for (index in 0..count) { destination[index] = b'x' }
                remaining -= count
                return count
            }
            blocked = true
            changed.notifyAll()
            while (!released && !closed) { changed.wait() }
            0
        }
    }

    public func close(): Unit {
        synchronized(mutex) { closed = true; changed.notifyAll() }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private func publicBodyReadWasCancelled(body: ResponseBody): Bool {
    try {
        let _ = body.read(Array<Byte>(4096, repeat: 0u8))
        false
    } catch (error: NetworkException) {
        match (error.category) {
            case NetworkErrorCategory.Cancelled => true
            case _ => false
        }
    }
}

private func readPublicBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(4, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

// Self-signed public test identity, valid 2026-08-23 through 2036-08-20.
internal func publicTlsTestCertificateDer(): Array<Byte> {
    decodePublicTlsBase64(
        "MIIDQzCCAiugAwIBAgIUDZ6pPmV6gcjC9tTovgITROZDWi4wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzIwMTkyOFoXDTM2MDgyMDIwMTkyOFowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQABo4GAMH4wHQYDVR0OBBYEFOdUzp+rhoI4EOD+k/HiZeHgTdcEMB8GA1UdIwQYMBaAFOdUzp+rhoI4EOD+k/HiZeHgTdcEMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALHiaFne/TJfVzznruLWTPKpQV/+dZKhPw8X2umZ1fLd6/sD2xtoeDof2IOx+HqQJuQNFNY8lAHsCb5J72/O5rXBhHHbYxwTL/LuAo9fKbCCwxp10Y5gwPrEcl5T1ZlsAgPTKq10ONwNR03wefE6epejITvX2nCNJUiaf3BWzFiq5xsZXfUHoil/AqAJfqnAgiABoOs/ZxErf0q16Apr4rjFvreAwsiYr1YgJ4aL97j3jCvJUNreGr8TNUBachUSrRvWcOOTaw90eex/6DnvU1EHDknlmcuuzywawVNzrTd10EuHimVfJgo1hRSzXd4deCHKStlYkPKZpwU/M+Al8F0="
    )
}

internal func publicTlsTestPrivateKeyDer(): Array<Byte> {
    decodePublicTlsBase64(
        "MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDf4gLNUdpDz5zPF5X9p6D+IAiDCGpjK1FVzXv8Fjdd0u1hJob07rBjG2qbnNm9y6NyXfm9K0QQhzpGxelDEBTManoarXb0xMPN3JblrvHrdtYLpmWHpKkLjMV23/EYmKwnD8dLgsctcrNCJLAdk/AU3vM5nQkwCHTkEsXjIQ7CRuKphRHeLvPTBW29QW4vc0AZ9lfNdjUdGL5B+b+H2VusyZC2beQEYGZlSHwBKq6Bx+IIzOJhhjXKBnDUwALEnrSdF++rXBhVl1SaIPZYQPg0XRUrny0/+onQqcrP8jaDgZxXle7W0f/Y1hojxhPZ6MhCfpODBhY37cdpd7dDzcNDAgMBAAECggEAKz/5o5l27VerptQbHTPnZYBhtJKJHtxM66L1GzddfcoUIorzUljUCWlP+HzeEYzH5/2gk7tKfFjrWKW+EL8IDY9aRFITY2ipnNjK69cWlBLSedCs133nTDxnHzZW2JYR17/0E7HRcYWxfIsi3KvqGtYRLaWZE0bm8fJweRa3R69WXYsZOYDK1CDMmrGZ572+5thDTVaiQKOOUBPNgucnB894rYtLYs98sb+2h4EUHZ0cQCIBUVdwu6BAFMwiAEtz2CClwA1G2fq59A9mqQXSkj8WaUHUgo9WcExt6pBEb5MPca+BHWz/aqdC9HRKQFBl3kn4h0qEGkLSy0WrMLKm7QKBgQD6fmd1BDrlsgbLoai3NnrnqKVbn8+0vnJjmTTykxeYHQXxBt3fzH+t42crJowQbuLeoO20oUY0VU8eQVh7bWvduucfFqrecLCL6GhhAFxp2dMjgOdvIim3QN9kvTSUlwOYchA43RTA7wWSzUf1+bL1XWs5bUNg5azpN0Btkma5xQKBgQDkzdwslfjcZgOp1QX2oSPOaA1VuOEJnr3+I2SR8FNH+bVwfbrilF5Mm08jHHHgoqgnGZLG7GLIgQAU1PmIr84hB7CE3JM9xXJ3t0jZ7BktfJEHLzog2Dr6vzXGT+yDcd2q1Lr3GL6x18Y+kgv6ieLv047SOBLal4o8iEjj9PZBZwKBgQCEzx4VKZ/8hq4ZquVj9iulxYGemZWrc8n8So+LCTfaO5EZ4JUkgi0zyby6YR6j29bHSLWfLl6lgpGHLgg2sKYfEmhV0FPZyg+griEhROq6aHYMfdy2zHsnoOqQY8yL96E9Y0R8kaLeRBxFYDeGD9S1SMl/0hGGP1+06slrDtMOLQKBgQCGArDviFN/O1zv7u4UOuNO9JDC4Ysk6E4deLth4uHUaURFA88fAImO0vRx+yoTyRE1/XuDeVaOW0gh62/QCDByFh/kYZD4ABqAVeCcivVgN/J1w8qHDD7XOIEViyBbCKktcnWjXmHqphfd9AqCDprVnxKqu98HGvUDaUtQANzvBwKBgQDJkuAOZocXTl77PfxDWfsP57StrsiuL+AvoH2FscRcT19e9T2U4YuCsyVydRM+gjUoJX5VPedIo+/gcvJrQcJIfwzZlqMMEJnYcWjoG8GYVtub9/xxSPmfuyj3GDbXEcirKkmGOmI5hPEP2UIasTUeljm8sHSP2B52kyKmdVGuUg=="
    )
}

private func decodePublicTlsBase64(value: String): Array<Byte> {
    let output = ArrayList<Byte>()
    var accumulator: Int64 = 0
    var bits: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == b'=') { break }
        let decoded: Int64 = if (byte >= b'A' && byte <= b'Z') {
            Int64(byte - b'A')
        } else if (byte >= b'a' && byte <= b'z') {
            Int64(byte - b'a') + 26
        } else if (byte >= b'0' && byte <= b'9') {
            Int64(byte - b'0') + 52
        } else if (byte == b'+') { 62 }
        else if (byte == b'/') { 63 }
        else { throw IllegalArgumentException("invalid public TLS test fixture") }
        accumulator = (accumulator << 6) | decoded
        bits += 6
        if (bits >= 8) {
            bits -= 8
            output.add(UInt8(UInt64((accumulator >> bits) & 0xff)))
            accumulator &= if (bits == 0) { 0 } else { (1 << bits) - 1 }
        }
    }
    output.toArray()
}

private class PublicEmptyHandler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        @Expect(request.target, "/ready")
        HttpServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}

private class PublicRedirectHandler <: HttpServerHandler {
    let calls = AtomicInt64(0)

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        let call = calls.fetchAdd(1) + 1
        if (call == 1) {
            HttpServerResponse(HttpResponse(
                302,
                "Found",
                ResponseBody.empty(),
                headers: HttpHeaders.builder()
                    .add("Location", "/final")
                    .add("Content-Length", "0")
                    .build()
            ))
        } else {
            @Expect(request.target, "/final")
            HttpServerResponse(HttpResponse(
                200,
                "OK",
                ResponseBody.empty(),
                headers: HttpHeaders.builder().add("Content-Length", "0").build()
            ))
        }
    }
}

private class FlakyPublicResolver <: Resolver {
    private let result: ResolveResult
    let calls = AtomicInt64(0)

    init(result: ResolveResult) { this.result = result }

    public func resolve(host: HostName, service: ?String, options: ResolveOptions,
        context: OperationContext): ResolveResult {
        let _ = host
        let _ = service
        let _ = options
        let _ = context
        if (calls.fetchAdd(1) == 0) {
            throw ResolveException(ResolveErrorCode.TemporaryFailure, "scripted temporary DNS failure")
        }
        result
    }
}

private class CountingPublicResolver <: Resolver {
    private let result: ResolveResult
    let calls = AtomicInt64(0)

    init(result: ResolveResult) { this.result = result }

    public func resolve(host: HostName, service: ?String, options: ResolveOptions,
        context: OperationContext): ResolveResult {
        let _ = host
        let _ = service
        let _ = options
        let _ = context
        calls.fetchAdd(1)
        result
    }
}

private class RejectingPublicResolver <: Resolver {
    let calls = AtomicInt64(0)

    public func resolve(host: HostName, service: ?String, options: ResolveOptions,
        context: OperationContext): ResolveResult {
        let _ = host
        let _ = service
        let _ = options
        let _ = context
        calls.fetchAdd(1)
        throw ResolveException(ResolveErrorCode.NameNotFound, "origin resolver must not run for a proxy route")
    }
}

private class PublicProxyAuthorization <: HttpProxyAuthorizationProvider {
    let calls = AtomicInt64(0)

    public func authorization(proxy: HttpProxyEndpoint, target: HttpUrl,
        context: OperationContext): ?String {
        let _ = context
        @Expect(proxy.identity.startsWith("proxy.test:"))
        @Expect(target.host, "origin.test")
        calls.fetchAdd(1)
        Some("Basic hook-value")
    }
}

private class PublicForwardProxyHandler <: HttpServerHandler {
    let valid = AtomicInt64(0)

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        if (request.target == "http://origin.test:8081/path?q=1" &&
            request.headers.getFirst("host") == Some("origin.test:8081") &&
            request.headers.getFirst("proxy-authorization") == Some("Basic hook-value") &&
            request.headers.getAll("proxy-authorization").size == 1) {
            valid.store(1)
        }
        HttpServerResponse(HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}
