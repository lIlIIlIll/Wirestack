package wirestack.internal.transport_stdnet

import std.sync.SyncCounter
import std.env.getVariable
import std.runtime.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

private func loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private func net06CancellationIterations(): Int64 {
    match (getVariable("WIRESTACK_NET06_ITERATIONS")) {
        case Some(value) =>
            let parsed = Int64.parse(value)
            if (parsed <= 0) { throw IllegalArgumentException("WIRESTACK_NET06_ITERATIONS must be positive") }
            parsed
        case None => 3
    }
}

private func net06CancellationHeapSample(index: Int64): Unit {
    gc(heavy: true)
    println("NET06_HEAP scenario=cancellation index=${index} usedHeapBytes=${getUsedHeapSize()}")
}

@Test
class Net06CancellationGateTest {
    @TestCase
    func cancelledReadsReleaseSocketsWaitersAndTasks(): Unit {
        let requested = net06CancellationIterations()
        let checkpointEvery = if (requested < 20) { requested } else { requested / 20 }
        let listener = StdNetTransportListener.bind(loopback(0), backlog: 16)
        var completed: Int64 = 0
        var joinedTasks: Int64 = 0
        var activeReads: Int64 = 0
        net06CancellationHeapSample(0)
        try {
            for (index in 0..requested) {
                let accepted: Future<DuplexTransport> = spawn { listener.accept() }
                let client = StdNetTransport.connect(listener.localEndpoint)
                let server = accepted.get(5 * Duration.second)
                joinedTasks += 1
                let source = CancellationSource()
                try {
                    let cancelled: Future<Bool> = spawn {
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
                    if (!client.waitUntilReadActive(5 * Duration.second)) {
                        throw Exception("NET06 cancellation read did not become active")
                    }
                    source.cancel()
                    if (!cancelled.get(5 * Duration.second)) {
                        throw Exception("NET06 cancellation did not produce Cancelled")
                    }
                    joinedTasks += 1
                    if (client.waitUntilReadActive(Duration.Zero)) { activeReads += 1 }
                    if (!client.isClosed()) {
                        throw Exception("NET06 cancelled transport remained open")
                    }
                    completed += 1
                } finally {
                    client.close()
                    server.close()
                }
                let observed = index + 1
                if (observed % checkpointEvery == 0 || observed == requested) {
                    net06CancellationHeapSample(observed)
                }
            }
        } finally {
            listener.close()
        }
        let backgroundTasks = requested * 2 - joinedTasks
        println(
            "NET06_CANCELLATION requested=${requested} completed=${completed} " +
            "joinedTasks=${joinedTasks} activeReads=${activeReads} " +
            "backgroundTasks=${backgroundTasks}"
        )
        @Assert(completed, requested)
        @Assert(joinedTasks, requested * 2)
        @Assert(activeReads, 0)
        @Assert(backgroundTasks, 0)
    }
}

@Test
class StdNetTransportTest {
    @TestCase
    func writeSomeIsPartialAndReusesBoundedConnectionStaging(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0), stagingBufferSize: 3)
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint, stagingBufferSize: 3)
        let server = accepted.get(Duration.second)
        try {
            @Expect(client.writeSome(ByteSpan([1, 2, 3, 4, 5])), 3)
            let first = Array<Byte>(3, repeat: 0)
            readExact(server, MutableByteSpan(first))
            let expectedFirst: Array<Byte> = [1, 2, 3]
            @Expect(first, expectedFirst)

            @Expect(client.writeSome(ByteSpan([6, 7, 8, 9])), 3)
            let second = Array<Byte>(3, repeat: 0)
            readExact(server, MutableByteSpan(second))
            let expectedSecond: Array<Byte> = [6, 7, 8]
            @Expect(second, expectedSecond)

            let tailSource: Array<Byte> = [0, 10, 11, 0]
            @Expect(client.writeSome(ByteSpan(tailSource, offset: 1, length: 2)), 2)
            let tail = Array<Byte>(2, repeat: 0)
            readExact(server, MutableByteSpan(tail))
            let expectedTail: Array<Byte> = [10, 11]
            @Expect(tail, expectedTail)

            let (_, writeCopies) = client.stagingCopiedBytes
            @Expect(writeCopies, 8)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func wholeArrayReadAndWriteBypassStagingForATypicalTlsRecord(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        try {
            let record = Array<Byte>(16 * 1024, repeat: 0x5a)
            @Expect(client.writeSome(ByteSpan(record)), 16 * 1024)
            let received = Array<Byte>(16 * 1024, repeat: 0)
            readExact(server, MutableByteSpan(received))
            @Expect(received, record)
            writeAll(server, ByteSpan(received))
            let echoed = Array<Byte>(16 * 1024, repeat: 0)
            readExact(client, MutableByteSpan(echoed))
            @Expect(echoed, record)
            let (clientReadCopies, clientWriteCopies) = client.stagingCopiedBytes
            @Expect(clientReadCopies, 0)
            @Expect(clientWriteCopies, 0)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func subrangesRetainBoundedStagingAndCopyAccounting(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0), stagingBufferSize: 3)
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint, stagingBufferSize: 3)
        let server = accepted.get(Duration.second)
        try {
            let source: Array<Byte> = [0, 1, 2, 3, 0]
            @Expect(client.writeSome(ByteSpan(source, offset: 1, length: 3)), 3)

            let destination = Array<Byte>(5, repeat: 0)
            match (server.readSome(
                MutableByteSpan(destination, offset: 1, length: 3),
                context: OperationContext.background()
            )) {
                case ReadResult.Data(count) => @Expect(count, 3)
                case ReadResult.EndOfStream => @Expect(false)
            }
            let expected: Array<Byte> = [0, 1, 2, 3, 0]
            @Expect(destination, expected)

            writeAll(server, ByteSpan(destination, offset: 1, length: 3))
            let echoed = Array<Byte>(5, repeat: 0)
            match (client.readSome(MutableByteSpan(echoed, offset: 1, length: 3))) {
                case ReadResult.Data(count) => @Expect(count, 3)
                case ReadResult.EndOfStream => @Expect(false)
            }
            @Expect(echoed, expected)

            let (clientReadCopies, clientWriteCopies) = client.stagingCopiedBytes
            @Expect(clientWriteCopies, 3)
            @Expect(clientReadCopies, 3)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

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
            @Expect(readCopies, 0)
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
        let result: Future<Bool> = spawn {
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
        // The spawned task may not have entered readSome when it starts. Gate on
        // the adapter's actual read lifecycle so this exercises active-I/O cancellation.
        @Expect(client.waitUntilReadActive(Duration.second))
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

    @TestCase
    func happyEyeballsComposesWithTheDefaultStdNetFactory(): Unit {
        let listener = StdNetTransportListener.bind(loopback(0))
        let host = HostName("loopback.test")
        let resolver = StaticResolver(
            ResolveResult([listener.localEndpoint.address], host, ResolverSource.Static)
        )
        let connector = HappyEyeballsConnector(resolver, StdNetTransportFactory())
        let accepted = spawn { listener.accept() }
        let connected = connector.connect(host, listener.localEndpoint.port)
        let server = accepted.get(Duration.second)
        try {
            @Expect(connected.diagnostics.winner, listener.localEndpoint)
            @Expect(connected.diagnostics.attempts.size, 1)
            @Expect(connected.diagnostics.attempts[0].won)
        } finally {
            connected.transport.close()
            server.close()
            listener.close()
        }
    }
}
