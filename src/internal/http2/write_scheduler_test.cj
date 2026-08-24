package wirestack.internal.http2

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2WriteSchedulerTest {
    @TestCase
    func controlPrecedesDataAndPartialWritesDrainGracefully(): Unit {
        let transport = RecordingSchedulerTransport(maxChunk: 2)
        let scheduler = Http2WriteScheduler(transport)
        let dataOne = scheduler.enqueue(schedulerData(1u32, 1u8))
        let ping = scheduler.enqueue(schedulerPing(9u8))
        let dataThree = scheduler.enqueue(schedulerData(3u32, 3u8))
        scheduler.close()

        let state = scheduler.run()
        let frames = decodeScheduledFrames(transport.bytes())

        @Expect(isSchedulerTestClosed(state))
        @Expect(frameCodes(frames), [6u8, 0u8, 0u8])
        @Expect(frames[1].header.streamId.value, 1u32)
        @Expect(frames[2].header.streamId.value, 3u32)
        @Expect(isWriteTestWritten(ping.wait()))
        @Expect(isWriteTestWritten(dataOne.wait()))
        @Expect(isWriteTestWritten(dataThree.wait()))
        @Expect(transport.writeCalls > 3)
        @Expect(transport.shutdownCalls.load(), 0)
        @Expect(scheduler.pendingWrites, 0)
        @Expect(scheduler.pendingBytes, 0u64)
    }

    @TestCase
    func controlBurstIsBoundedAndDataStreamsRotateFairly(): Unit {
        let transport = RecordingSchedulerTransport()
        let scheduler = Http2WriteScheduler(
            transport,
            limits: Http2Limits(maxPendingWrites: 32u32, maxPendingWriteBytes: 4096u32)
        )
        for (index in 0..20) { let _ = scheduler.enqueue(schedulerPing(UInt8(index))) }
        let _ = scheduler.enqueue(schedulerData(1u32, 101u8))
        let _ = scheduler.enqueue(schedulerData(1u32, 102u8))
        let _ = scheduler.enqueue(schedulerData(3u32, 103u8))
        let _ = scheduler.enqueue(schedulerData(3u32, 104u8))
        scheduler.close()
        let _ = scheduler.run()

        let frames = decodeScheduledFrames(transport.bytes())
        @Expect(frames.size, 24)
        @Expect(http2FrameTypeCode(frames[8].header.frameType), 0u8)
        @Expect(frames[8].header.streamId.value, 1u32)
        @Expect(http2FrameTypeCode(frames[17].header.frameType), 0u8)
        @Expect(frames[17].header.streamId.value, 3u32)
        @Expect(frames[22].header.streamId.value, 1u32)
        @Expect(frames[23].header.streamId.value, 3u32)
    }

    @TestCase
    func queueCountAndBytesAreHardAndCancellationReleasesCapacity(): Unit {
        let countScheduler = Http2WriteScheduler(
            RecordingSchedulerTransport(),
            limits: Http2Limits(maxPendingWrites: 2u32, maxPendingWriteBytes: 1024u32)
        )
        let first = countScheduler.enqueue(schedulerData(1u32, 1u8))
        let second = countScheduler.enqueue(schedulerData(3u32, 2u8))
        expectWriteQueueFull({ => let _ = countScheduler.enqueue(schedulerData(5u32, 3u8)) })
        @Expect(first.cancel())
        @Expect(!first.cancel())
        let third = countScheduler.enqueue(schedulerData(5u32, 3u8))
        @Expect(isWriteTestCancelled(first.wait()))
        countScheduler.close()
        let _ = countScheduler.run()
        @Expect(isWriteTestWritten(second.wait()))
        @Expect(isWriteTestWritten(third.wait()))

        let byteScheduler = Http2WriteScheduler(
            RecordingSchedulerTransport(),
            limits: Http2Limits(maxPendingWrites: 4u32, maxPendingWriteBytes: 10u32)
        )
        let _ = byteScheduler.enqueue(schedulerData(1u32, 1u8))
        expectWriteQueueFull({ => let _ = byteScheduler.enqueue(schedulerData(3u32, 2u8)) })
        @Expect(byteScheduler.pendingBytes, 10u64)
        byteScheduler.abort()
    }

    @TestCase
    func concurrentProducersStillUseExactlyOneWriter(): Unit {
        let transport = RecordingSchedulerTransport(maxChunk: 3)
        let scheduler = Http2WriteScheduler(
            transport,
            limits: Http2Limits(maxPendingWrites: 128u32, maxPendingWriteBytes: 4096u32)
        )
        let tickets = ArrayList<Http2WriteTicket>()
        let ticketsMutex = Mutex()
        let writer = spawn { scheduler.run() }
        let producers = ArrayList<Future<Unit>>()
        for (producer in 0..8) {
            producers.add(spawn {
                for (index in 0..10) {
                    let streamId = UInt32((producer * 2) + 1)
                    let ticket = scheduler.enqueue(schedulerData(streamId, UInt8(index)))
                    synchronized(ticketsMutex) { tickets.add(ticket) }
                }
            })
        }
        for (producer in producers) { producer.get(Duration.second) }
        scheduler.close()
        @Expect(isSchedulerTestClosed(writer.get(Duration.second)))
        @Expect(tickets.size, 80)
        for (ticket in tickets) { @Expect(isWriteTestWritten(ticket.wait())) }
        @Expect(decodeScheduledFrames(transport.bytes()).size, 80)
        @Expect(transport.maximumConcurrentWrites, 1)

        var rejected = false
        try { let _ = scheduler.run() } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected)
    }

    @TestCase
    func abortInterruptsActiveWriteAndFailsEveryTicket(): Unit {
        let transport = BlockingSchedulerTransport()
        let scheduler = Http2WriteScheduler(transport)
        let active = scheduler.enqueue(schedulerData(1u32, 1u8))
        let queued = scheduler.enqueue(schedulerData(3u32, 2u8))
        let writer = spawn { scheduler.run() }
        transport.waitUntilEntered()
        @Expect(!active.cancel())

        scheduler.abort(reason: AbortReason.Cancelled)
        @Expect(isSchedulerTestFailed(writer.get(Duration.second)))
        @Expect(isWriteTestFailed(active.wait()))
        @Expect(isWriteTestFailed(queued.wait()))
        @Expect(scheduler.pendingWrites, 0)
        @Expect(transport.abortCalls.load(), 1)
        expectSchedulerClosedToAdmission(scheduler)
    }

    @TestCase
    func transportFailureFansOutAndTicketWaitHonorsCancellation(): Unit {
        let transport = RecordingSchedulerTransport(failAtCall: 1)
        let scheduler = Http2WriteScheduler(transport)
        let first = scheduler.enqueue(schedulerData(1u32, 1u8))
        let second = scheduler.enqueue(schedulerData(3u32, 2u8))
        let third = scheduler.enqueue(schedulerPing(3u8))

        let source = CancellationSource()
        source.cancel()
        var waitCancelled = false
        try {
            let _ = second.wait(context: OperationContext(cancellation: source.token))
        } catch (error: NetworkException) {
            match (error.code) { case NetworkErrorCode.Cancelled => waitCancelled = true; case _ => () }
        }
        @Expect(waitCancelled)
        @Expect(isWriteTestQueued(second.state))

        scheduler.close()
        @Expect(isSchedulerTestFailed(scheduler.run()))
        @Expect(isWriteTestFailed(first.wait()))
        @Expect(isWriteTestFailed(second.wait()))
        @Expect(isWriteTestFailed(third.wait()))
        @Expect(scheduler.pendingWrites, 0)
        @Expect(scheduler.pendingBytes, 0u64)
    }
}

