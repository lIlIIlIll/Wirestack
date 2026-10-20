package wirestack.internal.http1

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1ResponseHeaderBudgetReviewTest {
    @TestCase
    func expectContinueRetainsOneResponseHeadersBudgetAcrossBodyWrite(): Unit {
        for (fallback in [false, true]) {
            let clock = ReviewContinueManualClock()
            let bodyWriteAdvance = if (fallback) { 6 * Duration.millisecond } else { 8 * Duration.millisecond }
            let transport = ReviewContinueBudgetTransport(clock, fallback, bodyWriteAdvance)
            let request = HttpRequest(
                HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
                headers: HttpHeaders.builder()
                    .add("Content-Length", "1")
                    .add("Expect", "100-continue")
                    .build(),
                body: RequestBody.bytes([120u8])
            )
            let writer = Http1RequestWriter(request)
            let context = OperationContext(
                deadline: Some(Deadline.after(Duration.second, clock: clock)),
                timeoutPolicy: OperationTimeoutPolicy(
                    responseHeaders: Some(10 * Duration.millisecond)
                )
            )
            let error = @AssertThrows[api.NetworkException](exchangeHttp1ExpectContinue(
                transport, request, writer, 5 * Duration.millisecond, context: context
            ))
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => @Fail("response-header budget was restarted after the body write")
            }
            match (error.phase) {
                case api.NetworkPhase.HttpHeaders => ()
                case _ => @Fail("Expect/Continue timeout lost its response-header phase")
            }
            @Expect(writer.evidence.bodyBytesWritten, 1)
            @Expect(clock.now(), clock.start + 12 * Duration.millisecond)
        }
    }
}

@Test
class Http1ResponseHeaderBoundaryReviewTest {
    @TestCase
    func responseHeaderBudgetExpiryBeforeContinueDoesNotSendBody(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewContinueBudgetTransport(clock, true, Duration.Zero)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([120u8])
        )
        let writer = Http1RequestWriter(request)
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(
                responseHeaders: Some(5 * Duration.millisecond)
            )
        )
        let error = @AssertThrows[api.NetworkException](exchangeHttp1ExpectContinue(
            transport, request, writer, 20 * Duration.millisecond, context: context
        ))
        match (error.code) {
            case api.NetworkErrorCode.TimedOut => ()
            case _ => @Fail("expired response-header budget lost its timeout")
        }
        match (error.phase) {
            case api.NetworkPhase.HttpHeaders => ()
            case _ => @Fail("expired response-header budget lost its phase")
        }
        @Expect(writer.evidence.bodyBytesWritten, 0)
        @Expect(clock.now(), clock.start + 6 * Duration.millisecond)
    }

    @TestCase
    func finalResponseWithinOriginalHeaderBudgetAfterContinueBodyWriteSucceeds(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewContinueBudgetTransport(clock, false, 4 * Duration.millisecond)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([120u8])
        )
        let writer = Http1RequestWriter(request)
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(
                responseHeaders: Some(10 * Duration.millisecond)
            )
        )
        let result = exchangeHttp1ExpectContinue(
            transport, request, writer, 5 * Duration.millisecond, context: context
        )
        @Expect(result.response.status, 200)
        @Expect(writer.evidence.bodyBytesWritten, 1)
        @Expect(clock.now(), clock.start + 8 * Duration.millisecond)
        result.response.close()
    }
}

