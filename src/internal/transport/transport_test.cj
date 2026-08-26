package wirestack.internal.transport

import std.collection.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private class ChunkedTestTransport <: DuplexTransport {
    private let input: Array<Byte>
    private var readOffset: Int64 = 0
    private let maxChunk: Int64
    private let output = ArrayList<Byte>()
    private var closed = false
    private var readCallCount: Int64 = 0
    private var writeCallCount: Int64 = 0

    init(input: Array<Byte>, maxChunk!: Int64 = 2) {
        this.input = input
        this.maxChunk = maxChunk
    }

    public prop info: TransportInfo {
        get() { TransportInfo("test") }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        readCallCount++
        if (destination.isEmpty()) {
            return ReadResult.Data(0)
        }
        if (readOffset >= input.size) {
            return ReadResult.EndOfStream
        }
        let count = min(destination.length, min(maxChunk, input.size - readOffset))
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = input[readOffset + index]
        }
        readOffset += count
        ReadResult.Data(count)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        writeCallCount++
        if (source.isEmpty()) {
            return 0
        }
        let count = min(source.length, maxChunk)
        for (index in 0..count) {
            output.add(source.bytes[source.offset + index])
        }
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(context: OperationContext): Unit { let _ = context; closed = true }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { closed }

    func written(): Array<Byte> { output.toArray() }
    func readCalls(): Int64 { readCallCount }
    func writeCalls(): Int64 { writeCallCount }
}

private class HelperClock <: MonotonicClock {
    private var current: MonoTime

    init(start: MonoTime) { current = start }
    public func now(): MonoTime { current }
    func expire(): Unit { current = current + 2 * Duration.second }
}

private enum HelperFailure {
    | NoFailure
    | CancelAfterFirst(CancellationSource)
    | DeadlineAfterFirst(HelperClock)
}

private class ScriptedHelperTransport <: DuplexTransport {
    private let input: Array<Byte>
    private let invalidWriteCount: ?Int64
    private let invalidReadCount: ?Int64
    private let failure: HelperFailure
    private let output = ArrayList<Byte>()
    private var readOffset: Int64 = 0
    private var readCalls: Int64 = 0
    private var writeCalls: Int64 = 0
    private var closed = false

    init(
        input!: Array<Byte> = [],
        invalidWriteCount!: ?Int64 = None<Int64>,
        invalidReadCount!: ?Int64 = None<Int64>,
        failure!: HelperFailure = HelperFailure.NoFailure
    ) {
        this.input = input
        this.invalidWriteCount = invalidWriteCount
        this.invalidReadCount = invalidReadCount
        this.failure = failure
    }

    public prop info: TransportInfo { get() { TransportInfo("helper-script") } }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        preflightHelperContext(context, NetworkErrorCategory.Read, NetworkPhase.TcpRead)
        match (invalidReadCount) {
            case Some(count) => return ReadResult.Data(count)
            case None => ()
        }
        if (readOffset >= input.size) { return ReadResult.EndOfStream }
        let count = min(1, min(destination.length, input.size - readOffset))
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = input[readOffset + index]
        }
        readOffset += count
        readCalls++
        if (readCalls == 1) { triggerHelperFailure(failure) }
        ReadResult.Data(count)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        preflightHelperContext(context, NetworkErrorCategory.Write, NetworkPhase.TcpWrite)
        match (invalidWriteCount) {
            case Some(count) => return count
            case None => ()
        }
        let count = min(1, source.length)
        for (index in 0..count) { output.add(source.bytes[source.offset + index]) }
        writeCalls++
        if (writeCalls == 1) { triggerHelperFailure(failure) }
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(context: OperationContext): Unit { let _ = context; closed = true }
    public func abort(reason!: ?AbortReason): Unit { let _ = reason; closed = true }
    public func close(): Unit { close(OperationContext.background()) }
    public func isClosed(): Bool { closed }

    func written(): Array<Byte> { output.toArray() }
}

