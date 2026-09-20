package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

private const SERVER_PUSH_TEST_BYTES: Int64 = 70000

@Test
class Http2ServerPushLifecycleTest {
    @TestCase
    func largePushDoesNotDelayParentHeadersUntilPushCreditReturns(): Unit {
        let fixture = LiveHttp2Server(
            LargePushServerHandler(),
            Http2Limits(maxConcurrentPushes: 1u32, maxPendingPushes: 1u32,
                maxPushesPerRequest: 1u32),
            1
        )
        try {
            let parent = fixture.client.execute(
                HttpRequest.get("https://example.test/large-parent"),
                context: lifecycleDeadline()
            )
            try {
                @Expect(parent.status, 204)
                let pushed = parent.pushes.getOrThrow().receive(
                    context: lifecycleDeadline()
                ).getOrThrow()
                try {
                    @Expect(pushed.request.url.toString(), "https://example.test:443/large-body")
                    let bytes = readLifecycleBody(pushed.response.body)
                    @Expect(bytes.size, SERVER_PUSH_TEST_BYTES)
                    var contentMatches = true
                    for (value in bytes) {
                        if (value != b'x') { contentMatches = false; break }
                    }
                    @Expect(contentMatches)
                } finally { pushed.close() }
            } finally { parent.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func cancelledPushReleasesItsWorkerSlotForTheNextParent(): Unit {
        let handler = CancellingPushServerHandler()
        let fixture = LiveHttp2Server(
            handler,
            Http2Limits(maxConcurrentPushes: 1u32, maxPendingPushes: 1u32,
                maxPushesPerRequest: 1u32),
            1
        )
        try {
            let first = fixture.client.execute(
                HttpRequest.get("https://example.test/cancel-first"),
                context: lifecycleDeadline()
            )
            handler.pushStalled.wait()
            handler.cancelPush()
            let second = fixture.client.execute(
                HttpRequest.get("https://example.test/cancel-second"),
                context: lifecycleDeadline()
            )
            @Expect(handler.pushLifetime.isClosed())
            try {
                @Expect(second.status, 204)
                let pushed = second.pushes.getOrThrow().receive(
                    context: lifecycleDeadline()
                ).getOrThrow()
                try {
                    @Expect(pushed.request.url.toString(), "https://example.test/after-cancel")
                    @Expect(String.fromUtf8(readLifecycleBody(pushed.response.body)), "released")
                } finally { pushed.close() }
            } finally {
                second.close()
                first.close()
            }
        } finally { fixture.close() }
    }

    @TestCase
    func crossOriginPushIsRejectedAndItsResponseIsClosedBeforeAnyOffer(): Unit {
        let handler = CrossOriginPushServerHandler()
        let fixture = LiveHttp2Server(handler, Http2Limits(), 2)
        try {
            let parent = fixture.client.execute(
                HttpRequest.get("https://example.test/origin"),
                context: lifecycleDeadline()
            )
            try {
                @Expect(parent.status, 204)
                @Expect(handler.rejected.load())
                @Expect(handler.responseClosed.load())
                @Expect(parent.pushes.getOrThrow().receive(
                    context: lifecycleDeadline()
                ).isNone())
            } finally { parent.close() }
        } finally { fixture.close() }
    }

    @TestCase
    func parentResetWhileWaitingForPushSlotIsRevalidatedBeforeReservation(): Unit {
        let handler = PostWaitResetServerHandler()
        let fixture = LiveHttp2Server(
            handler,
            Http2Limits(maxConcurrentPushes: 1u32, maxPendingPushes: 1u32,
                maxPushesPerRequest: 1u32),
            1
        )
        try {
            let heldParent = fixture.client.execute(
                HttpRequest.get("https://example.test/hold"),
                context: lifecycleDeadline()
            )
            let heldPush = heldParent.pushes.getOrThrow().receive(
                context: lifecycleDeadline()
            ).getOrThrow()
            let waitingCancellation = CancellationSource()
            let waiting = spawn {
                try {
                    let response = fixture.client.execute(
                        HttpRequest.get("https://example.test/waiting"),
                        context: OperationContext(cancellation: waitingCancellation.token)
                    )
                    response.close()
                    false
                } catch (_: Exception) { true }
            }
            handler.waitingEntered.wait()
            waitingCancellation.cancel()
            @Expect(waiting.get(Duration.second * 5))

            // The barrier request is serialized after the client's RST_STREAM,
            // so its handler proves that the server has removed the waiting parent.
            let barrier = fixture.client.execute(
                HttpRequest.get("https://example.test/barrier"),
                context: lifecycleDeadline()
            )
            barrier.close()
            heldPush.close()
            handler.waitingFinished.wait()
            @Expect(handler.rejectedAfterWait.load())
            heldParent.close()
        } finally { fixture.close() }
    }

    @TestCase
    func resetOfBlockedPushDoesNotBlockReaderOrReleaseWorkerSlotEarly(): Unit {
        let handler = ResetBlockedPushServerHandler()
        let fixture = LiveHttp2Server(
            handler,
            Http2Limits(maxConcurrentPushes: 1u32, maxPendingPushes: 1u32,
                maxPushesPerRequest: 1u32),
            1
        )
        try {
            let blockedParent = fixture.client.execute(
                HttpRequest.get("https://example.test/blocked"),
                context: lifecycleDeadline()
            )
            let blockedPush = blockedParent.pushes.getOrThrow().receive(
                context: lifecycleDeadline()
            ).getOrThrow()
            handler.readEntered.wait()
            blockedPush.close()

            // This response requires the reader to process frames after the
            // pushed-stream reset; reset notification must not call body.close.
            let barrier = fixture.client.execute(
                HttpRequest.get("https://example.test/barrier-after-reset"),
                context: lifecycleDeadline()
            )
            barrier.close()

            let replacement = spawn {
                try {
                    let parent = fixture.client.execute(
                        HttpRequest.get("https://example.test/replacement"),
                        context: lifecycleDeadline()
                    )
                    try {
                        let pushed = parent.pushes.getOrThrow().receive(
                            context: lifecycleDeadline()
                        ).getOrThrow()
                        try {
                            String.fromUtf8(readLifecycleBody(pushed.response.body)) ==
                                "replacement"
                        } finally { pushed.close() }
                    } finally { parent.close() }
                } catch (_: Exception) { false }
            }
            handler.replacementEntered.wait()
            let schedulingBarrier = fixture.client.execute(
                HttpRequest.get("https://example.test/scheduling-barrier"),
                context: lifecycleDeadline()
            )
            schedulingBarrier.close()
            @Expect(!handler.replacementFinished.isRaised())

            handler.releaseBlocked.signal()
            @Expect(replacement.get(Duration.second * 5))
            handler.replacementFinished.wait()
            blockedParent.close()
        } finally {
            handler.releaseBlocked.signal()
            fixture.close()
        }
    }

    @TestCase
    func blockingHeaderOnlyBodyCloseDoesNotDelayInboundReset(): Unit {
        let handler = BlockingHeaderOnlyPushServerHandler()
        let fixture = LiveHttp2Server(handler, Http2Limits(), 1)
        let cancellation = CancellationSource()
        try {
            let cancelled = spawn {
                try {
                    let response = fixture.client.execute(
                        HttpRequest.get("https://example.test/blocking-map"),
                        context: OperationContext(cancellation: cancellation.token)
                    )
                    response.close()
                    false
                } catch (_: Exception) { true }
            }
            handler.closeEntered.wait()
            cancellation.cancel()
            @Expect(cancelled.get(Duration.second * 5))

            // This request is serialized after RST_STREAM. Mapping may block
            // its handler task, but it must not retain the reset admission lock.
            let barrier = fixture.client.execute(
                HttpRequest.get("https://example.test/map-close-barrier"),
                context: lifecycleDeadline()
            )
            barrier.close()
            handler.releaseClose.signal()
            handler.mappingFinished.wait()
            @Expect(handler.rejectedAfterMapping.load())
        } finally {
            handler.releaseClose.signal()
            fixture.close()
        }
    }

    @TestCase
    func duplexHandlerReturnAbortsBothStreamDirections(): Unit {
        let handler = ReturningDuplexServerHandler()
        let fixture = LiveHttp2Server(handler, Http2Limits(), 1)
        try {
            let result = fixture.client.connectStream(
                HttpRequest(
                    HttpMethod("CONNECT"),
                    HttpUrl.parse("https://example.test:443/")
                ),
                context: lifecycleDeadline()
            )
            match (result) {
                case Http2ConnectResult.Connected(connected) =>
                    handler.mayReturn.signal()
                    let buffer = Array<Byte>(1, repeat: 0u8)
                    try {
                        let _ = connected.transport.readSome(
                            MutableByteSpan(buffer), context: lifecycleDeadline()
                        )
                    } catch (_: Exception) {}
                    var writeRejected = false
                    try {
                        let _ = connected.transport.writeSome(
                            ByteSpan([b'x']), context: lifecycleDeadline()
                        )
                    } catch (_: Exception) { writeRejected = true }
                    @Expect(writeRejected)
                    @Expect(connected.transport.isClosed())
                    connected.close()
                case Http2ConnectResult.Rejected(response) =>
                    response.close()
                    throw Exception("duplex lifecycle test did not establish CONNECT")
            }
        } finally { fixture.close() }
    }
}

private class LargePushServerHandler <: Http2ServerHandler {
    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        request.pushSender.getOrThrow().push(
            HttpRequest.get("https://EXAMPLE.TEST:443/large-body"),
            Http2ServerResponse(HttpResponse(
                200, "OK",
                ResponseBody(RequestBody.bytes(
                    Array<Byte>(SERVER_PUSH_TEST_BYTES, repeat: b'x')
                ).open())
            )),
            context: context, lifetime: None<Resource>
        )
        emptyLifecycleResponse()
    }
}

private class CancellingPushServerHandler <: Http2ServerHandler {
    let pushStalled = LifecycleSignal()
    private let cancellation = CancellationSource()
    let pushLifetime = LifecycleLease()

    func cancelPush(): Unit { cancellation.cancel() }

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        if (request.head.target == "/cancel-first") {
            request.pushSender.getOrThrow().push(
                HttpRequest.get("https://example.test/will-cancel"),
                Http2ServerResponse(HttpResponse(
                    200, "OK",
                    ResponseBody(SignallingLargeServerBody(pushStalled))
                )),
                context: OperationContext(cancellation: cancellation.token),
                lifetime: Some<Resource>(pushLifetime)
            )
            return emptyLifecycleResponse()
        }
        request.pushSender.getOrThrow().push(
            HttpRequest.get("https://example.test/after-cancel"),
            Http2ServerResponse(HttpResponse(
                200, "OK", ResponseBody(RequestBody.string("released").open())
            )),
            context: context, lifetime: None<Resource>
        )
        emptyLifecycleResponse()
    }
}

private class CrossOriginPushServerHandler <: Http2ServerHandler {
    let rejected = AtomicBool(false)
    let responseClosed = AtomicBool(false)

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        let response = Http2ServerResponse(HttpResponse(
            200, "OK", ResponseBody(RequestBody.string("must-close").open())
        ))
        try {
            request.pushSender.getOrThrow().push(
                HttpRequest.get("https://example.test:444/cross-origin"), response,
                context: context, lifetime: None<Resource>
            )
        } catch (_: IllegalArgumentException) {
            rejected.store(true)
        }
        responseClosed.store(response.response.isClosed())
        emptyLifecycleResponse()
    }
}

