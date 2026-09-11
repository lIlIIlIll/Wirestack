package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class M8002TcpListenerTest {
    @TestCase
    func bindRejectsInvalidBacklogAndStoppedContextsWithStructuredErrors(): Unit {
        for (backlog in [0, -1, 65536]) {
            let error = @AssertThrows[api.NetworkException](
                TcpListener.bind(m8002Loopback(0u16), backlog: backlog)
            )
            @Expect(m8002ListenerError(error, api.NetworkErrorCode.InvalidState))
        }

        let cancellation = api.CancellationSource()
        cancellation.cancel()
        let cancelled = @AssertThrows[api.NetworkException](
            TcpListener.bind(
                m8002Loopback(0u16),
                context: api.OperationContext(cancellation: cancellation.token)
            )
        )
        @Expect(m8002ListenerError(cancelled, api.NetworkErrorCode.Cancelled))

        let expired = @AssertThrows[api.NetworkException](
            TcpListener.bind(
                m8002Loopback(0u16),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(Duration.Zero))
                )
            )
        )
        @Expect(m8002ListenerError(expired, api.NetworkErrorCode.TimedOut))
    }

    @TestCase
    func bindFailureRetainsPublicCoordinatesAndCause(): Unit {
        let owner = TcpListener.bind(m8002Loopback(0u16), backlog: 1)
        try {
            let error = @AssertThrows[api.NetworkException](
                TcpListener.bind(owner.localEndpoint, backlog: 1)
            )
            @Expect(m8002ListenerSystemFailure(error))
            @Expect(m8002HasInternetEndpoint(error.localEndpoint, owner.localEndpoint))
            @Expect(error.cause.isSome())
        } finally {
            owner.close()
        }
    }

    @TestCase
    func cancelledAndExpiredAcceptsLeaveListenerReusable(): Unit {
        let listener = TcpListener.bind(m8002Loopback(0u16), backlog: 2)
        try {
            let cancellation = api.CancellationSource()
            let pending: Future<Bool> = spawn {
                try {
                    let _ = listener.accept(
                        context: api.OperationContext(cancellation: cancellation.token)
                    )
                    false
                } catch (error: api.NetworkException) {
                    m8002ListenerError(error, api.NetworkErrorCode.Cancelled)
                }
            }
            cancellation.cancel()
            @Expect(pending.get(Duration.second))
            m8002ExpectState(listener.state, SocketState.Listening)
            @Expect(!listener.isClosed())

            let deadlineError = @AssertThrows[api.NetworkException](
                listener.accept(
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(20 * Duration.millisecond))
                    )
                )
            )
            @Expect(m8002ListenerError(deadlineError, api.NetworkErrorCode.TimedOut))
            m8002ExpectState(listener.state, SocketState.Listening)
            @Expect(!listener.isClosed())

            let accepting = spawn { listener.accept() }
            let client = TcpStream.connect(listener.localEndpoint)
            let server = accepting.get(Duration.second)
            client.close()
            server.close()
        } finally {
            listener.close()
        }
    }

    @TestCase
    func acceptedStreamTransfersExactDataInBothDirections(): Unit {
        let listener = TcpListener.bind(m8002Loopback(0u16), backlog: 4)
        m8002ExpectState(listener.state, SocketState.Listening)
        @Expect(listener.localEndpoint.port != 0u16)
        @Expect(listener.capabilities.nonBlocking)
        @Expect(listener.capabilities.closeOnExec)
        let accepting = spawn { listener.accept() }
        let client = TcpStream.connect(listener.localEndpoint)
        let server = accepting.get(Duration.second)
        try {
            m8002ExpectState(server.state, SocketState.Open)
            @Expect(server.capabilities.nonBlocking)
            @Expect(server.capabilities.closeOnExec)
            @Expect(server.localEndpoint.isSome())
            @Expect(server.remoteEndpoint.isSome())

            let request = [0x00u8, 0x7Fu8, 0x80u8, 0xFFu8, 0x31u8]
            client.writeAll(
                api.ByteSpan(request),
                context: api.OperationContext.background()
            )
            let receivedRequest = Array<Byte>(request.size, repeat: 0u8)
            server.readExact(
                api.MutableByteSpan(receivedRequest),
                context: api.OperationContext.background()
            )
            @Expect(receivedRequest, request)

            let response = [0xA5u8, 0x5Au8, 0x01u8]
            server.writeAll(
                api.ByteSpan(response),
                context: api.OperationContext.background()
            )
            let receivedResponse = Array<Byte>(response.size, repeat: 0u8)
            client.readExact(
                api.MutableByteSpan(receivedResponse),
                context: api.OperationContext.background()
            )
            @Expect(receivedResponse, response)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func overlappingAcceptIsRejectedWithoutCreatingAPendingQueue(): Unit {
        let listener = TcpListener.bind(m8002Loopback(0u16), backlog: 1)
        let cancellation = api.CancellationSource()
        let accept = { =>
            try {
                let stream = listener.accept(context: api.OperationContext(
                    cancellation: cancellation.token,
                    deadline: Some(api.Deadline.after(Duration.second))
                ))
                stream.close()
                0
            } catch (error: api.NetworkException) {
                if (m8002ListenerError(error, api.NetworkErrorCode.ConcurrentOperation)) {
                    cancellation.cancel()
                    1
                } else if (m8002ListenerError(error, api.NetworkErrorCode.Cancelled)) {
                    2
                } else {
                    throw error
                }
            }
        }
        let first = spawn { accept() }
        let second = spawn { accept() }
        try {
            let left = first.get(2 * Duration.second)
            let right = second.get(2 * Duration.second)
            @Expect((left == 1 && right == 2) || (left == 2 && right == 1))
        } finally {
            cancellation.cancel()
            listener.close()
        }
    }

    @TestCase
    func stoppedCloseAdmissionHasNoNativeEffectAndListenerRemainsUsable(): Unit {
        let listener = TcpListener.bind(m8002Loopback(0u16), backlog: 1)
        let cancellation = api.CancellationSource()
        cancellation.cancel()
        let error = @AssertThrows[api.NetworkException](
            listener.close(
                context: api.OperationContext(cancellation: cancellation.token)
            )
        )
        @Expect(m8002CloseError(error, api.NetworkErrorCode.Cancelled))
        m8002ExpectState(listener.state, SocketState.Listening)
        @Expect(!listener.isClosed())

        let accepting = spawn { listener.accept() }
        let client = TcpStream.connect(listener.localEndpoint)
        let server = accepting.get(Duration.second)
        client.close()
        server.close()
        listener.close()
        m8002ExpectState(listener.state, SocketState.Closed)
    }

    @TestCase
    func gracefulAndAbortTerminalOwnersAreStableAndWakeAccept(): Unit {
        let graceful = TcpListener.bind(m8002Loopback(0u16), backlog: 1)
        let gracefulAccept: Future<Bool> = spawn {
            try {
                let _ = graceful.accept()
                false
            } catch (error: api.NetworkException) {
                m8002ListenerError(error, api.NetworkErrorCode.Closed)
            }
        }
        graceful.close()
        @Expect(gracefulAccept.get(Duration.second))
        graceful.close()
        graceful.abort(reason: Some(api.AbortReason.ApplicationAbort))
        @Expect(graceful.isClosed())
        m8002ExpectState(graceful.state, SocketState.Closed)

        let cancelled = api.CancellationSource()
        cancelled.cancel()
        graceful.close(context: api.OperationContext(cancellation: cancelled.token))
        m8002ExpectState(graceful.state, SocketState.Closed)

        let aborted = TcpListener.bind(m8002Loopback(0u16), backlog: 1)
        let abortedAccept: Future<Bool> = spawn {
            try {
                let _ = aborted.accept()
                false
            } catch (error: api.NetworkException) {
                m8002ListenerError(error, api.NetworkErrorCode.Closed)
            }
        }
        aborted.abort(reason: Some(api.AbortReason.ApplicationAbort))
        @Expect(abortedAccept.get(Duration.second))
        aborted.abort()
        aborted.close(context: api.OperationContext(cancellation: cancelled.token))
        @Expect(aborted.isClosed())
        m8002ExpectState(aborted.state, SocketState.Aborted)

        let closedAccept = @AssertThrows[api.NetworkException](aborted.accept())
        @Expect(m8002ListenerError(closedAccept, api.NetworkErrorCode.Closed))
    }
}

private func m8002Loopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func m8002ListenerError(
    error: api.NetworkException,
    code: api.NetworkErrorCode
): Bool {
    let shape = match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Accept, api.NetworkPhase.ServerAccept) => true
        case _ => false
    }
    let codeMatches = match ((error.code, code)) {
        case (api.NetworkErrorCode.InvalidState, api.NetworkErrorCode.InvalidState) => true
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) => true
        case (api.NetworkErrorCode.TimedOut, api.NetworkErrorCode.TimedOut) => true
        case (api.NetworkErrorCode.ConcurrentOperation, api.NetworkErrorCode.ConcurrentOperation) => true
        case (api.NetworkErrorCode.Closed, api.NetworkErrorCode.Closed) => true
        case _ => false
    }
    shape && codeMatches && error.localEndpoint.isSome()
}

