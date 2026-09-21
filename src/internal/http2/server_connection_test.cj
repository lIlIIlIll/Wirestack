package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2ServerConnectionTest {
    @TestCase
    func explicitAbortWakesBlockedRequestBodyAndConverges(): Unit {
        let handler = BlockingConnectionHandler()
        let fixture = ServerConnectionFixture(handler)
        let serving = fixture.start()
        try {
            fixture.sendRequest(endStream: false)
            handler.waitUntilReading()
            fixture.connection.abort()
            fixture.connection.abort()
            @Expect(handler.waitForOutcome(), "connection")
            @Expect(handler.responseBody.waitUntilClosed(), 1)
            serving.get(Duration.second)
            @Expect(fixture.connection.isClosed())
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func readerEofWakesBlockedRequestBodyWithoutInventingEof(): Unit {
        let handler = BlockingConnectionHandler()
        let fixture = ServerConnectionFixture(handler)
        let serving = fixture.start()
        try {
            fixture.sendRequest(endStream: false)
            handler.waitUntilReading()
            fixture.client.shutdown(ShutdownDirection.Write)
            @Expect(handler.waitForOutcome(), "connection")
            @Expect(handler.responseBody.waitUntilClosed(), 1)
            serving.get(Duration.second)
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func serveCancellationUsesTheSameContextForHandlerBodyAndWriter(): Unit {
        let source = CancellationSource()
        let handler = BlockingConnectionHandler()
        let fixture = ServerConnectionFixture(handler)
        let context = OperationContext(
            cancellation: source.token,
            trace: Some(NetworkTraceContext("server-cancel-trace"))
        )
        let serving = fixture.start(context: context)
        try {
            fixture.sendRequest(endStream: false)
            handler.waitUntilReading()
            let _ = source.cancel()
            @Expect(handler.waitForOutcome(), "cancelled")
            @Expect(handler.observedTrace(), "server-cancel-trace")
            @Expect(handler.responseBody.waitUntilClosed(), 1)
            serving.get(Duration.second)
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func serveDeadlineWakesBlockedRequestBodyAndAllOwnedTasksConverge(): Unit {
        let handler = BlockingConnectionHandler()
        let fixture = ServerConnectionFixture(handler)
        let context = OperationContext(
            deadline: Some(Deadline.after(250 * Duration.millisecond)),
            trace: Some(NetworkTraceContext("server-deadline-trace"))
        )
        let serving = fixture.start(context: context)
        try {
            fixture.sendRequest(endStream: false)
            handler.waitUntilReading()
            @Expect(handler.waitForOutcome(), "deadline")
            @Expect(handler.observedTrace(), "server-deadline-trace")
            @Expect(handler.responseBody.waitUntilClosed(), 1)
            serving.get(Duration.second)
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func flowBackpressureStopsOnServeCancellationAndClosesResponsePlan(): Unit {
        let source = CancellationSource()
        let body = TrackingConnectionBody(96 * 1024)
        let handler = ResponseConnectionHandler(body)
        let fixture = ServerConnectionFixture(handler)
        let serving = fixture.start(context: OperationContext(cancellation: source.token))
        try {
            fixture.sendRequest(endStream: true)
            handler.waitUntilCalled()
            body.waitForReads(4)
            let _ = source.cancel()
            @Expect(body.waitUntilClosed(), 1)
            serving.get(Duration.second)
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func initialHeadersWriteFailureStillClosesUnopenedResponsePlan(): Unit {
        let body = TrackingConnectionBody(1)
        let handler = ResponseConnectionHandler(body)
        let wire = serverConnectionInput(endStream: true)
        let transport = FailingServerWriteTransport(wire, failAfterWrites: 1)
        let connection = Http2ServerConnection(transport, handler)
        let serving = spawn { connection.serve() }
        try {
            handler.waitUntilCalled()
            @Expect(body.waitUntilClosed(), 1)
            serving.get(Duration.second)
            @Expect(transport.abortCalls.load(), 1)
        } finally {
            connection.abort()
            transport.abort()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func completedResponseUnregistersReaderListenerBeforeNextStream(): Unit {
        let handler = CountingConnectionHandler()
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024, maxChunk: 31)
        let server = Http2ServerConnection(
            serverTransport, handler,
            http2Limits: Http2Limits(maxConcurrentStreams: 1u32)
        )
        let serving = spawn { server.serve() }
        let client = Http2ClientConnection.connect(clientTransport)
        try {
            for (index in 0..2) {
                let response = client.execute(HttpRequest.get("https://example.test/${index}"))
                try {
                    @Expect(response.status, 204)
                    @Expect(response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
                } finally {
                    response.close()
                }
            }
            @Expect(handler.calls.load(), 2)
        } finally {
            client.abort()
            server.abort()
            serverTransport.abort()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func handlerFailureResetsStreamWithoutPublishingItsMessage(): Unit {
        let sentinel = "handler-secret-sentinel"
        let handler = ThrowingConnectionHandler(sentinel)
        let fixture = ServerConnectionFixture(handler)
        let serving = fixture.start()
        try {
            fixture.sendRequest(endStream: true)
            let observed = fixture.readUntil(Http2FrameType.RstStream)
            @Expect(
                http2ErrorCodeToWire(decodeHttp2RstStream(observed)),
                http2ErrorCodeToWire(Http2ErrorCode.InternalError)
            )
            @Expect(!containsConnectionBytes(fixture.receivedBytes(), sentinel.toArray()))
        } finally {
            fixture.abortBoth()
            try { serving.get(Duration.second) } catch (_: Exception) {}
        }
    }
}

private class ServerConnectionFixture {
    let client: MemoryTransport
    let server: MemoryTransport
    let connection: Http2ServerConnection
    private let parser = Http2FrameParser()
    private let received = ArrayList<Byte>()

    init(handler: Http2ServerHandler) {
        let (createdClient, createdServer) = MemoryTransport.pair(
            capacity: 1024 * 1024, maxChunk: 37
        )
        client = createdClient
        server = createdServer
        connection = Http2ServerConnection(server, handler)
    }

    func start(context!: OperationContext = OperationContext.background()): Future<Unit> {
        spawn { connection.serve(context: context) }
    }

    func sendRequest(endStream!: Bool): Unit {
        writeAll(client, ByteSpan(serverConnectionInput(endStream: endStream)))
    }

    func readUntil(frameType: Http2FrameType): Http2Frame {
        let buffer = Array<Byte>(16 * 1024, repeat: 0u8)
        let context = OperationContext(deadline: Some(Deadline.after(Duration.second)))
        while (true) {
            let count = match (client.readSome(MutableByteSpan(buffer), context: context)) {
                case ReadResult.Data(value) => value
                case ReadResult.EndOfStream => throw Exception("server closed before expected frame")
            }
            for (index in 0..count) { received.add(buffer[index]) }
            let chunk = Array<Byte>(count, repeat: 0u8)
            for (index in 0..count) { chunk[index] = buffer[index] }
            for (frame in parser.feed(chunk)) {
                if (sameConnectionFrameType(frame.header.frameType, frameType)) { return frame }
            }
        }
        throw Exception("unreachable expected-frame loop exit")
    }

    func receivedBytes(): Array<Byte> { received.toArray() }

    func abortBoth(): Unit {
        connection.abort()
        client.abort()
        server.abort()
    }
}

private class BlockingConnectionHandler <: Http2ServerHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var reading = false
    private var outcome = ""
    private var trace = ""
    let responseBody = TrackingConnectionBody(0)

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        synchronized(mutex) {
            if (let Some(value) <- context.trace) { trace = value.traceId }
            reading = true
            changed.notifyAll()
        }
        let observed = classifyConnectionBodyRead(request.body)
        synchronized(mutex) { outcome = observed; changed.notifyAll() }
        Http2ServerResponse(HttpResponse(204, "No Content", ResponseBody(responseBody)))
    }

    func waitUntilReading(): Unit {
        waitForConnectionPredicate({ => reading }, mutex, changed, "handler did not begin request body read")
    }

    func waitForOutcome(): String {
        waitForConnectionPredicate({ => !outcome.isEmpty() }, mutex, changed, "handler body read did not terminate")
        synchronized(mutex) { outcome }
    }

    func observedTrace(): String { synchronized(mutex) { trace } }
}

private class ResponseConnectionHandler <: Http2ServerHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var called = false
    private let body: TrackingConnectionBody

    init(body: TrackingConnectionBody) { this.body = body }

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        let _ = request
        let _ = context
        synchronized(mutex) { called = true; changed.notifyAll() }
        Http2ServerResponse(HttpResponse(200, "OK", ResponseBody(body)))
    }

    func waitUntilCalled(): Unit {
        waitForConnectionPredicate({ => called }, mutex, changed, "handler did not return its response")
    }
}

private class CountingConnectionHandler <: Http2ServerHandler {
    let calls = AtomicInt64(0)
    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        let _ = request
        let _ = context
        let _ = calls.fetchAdd(1)
        Http2ServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
    }
}

private class ThrowingConnectionHandler <: Http2ServerHandler {
    private let message: String
    init(message: String) { this.message = message }
    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        let _ = request
        let _ = context
        throw Exception(message)
    }
}

private class TrackingConnectionBody <: HttpBodyStream {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let length: Int64
    private var offset: Int64 = 0
    private var closed = false
    private var reads: Int64 = 0
    let closeCalls = AtomicInt64(0)

    init(length: Int64) { this.length = length }
    public prop contentLength: ?Int64 { get() { Some(length) } }

    public func read(destination: Array<Byte>): Int64 {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("tracked response body is closed") }
            reads++
            changed.notifyAll()
            if (destination.isEmpty() || offset == length) { return 0 }
            let count = min(destination.size, length - offset)
            for (index in 0..count) { destination[index] = b'x' }
            offset += count
            count
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (closed) { return }
            closed = true
            let _ = closeCalls.fetchAdd(1)
            changed.notifyAll()
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    func waitForReads(expected: Int64): Unit {
        waitForConnectionPredicate(
            { => reads >= expected }, mutex, changed,
            "response body did not reach flow-control backpressure"
        )
    }

    func waitUntilClosed(): Int64 {
        waitForConnectionPredicate({ => closed }, mutex, changed, "response body ownership was not closed")
        closeCalls.load()
    }
}

private class FailingServerWriteTransport <: DuplexTransport {
    private let mutex = Mutex()
    private let input: Array<Byte>
    private let failAfterWrites: Int64
    private var offset: Int64 = 0
    private var writes: Int64 = 0
    private var closed = false
    let abortCalls = AtomicInt64(0)

    init(input: Array<Byte>, failAfterWrites!: Int64) {
        this.input = input.clone()
        this.failAfterWrites = failAfterWrites
    }

    public prop info: TransportInfo { get() { TransportInfo("http2-server-failing-write-test") } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        synchronized(mutex) {
            if (offset == input.size) { return ReadResult.EndOfStream }
            let count = min(destination.length, input.size - offset)
            for (index in 0..count) {
                destination.bytes[destination.offset + index] = input[offset + index]
            }
            offset += count
            ReadResult.Data(count)
        }
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        synchronized(mutex) {
            writes++
            if (writes > failAfterWrites) { throw Exception("scripted HTTP/2 write failure") }
            source.length
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit { let _ = direction }
    public func close(context: OperationContext): Unit { let _ = context; synchronized(mutex) { closed = true } }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        let won = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (won) { let _ = abortCalls.fetchAdd(1) }
    }
}

private func serverConnectionInput(endStream!: Bool): Array<Byte> {
    let block = HpackEncoder().encode([
        HpackFieldEncoding(HpackHeaderField(":method", "POST")),
        HpackFieldEncoding(HpackHeaderField(":scheme", "https")),
        HpackFieldEncoding(HpackHeaderField(":authority", "example.test")),
        HpackFieldEncoding(HpackHeaderField(":path", "/blocked"))
    ])
    let flags: Byte = if (endStream) { 0x05u8 } else { 0x04u8 }
    let headers = serializeHttp2Frame(Http2Frame(
        Http2FrameHeader(
            UInt32(block.size), Http2FrameType.Headers, Http2Flags(raw: flags),
            Http2StreamId(1u32)
        ),
        block
    ))
    let settings = serializeHttp2Frame(encodeHttp2Settings([]))
    let output = Array<Byte>(http2ClientPreface().size + settings.size + headers.size, repeat: 0u8)
    var offset: Int64 = 0
    for (part in [http2ClientPreface(), settings, headers]) {
        for (index in 0..part.size) { output[offset + index] = part[index] }
        offset += part.size
    }
    output
}

private func classifyConnectionBodyRead(body: ResponseBody): String {
    try {
        let count = body.read(Array<Byte>(1, repeat: 0u8))
        "eof:${count}"
    } catch (error: NetworkException) {
        match (error.code) {
            case NetworkErrorCode.Cancelled => "cancelled"
            case NetworkErrorCode.TimedOut => "deadline"
            case _ => "network"
        }
    } catch (error: Http2ProtocolException) {
        match (error.scope) {
            case Http2ErrorScope.Connection => "connection"
            case Http2ErrorScope.Stream(_) => "stream"
        }
    } catch (_: Exception) {
        "other"
    }
}

private func waitForConnectionPredicate(
    predicate: () -> Bool,
    mutex: Mutex,
    changed: Condition,
    failure: String
): Unit {
    let deadline = Deadline.after(Duration.second)
    synchronized(mutex) {
        while (!predicate()) {
            if (deadline.isExpired()) { throw Exception(failure) }
            changed.wait(timeout: deadline.remaining())
        }
    }
}

private func sameConnectionFrameType(left: Http2FrameType, right: Http2FrameType): Bool {
    match ((left, right)) {
        case (Http2FrameType.RstStream, Http2FrameType.RstStream) => true
        case (Http2FrameType.Settings, Http2FrameType.Settings) => true
        case (Http2FrameType.Headers, Http2FrameType.Headers) => true
        case (Http2FrameType.Data, Http2FrameType.Data) => true
        case (Http2FrameType.GoAway, Http2FrameType.GoAway) => true
        case _ => false
    }
}

private func containsConnectionBytes(haystack: Array<Byte>, needle: Array<Byte>): Bool {
    if (needle.isEmpty()) { return true }
    if (haystack.size < needle.size) { return false }
    for (offset in 0..(haystack.size - needle.size + 1)) {
        var matched = true
        for (index in 0..needle.size) {
            if (haystack[offset + index] != needle[index]) { matched = false; break }
        }
        if (matched) { return true }
    }
    false
}