@Test
class Http1LateReadDeadlineReviewTest {
    @TestCase
    func responseHeadersReturnedAfterBudgetExpiryAreRejected(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
            clock: Some(clock), lateHeader: true
        )
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([120u8])
        )
        let writer = Http1RequestWriter(request)
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(responseHeaders: Some(5 * Duration.millisecond))
        )
        let error = @AssertThrows[api.NetworkException](exchangeHttp1ExpectContinue(
            transport, request, writer, Duration.second, context: context
        ))
        match (error.category) {
            case api.NetworkErrorCategory.DeadlineExceeded => ()
            case _ => @Fail("late response headers did not report a deadline error")
        }
        match (error.code) {
            case api.NetworkErrorCode.TimedOut => ()
            case _ => @Fail("late response headers did not report a timeout code")
        }
        match (error.phase) {
            case api.NetworkPhase.HttpHeaders => ()
            case _ => @Fail("late response headers lost their phase")
        }
        @Expect(writer.evidence.bodyBytesWritten, 0)
    }

    @TestCase
    func lateFinalResponseAfterContinueDeadlineDoesNotSendRequestBody(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n",
            clock: Some(clock), lateHeader: true
        )
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([120u8])
        )
        let writer = Http1RequestWriter(request)
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(responseHeaders: Some(20 * Duration.millisecond))
        )
        let error = @AssertThrows[api.NetworkException](exchangeHttp1ExpectContinue(
            transport, request, writer, 5 * Duration.millisecond, context: context
        ))
        @Expect(writer.evidence.bodyBytesWritten, 0)
        match (error.category) {
            case api.NetworkErrorCategory.DeadlineExceeded => ()
            case _ => @Fail("late final response did not retain its deadline error")
        }
        match (error.code) {
            case api.NetworkErrorCode.TimedOut => ()
            case _ => @Fail("late final response lost its timeout code")
        }
        match (error.phase) {
            case api.NetworkPhase.HttpHeaders => ()
            case _ => @Fail("late final response lost its response-header phase")
        }
    }

    @TestCase
    func responseBodyBytesReturnedAfterIdleExpiryAreRejected(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n",
            clock: Some(clock), tail: [120u8], lateTail: true
        )
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([121u8])
        )
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(
                responseHeaders: Some(5 * Duration.millisecond),
                bodyReadIdle: Some(5 * Duration.millisecond)
            )
        )
        let result = exchangeHttp1ExpectContinue(
            transport, request, Http1RequestWriter(request), Duration.second, context: context
        )
        try {
            let error = @AssertThrows[api.NetworkException](
                result.response.body.read(Array<Byte>(1, repeat: 0u8))
            )
            match (error.category) {
                case api.NetworkErrorCategory.DeadlineExceeded => ()
                case _ => @Fail("late response body data did not report a deadline error")
            }
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => @Fail("late response body data did not report a timeout code")
            }
            match (error.phase) {
                case api.NetworkPhase.HttpBody => ()
                case _ => @Fail("late response body data lost its phase")
            }
        } finally {
            result.response.close()
        }
    }

    @TestCase
    func upgradedBytesReturnedAfterIdleExpiryAreRejected(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: review/1\r\n\r\n",
            clock: Some(clock), tail: [120u8], lateTail: true
        )
        let request = HttpRequest.get("http://example.test/socket").withHeaders(
            HttpHeaders.builder()
                .add("Connection", "Upgrade")
                .add("Upgrade", "review/1")
                .build()
        )
        let upgraded = match (performHttp1Upgrade(transport, request)) {
            case Http1UpgradeExchangeResult.Upgraded(value) => value
            case _ => throw Exception("expected HTTP/1 Upgrade handoff")
        }
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(streamReadIdle: Some(5 * Duration.millisecond))
        )
        let buffer = Array<Byte>(1, repeat: 0u8)
        try {
            let error = @AssertThrows[api.NetworkException](upgraded.transport.readSome(
                MutableByteSpan(buffer), context: context
            ))
            match (error.category) {
                case api.NetworkErrorCategory.DeadlineExceeded => ()
                case _ => @Fail("late upgraded data did not report a deadline error")
            }
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => @Fail("late upgraded data did not report a timeout code")
            }
            match (error.phase) {
                case api.NetworkPhase.TcpRead => ()
                case _ => @Fail("late upgraded data lost its TCP-read phase")
            }
        } finally {
            upgraded.transport.abort(reason: Some(api.AbortReason.DeadlineExceeded))
        }
    }
}

