package wirestack.internal.transport_stdnet

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func m127FastPathLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private func m127ReadByte(transport: DuplexTransport, context: OperationContext): Byte {
    let bytes = Array<Byte>(1, repeat: 0)
    match (transport.readSome(MutableByteSpan(bytes), context: context)) {
        case ReadResult.Data(count) =>
            @Expect(count, 1)
            bytes[0]
        case ReadResult.EndOfStream =>
            @Expect(false)
            0
    }
}

@Test
class M127BackgroundFastPathTest {
    @TestCase
    func backgroundAndObservedPathsTransferEquivalentData(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let background = OperationContext.background()
        let observed = OperationContext(trace: Some(NetworkTraceContext("m1-027-equivalence")))
        try {
            @Expect(client.writeSome(ByteSpan([11]), context: background), 1)
            @Expect(m127ReadByte(server, observed), 11)

            @Expect(client.writeSome(ByteSpan([22]), context: observed), 1)
            @Expect(m127ReadByte(server, background), 22)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func backgroundPeerCloseRemainsEof(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
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
    func backgroundLocalCloseRaceRemainsClosed(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let result: Future<Bool> = spawn {
            try {
                let _ = client.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => true
                    case _ => false
                }
            }
        }
        @Expect(client.waitUntilReadActive(Duration.second))
        client.close()
        @Expect(result.get(Duration.second))
        server.close()
        listener.close()
    }

    @TestCase
    func backgroundStillRejectsConcurrentReaders(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let active: Future<Bool> = spawn {
            try {
                let _ = client.readSome(MutableByteSpan(Array<Byte>(1, repeat: 0)))
                false
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => true
                    case _ => false
                }
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
        client.close()
        @Expect(active.get(Duration.second))
        server.close()
        listener.close()
    }

    @TestCase
    func cancellableAndDeadlineContextsRetainGenericChecks(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let source = CancellationSource()
        source.cancel()
        var cancelled = false
        try {
            let _ = client.readSome(
                MutableByteSpan(Array<Byte>(1, repeat: 0)),
                context: OperationContext(cancellation: source.token)
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)

        var timedOut = false
        try {
            let _ = client.readSome(
                MutableByteSpan(Array<Byte>(1, repeat: 0)),
                context: OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
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
    func deadlineTimeoutIsClearedBeforeBackgroundRead(): Unit {
        let listener = StdNetTransportListener.bind(m127FastPathLoopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        var timedOut = false
        try {
            let _ = client.readSome(
                MutableByteSpan(Array<Byte>(1, repeat: 0)),
                context: OperationContext(
                    deadline: Some(Deadline.after(20 * Duration.millisecond))
                )
            )
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.TimedOut => timedOut = true
                case _ => ()
            }
        }
        @Expect(timedOut)
        @Expect(
            server.writeSome(ByteSpan([33]), context: OperationContext.background()),
            1
        )
        @Expect(m127ReadByte(client, OperationContext.background()), 33)
        client.close()
        server.close()
        listener.close()
    }
}
