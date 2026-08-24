package wirestack.internal.http2

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2ClientConnectionTest {
    @TestCase
    func tenConcurrentRequestsShareOneConnectionAndMapOutOfOrderResponses(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 1024 * 1024, maxChunk: 37)
        let server = TestHttp2Peer(serverTransport)
        let serving = spawn { server.serveOutOfOrder(10) }
        let connection = Http2ClientConnection.connect(clientTransport)

        let requests = ArrayList<Future<String>>()
        for (index in 0..10) {
            let captured = index
            requests.add(spawn {
                let response = connection.execute(HttpRequest.get("https://example.test/${captured}"))
                try {
                    @Expect(response.status, 200)
                    readClientBody(response.body)
                } finally {
                    response.close()
                }
            })
        }

        for (index in 0..10) {
            @Expect(requests[index].get(Duration.second * 5), "/${index}")
        }
        @Expect(serving.get(Duration.second * 5), 10)
        @Expect(connection.activeStreamCount, 0)
        @Expect(connection.streamCapacity, 10u32)
        connection.abort()
        serverTransport.abort()
    }

    @TestCase
    func declaredLengthDoesNotReleaseStreamBeforeWireEndStream(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024, maxChunk: 17)
        let peer = DelayedEndHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let connection = Http2ClientConnection.connect(clientTransport)
        let response = connection.execute(HttpRequest.get("https://example.test/delayed"))

        let bytes = Array<Byte>(3, repeat: 0u8)
        @Expect(response.body.read(bytes), 3)
        @Expect(String.fromUtf8(bytes), "abc")
        @Expect(!response.body.isFullyConsumed())
        @Expect(connection.activeStreamCount, 1)

        peer.releaseEndStream()
        @Expect(response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
        @Expect(response.body.isFullyConsumed())
        @Expect(connection.activeStreamCount, 0)
        @Expect(serving.get(Duration.second), true)
        response.close()
        connection.abort()
    }

    @TestCase
    func streamsRequestBodyThroughFlowControlledDataAndEndsLocallyOnce(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024, maxChunk: 11)
        let peer = EchoHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let connection = Http2ClientConnection.connect(clientTransport)
        let response = connection.execute(HttpRequest.post(
            "https://example.test/echo", RequestBody.string("streamed-request")
        ))

        @Expect(readClientBody(response.body), "streamed-request")
        response.close()
        @Expect(serving.get(Duration.second), "streamed-request")
        @Expect(connection.activeStreamCount, 0)
        connection.abort()
    }

    @TestCase
    func peerResetFailsOnlyItsStreamAndConnectionRemainsUsable(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024, maxChunk: 13)
        let peer = ResetIsolationHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let connection = Http2ClientConnection.connect(clientTransport)
        let resetRequest = spawn { expectResetResponse(connection, "/reset") }
        let okRequest = spawn {
            let response = connection.execute(HttpRequest.get("https://example.test/ok"))
            try { readClientBody(response.body) } finally { response.close() }
        }

        @Expect(resetRequest.get(Duration.second * 5))
        @Expect(okRequest.get(Duration.second * 5), "ok")
        @Expect(serving.get(Duration.second * 5), true)
        @Expect(connection.activeStreamCount, 0)
        @Expect(connection.acceptingNewStreams)
        connection.abort()
    }

    @TestCase
    func peerGoAwayDrainsConnectionWithoutFailingAcceptedStream(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024, maxChunk: 19)
        let peer = DrainingHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let connection = Http2ClientConnection.connect(clientTransport)
        let response = connection.execute(HttpRequest.get("https://example.test/accepted"))
        try { @Expect(readClientBody(response.body), "accepted") } finally { response.close() }

        @Expect(serving.get(Duration.second * 5), true)
        @Expect(!connection.acceptingNewStreams)
        @Expect(expectDrainingRejection(connection))
        @Expect(connection.activeStreamCount, 0)
        connection.abort()
    }
}

private class ResetIsolationHttp2Peer {
    private let transport: DuplexTransport
    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): Bool {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let parser = Http2FrameParser()
        let decoder = HpackDecoder()
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))
        let requests = ArrayList<TestHttp2Request>()
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        while (requests.size < 2) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("reset peer saw early EOF")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) { writeAll(transport, ByteSpan(serializeHttp2Frame(outbound))) }
                if (let Some(block) <- result.headerBlock) {
                    requests.add(TestHttp2Request(block.streamId, requestPath(decoder.decode(block.bytes))))
                }
            }
        }
        for (request in requests) {
            if (request.path == "/reset") {
                writeAll(transport, ByteSpan(serializeHttp2Frame(encodeHttp2RstStream(
                    request.streamId, Http2ErrorCode.Cancel
                ))))
            } else {
                sendTestResponse(transport, request.streamId, "ok")
            }
        }
        true
    }
}

private class DrainingHttp2Peer {
    private let transport: DuplexTransport
    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): Bool {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let parser = Http2FrameParser()
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        var streamId = Http2StreamId(0u32)
        while (streamId.isConnection()) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("draining peer saw early EOF")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) { writeAll(transport, ByteSpan(serializeHttp2Frame(outbound))) }
                if (let Some(block) <- result.headerBlock) { streamId = block.streamId }
            }
        }
        writeAll(transport, ByteSpan(serializeHttp2Frame(encodeHttp2GoAway(
            Http2GoAway(streamId, Http2ErrorCode.NoError, [])
        ))))
        sendTestResponse(transport, streamId, "accepted")
        true
    }
}

