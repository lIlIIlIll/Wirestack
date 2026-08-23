package wirestack.internal.transport_stdnet

import std.sync.SyncCounter
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

@Test
class StdNetTransportTest {
    @TestCase
    func connectsByResolvedIpAndTransfersBothDirections(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0), backlog: 4, stagingBufferSize: 3)
        let accepted: Future<DuplexTransport> = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint, stagingBufferSize: 3)
        let server = accepted.get(Duration.second)
        try {
            @Expect(client.info.backend, "std.net")
            @Expect(client.info.localEndpoint.isSome())
            @Expect(!client.info.supportsHalfClose)

            writeAll(client, ByteSpan([1, 2, 3, 4, 5]))
            let request = Array<Byte>(5, repeat: 0)
            readExact(server, MutableByteSpan(request))
            let expectedRequest: Array<Byte> = [1, 2, 3, 4, 5]
            @Expect(request, expectedRequest)

            writeAll(server, ByteSpan([9, 8]))
            let response = Array<Byte>(2, repeat: 0)
            readExact(client, MutableByteSpan(response))
            let expectedResponse: Array<Byte> = [9, 8]
            @Expect(response, expectedResponse)

            let (readCopies, writeCopies) = client.stagingCopiedBytes
            @Expect(readCopies, 2)
            @Expect(writeCopies, 5)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func emptyOperationsAreImmediateAndHalfCloseFailsExplicitly(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        try {
            match (client.readSome(MutableByteSpan(Array<Byte>()))) {
                case ReadResult.Data(count) => @Expect(count, 0)
                case ReadResult.EndOfStream => @Expect(false)
            }
            @Expect(client.writeSome(ByteSpan(Array<Byte>())), 0)
            var unsupported = false
            try {
                client.shutdown(ShutdownDirection.Write)
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Unsupported => unsupported = true
                    case _ => ()
                }
            }
            @Expect(unsupported)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func cancellationWakesBlockedReadAndIsNeverReportedAsEof(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let source = CancellationSource()
        let started = SyncCounter(1)
        let result: Future<Bool> = spawn {
            started.dec()
            try {
                let _ = client.readSome(
                    MutableByteSpan(Array<Byte>(1, repeat: 0)),
                    context: OperationContext(cancellation: source.token)
                )
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => true
                    case _ => false
                }
            }
        }
        started.waitUntilZero()
        source.cancel()
        @Expect(result.get(Duration.second), true)
        @Expect(client.isClosed())
        server.close()
        listener.close()
    }

    @TestCase
    func listenerCloseWakesBlockedAcceptAsClosed(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let started = SyncCounter(1)
        let result: Future<Bool> = spawn {
            started.dec()
            try {
                let _ = listener.accept()
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => true
                    case _ => false
                }
            }
        }
        started.waitUntilZero()
        listener.close()
        @Expect(result.get(Duration.second), true)
    }

    @TestCase
    func preCancelledConnectDoesNotCreateASocket(): Unit {
        let source = CancellationSource()
        source.cancel()
        var cancelled = false
        try {
            let _ = StdNetTransport.connect(
                loopback(9),
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
    }

    @TestCase
    func peerGracefulCloseIsReportedAsEof(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        server.close()
        try {
            match (client.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))) {
                case ReadResult.EndOfStream => @Expect(true)
                case ReadResult.Data(_) => @Expect(false)
            }
        } finally {
            client.close()
            listener.close()
        }
    }

    @TestCase
    func deadlineBoundsBlockedReadWithoutClosingConnection(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        var timedOut = false
        try {
            let _ = client.readSome(
                MutableByteSpan(Array<Byte>(1, repeat: 0)),
                context: OperationContext(deadline: Some(Deadline.after(20 * Duration.millisecond)))
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => timedOut = true
                case _ => ()
            }
        }
        @Expect(timedOut)
        @Expect(!client.isClosed())
        client.close()
        server.close()
        listener.close()
    }

    @TestCase
    func concurrentReadsFailWithoutDisturbingTheActiveRead(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let source = CancellationSource()
        let active = spawn {
            try {
                let _ = client.readSome(
                    MutableByteSpan(Array<Byte>(1, repeat: 0)),
                    context: OperationContext(cancellation: source.token)
                )
            } catch (_: NetworkException) {
                ()
            }
        }
        @Expect(client.waitUntilReadActive(Duration.second))
        var concurrent = false
        try {
            let _ = client.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.ConcurrentOperation => concurrent = true
                case _ => ()
            }
        }
        @Expect(concurrent)
        source.cancel()
        active.get(Duration.second)
        client.close()
        server.close()
        listener.close()
    }
}
