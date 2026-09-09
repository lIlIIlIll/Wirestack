package wirestack

/** Stable event names. The payload deliberately has no free-form text or HTTP data. */
public enum NetworkEventKind {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | DnsStarted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | DnsCompleted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ConnectAttemptStarted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ConnectAttemptCompleted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TcpConnected
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ProxyTunnelEstablished
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TlsHandshakeStarted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TlsHandshakeCompleted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | HttpConnectionAcquired
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | HttpConnectionReleased
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Http2StreamOpened
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Http2StreamClosed
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ConnectionClosed
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum NetworkEventOutcome {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Started
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Succeeded
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Failed
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Reused
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Released
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let kind: NetworkEventKind
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let outcome: NetworkEventOutcome
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let trace: ?NetworkTraceContext
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let phase: ?NetworkPhase
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let errorCode: ?NetworkErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let connectionId: ?Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param connectionId 调用方提供的输入值。
 * @param errorCode 调用方提供的输入值。
 * @param kind 调用方提供的输入值。
 * @param outcome 调用方提供的输入值。
 * @param phase 调用方提供的输入值。
 * @param trace 要传播的追踪元数据。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param event 调用方提供的输入值。
 */
    func emit(event: NetworkEvent): Unit
}

/**
 * Zero-work fast path when no sink is installed; user exceptions are isolated.
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param event 调用方提供的输入值。
 */
public func emitNetworkEvent(context: OperationContext, event: NetworkEvent): Unit {
    match (context.eventSink) {
        case Some(sink) => try { sink.emit(event) } catch (_: Exception) {}
        case None => ()
    }
}
