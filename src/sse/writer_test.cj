package wirestack.sse

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.*

@Test
class SseWriterTest {
    @TestCase
    func tinyRingAppliesBackpressureAndPreservesBytes(): Unit {
        let writer = SseWriter(maximumBufferBytes: 3, context: OperationContext(
            deadline: Some(Deadline.after(2 * Duration.second))))
        let event = SseEvent("one\ntwo", eventType: "update", lastEventId: "9")
        let expected = SseEncoder().encode(event, retryMilliseconds: Some(12u64))
        let publishing = spawn { writer.write(event, retryMilliseconds: Some(12u64)); writer.complete() }
        let output = ArrayList<Byte>()
        let buffer = Array<Byte>(2, repeat: 0u8)
        var maximum: Int64 = 0
        while (true) {
            maximum = max(maximum, writer.queuedBytes)
            let count = writer.read(buffer)
            if (count == 0) { break }
            for (i in 0..count) { output.add(buffer[i]) }
        }
        publishing.get(2 * Duration.second)
        @Expect(output.toArray(), expected)
        @Expect(maximum <= writer.maximumBufferBytes)
        @Expect(writer.queuedBytes, 0)
        writer.flush()
        @Expect(writer.read(buffer), 0)
        writer.complete(); writer.close(); writer.close()
    }

    @TestCase
    func flushWaitsForReaderConsumption(): Unit {
        let writer = SseWriter()
        writer.comment("heartbeat")
        let original = writer.queuedBytes
        let started = AtomicBool(false)
        let finished = AtomicBool(false)
        let flushing = spawn { started.store(true); writer.flush(); finished.store(true) }
        waitWriterFlag(started)
        sleep(10 * Duration.millisecond)
        @Expect(!finished.load())
        @Expect(writer.queuedBytes, original)
        let buffer = Array<Byte>(1, repeat: 0u8)
        @Expect(writer.read(buffer), 1)
        @Expect(!finished.load())
        let remaining = Array<Byte>(original, repeat: 0u8)
        @Expect(writer.read(remaining), original - 1)
        flushing.get(Duration.second)
        @Expect(finished.load())
        writer.close()
    }

    @TestCase
    func cancellationWakesFullRingAndAbortsPartialEvent(): Unit {
        let cancellation = CancellationSource()
        let writer = SseWriter(maximumBufferBytes: 1)
        let publishing = spawn {
            writerNetworkFailure({ => writer.write(SseEvent("long"),
                context: OperationContext(cancellation: cancellation.token)) })
        }
        waitWriterQueue(writer, 1)
        @Expect(writer.queuedBytes, 1)
        @Expect(writerSseFailure({ => writer.write(SseEvent("overlap")) }), SseErrorCode.ConcurrentOperation)
        cancellation.cancel()
        @Expect(publishing.get(Duration.second), "cancelled")
        @Expect(writer.queuedBytes, 0)
        @Expect(writerSseFailure({ => writer.read(Array<Byte>(1, repeat: 0u8)); () }), SseErrorCode.Closed)
        writer.close()
    }

    @TestCase
    func deadlinesBoundBackpressureAndFlush(): Unit {
        let writer = SseWriter(maximumBufferBytes: 1)
        @Expect(writerNetworkFailure({ => writer.write(SseEvent("blocked"), context: OperationContext(
            deadline: Some(Deadline.after(20 * Duration.millisecond)))) }), "timed-out")
        @Expect(writer.queuedBytes, 0)
        writer.close()
        let flushing = SseWriter()
        flushing.comment("pending")
        @Expect(writerNetworkFailure({ => flushing.flush(context: OperationContext(
            deadline: Some(Deadline.after(20 * Duration.millisecond)))) }), "timed-out")
        @Expect(flushing.queuedBytes > 0)
        flushing.close()
    }

    @TestCase
    func lifetimeCannotBeReplacedByBackgroundCallContext(): Unit {
        let cancellation = CancellationSource()
        let writer = SseWriter(context: OperationContext(cancellation: cancellation.token))
        let started = AtomicBool(false)
        let reading = spawn {
            started.store(true)
            writerNetworkFailure({ => writer.read(Array<Byte>(1, repeat: 0u8)); () })
        }
        waitWriterFlag(started)
        cancellation.cancel()
        @Expect(reading.get(Duration.second), "cancelled")
        @Expect(writerNetworkFailure({ => writer.comment("x") }), "cancelled")
        writer.close()
        let deadlineWriter = SseWriter(context: OperationContext(deadline: Some(Deadline.after(Duration.Zero))))
        @Expect(writerNetworkFailure({ => deadlineWriter.write(SseEvent("x")) }), "timed-out")
        deadlineWriter.close()
    }