@Test
class TransportHelperTest {
    @TestCase
    func writeAllHandlesPartialWritesAndEmptyInput(): Unit {
        let transport = ChunkedTestTransport([])
        writeAll(transport, ByteSpan([1, 2, 3, 4, 5]))
        let expected: Array<Byte> = [1, 2, 3, 4, 5]
        @Expect(transport.written(), expected)
    }

    @TestCase
    func readExactHandlesPartialReads(): Unit {
        let transport = ChunkedTestTransport([1, 2, 3, 4, 5])
        let destination = Array<Byte>(5, repeat: 0)
        readExact(transport, MutableByteSpan(destination))
        let expected: Array<Byte> = [1, 2, 3, 4, 5]
        @Expect(destination, expected)
    }

    @TestCase
    func readExactClassifiesPrematureEof(): Unit {
        let transport = ChunkedTestTransport([1, 2])
        var classified = false
        try {
            readExact(transport, MutableByteSpan(Array<Byte>(3, repeat: 0)))
        } catch (error: NetworkException) {
            classified = isHelperError(
                error,
                NetworkErrorCategory.Read,
                NetworkPhase.TcpRead,
                NetworkErrorCode.UnexpectedEof,
                Retryability.Never
            )
        }
        @Expect(classified)
    }

    @TestCase
    func emptyHelpersDoNotCallTransport(): Unit {
        let transport = ChunkedTestTransport([])
        writeAll(transport, ByteSpan([]))
        readExact(transport, MutableByteSpan([]))
        @Expect(transport.writeCalls(), 0)
        @Expect(transport.readCalls(), 0)
    }

    @TestCase
    func invalidProgressFailsOnceWithoutSpinning(): Unit {
        let invalidCounts: Array<Int64> = [-1, 0, 4]
        for (count in invalidCounts) {
            let writer = ScriptedHelperTransport(invalidWriteCount: Some(count))
            @Expect(throwsHelperError(
                { => writeAll(writer, ByteSpan([1, 2, 3])) },
                NetworkErrorCategory.System,
                NetworkPhase.TcpWrite,
                NetworkErrorCode.SystemFailure,
                Retryability.Never
            ))

            let reader = ScriptedHelperTransport(input: [1, 2, 3], invalidReadCount: Some(count))
            @Expect(throwsHelperError(
                { => readExact(reader, MutableByteSpan(Array<Byte>(3, repeat: 0))) },
                NetworkErrorCategory.System,
                NetworkPhase.TcpRead,
                NetworkErrorCode.SystemFailure,
                Retryability.Never
            ))
        }
    }

    @TestCase
    func cancellationAfterPartialProgressPropagatesWithoutRestart(): Unit {
        let writeSource = CancellationSource()
        let writer = ScriptedHelperTransport(failure: HelperFailure.CancelAfterFirst(writeSource))
        @Expect(throwsHelperError(
            { => writeAll(writer, ByteSpan([1, 2, 3]),
                context: OperationContext(cancellation: writeSource.token)) },
            NetworkErrorCategory.Write,
            NetworkPhase.TcpWrite,
            NetworkErrorCode.Cancelled,
            Retryability.Never
        ))
        let written: Array<Byte> = [1]
        @Expect(writer.written(), written)

        let readSource = CancellationSource()
        let reader = ScriptedHelperTransport(
            input: [7, 8, 9],
            failure: HelperFailure.CancelAfterFirst(readSource)
        )
        let destination = Array<Byte>(3, repeat: 0)
        @Expect(throwsHelperError(
            { => readExact(reader, MutableByteSpan(destination),
                context: OperationContext(cancellation: readSource.token)) },
            NetworkErrorCategory.Read,
            NetworkPhase.TcpRead,
            NetworkErrorCode.Cancelled,
            Retryability.Never
        ))
        @Expect(destination[0], 7)
        @Expect(destination[1], 0)
    }

