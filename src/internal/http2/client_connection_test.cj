package wirestack.internal.http2

import std.collection.*
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*
import wirestack as api

@Test
class Http2ClientConnectionTest {
    @TestCase
    func encodedHeaderFailureClosesTheConnection(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        let peer = TestHttp2Peer(serverTransport)
        let serving = spawn {
            try { let _ = peer.serveOutOfOrder(1); false }
            catch (_: Exception) { true }
        }
        let connection = Http2ClientConnection.connect(clientTransport,
            http2Limits: Http2Limits(maxHeaderBlockBytes: 32u32))
        try {
            var rejected = false
            try {
                let response = connection.execute(HttpRequest.get(
                    "https://example.test/this-header-block-exceeds-the-encoded-limit-after-authority-indexing"))
                response.close()
            } catch (_: Exception) { rejected = true }
            @Expect(rejected)
            @Expect(serving.get(2 * Duration.second))
            @Expect(clientTransport.isClosed())
        } finally {
            connection.abort()
            serverTransport.abort()
            try { let _ = serving.get(2 * Duration.second) } catch (_: Exception) {}
        }
    }

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
    func claimedStreamsPublishInitialHeadersInStreamIdOrder(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 23
        )
        let server = TestHttp2Peer(serverTransport)
        let serving = spawn { server.serveOutOfOrder(2) }
        let connection = Http2ClientConnection.connect(clientTransport)
        let lowerRequest = HttpRequest.get("https://example.test/lower")
        let higherRequest = HttpRequest.get("https://example.test/higher")
        let lowerPlan = mapHttp2ClientRequest(lowerRequest)
        let higherPlan = mapHttp2ClientRequest(higherRequest)
        let lowerSignal = Http2ClientExecutionSignal()
        let higherSignal = Http2ClientExecutionSignal()
        let lower = connection.openStream(lowerSignal, lowerPlan.endStreamOnHeaders)
        let higher = connection.openStream(higherSignal, higherPlan.endStreamOnHeaders)
        @Expect(lower.stream.id.value, 1u32)
        @Expect(higher.stream.id.value, 3u32)

