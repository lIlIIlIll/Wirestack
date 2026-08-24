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
