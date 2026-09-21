package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func m8Loopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func m8Internet(endpoint: ?NetworkEndpoint): api.SocketEndpoint {
    match (endpoint) {
        case Some(NetworkEndpoint.Internet(value)) => value
        case _ => throw Exception("expected an Internet endpoint")
    }
}

private func m8ErrorCode(operation: () -> Unit): ?api.NetworkErrorCode {
    try {
        operation()
        None<api.NetworkErrorCode>
    } catch (error: api.NetworkException) {
        Some(error.code)
    }
}

@Test
class NetworkSocketExecutionTest {
    @TestCase
    func tcpLoopbackPreservesPartialAndExactHelpers(): Unit {
        let listener = TcpListener.bind(m8Loopback(0), backlog: 8)
        let endpoint = m8Internet(listener.localEndpoint)
        let accepted: Future<TcpStream> = spawn { listener.accept() }
        let client = TcpStream.connect(endpoint, context: api.OperationContext(
            deadline: Some(api.Deadline.after(3 * Duration.second))
        ))
        let server = accepted.get(3 * Duration.second)
        try {
            @Expect(client.capabilities.nonBlocking)
            @Expect(client.capabilities.closeOnExec)

            let payload = Array<Byte>(20 * 1024, repeat: 0x5au8)
            client.writeAll(api.ByteSpan(payload), context: api.OperationContext(
                deadline: Some(api.Deadline.after(3 * Duration.second))
            ))
            let received = Array<Byte>(payload.size, repeat: 0u8)
            server.readExact(api.MutableByteSpan(received), context: api.OperationContext(
                deadline: Some(api.Deadline.after(3 * Duration.second))
            ))
            @Expect(received, payload)

            server.writeAll(api.ByteSpan(payload), context: api.OperationContext.background())
            let echoed = Array<Byte>(payload.size, repeat: 0u8)
            var firstCount = 0
            match (client.read(api.MutableByteSpan(echoed), context: api.OperationContext.background())) {
                case ReadResult.Data(count) => firstCount = count
                case ReadResult.EndOfStream => @Fail("loopback closed before data")
            }
            @Expect(firstCount > 0)
            @Expect(firstCount <= 16 * 1024)
            if (firstCount < payload.size) {
                let remaining = api.MutableByteSpan(echoed, offset: firstCount,
                    length: payload.size - firstCount)
                client.readExact(remaining, context: api.OperationContext.background())
            }
            @Expect(echoed, payload)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func cancellationStopsOnlyTheAffectedOperation(): Unit {
        let listener = TcpListener.bind(m8Loopback(0), backlog: 4)
        let endpoint = m8Internet(listener.localEndpoint)
        let accepted: Future<TcpStream> = spawn { listener.accept() }
        let client = TcpStream.connect(endpoint)
        let server = accepted.get(3 * Duration.second)
        let source = api.CancellationSource()
        let cancelledRead: Future<?api.NetworkErrorCode> = spawn {
            =>
            m8ErrorCode({
                =>
                let destination = Array<Byte>(1, repeat: 0u8)
                let _ = server.read(api.MutableByteSpan(destination), context: api.OperationContext(
                    cancellation: source.token
                ))
            })
        }
        try {
            sleep(40 * Duration.millisecond)
            source.cancel()
            match (cancelledRead.get(3 * Duration.second)) {
                case Some(api.NetworkErrorCode.Cancelled) => ()
                case _ => @Fail("cancelled read did not return Cancelled")
            }
            @Expect(!server.isClosed())

            // The stream remains usable after a cancelled operation.
            client.write(api.ByteSpan([0x42u8]), context: api.OperationContext.background())
            let received = Array<Byte>(1, repeat: 0u8)
            match (server.read(api.MutableByteSpan(received), context: api.OperationContext.background())) {
                case ReadResult.Data(count) => @Expect(count, 1)
                case ReadResult.EndOfStream => @Fail("cancelled read closed the stream")
            }
            @Expect(received, [0x42u8])
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func closeWakesReadAndSameDirectionOperationsAreExclusive(): Unit {
        let listener = TcpListener.bind(m8Loopback(0), backlog: 4)
        let endpoint = m8Internet(listener.localEndpoint)
        let accepted: Future<TcpStream> = spawn { listener.accept() }
        let client = TcpStream.connect(endpoint)
        let server = accepted.get(3 * Duration.second)
        let firstRead: Future<?api.NetworkErrorCode> = spawn {
            =>
            m8ErrorCode({
                =>
                let destination = Array<Byte>(1, repeat: 0u8)
                let _ = server.read(api.MutableByteSpan(destination), context: api.OperationContext.background())
            })
        }
        try {
            sleep(40 * Duration.millisecond)
            let concurrent = m8ErrorCode({
                =>
                let destination = Array<Byte>(1, repeat: 0u8)
                let _ = server.read(api.MutableByteSpan(destination), context: api.OperationContext.background())
            })
            match (concurrent) {
                case Some(api.NetworkErrorCode.ConcurrentOperation) => ()
                case _ => @Fail("same-direction read was not rejected")
            }
            server.close()
            match (firstRead.get(3 * Duration.second)) {
                case Some(api.NetworkErrorCode.Closed) => ()
                case _ => @Fail("close did not wake the active read")
            }
            server.close()
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func udpLoopbackPreservesAtomicityAndReportsTruncation(): Unit {
        let sender = DatagramSocket.bind()
        let receiver = DatagramSocket.bind()
        let receiverEndpoint = m8Internet(receiver.localEndpoint)
        try {
            let payload: Array<Byte> = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8]
            @Expect(sender.sendTo(receiverEndpoint, api.ByteSpan(payload)), payload.size)
            let truncated = receiver.receive(4, context: api.OperationContext(
                deadline: Some(api.Deadline.after(3 * Duration.second))
            ))
            @Expect(truncated.payload, [1u8, 2u8, 3u8, 4u8])
            @Expect(truncated.truncated)

            let exact: Array<Byte> = [9u8, 10u8, 11u8, 12u8]
            @Expect(sender.sendTo(receiverEndpoint, api.ByteSpan(exact)), exact.size)
            let complete = receiver.receive(4)
            @Expect(complete.payload, exact)
            @Expect(!complete.truncated)
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func datagramBoundsRejectOversizedMessages(): Unit {
        let socket = DatagramSocket.bind()
        try {
            let oversized = Array<Byte>(65508, repeat: 0u8)
            let code = m8ErrorCode({
                =>
                let _ = socket.sendTo(m8Loopback(9), api.ByteSpan(oversized))
            })
            match (code) {
                case Some(api.NetworkErrorCode.MessageTooLarge) => ()
                case _ => @Fail("oversized datagram was not rejected")
            }
        } finally {
            socket.close()
        }
    }
}