        let higherResponse = spawn {
            connection.executeAdmitted(
                higherRequest, higherPlan, higher.stream, higher.registration, higherSignal
            )
        }
        let lowerResponse = connection.executeAdmitted(
            lowerRequest, lowerPlan, lower.stream, lower.registration, lowerSignal
        )
        let openedHigher = higherResponse.get(Duration.second * 5)
        try {
            @Expect(readClientBody(lowerResponse.body), "/lower")
            @Expect(readClientBody(openedHigher.body), "/higher")
        } finally {
            lowerResponse.close()
            openedHigher.close()
        }
        @Expect(serving.get(Duration.second * 5), 2)
        @Expect(connection.activeStreamCount, 0)
        connection.abort()
        serverTransport.abort()
    }

    @TestCase
    func cancelledUnpublishedStreamDoesNotBlockNextClaim(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 29
        )
        let server = TestHttp2Peer(serverTransport)
        let serving = spawn { server.serveOutOfOrder(1, advertisedStreams: 2u32) }
        let connection = Http2ClientConnection.connect(clientTransport)
        let cancelledRequest = HttpRequest.get("https://example.test/cancelled")
        let nextRequest = HttpRequest.get("https://example.test/next")
        let cancelledPlan = mapHttp2ClientRequest(cancelledRequest)
        let nextPlan = mapHttp2ClientRequest(nextRequest)
        let cancelledSignal = Http2ClientExecutionSignal()
        let nextSignal = Http2ClientExecutionSignal()
        let cancelled = connection.openStream(
            cancelledSignal, cancelledPlan.endStreamOnHeaders
        )
        let next = connection.openStream(nextSignal, nextPlan.endStreamOnHeaders)
        let source = CancellationSource()
        let _ = source.cancel()

        var observedCancellation = false
        try {
            let response = connection.executeAdmitted(
                cancelledRequest, cancelledPlan, cancelled.stream,
                cancelled.registration, cancelledSignal,
                context: OperationContext(cancellation: source.token)
            )
            response.close()
        } catch (_: NetworkException) {
            observedCancellation = true
        }
        @Expect(observedCancellation)

        let response = connection.executeAdmitted(
            nextRequest, nextPlan, next.stream, next.registration, nextSignal
        )
        try { @Expect(readClientBody(response.body), "/next") }
        finally { response.close() }
        @Expect(serving.get(Duration.second * 5), 1)
        @Expect(connection.activeStreamCount, 0)
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

    @TestCase
    func connectedStreamOutlivesHandshakeCancellationAndUsesOperationContexts(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 7
        )
        let peer = ConnectHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let handshakeCancellation = CancellationSource()
        let connection = Http2ClientConnection.connect(clientTransport)
        let result = connection.connectStream(
            HttpRequest(HttpMethod("CONNECT"), HttpUrl.parse("https://example.test:443/")),
            context: OperationContext(cancellation: handshakeCancellation.token)
        )
        let connected = match (result) {
            case Http2ConnectResult.Connected(value) => value
            case Http2ConnectResult.Rejected(response) =>
                response.close()
                throw Exception("CONNECT was unexpectedly rejected")
        }

        let _ = handshakeCancellation.cancel()
        @Expect(connected.transport.writeSome(ByteSpan("ping".toArray()),
            context: OperationContext.background()), 4)
        let reply = Array<Byte>(4, repeat: 0u8)
        readExact(connected.transport, MutableByteSpan(reply))
        @Expect(String.fromUtf8(reply), "pong")
        connected.transport.shutdown(ShutdownDirection.Write)
        @Expect(serving.get(Duration.second * 5), "ping")
        connected.close()
        @Expect(connection.ownedStreamCount, 0)
        connection.abort()
    }

    @TestCase
    func contextlessHalfCloseDoesNotWaitForBlockedConnectionWriter(): Unit {
        let fixture = HalfCloseHttp2Fixture(65535u32)
        fixture.gate.arm()
        let closing = spawn { fixture.connected.transport.shutdown(ShutdownDirection.Write) }
        try {
            fixture.gate.entered.wait()
            closing.get(Duration.second)
            @Expect(!fixture.connected.isClosed())
            @Expect(fixture.connection.ownedStreamCount, 1)
            fixture.gate.release()
            @Expect(fixture.siblingBody(), "alive")
            @Expect(fixture.serving.get(3 * Duration.second), "")
            @Expect(fixture.connected.isClosed())
        } finally {
            fixture.close()
            try { closing.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func halfCloseOrdersEndAfterAdmittedFlowControlledWrite(): Unit {
        let fixture = HalfCloseHttp2Fixture(0u32, peerEndsOnHeaders: false)
        let writing = fixture.startWrite()
        try {
            fixture.awaitFlowStall()
            let closing = spawn { fixture.connected.transport.shutdown(ShutdownDirection.Write) }
            closing.get(Duration.second)
            fixture.peer.grantCredit()
            @Expect(writing.get(3 * Duration.second).getOrThrow(), 4)
            @Expect(fixture.siblingBody(), "alive")
            @Expect(fixture.serving.get(3 * Duration.second), "ping")
        } finally {
            fixture.close()
            try { let _ = writing.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func gracefulCloseOrdersEndAfterAdmittedFlowControlledWrite(): Unit {
        let fixture = HalfCloseHttp2Fixture(0u32)
        let writing = fixture.startWrite()
        try {
            fixture.awaitFlowStall()
            fixture.gate.arm()
            let clock = HalfCloseWaitClock()
            let context = OperationContext(
                deadline: Some(Deadline(MonoTime.now() + 5 * Duration.second, clock: clock))
            )
            let closing = spawn { fixture.connected.transport.close(context) }
            clock.entered.wait()
            fixture.peer.grantCredit()
            fixture.gate.release()
            @Expect(writing.get(3 * Duration.second).getOrThrow(), 4)
            closing.get(3 * Duration.second)
            @Expect(fixture.connected.isClosed())
            @Expect(fixture.siblingBody(), "alive")
            @Expect(fixture.serving.get(3 * Duration.second), "ping")
        } finally {
            fixture.close()
            try { let _ = writing.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func gracefulCloseDeadlineStopsAdmittedFlowControlledWrite(): Unit {
        let fixture = HalfCloseHttp2Fixture(0u32)
        let writing = fixture.startWrite()
        try {
            fixture.awaitFlowStall()
            let error = @AssertThrows[NetworkException](fixture.connected.transport.close(
                OperationContext(deadline: Some(Deadline.after(100 * Duration.millisecond)))
            ))
            @Expect(match (error.category) {
                case NetworkErrorCategory.DeadlineExceeded => true
                case _ => false
            })
            @Expect(writing.get(Duration.second).isNone())
            @Expect(fixture.connected.isClosed())
            @Expect(fixture.siblingBody(), "alive")
            @Expect(fixture.serving.get(3 * Duration.second), "")
        } finally {
            fixture.close()
            try { let _ = writing.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func queuedHalfCloseCancellationDoesNotWaitForConnectionWriter(): Unit {
        let fixture = HalfCloseHttp2Fixture(65535u32)
        let cancellation = CancellationSource()
        var closing = None<Future<?NetworkErrorCategory>>
        try {
            fixture.gate.arm()
            fixture.peer.ping()
            fixture.gate.entered.wait()
            let pending = spawn {
                try {
                    fixture.connected.transport.close(OperationContext(cancellation: cancellation.token))
                    None<NetworkErrorCategory>
                } catch (error: NetworkException) { Some(error.category) }
            }
            closing = Some(pending)
            let admission = Deadline.after(3 * Duration.second)
            while (fixture.connection.metrics().pendingWrites == 0) {
                if (admission.isExpired()) {
                    throw Exception("half-close did not queue behind the stalled PING acknowledgement")
                }
                sleep(Duration.millisecond)
            }
            let _ = cancellation.cancel()
            @Expect(match (pending.get(Duration.second).getOrThrow()) {
                case NetworkErrorCategory.Cancelled => true
                case _ => false
            })
            @Expect(fixture.connected.isClosed())
            @Expect(fixture.connection.ownedStreamCount, 0)
            fixture.gate.release()
            @Expect(fixture.siblingBody(), "alive")
            @Expect(fixture.serving.get(3 * Duration.second), "")
        } finally {
            fixture.close()
            if (let Some(pending) <- closing) {
                try { let _ = pending.get(Duration.second) } catch (_: Exception) {}
            }
        }
    }

    @TestCase
    func rejectedConnectReturnsFullResponseAndClosesRequestDirection(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 8
        )
        let peer = RejectedConnectHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let connection = Http2ClientConnection.connect(clientTransport)
        let result = connection.connectStream(HttpRequest(
            HttpMethod("CONNECT"), HttpUrl.parse("https://example.test:443/")
        ))
        match (result) {
            case Http2ConnectResult.Rejected(response) =>
                try {
                    @Expect(response.status, 403)
                    @Expect(readClientBody(response.body), "no")
                } finally { response.close() }
            case Http2ConnectResult.Connected(stream) =>
                stream.close()
                throw Exception("rejected CONNECT unexpectedly established a stream")
        }
        @Expect(serving.get(Duration.second * 5))
        @Expect(connection.ownedStreamCount, 0)
        connection.abort()
    }

    @TestCase
    func enabledPushAttachesBoundedCallerDrivenResponses(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 9
        )
        let peer = PushHttp2Peer(serverTransport)
        let serving = spawn { peer.serve() }
        let policy = RecordingPushPolicy()
        let connection = Http2ClientConnection.connect(
            clientTransport,
            pushConfig: Some(Http2PushConfig(
                policy, maximumConcurrentPushes: 2,
                maximumPendingPushes: 2, maximumPushesPerRequest: 2
            ))
        )
        let response = connection.execute(HttpRequest.get("https://example.test/index"))
        @Expect(readClientBody(response.body), "")
        let source = response.pushes.getOrThrow()
        let pushed = source.receive(context: OperationContext.background()).getOrThrow()
        @Expect(pushed.request.url.toString(), "https://example.test/asset.css")
        @Expect(readClientBody(pushed.response.body), "asset")
        @Expect(policy.calls.load(), 1)
        pushed.close()
        response.close()
        @Expect(serving.get(Duration.second * 5))
        @Expect(connection.ownedStreamCount, 0)
        connection.abort()
    }
}

private class RejectedConnectHttp2Peer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): Bool {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        var responseSent = false
        while (true) {
            let count = match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream =>
                    throw Exception("HTTP/2 client ended during rejected CONNECT")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (!responseSent) {
                    if (let Some(block) <- result.headerBlock) {
                        if (block.endStream || !hasConnectMethod(decoder.decode(block.bytes))) {
                            throw Exception("rejected CONNECT request head was invalid")
                        }
                        sendRejection(block.streamId)
                        responseSent = true
                    }
                } else if ((match (frame.header.frameType) { case Http2FrameType.Data => true; case _ => false }) &&
                    frame.header.flags.isEndStream() && frame.payload.isEmpty()) {
                    return true
                }
            }
        }
        false
    }

    private func sendRejection(streamId: Http2StreamId): Unit {
        let encoder = HpackEncoder()
        let head = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":status", "403")),
            HpackFieldEncoding(HpackHeaderField("content-length", "2"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(head.size), Http2FrameType.Headers,
                Http2Flags(raw: 0x04u8), streamId
            ),
            head
        ))))
        let body = "no".toArray()
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(body.size), Http2FrameType.Data,
                Http2Flags(raw: 0x01u8), streamId
            ),
            body
        ))))
    }
}

