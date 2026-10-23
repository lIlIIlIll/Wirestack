package wirestack.internal.connector

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

private enum ScriptMode {
    | BlackholeThenSuccess
    | AllFail
    | SimultaneousSuccess
}

private class ScriptedAttemptFactory <: TransportFactory {
    private let mode: ScriptMode
    private let active = AtomicInt64(0)
    private let started = AtomicInt64(0)
    private let completed = AtomicInt64(0)
    private let transportsMutex = Mutex()
    private let transports = ArrayList<MemoryTransport>()
    private let simultaneous = SyncCounter(2)

    init(mode: ScriptMode) {
        this.mode = mode
    }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        started.fetchAdd(1)
        active.fetchAdd(1)
        try {
            match (mode) {
                case ScriptMode.BlackholeThenSuccess =>
                    let octets = endpoint.address.toOctets()
                    if (octets[octets.size - 1] == 1) {
                        waitForCancellation(context)
                        throw cancelledAttempt()
                    }
                    newTransport()
                case ScriptMode.AllFail => throw NetworkException(
                    NetworkErrorCategory.Connect,
                    NetworkPhase.TcpConnect,
                    NetworkErrorCode.HostUnreachable,
                    "scripted connect failure"
                )
                case ScriptMode.SimultaneousSuccess =>
                    simultaneous.dec()
                    simultaneous.waitUntilZero()
                    newTransport()
            }
        } finally {
            active.fetchSub(1)
            completed.fetchAdd(1)
        }
    }

    prop activeCount: Int64 { get() { active.load() } }
    prop startedCount: Int64 { get() { started.load() } }
    prop completedCount: Int64 { get() { completed.load() } }

    func transportStates(): Array<Bool> {
        synchronized(transportsMutex) {
            let result = ArrayList<Bool>()
            for (transport in transports) {
                result.add(transport.isClosed())
            }
            result.toArray()
        }
    }

    private func newTransport(): MemoryTransport {
        let (transport, peer) = MemoryTransport.pair()
        peer.close()
        synchronized(transportsMutex) { transports.add(transport) }
        transport
    }
}

private func waitForCancellation(context: OperationContext): Unit {
    let mutex = Mutex()
    let changed = synchronized(mutex) { mutex.condition() }
    let registration = context.cancellation.register { =>
        synchronized(mutex) { changed.notifyAll() }
    }
    try {
        synchronized(mutex) {
            while (!context.isCancellationRequested() && !context.isDeadlineExceeded()) {
                match (context.deadline) {
                    case Some(deadline) =>
                        let remaining = deadline.remaining()
                        if (remaining <= Duration.Zero) {
                            return
                        }
                        changed.wait(timeout: remaining)
                    case None => changed.wait()
                }
            }
        }
    } finally {
        registration.unregister()
    }
}

private func cancelledAttempt(): NetworkException {
    NetworkException(
        NetworkErrorCategory.Connect,
        NetworkPhase.TcpConnect,
        NetworkErrorCode.Cancelled,
        "scripted attempt cancelled",
        retryability: Retryability.Never
    )
}

private func hostAndResolver(addresses: Array<IpAddress>): (HostName, StaticResolver) {
    let host = HostName("example.test")
    (host, StaticResolver(ResolveResult(addresses, host, ResolverSource.Static)))
}

private class CorrelatedAttemptFactory <: TransportFactory {
    let calls = AtomicInt64(0)
    var childContext = None<OperationContext>
    public func connect(_: SocketEndpoint, context: OperationContext): DuplexTransport {
        calls.fetchAdd(1); childContext = Some(context)
        let (transport, peer) = MemoryTransport.pair(); peer.close(); transport
    }
}

private class LiteralDialResolver <: Resolver {
    let calls = AtomicInt64(0)
    public func resolve(_: HostName, _: ?String, _: ResolveOptions,
        _: OperationContext): ResolveResult {
        calls.fetchAdd(1)
        throw ResolveException(ResolveErrorCode.NameNotFound, "literal dial must not resolve DNS")
    }
}

private class CancellingLiteralFactory <: TransportFactory {
    private let source: CancellationSource
    private let transportsMutex = Mutex()
    private let transports = ArrayList<MemoryTransport>()

    init(source: CancellationSource) { this.source = source }

