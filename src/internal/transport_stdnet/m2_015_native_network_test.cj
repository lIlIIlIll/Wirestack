package wirestack.internal.transport_stdnet

import std.collection.ArrayList
import std.convert.Parsable
import std.env.getVariable
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

private func m215Variable(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing M2-015 gate variable ${name}")
    }
}

private func m215Ipv4(last: Byte): IpAddress {
    IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, last])
}

private func m215Ipv6(): IpAddress {
    IpAddress(
        IpAddressFamily.Ipv6,
        [32u8, 1u8, 13u8, 184u8, 0u8, 0u8, 0u8, 0u8,
         0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8]
    )
}

private func m215SameFamily(left: IpAddressFamily, right: IpAddressFamily): Bool {
    match ((left, right)) {
        case (IpAddressFamily.Ipv4, IpAddressFamily.Ipv4) |
             (IpAddressFamily.Ipv6, IpAddressFamily.Ipv6) => true
        case _ => false
    }
}

private func m215Cancelled(code: NetworkErrorCode): Bool {
    match (code) {
        case NetworkErrorCode.Cancelled => true
        case _ => false
    }
}

private func m215TimedOut(code: NetworkErrorCode): Bool {
    match (code) {
        case NetworkErrorCode.TimedOut => true
        case _ => false
    }
}

private func m215Success(
    scenario: String,
    addresses: Array<IpAddress>,
    expectedFamily: IpAddressFamily,
    expectedDiagnostics: Int64,
    expectedCancelledPerIteration: Int64,
    iterations: Int64,
    port: UInt16,
    attemptDelay: Duration
): Unit {
    let host = HostName("m2-015.test")
    let resolver = StaticResolver(ResolveResult(addresses, host, ResolverSource.Static))
    let connector = HappyEyeballsConnector(
        resolver, StdNetTransportFactory(), attemptDelay: attemptDelay
    )
    let startedAt = MonoTime.now()
    var winners: Int64 = 0
    var attempts: Int64 = 0
    var cancelledLosers: Int64 = 0
    for (_ in 0..iterations) {
        let context = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        let result = connector.connect(host, port, context: context)
        try {
            @Assert(m215SameFamily(result.diagnostics.winner.address.family, expectedFamily))
            @Assert(result.diagnostics.attempts.size, expectedDiagnostics)
            attempts += result.diagnostics.attempts.size
            var iterationWinners: Int64 = 0
            var iterationCancelled: Int64 = 0
            for (diagnostic in result.diagnostics.attempts) {
                if (diagnostic.won) {
                    iterationWinners++
                } else {
                    @Assert(diagnostic.error.isSome())
                    if (m215Cancelled(diagnostic.error.getOrThrow().code)) {
                        iterationCancelled++
                    }
                }
            }
            @Assert(iterationWinners, 1)
            @Assert(iterationCancelled, expectedCancelledPerIteration)
            cancelledLosers += iterationCancelled
            winners++
        } finally {
            result.transport.close()
        }
    }
    let elapsedMs = (MonoTime.now() - startedAt).toNanoseconds() / 1000000
    println(
        "M2015_RESULT scenario=${scenario} outcome=success winners=${winners} " +
        "attempts=${attempts} cancelledLosers=${cancelledLosers} elapsedMs=${elapsedMs}"
    )
    @Assert(winners, iterations)
}

private func m215Deadline(scenario: String, count: Int64, port: UInt16): Unit {
    let all = [
        m215Ipv4(10u8), m215Ipv4(11u8), m215Ipv4(12u8), m215Ipv4(13u8),
        m215Ipv4(14u8), m215Ipv4(15u8), m215Ipv4(16u8), m215Ipv4(17u8)
    ]
    let selected = ArrayList<IpAddress>()
    for (index in 0..count) {
        selected.add(all[index])
    }
    let host = HostName("m2-015-deadline.test")
    let resolver = StaticResolver(ResolveResult(selected.toArray(), host, ResolverSource.Static))
    let connector = HappyEyeballsConnector(
        resolver, StdNetTransportFactory(), attemptDelay: 20 * Duration.millisecond
    )
    let startedAt = MonoTime.now()
    var terminal = NetworkErrorCode.SystemFailure
    var attempts: Int64 = -1
    try {
        let result = connector.connect(
            host,
            port,
            context: OperationContext(deadline: Some(Deadline.after(350 * Duration.millisecond)))
        )
        result.transport.close()
        @Fail("blackholed candidates unexpectedly connected")
    } catch (error: ConnectException) {
        terminal = error.code
        attempts = error.attempts.size
    }
    let elapsedMs = (MonoTime.now() - startedAt).toNanoseconds() / 1000000
    println(
        "M2015_RESULT scenario=${scenario} outcome=deadline terminal=TimedOut " +
        "attempts=${attempts} elapsedMs=${elapsedMs}"
    )
    @Assert(m215TimedOut(terminal))
    @Assert(attempts, count)
}

/**
 * Native Linux M2-015 entrypoint. The Python gate owns the disposable network
 * namespace and impairments; this test owns production connector assertions.
 */
@Test
@Tag[Performance]
class M2015NativeNetworkGateTest {
    @TestCase
    func runProfile(): Unit {
        let scenario = m215Variable("WIRESTACK_M2_015_SCENARIO")
        let port = UInt16.parse(m215Variable("WIRESTACK_M2_015_PORT"))
        let iterations = Int64.parse(m215Variable("WIRESTACK_M2_015_ITERATIONS"))
        if (iterations <= 0) {
            throw IllegalArgumentException("WIRESTACK_M2_015_ITERATIONS must be positive")
        }
        match (scenario) {
            case "ipv6-available" | "rtt-20ms" | "rtt-100ms" =>
                m215Success(
                    scenario,
                    [m215Ipv6(), m215Ipv4(2u8)],
                    IpAddressFamily.Ipv6,
                    2,
                    1,
                    iterations,
                    port,
                    250 * Duration.millisecond
                )
            case "ipv6-blackhole" =>
                m215Success(
                    scenario,
                    [m215Ipv6(), m215Ipv4(2u8)],
                    IpAddressFamily.Ipv4,
                    2,
                    1,
                    iterations,
                    port,
                    30 * Duration.millisecond
                )
            case "loss-1pct" =>
                m215Success(
                    scenario,
                    [m215Ipv4(2u8)],
                    IpAddressFamily.Ipv4,
                    1,
                    0,
                    iterations,
                    port,
                    250 * Duration.millisecond
                )
            case "deadline-2" => m215Deadline(scenario, 2, port)
            case "deadline-8" => m215Deadline(scenario, 8, port)
            case _ => throw IllegalArgumentException("unknown M2-015 scenario ${scenario}")
        }
    }
}
