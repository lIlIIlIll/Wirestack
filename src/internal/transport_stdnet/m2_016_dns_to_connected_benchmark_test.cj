package wirestack.internal.transport_stdnet

import std.convert.Parsable
import std.env.getVariable
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

private func m216Variable(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing M2-016 benchmark variable ${name}")
    }
}

private struct M216EventMetrics {
    let dnsNs: Int64
    let dnsCompletedNs: Int64
    let firstAttemptNs: Int64
    let winnerNs: Int64
    let connectionCount: Int64

    init(
        dnsNs: Int64,
        dnsCompletedNs: Int64,
        firstAttemptNs: Int64,
        winnerNs: Int64,
        connectionCount: Int64
    ) {
        this.dnsNs = dnsNs
        this.dnsCompletedNs = dnsCompletedNs
        this.firstAttemptNs = firstAttemptNs
        this.winnerNs = winnerNs
        this.connectionCount = connectionCount
    }
}

private class M216MetricSink <: NetworkEventSink {
    private let origin: MonoTime
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var dnsStartedNs: Int64 = -1
    private var dnsCompletedNs: Int64 = -1
    private var firstAttemptNs: Int64 = -1
    private var winnerNs: Int64 = -1
    private var connectionCount: Int64 = 0

    init(origin: MonoTime) {
        this.origin = origin
    }

    public func emit(event: NetworkEvent): Unit {
        let elapsed = (MonoTime.now() - origin).toNanoseconds()
        synchronized(mutex) {
            match (event.kind) {
                case NetworkEventKind.DnsStarted =>
                    if (dnsStartedNs < 0) { dnsStartedNs = elapsed }
                case NetworkEventKind.DnsCompleted =>
                    if (dnsCompletedNs < 0) { dnsCompletedNs = elapsed }
                case NetworkEventKind.ConnectAttemptStarted =>
                    connectionCount++
                    if (firstAttemptNs < 0) { firstAttemptNs = elapsed }
                    changed.notifyAll()
                case NetworkEventKind.TcpConnected =>
                    if (winnerNs < 0) { winnerNs = elapsed }
                case _ => ()
            }
        }
    }

    func waitForFirstAttempt(timeout: Duration): Bool {
        let expiresAt = MonoTime.now() + timeout
        synchronized(mutex) {
            while (firstAttemptNs < 0) {
                let remaining = expiresAt - MonoTime.now()
                if (remaining <= Duration.Zero) { return false }
                changed.wait(timeout: remaining)
            }
            true
        }
    }

    func snapshot(): M216EventMetrics {
        synchronized(mutex) {
            let dnsDuration = if (dnsStartedNs >= 0 && dnsCompletedNs >= dnsStartedNs) {
                dnsCompletedNs - dnsStartedNs
            } else {
                -1
            }
            M216EventMetrics(
                dnsDuration, dnsCompletedNs, firstAttemptNs, winnerNs, connectionCount
            )
        }
    }
}

private func m216SystemSource(source: ResolverSource): Bool {
    match (source) {
        case ResolverSource.System => true
        case _ => false
    }
}

private func m216Family(address: IpAddress, expected: IpAddressFamily): Bool {
    match ((address.family, expected)) {
        case (IpAddressFamily.Ipv4, IpAddressFamily.Ipv4) |
             (IpAddressFamily.Ipv6, IpAddressFamily.Ipv6) => true
        case _ => false
    }
}

private func m216Cancelled(code: NetworkErrorCode): Bool {
    match (code) {
        case NetworkErrorCode.Cancelled => true
        case _ => false
    }
}

private func m216SuccessProfile(
    profile: String,
    round: Int64,
    samples: Int64,
    port: UInt16,
    expectedFamily: IpAddressFamily,
    expectedConnections: Int64
): Unit {
    let resolver = SystemResolver(workerCount: 2, queueCapacity: 8)
    let connector = HappyEyeballsConnector(resolver, StdNetTransportFactory())
    let host = HostName("localhost")
    try {
        for (index in 0..samples) {
            let origin = MonoTime.now()
            let sink = M216MetricSink(origin)
            let result = connector.connect(
                host,
                port,
                context: OperationContext(
                    deadline: Some(Deadline.after(3 * Duration.second)),
                    eventSink: Some(sink)
                )
            )
            let totalNs = (MonoTime.now() - origin).toNanoseconds()
            let metrics = sink.snapshot()
            try {
                @Assert(m216SystemSource(result.diagnostics.dns.source))
                @Assert(m216Family(result.diagnostics.winner.address, expectedFamily))
                @Assert(metrics.dnsNs >= 0)
                @Assert(metrics.firstAttemptNs >= metrics.dnsCompletedNs)
                @Assert(metrics.winnerNs >= metrics.firstAttemptNs)
                @Assert(totalNs >= metrics.winnerNs)
                if (expectedConnections > 0) {
                    @Assert(metrics.connectionCount, expectedConnections)
                } else {
                    @Assert(metrics.connectionCount >= 1 && metrics.connectionCount <= 2)
                }
                println(
                    "M2016_SAMPLE profile=${profile} round=${round} index=${index} " +
                    "terminal=success source=system dnsNs=${metrics.dnsNs} " +
                    "firstAttemptNs=${metrics.firstAttemptNs} winnerNs=${metrics.winnerNs} " +
                    "totalNs=${totalNs} connectionCount=${metrics.connectionCount} " +
                    "cancellationNs=-1"
                )
            } finally {
                result.transport.close()
            }
        }
    } finally {
        resolver.close()
    }
}

