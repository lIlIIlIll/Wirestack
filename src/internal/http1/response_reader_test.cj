package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1ResponseReaderTest {
    @TestCase
    func readsInterimAndFixedResponseWithoutBufferingTheBody(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 5)
        let wire = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello"
        writeAll(server, ByteSpan(wire.toArray()))
        let observer = ReaderBodyObserver()

        let result = readHttp1Response(client, HttpMethod("POST"), observer: observer)
        @Expect(result.interimResponses.size, 1)
        @Expect(result.interimResponses[0].status, 100)
        @Expect(result.response.status, 200)
        @Expect(result.response.headers.getFirst("x-test"), Some("yes"))
        @Expect(readReaderBody(result.response.body), "hello")
        @Expect(observer.completedCount, 1)
        @Expect(observer.abandonedCount, 0)
    }

    @TestCase
    func decodesChunkedResponseAndPublishesTrailerAtEof(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 2)
        let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\nDigest: done\r\n\r\n"
        writeAll(server, ByteSpan(wire.toArray()))

        let result = readHttp1Response(client, HttpMethod("GET"))
        @Expect(readReaderBody(result.response.body), "hello")
        let trailer = match (result.response.body.trailer) {
            case Some(value) => value
            case None => throw Exception("missing decoded response trailer")
        }
        @Expect(trailer.headers.getFirst("digest"), Some("done"))
    }

    @TestCase
    func closeDelimitedBodyCompletesOnlyAtTransportEof(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 4)
        writeAll(server, ByteSpan("HTTP/1.1 200 OK\r\n\r\nclose-body".toArray()))
        server.shutdown(ShutdownDirection.Write)
        let observer = ReaderBodyObserver()

        let result = readHttp1Response(
            client, HttpMethod("GET"),
            limits: HttpLimits(maxBodyBytes: 10), observer: observer
        )
        @Expect(readReaderBody(result.response.body), "close-body")
        @Expect(observer.completedCount, 1)
    }

    @TestCase
    func prematureFixedBodyEofAbandonsResponseExactlyOnce(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        writeAll(server, ByteSpan("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nno".toArray()))
        server.shutdown(ShutdownDirection.Write)
        let observer = ReaderBodyObserver()
        let result = readHttp1Response(client, HttpMethod("GET"), observer: observer)

        var failed = false
        try {
            let _ = readReaderBody(result.response.body)
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.UnexpectedEof => failed = true
                case _ => ()
            }
        }
        @Expect(failed)
        @Expect(result.response.body.isClosed())
        @Expect(observer.abandonedCount, 1)
    }

    @TestCase
    func rejectsImplicitUpgradeAndConnectTransportTransfer(): Unit {
        for (response in [
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: test\r\n\r\n",
            "HTTP/1.1 200 Connection Established\r\n\r\n"
        ]) {
            let (client, server) = MemoryTransport.pair(capacity: 2048)
            writeAll(server, ByteSpan(response.toArray()))
            var rejected = false
            try {
                let method = if (response.contains("Established")) { HttpMethod("CONNECT") } else { HttpMethod("GET") }
                let _ = readHttp1Response(client, method)
            } catch (_: Http1ParseException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }
}

private class ReaderBodyObserver <: ResponseBodyObserver {
    var completedCount: Int64 = 0
    var abandonedCount: Int64 = 0
    public func completed(): Unit { completedCount++ }
    public func abandoned(): Unit { abandonedCount++ }
}

private func readReaderBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(3, repeat: 0)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}
