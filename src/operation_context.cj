package wirestack

/**
 * Opaque, read-only identifiers propagated to network event sinks.
 * Wirestack never derives these values from headers or payload data.
 */
public struct NetworkTraceContext {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let traceId: String
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let spanId: String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param spanId 当前追踪跨度的标识。
 * @param traceId 当前追踪链的标识。
 */
    public init(traceId: String, spanId!: String = "") {
        if (traceId.isEmpty()) {
            throw IllegalArgumentException("traceId must not be empty")
        }
        if (traceId.size > 128 || spanId.size > 128) {
            throw IllegalArgumentException("trace identifiers must not exceed 128 bytes")
        }
        this.traceId = traceId
        this.spanId = spanId
    }
}

/** Immutable budget, cancellation and trace input shared by one operation. */
public struct OperationContext {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let deadline: ?Deadline
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let cancellation: CancellationToken
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let trace: ?NetworkTraceContext
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let eventSink: ?NetworkEventSink

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cancellation 调用方提供的输入值。
 * @param deadline 本次操作使用的绝对截止时间。
 * @param eventSink 接收网络事件的可选目标。
 * @param trace 要传播的追踪元数据。
 */
    public init(
        deadline!: ?Deadline = None<Deadline>,
        cancellation!: CancellationToken = CancellationToken.none(),
        trace!: ?NetworkTraceContext = None<NetworkTraceContext>,
        eventSink!: ?NetworkEventSink = None<NetworkEventSink>
    ) {
        this.deadline = deadline
        this.cancellation = cancellation
        this.trace = trace
        this.eventSink = eventSink
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public static func background(): OperationContext {
        OperationContext()
    }

/**
 * Replaces cancellation while retaining the same absolute budget.
 * @param token 用于传播取消请求的令牌。
 */
    public func withCancellation(token: CancellationToken): OperationContext {
        OperationContext(deadline: deadline, cancellation: token, trace: trace, eventSink: eventSink)
    }

/**
 * Replaces trace metadata without touching deadline or cancellation.
 * @param value 待写入或配置的值。
 */
    public func withTrace(value: ?NetworkTraceContext): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: value, eventSink: eventSink)
    }

/**
 * Replaces the optional event destination without changing operation semantics.
 * @param value 待写入或配置的值。
 */
    public func withEventSink(value: ?NetworkEventSink): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: trace, eventSink: value)
    }

/**
 * Adds or shortens the deadline. It never extends an existing budget.
 * @param duration 相对当前上下文的最大持续时间。
 */
    public func shortenDeadline(duration: Duration): OperationContext {
        let next = match (deadline) {
            case Some(parent) => parent.child(duration)
            case None => Deadline.after(duration)
        }
        OperationContext(deadline: Some(next), cancellation: cancellation, trace: trace, eventSink: eventSink)
    }

/**
 * Uses an absolute deadline only when it is earlier than the current one.
 * @param candidate 待比较的候选截止时间。
 */
    public func withEarlierDeadline(candidate: Deadline): OperationContext {
        let next = match (deadline) {
            case Some(current) =>
                if (candidate.expiresAt < current.expiresAt) {
                    candidate
                } else {
                    current
                }
            case None => candidate
        }
        OperationContext(deadline: Some(next), cancellation: cancellation, trace: trace, eventSink: eventSink)
    }

/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
 */
    public func isCancellationRequested(): Bool {
        cancellation.isCancellationRequested
    }

/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
 */
    public func isDeadlineExceeded(): Bool {
        match (deadline) {
            case Some(value) => value.isExpired()
            case None => false
        }
    }
}