    @TestCase
    func closeWakesReaderAndProducerWithoutReportingEof(): Unit {
        let readerWriter = SseWriter()
        let started = AtomicBool(false)
        let reading = spawn {
            started.store(true)
            writerSseFailure({ => readerWriter.read(Array<Byte>(1, repeat: 0u8)); () })
        }
        waitWriterFlag(started)
        sleep(10 * Duration.millisecond)
        @Expect(writerSseFailure({ => readerWriter.read(Array<Byte>(1, repeat: 0u8)); () }), SseErrorCode.ConcurrentOperation)
        readerWriter.close()
        @Expect(reading.get(Duration.second), SseErrorCode.Closed)
        let producerWriter = SseWriter(maximumBufferBytes: 1)
        let producing = spawn { writerSseFailure({ => producerWriter.comment("blocked") }) }
        waitWriterQueue(producerWriter, 1)
        producerWriter.close()
        @Expect(producing.get(Duration.second), SseErrorCode.Closed)
        @Expect(producerWriter.queuedBytes, 0)
    }

    @TestCase
    func cancellationWakesFlushAndCompleteWakesEmptyReader(): Unit {
        let writer = SseWriter()
        writer.comment("queued")
        let cancellation = CancellationSource()
        let started = AtomicBool(false)
        let flushing = spawn {
            started.store(true)
            writerNetworkFailure({ => writer.flush(context: OperationContext(cancellation: cancellation.token)) })
        }
        waitWriterFlag(started)
        cancellation.cancel()
        @Expect(flushing.get(Duration.second), "cancelled")
        @Expect(writer.queuedBytes > 0)
        writer.close()
        let empty = SseWriter()
        let reading = spawn { empty.read(Array<Byte>(1, repeat: 0u8)) }
        empty.complete()
        @Expect(reading.get(Duration.second), 0)
        @Expect(!empty.isClosed())
        empty.close()
        @Expect(empty.isClosed())
    }

    @TestCase
    func completeDrainsAndValidationDoesNotPoisonWriter(): Unit {
        let writer = SseWriter()
        @Expect(writerSseFailure({ => writer.write(SseEvent("bad", lastEventId: "x\ny")) }), SseErrorCode.InvalidMetadata)
        @Expect(writer.queuedBytes, 0)
        writer.write(SseEvent("valid"))
        writer.complete(); writer.complete()
        @Expect(writerSseFailure({ => writer.comment("late") }), SseErrorCode.Closed)
        let bytes = Array<Byte>(writer.queuedBytes, repeat: 0u8)
        @Expect(writer.read(bytes), bytes.size)
        @Expect(SseDecoder().decode(bytes).event.getOrThrow().data, "valid")
        @Expect(writer.read(bytes), 0)
        writer.close()
        for (capacity in [0, -1, 1048577]) {
            try { SseWriter(maximumBufferBytes: capacity); @Fail("expected invalid capacity") }
            catch (_: IllegalArgumentException) { () }
        }
    }

    @TestCase
    func callerClockMayObserveWriterWithoutLockReentrancy(): Unit {
        let clock = WriterObservingClock()
        let writer = SseWriter(context: OperationContext(
            deadline: Some(Deadline.after(Duration.second, clock: clock))))
        clock.attach(writer)
        writer.write(SseEvent("clock"))
        let bytes = Array<Byte>(writer.queuedBytes, repeat: 0u8)
        @Expect(writer.read(bytes), bytes.size)
        writer.flush()
        writer.complete()
        @Expect(writer.read(bytes), 0)
        @Expect(clock.observations.load() > 0)
        writer.close()
    }
}

private func writerNetworkFailure(operation: () -> Unit): String {
    try { operation(); throw Exception("expected network failure") }
    catch (error: NetworkException) {
        match (error.code) {
            case NetworkErrorCode.Cancelled => "cancelled"
            case NetworkErrorCode.TimedOut => "timed-out"
            case _ => throw error
        }
    }
}
private func writerSseFailure(operation: () -> Unit): SseErrorCode {
    try { operation(); throw Exception("expected SSE failure") }
    catch (error: SseException) { error.code }
}
private func waitWriterFlag(flag: AtomicBool): Unit {
    let deadline = Deadline.after(Duration.second)
    while (!flag.load()) {
        if (deadline.isExpired()) { throw Exception("writer task did not start") }
        sleep(Duration.millisecond)
    }
}
private func waitWriterQueue(writer: SseWriter, bytes: Int64): Unit {
    let deadline = Deadline.after(Duration.second)
    while (writer.queuedBytes != bytes) {
        if (deadline.isExpired()) { throw Exception("writer queue did not fill") }
        sleep(Duration.millisecond)
    }
}

private class WriterObservingClock <: MonotonicClock {
    private var writer: ?SseWriter = None<SseWriter>
    let observations = AtomicInt64(0)
    func attach(value: SseWriter): Unit { writer = Some(value) }
    public func now(): MonoTime {
        if (let Some(value) <- writer) {
            let _ = value.queuedBytes
            observations.fetchAdd(1)
        }
        MonoTime.now()
    }
}