private class RecordingSchedulerTransport <: DuplexTransport {
    private let maxChunk: Int64
    private let failAtCall: Int64
    private let mutex = Mutex()
    private let output = ArrayList<Byte>()
    private var activeWrites: Int64 = 0
    private var maxActiveWrites: Int64 = 0
    private var closed = false
    public var writeCalls: Int64 = 0
    public let shutdownCalls = AtomicInt64(0)
    public let abortCalls = AtomicInt64(0)

    init(maxChunk!: Int64 = 16384, failAtCall!: Int64 = 0) {
        this.maxChunk = maxChunk
        this.failAtCall = failAtCall
    }

    public prop info: TransportInfo { get() { TransportInfo("http2-scheduler-test") } }
    public prop maximumConcurrentWrites: Int64 { get() { synchronized(mutex) { maxActiveWrites } } }

    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        synchronized(mutex) {
            activeWrites += 1
            maxActiveWrites = max(maxActiveWrites, activeWrites)
            writeCalls += 1
        }
        try {
            if (failAtCall > 0 && writeCalls >= failAtCall) {
                throw NetworkException(
                    NetworkErrorCategory.Write, NetworkPhase.HttpBody, NetworkErrorCode.BrokenPipe,
                    "scripted HTTP/2 write failure", retryability: Retryability.Never
                )
            }
            let count = min(maxChunk, source.length)
            synchronized(mutex) {
                for (index in 0..count) { output.add(source.bytes[source.offset + index]) }
            }
            count
        } finally {
            synchronized(mutex) { activeWrites -= 1 }
        }
    }

    public func shutdown(direction: ShutdownDirection): Unit {
        match (direction) { case ShutdownDirection.Write => let _ = shutdownCalls.fetchAdd(1); case _ => () }
    }
    public func close(_: OperationContext): Unit { closed = true }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true; let _ = abortCalls.fetchAdd(1) }
    func bytes(): Array<Byte> { synchronized(mutex) { output.toArray() } }
}

