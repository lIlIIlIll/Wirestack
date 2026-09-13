package wirestack.http

import wirestack as api
import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2

/** Exclusive protocol session. The server closes the transport when serve returns. */
public interface HttpDuplexHandler {
    /**
     * Runs outside connection-state locks after committing the upgrade response.
     * An exception ends the session; the server still closes the transferred transport.
     * @param transport HTTP/1.1 connection or HTTP/2 stream, never the shared H2 connection.
     * @param context Shared request cancellation, absolute deadline, trace, and event sink.
     */
    func serve(transport: api.DuplexTransport, context: OperationContext): Unit
}

/** Concrete WebSocket service invoked only after a validated request handshake. */
public interface WebSocketHandler {
    /**
     * Handles the session until completion. The server retains final close ownership.
     * An exception escapes the callback; the server still abort-closes the session.
     * @param connection Validated, uncompressed WebSocket session.
     * @param context Shared request cancellation, absolute deadline, trace, and event sink.
     */
    func serve(connection: WebSocketConnection, context: OperationContext): Unit
}

internal func mapHttp1DuplexHandler(value: ?HttpDuplexHandler,
    cancellation: HttpRequestCancellationOperation): ?http1.Http1DuplexHandler {
    match (value) {
        case Some(handler) => Some<http1.Http1DuplexHandler>(ServerDuplexAdapter(handler, cancellation))
        case None => None<http1.Http1DuplexHandler>
    }
}

internal func mapHttp2DuplexHandler(value: ?HttpDuplexHandler,
    cancellation: HttpRequestCancellationOperation): ?http2.Http2DuplexHandler {
    match (value) {
        case Some(handler) => Some<http2.Http2DuplexHandler>(ServerDuplexAdapter(handler, cancellation))
        case None => None<http2.Http2DuplexHandler>
    }
}

private class ServerDuplexAdapter <: http1.Http1DuplexHandler & http2.Http2DuplexHandler {
    private let delegate: HttpDuplexHandler
    private let cancellation: HttpRequestCancellationOperation
    init(delegate: HttpDuplexHandler, cancellation: HttpRequestCancellationOperation) {
        this.delegate = delegate
        this.cancellation = cancellation
    }
    /**
     * Invokes the delegate with the retained request-cancellation context, then releases its cancellation links.
     * @param transport Exclusive HTTP/1.1 connection or HTTP/2 stream transferred for this session.
     */
    public func serve(transport: api.DuplexTransport, _: OperationContext): Unit {
        try { delegate.serve(transport, cancellation.context) }
        finally { cancellation.fail() }
    }
    /** Releases request-cancellation links when response validation or commitment prevents session startup. */
    public func failed(): Unit { cancellation.fail() }
}

internal class WebSocketServerHandler <: HttpDuplexHandler {
    private let delegate: WebSocketHandler
    private let protocol: ?String
    private let limits: WebSocketLimits
    init(delegate: WebSocketHandler, protocol: ?String, limits: WebSocketLimits) {
        this.delegate = delegate
        this.protocol = protocol
        this.limits = limits
    }
    /**
     * Creates an uncompressed server-role session and invokes the delegate.
     * Return or failure from the delegate abort-closes the session; callback exceptions remain visible to the server.
     * @param transport Exclusive HTTP/1.1 connection or HTTP/2 stream transferred to the WebSocket session.
     * @param context Request cancellation and absolute deadline passed to the delegate.
     */
    public func serve(transport: api.DuplexTransport, context: OperationContext): Unit {
        let connection = WebSocketConnection(transport, WebSocketRole.Server,
            subProtocol: protocol, limits: limits)
        try { delegate.serve(connection, context) }
        finally { connection.close() }
    }
}
