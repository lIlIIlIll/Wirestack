package wirestack.internal.transport

/**
 * Opaque, read-only identifiers propagated to network event sinks.
 * Wirestack never derives these values from headers or payload data.
 */
public struct NetworkTraceContext {
    public let traceId: String
    public let spanId: String

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
    public let deadline: ?Deadline
    public let cancellation: CancellationToken
    public let trace: ?NetworkTraceContext
    public let eventSink: ?NetworkEventSink

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

    public static func background(): OperationContext {
        OperationContext()
    }

    /** Replaces cancellation while retaining the same absolute budget. */
    public func withCancellation(token: CancellationToken): OperationContext {
        OperationContext(deadline: deadline, cancellation: token, trace: trace, eventSink: eventSink)
    }

    /** Replaces trace metadata without touching deadline or cancellation. */
    public func withTrace(value: ?NetworkTraceContext): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: value, eventSink: eventSink)
    }

    /** Replaces the optional event destination without changing operation semantics. */
    public func withEventSink(value: ?NetworkEventSink): OperationContext {
        OperationContext(deadline: deadline, cancellation: cancellation, trace: trace, eventSink: value)
    }

    /** Adds or shortens the deadline. It never extends an existing budget. */
    public func shortenDeadline(duration: Duration): OperationContext {
        let next = match (deadline) {
            case Some(parent) => parent.child(duration)
            case None => Deadline.after(duration)
        }
        OperationContext(deadline: Some(next), cancellation: cancellation, trace: trace, eventSink: eventSink)
    }

    /** Uses an absolute deadline only when it is earlier than the current one. */
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

    public func isCancellationRequested(): Bool {
        cancellation.isCancellationRequested
    }

    public func isDeadlineExceeded(): Bool {
        match (deadline) {
            case Some(value) => value.isExpired()
            case None => false
        }
    }
}
