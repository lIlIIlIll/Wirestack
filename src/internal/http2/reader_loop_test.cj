package wirestack.internal.http2

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class Http2ConnectionReaderTest {
    @TestCase
    func oneReaderDecodesEveryByteBoundaryAndDispatchesInWireOrder(): Unit {
        let settings = serializeHttp2Frame(encodeHttp2Settings([]))
        let headers = serializeHttp2Frame(readerFrame(Http2FrameType.Headers, 1u32, [0x82], flags: 0x00u8))
        let continuation = serializeHttp2Frame(
            readerFrame(Http2FrameType.Continuation, 1u32, [0x84], flags: 0x04u8)
        )
        let transport = ScriptedReaderTransport(oneByteChunks(joinReaderBytes([settings, headers, continuation])))
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let _ = machine.start()
        let handler = RecordingReaderHandler()
        let reader = Http2ConnectionReader(transport, machine, handler)
        let listener = CountingTerminationListener()
        let _ = reader.terminationRegistry.register(listener)

        let completion = reader.run()

        @Expect(http2ErrorCodeToWire(completion.code), 0u32)
        @Expect(handler.frameCodes(), [4u8, 1u8, 9u8])
        @Expect(handler.completedHeaderBytes(), [0x82u8, 0x84u8])
        @Expect(handler.terminalCalls.load(), 1)
        @Expect(listener.calls.load(), 1)
        @Expect(transport.abortCalls.load(), 1)
        @Expect(!reader.isRunning)
    }

    @TestCase
    func serverConsumesMagicAndFirstFrameFromTheSameRead(): Unit {
        let wire = joinReaderBytes([http2ClientPreface(), serializeHttp2Frame(encodeHttp2Settings([]))])
        let transport = ScriptedReaderTransport([wire])
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let _ = machine.start()
        let handler = RecordingReaderHandler()

        let completion = Http2ConnectionReader(transport, machine, handler).run()

        @Expect(http2ErrorCodeToWire(completion.code), 0u32)
        @Expect(handler.frameCodes(), [4u8])
        @Expect(isReaderTestOpenOrClosed(machine.phase))
    }

    @TestCase
    func eofDuringPrefaceOrFrameFailsAndWakesEveryStream(): Unit {
        let prefaceMachine = Http2ConnectionStateMachine(Http2ConnectionRole.Server)
        let _ = prefaceMachine.start()
        let prefaceHandler = RecordingReaderHandler()
        let prefaceReader = Http2ConnectionReader(
            ScriptedReaderTransport(["PRI".toArray()]), prefaceMachine, prefaceHandler
        )
        let listeners = ArrayList<CountingTerminationListener>()
        for (_ in 0..100) {
            let listener = CountingTerminationListener()
            listeners.add(listener)
            let _ = prefaceReader.terminationRegistry.register(listener)
        }
        let prefaceCompletion = prefaceReader.run()
        @Expect(http2ErrorCodeToWire(prefaceCompletion.code), 1u32)
        @Expect(prefaceHandler.hadTerminalGoAway)
        for (listener in listeners) { @Expect(listener.calls.load(), 1) }

        let frameMachine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let _ = frameMachine.start()
        let incompleteFrame = [0u8, 0u8, 8u8, 6u8]
        let frameCompletion = Http2ConnectionReader(
            ScriptedReaderTransport([incompleteFrame]), frameMachine, RecordingReaderHandler()
        ).run()
        @Expect(http2ErrorCodeToWire(frameCompletion.code), 1u32)
    }

    @TestCase
    func invalidTransportProgressAndHandlerFailureBecomeTerminal(): Unit {
        let invalidMachine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let _ = invalidMachine.start()
        let invalid = ScriptedReaderTransport([], returnZero: true)
        let invalidCompletion = Http2ConnectionReader(
            invalid, invalidMachine, RecordingReaderHandler()
        ).run()
        @Expect(http2ErrorCodeToWire(invalidCompletion.code), 2u32)

        let settings = serializeHttp2Frame(encodeHttp2Settings([]))
        let ping = serializeHttp2Frame(readerPing())
        let failingMachine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let _ = failingMachine.start()
        let failing = RecordingReaderHandler(failAfterFrames: 1)
        let failed = Http2ConnectionReader(
            ScriptedReaderTransport([joinReaderBytes([settings, ping])]), failingMachine, failing
        ).run()
        @Expect(http2ErrorCodeToWire(failed.code), 2u32)
        @Expect(failing.frameCodes(), [4u8])
        @Expect(failing.terminalCalls.load(), 1)
    }

    @TestCase
    func readerLoopCanOnlyBeClaimedOnce(): Unit {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let _ = machine.start()
        let reader = Http2ConnectionReader(
            ScriptedReaderTransport([serializeHttp2Frame(encodeHttp2Settings([]))]),
            machine,
            RecordingReaderHandler()
        )
        let _ = reader.run()
        var rejected = false
        try { let _ = reader.run() } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected)
        @Expect(machine.completionCount, 1)
    }

    @TestCase
    func terminationRegistryIsBoundedRemovableAndExactlyOnce(): Unit {
        let registry = Http2ReaderTerminationRegistry(100u32)
        let listeners = ArrayList<CountingTerminationListener>()
        let removed = CountingTerminationListener()
        let removedRegistration = registry.register(removed)
        removedRegistration.unregister()
        removedRegistration.unregister()
        for (index in 0..100) {
            let listener = CountingTerminationListener(shouldThrow: index == 50)
            listeners.add(listener)
            let _ = registry.register(listener)
        }
        let completion = Http2ConnectionCompletion(Http2ErrorCode.NoError, "done")
        let winners = AtomicInt64(0)
        let tasks = ArrayList<Future<Unit>>()
        for (_ in 0..8) {
            tasks.add(spawn { if (registry.terminate(completion)) { let _ = winners.fetchAdd(1) } })
        }
        for (task in tasks) { task.get(Duration.second) }
        @Expect(winners.load(), 1)
        @Expect(registry.activeCount, 0)
        @Expect(removed.calls.load(), 0)
        for (listener in listeners) { @Expect(listener.calls.load(), 1) }

        let late = CountingTerminationListener()
        let _ = registry.register(late)
        @Expect(late.calls.load(), 1)

        let bounded = Http2ReaderTerminationRegistry(1u32)
        let _ = bounded.register(CountingTerminationListener())
        var rejected = false
        try { let _ = bounded.register(CountingTerminationListener()) } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected)
    }

    @TestCase
    func readerRegistryReservesOneListenerBeyondTheStreamLimit(): Unit {
        let machine = Http2ConnectionStateMachine(Http2ConnectionRole.Client)
        let reader = Http2ConnectionReader(
            ScriptedReaderTransport([]), machine, RecordingReaderHandler(),
            limits: Http2Limits(maxConcurrentStreams: 1u32)
        )
        let first = reader.terminationRegistry.register(CountingTerminationListener())
        let second = reader.terminationRegistry.register(CountingTerminationListener())
        @Expect(reader.terminationRegistry.activeCount, 2)
        var rejected = false
        try {
            let _ = reader.terminationRegistry.register(CountingTerminationListener())
        } catch (_: IllegalStateException) {
            rejected = true
        }
        @Expect(rejected)
        first.unregister()
        second.unregister()
    }
}

