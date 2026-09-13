package wirestack_m8_005_native_http

import std.collection.ArrayList
import std.env.getStdOut
import std.fs.*
import std.sync.*
import wirestack as api
import wirestack.http.*
import wirestack.net.TcpStream

func announce(value: String): Unit { println(value); getStdOut().flush() }
func require(value: Bool, message: String): Unit { if (!value) { throw Exception(message) } }
func boundedContext(): OperationContext {
    OperationContext(deadline: Some(Deadline.after(5 * Duration.second)))
}
func loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}
func localClient(server: HttpServer, host: String): HttpClientBuilder {
    HttpClient.builder().resolver(StaticResolver(ResolveResult(
        [server.localEndpoint.address], HostName(host), ResolverSource.Static
    ))).requestTimeout(5 * Duration.second)
}
func stopServer(server: HttpServer, serving: Future<Unit>): Unit {
    try {
        let result = server.shutdown(context: boundedContext())
        require(result.activeAtReturn == 0, "HTTP server retained active connections")
        serving.get(5 * Duration.second)
    } finally { server.close() }
}
func readBody(body: ResponseBody): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(7, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        if (output.size + count > 4096) { throw Exception("response exceeded consumer bound") }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    output.toArray()
}

const NATIVE_PUSH_BYTES: Int64 = 131072
func requireLargePushBody(body: ResponseBody): Unit {
    let buffer = Array<Byte>(4096, repeat: 0u8)
    var received: Int64 = 0
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        require(received + count <= NATIVE_PUSH_BYTES, "push exceeded its declared consumer bound")
        for (index in 0..count) { require(buffer[index] == b'p', "pushed byte changed") }
        received += count
    }
    require(received == NATIVE_PUSH_BYTES, "push ended before its body crossed the stream window")
}

func readFile(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(7, repeat: 0u8)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            if (output.size + count > 4096) { throw Exception("file exceeded consumer bound") }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        output.toArray()
    } finally { file.close() }
}
func isBinary(value: WebSocketOpcode): Bool {
    match (value) { case WebSocketOpcode.Binary => true; case _ => false }
}
func isClose(value: WebSocketOpcode): Bool {
    match (value) { case WebSocketOpcode.Close => true; case _ => false }
}

class HookFixture <: HttpConnector & HttpConnectionPoolHook & HttpServiceHook & HttpServerHandler {
    let connections = AtomicInt64(0)
    let acquisitions = AtomicInt64(0)
    let releases = AtomicInt64(0)
    let beforeCalls = AtomicInt64(0)
    let afterCalls = AtomicInt64(0)

    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let _ = connections.fetchAdd(1)
        TcpStream.connect(endpoint, context: context)
    }
    public func acquired(_: NetworkEvent, _: OperationContext): Unit {
        let _ = acquisitions.fetchAdd(1)
    }
    public func released(_: NetworkEvent, _: OperationContext): Unit {
        let _ = releases.fetchAdd(1)
    }
    public func before(_: HttpServerRequest, _: OperationContext): Unit {
        let _ = beforeCalls.fetchAdd(1)
    }
    public func after(_: HttpServerResponse, _: OperationContext): Unit {
        let _ = afterCalls.fetchAdd(1)
    }
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        request.body.close()
        let cookie = match (request.headers.getFirst("cookie")) {
            case Some(value) => value
            case None => "none"
        }
        let headers = HttpHeaders.builder().add("Content-Length", cookie.size.toString())
        if (request.target == "/seed") {
            headers.add("Set-Cookie", "session=stored; Path=/; HttpOnly")
        }
        HttpServerResponse(HttpResponse(200, "OK",
            ResponseBody(RequestBody.string(cookie).open()), headers: headers.build()))
    }
}