private class PostWaitResetServerHandler <: Http2ServerHandler {
    let waitingEntered = LifecycleSignal()
    let waitingFinished = LifecycleSignal()
    let rejectedAfterWait = AtomicBool(false)

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        match (request.head.target) {
            case "/hold" =>
                request.pushSender.getOrThrow().push(
                    HttpRequest.get("https://example.test/held-push"),
                    Http2ServerResponse(HttpResponse(
                        200, "OK",
                        ResponseBody(RequestBody.bytes(
                            Array<Byte>(SERVER_PUSH_TEST_BYTES, repeat: b'h')
                        ).open())
                    )),
                    context: context, lifetime: None<Resource>
                )
            case "/waiting" =>
                waitingEntered.signal()
                try {
                    request.pushSender.getOrThrow().push(
                        HttpRequest.get("https://example.test/must-not-promise"),
                        Http2ServerResponse(HttpResponse(
                            204, "No Content", ResponseBody.empty()
                        )),
                        context: context, lifetime: None<Resource>
                    )
                } catch (_: IllegalStateException) {
                    rejectedAfterWait.store(true)
                } finally {
                    waitingFinished.signal()
                }
            case _ => ()
        }
        emptyLifecycleResponse()
    }
}

private class ResetBlockedPushServerHandler <: Http2ServerHandler {
    let readEntered = LifecycleSignal()
    let releaseBlocked = LifecycleSignal()
    let replacementEntered = LifecycleSignal()
    let replacementFinished = LifecycleSignal()

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        match (request.head.target) {
            case "/blocked" =>
                request.pushSender.getOrThrow().push(
                    HttpRequest.get("https://example.test/blocked-push"),
                    Http2ServerResponse(HttpResponse(
                        200, "OK",
                        ResponseBody(ResetBlockedServerBody(readEntered, releaseBlocked))
                    )),
                    context: context, lifetime: None<Resource>
                )
            case "/replacement" =>
                replacementEntered.signal()
                try {
                    request.pushSender.getOrThrow().push(
                        HttpRequest.get("https://example.test/replacement-push"),
                        Http2ServerResponse(HttpResponse(
                            200, "OK",
                            ResponseBody(RequestBody.string("replacement").open())
                        )),
                        context: context, lifetime: None<Resource>
                    )
                } finally { replacementFinished.signal() }
            case _ => ()
        }
        emptyLifecycleResponse()
    }
}

