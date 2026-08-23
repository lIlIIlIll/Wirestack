package wirestack.internal.tls_engine

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class TlsConnectionTest {
    @TestCase
    func handshakeTransfersOwnershipAndPlaintextIoUsesTheEngine(): Unit {
        let engine = LifecycleEngine()
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)

        let output = Array<Byte>(2, repeat: 0)
        match (connection.readSome(MutableByteSpan(output))) {
            case ReadResult.Data(count) => @Expect(count, 1)
            case ReadResult.EndOfStream => @Expect(false)
        }
        @Expect(output[0], 42)
        @Expect(connection.writeSome(ByteSpan([1, 2, 3])), 3)
        @Expect(engine.writtenBytes.load(), 3)
        @Expect(transport.readCalls.load(), 0)
        @Expect(transport.writeCalls.load(), 0)

        connection.close()
        connection.close()
        @Expect(engine.closeCalls.load(), 1)
        @Expect(transport.closeCalls.load(), 1)
        @Expect(transport.abortCalls.load(), 0)
        @Expect(connection.isClosed())
    }

    @TestCase
    func oneReadAndOneWriteMayOverlapButSecondReadFailsImmediately(): Unit {
        let entered = SyncCounter(1)
        let engine = LifecycleEngine(blockRead: true, entered: Some(entered))
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)
        let first: Future<ReadResult> = spawn {
            connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        }
        entered.waitUntilZero()

        @Expect(connection.writeSome(ByteSpan([7])), 1)
        var concurrentRead = false
        try {
            let _ = connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.ConcurrentOperation => concurrentRead = true
                case _ => ()
            }
        }
        @Expect(concurrentRead)
        @Expect(!connection.isClosed())

        engine.releaseRead()
        match (first.get(Duration.second)) {
            case ReadResult.Data(count) => @Expect(count, 1)
            case ReadResult.EndOfStream => @Expect(false)
        }
        connection.close()
    }

    @TestCase
    func handshakeFailureAbortsTransportAndReleasesEngineExactlyOnce(): Unit {
        let engine = LifecycleEngine(failHandshake: true)
        let transport = LifecycleTransport()
        var observed = false

        try {
            let _ = TlsConnection.handshake(engine, transport)
        } catch (_: TlsEngineException) {
            observed = true
        }
        @Expect(observed)
        @Expect(engine.closeCalls.load(), 1)
        @Expect(transport.abortCalls.load(), 1)
        @Expect(transport.closeCalls.load(), 0)
    }

    @TestCase
    func expiredHandshakeDeadlineStillConsumesAndAbortsBothInputs(): Unit {
        let engine = LifecycleEngine()
        let transport = LifecycleTransport()
        var timedOut = false

        try {
            let _ = TlsConnection.handshake(
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
        @Expect(engine.closeCalls.load(), 1)
        @Expect(transport.abortCalls.load(), 1)
        @Expect(transport.terminalDisposals.load(), 1)
    }

    @TestCase
    func ioFailureAbortsAndRepeatedTerminalCallsDoNotReleaseTwice(): Unit {
        let engine = LifecycleEngine(failRead: true)
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)
        var observed = false

        try {
            let _ = connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => observed = true
                case _ => ()
            }
        }
        connection.abort(reason: Some(AbortReason.ApplicationAbort))
        connection.close()
        @Expect(observed)
        @Expect(engine.closeCalls.load(), 1)
        @Expect(transport.abortCalls.load(), 1)
        @Expect(transport.closeCalls.load(), 0)
        @Expect(connection.isClosed())
    }

    @TestCase
    func unsupportedHalfCloseDoesNotMutateAnOpenConnection(): Unit {
        let engine = LifecycleEngine()
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)
        var unsupported = false

        try {
            connection.shutdown(ShutdownDirection.Write)
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Unsupported => unsupported = true
                case _ => ()
            }
        }
        @Expect(unsupported)
        @Expect(!connection.isClosed())
        connection.close()
    }

    @TestCase
    func concurrentCloseAndAbortReleaseUnderlyingResourcesOnce(): Unit {
        for (_ in 0..100) {
            let engine = LifecycleEngine()
            let transport = LifecycleTransport()
            let connection = TlsConnection.handshake(engine, transport)
            let closeTask: Future<Unit> = spawn { connection.close() }
            let abortTask: Future<Unit> = spawn {
                connection.abort(reason: Some(AbortReason.ApplicationAbort))
            }
            closeTask.get(Duration.second)
            abortTask.get(Duration.second)

            @Expect(engine.closeCalls.load(), 1)
            @Expect(transport.terminalDisposals.load(), 1)
            @Expect(connection.isClosed())
        }
    }
}

