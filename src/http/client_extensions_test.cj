package wirestack.http

import std.collection.ArrayList
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.net.TcpStream

@Test
class HttpClientExtensionsTest {
    @TestCase
    func nativeCookiesAndServiceHooksSurviveThrowingPoolObservers(): Unit {
        let fixture = NativeHttpExtensionFixture()
        let server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16))
            .handler(fixture).serviceHook(fixture).build()
        let serving = spawn { server.serve() }
        let jar = CookieJar()
        let client = HttpClient.builder().cookieJar(jar).connector(fixture).poolHook(fixture)
            .requestTimeout(5 * Duration.second).build()
        let base = "http://127.0.0.1:${server.localEndpoint.port}"
        try {
            let seed = client.get("${base}/seed")
            try {
                @Expect(readExtensionBody(seed.body), "none")
            } finally { seed.close() }
            let stored = client.get("${base}/echo")
            try { @Expect(readExtensionBody(stored.body), "session=stored") }
            finally { stored.close() }
            let headers = HttpHeaders(entries: [HttpHeader("Cookie", "session=explicit")])
            let explicit = client.send(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/echo"),
                headers: headers))
            try { @Expect(readExtensionBody(explicit.body), "session=explicit") }
            finally { explicit.close() }
            @Expect(fixture.connections.load(), 1)
            @Expect(fixture.acquisitions.load(), 3)
            @Expect(fixture.releases.load(), 3)
            let denied = client.get("${base}/denied")
            try { @Expect(denied.status, 500) } finally { denied.close() }
            let afterFailure = client.get("${base}/after-fail")
            try { @Expect(afterFailure.status, 500) } finally { afterFailure.close() }
            let recovered = client.get("${base}/echo")
            try { @Expect(readExtensionBody(recovered.body), "session=stored") }
            finally { recovered.close() }
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
        }
        @Expect(jar.headerFor(HttpUrl.parse("${base}/echo")), "session=stored")
    }

    @TestCase
    func mismatchedUpgradePairingsNeverOpenConnections(): Unit {
        let connector = NativeHttpExtensionFixture()
        let client = HttpClient.builder().connector(connector).requestTimeout(Duration.second).build()
        let url = HttpUrl.parse("https://127.0.0.1:1/session")
        try {
            var implicitRejected = false
            try {
                let _ = client.upgrade(HttpRequest(HttpMethod("GET"), url,
                    headers: HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "echo").build()))
            } catch (_: IllegalArgumentException) { implicitRejected = true }
            @Expect(implicitRejected)
            var connectRejected = false
            try {
                let _ = client.upgrade(HttpRequest(HttpMethod("CONNECT"), url), protocol: Some("echo"))
            } catch (_: IllegalArgumentException) { connectRejected = true }
            @Expect(connectRejected)
            @Expect(connector.connections.load(), 0)
        } finally { client.close() }
    }

    @TestCase
    func unavailableServerPushClosesTheOwnedResponse(): Unit {
        let fixture = NativeHttpExtensionFixture()
        let server = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(fixture).build()
        let serving = spawn { server.serve() }
        let client = HttpClient.builder().requestTimeout(5 * Duration.second).build()
        try {
            let response = client.get("http://127.0.0.1:${server.localEndpoint.port}/push-unavailable")
            try { @Expect(readExtensionBody(response.body), "closed") } finally { response.close() }
        } finally {
            client.close()
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))))
            serving.get(5 * Duration.second)
        }
    }
}

private class NativeHttpExtensionFixture <:
    HttpConnector & HttpConnectionPoolHook & HttpServiceHook & HttpServerHandler {
    let connections = AtomicInt64(0)
    let acquisitions = AtomicInt64(0)
    let releases = AtomicInt64(0)

    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let _ = connections.fetchAdd(1)
        TcpStream.connect(endpoint, context: context)
    }
    public func acquired(_: NetworkEvent, _: OperationContext): Unit {
        let _ = acquisitions.fetchAdd(1)
        throw Exception("observer failure must not affect the request")
    }
    public func released(_: NetworkEvent, _: OperationContext): Unit {
        let _ = releases.fetchAdd(1)
        throw Exception("observer failure must not affect lease release")
    }
    public func before(request: HttpServerRequest, _: OperationContext): Unit {
        if (request.target == "/denied") { throw Exception("service denied this request") }
    }
    public func after(response: HttpServerResponse, _: OperationContext): Unit {
        if (response.response.status == 202) { throw Exception("service rejected this response") }
    }
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        if (request.target == "/push-unavailable") {
            let pushed = HttpResponse(200, "OK", ResponseBody(RequestBody.string("owned").open()))
            var rejected = false
            try {
                request.push(HttpRequest.get("http://127.0.0.1/pushed"), HttpServerResponse(pushed))
            } catch (_: IllegalStateException) { rejected = true }
            let result = if (rejected && pushed.isClosed()) { "closed" } else { "open" }
            pushed.close()
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string(result).open())))
        }
        let cookie = match (request.headers.getFirst("cookie")) {
            case Some(value) => value
            case None => "none"
        }
        let headers = HttpHeaders.builder().add("Content-Length", cookie.size.toString())
        if (request.target == "/seed") {
            headers.add("Set-Cookie", "session=stored; Path=/; HttpOnly")
        }
        let status = if (request.target == "/after-fail") { 202 } else { 200 }
        HttpServerResponse(HttpResponse(status, "OK",
            ResponseBody(RequestBody.string(cookie).open()), headers: headers.build()))
    }
}

private func readExtensionBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(7, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        if (output.size + count > 1024) { throw Exception("unexpected fixture body size") }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}
