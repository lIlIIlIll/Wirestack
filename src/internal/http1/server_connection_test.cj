package wirestack.internal.http1

import std.unittest.*
import wirestack as api
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1ServerConnectionTest {
    @TestCase
    func serializesTwoKeepAliveExchanges(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 3)
        let sink = api.NetworkEventBuffer(capacity: 256)
        let running: Future<Http1ServerConnectionResult> = spawn {
            serveHttp1Connection(server, EchoServerHandler(), maximumRequests: 2,
                context: OperationContext(eventSink: Some(sink), connectionId: Some(909),
                    timeoutPolicy: OperationTimeoutPolicy(responseHeaders: Some(Duration.nanosecond), requestWrite: Some(Duration.nanosecond))))
        }

        let first = HttpRequest(HttpMethod("POST"), HttpUrl.parse("http://example.com/one"),
            headers: HttpHeaders.builder().add("Content-Length", "3").build(),
            body: RequestBody.bytes("one".toArray()))
        let _ = writeHttp1Request(client, first)
        let firstResponse = readHttp1Response(client, first.method)
        @Expect(readServerConnectionBody(firstResponse.response.body), "one")

        let second = HttpRequest(HttpMethod("POST"), HttpUrl.parse("http://example.com/two"),
            headers: HttpHeaders.builder().add("Content-Length", "3").add("Connection", "close").build(),
            body: RequestBody.bytes("two".toArray()))
        let _ = writeHttp1Request(client, second)
        let secondResponse = readHttp1Response(client, second.method)
        @Expect(readServerConnectionBody(secondResponse.response.body), "two")
        let result = running.get(Duration.second)
        @Expect(result.requestsServed, 2)
        @Expect(!result.closedForUnreadRequestBody)
        var requestId = None<Int64>
        var starts: Int64 = 0
        var completions: Int64 = 0
        var headers: Int64 = 0
        for (event in sink.drain()) {
            @Expect(event.connectionId, Some(909))
            @Expect(event.requestId.isSome())
            match (event.kind) {
                case NetworkEventKind.BodyStarted =>
                    starts++
                    if (requestId.isSome()) { @Expect(event.requestId != requestId) }
                    requestId = event.requestId
                case NetworkEventKind.BodyCompleted => completions++; @Expect(event.requestId, requestId)
                case NetworkEventKind.StageStarted =>
                    match (event.phase) {
                        case Some(NetworkPhase.HttpHeaders) => headers++; @Expect(event.stage.isNone())
                        case Some(NetworkPhase.TcpWrite) => @Expect(event.stage.isNone())
                        case _ => ()
                    }
                case _ => ()
            }
        }
        @Expect(starts, 2); @Expect(completions, 2); @Expect(headers, 2)
        client.close()
    }

    @TestCase
    func unreadRequestBodyForcesConnectionCloseAfterResponse(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let running: Future<Http1ServerConnectionResult> = spawn {
            serveHttp1Connection(server, RejectingServerHandler())
        }
        let request = HttpRequest(HttpMethod("POST"), HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "4").add("Expect", "100-continue").build(),
            body: RequestBody.bytes("data".toArray()))
        let writer = Http1RequestWriter(request)
        let _ = writer.writeHead(client)
        let response = readHttp1Response(client, request.method)
        @Expect(response.response.status, 403)
        response.response.close()
        let result = running.get(Duration.second)
        @Expect(result.closedForUnreadRequestBody)
        @Expect(result.requestsServed, 1)
        client.close()
    }

    @TestCase
    func handlerFailureProducesBounded500AndCloses(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let running: Future<Http1ServerConnectionResult> = spawn {
            serveHttp1Connection(server, FailingServerHandler())
        }
        let request = HttpRequest.get("http://example.com/")
        let _ = writeHttp1Request(client, request)
        let response = readHttp1Response(client, request.method)
        @Expect(response.response.status, 500)
        @Expect(response.response.headers.getFirst("connection"), Some("close"))
        response.response.close()
        @Expect(running.get(Duration.second).requestsServed, 1)
        client.close()
    }

    @TestCase
    func rejectedHandoffReleasesSessionOwnershipExactlyOnce(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let handler = InvalidHandoffServerHandler()
        let request = HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "echo").build())
        try {
            let _ = writeHttp1Request(client, request)
            let result = serveHttp1Connection(server, handler)
            let response = readHttp1Response(client, request.method)
            try { @Expect(response.response.status, 500) } finally { response.response.close() }
            @Expect(result.requestsServed, 1)
            @Expect(handler.failedCalls, 1)
            @Expect(server.isClosed())
        } finally { client.close(); server.close() }
    }

    @TestCase
    func selectedUpgradeOfferTransfersBufferedSessionBytes(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let running = spawn { serveHttp1Connection(server, SelectedUpgradeServerHandler()) }
        try {
            let request = HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://example.com/"),
                headers: HttpHeaders.builder().add("Connection", "Upgrade")
                    .add("Upgrade", "other/1, WebSocket").add("Upgrade", "fallback").build())
            let connected = match (performHttp1Upgrade(client, request,
                context: OperationContext(deadline: Some(Deadline.after(2 * Duration.second))))) {
                case Http1UpgradeExchangeResult.Upgraded(value) => value
                case _ => throw Exception("valid offered Upgrade was rejected")
            }
            let payload = Array<Byte>(7, repeat: 0)
            readExact(connected.transport, MutableByteSpan(payload),
                context: OperationContext(deadline: Some(Deadline.after(2 * Duration.second))))
            @Expect(connected.protocol, "websocket")
            @Expect(payload, "session".toArray())
            connected.transport.close()
            @Expect(running.get(2 * Duration.second).requestsServed, 1)
        } finally { client.close(); server.close() }
    }
    @TestCase
    func bodylessRequestAndResponseEmitResponseBodyLifecycleWithoutATransfer(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let sink = api.NetworkEventBuffer(capacity: 128)
        let running = spawn {
            serveHttp1Connection(server, BodylessServerHandler(), maximumRequests: 1,
                context: OperationContext(eventSink: Some<NetworkEventSink>(sink), connectionId: Some(911)))
        }
        let request = HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://example.com/empty"),
            headers: HttpHeaders.builder().add("Connection", "close").build())
        let _ = writeHttp1Request(client, request)
        let response = readHttp1Response(client, request.method)
        @Expect(response.response.status, 200)
        @Expect(response.response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
        response.response.close()
        @Expect(running.get(Duration.second).requestsServed, 1)
        var started: Int64 = 0
        var completed: Int64 = 0
        var requestId = None<Int64>
        for (event in sink.drain()) {
            match (event.kind) {
                case NetworkEventKind.BodyStarted =>
                    started++; requestId = event.requestId
                case NetworkEventKind.BodyCompleted =>
                    completed++
                    @Expect(event.requestId, requestId)
                    @Expect(event.outcome, NetworkEventOutcome.Succeeded)
                    @Expect(event.errorCode.isNone())
                case _ => ()
            }
        }
        // The request body has no transfer lifecycle; only the returned response body does.
        @Expect(started, 1); @Expect(completed, 1)
        client.close()
    }

    @TestCase
    func streamingResponseFailureClosesTheBodyLifecycleAsFailed(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 64, maxChunk: 8)
        let sink = api.NetworkEventBuffer(capacity: 128)
        let reading = spawn {
            try {
                let response = readHttp1Response(client, HttpMethod("GET"))
                response.response.close()
            } catch (_: Exception) {}
            true
        }
        // The server owns the write failure; the peer only observes the truncated response.
        let error = @AssertThrows[Http1ResponseWriteException](serveHttp1Connection(
            server, BrokenResponseBodyHandler(), maximumRequests: 1,
            context: OperationContext(eventSink: Some<NetworkEventSink>(sink), connectionId: Some(912))))
        match (error.code) {
            case Http1ResponseWriteErrorCode.WriteFailed => ()
            case _ => @Fail("broken response body lost its write failure")
        }
        @Expect(reading.get(Duration.second), true)
        var started: Int64 = 0
        var failedCompletions: Int64 = 0
        for (event in sink.drain()) {
            match (event.kind) {
                case NetworkEventKind.BodyStarted => started++
                case NetworkEventKind.BodyCompleted =>
                    @Expect(event.outcome, NetworkEventOutcome.Failed)
                    @Expect(event.errorCode.isSome())
                    failedCompletions++
                case _ => ()
            }
        }
        @Expect(started, 1); @Expect(failedCompletions, 1)
        client.close(); server.close()
    }

    @TestCase
    func unreadRequestBodyDoesNotProduceARequestBodyLifecycle(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let sink = api.NetworkEventBuffer(capacity: 64)
        let running: Future<Http1ServerConnectionResult> = spawn {
            serveHttp1Connection(server, RejectingServerHandler(), maximumRequests: 1,
                context: OperationContext(eventSink: Some<NetworkEventSink>(sink)))
        }
        let request = HttpRequest(HttpMethod("POST"), HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "4").add("Expect", "100-continue").build(),
            body: RequestBody.bytes("data".toArray()))
        let _ = Http1RequestWriter(request).writeHead(client)
        let response = readHttp1Response(client, request.method)
        @Expect(response.response.status, 403)
        response.response.close()
        @Expect(running.get(Duration.second).closedForUnreadRequestBody, true)
        var started: Int64 = 0
        var completed: Int64 = 0
        for (event in sink.drain()) {
            match (event.kind) {
                case NetworkEventKind.BodyStarted => started++
                case NetworkEventKind.BodyCompleted =>
                    // The unread inbound body must not surface as a discarded response body.
                    @Expect(event.outcome, NetworkEventOutcome.Succeeded)
                    @Expect(event.errorCode.isNone())
                    completed++
                case _ => ()
            }
        }
        @Expect(started, 1); @Expect(completed, 1)
        client.close()
    }
}