@Test
class Http1RequestWriteBudgetReviewTest {
    @TestCase
    func expectContinueReusesOneRequestWriteBudgetForHeadAndBody(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewWriteBudgetTransport(clock)
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder()
                .add("Content-Length", "1")
                .add("Expect", "100-continue")
                .build(),
            body: RequestBody.bytes([120u8])
        )
        let writer = Http1RequestWriter(request)
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(
                requestWrite: Some(5 * Duration.millisecond)
            )
        )
        let error = @AssertThrows[Http1RequestWriteException](exchangeHttp1ExpectContinue(
            transport, request, writer, Duration.second, context: context
        ))
        @Expect(transport.headWrites, 1)
        @Expect(transport.bodyWriteAttempted, true)
        @Expect(transport.bodyWriteExpired, true)
        @Expect(transport.bodyWriteCompleted, false)
        @Expect(writer.evidence.bodyBytesWritten, 0)
        @Expect(error.cause.isSome())
        match (error.cause.getOrThrow()) {
            case value: api.NetworkException =>
                match (value.code) {
                    case api.NetworkErrorCode.TimedOut => ()
                    case _ => @Fail("request-write budget expiry lost its timeout")
                }
            case _ => @Fail("request-write budget expiry lost its network cause")
        }
    }
    @TestCase
    func completeRequestReusesOneRequestWriteBudgetForHeadAndBody(): Unit {
        let clock = ReviewContinueManualClock()
        let transport = ReviewWriteBudgetTransport(
            clock,
            headWriteAdvance: 4 * Duration.millisecond,
            bodyWriteAdvance: 2 * Duration.millisecond
        )
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.test/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "1").build(),
            body: RequestBody.bytes([120u8])
        )
        let context = OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(requestWrite: Some(5 * Duration.millisecond))
        )
        let error = @AssertThrows[Http1RequestWriteException](
            writeHttp1Request(transport, request, context: context)
        )
        @Expect(transport.headWrites, 1)
        @Expect(transport.bodyWriteAttempted, true)
        @Expect(transport.bodyWriteExpired, true)
        @Expect(transport.bodyWriteCompleted, false)
        @Expect(error.evidence.wireBytesWritten > 0)
        @Expect(error.evidence.bodyBytesWritten, 0)
        @Expect(clock.now(), clock.start + 6 * Duration.millisecond)
        match (error.cause.getOrThrow()) {
            case value: api.NetworkException =>
                match (value.code) {
                    case api.NetworkErrorCode.TimedOut => ()
                    case _ => @Fail("request-write budget expiry lost its timeout")
                }
                match (value.phase) {
                    case api.NetworkPhase.TcpWrite => ()
                    case _ => @Fail("request-write budget expiry lost its TCP-write phase")
                }
            case _ => @Fail("request-write budget expiry lost its network cause")
        }
    }

}

