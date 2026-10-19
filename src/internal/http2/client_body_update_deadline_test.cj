package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.transport.*

@Test
class Http2ClientBodyUpdateReviewTest {
    @TestCase
    func bodyWindowUpdatesUseTotalBudgetInsteadOfInboundIdleBudget(): Unit {
        for (stalled in [false, true]) {
            let total = Deadline.after(Duration.second)
            let events = api.NetworkEventBuffer(capacity: 16)
            let context = OperationContext(
                eventSink: Some<NetworkEventSink>(events),
                deadline: Some(total),
                timeoutPolicy: OperationTimeoutPolicy(
                    bodyReadIdle: Some(5 * Duration.millisecond)
                )
            )
            let transport = ReviewFlowGatedTransport()
            let writer = Http2WriteScheduler(transport)
            let running = spawn { writer.run() }
            let flow = Http2FlowController()
            let id = Http2StreamId(1u32)
            flow.openStream(id)
            let channel = Http2ClientBodyChannel(
                id, flow, writer, context, Http2Limits(),
                readTimeoutStage: OperationTimeoutStage.BodyReadIdle
            )
            if (stalled) {
                flow.receiveData(id, 65535)
                @Expect(flow.consumeReceived(id, 4096).isEmpty())
                channel.finish(None)
            } else {
                channel.offerView(
                    Array<Byte>(32768, repeat: 120u8), 0, 32768, 32768, true,
                    None<Http2ReceivedBufferReservation>
                )
            }
            let reading = spawn {
                channel.readSome(MutableByteSpan(Array<Byte>(32768, repeat: 0)), context)
            }
            try {
                @Expect(transport.waitUntilWriteEntered(Duration.second))
                sleep(20 * Duration.millisecond)
                @Expect(!total.isExpired())
                transport.release()
                let result = reading.get(Duration.second)
                match (result) {
                    case ReadResult.EndOfStream => @Expect(stalled)
                    case ReadResult.Data(count) => @Expect(count, 32768)
                }
                let frames = Http2FrameParser().feed(transport.bytes())
                @Expect(frames.size, if (stalled) { 1 } else { 2 })
                for (frame in frames) {
                    @Expect(decodeHttp2WindowUpdate(frame), if (stalled) { 4096u32 } else { 32768u32 })
                }
            } finally {
                transport.release()
                writer.close()
                let _ = running.get(Duration.second)
                channel.close()
                flow.close()
            }
        }
    }

    @TestCase
    func bodyWindowUpdateWriteFailuresAreRetained(): Unit {
        for (preRead in [true, false]) {
            let events = api.NetworkEventBuffer(capacity: 16)
            let context = OperationContext(
                eventSink: Some<NetworkEventSink>(events),
                deadline: Some(Deadline.after(Duration.second)),
                timeoutPolicy: OperationTimeoutPolicy(
                    bodyReadIdle: Some(5 * Duration.millisecond)
                )
            )
            let transport = ReviewFlowGatedTransport(failWrites: true)
            let writer = Http2WriteScheduler(transport)
            let running = spawn { writer.run() }
            let flow = Http2FlowController()
            let id = Http2StreamId(1u32)
            flow.openStream(id)
            let channel = Http2ClientBodyChannel(
                id, flow, writer, context, Http2Limits(),
                readTimeoutStage: OperationTimeoutStage.BodyReadIdle
            )
            if (preRead) {
                flow.receiveData(id, 65535)
                @Expect(flow.consumeReceived(id, 4096).isEmpty())
                channel.finish(None)
            } else {
                channel.offerView(
                    Array<Byte>(32768, repeat: 120u8), 0, 32768, 32768, false,
                    None<Http2ReceivedBufferReservation>
                )
            }
            let reading = spawn {
                try {
                    let _ = channel.readSome(MutableByteSpan(Array<Byte>(32768, repeat: 0)), context)
                    false
                } catch (_: Exception) { true }
            }
            try {
                @Expect(transport.waitUntilWriteEntered(Duration.second))
                transport.release()
                @Expect(reading.get(Duration.second))
                if (!preRead) {
                    var rejectedAfterFailure = false
                    try {
                        channel.offerView(
                            Array<Byte>(1, repeat: 120u8), 0, 1, 1, false,
                            None<Http2ReceivedBufferReservation>
                        )
                    } catch (_: Http2ProtocolException) {
                        rejectedAfterFailure = true
                    }
                    @Expect(rejectedAfterFailure)
                }
                let retainedFailure = channel.terminalFailure.getOrThrow()
                @Expect(channel.observationContext.stage.isSome())
                @Expect(match (retainedFailure) {
                    case _: IllegalStateException => true
                    case _ => false
                })
                var repeatedFailure = None<Exception>
                try {
                    let _ = channel.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)), context)
                } catch (error: Exception) {
                    repeatedFailure = Some(error)
                }
                match (repeatedFailure) {
                    case Some(error) =>
                        @Expect(error.toString() == retainedFailure.toString())
                    case None => @Fail("HTTP/2 body channel forgot its terminal write failure")
                }
            } finally {
                transport.release()
                writer.close()
                let _ = running.get(Duration.second)
                channel.close()
                flow.close()
            }
        }
    }
}

private class ReviewFlowGatedTransport <: DuplexTransport {
    private let failWrites: Bool
    init(failWrites!: Bool = false) { this.failWrites = failWrites }
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let output = ArrayList<Byte>()
    private var writeEntered = false
    private var released = false
    private var closed = false

    public prop info: TransportInfo { get() { TransportInfo("review-http2-flow-control-gated-test") } }

    public func readSome(_: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        synchronized(mutex) {
            writeEntered = true
            changed.notifyAll()
            while (!released) { changed.wait() }
            if (failWrites) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Write,
                    api.NetworkPhase.TcpWrite,
                    api.NetworkErrorCode.BrokenPipe,
                    "gated HTTP/2 flow-control write failure",
                    retryability: api.Retryability.Never
                )
            }
            for (index in 0..source.length) {
                output.add(source.bytes[source.offset + index])
            }
            source.length
        }
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { close() }
    public func close(): Unit {
        synchronized(mutex) {
            closed = true
            released = true
            changed.notifyAll()
        }
    }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        close()
    }

    func waitUntilWriteEntered(timeout: Duration): Bool {
        let deadline = Deadline.after(timeout)
        synchronized(mutex) {
            while (!writeEntered) {
                if (deadline.isExpired()) { return false }
                changed.wait(timeout: deadline.remaining())
            }
            true
        }
    }

    func release(): Unit {
        synchronized(mutex) {
            released = true
            changed.notifyAll()
        }
    }

    func bytes(): Array<Byte> { synchronized(mutex) { output.toArray() } }
}