private class BodylessServerHandler <: Http1ServerHandler {
    public func handle(_: Http1ServerRequest, _: OperationContext): Http1ServerResponse {
        Http1ServerResponse(HttpResponse(200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()))
    }
}

private class BrokenResponseBodyHandler <: Http1ServerHandler {
    public func handle(_: Http1ServerRequest, _: OperationContext): Http1ServerResponse {
        Http1ServerResponse(HttpResponse(200, "OK", ResponseBody(BrokenStreamingBody()),
            headers: HttpHeaders.builder().add("Transfer-Encoding", "chunked").build()))
    }
}

private class BrokenStreamingBody <: HttpBodyStream {
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(_: Array<Byte>): Int64 {
        throw Exception("response body source failed")
    }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
}

private class EchoServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let bytes = readServerConnectionBytes(request.body)
        Http1ServerResponse(HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes(bytes).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${bytes.size}").build()))
    }
}

private class RejectingServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request
        Http1ServerResponse(HttpResponse(403, "Forbidden", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()))
    }
}

private class FailingServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request
        throw Exception("handler failed")
    }
}

private class InvalidHandoffServerHandler <: Http1ServerHandler & Http1DuplexHandler {
    var failedCalls: Int64 = 0
    public func handle(_: Http1ServerRequest, _: OperationContext): Http1ServerResponse {
        Http1ServerResponse(HttpResponse(101, "Switching Protocols", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "wrong").build()),
            duplexHandler: Some<Http1DuplexHandler>(this))
    }
    public func serve(_: DuplexTransport, _: OperationContext): Unit {
        throw Exception("invalid handshake must never enter the session")
    }
    public func failed(): Unit { failedCalls++ }
}

private class SelectedUpgradeServerHandler <: Http1ServerHandler & Http1DuplexHandler {
    public func handle(_: Http1ServerRequest, _: OperationContext): Http1ServerResponse {
        Http1ServerResponse(HttpResponse(101, "Switching Protocols", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "websocket").build()),
            duplexHandler: Some<Http1DuplexHandler>(this))
    }
    public func serve(transport: DuplexTransport, context: OperationContext): Unit {
        writeAll(transport, ByteSpan("session".toArray()), context: context)
    }
    public func failed(): Unit {}
}

private func readServerConnectionBytes(body: ResponseBody): Array<Byte> {
    let output = Array<Byte>(body.contentLength.getOrThrow(), repeat: 0)
    var offset: Int64 = 0
    while (offset < output.size) {
        let buffer = Array<Byte>(output.size - offset, repeat: 0)
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output[offset + index] = buffer[index] }
        offset += count
    }
    output
}

private func readServerConnectionBody(body: ResponseBody): String {
    let buffer = Array<Byte>(16, repeat: 0)
    let count = body.read(buffer)
    body.close()
    String.fromUtf8(serverConnectionPrefix(buffer, count))
}

private func serverConnectionPrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let result = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { result[index] = bytes[index] }
    result
}
