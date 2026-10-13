package wirestack.internal.http1

import std.sync.AtomicInt64
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.ReferenceIdentity
import wirestack.internal.common.*
import wirestack.internal.http_model.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class Http1LiteralProxyDialDeadlineReviewTest {
    @TestCase
    func forwardProxyLiteralDialUsesTcpConnectBudget(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let clock = ProxyReviewManualClock()
        let factory = ProxyReviewDialTransportFactory(clock)
        let client = Http1ForwardProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"), resolver, factory
        )
        let cap = 50 * Duration.millisecond
        let context = OperationContext(
            deadline: Some(Deadline.after(2 * Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(cap))
        )
        var timedOut = false
        try {
            let _ = client.execute(HttpRequest.get("http://origin.test/path"), context: context)
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.TimedOut =>
                    match (error.phase) {
                        case api.NetworkPhase.TcpConnect => timedOut = true
                        case _ => ()
                    }
                case _ => ()
            }
        } finally {
            client.close()
        }
        @Expect(timedOut)
        @Expect(factory.calls, 1)
        @Expect(factory.deadlineExpired, true)
        match (factory.deadlineRemaining) {
            case Some(remaining) =>
                @Expect(remaining > Duration.Zero)
                @Expect(remaining <= cap)
            case None => @Fail("literal proxy dial did not use the TcpConnect deadline")
        }
    }

    @TestCase
    func forwardProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let factory = ProxyReviewDialTransportFactory(ProxyReviewManualClock(), advanceClock: false)
        let client = Http1ForwardProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"), resolver, factory
        )
        let cap = 50 * Duration.millisecond
        let context = OperationContext(
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(cap))
        )
        @Expect(context.deadline.isNone())
        var dialRejected = false
        try {
            let _ = client.execute(HttpRequest.get("http://origin.test/path"), context: context)
        } catch (_: IllegalStateException) {
            dialRejected = true
        } finally {
            client.close()
        }
        @Expect(dialRejected)
        @Expect(factory.calls, 1)
        @Expect(!factory.deadlineExpired)
        match (factory.deadlineRemaining) {
            case Some(remaining) =>
                @Expect(remaining > Duration.Zero)
                @Expect(remaining <= cap)
            case None => @Fail("literal forward-proxy dial did not derive TcpConnect deadline")
        }
    }

    @TestCase
    func httpsProxyLiteralDialAppliesTcpConnectCapWithoutCallerDeadline(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let factory = ProxyReviewDialTransportFactory(ProxyReviewManualClock(), advanceClock: false)
        let handshaker = ProxyReviewPassthroughHandshaker()
        let client = Http1HttpsProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"),
            resolver, factory, handshaker
        )
        let cap = 50 * Duration.millisecond
        let context = OperationContext(
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(cap))
        )
        @Expect(context.deadline.isNone())
        var dialRejected = false
        try {
            let _ = client.execute(HttpRequest.get("https://origin.test/path"), context: context)
        } catch (_: IllegalStateException) {
            dialRejected = true
        } finally {
            client.close()
        }
        @Expect(dialRejected)
        @Expect(factory.calls, 1)
        @Expect(!factory.deadlineExpired)
        @Expect(handshaker.handshakeCount, 0)
        match (factory.deadlineRemaining) {
            case Some(remaining) =>
                @Expect(remaining > Duration.Zero)
                @Expect(remaining <= cap)
            case None => @Fail("literal HTTPS-proxy dial did not derive TcpConnect deadline")
        }
    }
}

@Test
class Http1HttpsProxyDialCapReviewTest {
    @TestCase
    func httpsLiteralProxyDialTimesOutAtTcpConnectCap(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let clock = ProxyReviewManualClock()
        let factory = ProxyReviewDialTransportFactory(clock)
        let handshaker = ProxyReviewPassthroughHandshaker()
        let client = Http1HttpsProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"),
            resolver, factory, handshaker
        )
        let cap = 50 * Duration.millisecond
        let context = OperationContext(
            deadline: Some(Deadline.after(2 * Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(cap))
        )
        try {
            let error = @AssertThrows[api.NetworkException](
                client.execute(HttpRequest.get("https://origin.test/path"), context: context)
            )
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => @Fail("HTTPS literal proxy dial did not enforce the TCP connect cap")
            }
            match (error.phase) {
                case api.NetworkPhase.TcpConnect => ()
                case _ => @Fail("HTTPS literal proxy timeout lost its TCP connect phase")
            }
            @Expect(factory.calls, 1)
            @Expect(factory.deadlineExpired, true)
            @Expect(handshaker.handshakeCount, 0)
            match (factory.deadlineRemaining) {
                case Some(remaining) =>
                    @Expect(remaining > Duration.Zero)
                    @Expect(remaining <= cap)
                case None => @Fail("HTTPS literal proxy dial did not carry the TCP connect deadline")
            }
        } finally {
            client.close()
        }
    }
}

private class ProxyReviewManualClock <: MonotonicClock {
    private var current = MonoTime.now()
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

private class ProxyReviewDialTransportFactory <: TransportFactory {
    private let clock: ProxyReviewManualClock
    private let advanceClock: Bool
    private var connectCalls: Int64 = 0
    private var capturedDeadlineRemaining = None<Duration>
    private var didExpireDeadline = false

    init(clock: ProxyReviewManualClock, advanceClock!: Bool = true) {
        this.clock = clock
        this.advanceClock = advanceClock
    }

    prop calls: Int64 { get() { connectCalls } }
    prop deadlineRemaining: ?Duration { get() { capturedDeadlineRemaining } }
    prop deadlineExpired: Bool { get() { didExpireDeadline } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        connectCalls++
        match (context.deadline) {
            case Some(deadline) => capturedDeadlineRemaining = Some(deadline.remaining())
            case None => ()
        }
        if (advanceClock) { clock.advance(51 * Duration.millisecond) }
        didExpireDeadline = context.isDeadlineExceeded()
        if (didExpireDeadline) {
            throw api.NetworkException(
                api.NetworkErrorCategory.DeadlineExceeded,
                api.NetworkPhase.TcpConnect,
                api.NetworkErrorCode.TimedOut,
                "proxy TCP connect deadline expired"
            )
        }
        throw IllegalStateException("expected proxy dial failure")
    }
}

private class ProxyReviewPassthroughHandshaker <: Http1TlsHandshaker {
    private let handshakes = AtomicInt64(0)
    private var closed = false
    prop handshakeCount: Int64 { get() { handshakes.load() } }
    public prop tlsContextIdentity: String { get() { "proxy-review-tls" } }
    public prop trustContextIdentity: String { get() { "proxy-review-trust" } }
    public prop clientIdentity: String { get() { "none" } }
    public prop providerIdentity: String { get() { "proxy-review-provider" } }
    public prop alpnPolicy: String { get() { "http/1.1" } }

    public func handshake(reference: ReferenceIdentity, transport: DuplexTransport,
        context: OperationContext): DuplexTransport {
        let _ = reference
        let _ = context
        handshakes.fetchAdd(1)
        transport
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}
