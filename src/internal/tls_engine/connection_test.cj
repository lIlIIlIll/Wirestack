package wirestack.internal.tls_engine

import std.sync.*
import std.env.getVariable
import std.runtime.*
import std.convert.*
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

    @TestCase
    func gracefulCloseSendsAndProcessesCloseNotifyBeforeReleasingResources(): Unit {
        let engine = LifecycleEngine(shutdownNeedsPeer: true)
        let transport = LifecycleTransport(respondToTlsClose: true)
        let connection = TlsConnection.handshake(engine, transport)

        connection.close(OperationContext(deadline: Some(Deadline.after(Duration.second))))

        @Expect(engine.shutdownCalls.load(), 3)
        @Expect(transport.writeCalls.load(), 1)
        @Expect(transport.readCalls.load(), 1)
        @Expect(transport.closeCalls.load(), 1)
        @Expect(engine.closeCalls.load(), 1)
        match (connection.closureEvidence) {
            case Some(TlsClosureEvidence.CloseNotify) => @Expect(true)
            case _ => @Fail("graceful close must retain close_notify evidence")
        }
    }

    @TestCase
    func tcpEofDuringGracefulCloseRetainsTruncationAndStillReleasesEverything(): Unit {
        let engine = LifecycleEngine(shutdownNeedsPeer: true)
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)
        var truncated = false

        try {
            connection.close(OperationContext(deadline: Some(Deadline.after(Duration.second))))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.UnexpectedEof => truncated = true
                case _ => ()
            }
        }

        @Expect(truncated)
        @Expect(connection.isClosed())
        @Expect(transport.closeCalls.load(), 1)
        @Expect(engine.closeCalls.load(), 1)
        match (connection.closureEvidence) {
            case Some(TlsClosureEvidence.PeerClosedWithoutCloseNotify) => @Expect(true)
            case _ => @Fail("bare TCP EOF must retain TLS truncation evidence")
        }
    }

    @TestCase
    func expiredCloseBudgetStillClosesTransportAndReleasesEngine(): Unit {
        let engine = LifecycleEngine(shutdownNeedsPeer: true)
        let transport = LifecycleTransport(respondToTlsClose: true)
        let connection = TlsConnection.handshake(engine, transport)
        var timedOut = false

        try {
            connection.close(
                OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => timedOut = true
                case _ => ()
            }
        }

        @Expect(timedOut)
        @Expect(engine.shutdownCalls.load(), 0)
        @Expect(transport.closeCalls.load(), 1)
        @Expect(engine.closeCalls.load(), 1)
        @Expect(connection.isClosed())
    }

    @TestCase
    func abortNeverAttemptsTlsShutdownAndRetainsLocalAbortEvidence(): Unit {
        let engine = LifecycleEngine(shutdownNeedsPeer: true)
        let transport = LifecycleTransport(respondToTlsClose: true)
        let connection = TlsConnection.handshake(engine, transport)

        connection.abort(reason: Some(AbortReason.ApplicationAbort))

        @Expect(engine.shutdownCalls.load(), 0)
        @Expect(transport.writeCalls.load(), 0)
        @Expect(transport.abortCalls.load(), 1)
        @Expect(engine.closeCalls.load(), 1)
        match (connection.closureEvidence) {
            case Some(TlsClosureEvidence.LocalAbort) => @Expect(true)
            case _ => @Fail("abort must retain local termination evidence")
        }
    }

    @TestCase
    func tcpEofDuringApplicationReadRetainsTruncationBeforeAbort(): Unit {
        let engine = LifecycleEngine(readNeedsTransport: true)
        let transport = LifecycleTransport()
        let connection = TlsConnection.handshake(engine, transport)
        var truncated = false

        try {
            let _ = connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.UnexpectedEof => truncated = true
                case _ => ()
            }
        }

        @Expect(truncated)
        @Expect(transport.abortCalls.load(), 1)
        match (connection.closureEvidence) {
            case Some(TlsClosureEvidence.PeerClosedWithoutCloseNotify) => @Expect(true)
            case _ => @Fail("application read must retain bare EOF as TLS truncation")
        }
    }

    @TestCase
    func peerCloseNotifyProducesEofEvidenceAndRejectsNewApplicationWrites(): Unit {
        let engine = LifecycleEngine(peerClosedRead: true)
        let connection = TlsConnection.handshake(engine, LifecycleTransport())

        match (connection.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
            case ReadResult.EndOfStream => @Expect(true)
            case _ => @Fail("peer close_notify must produce plaintext EOF")
        }
        var writeClosed = false
        try {
            let _ = connection.writeSome(ByteSpan([1]))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Closed => writeClosed = true
                case _ => ()
            }
        }

        @Expect(writeClosed)
        match (connection.closureEvidence) {
            case Some(TlsClosureEvidence.CloseNotify) => @Expect(true)
            case _ => @Fail("peer close_notify must be retained")
        }
        connection.close()
    }
}

private func net06TlsCleanupIterations(): Int64 {
    match (getVariable("WIRESTACK_NET06_ITERATIONS")) {
        case Some(value) =>
            let parsed = Int64.parse(value)
            if (parsed <= 0) { throw IllegalArgumentException("WIRESTACK_NET06_ITERATIONS must be positive") }
            parsed
        case None => 3
    }
}

