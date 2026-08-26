package wirestack.internal.transport

import std.sync.SyncCounter
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MemoryTransportTest {
    @TestCase
    func pairTransfersPartialDataInBothDirections(): Unit {
        let (left, right) = MemoryTransport.pair(capacity: 8, maxChunk: 2)
        @Expect(left.writeSome(ByteSpan([1, 2, 3])), 2)
        let fromLeft = Array<Byte>(4, repeat: 0)
        match (right.readSome(MutableByteSpan(fromLeft))) {
            case ReadResult.Data(count) => @Expect(count, 2)
            case ReadResult.EndOfStream => @Expect(false)
        }
        @Expect(fromLeft[0], 1)
        @Expect(fromLeft[1], 2)

        @Expect(right.writeSome(ByteSpan([9])), 1)
        let fromRight = Array<Byte>(1, repeat: 0)
        readExact(left, MutableByteSpan(fromRight))
        @Expect(fromRight[0], 9)
    }

    @TestCase
    func emptyBuffersReturnZeroWithoutProducingEofOrPeerData(): Unit {
        let (left, right) = MemoryTransport.pair()
        match (left.readSome(MutableByteSpan(Array<Byte>(0, repeat: 0)))) {
            case ReadResult.Data(count) => @Expect(count, 0)
            case ReadResult.EndOfStream => @Expect(false)
        }
        @Expect(left.writeSome(ByteSpan(Array<Byte>(0, repeat: 0))), 0)

        left.shutdown(ShutdownDirection.Write)
        match (right.readSome(MutableByteSpan(Array<Byte>(0, repeat: 0)))) {
            case ReadResult.Data(count) => @Expect(count, 0)
            case ReadResult.EndOfStream => @Expect(false)
        }
        match (right.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
            case ReadResult.EndOfStream => @Expect(true)
            case ReadResult.Data(_) => @Expect(false)
        }
    }

    @TestCase
    func writeShutdownProducesPeerEofAfterBufferedData(): Unit {
        let (left, right) = MemoryTransport.pair()
        @Expect(left.writeSome(ByteSpan([7, 8])), 2)
        left.shutdown(ShutdownDirection.Write)

        let data = Array<Byte>(2, repeat: 0)
        readExact(right, MutableByteSpan(data))
        @Expect(data[0], 7)
        @Expect(data[1], 8)
        match (right.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
            case ReadResult.EndOfStream => @Expect(true)
            case ReadResult.Data(_) => @Expect(false)
        }
    }

    @TestCase
    func readShutdownMakesPeerWritesFailAsBrokenPipe(): Unit {
        let (left, right) = MemoryTransport.pair()
        right.shutdown(ShutdownDirection.Read)
        var brokenPipe = false
        try {
            let _ = left.writeSome(ByteSpan([1]))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.BrokenPipe => brokenPipe = true
                case _ => ()
            }
        }
        @Expect(brokenPipe)
    }

    @TestCase
    func cancelledBeforeOperationHasNoDataSideEffect(): Unit {
        let (left, right) = MemoryTransport.pair()
        let source = CancellationSource()
        source.cancel()
        var cancelled = false
        try {
            let _ = left.writeSome(
                ByteSpan([1]),
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)

        left.shutdown(ShutdownDirection.Write)
        match (right.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
            case ReadResult.EndOfStream => @Expect(true)
            case ReadResult.Data(_) => @Expect(false)
        }
    }

    @TestCase
    func closeAndAbortAreIdempotentAndTerminal(): Unit {
        let (left, right) = MemoryTransport.pair()
        let cancelled = CancellationSource()
        cancelled.cancel()
        left.close(OperationContext(cancellation: cancelled.token))
        left.close()
        left.abort()
        @Expect(left.isClosed())

        right.abort(reason: Some(AbortReason.ApplicationAbort))
        right.abort()
        @Expect(right.isClosed())
    }

    @TestCase
    func cancellationWakesABlockedRead(): Unit {
        let (_, right) = MemoryTransport.pair()
        let source = CancellationSource()
        let started = SyncCounter(1)
        let result: Future<Bool> = spawn {
            started.dec()
            try {
                let _ = right.readSome(
                    MutableByteSpan(Array<Byte>(1, repeat: 0)),
                    context: OperationContext(cancellation: source.token)
                )
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => true
                    case _ => false
                }
            }
        }
        started.waitUntilZero()
        source.cancel()
        @Expect(result.get(Duration.second), true)
    }

    @TestCase
    func closeWakesABlockedLocalRead(): Unit {
        let (left, _) = MemoryTransport.pair()
        let started = SyncCounter(1)
        let result: Future<Bool> = spawn {
            started.dec()
            try {
                let _ = left.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => true
                    case _ => false
                }
            }
        }
        started.waitUntilZero()
        left.close()
        @Expect(result.get(Duration.second), true)
    }

    @TestCase
    func writeShutdownWakesABlockedLocalWrite(): Unit {
        let (left, _) = MemoryTransport.pair(capacity: 1, maxChunk: 1)
        @Expect(left.writeSome(ByteSpan([1])), 1)
        let started = SyncCounter(1)
        let result: Future<Bool> = spawn {
            started.dec()
            try {
                let _ = left.writeSome(ByteSpan([2]))
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => true
                    case _ => false
                }
            }
        }
        started.waitUntilZero()
        left.shutdown(ShutdownDirection.Write)
        @Expect(result.get(Duration.second), true)
    }

    @TestCase
    func boundedBackpressureResumesAfterPeerReads(): Unit {
        let (left, right) = MemoryTransport.pair(capacity: 2, maxChunk: 2)
        let writer: Future<Unit> = spawn {
            writeAll(left, ByteSpan([1, 2, 3, 4]))
        }
        let received = Array<Byte>(4, repeat: 0)
        readExact(right, MutableByteSpan(received))
        writer.get(Duration.second)

        let expected: Array<Byte> = [1, 2, 3, 4]
        @Expect(received, expected)
    }

    @TestCase
    func expiredDeadlineFailsBeforeAnyWrite(): Unit {
        let (left, right) = MemoryTransport.pair()
        let expired = Deadline(MonoTime.now())
        var timedOut = false
        try {
            let _ = left.writeSome(
                ByteSpan([1]),
                context: OperationContext(deadline: Some(expired))
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => timedOut = true
                case _ => ()
            }
        }
        @Expect(timedOut)

        left.shutdown(ShutdownDirection.Write)
        match (right.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
            case ReadResult.EndOfStream => @Expect(true)
            case ReadResult.Data(_) => @Expect(false)
        }
    }
}
