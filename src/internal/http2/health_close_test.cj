package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2ConnectionHealthTest {
    @TestCase
    func pingCodecAndConnectionAckPreserveOpaqueBytes(): Unit {
        let payload: Array<Byte> = [0, 1, 2, 3, 4, 5, 6, 255]
        let machine = openHealthClient()
        let ping = encodeHttp2Ping(payload)
        let result = machine.receive(ping)
        @Expect(result.outbound.size, 1)
        let acknowledgement = decodeHttp2Ping(result.outbound[0])
        @Expect(acknowledgement.ack)
        @Expect(acknowledgement.opaqueData, payload)
        @Expect(machine.receive(result.outbound[0]).outbound.isEmpty())
    }

    @TestCase
    func idleProbeIsSingleOutstandingAndMatchingAckRestoresHealth(): Unit {
        let transport = HealthRecordingTransport()
        let writer = Http2WriteScheduler(transport)
        let writerTask = spawn { writer.run() }
        let clock = HealthFakeClock(MonoTime.now())
        let health = Http2ConnectionHealth(
            writer,
            policy: Http2HealthPolicy(
                idleTimeout: 10 * Duration.millisecond,
                pingTimeout: 5 * Duration.millisecond
            ),
            clock: clock
        )
        @Expect(health.poll().probe.isNone())
        clock.advance(10 * Duration.millisecond)
        let first = health.poll().probe.getOrThrow()
        @Expect(isHealthWriteWritten(first.wait()))
        @Expect(health.hasOutstandingPing)
        @Expect(health.poll().probe.isNone())

        let expected = health.outstandingOpaqueData.getOrThrow()
        @Expect(!health.observeInbound(encodeHttp2Ping(Array<Byte>(8, repeat: 9u8), ack: true)))
        @Expect(health.hasOutstandingPing)
        @Expect(health.observeInbound(encodeHttp2Ping(expected, ack: true)))
        @Expect(isHealthHealthy(health.state))
        @Expect(!health.hasOutstandingPing)

        clock.advance(10 * Duration.millisecond)
        let second = health.poll().probe.getOrThrow()
        @Expect(isHealthWriteWritten(second.wait()))
        clock.advance(5 * Duration.millisecond)
        let timedOut = health.poll()
        @Expect(timedOut.timedOut)
        @Expect(isHealthUnhealthy(timedOut.state))
        @Expect(health.poll().probe.isNone())
        health.close()
        writer.close()
        @Expect(isHealthWriterClosed(writerTask.get(Duration.second)))
        @Expect(transport.frameCount(), 2)
    }

    @TestCase
    func ordinaryActivityDefersIdleProbeWithoutAllocatingATimer(): Unit {
        let writer = Http2WriteScheduler(HealthRecordingTransport())
        let clock = HealthFakeClock(MonoTime.now())
        let health = Http2ConnectionHealth(
            writer,
            policy: Http2HealthPolicy(
                idleTimeout: 10 * Duration.millisecond,
                pingTimeout: 5 * Duration.millisecond
            ),
            clock: clock
        )
        clock.advance(9 * Duration.millisecond)
        @Expect(!health.observeInbound(encodeHttp2Settings([])))
        clock.advance(9 * Duration.millisecond)
        @Expect(health.poll().probe.isNone())
        @Expect(writer.pendingWrites, 0)
        health.close()
        writer.abort()
    }
}

@Test
class Http2ConnectionCloserTest {
    @TestCase
    func gracefulCloseSendsGoAwayWaitsForStreamAndClosesTransportOnce(): Unit {
        let fixture = CloseFixture()
        let admission = fixture.goAway.openLocal(CloseNoopGoAwayListener())
        let writerTask = spawn { fixture.writer.run() }
        let closing = spawn { fixture.closer.close() }
        fixture.transport.waitForWrite()
        @Expect(isCloseDraining(fixture.machine.phase))
        @Expect(fixture.closer.result.isNone())

        fixture.registry.localEnd(admission.stream.id)
        fixture.registry.peerEnd(admission.stream.id)
        let _ = fixture.flow.closeStream(admission.stream.id)
        admission.registration.unregister()
        let result = closing.get(Duration.second)
        @Expect(isCloseGraceful(result.mode))
        @Expect(isHealthWriterClosed(writerTask.get(Duration.second)))
        @Expect(fixture.transport.closeCalls.load(), 1)
        @Expect(fixture.transport.abortCalls.load(), 0)
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
    }