func runCookiesHooks(): Unit {
    let fixture = HookFixture()
    let server = HttpServer.builder().listen(loopback(0)).handler(fixture)
        .serviceHook(fixture).connectionLimit(4).build()
    let serving: Future<Unit> = spawn { server.serve() }
    let jar = CookieJar()
    let client = localClient(server, "cookies.test").cookieJar(jar)
        .connector(fixture).poolHook(fixture).build()
    let base = "http://cookies.test:${server.localEndpoint.port}"
    try {
        let seed = client.get("${base}/seed", context: boundedContext())
        try { require(String.fromUtf8(readBody(seed.body)) == "none", "seed request carried a cookie") }
        finally { seed.close() }
        let stored = client.get("${base}/echo", context: boundedContext())
        try { require(String.fromUtf8(readBody(stored.body)) == "session=stored", "stored cookie was not sent") }
        finally { stored.close() }
        let explicit = client.send(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/echo"),
            headers: HttpHeaders(entries: [HttpHeader("Cookie", "session=explicit")])),
            context: boundedContext())
        try { require(String.fromUtf8(readBody(explicit.body)) == "session=explicit", "explicit cookie did not win") }
        finally { explicit.close() }
        require(jar.headerFor(HttpUrl.parse("${base}/echo")) == "session=stored", "cookie jar selection changed")
        require(fixture.connections.load() == 1, "custom connector did not preserve pooled reuse")
        require(fixture.acquisitions.load() == 3 && fixture.releases.load() == 3,
            "pool hook did not observe every lease transition")
        require(fixture.beforeCalls.load() == 3 && fixture.afterCalls.load() == 3,
            "service hook did not surround every request")
    } finally {
        client.close()
        stopServer(server, serving)
    }
    announce("COOKIES_HOOKS_PASS")
}

func uploadRequest(server: HttpServer, writer: MultipartWriter): HttpRequest {
    let body = writer.body(maximumBytes: 4096)
    HttpRequest(HttpMethod("POST"),
        HttpUrl.parse("http://files-upload.test:${server.localEndpoint.port}/upload"),
        headers: HttpHeaders(entries: [
            HttpHeader("Content-Type", writer.contentType()),
            HttpHeader("Content-Length", body.contentLength.getOrThrow().toString())
        ]), body: body)
}

class FileContextFixture <: HttpServerHandler {
    private let handler: FileHandler
    init(handler: FileHandler) { this.handler = handler }

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        if (request.target != "/cancel" && request.target != "/expired") {
            return handler.handle(request, context)
        }
        let cancellation = api.CancellationSource()
        if (request.target == "/cancel") { cancellation.cancel() }
        let stopped = if (request.target == "/cancel") {
            OperationContext(cancellation: cancellation.token)
        } else {
            OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
        }
        try {
            let unexpected = handler.handle(request, stopped)
            unexpected.response.close()
        } catch (error: FileHandlerException) {
            let matches = match (error.code) {
                case FileHandlerErrorCode.Cancelled => request.target == "/cancel"
                case FileHandlerErrorCode.DeadlineExceeded => request.target == "/expired"
            }
            require(matches, "file context stop lost its structured category")
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        throw Exception("file handler accepted a stopped context")
    }
}

func runFilesMultipart(): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let bytes: Array<Byte> = [0u8, 255u8, 13u8, 10u8, 7u8, 0u8, 128u8]
    try {
        let uploader = FileHandler.upload(root, maximumBytes: 64, bufferSize: 4096,
            validator: { name => name == "payload.bin" }, maximumParts: 2)
        let uploadServer = HttpServer.builder().listen(loopback(0)).handler(uploader).build()
        let uploadServing: Future<Unit> = spawn { uploadServer.serve() }
        let uploadClient = localClient(uploadServer, "files-upload.test").build()
        try {
            let writer = MultipartWriter("m8-005:binary/boundary?")
                .add(MultipartPart("file", bytes, filename: Some("payload.bin")))
            require(writer.contentType() ==
                "multipart/form-data; boundary=\"m8-005:binary/boundary?\"",
                "multipart boundary was not quoted")
            let response = uploadClient.send(uploadRequest(uploadServer, writer), context: boundedContext())
            try { require(response.status == 201, "binary multipart upload was rejected") }
            finally { response.close() }
            require(readFile("${root}/payload.bin") == bytes, "uploaded binary file changed")
        } finally {
            uploadClient.close()
            stopServer(uploadServer, uploadServing)
            uploader.close()
        }

        let downloader = FileHandler.download(root, "payload.bin", maximumBytes: 64, bufferSize: 4096)
        let downloadServer = HttpServer.builder().listen(loopback(0))
            .handler(FileContextFixture(downloader)).build()
        let downloadServing: Future<Unit> = spawn { downloadServer.serve() }
        let downloadClient = localClient(downloadServer, "files-download.test").build()
        try {
            for (path in ["/cancel", "/expired"]) {
                let stopped = downloadClient.get(
                    "http://files-download.test:${downloadServer.localEndpoint.port}${path}",
                    context: boundedContext())
                try { require(stopped.status == 204, "file context stop was not preserved") }
                finally { stopped.close() }
            }
            let response = downloadClient.get(
                "http://files-download.test:${downloadServer.localEndpoint.port}/download",
                context: boundedContext())
            try {
                require(response.status == 200, "binary file download was rejected")
                require(response.headers.getFirst("content-type") == Some("application/octet-stream"),
                    "binary download content type changed")
                require(readBody(response.body) == bytes, "downloaded binary body changed")
            } finally { response.close() }
        } finally {
            downloadClient.close()
            stopServer(downloadServer, downloadServing)
            downloader.close()
        }
    } finally { let _ = removeIfExists(root, recursive: true) }
    announce("FILES_MULTIPART_PASS")
}

