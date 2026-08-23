package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1ServerRequestReaderTest {
    @TestCase
    func streamsFixedRequestBodyWithoutReadingPastItsLength(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 3)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "4").build(),
            body: RequestBody.bytes("data".toArray())
        )
        let written: Future<Unit> = spawn { let _ = writeHttp1Request(client, request) }
        let incoming = readHttp1ServerRequest(server)
        @Expect(incoming.head.target, "/upload")
        @Expect(readServerBody(incoming.body), "data")
        written.get(Duration.second)
        client.close()
        server.close()
    }

    @TestCase
    func decodesChunkedRequestAndPublishesTrailer(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 4)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Transfer-Encoding", "chunked").build(),
            body: RequestBody.replayableFactory(None<Int64>, { => ServerTestBody("body".toArray()) })
        )
        let trailer = HttpTrailer(headers: HttpHeaders.builder().add("Digest", "done").build())
        let written: Future<Unit> = spawn { let _ = writeHttp1Request(client, request, trailer: trailer) }
        let incoming = readHttp1ServerRequest(server)
        @Expect(readServerBody(incoming.body), "body")
        @Expect(incoming.body.trailer.getOrThrow().headers.getFirst("digest"), Some("done"))
        written.get(Duration.second)
        client.close()
        server.close()
    }

    @TestCase
    func sendsContinueOnlyWhenHandlerStartsReadingTheBody(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "4").add("Expect", "100-continue").build(),
            body: RequestBody.bytes("data".toArray())
        )
        let writer = Http1RequestWriter(request)
        let _ = writer.writeHead(client)
        let incoming = readHttp1ServerRequest(server)

        var timedOut = false
        try {
            let probe = Array<Byte>(1, repeat: 0)
            let _ = client.readSome(
                MutableByteSpan(probe),
                context: OperationContext(deadline: Some(Deadline.after(5 * Duration.millisecond)))
            )
        } catch (error: NetworkException) {
            match (error.code) { case NetworkErrorCode.TimedOut => timedOut = true; case _ => () }
        }
        @Expect(timedOut)

        let approved: Future<Bool> = spawn {
            let bytes = "HTTP/1.1 100 Continue\r\n\r\n".toArray()
            let received = Array<Byte>(bytes.size, repeat: 0)
            readExact(client, MutableByteSpan(received))
            let _ = writer.writeBody(client)
            received == bytes
        }
        @Expect(readServerBody(incoming.body), "data")
        @Expect(approved.get(Duration.second))
        client.close()
        server.close()
    }

    @TestCase
    func rejectingWithoutReadingNeverSendsContinue(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "4").add("Expect", "100-continue").build(),
            body: RequestBody.bytes("data".toArray())
        )
        let writer = Http1RequestWriter(request)
        let _ = writer.writeHead(client)
        let incoming = readHttp1ServerRequest(server)
        incoming.close()
        writeSerializedHead(
            server,
            serializeResponseHead(417, "Expectation Failed", HttpHeaders.builder().add("Content-Length", "0").build(), request.method)
        )
        let expected = "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(client, MutableByteSpan(received))
        @Expect(received, expected)
        client.close()
        server.close()
    }
}

private class ServerTestBody <: HttpBodyStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    private var closed = false
    init(bytes: Array<Byte>) { this.bytes = bytes.clone() }
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw Exception("closed server test body") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func readServerBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(2, repeat: 0)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}
