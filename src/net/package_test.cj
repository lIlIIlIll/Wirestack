package wirestack.net

import std.unittest.*
import std.sync.*
import std.time.MonoTime
import std.unittest.testmacro.*
import wirestack as api
import wirestack.{NetworkEndpoint, UnixEndpoint, UnixEndpointKind}
import wirestack.internal.transport_stdnet as stdnet

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
    func tcpStreamCancellationDistinguishesUntouchedFromAbortedDelegate(): Unit {
        let source = api.CancellationSource()
        source.cancel()
        let untouched = TcpStream(NetworkContractTransport())
        expectCancelledRead(untouched, api.OperationContext(cancellation: source.token))
        expectSocketState(untouched.state, SocketState.Open)
        @Expect(!untouched.isClosed())
        untouched.close()

        let aborted = TcpStream(NetworkContractTransport(cancelRead: true))
        expectCancelledRead(aborted, api.OperationContext.background())
        @Expect(aborted.isClosed())
        expectSocketState(aborted.state, SocketState.Aborted)
        aborted.close()
        expectSocketState(aborted.state, SocketState.Aborted)
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
    func tcpStreamTerminalCloseSkipsStoppedContextsAndCallerClock(): Unit {
        let closedDelegate = NetworkContractTransport()
        let closed = TcpStream(closedDelegate)
        closed.close()
        expectTerminalCloseSkipsContexts(closed, SocketState.Closed)
        @Expect(closedDelegate.closeCalls, 1)
        @Expect(closedDelegate.abortCalls, 0)

        let abortedDelegate = NetworkContractTransport()
        let aborted = TcpStream(abortedDelegate)
        aborted.abort(reason: Some(api.AbortReason.ApplicationAbort))
        expectTerminalCloseSkipsContexts(aborted, SocketState.Aborted)
        @Expect(abortedDelegate.closeCalls, 0)
        @Expect(abortedDelegate.abortCalls, 1)

        let failedDelegate = NetworkContractTransport(
            closeFailure: Some(Exception("terminal close failure")))
        let failed = TcpStream(failedDelegate)
        var failedClose = false
        try {
            failed.close()
        } catch (_: api.NetworkException) {
            failedClose = true
        }
        @Assert(failedClose)
        expectTerminalCloseSkipsContexts(failed, SocketState.Failed)
        @Expect(failedDelegate.closeCalls, 1)
        @Expect(failedDelegate.abortCalls, 1)
    }

    @TestCase
    func tcpStreamNonterminalStoppedCloseAdmissionStillRejects(): Unit {
        let cancelledDelegate = NetworkContractTransport()
        let cancelledStream = TcpStream(cancelledDelegate)
        cancelledDelegate.hideEndpoints()
        let cancellation = api.CancellationSource()
        cancellation.cancel()
        @Expect(closeFailsForContext(
            cancelledStream,
            api.OperationContext(cancellation: cancellation.token),
            false
        ))
        expectSocketState(cancelledStream.state, SocketState.Open)
        @Expect(!cancelledStream.isClosed())
        @Expect(cancelledDelegate.closeCalls, 0)
        @Expect(cancelledDelegate.abortCalls, 0)
        cancelledStream.close()

        let deadlineDelegate = NetworkContractTransport()
        let deadlineStream = TcpStream(deadlineDelegate)
        deadlineDelegate.hideEndpoints()
        @Expect(closeFailsForContext(
            deadlineStream,
            api.OperationContext(deadline: Some(api.Deadline.after(Duration.Zero))),
            true
        ))
        expectSocketState(deadlineStream.state, SocketState.Open)
        @Expect(!deadlineStream.isClosed())
        @Expect(deadlineDelegate.closeCalls, 0)
        @Expect(deadlineDelegate.abortCalls, 0)
        deadlineStream.close()
    }

    @TestCase
    func tcpStreamCloseNormalizesContextFailureWithoutTakingOwnership(): Unit {
        let cause = Exception("deadline clock failure")
        let delegate = NetworkContractTransport()
        let stream = TcpStream(delegate)
        let context = api.OperationContext(deadline: Some(api.Deadline(
            MonoTime.now() + Duration.second, clock: NetworkFailingCloseClock(cause))))
        var structured = false
        try {
            try {
                stream.close(context: context)
            } catch (error: api.NetworkException) {
                let classification = match ((error.category, error.phase, error.code, error.retryability)) {
                    case (api.NetworkErrorCategory.System, api.NetworkPhase.TransportClose,
                          api.NetworkErrorCode.SystemFailure, api.Retryability.Never) => true
                    case _ => false
                }
                structured = classification &&
                    hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                    hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16)) &&
                    error.cause.getOrThrow().message == cause.message
            } catch (_: Exception) {}
            @Expect(structured)
            expectSocketState(stream.state, SocketState.Open)
            @Expect(!stream.isClosed())
            @Expect(delegate.closeCalls, 0)
        } finally {
            stream.close()
        }
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
    func tcpStreamReadShutdownRejectsEveryReadPathWithoutLosingWrites(): Unit {
        expectReadShutdownRejection({ stream =>
            let _ = stream.read(
                api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                context: api.OperationContext.background()
            )
        })
        expectReadShutdownRejection({ stream =>
            let _ = stream.readSome(
                api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                context: api.OperationContext.background()
            )
        })
        expectReadShutdownRejection({ stream =>
            stream.readExact(
                api.MutableByteSpan(Array<Byte>(3, repeat: 0u8)),
                context: api.OperationContext.background()
            )
        })
    }

    @TestCase
    func tcpStreamWriteShutdownRejectsEveryWritePathWithoutLosingReads(): Unit {
        expectWriteShutdownRejection({ stream =>
            let _ = stream.write(
                api.ByteSpan([1u8]),
                context: api.OperationContext.background()
            )
        })
        expectWriteShutdownRejection({ stream =>
            let _ = stream.writeSome(
                api.ByteSpan([1u8]),
                context: api.OperationContext.background()
            )
        })
        expectWriteShutdownRejection({ stream =>
            stream.writeAll(
                api.ByteSpan([1u8, 2u8, 3u8]),
                context: api.OperationContext.background()
            )
        })
    }

    @TestCase
    func tcpStreamEmptyOperationsRemainImmediateAfterDirectionalShutdown(): Unit {
        let readClosed = TcpStream(NetworkContractTransport(supportsHalfClose: true))
        readClosed.shutdown(api.ShutdownDirection.Read)
        match (readClosed.readSome(
            api.MutableByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        )) {
            case api.ReadResult.Data(count) => @Expect(count, 0)
            case _ => @Fail("empty readSome reported end of stream")
        }
        match (readClosed.read(
            api.MutableByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        )) {
            case ReadResult.Data(count) => @Expect(count, 0)
            case _ => @Fail("empty read reported end of stream")
        }
        readClosed.readExact(
            api.MutableByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        )
        expectSocketState(readClosed.state, SocketState.ReadHalfClosed)

        let writeClosed = TcpStream(NetworkContractTransport(supportsHalfClose: true))
        writeClosed.shutdown(api.ShutdownDirection.Write)
        @Expect(writeClosed.writeSome(
            api.ByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        ), 0)
        @Expect(writeClosed.write(
            api.ByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        ), 0)
        writeClosed.writeAll(
            api.ByteSpan(Array<Byte>()),
            context: api.OperationContext.background()
        )
        expectSocketState(writeClosed.state, SocketState.WriteHalfClosed)
    }

    @TestCase
    func tcpStreamReadExactAddsCapturedEndpointsToUnexpectedEof(): Unit {
        let delegate = NetworkContractTransport(eofAfterFirstRead: true)
        let stream = TcpStream(delegate)
        delegate.hideEndpoints()
        let destination = Array<Byte>(3, repeat: 0u8)
        var matched = false

        try {
            stream.readExact(
                api.MutableByteSpan(destination),
                context: api.OperationContext.background()
            )
        } catch (error: api.NetworkException) {
            matched = isUnexpectedEofRead(error) &&
                hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16))
        }

        @Expect(matched)
        @Expect(destination, [0xA5u8, 0x5Au8, 0u8])
        expectSocketState(stream.state, SocketState.Open)
        @Expect(!stream.isClosed())
        stream.close()
    }

    @TestCase
    func tcpStreamReadKeepsPeerEofGraceful(): Unit {
        let delegate = NetworkContractTransport(eofAfterFirstRead: true)
        let stream = TcpStream(delegate)
        let prefix = Array<Byte>(3, repeat: 0u8)
        match (stream.read(api.MutableByteSpan(prefix),
            context: api.OperationContext.background())) {
            case ReadResult.Data(count) => @Expect(count, 2)
            case _ => @Fail("expected the deterministic prefix")
        }
        match (stream.read(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
            context: api.OperationContext.background())) {
            case ReadResult.EndOfStream => ()
            case _ => @Fail("expected graceful peer EOF")
        }

        expectSocketState(stream.state, SocketState.Open)
        @Expect(!stream.isClosed())
        stream.close()
    }

    @TestCase
    func tcpStreamReadExactMergesCapturedAndStructuredEndpointMetadata(): Unit {
        let cause = Exception("deterministic native read cause")
        let remoteBytes = [0u8, 0xFFu8, 0x2Fu8, 0x00u8, 0x41u8]
        let remote = UnixEndpoint.abstractName(remoteBytes)
        remoteBytes[1] = 0x01u8
        let supplied = api.NetworkException(
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.TcpRead,
            api.NetworkErrorCode.ConnectionReset,
            "deterministic structured read failure",
            retryability: api.Retryability.SafeBeforeWrite,
            nativeCode: Some<Int64>(104),
            remoteEndpoint: Some(NetworkEndpoint.Unix(remote)),
            cause: Some<Exception>(cause)
        )
        let delegate = NetworkContractTransport(readFailure: Some(supplied))
        let stream = TcpStream(delegate)
        delegate.hideEndpoints()
        var matched = false

        try {
            stream.readExact(
                api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                context: api.OperationContext.background()
            )
        } catch (error: api.NetworkException) {
            matched = hasStructuredReadClassification(error) &&
                error.nativeCode == Some<Int64>(104) &&
                error.cause.getOrThrow().toString() == cause.toString() &&
                hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                hasUnixAbstractEndpoint(
                    error.remoteEndpoint,
                    [0u8, 0xFFu8, 0x2Fu8, 0x00u8, 0x41u8]
                )
        }

        @Expect(matched)
        expectSocketState(stream.state, SocketState.Failed)
        @Expect(stream.isClosed())
    }

    @TestCase
    func tcpStreamIoConflictsRetainCapturedEndpointsWithoutClosing(): Unit {
        let readConflict = api.NetworkException(
            api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
            api.NetworkErrorCode.ConcurrentOperation, "read already active")
        let writeConflict = api.NetworkException(
            api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
            api.NetworkErrorCode.ConcurrentOperation, "write already active")
        let stream = TcpStream(NetworkContractTransport(
            readFailure: Some(readConflict), writeFailure: Some(writeConflict)))
        let context = api.OperationContext.background()
        let destination = api.MutableByteSpan(Array<Byte>(1, repeat: 0u8))
        let source = api.ByteSpan([1u8])
        let operations: Array<() -> Unit> = [
            { => let _ = stream.read(destination, context: context) },
            { => let _ = stream.readSome(destination, context: context) },
            { => stream.readExact(destination, context: context) },
            { => let _ = stream.write(source, context: context) },
            { => let _ = stream.writeSome(source, context: context) },
            { => stream.writeAll(source, context: context) }
        ]
        for (index in 0..operations.size) {
            var retained = false
            try {
                operations[index]()
            } catch (error: api.NetworkException) {
                let classification = match ((error.category, error.phase, error.code)) {
                    case (api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead,
                        api.NetworkErrorCode.ConcurrentOperation) => index < 3
                    case (api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite,
                        api.NetworkErrorCode.ConcurrentOperation) => index >= 3
                    case _ => false
                }
                retained = classification &&
                    hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                    hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16))
            }
            @Expect(retained)
            expectSocketState(stream.state, SocketState.Open)
            @Expect(!stream.isClosed())
        }
        stream.close()
    }

    @TestCase
    func tcpStreamDirectionalShutdownDoesNotPromoteWokenIoToFailure(): Unit {
        let readDelegate = NetworkContractTransport(
            supportsHalfClose: true,
            blockRead: true
        )
        let readStream = TcpStream(readDelegate)
        let reading: Future<Bool> = spawn {
            try {
                let _ = readStream.readSome(
                    api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                    context: api.OperationContext.background()
                )
                false
            } catch (error: api.NetworkException) {
                isClosedTransportError(error)
            }
        }
        readDelegate.waitUntilReadEntered()
        readStream.shutdown(api.ShutdownDirection.Read)
        @Expect(reading.get(Duration.second))
        expectSocketState(readStream.state, SocketState.ReadHalfClosed)
        @Expect(readStream.writeSome(
            api.ByteSpan([1u8]),
            context: api.OperationContext.background()
        ), 1)
        @Expect(!readStream.isClosed())

        let writeDelegate = NetworkContractTransport(
            supportsHalfClose: true,
            blockWrite: true
        )
        let writeStream = TcpStream(writeDelegate)
        let writing: Future<Bool> = spawn {
            try {
                let _ = writeStream.writeSome(
                    api.ByteSpan([1u8]),
                    context: api.OperationContext.background()
                )
                false
            } catch (error: api.NetworkException) {
                isClosedTransportError(error)
            }
        }
        writeDelegate.waitUntilWriteEntered()
        writeStream.shutdown(api.ShutdownDirection.Write)
        @Expect(writing.get(Duration.second))
        expectSocketState(writeStream.state, SocketState.WriteHalfClosed)
        let readBuffer = Array<Byte>(1, repeat: 0u8)
        match (writeStream.readSome(
            api.MutableByteSpan(readBuffer),
            context: api.OperationContext.background()
        )) {
            case api.ReadResult.Data(count) => @Expect(count, 1)
            case _ => @Fail("read direction was lost after racing write shutdown")
        }
        @Expect(readBuffer, [0xA5u8])
        @Expect(!writeStream.isClosed())
    }

    @TestCase
    func tcpStreamFinalShutdownRemainsGracefulWhenItWakesIo(): Unit {
        let reading = Array<?Future<Bool>>(1, repeat: None<Future<Bool>>)
        let delegate = NetworkContractTransport(
            supportsHalfClose: true,
            blockRead: true,
            afterShutdown: { =>
                match (reading[0]) {
                    case Some(pending) => @Expect(pending.get(Duration.second))
                    case None => ()
                }
            }
        )
        let stream = TcpStream(delegate)
        stream.shutdown(api.ShutdownDirection.Write)
        let pending: Future<Bool> = spawn {
            try {
                let _ = stream.readSome(
                    api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                    context: api.OperationContext.background())
                false
            } catch (error: api.NetworkException) {
                isClosedTransportError(error)
            }
        }
        reading[0] = Some(pending)
        delegate.waitUntilReadEntered()
        stream.shutdown(api.ShutdownDirection.Read)
        @Expect(stream.isClosed())
        expectSocketState(stream.state, SocketState.Closed)
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

        let closeCause = Exception("delegate close failed")
        let closeDelegate = NetworkContractTransport(closeFailure: Some(closeCause))
        let closeStream = TcpStream(closeDelegate)
        var closeFailure = false
        try {
            closeStream.close()
        } catch (error: api.NetworkException) {
            let classification = match ((error.category, error.phase, error.code, error.retryability)) {
                case (api.NetworkErrorCategory.System, api.NetworkPhase.TransportClose,
                    api.NetworkErrorCode.SystemFailure, api.Retryability.Never) => true
                case _ => false
            }
            closeFailure = classification &&
                hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16)) &&
                error.cause.getOrThrow().message == closeCause.message
        } catch (_: Exception) {}
        @Expect(closeFailure)
        expectSocketState(closeStream.state, SocketState.Failed)
        @Expect(closeStream.isClosed())
        @Expect(closeDelegate.closeCalls, 1)
        @Expect(closeDelegate.abortCalls, 1)
    }

    @TestCase
    func tcpStreamRetainsNativeCancellationOwnership(): Unit {
        let listener = stdnet.StdNetTransportListener.bind(networkTestEndpoint(0u16))
        let accepting = spawn { listener.accept() }
        let backend = stdnet.StdNetTransport.connect(listener.localEndpoint)
        let stream = TcpStream(backend)
        let peer = accepting.get(Duration.second)
        try {
            let cancellation = api.CancellationSource()
            let reading: Future<Bool> = spawn {
                try {
                    let _ = stream.readSome(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                        context: api.OperationContext(cancellation: cancellation.token))
                    false
                } catch (error: api.NetworkException) {
                    match (error.code) {
                        case api.NetworkErrorCode.Cancelled => true
                        case _ => false
                    }
                }
            }
            try {
                @Expect(backend.waitUntilReadActive(Duration.second))
                cancellation.cancel()
                @Expect(reading.get(Duration.second))
                expectSocketState(stream.state, SocketState.Aborted)
                @Expect(stream.isClosed())
                stream.close()
                expectSocketState(stream.state, SocketState.Aborted)
            } finally {
                cancellation.cancel()
                stream.abort()
            }
            let _ = reading.get(Duration.second)
        } finally {
            stream.close()
            peer.close()
            listener.close()
        }
    }

    @TestCase
    func tcpStreamNormalizesUnexpectedDelegateFailures(): Unit {
        for (operation in 0..8) {
            let cause = Exception("unclassified delegate failure")
            let delegate = NetworkContractTransport(
                readFailure: Some(cause), writeFailure: Some(cause),
                shutdownFailure: Some(cause), abortFailure: Some(cause))
            let stream = TcpStream(delegate)
            let context = api.OperationContext.background()
            let destination = api.MutableByteSpan(Array<Byte>(1, repeat: 0u8))
            let source = api.ByteSpan([1u8])
            var structured = false
            try {
                match (operation) {
                    case 0 => let _ = stream.read(destination, context: context)
                    case 1 => let _ = stream.readSome(destination, context: context)
                    case 2 => stream.readExact(destination, context: context)
                    case 3 => let _ = stream.write(source, context: context)
                    case 4 => let _ = stream.writeSome(source, context: context)
                    case 5 => stream.writeAll(source, context: context)
                    case 6 => stream.shutdown(api.ShutdownDirection.Read)
                    case _ => stream.abort()
                }
            } catch (error: api.NetworkException) {
                let category = match (error.category) {
                    case api.NetworkErrorCategory.Read => operation < 3
                    case api.NetworkErrorCategory.Write => operation >= 3 && operation < 6
                    case api.NetworkErrorCategory.Shutdown => operation == 6
                    case api.NetworkErrorCategory.System => operation == 7
                    case _ => false
                }
                let phase = match (error.phase) {
                    case api.NetworkPhase.TcpRead => operation < 3
                    case api.NetworkPhase.TcpWrite => operation >= 3 && operation < 6
                    case api.NetworkPhase.TransportClose => operation >= 6
                    case _ => false
                }
                let classification = match ((error.code, error.retryability)) {
                    case (api.NetworkErrorCode.SystemFailure, api.Retryability.Never) => true
                    case _ => false
                }
                structured = category && phase && classification &&
                    hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
                    hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16)) &&
                    error.cause.getOrThrow().message == cause.message
            } catch (_: Exception) {}
            @Expect(structured)
            expectSocketState(stream.state,
                if (operation == 7) { SocketState.Aborted } else { SocketState.Failed })
            @Expect(stream.isClosed())
            stream.close()
            stream.abort()
            expectSocketState(stream.state,
                if (operation == 7) { SocketState.Aborted } else { SocketState.Failed })
        }
    }

    @TestCase
    func tcpStreamPrecancelledIoCannotClaimAnotherClosesOwnership(): Unit {
        for (reading in [true, false]) {
            let admitted = NetworkTestLatch()
            let resumeIo = NetworkTestLatch()
            let closePublished = NetworkTestLatch()
            let finishClose = NetworkTestLatch()
            let delegate = NetworkContractTransport(
                beforeIo: { => admitted.signal(); resumeIo.wait() },
                afterClose: { => closePublished.signal(); finishClose.wait() })
            let stream = TcpStream(delegate)
            let cancellation = api.CancellationSource()
            cancellation.cancel()
            let context = api.OperationContext(cancellation: cancellation.token)
            let pending: Future<Bool> = spawn {
                try {
                    if (reading) {
                        let _ = stream.readSome(
                            api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)), context: context)
                    } else {
                        let _ = stream.writeSome(api.ByteSpan([1u8]), context: context)
                    }
                    false
                } catch (error: api.NetworkException) {
                    match (error.code) {
                        case api.NetworkErrorCode.Cancelled => true
                        case _ => false
                    }
                }
            }
            try {
                admitted.wait()
                let closing = spawn { stream.close() }
                try {
                    closePublished.wait()
                    resumeIo.signal()
                    @Expect(pending.get(Duration.second))
                    expectSocketState(stream.state, SocketState.Closing)
                } finally {
                    finishClose.signal()
                    resumeIo.signal()
                }
                closing.get(Duration.second)
                expectSocketState(stream.state, SocketState.Closed)
                @Expect(delegate.abortCalls, 0)
            } finally {
                finishClose.signal()
                resumeIo.signal()
            }
            let _ = pending.get(Duration.second)
        }
    }

    @TestCase
    func tcpStreamCancellationOwnershipSurvivesOtherObservers(): Unit {
        for (closeObserver in [true, false]) {
            let holder = Array<?TcpStream>(1, repeat: None<TcpStream>)
            let delegate = NetworkContractTransport(
                cancelRead: true,
                afterCancellation: { =>
                    let stream = holder[0].getOrThrow()
                    if (closeObserver) {
                        stream.close()
                    } else {
                        var closed = false
                        try {
                            let _ = stream.writeSome(api.ByteSpan([1u8]))
                        } catch (error: api.NetworkException) {
                            closed = isClosedTransportError(error)
                        }
                        @Expect(closed)
                    }
                })
            let stream = TcpStream(delegate)
            holder[0] = Some(stream)
            expectCancelledRead(stream, api.OperationContext.background())
            expectSocketState(stream.state, SocketState.Aborted)
            @Expect(stream.isClosed())
            holder[0] = None<TcpStream>
        }
    }

    @TestCase
    func tcpStreamAbortCannotRelabelClaimedGracefulNativeClose(): Unit {
        let delegate = NetworkContractTransport(
            blockClose: true,
            claimCloseBeforeBlock: true
        )
        let stream = TcpStream(delegate)
        let closing = spawn { stream.close() }
        try {
            delegate.waitUntilCloseEntered()
            stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
            expectSocketState(stream.state, SocketState.Closing)
            @Expect(stream.isClosed())
            @Expect(delegate.abortCalls, 0)
        } finally {
            delegate.releaseClose()
        }
        closing.get(Duration.second)

        expectSocketState(stream.state, SocketState.Closed)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 0)
    }

    @TestCase
    func tcpStreamAbortOwnershipSurvivesCompetingIoAndLateCloseFailure(): Unit {
        let delegate = NetworkContractTransport(
            blockClose: true,
            blockRead: true,
            closeFailure: Some(Exception("late close failure after abort ownership"))
        )
        let stream = TcpStream(delegate)
        let reading: Future<Bool> = spawn {
            try {
                let _ = stream.readSome(
                    api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
                    context: api.OperationContext.background())
                false
            } catch (error: api.NetworkException) {
                isClosedTransportError(error)
            }
        }
        try {
            delegate.waitUntilReadEntered()
            let closing: Future<Bool> = spawn {
                try {
                    stream.close()
                    false
                } catch (error: api.NetworkException) {
                    isSystemFailure(error)
                }
            }
            try {
                delegate.waitUntilCloseEntered()
                stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
                @Expect(reading.get(Duration.second))
            } finally {
                delegate.abort()
                delegate.releaseClose()
                @Expect(closing.get(Duration.second))
            }
            expectSocketState(stream.state, SocketState.Aborted)
            @Expect(stream.isClosed())
            @Expect(delegate.closeCalls, 1)
            @Expect(delegate.abortCalls, 1)
            stream.close()
            expectSocketState(stream.state, SocketState.Aborted)
        } finally {
            delegate.abort()
            delegate.releaseClose()
            let _ = reading.get(Duration.second)
        }
    }

    @TestCase
    func tcpStreamCancellationBoundsCloseWaitAndLateSuccessRemainsGraceful(): Unit {
        let delegate = NetworkContractTransport(blockClose: true)
        let stream = TcpStream(delegate)
        let cancellation = api.CancellationSource()
        let closing: Future<Bool> = spawn {
            closeFailsForContext(
                stream,
                api.OperationContext(cancellation: cancellation.token),
                false
            )
        }
        try {
            delegate.waitUntilCloseEntered()
            cancellation.cancel()
            @Expect(closing.get(Duration.second))
            expectSocketState(stream.state, SocketState.Closing)
            @Expect(!stream.isClosed())
            @Expect(delegate.closeCalls, 1)
            @Expect(delegate.abortCalls, 0)
        } finally {
            cancellation.cancel()
            delegate.releaseClose()
        }
        stream.close()
        expectSocketState(stream.state, SocketState.Closed)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 0)
    }

    @TestCase
    func tcpStreamJoiningBackgroundCloseWaitsForCompletion(): Unit {
        let delegate = NetworkContractTransport(blockClose: true)
        let stream = TcpStream(delegate)
        let closing = spawn { stream.close() }
        try {
            delegate.waitUntilCloseEntered()
            @Expect(closeFailsForContext(stream, api.OperationContext(
                deadline: Some(api.Deadline.after(20 * Duration.millisecond))
            ), true))
            expectSocketState(stream.state, SocketState.Closing)
            @Expect(!stream.isClosed())
        } finally {
            delegate.releaseClose()
        }
        closing.get(Duration.second)
        expectSocketState(stream.state, SocketState.Closed)
        @Expect(stream.isClosed())
    }

    @TestCase
    func tcpStreamDeadlineBoundsCloseWaitAndLateSuccessRemainsGraceful(): Unit {
        let delegate = NetworkContractTransport(blockClose: true)
        let stream = TcpStream(delegate)
        let clock = NetworkCloseDeadlineClock(delegate, stream)
        let context = api.OperationContext(deadline: Some(api.Deadline.after(
            Duration.second,
            clock: clock
        )))
        let closing: Future<Bool> = spawn {
            closeFailsForContext(stream, context, true)
        }
        try {
            delegate.waitUntilCloseEntered()
            @Expect(closing.get(Duration.second))
            expectSocketState(stream.state, SocketState.Closing)
            @Expect(!stream.isClosed())
            @Expect(delegate.closeCalls, 1)
            @Expect(delegate.abortCalls, 0)
        } finally {
            delegate.releaseClose()
        }
        stream.close()
        expectSocketState(stream.state, SocketState.Closed)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 0)
    }

    @TestCase
    func tcpStreamLateCloseFailurePublishesFailedWithoutReplacingCallerCancellation(): Unit {
        let closeCause = Exception("late deterministic close failure")
        let delegate = NetworkContractTransport(
            closeFailure: Some(closeCause),
            blockClose: true
        )
        let stream = TcpStream(delegate)
        let cancellation = api.CancellationSource()
        let closing: Future<Bool> = spawn {
            closeFailsForContext(
                stream,
                api.OperationContext(cancellation: cancellation.token),
                false
            )
        }
        try {
            delegate.waitUntilCloseEntered()
            cancellation.cancel()
            @Expect(closing.get(Duration.second))
            expectSocketState(stream.state, SocketState.Closing)
            @Expect(delegate.abortCalls, 0)
        } finally {
            cancellation.cancel()
            delegate.releaseClose()
        }
        delegate.waitUntilAbortCalled()
        settleDetachedClose(stream)
        expectSocketState(stream.state, SocketState.Failed)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 1)
    }

    @TestCase
    func tcpStreamAbortRemainsTerminalWhenDetachedCloseFailsLate(): Unit {
        let delegate = NetworkContractTransport(
            closeFailure: Some(Exception("secondary close cleanup failure")),
            blockClose: true
        )
        let stream = TcpStream(delegate)
        let cancellation = api.CancellationSource()
        let closing: Future<Bool> = spawn {
            closeFailsForContext(
                stream,
                api.OperationContext(cancellation: cancellation.token),
                false
            )
        }
        try {
            delegate.waitUntilCloseEntered()
            cancellation.cancel()
            @Expect(closing.get(Duration.second))
            stream.abort(reason: Some(api.AbortReason.ApplicationAbort))
            delegate.waitUntilCloseExited()
        } finally {
            cancellation.cancel()
            delegate.releaseClose()
        }
        expectSocketState(stream.state, SocketState.Aborted)
        @Expect(stream.isClosed())
        @Expect(delegate.closeCalls, 1)
        @Expect(delegate.abortCalls, 1)
        settleDetachedClose(stream)
        expectSocketState(stream.state, SocketState.Aborted)
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

private class NetworkContractTransport <: stdnet.SocketTransport {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var endpointsVisible: Bool
    private var closed = false
    private var readShutdown = false
    private var writeShutdown = false
    private let supportsHalfClose: Bool
    private let failRead: Bool
    private let eofAfterFirstRead: Bool
    private let readFailure: ?Exception
    private let writeFailure: ?Exception
    private let cancelRead: Bool
    private let failWrite: Bool
    private let closeFailure: ?Exception
    private let shutdownFailure: ?Exception
    private let abortFailure: ?Exception
    private let beforeIo: () -> Unit
    private let afterClose: () -> Unit
    private let afterCancellation: () -> Unit
    private var nativeCloseClaimed = false
    private var closedByAbort = false
    private let blockClose: Bool
    // Models the production delegate's first-close claim before close can block.
    private let claimCloseBeforeBlock: Bool
    private let blockRead: Bool
    private let blockWrite: Bool
    private let afterShutdown: () -> Unit
    private var closeEntered = false
    private var closeExited = false
    private var readEntered = false
    private var writeEntered = false
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
        eofAfterFirstRead!: Bool = false,
        readFailure!: ?Exception = None<Exception>,
        writeFailure!: ?Exception = None<Exception>,
        cancelRead!: Bool = false,
        failWrite!: Bool = false,
        closeFailure!: ?Exception = None<Exception>,
        shutdownFailure!: ?Exception = None<Exception>,
        abortFailure!: ?Exception = None<Exception>,
        beforeIo!: () -> Unit = { => },
        afterClose!: () -> Unit = { => },
        afterCancellation!: () -> Unit = { => },
        blockClose!: Bool = false,
        claimCloseBeforeBlock!: Bool = false,
        blockRead!: Bool = false,
        blockWrite!: Bool = false,
        afterShutdown!: () -> Unit = { => }
    ) {
        this.endpointsVisible = endpointsVisible
        this.supportsHalfClose = supportsHalfClose
        this.failRead = failRead
        this.eofAfterFirstRead = eofAfterFirstRead
        this.readFailure = readFailure
        this.writeFailure = writeFailure
        this.cancelRead = cancelRead
        this.failWrite = failWrite
        this.closeFailure = closeFailure
        this.shutdownFailure = shutdownFailure
        this.abortFailure = abortFailure
        this.beforeIo = beforeIo
        this.afterClose = afterClose
        this.afterCancellation = afterCancellation
        this.blockClose = blockClose
        this.claimCloseBeforeBlock = claimCloseBeforeBlock
        this.blockRead = blockRead
        this.blockWrite = blockWrite
        this.afterShutdown = afterShutdown
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
        beforeIo()
        if (context.isCancellationRequested()) { throw cancelledReadFailure() }
        if (cancelRead) {
            synchronized(mutex) {
                rejectClosedTransport(closed || readShutdown,
                    api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
                readCalls++
                if (!nativeCloseClaimed) {
                    nativeCloseClaimed = true
                    closedByAbort = true
                }
                closed = true
                changed.notifyAll()
            }
            afterCancellation()
            throw cancelledReadFailure()
        }
        synchronized(mutex) {
            rejectClosedTransport(closed || readShutdown,
                api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
            readCalls++
            match (readFailure) {
                case Some(error) => throw error
                case None => ()
            }
            if (failRead) { throw deterministicTransportFailure(api.NetworkErrorCategory.Read,
                api.NetworkPhase.TcpRead) }
            if (blockRead) {
                readEntered = true
                changed.notifyAll()
                while (!closed && !readShutdown) { changed.wait() }
                rejectClosedTransport(closed || readShutdown,
                    api.NetworkErrorCategory.Read, api.NetworkPhase.TcpRead)
            }
            if (eofAfterFirstRead && readCalls > 1) {
                return api.ReadResult.EndOfStream
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
        beforeIo()
        if (context.isCancellationRequested()) {
            throw api.NetworkException(api.NetworkErrorCategory.Cancelled, api.NetworkPhase.TcpWrite,
                api.NetworkErrorCode.Cancelled, "deterministic write cancellation")
        }
        synchronized(mutex) {
            rejectClosedTransport(closed || writeShutdown,
                api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite)
            writeCalls++
            match (writeFailure) {
                case Some(error) => throw error
                case None => ()
            }
            if (blockWrite) {
                writeEntered = true
                changed.notifyAll()
                while (!closed && !writeShutdown) { changed.wait() }
                rejectClosedTransport(closed || writeShutdown,
                    api.NetworkErrorCategory.Write, api.NetworkPhase.TcpWrite)
            }
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
            match (shutdownFailure) {
                case Some(error) => throw error
                case None => ()
            }
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
            if (readShutdown && writeShutdown) {
                nativeCloseClaimed = true
                closed = true
            }
            changed.notifyAll()
        }
        afterShutdown()
    }

    public func close(context: api.OperationContext): Unit {
        let _ = context
        try {
            synchronized(mutex) {
                if (!closed) {
                    closeCalls++
                    closeEntered = true
                    changed.notifyAll()
                    if (claimCloseBeforeBlock) { nativeCloseClaimed = true }
                    while (blockClose && !closeReleased && !closed) { changed.wait() }
                    match (closeFailure) {
                        case Some(error) => throw error
                        case None => ()
                    }
                    nativeCloseClaimed = true
                    closed = true
                }
            }
            afterClose()
        } finally {
            synchronized(mutex) {
                closeExited = true
                changed.notifyAll()
            }
        }
    }

    public func close(): Unit { close(api.OperationContext.background()) }

    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        let _ = reason
        synchronized(mutex) {
            if (!nativeCloseClaimed) {
                nativeCloseClaimed = true
                closedByAbort = true
                closed = true
                abortCalls++
                changed.notifyAll()
                match (abortFailure) {
                    case Some(error) => throw error
                    case None => ()
                }
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed || nativeCloseClaimed } }

    public func wasClosedByAbort(): Bool {
        synchronized(mutex) { closedByAbort }
    }

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

    func waitUntilWriteEntered(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (!writeEntered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for deterministic write")
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

    func waitUntilCloseExited(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (!closeExited) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for deterministic close cleanup")
                }
                changed.wait(timeout: remaining)
            }
        }
    }

    func waitUntilAbortCalled(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (abortCalls == 0) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for deterministic abort cleanup")
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

private class NetworkCloseDeadlineClock <: api.MonotonicClock {
    private let delegate: NetworkContractTransport
    private let stream: TcpStream
    private let origin = MonoTime.now()

    init(delegate: NetworkContractTransport, stream: TcpStream) {
        this.delegate = delegate
        this.stream = stream
    }

    public func now(): MonoTime {
        match (stream.state) {
            case SocketState.Closing =>
                delegate.waitUntilCloseEntered()
                origin + 2 * Duration.second
            case _ => origin
        }
    }
}

private class NetworkFailingCloseClock <: api.MonotonicClock {
    private let failure: Exception

    init(failure: Exception) {
        this.failure = failure
    }

    public func now(): MonoTime {
        throw failure
    }
}

private class NetworkTestLatch {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var signalled = false

    func signal(): Unit {
        synchronized(mutex) {
            signalled = true
            changed.notifyAll()
        }
    }

    func wait(): Unit {
        synchronized(mutex) {
            let deadline = api.Deadline.after(Duration.second)
            while (!signalled) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) {
                    throw Exception("timed out waiting for the network race gate")
                }
                changed.wait(timeout: remaining)
            }
        }
    }
}

private func cancelledReadFailure(): api.NetworkException {
    api.NetworkException(api.NetworkErrorCategory.Cancelled, api.NetworkPhase.TcpRead,
        api.NetworkErrorCode.Cancelled, "deterministic read cancellation")
}

private func expectCancelledRead(stream: TcpStream, context: api.OperationContext): Unit {
    var cancelled = false
    try {
        let _ = stream.readSome(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)),
            context: context)
    } catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.Cancelled => cancelled = true
            case _ => ()
        }
    }
    @Expect(cancelled)
}

