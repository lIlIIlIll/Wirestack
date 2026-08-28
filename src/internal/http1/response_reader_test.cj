package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1ResponseReaderTest {
    @TestCase
    func explicitUpgradeTransfersOnlyAMatching101Protocol(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 64)
        let served: Future<Bool> = spawn {
            let request = readReaderRequestHead(server)
            writeAll(server, ByteSpan(
                "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nxyz".toArray()
            ))
            request.target == "/chat"
        }
        let request = HttpRequest.get("http://example.com/chat").withHeaders(
            HttpHeaders.builder().add("Connection", "keep-alive, Upgrade").add("Upgrade", "websocket").build()
        )
        let exchanged = performHttp1Upgrade(client, request)
        let upgraded = match (exchanged) {
            case Http1UpgradeExchangeResult.Upgraded(value) => value
            case _ => throw Exception("expected HTTP Upgrade")
        }
        @Expect(upgraded.protocol, "websocket")
        let prefix = Array<Byte>(3, repeat: 0)
        readExact(upgraded.transport, MutableByteSpan(prefix))
        @Expect(prefix, "xyz".toArray())
        @Expect(served.get(Duration.second))
        upgraded.transport.close()
    }

    @TestCase
    func mismatchedUpgradeResponseFailsClosed(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        let served: Future<Unit> = spawn {
            let _ = readReaderRequestHead(server)
            writeAll(server, ByteSpan(
                "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: other\r\n\r\n".toArray()
            ))
        }
        let request = HttpRequest.get("http://example.com/").withHeaders(
            HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "websocket").build()
        )
        var rejected = false
        try { let _ = performHttp1Upgrade(client, request) } catch (_: Http1ParseException) { rejected = true }
        @Expect(rejected)
        @Expect(client.isClosed())
        served.get(Duration.second)
    }

    @TestCase
    func explicitConnectTransfersBufferedTunnelBytesAndTransportOwnership(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 64)
        let served: Future<Bool> = spawn {
            let request = readReaderRequestHead(server)
            writeAll(server, ByteSpan("HTTP/1.1 200 Connection Established\r\n\r\nabc".toArray()))
            let requestBytes = Array<Byte>(4, repeat: 0)
            readExact(server, MutableByteSpan(requestBytes))
            request.target == "example.com:443" && requestBytes == "ping".toArray()
        }
        let exchanged = performHttp1Connect(client, HttpUrl.parse("https://example.com/"))
        let tunnel = match (exchanged) {
            case Http1ConnectExchangeResult.Tunnel(value) => value
            case _ => throw Exception("expected CONNECT tunnel")
        }
        let prefix = Array<Byte>(3, repeat: 0)
        readExact(tunnel.transport, MutableByteSpan(prefix))
        @Expect(prefix, "abc".toArray())
        writeAll(tunnel.transport, ByteSpan("ping".toArray()))
        @Expect(served.get(Duration.second))
        tunnel.transport.close()
    }

    @TestCase
    func failedConnectRemainsAnHttpResponseAndClosesAfterBody(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        let served: Future<Bool> = spawn {
            let _ = readReaderRequestHead(server)
            writeAll(server, ByteSpan(
                "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 3\r\n\r\nbad".toArray()
            ))
            let probe = Array<Byte>(1, repeat: 0)
            match (server.readSome(MutableByteSpan(probe), context: OperationContext.background())) {
                case ReadResult.EndOfStream => true
                case _ => false
            }
        }
        let exchanged = performHttp1Connect(client, HttpUrl.parse("https://example.com/"))
        let response = match (exchanged) {
            case Http1ConnectExchangeResult.Response(value) => value.response
            case _ => throw Exception("expected CONNECT HTTP failure")
        }
        @Expect(response.status, 407)
        @Expect(readReaderBody(response.body), "bad")
        @Expect(served.get(Duration.second))
    }

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
    func received4xxAnd5xxRemainHttpResponses(): Unit {
        for (status in [404, 500]) {
            let (client, server) = MemoryTransport.pair(capacity: 2048)
            writeAll(server, ByteSpan(
                "HTTP/1.1 ${status} Received\r\nContent-Length: 0\r\n\r\n".toArray()
            ))

            let result = readHttp1Response(client, HttpMethod("GET"))
            @Expect(result.response.status, status)
            @Expect(result.response.body.read(Array<Byte>(1, repeat: 0)), 0)
            result.response.close()
            client.close()
            server.close()
        }
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
    func chunkedStreamingResponseMayExceedThePerSegmentBodyBound(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048, maxChunk: 3)
        let serving = spawn {
            writeAll(server, ByteSpan(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".toArray()
            ))
            writeAll(server, ByteSpan("2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n".toArray()))
        }
        let result = readHttp1Response(
            client, HttpMethod("GET"), limits: HttpLimits(maxBodyBytes: 2)
        )
        @Expect(readReaderBody(result.response.body), "abcd")
        serving.get(Duration.second)
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

private func readReaderRequestHead(transport: DuplexTransport): Http1RequestHead {
    let parser = Http1RequestHeadParser()
    while (true) {
        let buffer = Array<Byte>(128, repeat: 0)
        match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
            case ReadResult.Data(count) =>
                let input = Array<Byte>(count, repeat: 0)
                for (index in 0..count) { input[index] = buffer[index] }
                if (let Some(parsed) <- parser.feed(input)) { return parsed.head }
            case ReadResult.EndOfStream => throw Exception("CONNECT client closed before request")
        }
    }
    throw Exception("unreachable CONNECT request loop")
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