    @TestCase
    func expiredCloseAbortsActiveStreamsWithoutStartingGracefulIo(): Unit {
        let fixture = CloseFixture()
        let _ = fixture.goAway.openLocal(CloseNoopGoAwayListener())
        let result = fixture.closer.close(context: OperationContext(
            deadline: Some(Deadline.after(Duration.Zero))
        ))
        @Expect(isCloseAborted(result.mode))
        @Expect(isCloseDeadlineReason(result.reason.getOrThrow()))
        @Expect(fixture.transport.closeCalls.load(), 0)
        @Expect(fixture.transport.abortCalls.load(), 1)
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
    }

    @TestCase
    func racingShorterDeadlineUpgradesInFlightGracefulCloseToOneAbort(): Unit {
        let fixture = CloseFixture()
        let _ = fixture.goAway.openLocal(CloseNoopGoAwayListener())
        let writerTask = spawn { fixture.writer.run() }
        let graceful = spawn { fixture.closer.close() }
        fixture.transport.waitForWrite()
        let urgent = fixture.closer.close(context: OperationContext(
            deadline: Some(Deadline.after(Duration.Zero))
        ))
        @Expect(isCloseAborted(urgent.mode))
        @Expect(isCloseAborted(graceful.get(Duration.second).mode))
        @Expect(isHealthWriterFailed(writerTask.get(Duration.second)))
        @Expect(fixture.transport.abortCalls.load(), 1)
        @Expect(fixture.transport.closeCalls.load(), 0)
    }

    @TestCase
    func concurrentGracefulCallersShareOneTerminalResultAndTransportClose(): Unit {
        let fixture = CloseFixture()
        let writerTask = spawn { fixture.writer.run() }
        let callers = ArrayList<Future<Http2ConnectionCloseResult>>()
        for (_ in 0..32) { callers.add(spawn { fixture.closer.close() }) }
        for (caller in callers) { @Expect(isCloseGraceful(caller.get(Duration.second).mode)) }
        @Expect(isHealthWriterClosed(writerTask.get(Duration.second)))
        @Expect(fixture.transport.closeCalls.load(), 1)
        @Expect(fixture.transport.abortCalls.load(), 0)
        @Expect(isCloseGraceful(fixture.closer.close().mode))
        @Expect(fixture.transport.closeCalls.load(), 1)
    }

    @TestCase
    func failedGracefulTransportCloseFallsBackToOneAbort(): Unit {
        let transport = CloseFailingTransport()
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
        let flow = Http2FlowController()
        let writer = Http2WriteScheduler(transport)
        let goAway = Http2GoAwayManager(machine, registry, flow, writer)
        let closer = Http2ConnectionCloser(machine, registry, flow, writer, goAway)
        let _ = machine.start()
        let _ = machine.receive(encodeHttp2Settings([]))
        let writerTask = spawn { writer.run() }

        let result = closer.close()

        @Expect(isCloseAborted(result.mode))
        @Expect(isHealthWriterClosed(writerTask.get(Duration.second)))
        @Expect(transport.closeCalls.load(), 1)
        @Expect(transport.abortCalls.load(), 1)
    }
}

private class HealthFakeClock <: MonotonicClock {
    private var current: MonoTime
    init(start: MonoTime) { current = start }
    public func now(): MonoTime { current }
    func advance(value: Duration): Unit { current += value }
}

private class HealthRecordingTransport <: DuplexTransport {
    private let mutex = Mutex()
    private let output = ArrayList<Byte>()
    private var closed = false
    public prop info: TransportInfo { get() { TransportInfo("http2-health-test") } }
    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }
    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        synchronized(mutex) {
            for (index in 0..source.length) { output.add(source.bytes[source.offset + index]) }
        }
        source.length
    }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { closed = true }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true }
    func frameCount(): Int64 { synchronized(mutex) { Http2FrameParser().feed(output.toArray()).size } }
}

