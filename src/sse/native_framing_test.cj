package wirestack.sse

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.*
import wirestack.http.{HttpClient, HttpException, HttpErrorCode}
import wirestack.net.TcpListener

@Test
class SseNativeFramingTest {
    @TestCase
    func malformedChunkSizeIsFatalRatherThanAnAutomaticGetReconnect(): Unit {
        withSseRawPeer("Transfer-Encoding: chunked\r\n", "zz\r\n", { client, url =>
            let session = SseSession.eventSource(client, url, policy: SseSessionPolicy(maximumReconnects: 3))
            try {
                var invalid = false
                try { let _ = session.receive() }
                catch (error: HttpException) {
                    invalid = match (error.code) { case HttpErrorCode.InvalidFraming => true; case _ => false }
                    @Expect(error.cause.isSome())
                }
                @Expect(invalid)
                @Expect(session.reconnectCount, 0)
                @Expect(client.resourceSnapshot().activeRequests, 0)
                @Expect(client.resourceSnapshot().managedBufferBytes, 0u64)
            } finally { session.close() }
        })
    }

    @TestCase
    func prematureChunkEofRetainsTypedCauseAndNeverReplaysPost(): Unit {
        withSseRawPeer("Transfer-Encoding: chunked\r\n", "8\r\ndata:x\n\n\r\n", { client, url =>
            let session = SseSession.oneShot(client,
                HttpRequest(HttpMethod("POST"), url, retrySafety: HttpRetrySafety.ExplicitlySafe),
                policy: SseSessionPolicy(maximumReconnects: 3))
            try {
                @Expect(session.receive().getOrThrow().data, "x")
                var premature = false
                try { let _ = session.receive() }
                catch (error: SseException) {
                    @Expect(error.code, SseErrorCode.ReconnectLimit)
                    match (error.cause.getOrThrow()) {
                        case value: NetworkException =>
                            premature = match (value.code) { case NetworkErrorCode.UnexpectedEof => true; case _ => false }
                            @Expect(value.cause.isSome())
                        case _ => @Fail("premature EOF lost its typed network cause")
                    }
                }
                @Expect(premature)
                @Expect(session.reconnectCount, 0)
                @Expect(client.resourceSnapshot().activeRequests, 0)
                @Expect(client.resourceSnapshot().managedBufferBytes, 0u64)
            } finally { session.close() }
        })
    }

    @TestCase
    func absentContentTypeIsTypedInvalidResponseNotAnIndexFailure(): Unit {
        withSseRawPeer("Content-Length: 0\r\n", "", { client, url =>
            let session = SseSession.eventSource(client, url)
            try {
                var invalid = false
                try { let _ = session.receive() }
                catch (error: SseException) { invalid = error.code == SseErrorCode.InvalidResponse }
                @Expect(invalid)
                @Expect(session.reconnectCount, 0)
                @Expect(client.resourceSnapshot().managedBufferBytes, 0u64)
            } finally { session.close() }
        }, mime: false)
    }
}

private func withSseRawPeer(framing: String, payload: String,
    consume: (HttpClient, HttpUrl) -> Unit, mime!: Bool = true): Unit {
    let listener = TcpListener.bind(SocketEndpoint(IpAddress(IpAddressFamily.Ipv4,
        [127u8, 0u8, 0u8, 1u8]), 0u16), backlog: 1)
    let context = OperationContext(deadline: Some(Deadline.after(2 * Duration.second)))
    let serving = spawn {
        let peer = listener.accept(context: context)
        try {
            let request = Array<Byte>(8192, repeat: 0u8)
            var received: Int64 = 0
            while (true) {
                if (received == request.size) { throw IllegalStateException("raw SSE request headers exceed fixture bound") }
                match (peer.readSome(MutableByteSpan(request, offset: received), context: context)) {
                    case ReadResult.Data(count) => received += count
                    case ReadResult.EndOfStream => throw IllegalStateException("raw SSE request ended before headers")
                }
                if (String.fromUtf8(request[0..received]).contains("\r\n\r\n")) { break }
            }
            let contentType = if (mime) { "Content-Type: text/event-stream\r\n" } else { "" }
            peer.writeAll(ByteSpan(("HTTP/1.1 200 OK\r\n" + contentType + framing +
                "Connection: close\r\n\r\n" + payload).toArray()), context: context)
        } finally { peer.close() }
    }
    let client = HttpClient.builder().resolver(StaticResolver(ResolveResult([listener.localEndpoint.address],
        HostName("example.com"), ResolverSource.Static))).build()
    try {
        consume(client, HttpUrl.parse("http://example.com:" + listener.localEndpoint.port.toString() + "/events"))
        serving.get(3 * Duration.second)
    } finally { client.close(); listener.close() }
}
