package wirestack.internal.transport

import std.collection.ArrayList
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
        @Expect(context.eventSink.isNone())
        @Expect(!context.isCancellationRequested())
        @Expect(!context.isDeadlineExceeded())
    }

    @TestCase
    func derivedContextsRetainEventSinkAndSinkFailuresAreIsolated(): Unit {
        let sink = RecordingNetworkEventSink()
        let context = OperationContext(
            trace: Some(NetworkTraceContext("trace-1")), eventSink: Some(sink)
        ).shortenDeadline(Duration.second)
        @Expect(context.eventSink.isSome())

        emitNetworkEvent(context, NetworkEvent(
            NetworkEventKind.HttpConnectionAcquired,
            NetworkEventOutcome.Succeeded,
            trace: context.trace
        ))
        @Expect(sink.events.size, 1)
        @Expect(sink.events[0].trace.getOrThrow().traceId, "trace-1")

        // Observability is never allowed to change operation completion.
        emitNetworkEvent(
            context.withEventSink(Some<NetworkEventSink>(ThrowingNetworkEventSink())),
            NetworkEvent(NetworkEventKind.ConnectionClosed, NetworkEventOutcome.Succeeded)
        )
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
    func derivationHelpersChangeOnlyTheirNamedField(): Unit {
        let originalSource = CancellationSource()
        let replacementSource = CancellationSource()
        let trace = NetworkTraceContext("request-2", spanId: "headers")
        let sink = RecordingNetworkEventSink()
        let parent = Deadline.after(24 * Duration.hour)
        let context = OperationContext(
            deadline: Some(parent),
            cancellation: originalSource.token,
            trace: Some(trace),
            eventSink: Some(sink)
        )

        let replacedCancellation = context.withCancellation(replacementSource.token)
        let clearedTrace = context.withTrace(None<NetworkTraceContext>)
        let clearedSink = context.withEventSink(None<NetworkEventSink>)
        let relativeChild = context.shortenDeadline(Duration.second)
        let earlier = Deadline(MonoTime.now() + 2 * Duration.second)
        let absoluteChild = context.withEarlierDeadline(earlier)

        @Expect(replacedCancellation.deadline.getOrThrow().expiresAt, parent.expiresAt)
        @Expect(replacedCancellation.trace.getOrThrow().traceId, trace.traceId)
        @Expect(replacedCancellation.eventSink.isSome())
        @Expect(clearedTrace.deadline.getOrThrow().expiresAt, parent.expiresAt)
        @Expect(clearedTrace.trace.isNone())
        @Expect(clearedTrace.eventSink.isSome())
        @Expect(clearedSink.deadline.getOrThrow().expiresAt, parent.expiresAt)
        @Expect(clearedSink.trace.getOrThrow().traceId, trace.traceId)
        @Expect(clearedSink.eventSink.isNone())
        @Expect(relativeChild.deadline.getOrThrow().expiresAt < parent.expiresAt)
        @Expect(relativeChild.trace.getOrThrow().traceId, trace.traceId)
        @Expect(relativeChild.eventSink.isSome())
        @Expect(absoluteChild.deadline.getOrThrow().expiresAt, earlier.expiresAt)
        @Expect(absoluteChild.trace.getOrThrow().traceId, trace.traceId)
        @Expect(absoluteChild.eventSink.isSome())
        @Expect(context.deadline.getOrThrow().expiresAt, parent.expiresAt)
        @Expect(context.trace.getOrThrow().traceId, trace.traceId)
        @Expect(context.eventSink.isSome())

        originalSource.cancel()
        @Expect(context.isCancellationRequested())
        @Expect(!replacedCancellation.isCancellationRequested())
        @Expect(clearedTrace.isCancellationRequested())
        @Expect(clearedSink.isCancellationRequested())
        @Expect(relativeChild.isCancellationRequested())
        @Expect(absoluteChild.isCancellationRequested())
        replacementSource.cancel()
        @Expect(replacedCancellation.isCancellationRequested())
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
        let boundary = "x" * 128
        let accepted = NetworkTraceContext(boundary, spanId: boundary)
        @Expect(accepted.traceId, boundary)
        @Expect(accepted.spanId, boundary)

        @Expect(traceContextIsRejected("", ""))
        @Expect(traceContextIsRejected("x" * 129, ""))
        @Expect(traceContextIsRejected("trace", "x" * 129))
    }
    @TestCase
    func stageDeadlinesAreIndependentAndRemainCappedByTotalDeadline(): Unit {
        let clock = PolicyFakeMonotonicClock(MonoTime.now())
        let total = Deadline.after(3 * Duration.second, clock: clock)
        let policy = OperationTimeoutPolicy(
            dns: Some(Duration.second), tcpConnect: Some(2 * Duration.second)
        )
        let context = OperationContext(deadline: Some(total), timeoutPolicy: policy)
        let dns = context.forStage(OperationTimeoutStage.Dns)
        let tcp = context.forStage(OperationTimeoutStage.TcpConnect)

        @Expect(dns.deadline.getOrThrow().expiresAt < tcp.deadline.getOrThrow().expiresAt)
        @Expect(tcp.deadline.getOrThrow().expiresAt < total.expiresAt)
        @Expect(dns.timeoutPolicy.dns, Some(Duration.second))

        clock.advance(250 * Duration.millisecond)
        let retryDns = context.forStage(OperationTimeoutStage.Dns)
        @Expect(retryDns.deadline.getOrThrow().expiresAt, clock.now() + Duration.second)
        @Expect(retryDns.deadline.getOrThrow().expiresAt < total.expiresAt)

        let shortTotal = Deadline.after(250 * Duration.millisecond, clock: clock)
        let capped = OperationContext(
            deadline: Some(shortTotal),
            timeoutPolicy: OperationTimeoutPolicy(dns: Some(Duration.second))
        ).forStage(OperationTimeoutStage.Dns)
        @Expect(capped.deadline.getOrThrow().expiresAt, shortTotal.expiresAt)
    }

    @TestCase
    func timeoutPolicyRejectsZeroAndNegativeBudgets(): Unit {
        var zeroRejected = false
        var negativeRejected = false
        try {
            let _ = OperationTimeoutPolicy(bodyReadIdle: Some(Duration.Zero))
        } catch (_: IllegalArgumentException) {
            zeroRejected = true
        }
        try {
            let _ = OperationTimeoutPolicy(streamReadIdle: Some(Duration.Zero - Duration.second))
        } catch (_: IllegalArgumentException) {
            negativeRejected = true
        }
        @Expect(zeroRejected)
        @Expect(negativeRejected)
    }
}

private func traceContextIsRejected(traceId: String, spanId: String): Bool {
    try {
        let _ = NetworkTraceContext(traceId, spanId: spanId)
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private class RecordingNetworkEventSink <: NetworkEventSink {
    let events = ArrayList<NetworkEvent>()
    public func emit(event: NetworkEvent): Unit { events.add(event) }
}

private class ThrowingNetworkEventSink <: NetworkEventSink {
    public func emit(event: NetworkEvent): Unit {
        let _ = event
        throw Exception("sink failure")
    }
}

private class PolicyFakeMonotonicClock <: MonotonicClock {
    private var current: MonoTime

    init(start: MonoTime) { current = start }

    public func now(): MonoTime { current }

    func advance(duration: Duration): Unit {
        current = current + duration
    }
}
