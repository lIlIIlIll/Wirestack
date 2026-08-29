package wirestack.internal.transport_stdnet

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func listenerLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private func listenerErrorCoordinates(error: NetworkException): Bool {
    let categoryMatches = match (error.category) {
        case NetworkErrorCategory.Accept => true
        case _ => false
    }
    let phaseMatches = match (error.phase) {
        case NetworkPhase.ServerAccept => true
        case _ => false
    }
    categoryMatches && phaseMatches && error.nativeCode.isNone() &&
        error.localEndpoint.isSome()
}

private func listenerCancelled(error: NetworkException): Bool {
    if (!listenerErrorCoordinates(error)) { return false }
    match (error.code) {
        case NetworkErrorCode.Cancelled => true
        case _ => false
    }
}

private func listenerTimedOut(error: NetworkException): Bool {
    if (!listenerErrorCoordinates(error)) { return false }
    match (error.code) {
        case NetworkErrorCode.TimedOut => true
        case _ => false
    }
}

private func listenerClosed(error: NetworkException): Bool {
    if (!listenerErrorCoordinates(error)) { return false }
    match (error.code) {
        case NetworkErrorCode.Closed => true
        case _ => false
    }
}

@Test
class StdNetTransportListenerTest {
    @TestCase
    func listenerRejectsOutOfRangeBacklogBeforeBinding(): Unit {
        @AssertThrows[IllegalArgumentException](StdNetTransportListener.bind(listenerLoopback(0), backlog: 0))
        @AssertThrows[IllegalArgumentException](StdNetTransportListener.bind(listenerLoopback(0), backlog: -1))
        @AssertThrows[IllegalArgumentException](StdNetTransportListener.bind(listenerLoopback(0), backlog: 65536))
    }

    @TestCase
    func listenerPreCancelledAndExpiredAcceptsFailFast(): Unit {
        let listener = StdNetTransportListener.bind(listenerLoopback(0), backlog: 1)
        let source = CancellationSource()
        source.cancel()
        try {
            var cancelled = false
            try {
                let _ = listener.accept(OperationContext(cancellation: source.token))
            } catch (error: NetworkException) {
                cancelled = listenerCancelled(error)
            }
            @Expect(cancelled)
            @Expect(!listener.isClosed())

            var timedOut = false
            try {
                let _ = listener.accept(
                    OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
                )
            } catch (error: NetworkException) {
                timedOut = listenerTimedOut(error)
            }
            @Expect(timedOut)
            @Expect(!listener.isClosed())
        } finally {
            listener.close()
        }
    }

    @TestCase
    func listenerDeadlineBoundsBlockedAcceptAndListenerRemainsUsable(): Unit {
        let listener = StdNetTransportListener.bind(listenerLoopback(0), backlog: 1)
        try {
            var timedOut = false
            try {
                let _ = listener.accept(
                    OperationContext(deadline: Some(Deadline.after(20 * Duration.millisecond)))
                )
            } catch (error: NetworkException) {
                timedOut = listenerTimedOut(error)
            }
            @Expect(timedOut)
            @Expect(!listener.isClosed())

            let accepted = spawn { listener.accept() }
            @Assert(listener.waitUntilAcceptActive(Duration.second))
            let client = StdNetTransport.connect(listener.localEndpoint)
            let server = accepted.get(Duration.second)
            client.close()
            server.close()
        } finally {
            listener.close()
        }
    }

    @TestCase
    func listenerCancellationWakesActiveAcceptAndListenerRemainsUsable(): Unit {
        let listener = StdNetTransportListener.bind(listenerLoopback(0), backlog: 1)
        try {
            let source = CancellationSource()
            let result: Future<Bool> = spawn {
                try {
                    let _ = listener.accept(OperationContext(cancellation: source.token))
                    false
                } catch (error: NetworkException) {
                    listenerCancelled(error)
                }
            }
            @Assert(listener.waitUntilAcceptActive(Duration.second))
            source.cancel()
            @Expect(result.get(Duration.second), true)
            @Expect(!listener.isClosed())

            let accepted = spawn { listener.accept() }
            @Assert(listener.waitUntilAcceptActive(Duration.second))
            let client = StdNetTransport.connect(listener.localEndpoint)
            let server = accepted.get(Duration.second)
            client.close()
            server.close()
        } finally {
            listener.close()
        }
    }

    @TestCase
    func listenerCloseWakesActiveAcceptWithStructuredErrorAndIsIdempotent(): Unit {
        let listener = StdNetTransportListener.bind(listenerLoopback(0), backlog: 1)
        let result: Future<Bool> = spawn {
            try {
                let _ = listener.accept()
                false
            } catch (error: NetworkException) {
                listenerClosed(error)
            }
        }
        @Assert(listener.waitUntilAcceptActive(Duration.second))
        listener.close()
        @Expect(result.get(Duration.second), true)
        listener.close()
    }
}