private func m8002ListenerSystemFailure(error: api.NetworkException): Bool {
    match ((error.category, error.phase, error.code, error.retryability)) {
        case (
            api.NetworkErrorCategory.Accept,
            api.NetworkPhase.ServerAccept,
            api.NetworkErrorCode.SystemFailure,
            api.Retryability.Never
        ) => true
        case _ => false
    }
}

private func m8002CloseError(
    error: api.NetworkException,
    code: api.NetworkErrorCode
): Bool {
    let shape = match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Cancelled, api.NetworkPhase.TransportClose) => true
        case (api.NetworkErrorCategory.DeadlineExceeded, api.NetworkPhase.TransportClose) => true
        case _ => false
    }
    let codeMatches = match ((error.code, code)) {
        case (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) => true
        case (api.NetworkErrorCode.TimedOut, api.NetworkErrorCode.TimedOut) => true
        case _ => false
    }
    shape && codeMatches && error.localEndpoint.isSome()
}

private func m8002HasInternetEndpoint(
    actual: ?api.NetworkEndpoint,
    expected: api.SocketEndpoint
): Bool {
    match (actual) {
        case Some(api.NetworkEndpoint.Internet(endpoint)) => endpoint == expected
        case _ => false
    }
}

private func m8002ExpectState(actual: SocketState, expected: SocketState): Unit {
    let matches = match ((actual, expected)) {
        case (SocketState.Listening, SocketState.Listening) => true
        case (SocketState.Open, SocketState.Open) => true
        case (SocketState.Closing, SocketState.Closing) => true
        case (SocketState.Closed, SocketState.Closed) => true
        case (SocketState.Aborted, SocketState.Aborted) => true
        case (SocketState.Failed, SocketState.Failed) => true
        case _ => false
    }
    @Expect(matches)
}