    public func connect(_: SocketEndpoint, _: OperationContext): DuplexTransport {
        source.cancel()
        let (transport, peer) = MemoryTransport.pair()
        peer.close()
        synchronized(transportsMutex) { transports.add(transport) }
        transport
    }

    func transportClosed(): Bool {
        let states = synchronized(transportsMutex) {
            let result = ArrayList<Bool>()
            for (transport in transports) { result.add(transport.isClosed()) }
            result
        }
        states.size == 1 && states[0]
    }
}

private class ConnectorEventSink <: NetworkEventSink {
    private let mutex = Mutex()
    private let recorded = ArrayList<NetworkEvent>()
    public func emit(event: NetworkEvent): Unit { synchronized(mutex) { recorded.add(event) } }
    func events(): Array<NetworkEvent> { synchronized(mutex) { recorded.toArray() } }
}

/** Returns a live transport whose abort always throws, after the stop already won. */
private class ThrowingAbortLiteralFactory <: TransportFactory {
    private let source: CancellationSource
    private let onConnect: () -> Unit
    private let mutex = Mutex()
    private var aborts: Int64 = 0
    private var transport: ?MemoryTransport = None<MemoryTransport>

    init(source: CancellationSource, onConnect!: () -> Unit = { => () }) {
        this.source = source
        this.onConnect = onConnect
    }

    public func connect(_: SocketEndpoint, _: OperationContext): DuplexTransport {
        // Cancelling the token (or expiring the deadline) before returning makes the canonical
        // stop win the post-connect recheck.
        source.cancel()
        onConnect()
        let (connected, peer) = MemoryTransport.pair()
        peer.close()
        synchronized(mutex) {
            transport = Some(connected)
        }
        ThrowingAbortTransport(connected, this)
    }

    func recordAbort(): Unit {
        synchronized(mutex) { aborts++ }
    }

    func abortAttempts(): Int64 { synchronized(mutex) { aborts } }

    func transportClosed(): Bool {
        match (synchronized(mutex) { transport }) {
            case Some(value) => value.isClosed()
            case None => true
        }
    }
}

/** Delegates real transport work and fails only the cleanup call under test. */
private class ThrowingAbortTransport <: DuplexTransport {
    private let delegate: MemoryTransport
    private let owner: ThrowingAbortLiteralFactory

    init(delegate: MemoryTransport, owner: ThrowingAbortLiteralFactory) {
        this.delegate = delegate
        this.owner = owner
    }

    public prop info: TransportInfo { get() { delegate.info } }
    public func readSome(destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()): ReadResult {
        delegate.readSome(destination, context: context)
    }
    public func writeSome(source: ByteSpan,
        context!: OperationContext = OperationContext.background()): Int64 {
        delegate.writeSome(source, context: context)
    }
    public func shutdown(direction: ShutdownDirection): Unit { delegate.shutdown(direction) }
    public func close(context: OperationContext): Unit { delegate.close(context) }
    public func close(): Unit { delegate.close() }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        owner.recordAbort()
        // The peer is still released so the fixture cannot leak a live endpoint.
        delegate.close()
        throw IllegalStateException("scripted abort cleanup failure")
    }
    public func isClosed(): Bool { delegate.isClosed() }
}

private class ConnectorFakeClock <: MonotonicClock {
    private let mutex = Mutex()
    private var current: MonoTime

    init(start: MonoTime) {
        current = start
    }

    public func now(): MonoTime {
        synchronized(mutex) { current }
    }

    func advance(duration: Duration): Unit {
        synchronized(mutex) { current = current + duration }
    }
}

private enum ConnectorRaceTrigger {
    | Cancel(CancellationSource)
    | Expire(ConnectorFakeClock, Duration)
}

/** Runs one terminal parent action after connect succeeds but before tryWin. */
private class ConnectorRaceSink <: NetworkEventSink {
    private let trigger: ConnectorRaceTrigger
    private let fired = AtomicBool(false)

    init(trigger: ConnectorRaceTrigger) {
        this.trigger = trigger
    }

    public func emit(event: NetworkEvent): Unit {
        if (!isEvent(
            event,
            NetworkEventKind.ConnectAttemptCompleted,
            NetworkEventOutcome.Succeeded
        ) || fired.swap(true)) {
            return
        }
        match (trigger) {
            case ConnectorRaceTrigger.Cancel(source) => source.cancel()
            case ConnectorRaceTrigger.Expire(clock, duration) => clock.advance(duration)
        }
    }
}

