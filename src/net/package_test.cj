package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class NetworkFoundationContractTest {
    @TestCase
    func unixEndpointFormsAreDistinctAndOwned(): Unit {
        let abstractBytes = [0u8, 0xFFu8, 0x01u8]
        let endpoint = UnixEndpoint.abstractName(abstractBytes)
        abstractBytes[1] = 0x02u8

        match (endpoint.kind) {
            case UnixEndpointKind.Abstract => ()
            case _ => @Fail("abstract endpoint kind was changed")
        }
        @Expect(endpoint.nameBytes(), [0u8, 0xFFu8, 0x01u8])
    }

    @TestCase
    func unixEndpointRejectsUnboundedNames(): Unit {
        var rejected = false
        try {
            let _ = UnixEndpoint.abstractName(Array<Byte>(108, repeat: 0u8))
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func rawSocketCapabilityBoundaryFailsClosedForEveryDomain(): Unit {
        for (domain in [
            RawSocketDomain.Ipv4,
            RawSocketDomain.Ipv6,
            RawSocketDomain.Packet,
            RawSocketDomain.Netlink
        ]) {
            expectUnsupportedRaw({ => let _ = RawSocket.open(domain) })
        }
    }

    @TestCase
    func dnsParserAcceptsTheRecordLimitBoundary(): Unit {
        let summary = DnsMessageParser().parse([
            0x12u8, 0x34u8, 0x82u8, 0u8,
            0u8, 0u8, 0x10u8, 0u8, 0u8, 0u8, 0u8, 0u8
        ])
        @Expect(summary.answerCount, 4096)
        @Expect(summary.truncated)
    }

    @TestCase
    func cancelledConnectFailsBeforeSocketCreation(): Unit {
        let source = api.CancellationSource()
        source.cancel()
        let loopback = api.IpAddress(
            api.IpAddressFamily.Ipv4,
            [127u8, 0u8, 0u8, 1u8]
        )
        var cancelled = false
        try {
            let _ = TcpStream.connect(
                api.SocketEndpoint(loopback, 1u16),
                context: api.OperationContext(cancellation: source.token)
            )
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
    }

    @TestCase
    func tcpStreamLifecycleDoesNotDependOnEndpointPresence(): Unit {
        let delegate = NetworkContractTransport(endpointsVisible: false)
        let stream = TcpStream(delegate)

        expectSocketState(stream.state, SocketState.Open)
        @Expect(!stream.isClosed())
        @Expect(stream.localEndpoint.isNone())
        @Expect(stream.remoteEndpoint.isNone())

        stream.close()
        stream.close(context: api.OperationContext.background())
        @Expect(stream.isClosed())
        expectSocketState(stream.state, SocketState.Closed)
    }

    @TestCase
    func tcpStreamAbortPreservesConnectionFacts(): Unit {
        let delegate = NetworkContractTransport()
        let stream = TcpStream(delegate)
        let expectedLocal = networkTestEndpoint(41001u16)
        let expectedRemote = networkTestEndpoint(41002u16)
        delegate.hideEndpoints()

        expectInternetEndpoint(stream.localEndpoint, expectedLocal)
        expectInternetEndpoint(stream.remoteEndpoint, expectedRemote)
        @Expect(stream.info.localEndpoint, Some(expectedLocal))
        @Expect(stream.info.remoteEndpoint, Some(expectedRemote))
        expectSocketState(stream.state, SocketState.Open)


        stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
        stream.abort()
        stream.close()
        expectSocketState(stream.state, SocketState.Closed)
    }


    @TestCase
    func unsafeOptionValueIsBoundedAndOwnedWithoutApplyingIt(): Unit {
        let source = [1u8, 2u8, 3u8]
        let option = UnsafeSocketOption(1, 2, api.ByteSpan(source))
        source[0] = 9u8
        let returned = option.value()
        returned[1] = 9u8
        @Expect(option.value(), [1u8, 2u8, 3u8])

        var oversizedRejected = false
        try {
            let _ = UnsafeSocketOption(
                1,
                2,
                api.ByteSpan(Array<Byte>(4097, repeat: 0u8))
            )
        } catch (_: IllegalArgumentException) {
            oversizedRejected = true
        }
        @Expect(oversizedRejected)
    }

    @TestCase
    func dnsHeaderRejectsStructuralAndRecordBounds(): Unit {
        let parser = DnsMessageParser()
        expectDnsRejected(parser, Array<Byte>(11, repeat: 0u8))

        let query = Array<Byte>(12, repeat: 0u8)
        expectDnsRejected(parser, query)

        let overRecordLimit = [
            0u8, 1u8, 0x80u8, 0u8,
            0u8, 0u8, 0x10u8, 0x01u8, 0u8, 0u8, 0u8, 0u8
        ]
        expectDnsRejected(parser, overRecordLimit)

        let oversized = Array<Byte>(65536, repeat: 0u8)
        oversized[2] = 0x80u8
        expectDnsRejected(parser, oversized)
    }

    @TestCase
    func dnsHeaderMutationsHaveOnlyBoundedSuccessOrStructuredRejection(): Unit {
        let parser = DnsMessageParser()
        let seed = [
            0x12u8, 0x34u8, 0x83u8, 0x80u8,
            0u8, 1u8, 0u8, 2u8, 0u8, 3u8, 0u8, 4u8
        ]
        var accepted: Int64 = 0
        var rejected: Int64 = 0

        for (length in 0..13) {
            if (exerciseDnsHeader(parser, copyDnsPrefix(seed, length))) {
                accepted++
            } else {
                rejected++
            }
        }
        for (index in 0..seed.size) {
            for (mask in [0x01u8, 0x20u8, 0x80u8, 0xFFu8]) {
                let mutated = seed.clone()
                mutated[index] = mutated[index] ^ mask
                if (exerciseDnsHeader(parser, mutated)) {
                    accepted++
                } else {
                    rejected++
                }
            }
        }
        let pattern = [0x00u8, 0x01u8, 0x20u8, 0x7Fu8, 0x80u8, 0xFFu8]
        for (length in 0..65) {
            let generated = Array<Byte>(length, repeat: 0u8)
            for (index in 0..length) {
                generated[index] = pattern[(index + length) % pattern.size]
            }
            if (length > 2 && length % 2 == 0) {
                generated[2] = generated[2] | 0x80u8
            }
            if (exerciseDnsHeader(parser, generated)) {
                accepted++
            } else {
                rejected++
            }
        }

        @Expect(accepted > 0)
        @Expect(rejected > 0)
    }
}

private class NetworkContractTransport <: api.DuplexTransport {
    private var endpointsVisible: Bool
    private var closed = false
    public var readCalls: Int64 = 0
    public var writeCalls: Int64 = 0
    public var closeCalls: Int64 = 0
    public var abortCalls: Int64 = 0

    init(endpointsVisible!: Bool = true) {
        this.endpointsVisible = endpointsVisible
    }

    public prop info: api.TransportInfo {
        get() {
            if (endpointsVisible) {
                api.TransportInfo(
                    "network-contract-test",
                    runtimeIoBackend: "deterministic",
                    localEndpoint: Some(networkTestEndpoint(41001u16)),
                    remoteEndpoint: Some(networkTestEndpoint(41002u16)),
                    supportsHalfClose: false,
                    supportsAbort: true
                )
            } else {
                api.TransportInfo(
                    "network-contract-test",
                    runtimeIoBackend: "deterministic",
                    supportsHalfClose: false,
                    supportsAbort: true
                )
            }
        }
    }

    func hideEndpoints(): Unit { endpointsVisible = false }

    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        let _ = context
        rejectClosedTransport(closed, api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
        readCalls++
        if (destination.isEmpty()) {
            return api.ReadResult.Data(0)
        }
        destination.bytes[destination.offset] = 0xA5u8
        if (destination.length == 1) {
            return api.ReadResult.Data(1)
        }
        destination.bytes[destination.offset + 1] = 0x5Au8
        api.ReadResult.Data(2)
    }

    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        let _ = context
        rejectClosedTransport(closed, api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite)
        writeCalls++
        min(source.length, 2)
    }

    public func shutdown(direction: api.ShutdownDirection): Unit {
        let _ = direction
        rejectClosedTransport(closed, api.NetworkErrorCategory.Shutdown, api.NetworkPhase.TransportClose)
    }

    public func close(context: api.OperationContext): Unit {
        let _ = context
        close()
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            closeCalls++
        }
    }

    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        if (!closed) {
            closed = true
            abortCalls++
        }
    }

    public func isClosed(): Bool { closed }
}