private class RecordingPushPolicy <: Http2PushPolicy {

    let calls = AtomicInt64(0)

    public func allow(
        parent: HttpUrl,
        promised: HttpUrl,
        context: OperationContext
    ): Bool {
        let _ = context
        let _ = calls.fetchAdd(1)
        parent.host == promised.host
    }
}

private class PushHttp2Peer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()
    private let encoder = HpackEncoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): Bool {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start()))

        let parentStream = awaitParentRequest()
        let promisedFields = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":method", "GET")),
            HpackFieldEncoding(HpackHeaderField(":scheme", "https")),
            HpackFieldEncoding(HpackHeaderField(":authority", "example.test")),
            HpackFieldEncoding(HpackHeaderField(":path", "/asset.css"))
        ])
        let promisedPayload = ArrayList<Byte>()
        promisedPayload.add(0u8)
        promisedPayload.add(0u8)
        promisedPayload.add(0u8)
        promisedPayload.add(2u8)
        for (octet in promisedFields) { promisedPayload.add(octet) }
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(promisedPayload.size), Http2FrameType.PushPromise,
                Http2Flags(raw: 0x04u8), parentStream
            ),
            promisedPayload.toArray()
        ))))

        let parentHead = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "0"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(parentHead.size), Http2FrameType.Headers,
                Http2Flags(raw: 0x05u8), parentStream
            ),
            parentHead
        ))))

        let pushHead = encoder.encode([
            HpackFieldEncoding(HpackHeaderField(":status", "200")),
            HpackFieldEncoding(HpackHeaderField("content-length", "5"))
        ])
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(pushHead.size), Http2FrameType.Headers,
                Http2Flags(raw: 0x04u8), Http2StreamId(2u32)
            ),
            pushHead
        ))))
        let body = "asset".toArray()
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(body.size), Http2FrameType.Data,
                Http2Flags(raw: 0x01u8), Http2StreamId(2u32)
            ),
            body
        ))))
        true
    }

    private func awaitParentRequest(): Http2StreamId {
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        while (true) {
            let count = match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream =>
                    throw Exception("HTTP/2 client ended before its parent request")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) {
                    let _ = decoder.decode(block.bytes)
                    return block.streamId
                }
            }
        }
        throw Exception("unreachable push parent wait")
    }
}