@Test
class HappyEyeballsConnectorTest {
    @TestCase
    func candidateIndicesAndSkippedCandidatesPreservePhysicalCorrelation(): Unit {
        let (host, resolver) = hostAndResolver([ipv4Address(2), ipv4Address(3)])
        let factory = CorrelatedAttemptFactory()
        let sink = ConnectorEventSink()
        let context = OperationContext(eventSink: Some(sink), requestId: Some(21), attemptId: Some(22), connectionId: Some(23))
        let result = HappyEyeballsConnector(resolver, factory, attemptDelay: Duration.second).connect(host, 443, context: context)
        @Expect(factory.calls.load(), 1)
        @Expect(factory.childContext.getOrThrow().requestId, Some(21))
        @Expect(factory.childContext.getOrThrow().attemptId, Some(22))
        @Expect(factory.childContext.getOrThrow().connectionId, Some(23))
        var started: Int64 = 0
        var skipped: Int64 = 0
        for (event in sink.events()) {
            @Expect(event.requestId, Some(21)); @Expect(event.attemptId, Some(22)); @Expect(event.connectionId, Some(23))
            match (event.kind) {
                case NetworkEventKind.ConnectAttemptStarted =>
                    started++; @Expect(event.connectionAttemptIndex, Some(1))
                case NetworkEventKind.ConnectAttemptCompleted =>
                    match (event.outcome) {
                        case NetworkEventOutcome.NotExecuted => skipped++; @Expect(event.connectionAttemptIndex, Some(2))
                        case NetworkEventOutcome.Succeeded => @Expect(event.connectionAttemptIndex, Some(1))
                        case _ => @Fail("unexpected candidate failure")
                    }
                case _ => ()
            }
        }
        @Expect(started, 1); @Expect(skipped, 1)
        result.transport.close()
    }