private class CloseRecordingTransport <: DuplexTransport {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var writes: Int64 = 0
    private var closed = false
    let closeCalls = AtomicInt64(0)
    let abortCalls = AtomicInt64(0)
    public prop info: TransportInfo { get() { TransportInfo("http2-close-test") } }
    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }
    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        synchronized(mutex) { writes += 1; changed.notifyAll() }
        source.length
    }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {
        closed = true
        let _ = closeCalls.fetchAdd(1)
    }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { closed }
    public func abort(reason!: ?AbortReason): Unit {
        let _ = reason
        closed = true
        synchronized(mutex) { changed.notifyAll() }
        let _ = abortCalls.fetchAdd(1)
    }
    func waitForWrite(): Unit {
        let deadline = Deadline.after(Duration.second)
        synchronized(mutex) {
            while (writes == 0) {
                if (deadline.isExpired()) { throw Exception("HTTP/2 GOAWAY was not written") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
}

private class CloseFailingTransport <: DuplexTransport {
    let closeCalls = AtomicInt64(0)
    let abortCalls = AtomicInt64(0)
    public prop info: TransportInfo { get() { TransportInfo("http2-close-failing-test") } }
    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }
    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        source.length
    }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {
        let _ = closeCalls.fetchAdd(1)
        throw Exception("graceful transport close failed")
    }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { abortCalls.load() > 0 }
    public func abort(reason!: ?AbortReason): Unit {
        let _ = reason
        let _ = abortCalls.fetchAdd(1)
    }
}

private class CloseFixture {
    let transport = CloseRecordingTransport()
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    let registry = Http2StreamRegistry(Http2ConnectionRole.Client)
    let flow = Http2FlowController()
    let writer = Http2WriteScheduler(transport)
    let goAway: Http2GoAwayManager
    let health: Http2ConnectionHealth
    let closer: Http2ConnectionCloser
    init() {
        goAway = Http2GoAwayManager(machine, registry, flow, writer)
        health = Http2ConnectionHealth(writer)
        closer = Http2ConnectionCloser(machine, registry, flow, writer, goAway, health: Some(health))
        let _ = machine.start()
        let _ = machine.receive(encodeHttp2Settings([]))
    }
}

private class CloseNoopGoAwayListener <: Http2GoAwayListener {
    public func connectionGoAway(_: Http2GoAwayException): Unit {}
}

private func openHealthClient(): Http2ConnectionStateMachine {
    let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
    let _ = machine.start()
    let _ = machine.receive(encodeHttp2Settings([]))
    machine
}

private func isHealthHealthy(value: Http2HealthState): Bool {
    match (value) { case Http2HealthState.Healthy => true; case _ => false }
}
private func isHealthUnhealthy(value: Http2HealthState): Bool {
    match (value) { case Http2HealthState.Unhealthy => true; case _ => false }
}
private func isHealthWriteWritten(value: Http2WriteState): Bool {
    match (value) { case Http2WriteState.Written => true; case _ => false }
}
private func isHealthWriterClosed(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Closed => true; case _ => false }
}
private func isHealthWriterFailed(value: Http2WriteSchedulerState): Bool {
    match (value) { case Http2WriteSchedulerState.Failed => true; case _ => false }
}
private func isCloseDraining(value: Http2ConnectionPhase): Bool {
    match (value) { case Http2ConnectionPhase.Draining => true; case _ => false }
}
private func isCloseGraceful(value: Http2ConnectionCloseMode): Bool {
    match (value) { case Http2ConnectionCloseMode.Graceful => true; case _ => false }
}
private func isCloseAborted(value: Http2ConnectionCloseMode): Bool {
    match (value) { case Http2ConnectionCloseMode.Aborted => true; case _ => false }
}
private func isCloseDeadlineReason(value: AbortReason): Bool {
    match (value) { case AbortReason.DeadlineExceeded => true; case _ => false }
}
