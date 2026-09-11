package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func m8002Loopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func m8002DeadlineContext(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(Duration.second)))
}

private func m8002InternetEndpoint(socket: UdpSocket): api.NetworkEndpoint {
    socket.localEndpoint.getOrThrow()
}

private func m8002IsInternetEndpoint(
    actual: ?api.NetworkEndpoint,
    expected: api.SocketEndpoint
): Bool {
    match (actual) {
        case Some(api.NetworkEndpoint.Internet(value)) => value == expected
        case _ => false
    }
}

private func m8002SocketEndpoint(endpoint: api.NetworkEndpoint): api.SocketEndpoint {
    match (endpoint) {
        case api.NetworkEndpoint.Internet(value) => value
        case _ => throw IllegalStateException("expected an Internet endpoint")
    }
}
private func m8002CodeIs(
    error: api.NetworkException,
    expected: api.NetworkErrorCode
): Bool {
    match ((error.code, expected)) {
        case (api.NetworkErrorCode.Unsupported, api.NetworkErrorCode.Unsupported) => true
        case (api.NetworkErrorCode.MessageTooLarge, api.NetworkErrorCode.MessageTooLarge) => true
        case (api.NetworkErrorCode.NotConnected, api.NetworkErrorCode.NotConnected) => true
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) => true
        case (api.NetworkErrorCode.TimedOut, api.NetworkErrorCode.TimedOut) => true
        case (api.NetworkErrorCode.Closed, api.NetworkErrorCode.Closed) => true
        case _ => false
    }
}

private func m8002StateIs(actual: SocketState, expected: SocketState): Bool {
    match ((actual, expected)) {
        case (SocketState.Open, SocketState.Open) => true
        case (SocketState.Closed, SocketState.Closed) => true
        case (SocketState.Aborted, SocketState.Aborted) => true
        case (SocketState.Failed, SocketState.Failed) => true
        case _ => false
    }
}