private func expectTerminalCloseSkipsContexts(
    stream: TcpStream,
    expected: SocketState
): Unit {
    let cancellation = api.CancellationSource()
    cancellation.cancel()
    stream.close(context: api.OperationContext(cancellation: cancellation.token))
    expectSocketState(stream.state, expected)
    stream.close(context: api.OperationContext(deadline: Some(api.Deadline(
        MonoTime.now() + Duration.second,
        clock: NetworkFailingCloseClock(Exception("terminal close consulted caller clock"))
    ))))
    expectSocketState(stream.state, expected)
}

private func closeFailsForContext(
    stream: TcpStream,
    context: api.OperationContext,
    deadline: Bool
): Bool {
    try {
        stream.close(context: context)
        false
    } catch (error: api.NetworkException) {
        let classification = if (deadline) {
            match ((error.category, error.phase, error.code, error.retryability)) {
                case (
                    api.NetworkErrorCategory.DeadlineExceeded,
                    api.NetworkPhase.TransportClose,
                    api.NetworkErrorCode.TimedOut,
                    api.Retryability.Temporary
                ) => true
                case _ => false
            }
        } else {
            match ((error.category, error.phase, error.code, error.retryability)) {
                case (
                    api.NetworkErrorCategory.Cancelled,
                    api.NetworkPhase.TransportClose,
                    api.NetworkErrorCode.Cancelled,
                    api.Retryability.Never
                ) => true
                case _ => false
            }
        }
        classification &&
            hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
            hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16))
    } catch (_: Exception) {
        false
    }
}

