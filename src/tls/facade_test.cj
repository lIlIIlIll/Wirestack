package wirestack.tls

import std.unittest.*
import std.unittest.testmacro.*

@Test
class PublicTlsFacadeTest {
    @TestCase
    func clientBuilderRejectsReversedVersionRangeBeforeTransportIo(): Unit {
        @AssertThrows[TlsContextException](
            TlsClientContext.builder()
                .versions(TlsVersion.Tls13, TlsVersion.Tls12)
                .build()
        )
    }

    @TestCase
    func serverBuilderRequiresAnIdentityBeforeTransportIo(): Unit {
        @AssertThrows[TlsContextException](TlsServerContext.builder().build())
    }

    @TestCase
    func clientBuilderCopiesAlpnAndPublishesProviderNeutralCapabilities(): Unit {
        let protocols = ["h2", "http/1.1"]
        let context = TlsClientContext.builder().alpn(protocols).build()
        protocols[0] = "mutated"
        @Expect(context.alpnProtocols(), ["h2", "http/1.1"])
        @Expect(context.capabilities.supports(TlsCapability.Tls13))
        @Expect(context.capabilities.supports(TlsCapability.ServerMode))
    }

    @TestCase
    func preCancelledHandshakeConsumesAndAbortsTheTransport(): Unit {
        let source = CancellationSource()
        source.cancel()
        let transport = CountingTransport()
        let context = OperationContext(cancellation: source.token)
        @AssertThrows[NetworkException](
            TlsClientContext.builder().build().handshake(
                transport,
                HostName("example.com"),
                context: context
            )
        )
        @Expect(transport.abortCalls, 1)
        @Expect(transport.closeCalls, 0)
    }
}

private class CountingTransport <: DuplexTransport {
    var closeCalls: Int64 = 0
    var abortCalls: Int64 = 0
    private var closed = false

    public prop info: TransportInfo {
        get() { TransportInfo("public-tls-test", runtimeIoBackend: "deterministic") }
    }

    public func readSome(
        _: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        let _ = context
        ReadResult.EndOfStream
    }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        let _ = context
        source.length
    }

    public func shutdown(_: ShutdownDirection): Unit {}
    public func close(_: OperationContext): Unit { close() }
    public func close(): Unit {
        if (!closed) { closeCalls++; closed = true }
    }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit {
        let _ = reason
        if (!closed) { abortCalls++; closed = true }
    }
    public func isClosed(): Bool { closed }
}