private class BlockingHeaderOnlyPushServerHandler <: Http2ServerHandler {
    let closeEntered = LifecycleSignal()
    let releaseClose = LifecycleSignal()
    let mappingFinished = LifecycleSignal()
    let rejectedAfterMapping = AtomicBool(false)

    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        if (request.head.target == "/blocking-map") {
            try {
                request.pushSender.getOrThrow().push(
                    HttpRequest.get("https://example.test/header-only"),
                    Http2ServerResponse(HttpResponse(
                        204, "No Content",
                        ResponseBody(BlockingCloseServerBody(closeEntered, releaseClose))
                    )),
                    context: context, lifetime: None<Resource>
                )
            } catch (_: IllegalStateException) {
                rejectedAfterMapping.store(true)
            } finally { mappingFinished.signal() }
        }
        emptyLifecycleResponse()
    }
}

private class ReturningDuplexServerHandler <: Http2ServerHandler & Http2DuplexHandler {
    let mayReturn = LifecycleSignal()

    public func handle(_: Http2ServerRequest, _: OperationContext): Http2ServerResponse {
        Http2ServerResponse(
            HttpResponse(200, "OK", ResponseBody.empty()),
            duplexHandler: Some<Http2DuplexHandler>(this)
        )
    }

    public func serve(_: DuplexTransport, _: OperationContext): Unit {
        mayReturn.wait()
    }
}

