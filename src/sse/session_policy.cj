package wirestack.sse

import wirestack.*

/** Explicit GET reconnect and lifetime bounds. Defaults never reconnect. */
public class SseSessionPolicy {
    /** Number of new GET submissions permitted after the first request. */
    public let maximumReconnects: Int64
    /** Total lifetime cap, shortened by the caller's absolute deadline. */
    public let maximumDuration: Duration
    /** Initial reconnect delay before a valid server retry field replaces it. */
    public let initialRetryDelay: Duration
    /** Smallest delay, including retry:0, preventing a tight reconnect loop. */
    public let minimumRetryDelay: Duration
    /** Largest base delay and jittered delay. */
    public let maximumRetryDelay: Duration
    /** Symmetric random jitter magnitude in thousandths of the base delay. */
    public let jitterPermille: Int64
    /** Optional active body-read idle cap; does not run between receives. */
    public let bodyReadIdle: ?Duration

    /**
     * Creates bounded reconnect policy for GET EventSource sessions only.
     * @param maximumReconnects Reconnect count, zero by default; at most 1000.
     * @param maximumDuration Positive session lifetime, at most 24 hours.
     * @param initialRetryDelay Initial backoff base.
     * @param minimumRetryDelay Positive lower bound on each reconnect delay.
     * @param maximumRetryDelay Upper bound on each reconnect delay, at most one hour.
     * @param jitterPermille Jitter fraction, between zero and 1000.
     * @param bodyReadIdle Positive active-read cap, or the caller's existing cap.
     */
    public init(maximumReconnects!: Int64 = 0,
        maximumDuration!: Duration = 5 * Duration.minute,
        initialRetryDelay!: Duration = Duration.second,
        minimumRetryDelay!: Duration = 50 * Duration.millisecond,
        maximumRetryDelay!: Duration = 30 * Duration.second,
        jitterPermille!: Int64 = 200,
        bodyReadIdle!: ?Duration = None<Duration>) {
        if (maximumReconnects < 0 || maximumReconnects > 1000 ||
            maximumDuration <= Duration.Zero || maximumDuration > 24 * Duration.hour ||
            minimumRetryDelay <= Duration.Zero || maximumRetryDelay < minimumRetryDelay ||
            maximumRetryDelay > Duration.hour || initialRetryDelay < minimumRetryDelay ||
            initialRetryDelay > maximumRetryDelay || jitterPermille < 0 || jitterPermille > 1000) {
            throw IllegalArgumentException("SSE session policy exceeds its bounds")
        }
        if (let Some(idle) <- bodyReadIdle) {
            if (idle <= Duration.Zero) { throw IllegalArgumentException("SSE body idle cap must be positive") }
        }
        this.maximumReconnects = maximumReconnects
        this.maximumDuration = maximumDuration
        this.initialRetryDelay = initialRetryDelay
        this.minimumRetryDelay = minimumRetryDelay
        this.maximumRetryDelay = maximumRetryDelay
        this.jitterPermille = jitterPermille
        this.bodyReadIdle = bodyReadIdle
    }

    internal func operation(context: OperationContext): OperationContext {
        let prior = context.timeoutPolicy
        var idle = prior.bodyReadIdle
        if (let Some(value) <- bodyReadIdle) {
            idle = match (idle) { case Some(old) => Some(min(old, value)); case None => Some(value) }
        }
        context.shortenDeadline(maximumDuration).withTimeoutPolicy(OperationTimeoutPolicy(
            requestAdmission: prior.requestAdmission, connectionPool: prior.connectionPool,
            dns: prior.dns, tcpConnect: prior.tcpConnect, proxyConnect: prior.proxyConnect,
            tlsHandshake: prior.tlsHandshake, requestWrite: prior.requestWrite,
            responseHeaders: prior.responseHeaders, bodyReadIdle: idle, streamReadIdle: prior.streamReadIdle))
    }
}