private func networkTestEndpoint(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func expectSocketState(actual: SocketState, expected: SocketState): Unit {
    let matches = match ((actual, expected)) {
        case (SocketState.Created, SocketState.Created) => true
        case (SocketState.Connecting, SocketState.Connecting) => true
        case (SocketState.Listening, SocketState.Listening) => true
        case (SocketState.Open, SocketState.Open) => true
        case (SocketState.Closing, SocketState.Closing) => true
        case (SocketState.Closed, SocketState.Closed) => true
        case _ => false
    }
    @Expect(matches)
}

private func expectInternetEndpoint(
    actual: ?NetworkEndpoint,
    expected: api.SocketEndpoint
): Unit {
    match (actual) {
        case Some(NetworkEndpoint.Internet(endpoint)) => @Expect(endpoint, expected)
        case _ => @Fail("expected an Internet endpoint")
    }
}

private func expectUnsupportedRaw(action: () -> Unit): Unit {
    var rejected = false
    try {
        action()
    } catch (error: api.NetworkException) {
        rejected = isUnsupportedRawError(error)
    }
    @Expect(rejected)
}

private func isUnsupportedRawError(error: api.NetworkException): Bool {
    let categoryMatches = match (error.category) {
        case api.NetworkErrorCategory.Unsupported => true
        case _ => false
    }
    let phaseMatches = match (error.phase) {
        case api.NetworkPhase.RawSocket => true
        case _ => false
    }
    let codeMatches = match (error.code) {
        case api.NetworkErrorCode.Unsupported => true
        case _ => false
    }
    let retryMatches = match (error.retryability) {
        case api.Retryability.Never => true
        case _ => false
    }
    categoryMatches && phaseMatches && codeMatches && retryMatches
}

private func rejectClosedTransport(
    closed: Bool,
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase
): Unit {
    if (closed) {
        throw api.NetworkException(
            category,
            phase,
            api.NetworkErrorCode.Closed,
            "test transport is closed",
            retryability: api.Retryability.Never
        )
    }
}

private func expectDnsRejected(parser: DnsMessageParser, input: Array<Byte>): Unit {
    var rejected = false
    try {
        let _ = parser.parse(input)
    } catch (error: api.ResolveException) {
        rejected = isDnsHeaderRejection(error)
    }
    @Expect(rejected)
}

private func exerciseDnsHeader(parser: DnsMessageParser, input: Array<Byte>): Bool {
    try {
        let summary = parser.parse(input)
        @Assert(input.size >= 12 && input.size <= 65535)
        @Assert((input[2] & 0x80u8) != 0u8)
        let totalRecords =
            dnsTestUInt16(input, 4) + dnsTestUInt16(input, 6) +
            dnsTestUInt16(input, 8) + dnsTestUInt16(input, 10)
        @Assert(totalRecords <= 4096)
        @Assert(summary.answerCount >= 0 && summary.answerCount <= totalRecords)
        true
    } catch (error: api.ResolveException) {
        @Assert(isDnsHeaderRejection(error))
        false
    }
}

private func isDnsHeaderRejection(error: api.ResolveException): Bool {
    let resolveCodeMatches = match (error.resolveCode) {
        case api.ResolveErrorCode.SystemFailure => true
        case _ => false
    }
    let categoryMatches = match (error.category) {
        case api.NetworkErrorCategory.Resolve => true
        case _ => false
    }
    let phaseMatches = match (error.phase) {
        case api.NetworkPhase.Dns => true
        case _ => false
    }
    let codeMatches = match (error.code) {
        case api.NetworkErrorCode.SystemFailure => true
        case _ => false
    }
    resolveCodeMatches && categoryMatches && phaseMatches && codeMatches
}

private func dnsTestUInt16(input: Array<Byte>, offset: Int64): Int64 {
    (Int64(input[offset]) << 8) | Int64(input[offset + 1])
}

private func copyDnsPrefix(input: Array<Byte>, length: Int64): Array<Byte> {
    let copy = Array<Byte>(length, repeat: 0u8)
    for (index in 0..length) {
        copy[index] = input[index]
    }
    copy
}
