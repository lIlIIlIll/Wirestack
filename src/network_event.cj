package wirestack

import std.sync.AtomicInt64
import std.time.MonoTime

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
    /** Actual beginning of the stage field. */
    | StageStarted
    /** Actual completion or failure of the stage field. */
    | StageCompleted
    /** Logical request started, before admission. */
    | RequestStarted
    /** Logical request terminal result, emitted once across retries. */
    | RequestCompleted
    /** One protocol attempt began. */
    | AttemptStarted
    /** One protocol attempt produced headers or failed. */
    | AttemptCompleted
    /** Returned response body lifecycle began. */
    | BodyStarted
    /** Response body lifecycle ended by consumption, close, or failure. */
    | BodyCompleted
    /** Physical connection stopped accepting new exchanges. */
    | ConnectionDraining
    /** An actual TLS or resolver generation was published. */
    | ConfigurationRotated
    /** Actual local protocol flow-control capacity wait began. */
    | LocalBackpressureStarted
    /** Actual local protocol flow-control capacity wait ended. */
    | LocalBackpressureCompleted
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
    /** Stage did not run, for example DNS and TLS on a reused connection. */
    | NotExecuted
}

/** Which existing absolute budget caused a deadline failure. */
public enum NetworkTimeoutReason {
    /** The caller or instance's total absolute operation deadline. */
    | TotalDeadline
    /** A configured stage cap shortened the total absolute deadline. */
    | StageLimit
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
    /** Logical request identifier shared by all attempts. */
    public let requestId: ?Int64
    /** Identifier for one protocol or connection attempt. */
    public let attemptId: ?Int64
    /** HTTP/2 stream identifier scoped to connectionId. */
    public let streamId: ?Int64
    /** One-based Happy Eyeballs candidate position. */
    public let connectionAttemptIndex: ?Int64
    /** Current operation stage, when applicable. */
    public let stage: ?OperationTimeoutStage
    /** Expired effective budget owner; absent for unproven native/aggregate timeout causes. */
    public let timeoutReason: ?NetworkTimeoutReason
    /** Stage that owns a shortened deadline, not necessarily the failing stage. */
    public let timeoutStage: ?OperationTimeoutStage
    /** Monotonic emission time; absent until delivered to a sink. */
    public let occurredAt: ?MonoTime

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param connectionId 调用方提供的输入值。
 * @param errorCode 调用方提供的输入值。
 * @param kind 调用方提供的输入值。
 * @param outcome 调用方提供的输入值。
 * @param phase 调用方提供的输入值。
 * @param trace 要传播的追踪元数据。
 * @param requestId Logical request identifier shared by all attempts.
 * @param attemptId Identifier for one protocol or connection attempt.
 * @param streamId HTTP/2 stream identifier scoped to connectionId.
 * @param connectionAttemptIndex One-based Happy Eyeballs candidate position.
 * @param stage Current operation stage, when applicable.
 * @param timeoutReason Total deadline or stage cap responsible for a deadline failure.
 * @param timeoutStage Stage that owns a shortened deadline, not necessarily the failing stage.
 * @param occurredAt Monotonic emission time; absent until delivered to a sink.
 */
    public init(kind: NetworkEventKind, outcome: NetworkEventOutcome,
        trace!: ?NetworkTraceContext = None<NetworkTraceContext>,
        phase!: ?NetworkPhase = None<NetworkPhase>, errorCode!: ?NetworkErrorCode = None<NetworkErrorCode>,
        connectionId!: ?Int64 = None<Int64>, requestId!: ?Int64 = None<Int64>,
        attemptId!: ?Int64 = None<Int64>, streamId!: ?Int64 = None<Int64>,
        connectionAttemptIndex!: ?Int64 = None<Int64>,
        stage!: ?OperationTimeoutStage = None<OperationTimeoutStage>,
        timeoutReason!: ?NetworkTimeoutReason = None<NetworkTimeoutReason>,
        timeoutStage!: ?OperationTimeoutStage = None<OperationTimeoutStage>,
        occurredAt!: ?MonoTime = None<MonoTime>
    ) {
        requireNetworkCorrelationId(connectionId)
        requireNetworkCorrelationId(requestId)
        requireNetworkCorrelationId(attemptId)
        requireNetworkCorrelationId(streamId)
        requireNetworkCorrelationId(connectionAttemptIndex)
        this.kind = kind; this.outcome = outcome; this.trace = trace
        this.phase = phase; this.errorCode = errorCode; this.connectionId = connectionId
        this.requestId = requestId
        this.attemptId = attemptId
        this.streamId = streamId
        this.connectionAttemptIndex = connectionAttemptIndex
        this.stage = stage
        this.timeoutReason = timeoutReason
        this.timeoutStage = timeoutStage
        this.occurredAt = occurredAt
    }
}