private class ConnectHttp2Peer {
    private let transport: DuplexTransport
    private let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
    private let parser = Http2FrameParser()
    private let decoder = HpackDecoder()

    init(transport: DuplexTransport) { this.transport = transport }

    func serve(): String {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start(settings: [
            Http2Setting(Http2SettingId.EnableConnectProtocol, 1u32)
        ])))

        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        var connectStream = None<Http2StreamId>
        let received = ArrayList<Byte>()
        while (received.size < 4) {
            let count = match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream =>
                    throw Exception("HTTP/2 client ended during CONNECT")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)))
                }
                if (let Some(block) <- result.headerBlock) {
                    if (block.endStream) {
                        throw Exception("CONNECT initial HEADERS unexpectedly ended the stream")
                    }
                    let fields = decoder.decode(block.bytes)
                    if (!hasConnectMethod(fields)) {
                        throw Exception("CONNECT request omitted its method")
                    }
                    connectStream = Some(block.streamId)
                    let response = HpackEncoder().encode([
                        HpackFieldEncoding(HpackHeaderField(":status", "200"))
                    ])
                    writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
                        Http2FrameHeader(
                            UInt32(response.size), Http2FrameType.Headers,
                            Http2Flags(raw: 0x04u8), block.streamId
                        ),
                        response
                    ))))
                }
                if ((match (frame.header.frameType) { case Http2FrameType.Data => true; case _ => false }) &&
                    connectStream.isSome() && !frame.header.flags.isEndStream()) {
                    for (octet in frame.payload) { received.add(octet) }
                }
            }
        }
        let streamId = connectStream.getOrThrow()
        let payload = "pong".toArray()
        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
            Http2FrameHeader(
                UInt32(payload.size), Http2FrameType.Data,
                Http2Flags(raw: 0x01u8), streamId
            ),
            payload
        ))))
        String.fromUtf8(received.toArray())
    }
}

