package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class WebSocketHandshakeTest {
    @TestCase
    func nativeHttp1UpgradeTransfersFramesAndClosesSession(): Unit {
        exerciseNativeWebSocket(false)
    }

    @TestCase
    func nativeHttp2ExtendedConnectKeepsSiblingRequestsUsable(): Unit {
        exerciseNativeWebSocket(true)
    }
}

private func exerciseNativeWebSocket(secure: Bool): Unit {
    let handler = NativeWebSocketHandler(secure)
    let builder = HttpServer.builder().listen(SocketEndpoint(
        IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(handler)
    let certificate = publicTlsTestCertificateDer()
    let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
    let clientTls = HttpClientTlsConfig([certificate])
    if (secure) { builder.tls(serverTls) }
    let server = builder.build()
    let serving: Future<Unit> = spawn { server.serve() }
    let clientBuilder = HttpClient.builder().resolver(StaticResolver(ResolveResult(
        [server.localEndpoint.address], HostName("example.com"), ResolverSource.Static
    ))).requestTimeout(5 * Duration.second)
    if (secure) {
        clientBuilder.tls(clientTls)
        clientBuilder.http2Push(Http2PushConfig(SameOriginHttp2PushPolicy()))
    }
    let client = clientBuilder.build()
    let scheme = if (secure) { "https" } else { "http" }
    let base = "${scheme}://example.com:${server.localEndpoint.port}"
    try {
        let result = client.connectWebSocket(HttpUrl.parse("${base}/socket"), protocols: ["echo"])
        let session = match (result) {
            case WebSocketConnectResult.Connected(value) => value
            case WebSocketConnectResult.Rejected(response) =>
                let status = response.status
                response.close()
                throw Exception("WebSocket handshake rejected with ${status}")
        }
        try {
            session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [0u8, 255u8, 17u8]))
            @Expect(session.receive().payload, [0u8, 255u8, 17u8])
            if (secure) {
                let sibling = client.get("${base}/sibling")
                @Expect(sibling.status, 204)
                @Expect(sibling.version, HttpVersion.Http2)
                sibling.close()
                let parent = client.get("${base}/push")
                try {
                    @Expect(parent.body.read(Array<Byte>(1, repeat: 0u8)), 0)
                    let pushed = parent.pushes.getOrThrow().receive(context: OperationContext(
                        deadline: Some(Deadline.after(Duration.second)))).getOrThrow()
                    try {
                        @Expect(pushed.request.url.toString(), "${base}/asset")
                        let bytes = Array<Byte>(5, repeat: 0u8)
                        @Expect(pushed.response.body.read(bytes), 5)
                        @Expect(String.fromUtf8(bytes), "asset")
                    } finally { pushed.close() }
                } finally { parent.close() }
            }
            session.close(1000u16, "done", context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))))
            @Expect(session.isClosed())
        } finally { session.close() }
    } finally {
        client.close()
        let _ = server.shutdown(context: OperationContext(
            deadline: Some(Deadline.after(5 * Duration.second))))
        serving.get(5 * Duration.second)
        serverTls.close()
        clientTls.close()
    }
}

private class NativeWebSocketHandler <: HttpServerHandler & WebSocketHandler {
    private let secure: Bool
    init(secure: Bool) { this.secure = secure }

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        if (request.target == "/sibling") {
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        if (request.target == "/push") {
            request.push(
                HttpRequest.get("https://${request.authority}/asset"),
                HttpServerResponse(HttpResponse(200, "OK",
                    ResponseBody(RequestBody.string("asset").open())))
            )
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        if (secure) {
            @Expect(request.version, HttpVersion.Http2)
            @Expect(request.protocol, Some("websocket"))
        } else { @Expect(request.version, HttpVersion.Http11) }
        HttpServerResponse.webSocket(request, this, subProtocol: Some("echo"))
    }

    public func serve(connection: WebSocketConnection, context: OperationContext): Unit {
        let frame = connection.receive(context: context)
        connection.send(WebSocketFrame(WebSocketOpcode.Binary, payload: frame.payload), context: context)
        let close = connection.receive(context: context)
        @Expect(match (close.opcode) { case WebSocketOpcode.Close => true; case _ => false })
    }
}
