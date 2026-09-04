package wirestack

/** Stable event names. The payload deliberately has no free-form text or HTTP data. */
public enum NetworkEventKind {
/**
 * Wirestack 公开 API：DnsStarted。
 */
    | DnsStarted
/**
 * Wirestack 公开 API：DnsCompleted。
 */
    | DnsCompleted
/**
 * Wirestack 公开 API：ConnectAttemptStarted。
 */
    | ConnectAttemptStarted
/**
 * Wirestack 公开 API：ConnectAttemptCompleted。
 */
    | ConnectAttemptCompleted
/**
 * Wirestack 公开 API：TcpConnected。
 */
    | TcpConnected
/**
 * Wirestack 公开 API：ProxyTunnelEstablished。
 */
    | ProxyTunnelEstablished
/**
 * Wirestack 公开 API：TlsHandshakeStarted。
 */
    | TlsHandshakeStarted
/**
 * Wirestack 公开 API：TlsHandshakeCompleted。
 */
    | TlsHandshakeCompleted
/**
 * Wirestack 公开 API：HttpConnectionAcquired。
 */
    | HttpConnectionAcquired
/**
 * Wirestack 公开 API：HttpConnectionReleased。
 */
    | HttpConnectionReleased
/**
 * Wirestack 公开 API：Http2StreamOpened。
 */
    | Http2StreamOpened
/**
 * Wirestack 公开 API：Http2StreamClosed。
 */
    | Http2StreamClosed
/**
 * Wirestack 公开 API：ConnectionClosed。
 */
    | ConnectionClosed
}

/**
 * Wirestack 公开 API：NetworkEventOutcome。
 */
public enum NetworkEventOutcome {
/**
 * Wirestack 公开 API：Started。
 */
    | Started
/**
 * Wirestack 公开 API：Succeeded。
 */
    | Succeeded
/**
 * Wirestack 公开 API：Failed。
 */
    | Failed
/**
 * Wirestack 公开 API：Reused。
 */
    | Reused
/**
 * Wirestack 公开 API：Released。
 */
    | Released
/**
 * Wirestack 公开 API：Discarded。
 */
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
/**
 * Wirestack 公开 API：kind。
 */
    public let kind: NetworkEventKind
/**
 * Wirestack 公开 API：outcome。
 */
    public let outcome: NetworkEventOutcome
/**
 * Wirestack 公开 API：trace。
 */
    public let trace: ?NetworkTraceContext
/**
 * Wirestack 公开 API：phase。
 */
    public let phase: ?NetworkPhase
/**
 * Wirestack 公开 API：errorCode。
 */
    public let errorCode: ?NetworkErrorCode
/**
 * Wirestack 公开 API：connectionId。
 */
    public let connectionId: ?Int64

/**
 * Wirestack 公开 API：init。
 * @param connectionId 参数 connectionId。
 * @param errorCode 参数 errorCode。
 * @param kind 参数 kind。
 * @param outcome 参数 outcome。
 * @param phase 参数 phase。
 * @param trace 参数 trace。
 */
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
/**
 * Wirestack 公开 API：emit。
 * @param event 参数 event。
 */
    func emit(event: NetworkEvent): Unit
}

/**
 * Zero-work fast path when no sink is installed; user exceptions are isolated.
 * @param context 参数 context。
 * @param event 参数 event。
 */
public func emitNetworkEvent(context: OperationContext, event: NetworkEvent): Unit {
    match (context.eventSink) {
        case Some(sink) => try { sink.emit(event) } catch (_: Exception) {}
        case None => ()
    }
}