class UpgradeEcho <: HttpDuplexHandler {
    public func serve(transport: api.DuplexTransport, context: OperationContext): Unit {
        let request = Array<Byte>(4, repeat: 0u8)
        api.readExact(transport, api.MutableByteSpan(request), context: context)
        require(request == "ping".toArray(), "generic upgrade request bytes changed")
        api.writeAll(transport, api.ByteSpan("pong".toArray()), context: context)
        transport.shutdown(api.ShutdownDirection.Write)
    }
}
class UpgradeHandler <: HttpServerHandler {
    private let echo = UpgradeEcho()
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        require(request.version == HttpVersion.Http11, "generic Upgrade did not use HTTP/1.1")
        require(request.headers.getFirst("upgrade") == Some("wirestack-echo"),
            "generic Upgrade protocol was not preserved")
        request.body.close()
        HttpServerResponse(HttpResponse(101, "Switching Protocols", ResponseBody.empty(),
            headers: HttpHeaders(entries: [
                HttpHeader("Connection", "Upgrade"), HttpHeader("Upgrade", "wirestack-echo")
            ])), duplexHandler: Some<HttpDuplexHandler>(echo))
    }
}
func runUpgradeHttp1(): Unit {
    let server = HttpServer.builder().listen(loopback(0)).handler(UpgradeHandler()).build()
    let serving: Future<Unit> = spawn { server.serve() }
    let client = localClient(server, "upgrade.test").build()
    try {
        let request = HttpRequest(HttpMethod("GET"),
            HttpUrl.parse("http://upgrade.test:${server.localEndpoint.port}/upgrade"),
            headers: HttpHeaders(entries: [
                HttpHeader("Connection", "Upgrade"), HttpHeader("Upgrade", "wirestack-echo")
            ]))
        let connection = match (client.upgrade(request, protocol: Some("wirestack-echo"),
            context: boundedContext())) {
            case HttpUpgradeResult.Connected(value) => value
            case HttpUpgradeResult.Rejected(response) =>
                let status = response.status
                response.close()
                throw Exception("generic Upgrade rejected with ${status}")
        }
        try {
            require(connection.status == 101 && connection.version == HttpVersion.Http11,
                "generic Upgrade response metadata changed")
            require(connection.headers.getFirst("upgrade") == Some("wirestack-echo"),
                "generic Upgrade response protocol changed")
            api.writeAll(connection.transport, api.ByteSpan("ping".toArray()), context: boundedContext())
            let response = Array<Byte>(4, repeat: 0u8)
            api.readExact(connection.transport, api.MutableByteSpan(response), context: boundedContext())
            require(response == "pong".toArray(), "generic Upgrade response bytes changed")
            connection.close()
            require(connection.isClosed(), "generic Upgrade close did not become terminal")
        } finally { connection.close() }
    } finally {
        client.close()
        stopServer(server, serving)
    }
    announce("UPGRADE_HTTP1_PASS")
}