/** Synchronous operation-thread callback. Exceptions are isolated, but arbitrary
 * blocking callbacks cannot be preempted; use a bounded adapter for isolation. */
public interface NetworkEventSink {
    /** Receives one secret-safe event outside owner locks.
     * @param event Structured observation with no URL, headers, body, or secret fields.
     */
    func emit(event: NetworkEvent): Unit
}

/** Delivers an event only when a sink exists, filling absent correlation and time.
 * User exceptions cannot alter operation completion. A synchronous callback may block.
 * @param context Canonical deadline, cancellation, trace, sink and correlation scope.
 * @param event Secret-safe structured event; explicit fields win over context defaults.
 */
public func emitNetworkEvent(context: OperationContext, event: NetworkEvent): Unit {
    if (let Some(sink) <- context.eventSink) {
        let isTimeout = match (event.errorCode) {
            case Some(NetworkErrorCode.TimedOut) => true
            case _ => false
        }
        let reason = if (isTimeout && context.isDeadlineExceeded()) {
            if (context.deadlineStage.isSome()) { Some(NetworkTimeoutReason.StageLimit) }
            else { Some(NetworkTimeoutReason.TotalDeadline) }
        } else { None<NetworkTimeoutReason> }
        let correlated = NetworkEvent(event.kind, event.outcome,
            trace: if (event.trace.isSome()) { event.trace } else { context.trace },
            phase: event.phase, errorCode: event.errorCode,
            connectionId: if (event.connectionId.isSome()) { event.connectionId } else { context.connectionId },
            requestId: if (event.requestId.isSome()) { event.requestId } else { context.requestId },
            attemptId: if (event.attemptId.isSome()) { event.attemptId } else { context.attemptId },
            streamId: if (event.streamId.isSome()) { event.streamId } else { context.streamId },
            connectionAttemptIndex: event.connectionAttemptIndex,
            stage: if (event.stage.isSome()) { event.stage } else { context.stage },
            timeoutReason: if (event.timeoutReason.isSome()) { event.timeoutReason } else { reason },
            timeoutStage: if (event.timeoutStage.isSome()) { event.timeoutStage }
                else if (reason.isSome()) { context.deadlineStage } else { None<OperationTimeoutStage> },
            occurredAt: if (event.occurredAt.isSome()) { event.occurredAt } else { Some(MonoTime.now()) })
        try { sink.emit(correlated) } catch (_: Exception) {}
    }
}

internal func requireNetworkCorrelationId(identifier: ?Int64): Unit {
    if (let Some(value) <- identifier) {
        if (value <= 0) { throw IllegalArgumentException("network correlation identifiers must be positive") }
    }
}

private let networkCorrelationSequence = AtomicInt64(0)

/** Allocates a process-local positive identifier without retaining per-ID state.
 * User-supplied IDs are caller-owned namespaces. Automatic IDs share this sequence.
 */
public func nextNetworkCorrelationId(): Int64 {
    var current = networkCorrelationSequence.load()
    while (true) {
        if (current == 9223372036854775807) {
            throw IllegalStateException("network correlation identifier space exhausted")
        }
        if (networkCorrelationSequence.compareAndSwap(current, current + 1)) { return current + 1 }
        current = networkCorrelationSequence.load()
    }
    0
}
