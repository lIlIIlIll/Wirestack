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
            let transport = ReviewContinueBudgetTransport(clock, fallback)
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

private class ReviewContinueManualClock <: MonotonicClock {
    let start = MonoTime.now()
    private var current = start
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

private class ReviewContinueBudgetTransport <: DuplexTransport {
    private let clock: ReviewContinueManualClock
    private let fallback: Bool
    private var reads: Int64 = 0
    private var writes: Int64 = 0

    init(clock: ReviewContinueManualClock, fallback: Bool) {
        this.clock = clock
        this.fallback = fallback
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
            clock.advance(if (fallback) { 6 * Duration.millisecond } else { 8 * Duration.millisecond })
        }
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func close(_: OperationContext): Unit {}
    public func abort(reason!: ?api.AbortReason): Unit { let _ = reason }
}