class SocketHandler <: HttpServerHandler & WebSocketHandler {
    private let secure: Bool
    init(secure: Bool) { this.secure = secure }

    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        if (request.target == "/sibling") {
            request.body.close()
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        if (request.target == "/push") {
            require(request.version == HttpVersion.Http2, "push parent did not use HTTP/2")
            require(request.authority.startsWith("example.com:"),
                "request authority did not retain the explicit host and port")
            request.body.close()
            request.push(HttpRequest.get("https://${request.authority}/asset"),
                HttpServerResponse(HttpResponse(200, "OK",
                    ResponseBody(RequestBody.bytes(Array<Byte>(NATIVE_PUSH_BYTES, repeat: b'p')).open()),
                    headers: HttpHeaders(entries: [HttpHeader("Content-Length", "${NATIVE_PUSH_BYTES}")]))))
            return HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
        }
        if (secure) {
            require(request.version == HttpVersion.Http2 && request.protocol == Some("websocket"),
                "secure WebSocket did not use HTTP/2 extended CONNECT")
        } else {
            require(request.version == HttpVersion.Http11 && request.protocol.isNone(),
                "cleartext WebSocket did not use HTTP/1.1 Upgrade")
        }
        HttpServerResponse.webSocket(request, this, subProtocol: Some("echo"))
    }

    public func serve(connection: WebSocketConnection, context: OperationContext): Unit {
        let frame = connection.receive(context: context)
        require(isBinary(frame.opcode), "WebSocket binary opcode changed")
        connection.send(WebSocketFrame(WebSocketOpcode.Binary, payload: frame.payload), context: context)
        let closing = connection.receive(context: context)
        require(isClose(closing.opcode), "WebSocket graceful close was not received")
    }
}

func connectedSocket(result: WebSocketConnectResult): WebSocketConnection {
    match (result) {
        case WebSocketConnectResult.Connected(value) => value
        case WebSocketConnectResult.Rejected(response) =>
            let status = response.status
            response.close()
            throw Exception("WebSocket handshake rejected with ${status}")
    }
}
func exchangeAndClose(session: WebSocketConnection): Unit {
    try {
        require(session.subProtocol == Some("echo"), "WebSocket subprotocol changed")
        let payload: Array<Byte> = [0u8, 255u8, 17u8, 128u8]
        session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: payload), context: boundedContext())
        let echoed = session.receive(context: boundedContext())
        require(isBinary(echoed.opcode) && echoed.payload == payload,
            "WebSocket binary exchange changed")
        session.close(1000u16, "done", context: boundedContext())
        require(session.isClosed(), "WebSocket graceful close did not become terminal")
    } finally { session.close() }
}
func runWebSocketHttp1(): Unit {
    let server = HttpServer.builder().listen(loopback(0)).handler(SocketHandler(false)).build()
    let serving: Future<Unit> = spawn { server.serve() }
    let client = localClient(server, "socket.test").build()
    try {
        let session = connectedSocket(client.connectWebSocket(HttpUrl.parse(
            "http://socket.test:${server.localEndpoint.port}/socket"),
            protocols: ["echo"], context: boundedContext()))
        exchangeAndClose(session)
    } finally {
        client.close()
        stopServer(server, serving)
    }
    announce("WEBSOCKET_HTTP1_PASS")
}