private func settleDetachedClose(stream: TcpStream): Unit {
    try {
        stream.close()
    } catch (error: api.NetworkException) {
        let expected = match ((error.category, error.phase, error.code, error.retryability)) {
            case (
                api.NetworkErrorCategory.System,
                api.NetworkPhase.TransportClose,
                api.NetworkErrorCode.SystemFailure,
                api.Retryability.Never
            ) => true
            case _ => false
        }
        @Expect(expected)
    }
}

private func expectReadShutdownRejection(action: (TcpStream) -> Unit): Unit {
    let stream = TcpStream(NetworkContractTransport(supportsHalfClose: true))
    stream.shutdown(api.ShutdownDirection.Read)
    var rejected = false
    try {
        action(stream)
    } catch (error: api.NetworkException) {
        rejected = isDirectionalClosedError(
            error,
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.TcpRead
        )
    }
    @Expect(rejected)
    expectSocketState(stream.state, SocketState.ReadHalfClosed)
    stream.writeAll(
        api.ByteSpan([1u8, 2u8, 3u8]),
        context: api.OperationContext.background()
    )
    expectSocketState(stream.state, SocketState.ReadHalfClosed)
    @Expect(!stream.isClosed())
}

private func expectWriteShutdownRejection(action: (TcpStream) -> Unit): Unit {
    let stream = TcpStream(NetworkContractTransport(supportsHalfClose: true))
    stream.shutdown(api.ShutdownDirection.Write)
    var rejected = false
    try {
        action(stream)
    } catch (error: api.NetworkException) {
        rejected = isDirectionalClosedError(
            error,
            api.NetworkErrorCategory.Write,
            api.NetworkPhase.TcpWrite
        )
    }
    @Expect(rejected)
    expectSocketState(stream.state, SocketState.WriteHalfClosed)
    let destination = Array<Byte>(3, repeat: 0u8)
    stream.readExact(
        api.MutableByteSpan(destination),
        context: api.OperationContext.background()
    )
    @Expect(destination, [0xA5u8, 0x5Au8, 0xA5u8])
    expectSocketState(stream.state, SocketState.WriteHalfClosed)
    @Expect(!stream.isClosed())
}

