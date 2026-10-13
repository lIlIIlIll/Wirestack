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

/** A network-operation phase with an optional cap in OperationTimeoutPolicy. */
public enum OperationTimeoutStage {
    /** Waiting for shared client request-resource admission. */
    | RequestAdmission
    /** Waiting for a reusable connection or HTTP/2 stream. */
    | ConnectionPool
    /** Resolving the origin or proxy name. */
    | Dns
    /** Establishing the TCP connection plan. */
    | TcpConnect
    /** Establishing an HTTP CONNECT tunnel through the proxy. */
    | ProxyConnect
    /** Completing the TLS handshake. */
    | TlsHandshake
    /** Writing request headers and body bytes. */
    | RequestWrite
    /** Waiting for interim or final response headers. */
    | ResponseHeaders
    /** Waiting for response-body progress during an active body read. */
    | BodyReadIdle
    /** Waiting for progress during an active upgraded-stream read. */
    | StreamReadIdle
}

/** Optional positive caps for operation stages and active reads.
 * Each cap starts when its stage begins and is shortened by the context's
 * absolute deadline. Body-read timers do not run between caller read calls.
 * Omitted values add no stage-specific timer.
 */
public struct OperationTimeoutPolicy {
    /** Maximum wait for shared request-resource admission. */
    public let requestAdmission: ?Duration
    /** Maximum wait for a reusable connection or stream. */
    public let connectionPool: ?Duration
    /** Maximum time for DNS resolution. */
    public let dns: ?Duration
    /** Maximum time for the TCP connection plan. */
    public let tcpConnect: ?Duration
    /** Maximum time for the HTTP CONNECT proxy exchange. */
    public let proxyConnect: ?Duration
    /** Maximum TLS handshake time. */
    public let tlsHandshake: ?Duration
    /** Maximum request-header and request-body write time. */
    public let requestWrite: ?Duration
    /** Maximum wait for response headers. */
    public let responseHeaders: ?Duration
    /** Maximum wait for body progress during an active response-body read. */
    public let bodyReadIdle: ?Duration
    /** Maximum wait for upgraded-stream progress during an active stream read. */
    public let streamReadIdle: ?Duration

    /**
     * Creates optional positive limits for network-operation stages.
     * Every configured value must be greater than zero. None leaves that stage
     * governed by the operation's absolute deadline alone.
     * @param requestAdmission Maximum wait for shared request-resource admission.
     * @param connectionPool Maximum wait for a reusable connection or stream.
     * @param dns Maximum time for DNS resolution.
     * @param tcpConnect Maximum time for the TCP connection plan.
     * @param proxyConnect Maximum time for the HTTP CONNECT proxy exchange.
     * @param tlsHandshake Maximum TLS handshake time.
     * @param requestWrite Maximum request-header and request-body write time.
     * @param responseHeaders Maximum wait for interim or final response headers.
     * @param bodyReadIdle Maximum wait for response-body progress during an active read.
     * @param streamReadIdle Maximum wait for upgraded-stream progress during an active read.
     */
    public init(
        requestAdmission!: ?Duration = None<Duration>,
        connectionPool!: ?Duration = None<Duration>,
        dns!: ?Duration = None<Duration>,
        tcpConnect!: ?Duration = None<Duration>,
        proxyConnect!: ?Duration = None<Duration>,
        tlsHandshake!: ?Duration = None<Duration>,
        requestWrite!: ?Duration = None<Duration>,
        responseHeaders!: ?Duration = None<Duration>,
        bodyReadIdle!: ?Duration = None<Duration>,
        streamReadIdle!: ?Duration = None<Duration>
    ) {
        for (value in [requestAdmission, connectionPool, dns, tcpConnect, proxyConnect,
            tlsHandshake, requestWrite, responseHeaders, bodyReadIdle, streamReadIdle]) {
            if (let Some(duration) <- value) {
                if (duration <= Duration.Zero) {
                    throw IllegalArgumentException("operation timeout policy values must be positive")
                }
            }
        }
        this.requestAdmission = requestAdmission
        this.connectionPool = connectionPool
        this.dns = dns
        this.tcpConnect = tcpConnect
        this.proxyConnect = proxyConnect
        this.tlsHandshake = tlsHandshake
        this.requestWrite = requestWrite
        this.responseHeaders = responseHeaders
        this.bodyReadIdle = bodyReadIdle
        this.streamReadIdle = streamReadIdle
    }