func runWebSocketHttp2Push(): Unit {
    let certificate = testCertificateDer()
    let serverTls = HttpServerTlsConfig([certificate], testPrivateKeyDer())
    let server = HttpServer.builder().listen(loopback(0)).handler(SocketHandler(true))
        .tls(serverTls).http2StreamLimit(8u32).build()
    let serving: Future<Unit> = spawn { server.serve() }
    let clientTls = HttpClientTlsConfig([certificate])
    let client = localClient(server, "example.com").tls(clientTls)
        .http2Push(Http2PushConfig(SameOriginHttp2PushPolicy(),
            maximumConcurrentPushes: 2, maximumPendingPushes: 2, maximumPushesPerRequest: 2))
        .build()
    let base = "https://example.com:${server.localEndpoint.port}"
    try {
        let session = connectedSocket(client.connectWebSocket(HttpUrl.parse("${base}/socket"),
            protocols: ["echo"], context: boundedContext()))
        try {
            let payload: Array<Byte> = [0u8, 255u8, 17u8, 128u8]
            session.send(WebSocketFrame(WebSocketOpcode.Binary, payload: payload), context: boundedContext())
            let echoed = session.receive(context: boundedContext())
            require(isBinary(echoed.opcode) && echoed.payload == payload,
                "HTTP/2 WebSocket binary exchange changed")

            let parent = client.get("${base}/push", context: boundedContext())
            try {
                require(parent.version == HttpVersion.Http2 && parent.status == 204,
                    "HTTP/2 push parent metadata changed")
                require(parent.body.read(Array<Byte>(1, repeat: 0u8)) == 0,
                    "HTTP/2 push parent did not reach EOF")
                let pushed = parent.pushes.getOrThrow().receive(context: boundedContext()).getOrThrow()
                try {
                    require(pushed.request.url.toString() == "${base}/asset",
                        "same-origin pushed URL lost the parent authority")
                    require(pushed.response.version == HttpVersion.Http2,
                        "pushed response did not use HTTP/2")
                    requireLargePushBody(pushed.response.body)
                } finally { pushed.close() }
            } finally { parent.close() }

            let sibling = client.get("${base}/sibling", context: boundedContext())
            try { require(sibling.status == 204 && sibling.version == HttpVersion.Http2,
                "HTTP/2 sibling became unusable after parent EOF and push delivery") }
            finally { sibling.close() }

            session.close(1000u16, "done", context: boundedContext())
            require(session.isClosed(), "HTTP/2 WebSocket close did not become terminal")
        } finally { session.close() }
    } finally {
        client.close()
        stopServer(server, serving)
        clientTls.close()
        serverTls.close()
    }
    announce("WEBSOCKET_HTTP2_PUSH_PASS")
}

