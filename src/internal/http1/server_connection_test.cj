package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1ServerConnectionTest {
    @TestCase
    func serializesTwoKeepAliveExchanges(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 3)
        let running: Future<Http1ServerConnectionResult> = spawn {
            serveHttp1Connection(server, EchoServerHandler(), maximumRequests: 2)
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
}

private class EchoServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest): Http1ServerResponse {
        let bytes = readServerConnectionBytes(request.body)
        Http1ServerResponse(HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes(bytes).open()),
            headers: HttpHeaders.builder().add("Content-Length", "${bytes.size}").build()))
    }
}

private class RejectingServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest): Http1ServerResponse {
        let _ = request
        Http1ServerResponse(HttpResponse(403, "Forbidden", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()))
    }
}

private class FailingServerHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest): Http1ServerResponse {
        let _ = request
        throw Exception("handler failed")
    }
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
