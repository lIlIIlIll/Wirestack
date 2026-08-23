package wirestack.internal.tls_engine

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class TlsEnginePumpTest {
    @TestCase
    func awsLcClientEngineProducesAClientHelloWithoutSocketIo(): Unit {
        let provider = AwsLcTlsProvider()
        let engine = provider.createEngine(TlsEngineRole.Client)
        try {
            var wantsRead = false
            match (engine.handshakeStep()) {
                case TlsEngineStep.WantRead => wantsRead = true
                case _ => ()
            }
            @Expect(wantsRead)
            @Expect(engine.pendingCiphertext() > 0)
            let output = Array<Byte>(4096, repeat: 0)
            let count = engine.drainCiphertext(MutableByteSpan(output))
            @Expect(count > 5)
            @Expect(output[0], 22) // TLS handshake record content type.
        } finally {
            engine.close()
            provider.close()
        }
    }

    @TestCase
    func pumpHandlesWantReadWriteAndPartialIoWithBoundedBuffers(): Unit {
        let engine = ScriptedEngine()
        let transport = ScriptedTransport([7, 6, 5], readChunk: 2, writeChunk: 2)

        TlsEnginePump(ciphertextChunkSize: 3).driveHandshake(engine, transport)

        @Expect(transport.written.size, 7)
        @Expect(transport.written[0], 1)
        @Expect(transport.written[4], 5)
        @Expect(transport.written[5], 9)
        @Expect(transport.written[6], 8)
        @Expect(engine.fed.size, 2)
        @Expect(engine.fed[0], 7)
        @Expect(engine.fed[1], 6)
        @Expect(transport.maxRequestedRead, 3)
        @Expect(transport.maxRequestedWrite <= 3)
    }

    @TestCase
    func wantWriteWithoutCiphertextFailsInsteadOfSpinning(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantWrite)
        let transport = ScriptedTransport([])
        var observed = false

        try {
            TlsEnginePump().driveHandshake(engine, transport)
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.NoProgress => observed = true
                case _ => ()
            }
        }
        @Expect(observed)
        @Expect(engine.steps, 1)
    }

    @TestCase
    func eofDuringWantReadRetainsTlsHandshakeEvidence(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([])
        var observed = false

        try {
            TlsEnginePump().driveHandshake(engine, transport)
        } catch (error: TlsEngineException) {
            match (error.tlsCode) {
                case TlsEngineErrorCode.UnexpectedTransportEof =>
                    match (error.phase) {
                        case NetworkPhase.TlsHandshake => observed = true
                        case _ => ()
                    }
                case _ => ()
            }
        }
        @Expect(observed)
    }

    @TestCase
    func preCancellationStopsBeforeCallingProviderOrTransport(): Unit {
        let source = CancellationSource()
        source.cancel()
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([1])
        var cancelled = false

        try {
            TlsEnginePump().driveHandshake(
                engine,
                transport,
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
        @Expect(engine.steps, 0)
        @Expect(transport.readCalls, 0)
        @Expect(transport.writeCalls, 0)
    }

    @TestCase
    func expiredDeadlineStopsBeforeCallingProviderOrTransport(): Unit {
        let engine = StalledEngine(TlsEngineStep.WantRead)
        let transport = ScriptedTransport([1])
        var timedOut = false

        try {
            TlsEnginePump().driveHandshake(
                engine,
                transport,
                context: OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => timedOut = true
                case _ => ()
            }
        }
        @Expect(timedOut)
        @Expect(engine.steps, 0)
        @Expect(transport.readCalls, 0)
        @Expect(transport.writeCalls, 0)
    }
}

private class ScriptedEngine <: TlsEngine {
    let fed = ArrayList<Byte>()
    private let outgoing = ArrayList<Byte>()
    private var stepNumber: Int64 = 0

    public func handshakeStep(): TlsEngineStep {
        stepNumber++
        if (stepNumber == 1) {
            let values: Array<Byte> = [1, 2, 3, 4, 5]
            for (value in values) { outgoing.add(value) }
            return TlsEngineStep.WantWrite
        }
        if (fed.isEmpty()) {
            return TlsEngineStep.WantRead
        }
        let values: Array<Byte> = [9, 8]
        for (value in values) { outgoing.add(value) }
        TlsEngineStep.Complete
    }

    public func pendingCiphertext(): Int64 { outgoing.size }

    public func drainCiphertext(destination: MutableByteSpan): Int64 {
        let count = min(min(destination.length, outgoing.size), 2)
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = outgoing.remove(at: 0)
        }
        count
    }

    public func feedCiphertext(source: ByteSpan): Int64 {
        let count = min(source.length, 1)
        for (index in 0..count) { fed.add(source.bytes[source.offset + index]) }
        count
    }

    public func close(): Unit {}
    public func isClosed(): Bool { false }
}

private class StalledEngine <: TlsEngine {
    private let result: TlsEngineStep
    var steps: Int64 = 0

    init(result: TlsEngineStep) { this.result = result }

    public func handshakeStep(): TlsEngineStep { steps++; result }
    public func pendingCiphertext(): Int64 { 0 }
    public func drainCiphertext(_: MutableByteSpan): Int64 { 0 }
    public func feedCiphertext(_: ByteSpan): Int64 { 0 }
    public func close(): Unit {}
    public func isClosed(): Bool { false }
}

private class ScriptedTransport <: DuplexTransport {
    private let incoming: ArrayList<Byte>
    private let readChunk: Int64
    private let writeChunk: Int64
    let written = ArrayList<Byte>()
    var readCalls: Int64 = 0
    var writeCalls: Int64 = 0
    var maxRequestedRead: Int64 = 0
    var maxRequestedWrite: Int64 = 0

    init(
        input: Array<Byte>,
        readChunk!: Int64 = 16 * 1024,
        writeChunk!: Int64 = 16 * 1024
    ) {
        incoming = ArrayList<Byte>()
        for (value in input) { incoming.add(value) }
        this.readChunk = readChunk
        this.writeChunk = writeChunk
    }

    public prop info: TransportInfo {
        get() { TransportInfo("tls-pump-test", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        readCalls++
        maxRequestedRead = max(maxRequestedRead, destination.length)
        if (incoming.isEmpty()) { return ReadResult.EndOfStream }
        let count = min(min(destination.length, incoming.size), readChunk)
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = incoming.remove(at: 0)
        }
        ReadResult.Data(count)
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        writeCalls++
        maxRequestedWrite = max(maxRequestedWrite, source.length)
        let count = min(source.length, writeChunk)
        for (index in 0..count) { written.add(source.bytes[source.offset + index]) }
        count
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {}
    public func close(): Unit {}
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { let _ = reason }
    public func isClosed(): Bool { false }
}