private func hasConnectMethod(fields: Array<HpackHeaderField>): Bool {
    for (field in fields) {
        if (field.name == ":method" && field.value == "CONNECT") { return true }
    }
    false
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

    func serveOutOfOrder(
        expected: Int64,
        advertisedStreams!: UInt32 = UInt32(expected)
    ): Int64 {
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface))
        let _ = machine.acceptClientPreface(preface)
        let settings = machine.start(settings: [
            Http2Setting(Http2SettingId.MaxConcurrentStreams, advertisedStreams)
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

private class HalfCloseSignal {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var raised = false

    func signal(): Unit {
        synchronized(mutex) { raised = true; changed.notifyAll() }
    }

    func wait(): Unit {
        let deadline = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (!raised) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for HTTP/2 half-close event")
                }
                changed.wait(timeout: remaining)
            }
        }
    }
}

private class HalfCloseWaitClock <: api.MonotonicClock {
    let entered = HalfCloseSignal()
    public func now(): MonoTime { entered.signal(); MonoTime.now() }
}

private class HalfCloseWriteGate <: DuplexTransport {
    let entered = HalfCloseSignal()
    private let released = HalfCloseSignal()
    private let armed = AtomicBool(false)
    private let delegate: DuplexTransport

    init(delegate: DuplexTransport) { this.delegate = delegate }
    func arm(): Unit { armed.store(true) }
    func release(): Unit { released.signal() }
    public prop info: TransportInfo { get() { delegate.info } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        delegate.readSome(destination, context: context)
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        if (armed.load()) { entered.signal(); released.wait() }
        delegate.writeSome(source, context: context)
    }

    public func shutdown(direction: ShutdownDirection): Unit { delegate.shutdown(direction) }
    public func close(context: OperationContext): Unit { release(); delegate.close(context) }
    public func close(): Unit { release(); delegate.close() }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        release()
        delegate.abort(reason: reason)
    }
    public func isClosed(): Bool { delegate.isClosed() }
}

private class HalfCloseHttp2Fixture <: Resource {
    let gate: HalfCloseWriteGate
    let peer: HalfCloseHttp2Peer
    let serving: Future<String>
    let connection: Http2ClientConnection
    let connected: Http2ConnectedStream
    private let peerTransport: DuplexTransport

    init(initialWindow: UInt32, peerEndsOnHeaders!: Bool = true) {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        peerTransport = serverTransport
        gate = HalfCloseWriteGate(clientTransport)
        let createdPeer = HalfCloseHttp2Peer(serverTransport, initialWindow, peerEndsOnHeaders)
        peer = createdPeer
        serving = spawn { createdPeer.serve() }
        connection = Http2ClientConnection.connect(gate)
        connected = match (connection.connectStream(HttpRequest(
            HttpMethod("CONNECT"), HttpUrl.parse("https://example.test:443/")
        ))) {
            case Http2ConnectResult.Connected(value) => value
            case Http2ConnectResult.Rejected(response) =>
                response.close()
                throw Exception("half-close CONNECT was rejected")
        }
    }

    func startWrite(): Future<?Int64> {
        let transport = connected.transport
        spawn {
            try {
                Some(transport.writeSome(ByteSpan("ping".toArray()), context: OperationContext(
                    deadline: Some(Deadline.after(5 * Duration.second))
                )))
            } catch (_: Exception) { None<Int64> }
        }
    }

    func awaitFlowStall(): Unit {
        let deadline = Deadline.after(3 * Duration.second)
        while (connection.metrics().flowControlStalls == 0) {
            if (deadline.isExpired()) {
                throw Exception("HTTP/2 writer did not reach its advertised zero window")
            }
            sleep(Duration.millisecond)
        }
    }

