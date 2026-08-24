package wirestack.http

import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

private func publicLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

@Test
class HttpFacadeTest {
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
    func defaultResolverFailsClosedBeforeOpeningASocket(): Unit {
        let client = HttpClient.default()
        var unavailable = false
        try {
            let _ = client.get("http://example.com/")
        } catch (error: HttpClientCapabilityException) {
            match (error.code) {
                case HttpClientCapabilityErrorCode.SystemResolverUnavailable => unavailable = true
            }
        } finally {
            client.close()
        }
        @Expect(unavailable)
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
