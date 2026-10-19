package wirestack.observability

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func event(id: Int64): api.NetworkEvent {
    api.NetworkEvent(api.NetworkEventKind.RequestStarted, api.NetworkEventOutcome.Started, requestId: Some(id))
}
private func budget(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(3 * Duration.second)))
}
private class ExportGate <: NetworkEventExporter {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    private var ids = ArrayList<Int64>()
    private var sizes = ArrayList<Int64>()
    private let throwing: Bool
    init(throwing!: Bool = false) { this.throwing = throwing }
    public func export(events: Array<api.NetworkEvent>, context: api.OperationContext): Unit {
        synchronized(mutex) {
            entered = true; changed.notifyAll()
            let deadline = api.Deadline.after(5 * Duration.second)
            while (!released) {
                if (deadline.isExpired()) { throw Exception("export barrier expired") }
                changed.wait(timeout: deadline.remaining())
            }
            sizes.add(events.size)
            for (item in events) { ids.add(item.requestId ?? 0) }
        }
        if (throwing) { throw Exception("SECRET-exporter-failure-not-retained") }
    }
    func waitEntered(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(3 * Duration.second)
            while (!entered) {
                if (deadline.isExpired()) { throw Exception("export did not enter") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
    func delivered(): Array<Int64> { synchronized(mutex) { ids.toArray() } }
    func batches(): Array<Int64> { synchronized(mutex) { sizes.toArray() } }
}
private class ReentrantExporter <: NetworkEventExporter {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var finished = false
    var sink: ?BoundedNetworkEventSink = None<BoundedNetworkEventSink>
    let flushed = AtomicBool(true)
    let closedResult = AtomicBool(true)
    let observed = AtomicInt64(0)
    public func export(events: Array<api.NetworkEvent>, context: api.OperationContext): Unit {
        let target = sink.getOrThrow()
        observed.store(target.detailedSnapshot().inFlightEvents)
        target.emit(event(2))
        flushed.store(target.flush(budget()))
        closedResult.store(target.close(budget()))
        synchronized(mutex) { finished = true; changed.notifyAll() }
    }
    func waitFinished(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(3 * Duration.second)
            while (!finished) {
                if (deadline.isExpired()) { throw Exception("reentrant exporter stalled") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
}
private class CancellationExporter <: NetworkEventExporter {
    let callback = ExportGate()
    public func export(events: Array<api.NetworkEvent>, context: api.OperationContext): Unit {
        context.cancellation.register({ => callback.export([], context) })
    }
}

@Test
class BoundedNetworkEventSinkTests {
    @TestCase
    func samplingFallsBackToAttemptThenConnectionAndKeepsUncorrelatedEvents() {
        let exporter = ExportGate()
        exporter.release()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(sampleEvery: 2))
        try {
            for (id in 1..3) {
                sink.emit(api.NetworkEvent(api.NetworkEventKind.AttemptStarted, api.NetworkEventOutcome.Started,
                    attemptId: Some(id), connectionId: Some(3 - id)))
                sink.emit(api.NetworkEvent(api.NetworkEventKind.ConnectionClosed, api.NetworkEventOutcome.Succeeded,
                    connectionId: Some(id)))
            }
            sink.emit(api.NetworkEvent(api.NetworkEventKind.DnsStarted, api.NetworkEventOutcome.Started))
            @Expect(sink.flush(budget()))
            @Expect(sink.detailedSnapshot().sampledOutEvents, 2)
            @Expect(sink.detailedSnapshot().exportedEvents, 3)
            @Expect(sink.snapshot().droppedEvents, 0)
        } finally { sink.close(budget()) }
    }
    @TestCase
    func blockingCancellationCallbackRetainsDispatcherUntilReleased() {
        let exporter = CancellationExporter()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(shutdownCap: 100 * Duration.millisecond))
        try {
            sink.emit(event(1)); @Expect(sink.flush(budget()))
            let start = MonoTime.now()
            @Expect(!sink.close(budget()))
            @Expect(MonoTime.now() - start < Duration.second)
            exporter.callback.waitEntered()
            let blocked = sink.detailedSnapshot()
            @Expect(blocked.dispatcherRunning); @Expect(!blocked.cancellationCompleted)
            @Expect(!blocked.workerRunning); @Expect(blocked.inFlightEvents, 0)
            let again: Future<Bool> = spawn { sink.close(budget()) }
            @Expect(!sink.close(budget())); @Expect(!again.get())
            @Expect(sink.detailedSnapshot().dispatcherRunning)
            exporter.callback.release(); @Expect(sink.close(budget()))
            @Expect(!sink.detailedSnapshot().dispatcherRunning)
            @Expect(sink.detailedSnapshot().cancellationCompleted)
        } finally { exporter.callback.release(); sink.close(budget()) }
    }
    @TestCase
    func fullQueueDropsNewestAndPreservesFifoBatches() {
        let exporter = ExportGate()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(capacity: 3, batchSize: 2))
        try {
            sink.emit(event(1)); exporter.waitEntered()
            for (id in 2..6) { sink.emit(event(id)) }
            let producer: Future<api.NetworkEventBufferSnapshot> = spawn { sink.snapshot() }
            @Expect(producer.get().queuedEvents, 3)
            let blocked = sink.detailedSnapshot()
            @Expect(blocked.inFlightEvents, 1)
            @Expect(blocked.queueFullDroppedEvents, 1)
            exporter.release()
            @Expect(sink.flush(budget()))
            let ids = exporter.delivered()
            @Expect(ids.size, 4)
            for (i in 0..4) { @Expect(ids[i], i + 1) }
            let batches = exporter.batches()
            @Expect(batches.size, 3)
            @Expect(batches[0], 1); @Expect(batches[1], 2); @Expect(batches[2], 1)
            @Expect(sink.detailedSnapshot().exportedEvents, 4)
        } finally { exporter.release(); sink.close(budget()) }
    }
    @TestCase
    func blockingCallbackCloseExpiresWithoutFakingWorkerReclamation() {
        let exporter = ExportGate()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(capacity: 2, batchSize: 1,
            shutdownCap: 100 * Duration.millisecond))
        try {
            sink.emit(event(1)); exporter.waitEntered(); sink.emit(event(2))
            let start = MonoTime.now()
            @Expect(!sink.close(api.OperationContext()))
            @Expect(MonoTime.now() - start < Duration.second)
            let blocked = sink.detailedSnapshot()
            @Expect(blocked.closed); @Expect(blocked.workerRunning)
            @Expect(blocked.inFlightEvents, 1); @Expect(blocked.queuedEvents, 0)
            @Expect(blocked.shutdownDroppedEvents, 1)
            sink.emit(event(3)); @Expect(sink.detailedSnapshot().closedDroppedEvents, 1)
            exporter.release()
            @Expect(sink.close(budget()))
            @Expect(!sink.detailedSnapshot().workerRunning)
            @Expect(sink.detailedSnapshot().inFlightEvents, 0)
            @Expect(sink.snapshot().droppedEvents, 2)
        } finally { exporter.release(); sink.close(budget()) }
    }
    @TestCase
    func exporterExceptionsAreCountedWithoutRetryOrRetainedText() {
        let exporter = ExportGate(throwing: true)
        exporter.release()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(capacity: 2, batchSize: 1))
        try {
            sink.emit(event(1)); @Expect(sink.flush(budget()))
            sink.emit(event(2)); @Expect(sink.flush(budget()))
            let sample = sink.detailedSnapshot()
            @Expect(sample.exportFaults, 2); @Expect(sample.exportFaultDroppedEvents, 2)
            @Expect(sample.exportedEvents, 0); @Expect(sample.inFlightEvents, 0)
            @Expect(exporter.delivered().size, 2)
            @Expect(sink.snapshot().droppedEvents, 2)
        } finally { sink.close(budget()) }
    }
    @TestCase
    func reentrantExporterDoesNotJoinItselfOrHoldOwnerLock() {
        let exporter = ReentrantExporter()
        let sink = BoundedNetworkEventSink(exporter)
        exporter.sink = Some(sink)
        sink.emit(event(1))
        exporter.waitFinished()
        @Expect(sink.close(budget()))
        @Expect(exporter.observed.load(), 1)
        @Expect(!exporter.flushed.load()); @Expect(!exporter.closedResult.load())
        @Expect(sink.detailedSnapshot().shutdownDroppedEvents, 1)
        @Expect(!sink.detailedSnapshot().workerRunning)
    }
    @TestCase
    func samplingIsStableAcrossSpansWithoutRetainingUniqueIds() {
        let exporter = ExportGate()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(capacity: 4, batchSize: 2, sampleEvery: 2))
        try {
            sink.emit(event(2)); exporter.waitEntered()
            for (id in 1..10001) {
                sink.emit(api.NetworkEvent(api.NetworkEventKind.AttemptStarted, api.NetworkEventOutcome.Started,
                    requestId: Some(id), attemptId: Some(id + 10000), connectionId: Some(id + 20000)))
                sink.emit(api.NetworkEvent(api.NetworkEventKind.BodyCompleted, api.NetworkEventOutcome.Succeeded,
                    requestId: Some(id), attemptId: Some(id + 30000)))
            }
            let sample = sink.detailedSnapshot()
            @Expect(sample.sampledOutEvents, 10000)
            @Expect(sample.queuedEvents, 4); @Expect(sample.queueFullDroppedEvents, 9996)
            exporter.release(); @Expect(sink.flush(budget()))
            let ids = exporter.delivered()
            @Expect(ids.size, 5); @Expect(ids[1], 2); @Expect(ids[2], 2)
            @Expect(ids[3], 4); @Expect(ids[4], 4)
            @Expect(sink.detailedSnapshot().sampledOutEvents, 10000)
        } finally { exporter.release(); sink.close(budget()) }
    }
    @TestCase
    func cancellationDeadlineAndConcurrentFlushCloseRemainBounded() {
        let exporter = ExportGate()
        let sink = BoundedNetworkEventSink(exporter, config: NetworkEventSinkConfig(capacity: 1, batchSize: 1))
        try {
            sink.emit(event(1)); exporter.waitEntered()
            let cancelled = api.CancellationSource(); cancelled.cancel()
            @Expect(!sink.flush(api.OperationContext(cancellation: cancelled.token)))
            @Expect(!sink.flush(api.OperationContext(deadline: Some(api.Deadline.after(Duration.Zero)))))
            let caller = api.CancellationSource()
            let waiting: Future<Bool> = spawn { sink.flush(api.OperationContext(cancellation: caller.token)) }
            caller.cancel(); @Expect(!waiting.get())
            let flushing: Future<Bool> = spawn {
                sink.flush(api.OperationContext(deadline: Some(api.Deadline.after(60 * Duration.millisecond))))
            }
            let closing: Future<Bool> = spawn {
                sink.close(api.OperationContext(deadline: Some(api.Deadline.after(30 * Duration.millisecond))))
            }
            @Expect(!closing.get()); @Expect(sink.detailedSnapshot().workerRunning)
            @Expect(!flushing.get())
            exporter.release(); @Expect(sink.close(budget()))
            @Expect(sink.flush(budget()))
        } finally { exporter.release(); sink.close(budget()) }
    }
    @TestCase
    func configurationBoundsRejectUnboundedWork() {
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(capacity: 0) })
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(capacity: 4097) })
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(capacity: 1, batchSize: 2) })
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(sampleEvery: 65537) })
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(shutdownCap: Duration.Zero) })
        let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkEventSinkConfig(shutdownCap: 6 * Duration.second) })
    }
}
