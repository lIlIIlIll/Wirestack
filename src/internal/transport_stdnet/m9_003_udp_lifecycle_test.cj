package wirestack.internal.transport_stdnet

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func m9003InternalEndpoint(): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0)
}

private func m9003InternalCodeIs(error: api.NetworkException, expected: api.NetworkErrorCode): Bool {
    match ((error.code, expected)) {
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) |
             (api.NetworkErrorCode.Closed, api.NetworkErrorCode.Closed) |
             (api.NetworkErrorCode.ConcurrentOperation, api.NetworkErrorCode.ConcurrentOperation) => true
        case _ => false
    }
}
private func m9003EndpointMatches(actual: ?api.NetworkEndpoint, expected: api.NetworkEndpoint): Bool {
    match ((actual, expected)) {
        case (Some(api.NetworkEndpoint.Internet(value)), api.NetworkEndpoint.Internet(endpoint)) => value == endpoint
        case _ => false
    }
}

@Test
class M9003UdpLifecycleAdapterTest {
    @TestCase
    func disconnectRejectsActiveReceiveAndCancellationOwnsTheTerminalClose(): Unit {
        let receiver = StdNetDatagramSocket.bind(m9003InternalEndpoint())
        let sender = StdNetDatagramSocket.bind(m9003InternalEndpoint())
        let peer = receiver.localEndpoint
        try {
            sender.connect(peer, context: api.OperationContext.background())
            let cancellation = api.CancellationSource()
            let receiving: Future<Bool> = spawn {
                try {
                    let _ = sender.receive(1,
                        context: api.OperationContext(cancellation: cancellation.token))
                    false
                } catch (error: api.NetworkException) {
                    m9003InternalCodeIs(error, api.NetworkErrorCode.Cancelled)
                }
            }
            @Assert(sender.waitUntilReceiveActive(2 * Duration.second))

            let concurrent = @AssertThrows[api.NetworkException]({ sender.disconnect() })
            @Expect(m9003InternalCodeIs(concurrent, api.NetworkErrorCode.ConcurrentOperation))
            @Expect(sender.remoteEndpoint.isSome())
            @Expect(m9003EndpointMatches(sender.remoteEndpoint, peer))

            cancellation.cancel()
            @Expect(receiving.get(2 * Duration.second), true)
            @Expect(sender.isClosed())
            sender.close()
            sender.abort()
            @Expect(sender.isClosed())
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func closeDuringBlockedReceiveCompletesOnceWithClosedState(): Unit {
        let receiver = StdNetDatagramSocket.bind(m9003InternalEndpoint())
        let receiving: Future<Bool> = spawn {
            try {
                let _ = receiver.receive(1,
                    context: api.OperationContext(deadline: Some(api.Deadline.after(5 * Duration.second))))
                false
            } catch (error: api.NetworkException) {
                m9003InternalCodeIs(error, api.NetworkErrorCode.Closed)
            }
        }
        @Assert(receiver.waitUntilReceiveActive(2 * Duration.second))
        receiver.close()
        receiver.close()
        @Expect(receiving.get(2 * Duration.second), true)
        @Expect(receiver.isClosed())
    }
}
