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
