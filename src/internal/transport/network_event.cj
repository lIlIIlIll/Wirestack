package wirestack.internal.transport

/** Stable event names. The payload deliberately has no free-form text or HTTP data. */
public enum NetworkEventKind {
    | DnsStarted
    | DnsCompleted
    | ConnectAttemptStarted
    | ConnectAttemptCompleted
    | TcpConnected
    | ProxyTunnelEstablished
    | TlsHandshakeStarted
    | TlsHandshakeCompleted
    | HttpConnectionAcquired
    | HttpConnectionReleased
    | Http2StreamOpened
    | Http2StreamClosed
    | ConnectionClosed
}

public enum NetworkEventOutcome {
    | Started
    | Succeeded
    | Failed
    | Reused
    | Released
    | Discarded
}

/**
 * Secret-safe structured network evidence.
 *
 * Header names/values, URLs, bodies, certificates and arbitrary messages are
 * intentionally absent, so default instrumentation cannot accidentally expose
 * credentials or payload data.
 */
public struct NetworkEvent {
    public let kind: NetworkEventKind
    public let outcome: NetworkEventOutcome
    public let trace: ?NetworkTraceContext
    public let phase: ?NetworkPhase
    public let errorCode: ?NetworkErrorCode
    public let connectionId: ?Int64

    public init(
        kind: NetworkEventKind,
        outcome: NetworkEventOutcome,
        trace!: ?NetworkTraceContext = None<NetworkTraceContext>,
        phase!: ?NetworkPhase = None<NetworkPhase>,
        errorCode!: ?NetworkErrorCode = None<NetworkErrorCode>,
        connectionId!: ?Int64 = None<Int64>
    ) {
        this.kind = kind
        this.outcome = outcome
        this.trace = trace
        this.phase = phase
        this.errorCode = errorCode
        this.connectionId = connectionId
    }
}

/** User event sinks must be non-blocking; sink failures never affect I/O. */
public interface NetworkEventSink {
    func emit(event: NetworkEvent): Unit
}

/** Zero-work fast path when no sink is installed; user exceptions are isolated. */
public func emitNetworkEvent(context: OperationContext, event: NetworkEvent): Unit {
    match (context.eventSink) {
        case Some(sink) => try { sink.emit(event) } catch (_: Exception) {}
        case None => ()
    }
}
