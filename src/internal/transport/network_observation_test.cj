package wirestack.internal.transport

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import std.time.MonoTime

@Test
class NetworkObservationTest {
    @TestCase
    func fullDiagnosticBufferDropsNewestAndDrainsOldestWithoutRetainingIds(): Unit {
        let sink = api.NetworkEventBuffer(capacity: 2)
        let operation = OperationContext(eventSink: Some<api.NetworkEventSink>(sink), requestId: Some(91))
        for (attempt in 11..15) {
            api.emitNetworkEvent(operation, api.NetworkEvent(api.NetworkEventKind.AttemptCompleted,
                api.NetworkEventOutcome.Succeeded, attemptId: Some(attempt)))
        }
        @Expect(sink.snapshot().droppedEvents, 2)
        let first = sink.drain()
        @Expect(first[0].attemptId, Some(11))
        @Expect(first[1].attemptId, Some(12))
        @Expect(first[0].requestId, Some(91))
        api.emitNetworkEvent(operation, api.NetworkEvent(api.NetworkEventKind.AttemptCompleted,
            api.NetworkEventOutcome.Failed, attemptId: Some(19)))
        let next = sink.drain()
        @Expect(next[0].attemptId, Some(19))
        @Assert(match (next[0].outcome) { case api.NetworkEventOutcome.Failed => true; case _ => false })
        @Expect(sink.snapshot().queuedEvents, 0)
        @Expect(sink.snapshot().droppedEvents, 2)
    }

    @TestCase
    func largerStageCapReportsTotalDeadlineRatherThanInventingStageTimeout(): Unit {
        let clock = ObservationClock()
        let sink = api.NetworkEventBuffer(capacity: 4)
        let operation = OperationContext(deadline: Some(Deadline.after(Duration.second, clock: clock)),
            eventSink: Some<api.NetworkEventSink>(sink),
            timeoutPolicy: OperationTimeoutPolicy(responseHeaders: Some(5 * Duration.second)))
            .forStage(OperationTimeoutStage.ResponseHeaders)
        clock.advance(2 * Duration.second)
        api.emitNetworkEvent(operation, api.NetworkEvent(api.NetworkEventKind.StageCompleted,
            api.NetworkEventOutcome.Failed, errorCode: Some(api.NetworkErrorCode.TimedOut)))
        let event = sink.drain()[0]
        @Assert(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.TotalDeadline) => true; case _ => false })
        @Expect(event.timeoutStage.isNone(), true)
        @Assert(match (event.stage) { case Some(OperationTimeoutStage.ResponseHeaders) => true; case _ => false })
    }

    @TestCase
    func nestedWaitReportsOriginalShorterStageOwnerNotTheLastVisitedStage(): Unit {
        let clock = ObservationClock()
        let sink = api.NetworkEventBuffer(capacity: 4)
        let stage = OperationContext(deadline: Some(Deadline.after(60 * Duration.second, clock: clock)),
            eventSink: Some<api.NetworkEventSink>(sink),
            timeoutPolicy: OperationTimeoutPolicy(dns: Some(Duration.second), tcpConnect: Some(5 * Duration.second)))
            .forStage(OperationTimeoutStage.Dns).forStage(OperationTimeoutStage.TcpConnect)
        clock.advance(2 * Duration.second)
        api.emitNetworkEvent(stage, api.NetworkEvent(api.NetworkEventKind.StageCompleted,
            api.NetworkEventOutcome.Failed, errorCode: Some(api.NetworkErrorCode.TimedOut)))
        let event = sink.drain()[0]
        @Assert(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.StageLimit) => true; case _ => false })
        @Assert(match (event.timeoutStage) { case Some(OperationTimeoutStage.Dns) => true; case _ => false })
        @Assert(match (event.stage) { case Some(OperationTimeoutStage.TcpConnect) => true; case _ => false })
    }

    @TestCase
    func narrowerNativeQueryBudgetIsAttributedToItsActiveDnsStage(): Unit {
        let clock = ObservationClock()
        let sink = api.NetworkEventBuffer(capacity: 4)
        let stage = OperationContext(deadline: Some(Deadline.after(60 * Duration.second, clock: clock)),
            eventSink: Some<api.NetworkEventSink>(sink)).forStage(OperationTimeoutStage.Dns)
            .shortenDeadline(Duration.second)
        clock.advance(2 * Duration.second)
        api.emitNetworkEvent(stage, api.NetworkEvent(api.NetworkEventKind.DnsCompleted,
            api.NetworkEventOutcome.Failed, errorCode: Some(api.NetworkErrorCode.TimedOut)))
        let event = sink.drain()[0]
        @Assert(match (event.timeoutReason) { case Some(api.NetworkTimeoutReason.StageLimit) => true; case _ => false })
        @Assert(match (event.timeoutStage) { case Some(OperationTimeoutStage.Dns) => true; case _ => false })
    }

    @TestCase
    func earlierCallerDeadlineReplacesStageCapOwnership(): Unit {
        let clock = ObservationClock()
        let sink = api.NetworkEventBuffer(capacity: 4)
        let stage = OperationContext(deadline: Some(Deadline.after(60 * Duration.second, clock: clock)),
            eventSink: Some<api.NetworkEventSink>(sink),
            timeoutPolicy: OperationTimeoutPolicy(tlsHandshake: Some(20 * Duration.second)))
            .forStage(OperationTimeoutStage.TlsHandshake).withEarlierDeadline(Deadline.after(Duration.second, clock: clock))
        clock.advance(2 * Duration.second)
        api.emitNetworkEvent(stage, api.NetworkEvent(api.NetworkEventKind.TlsHandshakeCompleted,
            api.NetworkEventOutcome.Failed, errorCode: Some(api.NetworkErrorCode.TimedOut)))
        @Assert(match (sink.drain()[0].timeoutReason) { case Some(api.NetworkTimeoutReason.TotalDeadline) => true; case _ => false })
    }
    @TestCase
    func nativeTimeoutDoesNotInventAnUnexpiredTotalDeadlineCause(): Unit {
        let sink = api.NetworkEventBuffer(capacity: 2)
        let context = OperationContext(deadline: Some(Deadline.after(60 * Duration.second)),
            eventSink: Some<api.NetworkEventSink>(sink)).forStage(OperationTimeoutStage.TcpConnect)
        api.emitNetworkEvent(context, api.NetworkEvent(api.NetworkEventKind.ConnectAttemptCompleted,
            api.NetworkEventOutcome.Failed, errorCode: Some(api.NetworkErrorCode.TimedOut)))
        let event = sink.drain()[0]
        @Expect(event.timeoutReason.isNone(), true)
        @Expect(event.timeoutStage.isNone(), true)
    }
}

private class ObservationClock <: api.MonotonicClock {
    private var instant = MonoTime.now()
    public func now(): MonoTime { instant }
    func advance(duration: Duration): Unit { instant += duration }
}