@Test
class M8002UdpSocketTest {
    @TestCase
    func datagramBoundariesAndOwnedPayloadSurviveScratchReuse(): Unit {
        let receiver = UdpSocket.bind(m8002Loopback(0))
        let sender = UdpSocket.bind(m8002Loopback(0))
        try {
            let destination = m8002InternetEndpoint(receiver)
            let framed = [0xFFu8, 1u8, 2u8, 0xFFu8]
            @Expect(
                sender.sendTo(destination, api.ByteSpan(framed, offset: 1, length: 2)),
                2
            )
            @Expect(sender.sendTo(destination, api.ByteSpan([3u8, 4u8, 5u8])), 3)

            let first = receiver.receive(8, context: m8002DeadlineContext())
            let second = receiver.receive(8, context: m8002DeadlineContext())
            @Expect(first.payload, [1u8, 2u8])
            @Expect(!first.truncated)
            @Expect(second.payload, [3u8, 4u8, 5u8])
            @Expect(!second.truncated)

            let senderEndpoint = m8002SocketEndpoint(m8002InternetEndpoint(sender))
            @Expect(m8002IsInternetEndpoint(first.source, senderEndpoint))
            @Expect(m8002IsInternetEndpoint(second.source, senderEndpoint))

            @Expect(sender.sendTo(destination, api.ByteSpan([9u8, 8u8])), 2)
            let third = receiver.receive(8, context: m8002DeadlineContext())
            @Expect(third.payload, [9u8, 8u8])
            @Expect(first.payload, [1u8, 2u8])
            @Expect(second.payload, [3u8, 4u8, 5u8])
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func exactCapacityAndTruncationDiscardOnlyTheCurrentDatagramTail(): Unit {
        let receiver = UdpSocket.bind(m8002Loopback(0))
        let sender = UdpSocket.bind(m8002Loopback(0))
        try {
            let destination = m8002InternetEndpoint(receiver)
            @Expect(sender.sendTo(destination, api.ByteSpan([1u8, 2u8, 3u8])), 3)
            let exact = receiver.receive(3, context: m8002DeadlineContext())
            @Expect(exact.payload, [1u8, 2u8, 3u8])
            @Expect(!exact.truncated)

            @Expect(sender.sendTo(destination, api.ByteSpan([4u8, 5u8, 6u8, 7u8])), 4)
            @Expect(sender.sendTo(destination, api.ByteSpan([8u8])), 1)
            let truncated = receiver.receive(3, context: m8002DeadlineContext())
            let following = receiver.receive(3, context: m8002DeadlineContext())
            @Expect(truncated.payload, [4u8, 5u8, 6u8])
            @Expect(truncated.truncated)
            @Expect(following.payload, [8u8])
            @Expect(!following.truncated)
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func connectedSocketSelectsNativePeerAndFiltersOtherSenders(): Unit {
        let receiver = UdpSocket.bind(m8002Loopback(0))
        let selected = UdpSocket.bind(m8002Loopback(0))
        let other = UdpSocket.bind(m8002Loopback(0))
        try {
            let selectedEndpoint = m8002InternetEndpoint(selected)
            let destination = m8002InternetEndpoint(receiver)
            receiver.connect(selectedEndpoint, context: m8002DeadlineContext())
            @Expect(m8002IsInternetEndpoint(
                receiver.remoteEndpoint,
                m8002SocketEndpoint(selectedEndpoint)
            ))
            @Expect(receiver.send(api.ByteSpan([0x33u8])), 1)
            @Expect(
                selected.receive(1, context: m8002DeadlineContext()).payload,
                [0x33u8]
            )


            @Expect(other.sendTo(destination, api.ByteSpan([0xEEu8])), 1)
            @Expect(selected.sendTo(destination, api.ByteSpan([0x11u8, 0x22u8])), 2)
            let received = receiver.receive(8, context: m8002DeadlineContext())
            @Expect(received.payload, [0x11u8, 0x22u8])
            @Expect(m8002IsInternetEndpoint(
                received.source,
                m8002SocketEndpoint(selectedEndpoint)
            ))
        } finally {
            other.close()
            selected.close()
            receiver.close()
        }
    }

    @TestCase
    func invalidAndUnsupportedInputsLeaveSocketReusable(): Unit {
        let receiver = UdpSocket.bind(m8002Loopback(0))
        let sender = UdpSocket.bind(m8002Loopback(0))
        try {
            let destination = m8002InternetEndpoint(receiver)
            @Expect(!sender.capabilities.zeroLengthDatagramSend)
            @AssertThrows[IllegalArgumentException](receiver.receive(0))
            @AssertThrows[IllegalArgumentException](receiver.receive(65508))

            let emptyError = @AssertThrows[api.NetworkException]({
                let _ = sender.sendTo(destination, api.ByteSpan(Array<Byte>()))
            })
            @Expect(m8002CodeIs(emptyError, api.NetworkErrorCode.Unsupported))
            @Expect(m8002StateIs(sender.state, SocketState.Open))
            @Expect(!sender.isClosed())

            let oversized = Array<Byte>(65508, repeat: 0u8)
            let sizeError = @AssertThrows[api.NetworkException]({
                let _ = sender.sendTo(destination, api.ByteSpan(oversized))
            })
            @Expect(m8002CodeIs(sizeError, api.NetworkErrorCode.MessageTooLarge))
            @Expect(m8002StateIs(sender.state, SocketState.Open))

            let unixEndpoint = api.NetworkEndpoint.Unix(api.UnixEndpoint.unnamed())
            let endpointError = @AssertThrows[api.NetworkException]({
                let _ = sender.sendTo(unixEndpoint, api.ByteSpan([1u8]))
            })
            @Expect(m8002CodeIs(endpointError, api.NetworkErrorCode.Unsupported))
            @Expect(m8002StateIs(sender.state, SocketState.Open))
            let connectEndpointError = @AssertThrows[api.NetworkException]({
                sender.connect(unixEndpoint)
            })
            @Expect(m8002CodeIs(connectEndpointError, api.NetworkErrorCode.Unsupported))
            @Expect(m8002StateIs(sender.state, SocketState.Open))


            let missingPeer = @AssertThrows[api.NetworkException]({
                let _ = sender.send(api.ByteSpan([2u8]))
            })
            @Expect(m8002CodeIs(missingPeer, api.NetworkErrorCode.NotConnected))
            @Expect(m8002StateIs(sender.state, SocketState.Open))

            @Expect(sender.sendTo(destination, api.ByteSpan([7u8])), 1)
            @Expect(
                receiver.receive(1, context: m8002DeadlineContext()).payload,
                [7u8]
            )
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func cancellationDeadlineCloseAndAbortRetainDistinctState(): Unit {
        let receiver = UdpSocket.bind(m8002Loopback(0))
        let sender = UdpSocket.bind(m8002Loopback(0))
        try {
            let cancelled = api.CancellationSource()
            cancelled.cancel()
            let cancelledError = @AssertThrows[api.NetworkException]({
                let _ = receiver.receive(
                    1,
                    context: api.OperationContext(cancellation: cancelled.token)
                )
            })
            @Expect(m8002CodeIs(cancelledError, api.NetworkErrorCode.Cancelled))
            @Expect(m8002StateIs(receiver.state, SocketState.Open))
            let cancelledClose = @AssertThrows[api.NetworkException]({
                receiver.close(
                    context: api.OperationContext(cancellation: cancelled.token)
                )
            })
            @Expect(m8002CodeIs(cancelledClose, api.NetworkErrorCode.Cancelled))
            @Expect(m8002StateIs(receiver.state, SocketState.Open))


            let expiredError = @AssertThrows[api.NetworkException]({
                let _ = receiver.receive(
                    1,
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.Zero))
                    )
                )
            })
            @Expect(m8002CodeIs(expiredError, api.NetworkErrorCode.TimedOut))
            @Expect(m8002StateIs(receiver.state, SocketState.Open))
            let expiredClose = @AssertThrows[api.NetworkException]({
                receiver.close(
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.Zero))
                    )
                )
            })
            @Expect(m8002CodeIs(expiredClose, api.NetworkErrorCode.TimedOut))
            @Expect(m8002StateIs(receiver.state, SocketState.Open))


            let timeoutError = @AssertThrows[api.NetworkException]({
                let _ = receiver.receive(
                    1,
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(20 * Duration.millisecond))
                    )
                )
            })
            @Expect(m8002CodeIs(timeoutError, api.NetworkErrorCode.TimedOut))
            @Expect(m8002StateIs(receiver.state, SocketState.Open))
            @Expect(!receiver.isClosed())
            @Expect(sender.sendTo(m8002InternetEndpoint(receiver), api.ByteSpan([6u8])), 1)
            @Expect(
                receiver.receive(1, context: m8002DeadlineContext()).payload,
                [6u8]
            )

            receiver.close()
            receiver.close(context: api.OperationContext(cancellation: cancelled.token))
            @Expect(m8002StateIs(receiver.state, SocketState.Closed))
            @Expect(receiver.isClosed())
            let closedError = @AssertThrows[api.NetworkException]({
                let _ = receiver.receive(1)
            })
            @Expect(m8002CodeIs(closedError, api.NetworkErrorCode.Closed))
        } finally {
            sender.close()
            receiver.close()
        }

        let aborted = UdpSocket.bind(m8002Loopback(0))
        aborted.abort(reason: Some(api.AbortReason.ApplicationAbort))
        @Expect(m8002StateIs(aborted.state, SocketState.Aborted))
        @Expect(aborted.isClosed())
        aborted.close()
        @Expect(m8002StateIs(aborted.state, SocketState.Aborted))
    }
}