private func net06TlsHeapSample(index: Int64): Unit {
    gc(heavy: true)
    println("NET06_HEAP scenario=tls-transport-cleanup index=${index} usedHeapBytes=${getUsedHeapSize()}")
}

@Test
class Net06TlsTransportCleanupGateTest {
    @TestCase
    func failedHandshakesDisposeEngineAndTransportExactlyOnce(): Unit {
        let requested = net06TlsCleanupIterations()
        let checkpointEvery = if (requested < 20) { requested } else { requested / 20 }
        var completed: Int64 = 0
        var engineClosed: Int64 = 0
        var transportAborted: Int64 = 0
        var terminalDisposals: Int64 = 0
        net06TlsHeapSample(0)
        for (index in 0..requested) {
            let engine = LifecycleEngine(failHandshake: true)
            let transport = LifecycleTransport()
            var failed = false
            try {
                let _ = TlsConnection.handshake(engine, transport)
            } catch (_: TlsEngineException) {
                failed = true
            }
            if (!failed || engine.closeCalls.load() != 1 ||
                transport.abortCalls.load() != 1 || transport.closeCalls.load() != 0 ||
                transport.terminalDisposals.load() != 1) {
                throw Exception("NET06 TLS failure did not clean up exactly once")
            }
            completed += 1
            engineClosed += engine.closeCalls.load()
            transportAborted += transport.abortCalls.load()
            terminalDisposals += transport.terminalDisposals.load()
            let observed = index + 1
            if (observed % checkpointEvery == 0 || observed == requested) {
                net06TlsHeapSample(observed)
            }
        }
        println(
            "NET06_TLS_TRANSPORT requested=${requested} completed=${completed} " +
            "engineClosed=${engineClosed} transportAborted=${transportAborted} " +
            "terminalDisposals=${terminalDisposals} backgroundTasks=0"
        )
        @Assert(completed, requested)
        @Assert(engineClosed, requested)
        @Assert(transportAborted, requested)
        @Assert(terminalDisposals, requested)
    }
}

private class LifecycleEngine <: TlsEngine {
    private let failHandshake: Bool
    private let failRead: Bool
    private let blockRead: Bool
    private let readNeedsTransport: Bool
    private let peerClosedRead: Bool
    private let shutdownNeedsPeer: Bool
    private let entered: ?SyncCounter
    private let readMutex = Mutex()
    private let readChanged = synchronized(readMutex) { readMutex.condition() }
    private var readReleased = false
    private var closeNotifyPending = false
    private var peerCloseReceived = false
    let closeCalls = AtomicInt64(0)
    let writtenBytes = AtomicInt64(0)
    let shutdownCalls = AtomicInt64(0)

    init(
        failHandshake!: Bool = false,
        failRead!: Bool = false,
        blockRead!: Bool = false,
        readNeedsTransport!: Bool = false,
        peerClosedRead!: Bool = false,
        shutdownNeedsPeer!: Bool = false,
        entered!: ?SyncCounter = None<SyncCounter>
    ) {
        this.failHandshake = failHandshake
        this.failRead = failRead
        this.blockRead = blockRead
        this.readNeedsTransport = readNeedsTransport
        this.peerClosedRead = peerClosedRead
        this.shutdownNeedsPeer = shutdownNeedsPeer
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

    public func pendingCiphertext(): Int64 { if (closeNotifyPending) { 1 } else { 0 } }
    public func drainCiphertext(destination: MutableByteSpan): Int64 {
        if (!closeNotifyPending || destination.isEmpty()) { return 0 }
        destination.bytes[destination.offset] = 21
        closeNotifyPending = false
        1
    }
    public func feedCiphertext(source: ByteSpan): Int64 {
        if (!source.isEmpty()) { peerCloseReceived = true }
        source.length
    }

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
        if (peerClosedRead) { return TlsEngineReadResult.PeerClosed }
        if (readNeedsTransport) { return TlsEngineReadResult.WantRead }
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

    public func shutdownStep(): TlsEngineShutdownResult {
        shutdownCalls.fetchAdd(1)
        if (!shutdownNeedsPeer || peerCloseReceived) {
            return TlsEngineShutdownResult.Complete
        }
        if (shutdownCalls.load() == 1) {
            closeNotifyPending = true
            return TlsEngineShutdownResult.Sent
        }
        TlsEngineShutdownResult.WantRead
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
    private let respondToTlsClose: Bool
    let readCalls = AtomicInt64(0)
    let writeCalls = AtomicInt64(0)
    let closeCalls = AtomicInt64(0)
    let abortCalls = AtomicInt64(0)
    let terminalDisposals = AtomicInt64(0)
    private let disposed = AtomicBool(false)

    init(respondToTlsClose!: Bool = false) {
        this.respondToTlsClose = respondToTlsClose
    }

    public prop info: TransportInfo {
        get() { TransportInfo("lifecycle-test", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        readCalls.fetchAdd(1)
        if (respondToTlsClose) {
            destination.bytes[destination.offset] = 21
            ReadResult.Data(1)
        } else {
            ReadResult.EndOfStream
        }
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