@Test
class Http1UpgradedReadBudgetReviewTest {
    @TestCase
    func upgradeHandoffAppliesStreamReadIdleToTransportReads(): Unit {
        let probe = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: review/1\r\n\r\n"
        )
        let request = HttpRequest.get("http://example.test/socket").withHeaders(
            HttpHeaders.builder()
                .add("Connection", "Upgrade")
                .add("Upgrade", "review/1")
                .build()
        )
        let upgraded = match (performHttp1Upgrade(probe, request)) {
            case Http1UpgradeExchangeResult.Upgraded(value) => value
            case _ => throw Exception("expected HTTP/1 Upgrade handoff")
        }
        proveUpgradedReadBudget(
            upgraded.transport, probe, reviewReadBudgetContext()
        )
        upgraded.transport.close()
    }

    @TestCase
    func connectHandoffAppliesStreamReadIdleOnlyWhenRequested(): Unit {
        let bounded = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 200 Connection Established\r\n\r\n"
        )
        let boundedExchanged = performHttp1Connect(
            bounded, HttpUrl.parse("https://example.test/"),
            readTimeoutStage: Some(OperationTimeoutStage.StreamReadIdle)
        )
        let boundedTunnel = match (boundedExchanged) {
            case Http1ConnectExchangeResult.Tunnel(value) => value
            case _ => throw Exception("expected HTTP/1 CONNECT tunnel")
        }
        proveUpgradedReadBudget(
            boundedTunnel.transport, bounded, reviewReadBudgetContext()
        )
        boundedTunnel.transport.close()

        let proxy = ReviewUpgradeReadBudgetTransport(
            "HTTP/1.1 200 Connection Established\r\n\r\n"
        )
        let proxyExchanged = performHttp1Connect(proxy, HttpUrl.parse("https://example.test/"))
        let proxyTunnel = match (proxyExchanged) {
            case Http1ConnectExchangeResult.Tunnel(value) => value
            case _ => throw Exception("expected HTTP/1 proxy CONNECT tunnel")
        }
        let context = reviewReadBudgetContext()
        let buffer = Array<Byte>(1, repeat: 0u8)
        match (proxyTunnel.transport.readSome(MutableByteSpan(buffer), context: context)) {
            case ReadResult.EndOfStream => ()
            case _ => @Fail("internal proxy tunnel probe returned unexpected data")
        }
        match (proxy.readBudgetRemaining) {
            case Some(remaining) => @Expect(remaining > 5 * Duration.millisecond)
            case None => @Fail("internal proxy tunnel lost its parent read context")
        }
        proxyTunnel.transport.close()
    }

    private func proveUpgradedReadBudget(
        transport: DuplexTransport,
        probe: ReviewUpgradeReadBudgetTransport,
        context: OperationContext
    ): Unit {
        let buffer = Array<Byte>(1, repeat: 0u8)
        match (transport.readSome(MutableByteSpan(buffer), context: context)) {
            case ReadResult.EndOfStream => ()
            case _ => @Fail("upgraded transport read probe returned unexpected data")
        }
        match (probe.readBudgetRemaining) {
            case Some(remaining) =>
                @Expect(remaining > Duration.Zero)
                @Expect(remaining <= 5 * Duration.millisecond)
            case None => @Fail("upgraded transport forwarded an unbounded read context")
        }
    }
}

private func reviewReadBudgetContext(): OperationContext {
    let clock = ReviewContinueManualClock()
    OperationContext(
        deadline: Some(Deadline.after(Duration.second, clock: clock)),
        timeoutPolicy: OperationTimeoutPolicy(streamReadIdle: Some(5 * Duration.millisecond))
    )
}

private class ReviewUpgradeReadBudgetTransport <: DuplexTransport {
    private let responseWire: Array<Byte>
    private let clock: ?ReviewContinueManualClock
    private let tail: Array<Byte>
    private let lateHeader: Bool
    private let lateTail: Bool
    private var wireOffset: Int64 = 0
    private var tailOffset: Int64 = 0
    private var budgetRemaining: ?Duration = None<Duration>

    init(
        responseWire: String,
        clock!: ?ReviewContinueManualClock = None<ReviewContinueManualClock>,
        tail!: Array<Byte> = [],
        lateHeader!: Bool = false,
        lateTail!: Bool = false
    ) {
        this.responseWire = responseWire.toArray()
        this.clock = clock
        this.tail = tail
        this.lateHeader = lateHeader
        this.lateTail = lateTail
    }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        if (wireOffset < responseWire.size) {
            if (lateHeader) { clock.getOrThrow().advance(6 * Duration.millisecond) }
            let count = min(destination.length, responseWire.size - wireOffset)
            for (index in 0..count) {
                destination.bytes[destination.offset + index] = responseWire[wireOffset + index]
            }
            wireOffset += count
            return ReadResult.Data(count)
        }
        if (tailOffset < tail.size) {
            if (lateTail) { clock.getOrThrow().advance(6 * Duration.millisecond) }
            let count = min(destination.length, tail.size - tailOffset)
            for (index in 0..count) {
                destination.bytes[destination.offset + index] = tail[tailOffset + index]
            }
            tailOffset += count
            return ReadResult.Data(count)
        }
        budgetRemaining = match (context.deadline) {
            case Some(deadline) => Some(deadline.remaining())
            case None => None<Duration>
        }
        ReadResult.EndOfStream
    }

    prop readBudgetRemaining: ?Duration { get() { budgetRemaining } }

    public prop info: TransportInfo { get() { TransportInfo("review-upgrade-read-budget-test") } }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func close(_: OperationContext): Unit {}
    public func abort(reason!: ?api.AbortReason): Unit { let _ = reason }
}

