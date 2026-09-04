package wirestack

/**
 * Opaque, read-only identifiers propagated to network event sinks.
 * Wirestack never derives these values from headers or payload data.
 */
public struct NetworkTraceContext {
/**
 * Wirestack 公开 API：traceId。
 */
    public let traceId: String
/**
 * Wirestack 公开 API：spanId。
 */
    public let spanId: String

/**
 * Wirestack 公开 API：init。
 * @param spanId 参数 spanId。
 * @param traceId 参数 traceId。
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
 * Wirestack 公开 API：deadline。
 */
    public let deadline: ?Deadline
/**
 * Wirestack 公开 API：cancellation。
 */
    public let cancellation: CancellationToken
/**
 * Wirestack 公开 API：trace。
 */
    public let trace: ?NetworkTraceContext
/**
 * Wirestack 公开 API：eventSink。
 */
    public let eventSink: ?NetworkEventSink

/**
 * Wirestack 公开 API：init。
 * @param cancellation 参数 cancellation。
 * @param deadline 参数 deadline。
 * @param eventSink 参数 eventSink。
 * @param trace 参数 trace。
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
 * Wirestack 公开 API：background。
 */
    public static func background(): OperationContext {
        OperationContext()
    }

/**
 * Replaces cancellation while retaining the same absolute budget.
 * @param token 参数 token。
 */
    public func withCancellation(token: CancellationToken): OperationContext {
        OperationContext(deadline: deadline, cancellation: token, trace: trace, eventSink: eventSink)
    }

/**
 * Replaces trace metadata without touching deadline or cancellation.
 * @param value 参数 value。
 */
    public func withTrace(value: ?NetworkTraceContext): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: value, eventSink: eventSink)
    }

/**
 * Replaces the optional event destination without changing operation semantics.
 * @param value 参数 value。
 */
    public func withEventSink(value: ?NetworkEventSink): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: trace, eventSink: value)
    }

/**
 * Adds or shortens the deadline. It never extends an existing budget.
 * @param duration 参数 duration。
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
 * @param candidate 参数 candidate。
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
 * Wirestack 公开 API：isCancellationRequested。
 */
    public func isCancellationRequested(): Bool {
        cancellation.isCancellationRequested
    }

/**
 * Wirestack 公开 API：isDeadlineExceeded。
 */
    public func isDeadlineExceeded(): Bool {
        match (deadline) {
            case Some(value) => value.isExpired()
            case None => false
        }
    }
}