// Test-only self-signed identity for example.com, valid 2026-08-23 to 2036-08-20.
func testCertificateDer(): Array<Byte> {
    decodeBase64("MIIDQzCCAiugAwIBAgIUDZ6pPmV6gcjC9tTovgITROZDWi4wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzIwMTkyOFoXDTM2MDgyMDIwMTkyOFowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQABo4GAMH4wHQYDVR0OBBYEFOdUzp+rhoI4EOD+k/HiZeHgTdcEMB8GA1UdIwQYMBaAFOdUzp+rhoI4EOD+k/HiZeHgTdcEMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALHiaFne/TJfVzznruLWTPKpQV/+dZKhPw8X2umZ1fLd6/sD2xtoeDof2IOx+HqQJuQNFNY8lAHsCb5J72/O5rXBhHHbYxwTL/LuAo9fKbCCwxp10Y5gwPrEcl5T1ZlsAgPTKq10ONwNR03wefE6epejITvX2nCNJUiaf3BWzFiq5xsZXfUHoil/AqAJfqnAgiABoOs/ZxErf0q16Apr4rjFvreAwsiYr1YgJ4aL97j3jCvJUNreGr8TNUBachUSrRvWcOOTaw90eex/6DnvU1EHDknlmcuuzywawVNzrTd10EuHimVfJgo1hRSzXd4deCHKStlYkPKZpwU/M+Al8F0=")
}
func testPrivateKeyDer(): Array<Byte> {
    decodeBase64("MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDf4gLNUdpDz5zPF5X9p6D+IAiDCGpjK1FVzXv8Fjdd0u1hJob07rBjG2qbnNm9y6NyXfm9K0QQhzpGxelDEBTManoarXb0xMPN3JblrvHrdtYLpmWHpKkLjMV23/EYmKwnD8dLgsctcrNCJLAdk/AU3vM5nQkwCHTkEsXjIQ7CRuKphRHeLvPTBW29QW4vc0AZ9lfNdjUdGL5B+b+H2VusyZC2beQEYGZlSHwBKq6Bx+IIzOJhhjXKBnDUwALEnrSdF++rXBhVl1SaIPZYQPg0XRUrny0/+onQqcrP8jaDgZxXle7W0f/Y1hojxhPZ6MhCfpODBhY37cdpd7dDzcNDAgMBAAECggEAKz/5o5l27VerptQbHTPnZYBhtJKJHtxM66L1GzddfcoUIorzUljUCWlP+HzeEYzH5/2gk7tKfFjrWKW+EL8IDY9aRFITY2ipnNjK69cWlBLSedCs133nTDxnHzZW2JYR17/0E7HRcYWxfIsi3KvqGtYRLaWZE0bm8fJweRa3R69WXYsZOYDK1CDMmrGZ572+5thDTVaiQKOOUBPNgucnB894rYtLYs98sb+2h4EUHZ0cQCIBUVdwu6BAFMwiAEtz2CClwA1G2fq59A9mqQXSkj8WaUHUgo9WcExt6pBEb5MPca+BHWz/aqdC9HRKQFBl3kn4h0qEGkLSy0WrMLKm7QKBgQD6fmd1BDrlsgbLoai3NnrnqKVbn8+0vnJjmTTykxeYHQXxBt3fzH+t42crJowQbuLeoO20oUY0VU8eQVh7bWvduucfFqrecLCL6GhhAFxp2dMjgOdvIim3QN9kvTSUlwOYchA43RTA7wWSzUf1+bL1XWs5bUNg5azpN0Btkma5xQKBgQDkzdwslfjcZgOp1QX2oSPOaA1VuOEJnr3+I2SR8FNH+bVwfbrilF5Mm08jHHHgoqgnGZLG7GLIgQAU1PmIr84hB7CE3JM9xXJ3t0jZ7BktfJEHLzog2Dr6vzXGT+yDcd2q1Lr3GL6x18Y+kgv6ieLv047SOBLal4o8iEjj9PZBZwKBgQCEzx4VKZ/8hq4ZquVj9iulxYGemZWrc8n8So+LCTfaO5EZ4JUkgi0zyby6YR6j29bHSLWfLl6lgpGHLgg2sKYfEmhV0FPZyg+griEhROq6aHYMfdy2zHsnoOqQY8yL96E9Y0R8kaLeRBxFYDeGD9S1SMl/0hGGP1+06slrDtMOLQKBgQCGArDviFN/O1zv7u4UOuNO9JDC4Ysk6E4deLth4uHUaURFA88fAImO0vRx+yoTyRE1/XuDeVaOW0gh62/QCDByFh/kYZD4ABqAVeCcivVgN/J1w8qHDD7XOIEViyBbCKktcnWjXmHqphfd9AqCDprVnxKqu98HGvUDaUtQANzvBwKBgQDJkuAOZocXTl77PfxDWfsP57StrsiuL+AvoH2FscRcT19e9T2U4YuCsyVydRM+gjUoJX5VPedIo+/gcvJrQcJIfwzZlqMMEJnYcWjoG8GYVtub9/xxSPmfuyj3GDbXEcirKkmGOmI5hPEP2UIasTUeljm8sHSP2B52kyKmdVGuUg==")
}
func decodeBase64(value: String): Array<Byte> {
    let output = ArrayList<Byte>()
    var accumulator: Int64 = 0
    var bits: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == b'=') { break }
        let decoded: Int64 = if (byte >= b'A' && byte <= b'Z') { Int64(byte - b'A') }
        else if (byte >= b'a' && byte <= b'z') { Int64(byte - b'a') + 26 }
        else if (byte >= b'0' && byte <= b'9') { Int64(byte - b'0') + 52 }
        else if (byte == b'+') { 62 }
        else if (byte == b'/') { 63 }
        else { throw IllegalArgumentException("invalid TLS fixture") }
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

main(arguments: Array<String>): Int64 {
    require(arguments.size == 1, "expected exactly one native HTTP scenario argument")
    match (arguments[0]) {
        case "cookies-hooks" => runCookiesHooks()
        case "files-multipart" => runFilesMultipart()
        case "upgrade-http1" => runUpgradeHttp1()
        case "websocket-http1" => runWebSocketHttp1()
        case "websocket-http2-push" => runWebSocketHttp2Push()
        case _ => throw IllegalArgumentException("unknown native HTTP scenario")
    }
    0
}