private class SignallingLargeServerBody <: HttpBodyStream {
    private let fourthRead: LifecycleSignal
    private let mutex = Mutex()
    private var offset: Int64 = 0
    private var reads: Int64 = 0
    private var closed = false

    init(fourthRead: LifecycleSignal) {
        this.fourthRead = fourthRead
    }

    public prop contentLength: ?Int64 { get() { Some(SERVER_PUSH_TEST_BYTES) } }

    public func read(destination: Array<Byte>): Int64 {
        let (count, signal) = synchronized(mutex) {
            if (closed) { throw IllegalStateException("signalling server body is closed") }
            if (offset == SERVER_PUSH_TEST_BYTES) { return 0 }
            let progress = min(destination.size, SERVER_PUSH_TEST_BYTES - offset)
            for (index in 0..progress) { destination[index] = b'c' }
            offset += progress
            reads++
            (progress, reads == 4)
        }
        if (signal) { fourthRead.signal() }
        count
    }

    public func close(): Unit { synchronized(mutex) { closed = true } }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private class ResetBlockedServerBody <: HttpBodyStream {
    private let readEntered: LifecycleSignal
    private let releaseBlocked: LifecycleSignal
    private let mutex = Mutex()
    private var delivered = false
    private var closed = false

    init(readEntered: LifecycleSignal, releaseBlocked: LifecycleSignal) {
        this.readEntered = readEntered
        this.releaseBlocked = releaseBlocked
    }

    public prop contentLength: ?Int64 { get() { Some(1) } }

    public func read(destination: Array<Byte>): Int64 {
        readEntered.signal()
        releaseBlocked.wait()
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("reset-blocked server body is closed") }
            if (delivered) { return 0 }
            destination[0] = b'b'
            delivered = true
            1
        }
    }

    public func close(): Unit {
        releaseBlocked.wait()
        synchronized(mutex) { closed = true }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }
}