private func m216CancellationProfile(
    profile: String,
    round: Int64,
    samples: Int64,
    port: UInt16
): Unit {
    let resolver = SystemResolver(workerCount: 2, queueCapacity: 8)
    let connector = HappyEyeballsConnector(
        resolver, StdNetTransportFactory(), attemptDelay: 250 * Duration.millisecond
    )
    let host = HostName("localhost")
    try {
        for (index in 0..samples) {
            let source = CancellationSource()
            let origin = MonoTime.now()
            let sink = M216MetricSink(origin)
            let connecting: Future<Bool> = spawn {
                try {
                    let result = connector.connect(
                        host,
                        port,
                        context: OperationContext(
                            deadline: Some(Deadline.after(3 * Duration.second)),
                            cancellation: source.token,
                            eventSink: Some(sink)
                        )
                    )
                    result.transport.close()
                    false
                } catch (error: ConnectException) {
                    m216Cancelled(error.code)
                }
            }
            @Assert(sink.waitForFirstAttempt(Duration.second))
            // The attempt event is emitted immediately before the transport
            // factory call. Keep the measured cancellation interval honest by
            // allowing the SYN to enter the namespace drop filter first.
            sleep(5 * Duration.millisecond)
            let cancelStarted = MonoTime.now()
            source.cancel()
            @Assert(connecting.get(Duration.second))
            let completedAt = MonoTime.now()
            let metrics = sink.snapshot()
            let totalNs = (completedAt - origin).toNanoseconds()
            let cancellationNs = (completedAt - cancelStarted).toNanoseconds()
            @Assert(metrics.dnsNs >= 0)
            @Assert(metrics.firstAttemptNs >= metrics.dnsCompletedNs)
            @Assert(metrics.winnerNs, -1)
            @Assert(metrics.connectionCount, 1)
            println(
                "M2016_SAMPLE profile=${profile} round=${round} index=${index} " +
                "terminal=cancelled source=system dnsNs=${metrics.dnsNs} " +
                "firstAttemptNs=${metrics.firstAttemptNs} winnerNs=-1 " +
                "totalNs=${totalNs} connectionCount=${metrics.connectionCount} " +
                "cancellationNs=${cancellationNs}"
            )
        }
    } finally {
        resolver.close()
    }
}

/** Machine-readable M2-016 native benchmark entrypoint. */
@Test
@Tag[Performance]
class M2016DnsToConnectedBenchmarkTest {
    @TestCase
    func runProfile(): Unit {
        let profile = m216Variable("WIRESTACK_M2_016_PROFILE")
        let round = Int64.parse(m216Variable("WIRESTACK_M2_016_ROUND"))
        let samples = Int64.parse(m216Variable("WIRESTACK_M2_016_SAMPLES"))
        let port = UInt16.parse(m216Variable("WIRESTACK_M2_016_PORT"))
        if (samples <= 0) {
            throw IllegalArgumentException("WIRESTACK_M2_016_SAMPLES must be positive")
        }
        match (profile) {
            case "ipv6-available" | "rtt-20ms" | "rtt-100ms" =>
                m216SuccessProfile(
                    profile, round, samples, port, IpAddressFamily.Ipv6, 1
                )
            case "loss-1pct" =>
                m216SuccessProfile(
                    profile, round, samples, port, IpAddressFamily.Ipv6, -1
                )
            case "ipv6-blackhole" =>
                m216SuccessProfile(
                    profile, round, samples, port, IpAddressFamily.Ipv4, 2
                )
            case "cancellation" =>
                m216CancellationProfile(profile, round, samples, port)
            case _ => throw IllegalArgumentException("unknown M2-016 profile ${profile}")
        }
    }
}