private class LifecycleEngine <: TlsEngine {
    private let failHandshake: Bool
    private let failRead: Bool
    private let blockRead: Bool
    private let entered: ?SyncCounter
    private let readMutex = Mutex()
    private let readChanged = synchronized(readMutex) { readMutex.condition() }
    private var readReleased = false
    let closeCalls = AtomicInt64(0)
    let writtenBytes = AtomicInt64(0)

    init(
        failHandshake!: Bool = false,
        failRead!: Bool = false,
        blockRead!: Bool = false,
        entered!: ?SyncCounter = None<SyncCounter>
    ) {
        this.failHandshake = failHandshake
        this.failRead = failRead
        this.blockRead = blockRead
        this.entered = entered
    }

    public func handshakeStep(): TlsEngineStep {
        if (failHandshake) {
            throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "deterministic handshake failure"
            )
        }
        TlsEngineStep.Complete
    }

    public func pendingCiphertext(): Int64 { 0 }
    public func drainCiphertext(_: MutableByteSpan): Int64 { 0 }
    public func feedCiphertext(source: ByteSpan): Int64 { source.length }

    public func readPlaintext(destination: MutableByteSpan): TlsEngineReadResult {
        if (failRead) {
            throw NetworkException(
                NetworkErrorCategory.DeadlineExceeded,
                NetworkPhase.TlsRead,
                NetworkErrorCode.TimedOut,
                "deterministic TLS read timeout",
                retryability: Retryability.Never
            )
        }
        if (blockRead) {
            match (entered) {
                case Some(counter) => counter.dec()
                case None => ()
            }
            synchronized(readMutex) {
                while (!readReleased) { readChanged.wait() }
            }
        }
        destination.bytes[destination.offset] = 42
        TlsEngineReadResult.Data(1)
    }

    public func writePlaintext(source: ByteSpan): TlsEngineWriteResult {
        writtenBytes.fetchAdd(source.length)
        TlsEngineWriteResult.Consumed(source.length)
    }

    public func close(): Unit { closeCalls.fetchAdd(1); () }
    public func isClosed(): Bool { closeCalls.load() > 0 }

    func releaseRead(): Unit {
        synchronized(readMutex) {
            readReleased = true
            readChanged.notifyAll()
        }
    }
}

private class LifecycleTransport <: DuplexTransport {
    let readCalls = AtomicInt64(0)
    let writeCalls = AtomicInt64(0)
    let closeCalls = AtomicInt64(0)
    let abortCalls = AtomicInt64(0)
    let terminalDisposals = AtomicInt64(0)
    private let disposed = AtomicBool(false)

    public prop info: TransportInfo {
        get() { TransportInfo("lifecycle-test", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        _: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        readCalls.fetchAdd(1)
        ReadResult.EndOfStream
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        writeCalls.fetchAdd(1)
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit {
        closeCalls.fetchAdd(1)
        if (!disposed.swap(true)) { terminalDisposals.fetchAdd(1); () }
    }
    public func close(): Unit { close(OperationContext.background()) }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        abortCalls.fetchAdd(1)
        if (!disposed.swap(true)) { terminalDisposals.fetchAdd(1); () }
        ()
    }
    public func isClosed(): Bool { closeCalls.load() > 0 || abortCalls.load() > 0 }
}
