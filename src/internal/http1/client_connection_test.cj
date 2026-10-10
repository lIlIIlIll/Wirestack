package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.{NetworkEndpoint}
import wirestack.internal.transport.*

@Test
class Http1ClientConnectionTest {
    @TestCase
    func expectContinueWaitsForApprovalBeforeOpeningBody(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096, maxChunk: 5)
        let body = ConnectionCountingBody("data".toArray())
        let served: Future<Bool> = spawn {
            let head = readConnectionTestRequest(server)
            writeAll(server, ByteSpan("HTTP/1.1 100 Continue\r\n\r\n".toArray()))
            let received = Array<Byte>(4, repeat: 0)
            readExact(server, MutableByteSpan(received))
            writeAll(server, ByteSpan("HTTP/1.1 204 No Content\r\n\r\n".toArray()))
            head.target == "/upload" && received == "data".toArray()
        }
        let request = expectContinueRequest(RequestBody.oneShot(body))
        let result = Http1ClientConnection(client).execute(request)
        @Expect(result.response.status, 204)
        @Expect(body.readCalls > 0)
        @Expect(served.get(Duration.second))
    }

    @TestCase
    func finalRejectionBeforeContinueNeverOpensRequestBody(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let body = ConnectionCountingBody("data".toArray())
        let served: Future<Unit> = spawn {
            let _ = readConnectionTestRequest(server)
            writeAll(server, ByteSpan("HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n".toArray()))
        }
        let connection = Http1ClientConnection(client)
        let result = connection.execute(expectContinueRequest(RequestBody.oneShot(body)))
        @Expect(result.response.status, 417)
        @Expect(body.readCalls, 0)
        @Expect(isConnectionState(connection.currentState(), Http1ClientConnectionState.Ready))
        served.get(Duration.second)
        connection.close()
    }

    @TestCase
    func continueWaitTimeoutSendsBodyUnderTheOriginalBudget(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let served: Future<Bool> = spawn {
            let _ = readConnectionTestRequest(server)
            let received = Array<Byte>(4, repeat: 0)
            readExact(server, MutableByteSpan(received))
            writeAll(server, ByteSpan("HTTP/1.1 204 No Content\r\n\r\n".toArray()))
            received == "data".toArray()
        }
        let connection = Http1ClientConnection(client, continueTimeout: 10 * Duration.millisecond)
        let result = connection.execute(expectContinueRequest(RequestBody.bytes("data".toArray())))
        @Expect(result.response.status, 204)
        @Expect(served.get(Duration.second))
        connection.close()
    }

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
    @TestCase
    func executionFailurePreservesNetworkErrorEvidence(): Unit {
        let local = SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8]), 32100)
        let remote = SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [198u8, 51u8, 100u8, 2u8]), 443)
        let underlying = Exception("socket read failed")
        let cause = NetworkException(
            NetworkErrorCategory.Read, NetworkPhase.HttpHeaders,
            NetworkErrorCode.UnexpectedEof, "response read failed",
            retryability: Retryability.Temporary, nativeCode: Some<Int64>(54),
            localEndpoint: Some(NetworkEndpoint.Internet(local)),
            remoteEndpoint: Some(NetworkEndpoint.Internet(remote)),
            cause: Some<Exception>(underlying)
        )
        let wrapped = Http1RequestExecutionException(Http1RequestCommitEvidence(21, 5), cause)

        match (wrapped.category) {
            case NetworkErrorCategory.Read => ()
            case _ => @Fail("network error category was not preserved")
        }
        match (wrapped.phase) {
            case NetworkPhase.HttpHeaders => ()
            case _ => @Fail("network phase was not preserved")
        }
        match (wrapped.code) {
            case NetworkErrorCode.UnexpectedEof => ()
            case _ => @Fail("network error code was not preserved")
        }
        match (wrapped.retryability) {
            case Retryability.Temporary => ()
            case _ => @Fail("retryability was not preserved")
        }
        @Expect(wrapped.nativeCode, Some<Int64>(54))
        match (wrapped.localEndpoint) {
            case Some(NetworkEndpoint.Internet(endpoint)) => @Expect(endpoint.port, 32100)
            case _ => @Fail("expected preserved local endpoint")
        }
        match (wrapped.remoteEndpoint) {
            case Some(NetworkEndpoint.Internet(endpoint)) => @Expect(endpoint.port, 443)
            case _ => @Fail("expected preserved remote endpoint")
        }
        @Expect(wrapped.evidence.wireBytesWritten, 21)
        @Expect(wrapped.evidence.bodyBytesWritten, 5)
        @Expect(wrapped.cause.getOrThrow().toString(), cause.toString())
        @Expect(cause.cause.getOrThrow().toString(), underlying.toString())
    }

    @TestCase
    func responseFailureCarriesCommittedRequestEvidence(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let served: Future<Bool> = spawn {
            let head = readConnectionTestRequest(server)
            server.close()
            head.target == "/eof"
        }
        let connection = Http1ClientConnection(client)
        var committedFailure = false
        try {
            let _ = connection.execute(HttpRequest.get("http://example.com/eof"))
        } catch (error: Http1RequestExecutionException) {
            committedFailure = error.evidence.requestCommitted &&
                error.evidence.wireBytesWritten > 0 && error.evidence.bodyBytesWritten == 0
        }

        @Expect(committedFailure)
        @Expect(served.get(Duration.second))
        @Expect(connection.isClosed())
        connection.close()
    }
}

private class ConnectionCountingBody <: HttpBodyStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    private var closed = false
    var readCalls: Int64 = 0
    init(bytes: Array<Byte>) { this.bytes = bytes.clone() }
    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }
    public func read(destination: Array<Byte>): Int64 {
        readCalls++
        if (closed) { throw Exception("closed connection test body") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func expectContinueRequest(body: RequestBody): HttpRequest {
    HttpRequest(
        HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
        headers: HttpHeaders.builder().add("Content-Length", "4").add("Expect", "100-continue").build(),
        body: body
    )
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