private class BlockingCloseServerBody <: HttpBodyStream {
    private let closeEntered: LifecycleSignal
    private let releaseClose: LifecycleSignal
    private let closed = AtomicBool(false)

    init(closeEntered: LifecycleSignal, releaseClose: LifecycleSignal) {
        this.closeEntered = closeEntered
        this.releaseClose = releaseClose
    }

    public prop contentLength: ?Int64 { get() { Some(0) } }

    public func read(_: Array<Byte>): Int64 {
        throw IllegalStateException("header-only response body must not be read")
    }

    public func close(): Unit {
        closeEntered.signal()
        releaseClose.wait()
        closed.store(true)
    }

    public func isClosed(): Bool { closed.load() }
}

private class LifecycleLease <: Resource {
    private let closed = AtomicBool(false)

    public func close(): Unit { closed.store(true) }
    public func isClosed(): Bool { closed.load() }
}

private class LifecycleSignal {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var raised = false

    func signal(): Unit {
        synchronized(mutex) {
            raised = true
            changed.notifyAll()
        }
    }

    func wait(): Unit {
        let deadline = Deadline.after(Duration.second * 5)
        synchronized(mutex) {
            while (!raised) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for HTTP/2 server lifecycle event")
                }
                changed.wait(timeout: remaining)
            }
        }
    }
    func isRaised(): Bool { synchronized(mutex) { raised } }
}

private class LiveHttp2Server <: Resource {
    let server: Http2ServerConnection
    let client: Http2ClientConnection
    private let serving: Future<Unit>

    init(handler: Http2ServerHandler, serverLimits: Http2Limits, clientPushLimit: Int64) {
        let (clientTransport, serverTransport) = MemoryTransport.pair(
            capacity: 64 * 1024, maxChunk: 4096
        )
        let createdServer = Http2ServerConnection(
            serverTransport, handler, http2Limits: serverLimits
        )
        server = createdServer
        serving = spawn { createdServer.serve() }
        client = Http2ClientConnection.connect(
            clientTransport,
            pushConfig: Some(Http2PushConfig(
                AllowLifecyclePushPolicy(),
                maximumConcurrentPushes: clientPushLimit,
                maximumPendingPushes: clientPushLimit,
                maximumPushesPerRequest: clientPushLimit
            ))
        )
    }

    public func close(): Unit {
        client.abort()
        server.abort()
        try { let _ = serving.get(Duration.second) } catch (_: Exception) {}
    }

    public func isClosed(): Bool { server.isClosed() }
}

private class AllowLifecyclePushPolicy <: Http2PushPolicy {
    public func allow(_: HttpUrl, _: HttpUrl, _: OperationContext): Bool { true }
}

private func emptyLifecycleResponse(): Http2ServerResponse {
    Http2ServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
}

private func lifecycleDeadline(): OperationContext {
    OperationContext(deadline: Some(Deadline.after(Duration.second * 5)))
}

private func readLifecycleBody(body: ResponseBody): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(8192, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { return output.toArray() }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    throw Exception("unreachable HTTP/2 lifecycle body read")
}
