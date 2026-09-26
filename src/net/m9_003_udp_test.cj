package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func m9003EndpointMatches(actual: ?api.NetworkEndpoint, expected: api.NetworkEndpoint): Bool {
    match ((actual, expected)) {
        case (Some(api.NetworkEndpoint.Internet(value)), api.NetworkEndpoint.Internet(endpoint)) => value == endpoint
        case _ => false
    }
}

private func m9003OptionalEndpointMatches(actual: ?api.NetworkEndpoint, expected: ?api.NetworkEndpoint): Bool {
    match ((actual, expected)) {
        case (Some(api.NetworkEndpoint.Internet(value)), Some(api.NetworkEndpoint.Internet(endpoint))) => value == endpoint
        case (None, None) => true
        case _ => false
    }
}

private func m9003StateIs(actual: SocketState, expected: SocketState): Bool {
    match ((actual, expected)) {
        case (SocketState.Open, SocketState.Open) => true
        case (SocketState.Closed, SocketState.Closed) => true
        case _ => false
    }
}

private func m9003Context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(3 * Duration.second)))
}

private func m9003Endpoint(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

private func m9003Local(socket: UdpSocket): api.NetworkEndpoint {
    socket.localEndpoint.getOrThrow()
}

private func m9003CodeIs(error: api.NetworkException, expected: api.NetworkErrorCode): Bool {
    match ((error.code, expected)) {
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) |
             (api.NetworkErrorCode.Closed, api.NetworkErrorCode.Closed) |
             (api.NetworkErrorCode.ConcurrentOperation, api.NetworkErrorCode.ConcurrentOperation) |
             (api.NetworkErrorCode.InvalidState, api.NetworkErrorCode.InvalidState) |
             (api.NetworkErrorCode.NotConnected, api.NetworkErrorCode.NotConnected) |
             (api.NetworkErrorCode.ResourceExhausted, api.NetworkErrorCode.ResourceExhausted) |
             (api.NetworkErrorCode.SystemFailure, api.NetworkErrorCode.SystemFailure) |
             (api.NetworkErrorCode.Unsupported, api.NetworkErrorCode.Unsupported) => true
        case _ => false
    }
}

private func m9003OptionErrorIs(error: api.NetworkException, code: api.NetworkErrorCode): Bool {
    let category = match (error.category) {
        case api.NetworkErrorCategory.Option => true
        case _ => false
    }
    let phase = match (error.phase) {
        case api.NetworkPhase.DatagramSend => true
        case _ => false
    }
    category && phase && m9003CodeIs(error, code)
}

private func m9003Group(last: UInt8): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv4, [239u8, 255u8, 250u8, last])
}

private func m9003V6Group(): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv6,
        [0xFFu8, 0x02u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
         0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 1u8])
}

@Test
class M9003UdpLifecycleTest {
    @TestCase
    func disconnectRetainsBindAndRestoresExplicitSendTo(): Unit {
        let first = UdpSocket.bind(m9003Endpoint(0))
        let second = UdpSocket.bind(m9003Endpoint(0))
        let sender = UdpSocket.bind(m9003Endpoint(0))
        let originalBind = sender.localEndpoint
        let firstPeer = m9003Local(first)
        let secondPeer = m9003Local(second)
        try {
            sender.connect(firstPeer, context: m9003Context())
            @Expect(sender.remoteEndpoint.isSome())
            @Expect(m9003EndpointMatches(sender.remoteEndpoint, firstPeer))
            @Expect(sender.send(api.ByteSpan([31u8]), context: m9003Context()), 1)
            @Expect(first.receive(2, context: m9003Context()).payload, [31u8])

            sender.disconnect(context: m9003Context())
            @Expect(sender.remoteEndpoint.isNone())
            @Expect(m9003OptionalEndpointMatches(sender.localEndpoint, originalBind))
            sender.disconnect(context: m9003Context())
            @Expect(sender.remoteEndpoint.isNone())

            let notConnected = @AssertThrows[api.NetworkException]({
                let _ = sender.send(api.ByteSpan([32u8]), context: m9003Context())
            })
            @Expect(m9003CodeIs(notConnected, api.NetworkErrorCode.NotConnected))
            @Expect(sender.sendTo(secondPeer, api.ByteSpan([33u8]), context: m9003Context()), 1)
            let received = second.receive(2, context: m9003Context())
            @Expect(received.payload, [33u8])
            @Expect(m9003OptionalEndpointMatches(received.source, originalBind))
            @Expect(m9003OptionalEndpointMatches(sender.localEndpoint, originalBind))
        } finally {
            sender.close()
            second.close()
            first.close()
        }
    }

