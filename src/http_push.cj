package wirestack

/** Application policy consulted by HttpPushSource.receive on the caller's task. */
public interface Http2PushPolicy {
    /**
     * Decides whether the caller accepts an already validated push offer.
     * @param parent URL of the request associated with the offer.
     * @param promised URL of the promised request.
     * @param context Deadline and cancellation supplied by the receiving caller.
     */
    func allow(parent: HttpUrl, promised: HttpUrl, context: OperationContext): Bool
}

/** Bounded HTTP/2 push acceptance and delivery policy. */
public class Http2PushConfig {
    /** Application decision invoked when the caller receives an offer. */
    public let policy: Http2PushPolicy
    /** Maximum admitted pushed exchanges on one connection. */
    public let maximumConcurrentPushes: Int64
    /** Maximum queued, unclaimed offers for one parent response. */
    public let maximumPendingPushes: Int64
    /** Maximum total offers admitted for one parent request. */
    public let maximumPushesPerRequest: Int64

    /**
     * Creates positive push bounds; pending and per-request bounds cannot exceed concurrency.
     * @param policy Application acceptance policy.
     * @param maximumConcurrentPushes Connection-wide admission bound, at most 65535.
     * @param maximumPendingPushes Per-parent bound on queued offers.
     * @param maximumPushesPerRequest Per-parent bound on total admitted offers.
     */
    public init(
        policy: Http2PushPolicy,
        maximumConcurrentPushes!: Int64 = 8,
        maximumPendingPushes!: Int64 = 8,
        maximumPushesPerRequest!: Int64 = 8
    ) {
        if (maximumConcurrentPushes <= 0 || maximumConcurrentPushes > 65535 ||
            maximumPendingPushes <= 0 || maximumPendingPushes > maximumConcurrentPushes ||
            maximumPushesPerRequest <= 0 || maximumPushesPerRequest > maximumConcurrentPushes) {
            throw IllegalArgumentException("HTTP/2 push limits are invalid")
        }
        this.policy = policy
        this.maximumConcurrentPushes = maximumConcurrentPushes
        this.maximumPendingPushes = maximumPendingPushes
        this.maximumPushesPerRequest = maximumPushesPerRequest
    }
}

/** Accepts only pushes whose canonical scheme, host and effective port match the parent. */
public class SameOriginHttp2PushPolicy <: Http2PushPolicy {
    /** Creates the canonical same-origin acceptance policy. */
    public init() {}

    /**
     * Compares canonical scheme, case-insensitive host, and effective port.
     * @param parent Parent request URL.
     * @param promised Promised request URL.
     * @param context Caller context, unused by this immediate decision.
     */
    public func allow(parent: HttpUrl, promised: HttpUrl, context: OperationContext): Bool {
        let _ = context
        parent.scheme == promised.scheme &&
            parent.host.toAsciiLower() == promised.host.toAsciiLower() &&
            parent.port == promised.port
    }
}

/** Rejects every offered push without running protocol work on the connection reader. */
public class DenyHttp2PushPolicy <: Http2PushPolicy {
    /** Creates a policy that rejects every offer. */
    public init() {}

    /**
     * Rejects the offered request.
     * @param parent Parent URL, unused by this unconditional policy.
     * @param promised Promised URL, unused by this unconditional policy.
     * @param context Caller context, unused by this immediate decision.
     */
    public func allow(parent: HttpUrl, promised: HttpUrl, context: OperationContext): Bool {
        let _ = parent
        let _ = promised
        let _ = context
        false
    }
}

/** One promised request paired with its uniquely-owned response. */
public class HttpPushedResponse <: Resource {
    /** Promised request metadata associated with the response. */
    public let request: HttpRequest
    /** Response whose body and nested push source belong to this owner. */
    public let response: HttpResponse

    /**
     * Records the request metadata and takes ownership of its response.
     * @param request Promised request metadata.
     * @param response Response transferred to this owner.
     */
    public init(request: HttpRequest, response: HttpResponse) {
        this.request = request
        this.response = response
    }

    /** Closes the owned response and its remaining resources. */
    public func close(): Unit { response.close() }
    /** Reports whether the owned response has released its resources. */
    public func isClosed(): Bool { response.isClosed() }
}

/** Caller-driven source of bounded HTTP/2 push offers. */
public interface HttpPushSource <: Resource {
    /**
     * Receives the next accepted push, or None once the parent and queued offers finish.
     * Only one receiver may be active; closing the source rejects its unclaimed offers.
     * @param context Deadline and cancellation for queue/header waits and the policy call.
     */
    func receive(context!: OperationContext): ?HttpPushedResponse
}