private class RecordingReaderHandler <: Http2InboundFrameHandler {
    private let mutex = Mutex()
    private let codes = ArrayList<Byte>()
    private var headerBytes: Array<Byte> = []
    private let failAfterFrames: Int64
    public let terminalCalls = AtomicInt64(0)
    public var hadTerminalGoAway = false

    init(failAfterFrames!: Int64 = 0) { this.failAfterFrames = failAfterFrames }

    public func handle(frame: Http2Frame, result: Http2ConnectionReceiveResult): Unit {
        synchronized(mutex) {
            codes.add(http2FrameTypeCode(frame.header.frameType))
            if (let Some(block) <- result.headerBlock) { headerBytes = block.bytes }
            if (failAfterFrames > 0 && codes.size >= failAfterFrames) {
                throw Exception("scripted HTTP/2 handler failure")
            }
        }
    }

    public func readerTerminated(_: Http2ConnectionCompletion, terminalGoAway: ?Http2Frame): Unit {
        hadTerminalGoAway = terminalGoAway.isSome()
        let _ = terminalCalls.fetchAdd(1)
    }

    func frameCodes(): Array<Byte> { synchronized(mutex) { codes.toArray() } }
    func completedHeaderBytes(): Array<Byte> { synchronized(mutex) { headerBytes.clone() } }
}

