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

@Test
class Http1LiteralProxyLateSuccessReviewTest {
    @TestCase
    func lateLiteralProxyDialIsRejectedBeforeRequestAndSuccessEvent(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let clock = ProxyReviewManualClock()
        let factory = ProxyReviewDialTransportFactory(clock, lateSuccess: true, abortThrows: true)
        let events = ProxyReviewEventSink()
        let client = Http1ForwardProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"), resolver, factory
        )
        let cap = 50 * Duration.millisecond
        let context = OperationContext(
            deadline: Some(Deadline.after(2 * Duration.second, clock: clock)),
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(cap)),
            eventSink: Some<api.NetworkEventSink>(events)
        )
        try {
            let error = @AssertThrows[api.NetworkException](client.execute(
                HttpRequest.get("http://origin.test/path"), context: context
            ))
            match (error.category) {
                case api.NetworkErrorCategory.DeadlineExceeded => ()
                case _ => @Fail("late proxy dial did not report a deadline error")
            }
            match (error.code) {
                case api.NetworkErrorCode.TimedOut => ()
                case _ => @Fail("late proxy dial did not report a timeout code")
            }
            match (error.phase) {
                case api.NetworkPhase.TcpConnect => ()
                case _ => @Fail("late proxy dial lost its TCP-connect phase")
            }
            @Expect(factory.calls, 1)
            @Expect(factory.deadlineExpired, true)
            @Expect(factory.writeCalls, 0)
            @Expect(factory.abortCalls, 1)
            @Expect(events.successfulTcpConnected, 0)
        } finally {
            client.close()
        }
    }
    @TestCase
    func cancellationWhileLiteralProxyDialingIsPreservedIfAbortFails(): Unit {
        let proxyAddress = IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 9u8])
        let resolver = StaticResolver(ResolveResult(
            [proxyAddress], HostName("proxy.test"), ResolverSource.Static
        ))
        let clock = ProxyReviewManualClock()
        let cancellation = api.CancellationSource()
        let factory = ProxyReviewDialTransportFactory(
            clock,
            cancelDuringConnect: Some(cancellation),
            abortThrows: true
        )
        let events = ProxyReviewEventSink()
        let client = Http1ForwardProxyClient(
            Http1ProxyEndpoint.address(proxyAddress, 3128, "proxy.test:3128"), resolver, factory
        )
        let context = OperationContext(
            deadline: Some(Deadline.after(2 * Duration.second, clock: clock)),
            cancellation: cancellation.token,
            timeoutPolicy: OperationTimeoutPolicy(tcpConnect: Some(50 * Duration.millisecond)),
            eventSink: Some<api.NetworkEventSink>(events)
        )
        try {
            let error = @AssertThrows[api.NetworkException](client.execute(
                HttpRequest.get("http://origin.test/path"), context: context
            ))
            match (error.category) {
                case api.NetworkErrorCategory.Cancelled => ()
                case _ => @Fail("proxy dial cancellation was masked by transport cleanup")
            }
            match (error.code) {
                case api.NetworkErrorCode.Cancelled => ()
                case _ => @Fail("proxy dial cancellation lost its stable code")
            }
            match (error.phase) {
                case api.NetworkPhase.TcpConnect => ()
                case _ => @Fail("proxy dial cancellation lost its TCP-connect phase")
            }
            @Expect(factory.calls, 1)
            @Expect(!factory.deadlineExpired)
            @Expect(factory.writeCalls, 0)
            @Expect(factory.abortCalls, 1)
            @Expect(events.successfulTcpConnected, 0)
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
    private let lateSuccess: Bool
    private let cancelDuringConnect: ?api.CancellationSource
    private let abortThrows: Bool
    private let lateTransport: ProxyReviewLateResponseTransport
    private var connectCalls: Int64 = 0
    private var capturedDeadlineRemaining = None<Duration>
    private var didExpireDeadline = false

    init(
        clock: ProxyReviewManualClock,
        advanceClock!: Bool = true,
        lateSuccess!: Bool = false,
        cancelDuringConnect!: ?api.CancellationSource = None<api.CancellationSource>,
        abortThrows!: Bool = false
    ) {
        this.clock = clock
        this.advanceClock = advanceClock
        this.lateSuccess = lateSuccess
        this.cancelDuringConnect = cancelDuringConnect
        this.abortThrows = abortThrows
        lateTransport = ProxyReviewLateResponseTransport(abortThrows: abortThrows)
    }

    prop calls: Int64 { get() { connectCalls } }
    prop deadlineRemaining: ?Duration { get() { capturedDeadlineRemaining } }
    prop deadlineExpired: Bool { get() { didExpireDeadline } }
    prop writeCalls: Int64 { get() { lateTransport.writeCalls } }
    prop abortCalls: Int64 { get() { lateTransport.abortCalls } }

    public func connect(endpoint: SocketEndpoint, context: OperationContext): DuplexTransport {
        let _ = endpoint
        connectCalls++
        match (context.deadline) {
            case Some(deadline) => capturedDeadlineRemaining = Some(deadline.remaining())
            case None => ()
        }
        if (let Some(source) <- cancelDuringConnect) {
            source.cancel()
            didExpireDeadline = context.isDeadlineExceeded()
            return lateTransport
        }
        if (advanceClock) { clock.advance(51 * Duration.millisecond) }
        didExpireDeadline = context.isDeadlineExceeded()
        if (didExpireDeadline) {
            if (lateSuccess) { return lateTransport }
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

private class ProxyReviewLateResponseTransport <: DuplexTransport {
    private let responseWire: Array<Byte>
    private let writes = AtomicInt64(0)
    private let aborts = AtomicInt64(0)
    private var wireOffset: Int64 = 0

    private let abortThrows: Bool

    init(abortThrows!: Bool = false) {
        this.abortThrows = abortThrows
        responseWire = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".toArray()
    }

    prop writeCalls: Int64 { get() { writes.load() } }
    prop abortCalls: Int64 { get() { aborts.load() } }
    public prop info: TransportInfo { get() { TransportInfo("proxy-review-late-success-test") } }

    public func readSome(destination: MutableByteSpan, context!: OperationContext): ReadResult {
        let _ = context
        if (wireOffset == responseWire.size) { return ReadResult.EndOfStream }
        let count = min(destination.length, responseWire.size - wireOffset)
        for (index in 0..count) {
            destination.bytes[destination.offset + index] = responseWire[wireOffset + index]
        }
        wireOffset += count
        ReadResult.Data(count)
    }

    public func writeSome(source: ByteSpan, context!: OperationContext): Int64 {
        let _ = context
        writes.fetchAdd(1)
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(): Unit {}
    public func isClosed(): Bool { false }
    public func close(_: OperationContext): Unit {}
    public func abort(reason!: ?api.AbortReason): Unit {
        let _ = reason
        aborts.fetchAdd(1)
        if (abortThrows) { throw Exception("proxy transport abort failed") }
}
}

private class ProxyReviewEventSink <: api.NetworkEventSink {
    private let successfulTcpConnectedCount = AtomicInt64(0)
    prop successfulTcpConnected: Int64 { get() { successfulTcpConnectedCount.load() } }

    public func emit(event: api.NetworkEvent): Unit {
        match ((event.kind, event.outcome)) {
            case (api.NetworkEventKind.TcpConnected, api.NetworkEventOutcome.Succeeded) =>
                successfulTcpConnectedCount.fetchAdd(1)
            case _ => ()
        }
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
