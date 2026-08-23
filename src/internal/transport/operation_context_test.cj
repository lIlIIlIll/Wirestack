package wirestack.internal.transport

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OperationContextTest {
    @TestCase
    func backgroundHasNoDeadlineCancellationOrTrace(): Unit {
        let context = OperationContext.background()
        @Expect(context.deadline.isNone())
        @Expect(context.trace.isNone())
        @Expect(!context.isCancellationRequested())
        @Expect(!context.isDeadlineExceeded())
    }

    @TestCase
    func derivedContextRetainsCancellationAndTrace(): Unit {
        let source = CancellationSource()
        let trace = NetworkTraceContext("request-1", spanId: "connect")
        let context = OperationContext(cancellation: source.token, trace: Some(trace))
            .shortenDeadline(Duration.second)

        @Expect(context.deadline.isSome())
        @Expect(context.trace.getOrThrow().traceId, "request-1")
        @Expect(!context.isCancellationRequested())
        source.cancel()
        @Expect(context.isCancellationRequested())
    }

    @TestCase
    func earlierDeadlineCannotBeExtended(): Unit {
        let now = MonoTime.now()
        let early = Deadline(now + Duration.second)
        let late = Deadline(now + 2 * Duration.second)
        let context = OperationContext(deadline: Some(early))

        let unchanged = context.withEarlierDeadline(late)
        @Expect(unchanged.deadline.getOrThrow().expiresAt, early.expiresAt)

        let shortened = context.withEarlierDeadline(Deadline(now + 10 * Duration.millisecond))
        @Expect(shortened.deadline.getOrThrow().expiresAt < early.expiresAt)
    }

    @TestCase
    func traceIdentifiersAreBoundedAndNonEmpty(): Unit {
        var emptyRejected = false
        try {
            let _ = NetworkTraceContext("")
        } catch (_: IllegalArgumentException) {
            emptyRejected = true
        }

        var oversizedRejected = false
        try {
            let _ = NetworkTraceContext("x" * 129)
        } catch (_: IllegalArgumentException) {
            oversizedRejected = true
        }

        @Expect(emptyRejected)
        @Expect(oversizedRejected)
    }
}