    @TestCase
    func cancelledDisconnectDoesNotChangeTheSelectedPeer(): Unit {
        let peer = UdpSocket.bind(m9003Endpoint(0))
        let sender = UdpSocket.bind(m9003Endpoint(0))
        let endpoint = m9003Local(peer)
        try {
            sender.connect(endpoint, context: m9003Context())
            let cancelled = api.CancellationSource()
            cancelled.cancel()
            let failure = @AssertThrows[api.NetworkException]({
                sender.disconnect(context: api.OperationContext(cancellation: cancelled.token))
            })
            @Expect(m9003CodeIs(failure, api.NetworkErrorCode.Cancelled))
            @Expect(sender.remoteEndpoint.isSome())
            @Expect(m9003StateIs(sender.state, SocketState.Open))
            @Expect(m9003EndpointMatches(sender.remoteEndpoint, endpoint))
            sender.disconnect(context: m9003Context())
            @Expect(sender.remoteEndpoint.isNone())
        } finally {
            sender.close()
            peer.close()
        }
    }

    @TestCase
    func multicastMembershipIsFamilyCheckedKeyedAndBounded(): Unit {
        let options = [SocketOption.ReuseAddress(true)]
        let socket = UdpSocket.bind(m9003Endpoint(0), options: options, context: m9003Context())
        try {
            @Expect(socket.capabilities.multicast)
            var invalidAddress = false
            try {
                socket.joinMulticastGroup(
                    api.IpAddress(api.IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8]),
                    interfaceIndex: 1u32,
                    context: m9003Context())
            } catch (_: IllegalArgumentException) {
                invalidAddress = true
            }
            @Expect(invalidAddress)

            let wrongFamily = @AssertThrows[api.NetworkException]({
                socket.joinMulticastGroup(m9003V6Group(), interfaceIndex: 1u32, context: m9003Context())
            })
            @Expect(m9003OptionErrorIs(wrongFamily, api.NetworkErrorCode.Unsupported))

            var invalidIndex = false
            try {
                socket.joinMulticastGroup(m9003Group(90u8), interfaceIndex: 4294967295u32,
                    context: m9003Context())
            } catch (_: IllegalArgumentException) {
                invalidIndex = true
            }
            @Expect(invalidIndex)

            let nativeFailure = @AssertThrows[api.NetworkException]({
                socket.joinMulticastGroup(m9003Group(91u8), interfaceIndex: 2147483647u32,
                    context: m9003Context())
            })
            @Expect(m9003OptionErrorIs(nativeFailure, api.NetworkErrorCode.SystemFailure))
            @Expect(m9003StateIs(socket.state, SocketState.Open))

            for (last in 1..17) {
                socket.joinMulticastGroup(m9003Group(UInt8(last)), interfaceIndex: 1u32,
                    context: m9003Context())
            }
            let duplicate = @AssertThrows[api.NetworkException]({
                socket.joinMulticastGroup(m9003Group(1u8), interfaceIndex: 1u32,
                    context: m9003Context())
            })
            @Expect(m9003OptionErrorIs(duplicate, api.NetworkErrorCode.InvalidState))
            let wrongInterface = @AssertThrows[api.NetworkException]({
                socket.leaveMulticastGroup(m9003Group(1u8), interfaceIndex: 2u32,
                    context: m9003Context())
            })
            @Expect(m9003OptionErrorIs(wrongInterface, api.NetworkErrorCode.InvalidState))
            let exhausted = @AssertThrows[api.NetworkException]({
                socket.joinMulticastGroup(m9003Group(17u8), interfaceIndex: 1u32,
                    context: m9003Context())
            })
            @Expect(m9003OptionErrorIs(exhausted, api.NetworkErrorCode.ResourceExhausted))

            socket.leaveMulticastGroup(m9003Group(1u8), interfaceIndex: 1u32,
                context: m9003Context())
            socket.joinMulticastGroup(m9003Group(17u8), interfaceIndex: 1u32,
                context: m9003Context())
            socket.close()
            socket.close()
            @Expect(m9003StateIs(socket.state, SocketState.Closed))
            let closed = @AssertThrows[api.NetworkException]({
                socket.leaveMulticastGroup(m9003Group(17u8), interfaceIndex: 1u32,
                    context: m9003Context())
            })
            @Expect(m9003CodeIs(closed, api.NetworkErrorCode.Closed))
        } finally {
            socket.close()
        }
    }
}
