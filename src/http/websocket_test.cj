package wirestack.http

import std.collection.*
import std.sync.*
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

    @TestCase
    func boundedDeterministicWireMutationsAreSplitInvariantAndFailClosed(): Unit {
        let anchors = m8005WebSocketCorpus()
        let mutations = m8005WebSocketMutations()
        let schedules = [1i64, 2i64, 7i64, 64i64]
        var executions: Int64 = 0
        var readCalls: Int64 = 0
        var maximumInputBytes: Int64 = 0
        for (scenario in anchors) {
            maximumInputBytes = max(maximumInputBytes, scenario.wire.size)
            var baseline: ?M8005WebSocketOutcome = None<M8005WebSocketOutcome>
            for (maximumRead in schedules) {
                let outcome = m8005RunWebSocketWire(scenario.wire, maximumRead)
                m8005ExpectWebSocketOutcome(outcome, scenario)
                match (baseline) {
                    case None => baseline = Some(outcome)
                    case Some(first) => m8005ExpectEquivalentWebSocketOutcome(outcome, first)
                }
                executions++
                readCalls += outcome.readCalls
            }
        }
        for (wire in mutations) {
            maximumInputBytes = max(maximumInputBytes, wire.size)
            var baseline: ?M8005WebSocketOutcome = None<M8005WebSocketOutcome>
            for (maximumRead in schedules) {
                let outcome = m8005RunWebSocketWire(wire, maximumRead)
                m8005ExpectSafeWebSocketTermination(outcome)
                match (baseline) {
                    case None => baseline = Some(outcome)
                    case Some(first) => m8005ExpectEquivalentWebSocketOutcome(outcome, first)
                }
                executions++
                readCalls += outcome.readCalls
            }
        }
        println(
            "M8005_FUZZ target=websocket seed=8005 anchors=${anchors.size} " +
            "mutations=${mutations.size} schedules=${schedules.size} executions=${executions} " +
            "maxInputBytes=${maximumInputBytes} readCalls=${readCalls} decision=PASS"
        )
    }

    @TestCase
    func rejectedCloseWritesNoFrameAndLeavesTheSessionUsable(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 4096, maxChunk: 4096)
        let client = WebSocketConnection(clientTransport, WebSocketRole.Client)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        let bounded = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        try {
            let first = spawn { server.receive(context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.readerActive }).readerActive)
            let second = spawn { server.receive(context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.readerWaiters == 1 }).readerWaiters, 1)

            let rejected = @AssertThrows[WebSocketException](
                server.close(1000u16, "done", context: bounded))
            @Expect(webSocketTestError(rejected.code, WebSocketErrorCode.CapacityExceeded))
            // Side-effect free rejection: no close frame was written and no slot was consumed.
            @Expect(!server.isClosed())
            let after = server.admissionState
            @Expect(after.closeWaiters, 0)
            @Expect(after.replyWaiters, 0)
            @Expect(after.writerWaiters, 0)
            @Expect(after.readerWaiters, 1)

            client.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [1u8, 2u8, 3u8]))
            let active = first.get(3 * Duration.second)
            @Expect(webSocketTestOpcode(active.opcode, WebSocketOpcode.Binary))
            @Expect(active.payload, [1u8, 2u8, 3u8])
            client.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [4u8]))
            let queued = second.get(3 * Duration.second)
            @Expect(webSocketTestOpcode(queued.opcode, WebSocketOpcode.Binary))
            @Expect(queued.payload, [4u8])

            // The session stayed open, so a later close handshake still completes normally.
            let peer = spawn {
                try { Some(client.receive(context: bounded)) } catch (_: WebSocketException) { None<WebSocketFrame> }
            }
            server.close(1000u16, "done", context: bounded)
            @Expect(server.isClosed())
            @Expect(webSocketTestOpcode(peer.get(3 * Duration.second).getOrThrow().opcode, WebSocketOpcode.Close))
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func reservedReplySurvivesABlockedApplicationWriterAndWaitingClose(): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64, maxChunk: 64)
        let client = WebSocketConnection(clientTransport, WebSocketRole.Client)
        let server = WebSocketConnection(serverTransport, WebSocketRole.Server)
        let payload = Array<Byte>(512, repeat: 42u8)
        let bounded = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        try {
            let blockedSend = spawn { server.send(WebSocketFrame(WebSocketOpcode.Binary, payload: payload),
                context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.writerActive }).writerActive)
            let reader = spawn { server.receive(context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.readerActive }).readerActive)
            // The caller close reserves reader admission before writing, so it waits without
            // occupying the reserved reply slot.
            let closer = spawn { server.close(1000u16, "done", context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.readerWaiters == 1 }).readerWaiters, 1)
            @Expect(server.admissionState.closeWaiters, 0)

            client.send(WebSocketFrame(WebSocketOpcode.Ping, payload: "probe".toArray()))
            // The reply waits in its own bounded slot, not in the application writer's pending slot.
            @Expect(webSocketTestAwaitAdmission(server, { state => state.replyWaiters == 1 }).replyWaiters, 1)
            @Expect(server.admissionState.writerWaiters, 0)
            let pendingSend = spawn { server.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [7u8]),
                context: bounded) }
            @Expect(webSocketTestAwaitAdmission(server, { state => state.writerWaiters == 1 }).writerWaiters, 1)
            let overflow = @AssertThrows[WebSocketException](
                server.send(WebSocketFrame(WebSocketOpcode.Binary, payload: [8u8]), context: bounded))
            @Expect(webSocketTestError(overflow.code, WebSocketErrorCode.CapacityExceeded))
            @Expect(!server.isClosed())

            let large = client.receive(context: bounded)
            @Expect(webSocketTestOpcode(large.opcode, WebSocketOpcode.Binary))
            @Expect(large.payload.size, payload.size)
            var pongSeen = false
            var closeSeen = false
            for (_ in 0..4) {
                if (pongSeen && closeSeen) { break }
                let frame = client.receive(context: bounded)
                match (frame.opcode) {
                    case WebSocketOpcode.Pong =>
                        @Expect(frame.payload, "probe".toArray())
                        pongSeen = true
                    case WebSocketOpcode.Close => closeSeen = true
                    case _ => ()
                }
            }
            @Expect(pongSeen)
            @Expect(closeSeen)
            @Expect(webSocketTestOpcode(reader.get(3 * Duration.second).opcode, WebSocketOpcode.Ping))
            // The blocked and pending application writes may finish or fail once the close frame
            // is sent; either way the session must reach exactly one terminal state.
            webSocketTestSettle(blockedSend)
            webSocketTestSettle(pendingSend)
            webSocketTestSettle(closer)
            @Expect(server.isClosed())
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func terminalCleanupRunsExactlyOnceAfterGracefulCloseAndAfterFailure(): Unit {
        let (gracefulClient, gracefulServer) =
            MemoryTransport.pair(capacity: 4096, maxChunk: 4096)
        let gracefulCounting = WebSocketTestCountingTransport(gracefulServer)
        let gracefulPeer = WebSocketConnection(gracefulClient, WebSocketRole.Client)
        let graceful = WebSocketConnection(gracefulCounting, WebSocketRole.Server)
        let bounded = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        try {
            gracefulPeer.close(1000u16, "done", context: bounded)
            let closeFrame = graceful.receive(context: bounded)
            @Expect(webSocketTestOpcode(closeFrame.opcode, WebSocketOpcode.Close))
            @Expect(graceful.isClosed())
            let afterClose = gracefulCounting.terminalCounts()
            @Expect(afterClose.closes, 1)
            @Expect(afterClose.aborts, 0)
            graceful.close()
            gracefulPeer.close()
            let stable = gracefulCounting.terminalCounts()
            @Expect(stable.closes, 1)
            @Expect(stable.aborts, 0)
        } finally {
            graceful.close()
            gracefulPeer.close()
        }

        let (failedClient, failedServer) = MemoryTransport.pair(capacity: 4096, maxChunk: 4096)
        let failedCounting = WebSocketTestCountingTransport(failedServer)
        let failed = WebSocketConnection(failedCounting, WebSocketRole.Server)
        try {
            failedClient.close()
            let failure = @AssertThrows[WebSocketException](failed.receive(context: bounded))
            @Expect(webSocketTestError(failure.code, WebSocketErrorCode.TransportFailure))
            @Expect(failed.isClosed())
            let afterFailure = failedCounting.terminalCounts()
            @Expect(afterFailure.closes, 0)
            @Expect(afterFailure.aborts, 1)
            failed.close()
            failed.close()
            let stable = failedCounting.terminalCounts()
            @Expect(stable.closes, 0)
            @Expect(stable.aborts, 1)
        } finally {
            failed.close()
            failedClient.close()
        }

        let (raceClient, raceServer) = MemoryTransport.pair(capacity: 4096, maxChunk: 4096)
        let raceCounting = WebSocketTestCountingTransport(raceServer)
        let racePeer = WebSocketConnection(raceClient, WebSocketRole.Client)
        let race = WebSocketConnection(raceCounting, WebSocketRole.Server)
        try {
            let receiver = spawn {
                try { let _ = race.receive(context: bounded); true } catch (_: WebSocketException) { true }
            }
            let closers = Array<Future<Unit>>(4, { _ => spawn { race.close() } })
            let peerClose = spawn {
                try { racePeer.close(1000u16, "done", context: bounded) } catch (_: Exception) { () }
            }
            @Expect(receiver.get(3 * Duration.second))
            peerClose.get(3 * Duration.second)
            for (closer in closers) { closer.get(3 * Duration.second) }
            let counts = raceCounting.terminalCounts()
            @Expect(counts.closes + counts.aborts, 1)
            race.close()
            let stable = raceCounting.terminalCounts()
            @Expect(stable.closes + stable.aborts, 1)
        } finally {
            race.close()
            racePeer.close()
        }
    }
}