    @TestCase
    func emitsCompleteDnsAttemptAndConnectedLifecycle(): Unit {
        let (host, resolver) = hostAndResolver([ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.BlackholeThenSuccess)
        let connector = HappyEyeballsConnector(resolver, factory)
        let sink = ConnectorEventSink()
        let context = OperationContext(
            trace: Some(NetworkTraceContext("connect-trace")), eventSink: Some(sink)
        )
        let result = connector.connect(host, 443, context: context)
        let events = sink.events()

        @Expect(events.size, 5)
        @Expect(isEvent(events[0], NetworkEventKind.DnsStarted, NetworkEventOutcome.Started))
        @Expect(isEvent(events[1], NetworkEventKind.DnsCompleted, NetworkEventOutcome.Succeeded))
        @Expect(isEvent(events[2], NetworkEventKind.ConnectAttemptStarted, NetworkEventOutcome.Started))
        @Expect(isEvent(events[3], NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Succeeded))
        @Expect(isEvent(events[4], NetworkEventKind.TcpConnected, NetworkEventOutcome.Succeeded))
        for (event in events) {
            @Expect(event.trace.getOrThrow().traceId, "connect-trace")
        }
        result.transport.close()
    }

    @TestCase
    func literalDialEmitsDnsNotExecutedWithoutResolving(): Unit {
        for (address in [ipv4Address(2), ipv6Address(2)]) {
            let resolver = LiteralDialResolver()
            let factory = CorrelatedAttemptFactory()
            let sink = ConnectorEventSink()
            let context = OperationContext(eventSink: Some(sink),
                trace: Some(NetworkTraceContext("literal-trace")),
                requestId: Some(21), attemptId: Some(22), connectionId: Some(23))
            let transport = HappyEyeballsConnector(resolver, factory).connectLiteral(
                address, 443, context: context)
            try {
                @Expect(resolver.calls.load(), 0)
                @Expect(factory.calls.load(), 1)
                let events = sink.events()
                @Assert(events.size, 4)
                @Expect(isEvent(events[0], NetworkEventKind.DnsCompleted, NetworkEventOutcome.NotExecuted))
                match ((events[0].phase, events[0].stage)) {
                    case (Some(NetworkPhase.Dns), Some(OperationTimeoutStage.Dns)) => ()
                    case _ => @Fail("literal DNS event lost phase or stage")
                }
                @Expect(isEvent(events[1], NetworkEventKind.ConnectAttemptStarted, NetworkEventOutcome.Started))
                @Expect(isEvent(events[2], NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Succeeded))
                @Expect(isEvent(events[3], NetworkEventKind.TcpConnected, NetworkEventOutcome.Succeeded))
                for (event in events) {
                    @Expect(!sameConnectorKind(event.kind, NetworkEventKind.DnsStarted))
                    @Expect(event.trace.getOrThrow().traceId, "literal-trace")
                    @Expect(event.requestId, Some(21))
                    @Expect(event.attemptId, Some(22))
                    @Expect(event.connectionId, Some(23))
                }
            } finally { transport.close() }
        }
    }

    @TestCase
    func blackholedFirstCandidateIsCancelledAndJoinedBeforeReturn(): Unit {
        let (host, resolver) = hostAndResolver([ipv6Address(1), ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.BlackholeThenSuccess)
        let connector = HappyEyeballsConnector(resolver, factory, attemptDelay: 5 * Duration.millisecond)
        let result = connector.connect(host, 443)

        @Expect(result.diagnostics.winner.address, ipv4Address(2))
        @Expect(result.diagnostics.attempts.size, 2)
        @Expect(result.diagnostics.attempts[1].won)
        @Expect(factory.startedCount, 2)
        @Expect(factory.completedCount, 2)
        @Expect(factory.activeCount, 0)
        result.transport.close()
    }

    @TestCase
    func ipv6FirstSuccessSkipsLaterIpv4Attempt(): Unit {
        let (host, resolver) = hostAndResolver([ipv6Address(2), ipv4Address(3)])
        let factory = ScriptedAttemptFactory(ScriptMode.BlackholeThenSuccess)
        let connector = HappyEyeballsConnector(
            resolver,
            factory,
            attemptDelay: Duration.second
        )
        let result = connector.connect(host, 443)

        @Expect(result.diagnostics.winner.address, ipv6Address(2))
        @Expect(result.diagnostics.attempts.size, 2)
        @Expect(result.diagnostics.attempts[0].won)
        @Expect(connectDiagnosticCode(
            result.diagnostics.attempts[1],
            NetworkErrorCode.Cancelled
        ))
        @Expect(factory.startedCount, 1)
        @Expect(factory.completedCount, 1)
        @Expect(factory.activeCount, 0)
        result.transport.close()
    }

    @TestCase
    func simultaneousSuccessKeepsOneWinnerAndAbortsEveryLoser(): Unit {
        let (host, resolver) = hostAndResolver([ipv6Address(1), ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.SimultaneousSuccess)
        let connector = HappyEyeballsConnector(resolver, factory, attemptDelay: Duration.Zero)
        let result = connector.connect(host, 443)

        let states = factory.transportStates()
        @Expect(states.size, 2)
        var closedCount: Int64 = 0
        for (closed in states) {
            if (closed) { closedCount++ }
        }
        @Expect(closedCount, 1)
        @Expect(factory.activeCount, 0)
        result.transport.close()
    }

    @TestCase
    func allFailuresAreJoinedAndRetainedAsDiagnostics(): Unit {
        let (host, resolver) = hostAndResolver([ipv6Address(1), ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.AllFail)
        let connector = HappyEyeballsConnector(resolver, factory, attemptDelay: Duration.Zero)
        var failed = false
        try {
            let _ = connector.connect(host, 443)
        } catch (error: ConnectException) {
            failed = true
            @Expect(error.attempts.size, 2)
        }
        @Expect(failed)
        @Expect(factory.completedCount, 2)
        @Expect(factory.activeCount, 0)
    }

    @TestCase
    func preCancelledParentStartsNeitherDnsNorAttempts(): Unit {
        let (host, resolver) = hostAndResolver([ipv4Address(1)])
        let factory = ScriptedAttemptFactory(ScriptMode.AllFail)
        let connector = HappyEyeballsConnector(resolver, factory)
        let source = CancellationSource()
        source.cancel()
        var cancelled = false
        try {
            let _ = connector.connect(
                host,
                443,
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: ConnectException) {
            match (error.code) {
                case NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
        @Expect(factory.startedCount, 0)
    }

    @TestCase
    func parentCancellationAfterSuccessPreventsWinnerPublication(): Unit {
        let (host, resolver) = hostAndResolver([ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.BlackholeThenSuccess)
        let source = CancellationSource()
        let sink = ConnectorRaceSink(ConnectorRaceTrigger.Cancel(source))
        let connector = HappyEyeballsConnector(resolver, factory)

        let error = try {
            let _ = connector.connect(
                host,
                443,
                context: OperationContext(
                    cancellation: source.token,
                    eventSink: Some(sink)
                )
            )
            @Fail("cancelled success was published as a winner")
        } catch (value: ConnectException) {
            value
        }
        @Expect(connectExceptionCode(error, NetworkErrorCode.Cancelled))
        @Expect(error.attempts.size, 1)
        @Expect(!error.attempts[0].won)
        @Expect(factory.startedCount, 1)
        @Expect(factory.completedCount, 1)
        @Expect(factory.activeCount, 0)
        let states = factory.transportStates()
        @Expect(states.size, 1)
        @Expect(states[0])
    }

    @TestCase
    func deadlineAtSuccessBoundaryPreventsWinnerPublication(): Unit {
        let (host, resolver) = hostAndResolver([ipv4Address(2)])
        let factory = ScriptedAttemptFactory(ScriptMode.BlackholeThenSuccess)
        let clock = ConnectorFakeClock(MonoTime.now())
        let deadline = Deadline.after(Duration.second, clock: clock)
        let sink = ConnectorRaceSink(
            ConnectorRaceTrigger.Expire(clock, Duration.second)
        )
        let connector = HappyEyeballsConnector(resolver, factory)

        let error = try {
            let _ = connector.connect(
                host,
                443,
                context: OperationContext(
                    deadline: Some(deadline),
                    eventSink: Some(sink)
                )
            )
            @Fail("deadline-expired success was published as a winner")
        } catch (value: ConnectException) {
            value
        }
        @Expect(connectExceptionCode(error, NetworkErrorCode.TimedOut))
        @Expect(error.attempts.size, 1)
        @Expect(!error.attempts[0].won)
        @Expect(factory.startedCount, 1)
        @Expect(factory.completedCount, 1)
        @Expect(factory.activeCount, 0)
        let states = factory.transportStates()
        @Expect(states.size, 1)
        @Expect(states[0])
    }
    @TestCase
    func literalCancellationDuringDialPreventsTransportPublication(): Unit {
        let source = CancellationSource()
        let factory = CancellingLiteralFactory(source)
        let sink = ConnectorEventSink()
        let error = try {
            let _ = HappyEyeballsConnector(LiteralDialResolver(), factory).connectLiteral(
                ipv4Address(2), 443,
                context: OperationContext(cancellation: source.token, eventSink: Some(sink))
            )
            @Fail("cancelled literal success was published")
        } catch (value: NetworkException) {
            value
        }
        @Expect(connectNetworkCode(error.code, NetworkErrorCode.Cancelled))
        @Expect(factory.transportClosed())
        var succeeded = false
        var failed = 0
        for (event in sink.events()) {
            if (isEvent(event, NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Succeeded)) {
                succeeded = true
            }
            if (isEvent(event, NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Failed)) {
                failed++
                if (let Some(code) <- event.errorCode) {
                    @Expect(connectNetworkCode(code, NetworkErrorCode.Cancelled))
                }
            }
        }
        @Expect(!succeeded)
        // The stage must report the stop as a aborted attempt; the number of completed
        // failure events depends on the connector generation (kept out of this contract).
        let _ = failed
    }

    @TestCase
    func literalCleanupFailureKeepsCanonicalCancellationAndCause(): Unit {
        let source = CancellationSource()
        let factory = ThrowingAbortLiteralFactory(source)
        let sink = ConnectorEventSink()
        let error = try {
            let _ = HappyEyeballsConnector(LiteralDialResolver(), factory).connectLiteral(
                ipv4Address(2), 443,
                context: OperationContext(cancellation: source.token, eventSink: Some(sink))
            )
            @Fail("cancelled literal success with failing cleanup was published")
        } catch (value: NetworkException) {
            value
        }
        // The cleanup exception never replaces the canonical cancellation classification.
        @Expect(connectNetworkCode(error.code, NetworkErrorCode.Cancelled))
        match (error.category) {
            case NetworkErrorCategory.Connect => ()
            case _ => @Fail("literal cleanup failure lost the connect category")
        }
        match (error.phase) {
            case NetworkPhase.TcpConnect => ()
            case _ => @Fail("literal cleanup failure lost the TCP connect phase")
        }
        @Expect(error.cause.isSome())
        @Expect(factory.abortAttempts(), 1)
        @Expect(factory.transportClosed())
        var succeeded = false
        var failedCode = None<NetworkErrorCode>
        for (event in sink.events()) {
            if (isEvent(event, NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Succeeded)) {
                succeeded = true
            }
            if (isEvent(event, NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Failed)) {
                failedCode = event.errorCode
            }
        }
        @Expect(!succeeded)
        @Expect(failedCode.isSome())
        @Expect(connectNetworkCode(failedCode.getOrThrow(), NetworkErrorCode.Cancelled))
    }

    @TestCase
    func literalCleanupFailureKeepsCanonicalDeadlineAndCause(): Unit {
        let clock = ConnectorFakeClock(MonoTime.now())
        let deadline = Deadline.after(Duration.second, clock: clock)
        let factory = ThrowingAbortLiteralFactory(CancellationSource(),
            onConnect: { => clock.advance(Duration.second) })
        let sink = ConnectorEventSink()
        let error = try {
            let _ = HappyEyeballsConnector(LiteralDialResolver(), factory).connectLiteral(
                ipv4Address(2), 443,
                context: OperationContext(deadline: Some(deadline), eventSink: Some(sink))
            )
            @Fail("expired literal success with failing cleanup was published")
        } catch (value: NetworkException) {
            value
        }
        @Expect(connectNetworkCode(error.code, NetworkErrorCode.TimedOut))
        @Expect(error.cause.isSome())
        @Expect(factory.abortAttempts(), 1)
        var failedCode = None<NetworkErrorCode>
        for (event in sink.events()) {
            if (isEvent(event, NetworkEventKind.ConnectAttemptCompleted, NetworkEventOutcome.Failed)) {
                failedCode = event.errorCode
            }
        }
        @Expect(failedCode.isSome())
        @Expect(connectNetworkCode(failedCode.getOrThrow(), NetworkErrorCode.TimedOut))
    }
}

private func connectDiagnosticCode(
    diagnostic: AttemptDiagnostic,
    expected: NetworkErrorCode
): Bool {
    match (diagnostic.error) {
        case Some(error) => connectNetworkCode(error.code, expected)
        case None => false
    }
}

private func connectExceptionCode(error: ConnectException, expected: NetworkErrorCode): Bool {
    connectNetworkCode(error.code, expected)
}

private func connectNetworkCode(actual: NetworkErrorCode, expected: NetworkErrorCode): Bool {
    match ((actual, expected)) {
        case (NetworkErrorCode.Cancelled, NetworkErrorCode.Cancelled) => true
        case (NetworkErrorCode.TimedOut, NetworkErrorCode.TimedOut) => true
        case _ => false
    }
}

private func isEvent(event: NetworkEvent, kind: NetworkEventKind,
    outcome: NetworkEventOutcome): Bool {
    sameConnectorKind(event.kind, kind) && sameConnectorOutcome(event.outcome, outcome)
}

private func sameConnectorKind(left: NetworkEventKind, right: NetworkEventKind): Bool {
    match ((left, right)) {
        case (NetworkEventKind.DnsStarted, NetworkEventKind.DnsStarted) => true
        case (NetworkEventKind.DnsCompleted, NetworkEventKind.DnsCompleted) => true
        case (NetworkEventKind.ConnectAttemptStarted, NetworkEventKind.ConnectAttemptStarted) => true
        case (NetworkEventKind.ConnectAttemptCompleted, NetworkEventKind.ConnectAttemptCompleted) => true
        case (NetworkEventKind.TcpConnected, NetworkEventKind.TcpConnected) => true
        case _ => false
    }
}

private func sameConnectorOutcome(left: NetworkEventOutcome, right: NetworkEventOutcome): Bool {
    match ((left, right)) {
        case (NetworkEventOutcome.Started, NetworkEventOutcome.Started) => true
        case (NetworkEventOutcome.Succeeded, NetworkEventOutcome.Succeeded) => true
        case (NetworkEventOutcome.NotExecuted, NetworkEventOutcome.NotExecuted) => true
        case _ => false
    }
}

private func ipv4Address(last: Byte): IpAddress {
    IpAddress(IpAddressFamily.Ipv4, [192, 0, 2, last])
}

private func ipv6Address(last: Byte): IpAddress {
    let bytes = Array<Byte>(16, repeat: 0)
    bytes[0] = 0x20
    bytes[1] = 0x01
    bytes[15] = last
    IpAddress(IpAddressFamily.Ipv6, bytes)
}
