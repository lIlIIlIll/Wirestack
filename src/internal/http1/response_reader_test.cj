package wirestack.internal.http1

import std.sync.*
import wirestack as api
import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1ResponseReaderTest {
    @TestCase
    func upgradedReadsKeepOwnerCorrelationWithoutReplacingCallerIdleBudget(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        writeAll(server, ByteSpan("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nx".toArray()))
        let sink = api.NetworkEventBuffer(capacity: 64)
        let request = HttpRequest.get("http://example.test/chat").withHeaders(
            HttpHeaders.builder().add("Connection", "Upgrade").add("Upgrade", "websocket").build())
        let result = performHttp1Upgrade(client, request, context: OperationContext(eventSink: Some(sink),
            requestId: Some(801), attemptId: Some(802), connectionId: Some(803)))
        let upgraded = match (result) { case Http1UpgradeExchangeResult.Upgraded(value) => value; case _ => throw Exception("upgrade rejected") }
        let _ = sink.drain()
        let context = OperationContext(deadline: Some(Deadline.after(Duration.second)),
            timeoutPolicy: OperationTimeoutPolicy(streamReadIdle: Some(5 * Duration.millisecond)))
        let bytes = Array<Byte>(1, repeat: 0)
        match (upgraded.transport.readSome(MutableByteSpan(bytes), context: context)) {
            case ReadResult.Data(1) => @Expect(bytes[0], 120u8)
            case _ => @Fail("upgrade lost parser remainder")
        }
        let _ = @AssertThrows[NetworkException](upgraded.transport.readSome(MutableByteSpan(bytes), context: context))
        var starts: Int64 = 0
        var ends: Int64 = 0
        var timedOut: Int64 = 0
        for (event in sink.drain()) {
            @Expect(event.requestId, Some(801)); @Expect(event.attemptId, Some(802)); @Expect(event.connectionId, Some(803))
            match (event.kind) {
                case NetworkEventKind.StageStarted => starts++
                case NetworkEventKind.StageCompleted =>
                    ends++
                    match (event.errorCode) {
                        case Some(NetworkErrorCode.TimedOut) =>
                            timedOut++
                            match (event.timeoutStage) { case Some(OperationTimeoutStage.StreamReadIdle) => (); case _ => @Fail("lost stream idle owner") }
                        case _ => ()
                    }
                case _ => @Fail("stream read emitted an unrelated lifecycle event")
            }
        }
        @Expect(starts, 2); @Expect(ends, 2); @Expect(timedOut, 1)
        upgraded.transport.close(); server.close()
    }

    @TestCase
    func bodyTerminationSeparatesIdleTimeoutAbandonmentEofAndCancellation(): Unit {
        for (mode in 0..4) {
            let (client, server) = MemoryTransport.pair(capacity: 2048)
            writeAll(server, ByteSpan("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n".toArray()))
            if (mode == 2) { server.shutdown(ShutdownDirection.Write) }
            let sink = api.NetworkEventBuffer(capacity: 64)
            let source = CancellationSource()
            let result = readHttp1Response(client, HttpMethod("GET"), context: OperationContext(
                eventSink: Some(sink), cancellation: source.token, requestId: Some(41), attemptId: Some(42),
                connectionId: Some(43), timeoutPolicy: OperationTimeoutPolicy(
                    bodyReadIdle: Some(5 * Duration.millisecond))))
            let initial = sink.drain()
            var starts: Int64 = 0
            for (event in initial) {
                match (event.kind) { case NetworkEventKind.BodyStarted => starts++; case _ => () }
            }
            @Expect(starts, 1)
            if (mode == 0 || mode == 2) {
                let _ = @AssertThrows[NetworkException](result.response.body.read(Array<Byte>(1, repeat: 0)))
            } else if (mode == 3) { source.cancel() }
            result.response.close()
            result.response.close()
            var completed: Int64 = 0
            for (event in sink.drain()) {
                match (event.kind) {
                    case NetworkEventKind.BodyCompleted =>
                        completed++
                        @Expect(event.connectionId, Some(43))
                        @Expect(event.requestId, Some(41))
                        @Expect(event.attemptId, Some(42))
                        match ((mode, event.errorCode)) {
                            case (0, Some(NetworkErrorCode.TimedOut)) =>
                                match (event.timeoutReason) {
                                    case Some(api.NetworkTimeoutReason.StageLimit) => ()
                                    case _ => @Fail("body idle timeout lost its cap owner")
                                }
                                match (event.timeoutStage) {
                                    case Some(OperationTimeoutStage.BodyReadIdle) => ()
                                    case _ => @Fail("body idle timeout attributed to another stage")
                                }
                            case (1, Some(NetworkErrorCode.Closed)) =>
                                match (event.outcome) { case NetworkEventOutcome.Discarded => (); case _ => @Fail("close became success") }
                            case (2, Some(NetworkErrorCode.UnexpectedEof)) => ()
                            case (3, Some(NetworkErrorCode.Cancelled)) => ()
                            case _ => @Fail("wrong body terminal error")
                        }
                    case _ => ()
                }
            }
            @Expect(completed, 1)
            client.close(); server.close()
        }
    }

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
            HttpHeaders.builder().add("Connection", "keep-alive, Upgrade")
                .add("Upgrade", "other/1, WebSocket").add("Upgrade", "fallback").build()
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
    func bodyReadIdleStartsWhenTheCallerBeginsReading(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        writeAll(server, ByteSpan(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toArray()
        ))
        let context = OperationContext(timeoutPolicy: OperationTimeoutPolicy(
            bodyReadIdle: Some(20 * Duration.millisecond)
        ))
        let response = readHttp1Response(
            client, HttpMethod("GET"), context: context
        ).response
        try {
            sleep(60 * Duration.millisecond)
            @Expect(readReaderBody(response.body), "ok")
        } finally {
            response.close()
            client.close()
            server.close()
        }
    }

    @TestCase
    func timeoutAndCancellationRaceAbandonsBodyExactlyOnce(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 2048)
        writeAll(server, ByteSpan(
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n".toArray()
        ))
        let cancellation = CancellationSource()
        let observer = ReaderBodyObserver()
        let context = OperationContext(
            cancellation: cancellation.token,
            timeoutPolicy: OperationTimeoutPolicy(
                bodyReadIdle: Some(40 * Duration.millisecond)
            )
        )
        let response = readHttp1Response(
            client, HttpMethod("GET"), context: context, observer: observer
        ).response
        let readStarted = AtomicInt64(0)
        let read = spawn {
            readStarted.store(1)
            try {
                let _ = response.body.read(Array<Byte>(1, repeat: 0u8))
                0
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => 2
                    case NetworkErrorCode.TimedOut => 1
                    case _ => 3
                }
            }
        }
        let startupDeadline = Deadline.after(Duration.second)
        while (readStarted.load() == 0 && !startupDeadline.isExpired()) {
            sleep(Duration.millisecond)
        }
        @Expect(readStarted.load(), 1)
        let cancel = spawn {
            sleep(40 * Duration.millisecond)
            cancellation.cancel()
        }
        let winner = read.get(Duration.second)
        cancel.get(Duration.second)
        @Expect(winner == 1 || winner == 2)
        @Expect(observer.abandonedCount, 1)
        response.close()
        @Expect(observer.abandonedCount, 1)
        client.close()
        server.close()
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
