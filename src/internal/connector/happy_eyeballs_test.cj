package wirestack.internal.connector

import std.collection.ArrayList
import std.sync.*
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

private class ConnectorEventSink <: NetworkEventSink {
    private let mutex = Mutex()
    private let recorded = ArrayList<NetworkEvent>()
    public func emit(event: NetworkEvent): Unit { synchronized(mutex) { recorded.add(event) } }
    func events(): Array<NetworkEvent> { synchronized(mutex) { recorded.toArray() } }
}

@Test
class HappyEyeballsConnectorTest {
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