    internal func timeoutFor(stage: OperationTimeoutStage): ?Duration {
        match (stage) {
            case OperationTimeoutStage.RequestAdmission => requestAdmission
            case OperationTimeoutStage.ConnectionPool => connectionPool
            case OperationTimeoutStage.Dns => dns
            case OperationTimeoutStage.TcpConnect => tcpConnect
            case OperationTimeoutStage.ProxyConnect => proxyConnect
            case OperationTimeoutStage.TlsHandshake => tlsHandshake
            case OperationTimeoutStage.RequestWrite => requestWrite
            case OperationTimeoutStage.ResponseHeaders => responseHeaders
            case OperationTimeoutStage.BodyReadIdle => bodyReadIdle
            case OperationTimeoutStage.StreamReadIdle => streamReadIdle
        }
    }
}

/** Immutable deadline, stage policy, cancellation and trace input for one operation. */
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
    /** Stage caps remain children of the same total operation deadline. */
    public let timeoutPolicy: OperationTimeoutPolicy

/**
 * Creates an immutable operation context.
 * Stage limits only shorten the absolute deadline; they do not change
 * cancellation, trace metadata, or the event sink.
 * @param deadline Absolute upper bound for the complete operation.
 * @param cancellation Token observed by this operation.
 * @param trace Opaque trace identifiers propagated to network event sinks.
 * @param eventSink Optional destination for network lifecycle events.
 * @param timeoutPolicy Optional positive stage caps and active-read idle limits.
 */
    public init(
        deadline!: ?Deadline = None<Deadline>,
        cancellation!: CancellationToken = CancellationToken.none(),
        trace!: ?NetworkTraceContext = None<NetworkTraceContext>,
        eventSink!: ?NetworkEventSink = None<NetworkEventSink>,
        timeoutPolicy!: OperationTimeoutPolicy = OperationTimeoutPolicy()
    ) {
        this.deadline = deadline
        this.cancellation = cancellation
        this.trace = trace
        this.eventSink = eventSink
        this.timeoutPolicy = timeoutPolicy
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public static func background(): OperationContext {
        OperationContext()
    }

/** Replaces the timeout policy while retaining deadline and cancellation.
 * @param value New per-stage and active-read timeout policy.
 */
    public func withTimeoutPolicy(value: OperationTimeoutPolicy): OperationContext {
        OperationContext(
            deadline: deadline, cancellation: cancellation, trace: trace, eventSink: eventSink,
            timeoutPolicy: value
        )
    }

/** Derives the selected stage deadline, capped by this context's deadline.
 * @param stage Stage whose optional timeout should be applied.
 */
    public func forStage(stage: OperationTimeoutStage): OperationContext {
        match (timeoutPolicy.timeoutFor(stage)) {
            case Some(duration) => shortenDeadline(duration)
            case None => this
        }
    }

/**
 * Replaces cancellation while retaining the same absolute budget and stage policy.
 * @param token 用于传播取消请求的令牌。
 */
    public func withCancellation(token: CancellationToken): OperationContext {
        OperationContext(
            deadline: deadline, cancellation: token, trace: trace, eventSink: eventSink,
            timeoutPolicy: timeoutPolicy
        )
    }

/** Replaces trace metadata without changing deadline, cancellation or timeout policy.
 * @param value New optional trace metadata.
 */
    public func withTrace(value: ?NetworkTraceContext): OperationContext {
        OperationContext(
            deadline: deadline, cancellation: cancellation, trace: value, eventSink: eventSink,
            timeoutPolicy: timeoutPolicy
        )
    }

/** Replaces the optional event destination without changing operation semantics.
 * @param value New optional network-event sink.
 */
    public func withEventSink(value: ?NetworkEventSink): OperationContext {
        OperationContext(
            deadline: deadline, cancellation: cancellation, trace: trace, eventSink: value,
            timeoutPolicy: timeoutPolicy
        )
    }

/** Adds or shortens the deadline. It never extends an existing budget.
 * @param duration Maximum duration from now for this operation stage.
 */
    public func shortenDeadline(duration: Duration): OperationContext {
        let next = match (deadline) {
            case Some(parent) => parent.child(duration)
            case None => Deadline.after(duration)
        }
        OperationContext(
            deadline: Some(next), cancellation: cancellation, trace: trace, eventSink: eventSink,
            timeoutPolicy: timeoutPolicy
        )
    }

/** Uses an absolute deadline only when it is earlier than the current one.
 * @param candidate Deadline to compare with the current operation deadline.
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
        OperationContext(
            deadline: Some(next), cancellation: cancellation, trace: trace, eventSink: eventSink,
            timeoutPolicy: timeoutPolicy
        )
    }

/** Reports whether the caller requested cancellation. */
    public func isCancellationRequested(): Bool {
        cancellation.isCancellationRequested
    }

/** Reports whether this context's effective absolute deadline has expired. */
    public func isDeadlineExceeded(): Bool {
        match (deadline) {
            case Some(value) => value.isExpired()
            case None => false
        }
    }
}