private func webSocketTestAwaitAdmission(
    session: WebSocketConnection,
    predicate: (WebSocketAdmissionState) -> Bool
): WebSocketAdmissionState {
    let deadline = Deadline.after(3 * Duration.second)
    while (!deadline.isExpired()) {
        let state = session.admissionState
        if (predicate(state)) { return state }
        sleep(Duration.millisecond)
    }
    throw Exception("WebSocket admission did not reach the expected state")
}

/** Waits for one racing caller to finish; a terminal close may legitimately fail it. */
private func webSocketTestSettle(future: Future<Unit>): Unit {
    try {
        future.get(3 * Duration.second)
    } catch (_: Exception) {
        ()
    }
}

/** Delegates to a real in-memory pair while counting terminal transport calls. */
private class WebSocketTestCountingTransport <: api.DuplexTransport {
    private let delegate: MemoryTransport
    private let mutex = Mutex()
    private var closes: Int64 = 0
    private var aborts: Int64 = 0

    init(delegate: MemoryTransport) {
        this.delegate = delegate
    }

    public prop info: api.TransportInfo { get() { delegate.info } }
    public func readSome(destination: api.MutableByteSpan,
        context!: OperationContext = OperationContext.background()): api.ReadResult {
        delegate.readSome(destination, context: context)
    }
    public func writeSome(source: api.ByteSpan,
        context!: OperationContext = OperationContext.background()): Int64 {
        delegate.writeSome(source, context: context)
    }
    public func shutdown(direction: api.ShutdownDirection): Unit { delegate.shutdown(direction) }
    public func close(context: OperationContext): Unit {
        synchronized(mutex) { closes++ }
        delegate.close(context)
    }
    public func close(): Unit {
        synchronized(mutex) { closes++ }
        delegate.close()
    }
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        synchronized(mutex) { aborts++ }
        delegate.abort(reason: reason)
    }
    public func isClosed(): Bool { delegate.isClosed() }
    func terminalCounts(): WebSocketTestTerminalCounts {
        synchronized(mutex) { WebSocketTestTerminalCounts(closes, aborts) }
    }
}