    @TestCase
    func absoluteDeadlineExpiresAcrossPartialRetries(): Unit {
        let writeClock = HelperClock(MonoTime.now())
        let writeDeadline = Deadline.after(Duration.second, clock: writeClock)
        let writer = ScriptedHelperTransport(failure: HelperFailure.DeadlineAfterFirst(writeClock))
        @Expect(throwsHelperError(
            { => writeAll(writer, ByteSpan([1, 2, 3]),
                context: OperationContext(deadline: Some(writeDeadline))) },
            NetworkErrorCategory.Write,
            NetworkPhase.TcpWrite,
            NetworkErrorCode.TimedOut,
            Retryability.Temporary
        ))
        let written: Array<Byte> = [1]
        @Expect(writer.written(), written)

        let readClock = HelperClock(MonoTime.now())
        let readDeadline = Deadline.after(Duration.second, clock: readClock)
        let reader = ScriptedHelperTransport(
            input: [7, 8, 9],
            failure: HelperFailure.DeadlineAfterFirst(readClock)
        )
        let destination = Array<Byte>(3, repeat: 0)
        @Expect(throwsHelperError(
            { => readExact(reader, MutableByteSpan(destination),
                context: OperationContext(deadline: Some(readDeadline))) },
            NetworkErrorCategory.Read,
            NetworkPhase.TcpRead,
            NetworkErrorCode.TimedOut,
            Retryability.Temporary
        ))
        @Expect(destination[0], 7)
        @Expect(destination[1], 0)
    }
}

private func triggerHelperFailure(failure: HelperFailure): Unit {
    match (failure) {
        case HelperFailure.NoFailure => ()
        case HelperFailure.CancelAfterFirst(source) => source.cancel()
        case HelperFailure.DeadlineAfterFirst(clock) => clock.expire()
    }
}

private func preflightHelperContext(
    context: OperationContext,
    category: NetworkErrorCategory,
    phase: NetworkPhase
): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            category,
            phase,
            NetworkErrorCode.Cancelled,
            "scripted helper operation cancelled",
            retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            category,
            phase,
            NetworkErrorCode.TimedOut,
            "scripted helper operation timed out",
            retryability: Retryability.Temporary
        )
    }
}

private func throwsHelperError(
    action: () -> Unit,
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    code: NetworkErrorCode,
    retryability: Retryability
): Bool {
    try {
        action()
        false
    } catch (error: NetworkException) {
        isHelperError(error, category, phase, code, retryability)
    }
}

private func isHelperError(
    error: NetworkException,
    category: NetworkErrorCategory,
    phase: NetworkPhase,
    code: NetworkErrorCode,
    retryability: Retryability
): Bool {
    sameHelperCategory(error.category, category) &&
        sameHelperPhase(error.phase, phase) &&
        sameHelperCode(error.code, code) &&
        sameHelperRetryability(error.retryability, retryability)
}

private func sameHelperCategory(left: NetworkErrorCategory, right: NetworkErrorCategory): Bool {
    match ((left, right)) {
        case (NetworkErrorCategory.Read, NetworkErrorCategory.Read) |
             (NetworkErrorCategory.Write, NetworkErrorCategory.Write) |
             (NetworkErrorCategory.System, NetworkErrorCategory.System) => true
        case _ => false
    }
}

private func sameHelperPhase(left: NetworkPhase, right: NetworkPhase): Bool {
    match ((left, right)) {
        case (NetworkPhase.TcpRead, NetworkPhase.TcpRead) |
             (NetworkPhase.TcpWrite, NetworkPhase.TcpWrite) => true
        case _ => false
    }
}

private func sameHelperCode(left: NetworkErrorCode, right: NetworkErrorCode): Bool {
    match ((left, right)) {
        case (NetworkErrorCode.UnexpectedEof, NetworkErrorCode.UnexpectedEof) |
             (NetworkErrorCode.SystemFailure, NetworkErrorCode.SystemFailure) |
             (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) |
             (NetworkErrorCode.TimedOut, NetworkErrorCode.TimedOut) => true
        case _ => false
    }
}

private func sameHelperRetryability(left: Retryability, right: Retryability): Bool {
    match ((left, right)) {
        case (Retryability.Never, Retryability.Never) |
             (Retryability.Temporary, Retryability.Temporary) => true
        case _ => false
    }
}