private class ReviewContinueManualClock <: MonotonicClock {
    let start = MonoTime.now()
    private var current = start
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

private class ReviewContinueBudgetTransport <: DuplexTransport {
    private let clock: ReviewContinueManualClock
    private let fallback: Bool
    private let bodyWriteAdvance: Duration
    private var reads: Int64 = 0
    private var writes: Int64 = 0

    init(clock: ReviewContinueManualClock, fallback: Bool, bodyWriteAdvance: Duration) {
        this.clock = clock
        this.fallback = fallback
        this.bodyWriteAdvance = bodyWriteAdvance
    }

    public prop info: TransportInfo { get() { TransportInfo("review-continue-budget-test") } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        reads++
        if (reads == 1) {
            clock.advance(if (fallback) { 6 * Duration.millisecond } else { 4 * Duration.millisecond })
        }
        if (context.isDeadlineExceeded()) {
            throw api.NetworkException(
                api.NetworkErrorCategory.DeadlineExceeded,
                api.NetworkPhase.HttpHeaders,
                api.NetworkErrorCode.TimedOut,
                "response wait expired"
            )
        }
        let wire = if (reads == 1 && !fallback) {
            "HTTP/1.1 100 Continue\r\n\r\n"
        } else {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        }
        let bytes = wire.toArray()
        for (index in 0..bytes.size) {
            destination.bytes[destination.offset + index] = bytes[index]
        }
        ReadResult.Data(bytes.size)
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        writes++
        if (writes == 2) {
            clock.advance(bodyWriteAdvance)
        }
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func close(_: OperationContext): Unit {}
    public func abort(reason!: ?api.AbortReason): Unit { let _ = reason }
}

private class ReviewWriteBudgetTransport <: DuplexTransport {
    private let clock: ReviewContinueManualClock
    private let headWriteAdvance: Duration
    private let bodyWriteAdvance: Duration
    private var reads: Int64 = 0
    private var writes: Int64 = 0
    private var headWriteCount: Int64 = 0
    private var attemptedBody = false
    private var expiredBody = false
    private var completedBody = false

    init(
        clock: ReviewContinueManualClock,
        headWriteAdvance!: Duration = 6 * Duration.millisecond,
        bodyWriteAdvance!: Duration = Duration.Zero
    ) {
        this.clock = clock
        this.headWriteAdvance = headWriteAdvance
        this.bodyWriteAdvance = bodyWriteAdvance
    }


    prop headWrites: Int64 { get() { headWriteCount } }
    prop bodyWriteAttempted: Bool { get() { attemptedBody } }
    prop bodyWriteExpired: Bool { get() { expiredBody } }
    prop bodyWriteCompleted: Bool { get() { completedBody } }

    public prop info: TransportInfo { get() { TransportInfo("review-request-write-budget-test") } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        reads++
        let wire = if (reads == 1) {
            "HTTP/1.1 100 Continue\r\n\r\n"
        } else {
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        }
        let bytes = wire.toArray()
        for (index in 0..bytes.size) {
            destination.bytes[destination.offset + index] = bytes[index]
        }
        ReadResult.Data(bytes.size)
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        writes++
        if (writes == 1) {
            headWriteCount++
            clock.advance(headWriteAdvance)
            return source.length
        }
        attemptedBody = true
        if (context.isDeadlineExceeded()) {
            expiredBody = true
            throw api.NetworkException(
                api.NetworkErrorCategory.DeadlineExceeded,
                api.NetworkPhase.TcpWrite,
                api.NetworkErrorCode.TimedOut,
                "request-write budget expired before the body write"
            )
        }
        clock.advance(bodyWriteAdvance)
        if (context.isDeadlineExceeded()) {
            expiredBody = true
            throw api.NetworkException(
                api.NetworkErrorCategory.DeadlineExceeded,
                api.NetworkPhase.TcpWrite,
                api.NetworkErrorCode.TimedOut,
                "request-write budget expired during the body write"
            )
        }
        completedBody = true
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func close(_: OperationContext): Unit {}
    public func abort(reason!: ?api.AbortReason): Unit { let _ = reason }
}