private struct WebSocketTestTerminalCounts {
    let closes: Int64
    let aborts: Int64

    init(closes: Int64, aborts: Int64) {
        this.closes = closes
        this.aborts = aborts
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

private class M8005WebSocketScenario {
    let wire: Array<Byte>
    let expectedFrames: Array<WebSocketFrame>
    let expectedError: WebSocketErrorCode
    let expectedCloseCode: ?UInt16
    let expectedOutput: Array<Byte>
    let expectAbort: Bool

    init(
        wire: Array<Byte>,
        expectedFrames: Array<WebSocketFrame>,
        expectedError: WebSocketErrorCode,
        expectedCloseCode: ?UInt16,
        expectedOutput: Array<Byte>,
        expectAbort: Bool
    ) {
        this.wire = wire.clone()
        this.expectedFrames = expectedFrames
        this.expectedError = expectedError
        this.expectedCloseCode = expectedCloseCode
        this.expectedOutput = expectedOutput.clone()
        this.expectAbort = expectAbort
    }
}

private class M8005WebSocketOutcome {
    let frames: Array<WebSocketFrame>
    let error: WebSocketErrorCode
    let closeCode: ?UInt16
    let errorCauseAbsent: Bool
    let output: Array<Byte>
    let gracefullyClosed: Bool
    let aborted: Bool
    let readCalls: Int64

    init(
        frames: Array<WebSocketFrame>,
        error: WebSocketErrorCode,
        closeCode: ?UInt16,
        errorCauseAbsent: Bool,
        output: Array<Byte>,
        gracefullyClosed: Bool,
        aborted: Bool,
        readCalls: Int64
    ) {
        this.frames = frames
        this.error = error
        this.closeCode = closeCode
        this.errorCauseAbsent = errorCauseAbsent
        this.output = output
        this.gracefullyClosed = gracefullyClosed
        this.aborted = aborted
        this.readCalls = readCalls
    }
}

private class M8005FiniteWebSocketTransport <: api.DuplexTransport {
    private let input: Array<Byte>
    private let maximumRead: Int64
    private let maximumReads: Int64
    private var offset: Int64 = 0
    private var calls: Int64 = 0
    private let output = ArrayList<Byte>()
    private var terminal = false
    private var graceful = false
    private var abortedByOwner = false

    init(input: Array<Byte>, maximumRead: Int64) {
        if (input.size > 192 || maximumRead <= 0) {
            throw IllegalArgumentException("M8-005 WebSocket fixture exceeds its finite bounds")
        }
        this.input = input.clone()
        this.maximumRead = maximumRead
        maximumReads = input.size + 8
    }

    public prop info: api.TransportInfo {
        get() { api.TransportInfo("m8005-websocket-finite", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        destination: api.MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): api.ReadResult {
        let _ = context
        calls++
        if (calls > maximumReads) {
            throw IllegalStateException("M8-005 WebSocket read-call budget exceeded")
        }
        if (destination.isEmpty()) { return api.ReadResult.Data(0) }
        if (terminal || offset == input.size) { return api.ReadResult.EndOfStream }
        let count = min(destination.length, min(maximumRead, input.size - offset))
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = input[offset + index]
        }
        offset += count
        api.ReadResult.Data(count)
    }

    public func writeSome(
        source: api.ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        if (terminal) { throw IllegalStateException("M8-005 WebSocket wrote after terminal ownership") }
        if (output.size + source.length > 256) {
            throw IllegalStateException("M8-005 WebSocket output budget exceeded")
        }
        for (index in 0..source.length) {
            output.add(source.bytes[source.offset + index])
        }
        source.length
    }

    public func shutdown(_: api.ShutdownDirection): Unit {}

    public func close(context: OperationContext): Unit {
        let _ = context
        if (!terminal) {
            terminal = true
            graceful = true
        }
    }

    public func abort(reason!: ?api.AbortReason): Unit {
        let _ = reason
        if (!terminal) {
            terminal = true
            abortedByOwner = true
        }
    }

    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { terminal }
    func written(): Array<Byte> { output.toArray() }
    func readCallCount(): Int64 { calls }
    func wasGracefullyClosed(): Bool { graceful }
    func wasAborted(): Bool { abortedByOwner }
}

private func m8005RunWebSocketWire(
    wire: Array<Byte>,
    maximumRead: Int64
): M8005WebSocketOutcome {
    let transport = M8005FiniteWebSocketTransport(wire, maximumRead)
    let limits = WebSocketLimits(
        maximumFrameBytes: 128,
        maximumMessageBytes: 128,
        ioBufferBytes: 1,
        closeTimeout: Duration.second
    )
    let connection = WebSocketConnection(transport, WebSocketRole.Server, limits: limits)
    var result: ?M8005WebSocketOutcome = None<M8005WebSocketOutcome>
    try {
        let frames = ArrayList<WebSocketFrame>()
        var terminal: ?WebSocketException = None<WebSocketException>
        while (terminal.isNone()) {
            if (frames.size >= 16) {
                throw IllegalStateException("M8-005 WebSocket frame-count bound exceeded")
            }
            try {
                frames.add(connection.receive())
            } catch (error: WebSocketException) {
                terminal = Some(error)
            }
        }
        let error = terminal.getOrThrow()
        @Assert(connection.isClosed())
        result = Some(M8005WebSocketOutcome(
            frames.toArray(),
            error.code,
            error.closeCode,
            error.cause.isNone(),
            transport.written(),
            transport.wasGracefullyClosed(),
            transport.wasAborted(),
            transport.readCallCount()
        ))
    } finally {
        connection.close()
    }
    result.getOrThrow()
}

private func m8005ExpectWebSocketOutcome(
    actual: M8005WebSocketOutcome,
    scenario: M8005WebSocketScenario
): Unit {
    m8005ExpectSafeWebSocketTermination(actual)
    m8005ExpectWebSocketTrace(actual.frames, scenario.expectedFrames)
    @Assert(webSocketTestError(actual.error, scenario.expectedError))
    @Assert(actual.closeCode, scenario.expectedCloseCode)
    @Assert(actual.output, scenario.expectedOutput)
    @Assert(actual.aborted, scenario.expectAbort)
    @Assert(actual.gracefullyClosed, !scenario.expectAbort)
}

private func m8005ExpectEquivalentWebSocketOutcome(
    actual: M8005WebSocketOutcome,
    baseline: M8005WebSocketOutcome
): Unit {
    m8005ExpectWebSocketTrace(actual.frames, baseline.frames)
    @Assert(webSocketTestError(actual.error, baseline.error))
    @Assert(actual.closeCode, baseline.closeCode)
    @Assert(actual.errorCauseAbsent, baseline.errorCauseAbsent)
    @Assert(actual.output, baseline.output)
    @Assert(actual.gracefullyClosed, baseline.gracefullyClosed)
    @Assert(actual.aborted, baseline.aborted)
}

private func m8005ExpectSafeWebSocketTermination(actual: M8005WebSocketOutcome): Unit {
    @Assert(actual.errorCauseAbsent)
    @Assert(actual.gracefullyClosed != actual.aborted)
}

private func m8005ExpectWebSocketTrace(
    actual: Array<WebSocketFrame>,
    expected: Array<WebSocketFrame>
): Unit {
    @Assert(actual.size, expected.size)
    for (index in 0..expected.size) {
        @Assert(webSocketTestOpcode(actual[index].opcode, expected[index].opcode))
        @Assert(actual[index].finalFragment, expected[index].finalFragment)
        @Assert(actual[index].payload, expected[index].payload)
    }
}

private func m8005WebSocketMutations(): Array<Array<Byte>> {
    let extendedPayload = Array<Byte>(126, repeat: 0x5au8)
    let seeds = [
        webSocketTestMaskedFrame(0x01u8, true, "hello".toArray()),
        m8005JoinWebSocketBytes([
            webSocketTestMaskedFrame(0x01u8, false, [0xe4u8, 0xb8u8]),
            webSocketTestMaskedFrame(0x00u8, true, [0xadu8])
        ]),
        webSocketTestMaskedFrame(0x09u8, true, "probe".toArray()),
        webSocketTestMaskedFrame(0x08u8, true, [0x03u8, 0xe8u8, b'o', b'k']),
        m8005ExtendedMaskedWebSocketFrame(0x02u8, extendedPayload)
    ]
    let replacements = [0u8, 1u8, 0x7fu8, 0x80u8, 0xffu8]
    let bitMasks = [1u8, 2u8, 4u8, 8u8, 0x10u8, 0x20u8, 0x40u8, 0x80u8]
    let mutations = ArrayList<Array<Byte>>()
    for (seed in seeds) {
        let positions = m8005WebSocketMutationPositions(seed.size)
        for (index in positions) {
            for (replacement in replacements) {
                if (replacement == seed[index]) { continue }
                let substituted = seed.clone()
                substituted[index] = replacement
                mutations.add(substituted)
            }
            for (bitMask in bitMasks) {
                let flipped = seed.clone()
                flipped[index] ^= bitMask
                mutations.add(flipped)
            }
            mutations.add(m8005DeleteWebSocketByte(seed, index))
            mutations.add(m8005WebSocketPrefix(seed, index))
        }
    }
    mutations.toArray()
}

private func m8005WebSocketMutationPositions(size: Int64): Array<Int64> {
    if (size <= 16) {
        let positions = ArrayList<Int64>()
        for (index in 0..size) { positions.add(index) }
        return positions.toArray()
    }
    [
        0i64, 1i64, 2i64, 3i64, 4i64, 5i64, 6i64, 7i64, 8i64,
        size / 2, size - 2, size - 1
    ]
}

private func m8005DeleteWebSocketByte(bytes: Array<Byte>, removed: Int64): Array<Byte> {
    let output = Array<Byte>(bytes.size - 1, repeat: 0u8)
    var target: Int64 = 0
    for (source in 0..bytes.size) {
        if (source == removed) { continue }
        output[target] = bytes[source]
        target++
    }
    output
}

private func m8005WebSocketCorpus(): Array<M8005WebSocketScenario> {
    let protocolOutput = m8005WebSocketCloseOutput(1002u16)
    let invalidPayloadOutput = m8005WebSocketCloseOutput(1007u16)
    let tooLargeOutput = m8005WebSocketCloseOutput(1009u16)
    let textSeed = webSocketTestMaskedFrame(0x01u8, true, [b'o', b'k'])

    let maskKeyMutation = textSeed.clone()
    maskKeyMutation[2] = 0u8
    let maskBitMutation = textSeed.clone()
    maskBitMutation[1] &= 0x7fu8
    let rsvMutation = textSeed.clone()
    rsvMutation[0] |= 0x40u8
    let reservedDataOpcode = textSeed.clone()
    reservedDataOpcode[0] = 0x83u8
    let reservedControlOpcode = textSeed.clone()
    reservedControlOpcode[0] = 0x8bu8

    let extendedPayload = Array<Byte>(126, repeat: 0x5au8)
    let extendedFrame = m8005ExtendedMaskedWebSocketFrame(0x02u8, extendedPayload)
    let fragmentedUtf8 = webSocketTestMaskedFrame(
        0x01u8, false, [0xe4u8, 0xb8u8]
    )
    let validUtf8Continuation = webSocketTestMaskedFrame(0x00u8, true, [0xadu8])
    let invalidUtf8Continuation = webSocketTestMaskedFrame(0x00u8, true, [b'A'])
    let incompleteUtf8Continuation = webSocketTestMaskedFrame(0x00u8, true, [])
    let pingPayload = "probe".toArray()
    let pingFrame = webSocketTestMaskedFrame(0x09u8, true, pingPayload)
    let closePayload = [0x03u8, 0xe8u8, b'o', b'k']
    let closeFrame = webSocketTestMaskedFrame(0x08u8, true, closePayload)
    let firstBoundedFragment = Array<Byte>(100, repeat: 1u8)
    let overflowingFragment = Array<Byte>(40, repeat: 2u8)

    return [
        M8005WebSocketScenario(
            maskKeyMutation,
            [WebSocketFrame(WebSocketOpcode.Text, payload: [b'n', b'k'])],
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            maskBitMutation, [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            [0x81u8, 0x81u8, 1u8, 2u8, 3u8], [], // Truncated mask key.
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            rsvMutation, [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            reservedDataOpcode, [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            reservedControlOpcode, [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            extendedFrame,
            [WebSocketFrame(WebSocketOpcode.Binary, payload: extendedPayload)],
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            [0x82u8, 0xfeu8, 0x00u8, 0x01u8], [], // Noncanonical 16-bit length.
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            // Noncanonical 64-bit length.
            [0x82u8, 0xffu8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0xffu8, 0xffu8],
            [], WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            // A 64-bit length with its forbidden high bit set.
            [0x82u8, 0xffu8, 0x80u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8],
            [], WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            // Canonical 64-bit length above the configured bound.
            [0x82u8, 0xffu8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8, 0u8, 0u8],
            [], WebSocketErrorCode.MessageTooLarge, Some(1009u16), tooLargeOutput, false
        ),
        M8005WebSocketScenario(
            pingFrame,
            [WebSocketFrame(WebSocketOpcode.Ping, payload: pingPayload)],
            WebSocketErrorCode.TransportFailure, None<UInt16>,
            m8005UnmaskedWebSocketFrame(0x0au8, pingPayload), true
        ),
        M8005WebSocketScenario(
            webSocketTestMaskedFrame(0x09u8, false, [b'x']), [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            [0x89u8, 0xfeu8, 0x00u8, 0x7eu8], [], // Oversized Ping.
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            m8005JoinWebSocketBytes([fragmentedUtf8, validUtf8Continuation]),
            [
                WebSocketFrame(
                    WebSocketOpcode.Text,
                    payload: [0xe4u8, 0xb8u8],
                    finalFragment: false
                ),
                WebSocketFrame(WebSocketOpcode.Continuation, payload: [0xadu8])
            ],
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            m8005JoinWebSocketBytes([fragmentedUtf8, invalidUtf8Continuation]),
            [
                WebSocketFrame(
                    WebSocketOpcode.Text,
                    payload: [0xe4u8, 0xb8u8],
                    finalFragment: false
                )
            ],
            WebSocketErrorCode.InvalidPayload, Some(1007u16), invalidPayloadOutput, false
        ),
        M8005WebSocketScenario(
            m8005JoinWebSocketBytes([fragmentedUtf8, incompleteUtf8Continuation]),
            [
                WebSocketFrame(
                    WebSocketOpcode.Text,
                    payload: [0xe4u8, 0xb8u8],
                    finalFragment: false
                )
            ],
            WebSocketErrorCode.InvalidPayload, Some(1007u16), invalidPayloadOutput, false
        ),
        M8005WebSocketScenario(
            // Continuation without an active message.
            webSocketTestMaskedFrame(0x00u8, true, [b'x']), [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            closeFrame,
            [WebSocketFrame(WebSocketOpcode.Close, payload: closePayload)],
            WebSocketErrorCode.Closed, None<UInt16>,
            m8005UnmaskedWebSocketFrame(0x08u8, closePayload), false
        ),
        M8005WebSocketScenario(
            webSocketTestMaskedFrame(0x08u8, true, [0x03u8]), [], // Incomplete close status.
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            // Reserved close status.
            webSocketTestMaskedFrame(0x08u8, true, [0x03u8, 0xedu8]), [],
            WebSocketErrorCode.ProtocolViolation, Some(1002u16), protocolOutput, false
        ),
        M8005WebSocketScenario(
            // Invalid UTF-8 in the close reason.
            webSocketTestMaskedFrame(0x08u8, true, [0x03u8, 0xe8u8, 0xffu8]), [],
            WebSocketErrorCode.InvalidPayload, Some(1007u16), invalidPayloadOutput, false
        ),
        M8005WebSocketScenario(
            // Fragmented message exceeds the aggregate byte bound.
            m8005JoinWebSocketBytes([
                webSocketTestMaskedFrame(0x02u8, false, firstBoundedFragment),
                webSocketTestMaskedFrame(0x00u8, true, overflowingFragment)
            ]),
            [
                WebSocketFrame(
                    WebSocketOpcode.Binary,
                    payload: firstBoundedFragment,
                    finalFragment: false
                )
            ],
            WebSocketErrorCode.MessageTooLarge, Some(1009u16), tooLargeOutput, false
        ),
        M8005WebSocketScenario(
            [0x81u8], [], // Truncated header.
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            [0x82u8, 0xfeu8, 0x00u8], [], // Truncated 16-bit length.
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            [0x82u8, 0xffu8, 0u8, 0u8, 0u8, 0u8], [], // Truncated 64-bit length.
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        ),
        M8005WebSocketScenario(
            m8005WebSocketPrefix(
                webSocketTestMaskedFrame(0x02u8, true, [1u8, 2u8, 3u8]),
                8
            ), [],
            WebSocketErrorCode.TransportFailure, None<UInt16>, [], true
        )
    ]
}

private func m8005ExtendedMaskedWebSocketFrame(
    opcode: Byte,
    payload: Array<Byte>
): Array<Byte> {
    let mask = [1u8, 2u8, 3u8, 4u8]
    let output = Array<Byte>(8 + payload.size, repeat: 0u8)
    output[0] = 0x80u8 | opcode
    output[1] = 0xfeu8
    output[2] = UInt8((payload.size >> 8) & 0xff)
    output[3] = UInt8(payload.size & 0xff)
    for (index in 0..mask.size) { output[4 + index] = mask[index] }
    for (index in 0..payload.size) {
        output[8 + index] = payload[index] ^ mask[index % mask.size]
    }
    output
}

private func m8005UnmaskedWebSocketFrame(
    opcode: Byte,
    payload: Array<Byte>
): Array<Byte> {
    let output = Array<Byte>(2 + payload.size, repeat: 0u8)
    output[0] = 0x80u8 | opcode
    output[1] = UInt8(payload.size)
    for (index in 0..payload.size) { output[2 + index] = payload[index] }
    output
}

private func m8005WebSocketCloseOutput(code: UInt16): Array<Byte> {
    [0x88u8, 0x02u8, UInt8(code >> 8), UInt8(code & 0xffu16)]
}

private func m8005JoinWebSocketBytes(parts: Array<Array<Byte>>): Array<Byte> {
    var size: Int64 = 0
    for (part in parts) { size += part.size }
    let output = Array<Byte>(size, repeat: 0u8)
    var offset: Int64 = 0
    for (part in parts) {
        for (index in 0..part.size) { output[offset + index] = part[index] }
        offset += part.size
    }
    output
}

private func m8005WebSocketPrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let output = Array<Byte>(count, repeat: 0u8)
    for (index in 0..count) { output[index] = bytes[index] }
    output
}