private class EchoHttp2Peer {
    private let transport: DuplexTransport
    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): String {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let parser = Http2FrameParser()
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))
        let body = ArrayList<Byte>()
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        var streamId = Http2StreamId(0u32)
        var ended = false
        while (!ended) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("echo HTTP/2 peer saw early EOF")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) { streamId = block.streamId }
                match (frame.header.frameType) {
                    case Http2FrameType.Data =>
                        for (byte in frame.payload) { body.add(byte) }
                        if (frame.header.flags.isEndStream()) { ended = true }
                    case _ => ()
                }
            }
        }

        let bytes = body.toArray()
        let headers = HpackEncoder().encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "${bytes.size}"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(headers.size), Http2FrameType.Headers, Http2Flags(raw: 0x04u8), streamId
            ),
            headers
        ))))
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(bytes.size), Http2FrameType.Data, Http2Flags(raw: 0x01u8), streamId
            ),
            bytes
        ))))
        String.fromUtf8(bytes)
    }
}

private class DelayedEndHttp2Peer {
    private let transport: DuplexTransport
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var released = false

    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): Bool {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let parser = Http2FrameParser()
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))

        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        var streamId = Http2StreamId(0u32)
        while (streamId.isConnection()) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("delayed HTTP/2 peer saw early EOF")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) { streamId = block.streamId }
            }
        }

        let headers = HpackEncoder().encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "3"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(headers.size), Http2FrameType.Headers, Http2Flags(raw: 0x04u8), streamId
            ),
            headers
        ))))
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(3u32, Http2FrameType.Data, Http2Flags(), streamId),
            "abc".toArray()
        ))))

        synchronized(mutex) { while (!released) { changed.wait() } }
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8), streamId),
            []
        ))))
        true
    }

    func releaseEndStream(): Unit {
        synchronized(mutex) { released = true; changed.notifyAll() }
    }
}

private class TestHttp2Peer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()
    private let encoder = HpackEncoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serveOutOfOrder(expected: Int64): Int64 {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        let settings = machine.start(settings: [
            Http2Setting(Http2SettingId.MaxConcurrentStreams, UInt32(expected))
        ])
        writeAll(transport, ByteSpan(settings))

        let pending = ArrayList<TestHttp2Request>()
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        while (pending.size < expected) {
            let count = match (transport.readSome(
                MutableByteSpan(buffer), context: OperationContext.background()
            )) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("HTTP/2 client ended before every request")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) {
                    let path = requestPath(decoder.decode(block.bytes))
                    pending.add(TestHttp2Request(block.streamId, path))
                }
            }
        }

        var index: Int64 = pending.size - 1
        while (index >= 0) {
            sendResponse(pending[index])
            index -= 1
        }
        pending.size
    }

    private func sendResponse(request: TestHttp2Request): Unit {
        let body = request.path.toArray()
        let fields = [
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "${body.size}"))
        ]
        let block = encoder.encode(fields)
        let headers = Http2Frame(
            Http2FrameHeader(
                UInt32(block.size), Http2FrameType.Headers, Http2Flags(raw: 0x04u8), request.streamId
            ),
            block
        )
        let data = Http2Frame(
            Http2FrameHeader(
                UInt32(body.size), Http2FrameType.Data, Http2Flags(raw: 0x01u8), request.streamId
            ),
            body
        )
        writeAll(transport, ByteSpan(serializeHttp2Frame(headers)))
        writeAll(transport, ByteSpan(serializeHttp2Frame(data)))
    }
}

private class TestHttp2Request {
    let streamId: Http2StreamId
    let path: String
    init(streamId: Http2StreamId, path: String) { this.streamId = streamId; this.path = path }
}

private func requestPath(fields: Array<HpackHeaderField>): String {
    for (field in fields) { if (field.name == ":path") { return field.value } }
    throw Exception("HTTP/2 request did not contain :path")
}

private func readClientBody(body: ResponseBody): String {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(3, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    String.fromUtf8(output.toArray())
}

private func sendTestResponse(
    transport: DuplexTransport,
    streamId: Http2StreamId,
    content: String
): Unit {
    let body = content.toArray()
    let block = HpackEncoder().encode([
        HpackFieldEncoding(HpackHeaderField(":status", "200")),
        HpackFieldEncoding(HpackHeaderField("content-length", "${body.size}"))
    ])
    writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
        Http2FrameHeader(UInt32(block.size), Http2FrameType.Headers, Http2Flags(raw: 0x04u8), streamId),
        block
    ))))
    writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
        Http2FrameHeader(UInt32(body.size), Http2FrameType.Data, Http2Flags(raw: 0x01u8), streamId),
        body
    ))))
}

private func expectResetResponse(connection: Http2ClientConnection, path: String): Bool {
    var response: ?HttpResponse = None<HttpResponse>
    try {
        let opened = connection.execute(HttpRequest.get("https://example.test${path}"))
        response = Some(opened)
        let _ = readClientBody(opened.body)
        false
    } catch (_: Http2ProtocolException) {
        true
    } finally {
        if (let Some(value) <- response) { value.close() }
    }
}

private func expectDrainingRejection(connection: Http2ClientConnection): Bool {
    try {
        let response = connection.execute(HttpRequest.get("https://example.test/rejected"))
        response.close()
        false
    } catch (_: Http2StreamLimitException) {
        true
    }
}