private class BlockingSchedulerTransport <: DuplexTransport {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var aborted = false
    public let abortCalls = AtomicInt64(0)

    public prop info: TransportInfo { get() { TransportInfo("http2-blocking-scheduler-test") } }
    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult { let _ = context; ReadResult.EndOfStream }
    public func writeSome(_: ByteSpan, context!: OperationContext): Int64 {
        let registration = context.cancellation.register { => wake() }
        try {
            synchronized(mutex) {
                entered = true
                changed.notifyAll()
                while (!aborted && !context.isCancellationRequested()) { changed.wait() }
                throw NetworkException(
                    NetworkErrorCategory.Write, NetworkPhase.HttpBody, NetworkErrorCode.ConnectionReset,
                    "scripted blocked write interrupted", retryability: Retryability.Never
                )
            }
        } finally {
            registration.unregister()
        }
    }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { abort() }
    public func close(): Unit { abort() }
    public func isClosed(): Bool { synchronized(mutex) { aborted } }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        synchronized(mutex) { aborted = true; changed.notifyAll() }
        let _ = abortCalls.fetchAdd(1)
    }
    func waitUntilEntered(): Unit {
        let deadline = Deadline.after(Duration.second)
        synchronized(mutex) {
            while (!entered) {
                if (deadline.isExpired()) { throw Exception("HTTP/2 writer did not enter transport") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private func schedulerData(streamId: UInt32, marker: Byte): Http2Frame {
    Http2Frame(
        Http2FrameHeader(1u32, Http2FrameType.Data, Http2Flags(), Http2StreamId(streamId)),
        [marker]
    )
}

private func schedulerPing(marker: Byte): Http2Frame {
    Http2Frame(
        Http2FrameHeader(8u32, Http2FrameType.Ping, Http2Flags(), Http2StreamId(0u32)),
        Array<Byte>(8, repeat: marker)
    )
}

private func decodeScheduledFrames(bytes: Array<Byte>): Array<Http2Frame> {
    let parser = Http2FrameParser()
    let frames = parser.feed(bytes)
    @Expect(!parser.hasIncompleteFrame())
    frames
}

private func frameCodes(frames: Array<Http2Frame>): Array<Byte> {
    let output = Array<Byte>(frames.size, repeat: 0u8)
    for (index in 0..frames.size) { output[index] = http2FrameTypeCode(frames[index].header.frameType) }
    output
}

private func expectWriteQueueFull(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: Http2WriteQueueFullException) { rejected = true }
    @Expect(rejected)
}

private func expectSchedulerClosedToAdmission(scheduler: Http2WriteScheduler): Unit {
    var rejected = false
    try { let _ = scheduler.enqueue(schedulerPing(0u8)) } catch (_: IllegalStateException) { rejected = true }
    @Expect(rejected)
}

private func isWriteTestQueued(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Queued => true; case _ => false }
}

private func isWriteTestWritten(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Written => true; case _ => false }
}

private func isWriteTestCancelled(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Cancelled => true; case _ => false }
}

private func isWriteTestFailed(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Failed => true; case _ => false }
}

private func isSchedulerTestClosed(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Closed => true; case _ => false }
}

private func isSchedulerTestFailed(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Failed => true; case _ => false }
}