    func siblingBody(): String {
        let response = connection.execute(
            HttpRequest.get("https://example.test/sibling"),
            context: OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        )
        try { readClientBody(response.body) } finally { response.close() }
    }

    public func close(): Unit {
        gate.release()
        connection.abort()
        peerTransport.abort(reason: Some(AbortReason.ApplicationAbort))
        try { let _ = serving.get(Duration.second) } catch (_: Exception) {}
    }

    public func isClosed(): Bool { connection.isClosed() }
}

private class HalfCloseHttp2Peer {
    private let transport: DuplexTransport
    private let initialWindow: UInt32
    private let endWithHeaders: Bool
    private let mutex = Mutex()
    private var connectedStream = None<Http2StreamId>

    init(transport: DuplexTransport, initialWindow: UInt32, endWithHeaders: Bool) {
        this.transport = transport
        this.initialWindow = initialWindow
        this.endWithHeaders = endWithHeaders
    }

    func grantCredit(): Unit {
        let stream = synchronized(mutex) { connectedStream.getOrThrow() }
        writeAll(transport, ByteSpan(serializeHttp2Frame(
            encodeHttp2WindowUpdate(stream, 4u32)
        )))
    }

    func ping(): Unit {
        writeAll(transport, ByteSpan(serializeHttp2Frame(
            encodeHttp2Ping(Array<Byte>(8, repeat: 3u8))
        )))
    }

    func serve(): String {
        let context = OperationContext(deadline: Some(Deadline.after(10 * Duration.second)))
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let parser = Http2FrameParser()
        let decoder = HpackDecoder()
        let preface = Array<Byte>(http2ClientPreface().size, repeat: 0u8)
        readExact(transport, MutableByteSpan(preface), context: context)
        let _ = machine.acceptClientPreface(preface)
        writeAll(transport, ByteSpan(machine.start(settings: [
            Http2Setting(Http2SettingId.InitialWindowSize, initialWindow)
        ])), context: context)
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        let received = ArrayList<Byte>()
        var ended = false
        var siblingAnswered = false
        while (!ended || !siblingAnswered) {
            let count = match (transport.readSome(MutableByteSpan(buffer), context: context)) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("HTTP/2 half-close peer lost its connection")
            }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                let result = machine.receive(frame)
                for (outbound in result.outbound) {
                    writeAll(transport, ByteSpan(serializeHttp2Frame(outbound)), context: context)
                }
                if (let Some(block) <- result.headerBlock) {
                    if (hasConnectMethod(decoder.decode(block.bytes))) {
                        synchronized(mutex) { connectedStream = Some(block.streamId) }
                        let response = HpackEncoder().encode([
                            HpackFieldEncoding(HpackHeaderField(":status", "200"))
                        ])
                        writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
                            Http2FrameHeader(
                                UInt32(response.size), Http2FrameType.Headers,
                                Http2Flags(raw: if (endWithHeaders) { 0x05u8 } else { 0x04u8 }),
                                block.streamId
                            ),
                            response
                        ))), context: context)
                    } else {
                        if (!endWithHeaders) {
                            let stream = synchronized(mutex) { connectedStream.getOrThrow() }
                            writeAll(transport, ByteSpan(serializeHttp2Frame(Http2Frame(
                                Http2FrameHeader(
                                    0u32, Http2FrameType.Data, Http2Flags(raw: 0x01u8), stream
                                ),
                                []
                            ))), context: context)
                        }
                        sendTestResponse(transport, block.streamId, "alive")
                        siblingAnswered = true
                    }
                }
                let primary = synchronized(mutex) { connectedStream }
                if (let Some(stream) <- primary) {
                    if (frame.header.streamId.value == stream.value) {
                        match (frame.header.frameType) {
                            case Http2FrameType.Data =>
                                if (ended) { throw Exception("HTTP/2 peer received DATA after END_STREAM") }
                                for (octet in frame.payload) { received.add(octet) }
                                if (frame.header.flags.isEndStream()) { ended = true }
                            case Http2FrameType.RstStream => ended = true
                            case _ => ()
                        }
                    }
                }
            }
        }
        String.fromUtf8(received.toArray())
    }
}