private func isDirectionalClosedError(
    error: api.NetworkException,
    category: api.NetworkErrorCategory,
    phase: api.NetworkPhase
): Bool {
    let shapeMatches = match ((error.category, category, error.phase, phase)) {
        case (api.NetworkErrorCategory.Read, api.NetworkErrorCategory.Read,
              api.NetworkPhase.TcpRead, api.NetworkPhase.TcpRead) => true
        case (api.NetworkErrorCategory.Write, api.NetworkErrorCategory.Write,
              api.NetworkPhase.TcpWrite, api.NetworkPhase.TcpWrite) => true
        case _ => false
    }
    let codeMatches = match ((error.code, error.retryability)) {
        case (api.NetworkErrorCode.Closed, api.Retryability.Never) => true
        case _ => false
    }
    shapeMatches && codeMatches &&
        hasInternetEndpoint(error.localEndpoint, networkTestEndpoint(41001u16)) &&
        hasInternetEndpoint(error.remoteEndpoint, networkTestEndpoint(41002u16))
}

private func isUnexpectedEofRead(error: api.NetworkException): Bool {
    match ((error.category, error.phase, error.code, error.retryability)) {
        case (
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.TcpRead,
            api.NetworkErrorCode.UnexpectedEof,
            api.Retryability.Never
        ) => true
        case _ => false
    }
}

private func hasStructuredReadClassification(error: api.NetworkException): Bool {
    match ((error.category, error.phase, error.code, error.retryability)) {
        case (
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.TcpRead,
            api.NetworkErrorCode.ConnectionReset,
            api.Retryability.SafeBeforeWrite
        ) => true
        case _ => false
    }
}

private func hasUnixAbstractEndpoint(
    actual: ?NetworkEndpoint,
    expected: Array<Byte>
): Bool {
    match (actual) {
        case Some(NetworkEndpoint.Unix(endpoint)) =>
            match (endpoint.kind) {
                case UnixEndpointKind.Abstract => endpoint.nameBytes() == expected
                case _ => false
            }
        case _ => false
    }
}

private func hasInternetEndpoint(
    actual: ?NetworkEndpoint,
    expected: api.SocketEndpoint
): Bool {
    match (actual) {
        case Some(NetworkEndpoint.Internet(endpoint)) => endpoint == expected
        case _ => false
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

