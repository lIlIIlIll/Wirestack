package wirestack.net

import std.unittest.*
import std.sync.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.{NetworkEndpoint, UnixEndpoint, UnixEndpointKind}

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
    func rawSocketCapabilityBoundaryRequiresDomainSpecificProtocol(): Unit {
        expectUnsupportedRaw({ =>
            let _ = RawSocket.open(RawSocketDomain.Ipv4, RawSocketProtocol.icmp())
        })
        expectUnsupportedRaw({ =>
            let _ = RawSocket.open(RawSocketDomain.Ipv6, RawSocketProtocol.icmpv6())
        })
        expectUnsupportedRaw({ =>
            let _ = RawSocket.open(RawSocketDomain.Packet, RawSocketProtocol(0))
        })
        expectUnsupportedRaw({ =>
            let _ = RawSocket.open(RawSocketDomain.Netlink, RawSocketProtocol(0))
        })
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
    func tcpStreamGracefulCloseIsRetainedAndIdempotent(): Unit {
        let delegate = NetworkContractTransport(endpointsVisible: false)
        let stream = TcpStream(delegate)

        expectSocketState(stream.state, SocketState.Open)
        @Expect(!stream.isClosed())
        @Expect(stream.localEndpoint.isNone())
        @Expect(stream.remoteEndpoint.isNone())

        stream.close()
        stream.close(context: api.OperationContext.background())
        stream.abort()
        @Expect(stream.isClosed())
        expectSocketState(stream.state, SocketState.Closed)
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 0)
    }

    @TestCase
    func tcpStreamAbortRetainsItsCauseAndConnectionFacts(): Unit {
        let delegate = NetworkContractTransport()
        let stream = TcpStream(delegate)
        let expectedLocal = networkTestEndpoint(41001u16)
        let expectedRemote = networkTestEndpoint(41002u16)
        delegate.hideEndpoints()

        expectInternetEndpoint(stream.localEndpoint, expectedLocal)
        expectInternetEndpoint(stream.remoteEndpoint, expectedRemote)
        @Expect(stream.info.localEndpoint, Some(expectedLocal))
        @Expect(stream.info.remoteEndpoint, Some(expectedRemote))

        stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
        stream.abort()
        stream.close()
        @Expect(stream.isClosed())
        expectSocketState(stream.state, SocketState.Aborted)
        @Expect(delegate.abortCalls, 1)
        @Expect(delegate.closeCalls, 0)
    }

    @TestCase
    func tcpStreamDirectionalShutdownPublishesOnlySuccessfulTransitions(): Unit {
        let readDelegate = NetworkContractTransport(supportsHalfClose: true)
        let readClosed = TcpStream(readDelegate)
        readClosed.shutdown(api.ShutdownDirection.Read)
        readClosed.shutdown(api.ShutdownDirection.Read)
        expectSocketState(readClosed.state, SocketState.ReadHalfClosed)
        @Expect(readDelegate.shutdownCalls, 1)
        @Expect(readClosed.write(api.ByteSpan([1u8]), context: api.OperationContext.background()), 1)

        let writeDelegate = NetworkContractTransport(supportsHalfClose: true)
        let writeClosed = TcpStream(writeDelegate)
        writeClosed.shutdown(api.ShutdownDirection.Write)
        expectSocketState(writeClosed.state, SocketState.WriteHalfClosed)
        let buffer = Array<Byte>(1, repeat: 0u8)
        match (writeClosed.read(api.MutableByteSpan(buffer), context: api.OperationContext.background())) {
            case ReadResult.Data(count) => @Expect(count, 1)
            case _ => @Fail("read direction was lost after write shutdown")
        }

        writeClosed.shutdown(api.ShutdownDirection.Read)
        expectSocketState(writeClosed.state, SocketState.Closed)
        @Expect(writeClosed.isClosed())

        let unsupportedDelegate = NetworkContractTransport()
        let unsupported = TcpStream(unsupportedDelegate)
        var rejected = false
        try {
            unsupported.shutdown(api.ShutdownDirection.Read)
        } catch (error: api.NetworkException) {
            rejected = isUnsupportedTransportError(error)
        }
        @Expect(rejected)
        expectSocketState(unsupported.state, SocketState.Open)
        @Expect(!unsupported.isClosed())
        @Expect(unsupportedDelegate.shutdownCalls, 1)
    }

    @TestCase
    func tcpStreamFailuresRetainOriginalErrorAndReleaseDelegate(): Unit {
        let readDelegate = NetworkContractTransport(failRead: true)
        let readStream = TcpStream(readDelegate)
        var readFailure = false
        try {
            let _ = readStream.read(
                api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                context: api.OperationContext.background()
            )
        } catch (error: api.NetworkException) {
            readFailure = isSystemFailure(error)
        }
        @Expect(readFailure)
        expectSocketState(readStream.state, SocketState.Failed)
        @Expect(readStream.isClosed())
        @Expect(readDelegate.abortCalls, 1)

        let writeDelegate = NetworkContractTransport(failWrite: true)
        let writeStream = TcpStream(writeDelegate)
        var writeFailure = false
        try {
            let _ = writeStream.write(
                api.ByteSpan([1u8]),
                context: api.OperationContext.background()
            )
        } catch (error: api.NetworkException) {
            writeFailure = isSystemFailure(error)
        }
        @Expect(writeFailure)
        expectSocketState(writeStream.state, SocketState.Failed)
        @Expect(writeStream.isClosed())
        @Expect(writeDelegate.abortCalls, 1)

        let closeDelegate = NetworkContractTransport(failClose: true)
        let closeStream = TcpStream(closeDelegate)
        var closeMessage = ""
        try {
            closeStream.close()
        } catch (error: Exception) {
            closeMessage = error.message
        }
        @Expect(closeMessage, "deterministic close failure")
        expectSocketState(closeStream.state, SocketState.Failed)
        @Expect(closeStream.isClosed())
        @Expect(closeDelegate.closeCalls, 1)
        @Expect(closeDelegate.abortCalls, 1)
    }

    @TestCase
    func tcpStreamAbortWinsWhileGracefulCloseIsBlocked(): Unit {
        let delegate = NetworkContractTransport(blockClose: true)
        let stream = TcpStream(delegate)
        let closing = spawn { stream.close() }
        delegate.waitUntilCloseEntered()

        stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
        delegate.releaseClose()
        closing.get(Duration.second)

        expectSocketState(stream.state, SocketState.Aborted)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 1)
    }

    @TestCase
    func tcpStreamCloseKeepsGracefulCauseWhenItWakesARead(): Unit {
        let delegate = NetworkContractTransport(blockRead: true)
        let stream = TcpStream(delegate)
        let reading: Future<Bool> = spawn {
            try {
                let _ = stream.read(
                    api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                    context: api.OperationContext.background()
                )
                false
            } catch (error: api.NetworkException) {
                isClosedTransportError(error)
            }
        }
        delegate.waitUntilReadEntered()

        stream.close()
        @Expect(reading.get(Duration.second))
        expectSocketState(stream.state, SocketState.Closed)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 0)
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
    func datagramResultEnforcesTheIpv4PayloadBound(): Unit {
        let maximum = DatagramReceiveResult(
            Array<Byte>(65507, repeat: 0u8), None<NetworkEndpoint>, false)
        @Expect(maximum.payload.size, 65507)
        var rejected = false
        try {
            let _ = DatagramReceiveResult(
                Array<Byte>(65508, repeat: 0u8), None<NetworkEndpoint>, false)
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func datagramResultSurvivesReceiveBufferReuse(): Unit {
        let buffer = [1u8, 2u8, 3u8]
        let received = DatagramReceiveResult(buffer, None<NetworkEndpoint>, true)
        buffer[0] = 9u8
        @Expect(received.payload, [1u8, 2u8, 3u8])
    }

}

private class NetworkContractTransport <: api.DuplexTransport {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var endpointsVisible: Bool
    private var closed = false
    private var readShutdown = false
    private var writeShutdown = false
    private let supportsHalfClose: Bool
    private let failRead: Bool
    private let failWrite: Bool
    private let failClose: Bool
    private let blockClose: Bool
    private let blockRead: Bool
    private var closeEntered = false
    private var readEntered = false
    private var closeReleased = false
    public var readCalls: Int64 = 0
    public var writeCalls: Int64 = 0
    public var shutdownCalls: Int64 = 0
    public var closeCalls: Int64 = 0
    public var abortCalls: Int64 = 0

    init(
        endpointsVisible!: Bool = true,
        supportsHalfClose!: Bool = false,
        failRead!: Bool = false,
        failWrite!: Bool = false,
        failClose!: Bool = false,
        blockClose!: Bool = false,
        blockRead!: Bool = false
    ) {
        this.endpointsVisible = endpointsVisible
        this.supportsHalfClose = supportsHalfClose
        this.failRead = failRead
        this.failWrite = failWrite
        this.failClose = failClose
        this.blockClose = blockClose
        this.blockRead = blockRead
    }

    public prop info: api.TransportInfo {
        get() {
            synchronized(mutex) {
                if (endpointsVisible) {
                    api.TransportInfo(
                        "network-contract-test",
                        runtimeIoBackend: "deterministic",
                        localEndpoint: Some(networkTestEndpoint(41001u16)),
                        remoteEndpoint: Some(networkTestEndpoint(41002u16)),
                        supportsHalfClose: supportsHalfClose,
                        supportsAbort: true
                    )
                } else {
                    api.TransportInfo(
                        "network-contract-test",
                        runtimeIoBackend: "deterministic",
                        supportsHalfClose: supportsHalfClose,
                        supportsAbort: true
                    )
                }
            }
        }
    }

    func hideEndpoints(): Unit { synchronized(mutex) { endpointsVisible = false } }

    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        let _ = context
        synchronized(mutex) {
            rejectClosedTransport(closed || readShutdown,
                api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
            readCalls++
            if (failRead) { throw deterministicTransportFailure(api.NetworkErrorCategory.Read,
                api.NetworkPhase.TcpRead) }
            if (blockRead) {
                readEntered = true
                changed.notifyAll()
                while (!closed) { changed.wait() }
                rejectClosedTransport(closed,
                    api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
            }
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
    }

    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        let _ = context
        synchronized(mutex) {
            rejectClosedTransport(closed || writeShutdown,
                api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite)
            writeCalls++
            if (failWrite) { throw deterministicTransportFailure(api.NetworkErrorCategory.Write,
                api.NetworkPhase.TcpWrite) }
            min(source.length, 2)
        }
    }

    public func shutdown(direction: api.ShutdownDirection): Unit {
        synchronized(mutex) {
            rejectClosedTransport(closed, api.NetworkErrorCategory.Shutdown,
                api.NetworkPhase.TransportClose)
            shutdownCalls++
            if (!supportsHalfClose) {
                throw api.NetworkException(
                    api.NetworkErrorCategory.Unsupported,
                    api.NetworkPhase.TransportClose,
                    api.NetworkErrorCode.Unsupported,
                    "deterministic transport does not support half-close",
                    retryability: api.Retryability.Never
                )
            }
            match (direction) {
                case api.ShutdownDirection.Read => readShutdown = true
                case api.ShutdownDirection.Write => writeShutdown = true
            }
            if (readShutdown && writeShutdown) { closed = true }
        }
    }

    public func close(context: api.OperationContext): Unit {
        let _ = context
        synchronized(mutex) {
            if (!closed) {
                closeCalls++
                if (failClose) { throw Exception("deterministic close failure") }
                closeEntered = true
                changed.notifyAll()
                while (blockClose && !closeReleased && !closed) { changed.wait() }
                closed = true
            }
        }
    }

    public func close(): Unit { close(api.OperationContext.background()) }

    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        synchronized(mutex) {
            if (!closed) {
                closed = true
                abortCalls++
                changed.notifyAll()
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    func waitUntilReadEntered(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (!readEntered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for deterministic read")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func waitUntilCloseEntered(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (!closeEntered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for deterministic close")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func releaseClose(): Unit {
        synchronized(mutex) {
            closeReleased = true
            changed.notifyAll()
        }
    }
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
        case (SocketState.ReadHalfClosed, SocketState.ReadHalfClosed) => true
        case (SocketState.WriteHalfClosed, SocketState.WriteHalfClosed) => true
        case (SocketState.Closing, SocketState.Closing) => true
        case (SocketState.Closed, SocketState.Closed) => true
        case (SocketState.Aborted, SocketState.Aborted) => true
        case (SocketState.Failed, SocketState.Failed) => true
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

private func isUnsupportedTransportError(error: api.NetworkException): Bool {
    match (error.code) {
        case api.NetworkErrorCode.Unsupported => true
        case _ => false
    }
}

private func isSystemFailure(error: api.NetworkException): Bool {
    match (error.code) {
        case api.NetworkErrorCode.SystemFailure => true
        case _ => false
    }
}

private func isClosedTransportError(error: api.NetworkException): Bool {
    match (error.code) {
        case api.NetworkErrorCode.Closed => true
        case _ => false
    }
}

private func deterministicTransportFailure(
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase
): api.NetworkException {
    api.NetworkException(
        category,
        phase,
        api.NetworkErrorCode.SystemFailure,
        "deterministic transport failure",
        retryability: api.Retryability.Unknown
    )
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