private class CountingTerminationListener <: Http2ReaderTerminationListener {
    public let calls = AtomicInt64(0)
    private let shouldThrow: Bool
    init(shouldThrow!: Bool = false) { this.shouldThrow = shouldThrow }
    public func readerTerminated(_: Http2ConnectionCompletion): Unit {
        let _ = calls.fetchAdd(1)
        if (shouldThrow) { throw Exception("scripted listener failure") }
    }
}

private class ScriptedReaderTransport <: DuplexTransport {
    private let chunks: ArrayList<Array<Byte>>
    private let returnZero: Bool
    private var closed = false
    public let abortCalls = AtomicInt64(0)

    init(chunks: Array<Array<Byte>>, returnZero!: Bool = false) {
        this.chunks = ArrayList<Array<Byte>>(chunks)
        this.returnZero = returnZero
    }

    public prop info: TransportInfo { get() { TransportInfo("http2-reader-test") } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        if (returnZero) { return ReadResult.Data(0) }
        if (chunks.isEmpty()) { return ReadResult.EndOfStream }
        let chunk = chunks.remove(at: 0)
        if (chunk.size > destination.length) { throw Exception("script chunk exceeds reader buffer") }
        for (index in 0..chunk.size) { destination.bytes[destination.offset + index] = chunk[index] }
        ReadResult.Data(chunk.size)
    }

    public func writeSome(_: ByteSpan, context!: OperationContext): Int64 { let _ = context; 0 }
    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { closed = true }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
    public func abort(reason!: ?AbortReason): Unit {
        let _ = reason
        closed = true
        let _ = abortCalls.fetchAdd(1)
    }
}

private func readerFrame(
    frameType: Http2FrameType,
    streamId: UInt32,
    payload: Array<Byte>,
    flags!: Byte = 0u8
): Http2Frame {
    Http2Frame(
        Http2FrameHeader(UInt32(payload.size), frameType, Http2Flags(raw: flags), Http2StreamId(streamId)),
        payload
    )
}

private func readerPing(): Http2Frame {
    readerFrame(Http2FrameType.Ping, 0u32, Array<Byte>(8, repeat: 0u8))
}

private func joinReaderBytes(parts: Array<Array<Byte>>): Array<Byte> {
    var size: Int64 = 0
    for (part in parts) { size += part.size }
    let output = Array<Byte>(size, repeat: 0u8)
    var offset: Int64 = 0
    for (part in parts) {
        for (index in 0..part.size) { output[offset + index] = part[index] }
        offset += part.size
    }
    output
}

private func oneByteChunks(input: Array<Byte>): Array<Array<Byte>> {
    let chunks = Array<Array<Byte>>(input.size, repeat: [])
    for (index in 0..input.size) { chunks[index] = [input[index]] }
    chunks
}

private func isReaderTestOpenOrClosed(phase: Http2ConnectionPhase): Bool {
    match (phase) {
        case Http2ConnectionPhase.Open => true
        case Http2ConnectionPhase.Closed => true
        case _ => false
    }
}
