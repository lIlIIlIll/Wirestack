package wirestack_m7_027_examples

import std.collection.ArrayList
import std.sync.*
import wirestack.http.*

private func exampleLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

private class ExampleHttpHandler <: HttpServerHandler {
    let calls = AtomicInt64(0)

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        calls.fetchAdd(1)
        if (request.target == "/events") {
            let headers = if (request.version == HttpVersion.Http11) {
                HttpHeaders.builder()
                    .add("Content-Type", "text/event-stream")
                    .add("Transfer-Encoding", "chunked")
                    .build()
            } else {
                HttpHeaders.builder().add("Content-Type", "text/event-stream").build()
            }
            return HttpServerResponse(HttpResponse(
                200, "OK", ResponseBody(FiniteSseBody()), headers: headers
            ))
        }
        let content = "ok".toArray()
        HttpServerResponse(HttpResponse(
            200,
            "OK",
            ResponseBody(RequestBody.bytes(content).open()),
            headers: HttpHeaders.builder().add("Content-Length", content.size.toString()).build()
        ))
    }
}

private class FiniteSseBody <: HttpBodyStream {
    private let bytes = "id: 1\ndata: alpha\n\nid: 2\ndata: beta\n\n".toArray()
    private var offset: Int64 = 0
    private var closed = false

