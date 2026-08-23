package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1ClientConnectionTest {
    @TestCase
    func serializesRequestsUntilBodyEofThenReusesConnection(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 3)
        let served: Future<Bool> = spawn {
            let first = readConnectionTestRequest(server)
            writeAll(server, ByteSpan("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toArray()))
            let second = readConnectionTestRequest(server)
            writeAll(server, ByteSpan("HTTP/1.1 204 No Content\r\n\r\n".toArray()))
            first.target == "/one" && second.target == "/two"
        }
        let connection = Http1ClientConnection(client)

        let first = connection.execute(HttpRequest.get("http://example.com/one"))
        @Expect(isConnectionState(connection.currentState(), Http1ClientConnectionState.AwaitingBody))
        var pipeliningRejected = false
        try {
            let _ = connection.execute(HttpRequest.get("http://example.com/forbidden"))
        } catch (_: Http1ClientConnectionException) {
            pipeliningRejected = true
        }
        @Expect(pipeliningRejected)
        @Expect(readConnectionBody(first.response.body), "ok")
        @Expect(isConnectionState(connection.currentState(), Http1ClientConnectionState.Ready))

        let second = connection.execute(HttpRequest.get("http://example.com/two"))
        @Expect(second.response.status, 204)
        @Expect(isConnectionState(connection.currentState(), Http1ClientConnectionState.Ready))
        @Expect(served.get(Duration.second))
        connection.close()
    }

    @TestCase
    func earlyBodyCloseClosesInsteadOfReturningConnectionForReuse(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let served: Future<Unit> = spawn {
            let _ = readConnectionTestRequest(server)
            writeAll(server, ByteSpan("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata".toArray()))
        }
        let connection = Http1ClientConnection(client)
        let result = connection.execute(HttpRequest.get("http://example.com/"))

        result.response.close()
        @Expect(connection.isClosed())
        @Expect(isConnectionState(connection.currentState(), Http1ClientConnectionState.Closed))
        served.get(Duration.second)
    }

    @TestCase
    func connectionCloseResponseIsNeverReusableAfterEof(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let served: Future<Unit> = spawn {
            let _ = readConnectionTestRequest(server)
            writeAll(server, ByteSpan(
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toArray()
            ))
        }
        let connection = Http1ClientConnection(client)
        let result = connection.execute(HttpRequest.get("http://example.com/"))

        @Expect(readConnectionBody(result.response.body), "ok")
        @Expect(connection.isClosed())
        served.get(Duration.second)
    }
}

private func readConnectionTestRequest(transport: DuplexTransport): Http1RequestHead {
    let parser = Http1RequestHeadParser()
    while (true) {
        let buffer = Array<Byte>(32, repeat: 0)
        match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
            case ReadResult.Data(count) =>
                let input = Array<Byte>(count, repeat: 0)
                for (index in 0..count) { input[index] = buffer[index] }
                if (let Some(parsed) <- parser.feed(input)) { return parsed.head }
            case ReadResult.EndOfStream => throw Exception("client closed before request head")
        }
    }
    throw Exception("unreachable request reader loop")
}

private func readConnectionBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(2, repeat: 0)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func isConnectionState(left: Http1ClientConnectionState, right: Http1ClientConnectionState): Bool {
    match ((left, right)) {
        case (Http1ClientConnectionState.Ready, Http1ClientConnectionState.Ready) => true
        case (Http1ClientConnectionState.Exchanging, Http1ClientConnectionState.Exchanging) => true
        case (Http1ClientConnectionState.AwaitingBody, Http1ClientConnectionState.AwaitingBody) => true
        case (Http1ClientConnectionState.Closed, Http1ClientConnectionState.Closed) => true
        case (Http1ClientConnectionState.Failed, Http1ClientConnectionState.Failed) => true
        case _ => false
    }
}
