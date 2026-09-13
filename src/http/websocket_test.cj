package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.transport.MemoryTransport

@Test
class WebSocketConnectionTest {
    @TestCase
    func fragmentedUtf8AndAutomaticPongSurviveOneByteTransportReads(): Unit {
        let (clientTransport, serverTransport) =
            MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let client = WebSocketConnection(clientTransport, WebSocketRole.Client)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        try {
            client.send(WebSocketFrame(
                WebSocketOpcode.Text, payload: [0xe4u8, 0xb8u8], finalFragment: false
            ))
            client.send(WebSocketFrame(WebSocketOpcode.Continuation, payload: [0xadu8]))
            let first = server.receive()
            let continuation = server.receive()
            @Expect(webSocketTestOpcode(first.opcode, WebSocketOpcode.Text))
            @Expect(!first.finalFragment)
            @Expect(first.payload, [0xe4u8, 0xb8u8])
            @Expect(webSocketTestOpcode(
                continuation.opcode, WebSocketOpcode.Continuation
            ))
            @Expect(continuation.finalFragment)
            @Expect(continuation.payload, [0xadu8])

            client.send(WebSocketFrame(WebSocketOpcode.Ping, payload: "probe".toArray()))
            let ping = server.receive()
            let pong = client.receive()
            @Expect(webSocketTestOpcode(ping.opcode, WebSocketOpcode.Ping))
            @Expect(ping.payload, "probe".toArray())
            @Expect(webSocketTestOpcode(pong.opcode, WebSocketOpcode.Pong))
            @Expect(pong.payload, "probe".toArray())
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func preCancelledSendPerformsNoIoAndLeavesUntouchedSessionHealthy(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let client = WebSocketConnection(clientTransport, WebSocketRole.Client)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        let cancellation = CancellationSource()
        cancellation.cancel()
        try {
            let error = @AssertThrows[WebSocketException](
                client.send(
                    WebSocketFrame(WebSocketOpcode.Binary, payload: [1u8]),
                    context: OperationContext(cancellation: cancellation.token)
                )
            )
            @Expect(webSocketTestError(error.code, WebSocketErrorCode.ContextStopped))
            @Expect(!client.isClosed())

            client.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [2u8]))
            let received = server.receive()
            @Expect(webSocketTestOpcode(received.opcode, WebSocketOpcode.Binary))
            @Expect(received.payload, [2u8])
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func fragmentedMessageBoundRejectsBeforeWritingAndPreservesProgression(): Unit {
        let limits = WebSocketLimits(
            maximumFrameBytes: 4,
            maximumMessageBytes: 4,
            ioBufferBytes: 1,
            closeTimeout: Duration.second
        )
        let (clientTransport, serverTransport) =
            MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let client = WebSocketConnection(
            clientTransport, WebSocketRole.Client, limits: limits
        )
        let server = WebSocketConnection(
            serverTransport, WebSocketRole.Server, limits: limits
        )
        try {
            client.send(WebSocketFrame(
                WebSocketOpcode.Binary, payload: [1u8, 2u8, 3u8], finalFragment: false
            ))
            let tooLarge = @AssertThrows[WebSocketException](
                client.send(WebSocketFrame(
                    WebSocketOpcode.Continuation, payload: [4u8, 5u8]
                ))
            )
            @Expect(webSocketTestError(
                tooLarge.code, WebSocketErrorCode.MessageTooLarge
            ))
            @Expect(!client.isClosed())

            client.send(WebSocketFrame(WebSocketOpcode.Continuation, payload: [4u8]))
            let first = server.receive()
            let continuation = server.receive()
            @Expect(first.payload, [1u8, 2u8, 3u8])
            @Expect(!first.finalFragment)
            @Expect(continuation.payload, [4u8])
            @Expect(continuation.finalFragment)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func roleMaskingAndNonCanonicalLengthFailClosedWithProtocolStatus(): Unit {
        let (rawClient, serverTransport) = MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        try {
            api.writeAll(rawClient, api.ByteSpan([0x81u8, 0x01u8, b'x']))
            let masking = @AssertThrows[WebSocketException](server.receive())
            @Expect(webSocketTestError(masking.code, WebSocketErrorCode.ProtocolViolation))
            @Expect(masking.closeCode, Some(1002u16))
            @Expect(server.isClosed())
        } finally {
            rawClient.close()
            server.close()
        }

        let (rawClient2, serverTransport2) = MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let server2 = WebSocketConnection(serverTransport2, WebSocketRole.Server)
        try {
            api.writeAll(rawClient2, api.ByteSpan([
                0x81u8, 0xfeu8, 0x00u8, 0x01u8,
                1u8, 2u8, 3u8, 4u8, b'x' ^ 1u8
            ]))
            let canonical = @AssertThrows[WebSocketException](server2.receive())
            @Expect(webSocketTestError(canonical.code, WebSocketErrorCode.ProtocolViolation))
            @Expect(canonical.closeCode, Some(1002u16))
            @Expect(server2.isClosed())
        } finally {
            rawClient2.close()
            server2.close()
        }
    }

    @TestCase
    func fragmentedTextRejectsInvalidContinuationAtTheMessageBoundary(): Unit {
        let (rawClient, serverTransport) = MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        try {
            api.writeAll(rawClient, api.ByteSpan(webSocketTestMaskedFrame(
                0x01u8, false, [0xe4u8, 0xb8u8]
            )))
            api.writeAll(rawClient, api.ByteSpan(webSocketTestMaskedFrame(
                0x00u8, true, [b'A']
            )))
            let first = server.receive()
            @Expect(webSocketTestOpcode(first.opcode, WebSocketOpcode.Text))
            @Expect(!first.finalFragment)
            let invalid = @AssertThrows[WebSocketException](server.receive())
            @Expect(webSocketTestError(invalid.code, WebSocketErrorCode.InvalidPayload))
            @Expect(invalid.closeCode, Some(1007u16))
            @Expect(server.isClosed())
        } finally {
            rawClient.close()
            server.close()
        }
    }

    @TestCase
    func gracefulCloseEchoesStatusAndCompletesBothOwners(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 4096, maxChunk: 1)
        let client = WebSocketConnection(clientTransport, WebSocketRole.Client)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        let serverResult: Future<Bool> = spawn {
            let closeFrame = server.receive(context: OperationContext(
                deadline: Some(Deadline.after(Duration.second))))
            webSocketTestOpcode(closeFrame.opcode, WebSocketOpcode.Close) && server.isClosed()
        }
        client.close(1000u16, "done", context: OperationContext(
            deadline: Some(Deadline.after(Duration.second))))
        @Expect(client.isClosed())
        @Expect(serverResult.get(Duration.second))
        client.close()
        server.close()
    }

    @TestCase
    func handshakeCryptoMatchesRfcVectorAndReturnsCanonicalFreshKeyShape(): Unit {
        @Expect(
            webSocketAcceptKey("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
        let key = newWebSocketKey()
        let keyBytes = key.toArray()
        @Expect(keyBytes.size, 24)
        @Expect(keyBytes[22], b'=')
        @Expect(keyBytes[23], b'=')
        @Expect(webSocketAcceptKey(key).toArray().size, 28)
    }

    @TestCase
    func framePayloadIsOwnedAndCloseInputIsStrict(): Unit {
        let source = [1u8, 2u8]
        let frame = WebSocketFrame(WebSocketOpcode.Binary, payload: source)
        source[0] = 9u8
        let returned = frame.payload
        returned[1] = 8u8
        @Expect(frame.payload, [1u8, 2u8])
        @AssertThrows[IllegalArgumentException](
            WebSocketFrame(WebSocketOpcode.Close, payload: [0x03u8])
        )
        @AssertThrows[IllegalArgumentException](
            WebSocketFrame(WebSocketOpcode.Ping, payload: Array<Byte>(126, repeat: 0u8))
        )
    }
}

private func webSocketTestMaskedFrame(
    opcode: Byte,
    finalFragment: Bool,
    payload: Array<Byte>
): Array<Byte> {
    let mask = [1u8, 2u8, 3u8, 4u8]
    let output = Array<Byte>(2 + mask.size + payload.size, repeat: 0u8)
    output[0] = (if (finalFragment) { 0x80u8 } else { 0u8 }) | opcode
    output[1] = 0x80u8 | UInt8(payload.size)
    for (index in 0..mask.size) { output[2 + index] = mask[index] }
    for (index in 0..payload.size) {
        output[2 + mask.size + index] = payload[index] ^ mask[index % mask.size]
    }
    output
}

private func webSocketTestOpcode(actual: WebSocketOpcode, expected: WebSocketOpcode): Bool {
    match ((actual, expected)) {
        case (WebSocketOpcode.Continuation, WebSocketOpcode.Continuation) |
            (WebSocketOpcode.Text, WebSocketOpcode.Text) |
            (WebSocketOpcode.Binary, WebSocketOpcode.Binary) |
            (WebSocketOpcode.Close, WebSocketOpcode.Close) |
            (WebSocketOpcode.Ping, WebSocketOpcode.Ping) |
            (WebSocketOpcode.Pong, WebSocketOpcode.Pong) => true
        case _ => false
    }
}

private func webSocketTestError(actual: WebSocketErrorCode, expected: WebSocketErrorCode): Bool {
    match ((actual, expected)) {
        case (WebSocketErrorCode.InvalidFrame, WebSocketErrorCode.InvalidFrame) |
            (WebSocketErrorCode.ProtocolViolation, WebSocketErrorCode.ProtocolViolation) |
            (WebSocketErrorCode.MessageTooLarge, WebSocketErrorCode.MessageTooLarge) |
            (WebSocketErrorCode.InvalidPayload, WebSocketErrorCode.InvalidPayload) |
            (WebSocketErrorCode.Closed, WebSocketErrorCode.Closed) |
            (WebSocketErrorCode.ContextStopped, WebSocketErrorCode.ContextStopped) |
            (WebSocketErrorCode.TransportFailure, WebSocketErrorCode.TransportFailure) |
            (WebSocketErrorCode.CryptoFailure, WebSocketErrorCode.CryptoFailure) => true
        case _ => false
    }
}