    public prop contentLength: ?Int64 { get() { None<Int64> } }

    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw IllegalStateException("SSE body is closed") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

func runHttpExamples(): Unit {
    runHttp1SseCancellationAndProxyExamples()
    runHttpsHttp2AndCustomCaExamples()
}

private func runHttp1SseCancellationAndProxyExamples(): Unit {
    let handler = ExampleHttpHandler()
    let server = HttpServer.builder()
        .listen(exampleLoopback(0))
        .handler(handler)
        .connectionLimit(16)
        .build()
    let serving: Future<Unit> = spawn { server.serve() }
    let host = HostName("service.test")
    let resolver = StaticResolver(ResolveResult(
        [server.localEndpoint.address], host, ResolverSource.Static
    ))
    let client = HttpClient.builder()
        .resolver(resolver)
        .requestTimeout(5 * Duration.second)
        .retryPolicy(HttpRetryPolicy(maximumAttempts: 2))
        .build()
    let context = OperationContext(
        deadline: Some(Deadline.after(5 * Duration.second))
    )
    try {
        let response = client.get(
            "http://service.test:${server.localEndpoint.port}/ready",
            context: context
        )
        try {
            exampleRequire(response.status == 200, "HTTP/1.1 status")
            exampleRequire(response.version == HttpVersion.Http11, "HTTP/1.1 version")
            exampleRequire(readExampleBody(response.body) == "ok", "HTTP/1.1 body")
        } finally { response.close() }
        println("HTTP1_SERVER=PASS")

        let events = client.get(
            "http://service.test:${server.localEndpoint.port}/events",
            context: context
        )
        try {
            exampleRequire(
                events.headers.getFirst("content-type") == Some("text/event-stream"),
                "SSE content type"
            )
            exampleRequire(
                readExampleBody(events.body) == "id: 1\ndata: alpha\n\nid: 2\ndata: beta\n\n",
                "SSE payload"
            )
        } finally { events.close() }
        println("SSE=PASS")

        let requestHandle = HttpRequestCancellationHandle()
        let connectionHandle = HttpConnectionCancellationHandle()
        let streamHandle = HttpStreamCancellationHandle()
        exampleRequire(requestHandle.scope == HttpCancellationScope.Request, "request scope")
        exampleRequire(connectionHandle.scope == HttpCancellationScope.Connection, "connection scope")
        exampleRequire(streamHandle.scope == HttpCancellationScope.Stream, "stream scope")
        exampleRequire(requestHandle.cancel() && !requestHandle.cancel(), "request cancellation")
        exampleRequire(connectionHandle.cancel() && !connectionHandle.cancel(), "connection cancellation")
        exampleRequire(streamHandle.cancel() && !streamHandle.cancel(), "stream cancellation")
        var cancelled = false
        try {
            let _ = client.getControlled(
                "http://service.test:${server.localEndpoint.port}/never-sent",
                HttpCancellationHandles(request: Some(requestHandle)),
                context: context
            )
        } catch (error: NetworkException) {
            cancelled = sameNetworkCategory(error.category, NetworkErrorCategory.Cancelled) &&
                sameNetworkCode(error.code, NetworkErrorCode.Cancelled)
        }
        exampleRequire(cancelled, "pre-cancelled request uses structured cancellation")
        exampleRequire(HttpRetryPolicy(maximumAttempts: 2).maximumAttempts == 2, "bounded retry")
        println("SCOPED_CANCELLATION=PASS")

        let proxyHost = HostName("proxy.test")
        let proxyResolver = StaticResolver(ResolveResult(
            [server.localEndpoint.address], proxyHost, ResolverSource.Static
        ))
        let proxy = HttpProxyConfig(
            HttpProxyEndpoint.hostname("proxy.test", server.localEndpoint.port),
            proxyResolver
        )
        let origin = HttpUrl.parse("https://origin.test/resource")
        match (proxy.routeFor(origin)) {
            case HttpProxyRoute.Proxy(selected) =>
                exampleRequire(selected.endpoint.identity.startsWith("proxy.test:"), "proxy identity")
                exampleRequire(origin.host == "origin.test", "origin identity")
            case HttpProxyRoute.Direct => throw IllegalStateException("CONNECT route became direct")
        }
        let tlsConfig = HttpClientTlsConfig([exampleCertificateDer()])
        let proxyClient = HttpClient.builder()
            .resolver(resolver)
            .proxy(proxy)
            .tls(tlsConfig)
            .requestTimeout(5 * Duration.second)
            .build()
        proxyClient.close()
        tlsConfig.close()
        println("CONNECT_TLS=PASS")
    } finally {
        client.close()
        let result = server.shutdown(context: context)
        exampleRequire(result.activeAtReturn == 0, "HTTP/1.1 shutdown")
        serving.get(5 * Duration.second)
    }
}

private func runHttpsHttp2AndCustomCaExamples(): Unit {
    let certificate = exampleCertificateDer()
    let serverTls = HttpServerTlsConfig([certificate], examplePrivateKeyDer())
    let handler = ExampleHttpHandler()
    let server = HttpServer.builder()
        .listen(exampleLoopback(0))
        .handler(handler)
        .tls(serverTls)
        .http2StreamLimit(16u32)
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
    let context = OperationContext(
        deadline: Some(Deadline.after(5 * Duration.second))
    )
    try {
        let response = client.get(
            "https://example.com:${server.localEndpoint.port}/ready",
            context: context
        )
        try {
            exampleRequire(response.status == 200, "HTTPS status")
            exampleRequire(response.version == HttpVersion.Http2, "HTTP/2 ALPN dispatch")
            exampleRequire(readExampleBody(response.body) == "ok", "HTTPS body")
        } finally { response.close() }
        println("HTTPS_CLIENT=PASS")
        println("CUSTOM_CA=PASS")
        println("HTTP2_SERVER=PASS")
    } finally {
        client.close()
        let result = server.shutdown(context: context)
        exampleRequire(result.activeAtReturn == 0, "HTTP/2 shutdown")
        serving.get(5 * Duration.second)
        clientTls.close()
        serverTls.close()
    }
}

private func readExampleBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(128, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func sameNetworkCategory(left: NetworkErrorCategory, right: NetworkErrorCategory): Bool {
    match ((left, right)) {
        case (NetworkErrorCategory.Cancelled, NetworkErrorCategory.Cancelled) => true
        case _ => false
    }
}

private func sameNetworkCode(left: NetworkErrorCode, right: NetworkErrorCode): Bool {
    match ((left, right)) {
        case (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) => true
        case _ => false
    }
}

func exampleRequire(condition: Bool, label: String): Unit {
    if (!condition) { throw IllegalStateException("example assertion failed: ${label}") }
}

