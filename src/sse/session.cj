package wirestack.sse

import std.random.Random
import std.sync.Mutex
import std.time.MonoTime
import wirestack.*
import wirestack.http.HttpClient
import wirestack.http.HttpException
import wirestack.http.HttpErrorCode

/**
 * Pull-owned SSE response lifetime. No background reader or delivery queue exists.
 * The parsed cursor is not an application acknowledgement; reconnect may duplicate events.
 * Close interrupts only this request/HTTP2 stream, never the shared client or connection.
 */
public class SseSession <: Resource {
    private let client: HttpClient
    private let request: HttpRequest
    private let limits: SseLimits
    private let policy: SseSessionPolicy
    private let reconnect: Bool
    private let readBufferBytes: Int64
    private let source = CancellationSource()
    private let context: OperationContext
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let random = Random()
    private var registration: ?CancellationRegistration = None<CancellationRegistration>
    private var response: ?HttpResponse = None<HttpResponse>
    private var reservation: ?Resource = None<Resource>
    private var decoder: ?SseDecoder = None<SseDecoder>
    private var buffer = Array<Byte>()
    private var offset: Int64 = 0
    private var count: Int64 = 0
    private var active = false
    private var closed = false
    private var completedNormally = false
    private var parentCancelled = false
    private var workspaceReleased = false
    private var cursor = ""
    private var reconnects: Int64 = 0
    private var failure: ?Exception = None<Exception>
    private var retryDelay: Duration

    private init(client: HttpClient, request: HttpRequest, limits: SseLimits,
        policy: SseSessionPolicy, reconnect: Bool, readBufferBytes: Int64, context: OperationContext) {
        if (readBufferBytes < 1 || readBufferBytes > 1024 * 1024) {
            throw IllegalArgumentException("SSE read buffer must be between 1 byte and 1 MiB")
        }
        this.client = client; this.request = request; this.limits = limits; this.policy = policy
        this.reconnect = reconnect; this.readBufferBytes = readBufferBytes
        this.retryDelay = policy.initialRetryDelay
        let bounded = policy.operation(context).withCancellation(source.token)
        this.context = if (bounded.requestId.isSome()) { bounded } else {
            bounded.withEventCorrelation(requestId: Some(nextNetworkCorrelationId()),
                attemptId: None<Int64>, connectionId: None<Int64>, streamId: None<Int64>)
        }
        registration = Some(context.cancellation.register({ =>
            let claim = synchronized(mutex) {
                if (completedNormally || closed) { false } else { parentCancelled = true; true }
            }
            if (claim) { close() }
        }))
    }

    /**
     * Creates a lazy GET session. Only this explicit policy can resubmit the GET.
     * HTTP retries and redirects are disabled so the reconnect count bounds submissions.
     * @param client Shared HTTP client, retained but never closed by the session.
     * @param url GET resource; redirects must be resolved explicitly by the caller.
     * @param headers Additional request headers; Accept and Last-Event-ID are session-owned.
     * @param limits Codec storage and per-event work limits.
     * @param policy Explicit reconnect, duration and active-read idle bounds.
     * @param readBufferBytes Maximum retained unread HTTP body chunk.
     * @param context Parent absolute deadline, cancellation and event correlation.
     * @return A caller-owned pull session, not an asynchronously running EventSource.
     */
    public static func eventSource(client: HttpClient, url: HttpUrl,
        headers!: HttpHeaders = HttpHeaders(), limits!: SseLimits = SseLimits(),
        policy!: SseSessionPolicy = SseSessionPolicy(), readBufferBytes!: Int64 = 16 * 1024,
        context!: OperationContext = OperationContext.background()): SseSession {
        SseSession(client, HttpRequest(HttpMethod("GET"), url, headers: headers), limits,
            policy, true, readBufferBytes, context)
    }

    /**
     * Sends an arbitrary request once and consumes its SSE response without any replay.
     * A replayable POST body and client retry/redirect settings cannot change this rule.
     * @param client Shared HTTP client, retained but never closed by this session.
     * @param request Arbitrary one-shot HTTP request; method, body and Last-Event-ID are preserved.
     * @param limits Codec storage and work bounds.
     * @param policy Lifetime and idle bounds; reconnect count has no effect for this mode.
     * @param readBufferBytes Maximum retained unread body chunk.
     * @param context Parent deadline, cancellation and correlation.
     * @return An owned session that never resubmits the request.
     */
    public static func oneShot(client: HttpClient, request: HttpRequest,
        limits!: SseLimits = SseLimits(), policy!: SseSessionPolicy = SseSessionPolicy(),
        readBufferBytes!: Int64 = 16 * 1024,
        context!: OperationContext = OperationContext.background()): SseSession {
        SseSession(client, request, limits, policy, false, readBufferBytes, context)
    }

    /** Last blank-line-committed parsed cursor, not durable application acknowledgement. */
    public prop lastEventId: String { get() { synchronized(mutex) { cursor } } }
    /** Number of reconnect submissions begun, excluding the original request. */
    public prop reconnectCount: Int64 { get() { synchronized(mutex) { reconnects } } }
    /** Last typed disconnect failure; clean EOF leaves this unset. */
    public prop lastFailure: ?Exception { get() { synchronized(mutex) { failure } } }
    /** Stable logical request correlation shared by all explicit reconnect attempts. */
    public prop requestId: Int64 { get() { context.requestId.getOrThrow() } }
    /** Conservative retained-storage reservation in the client's actual managed-buffer ledger. */
    public prop reservedBufferBytes: UInt64 { get() { limits.maximumRetainedBytes + UInt64(readBufferBytes) } }

    /**
     * Receives one complete event, or None after 204 or normal one-shot/default-policy EOF.
     * No further body read occurs until the caller requests another event.
     * Codec limits, invalid responses, exhausted reconnects and cancellation close all owned resources.
     * @return One decoded event, including explicit empty data, or terminal completion.
     */
    public func receive(): ?SseEvent {
        synchronized(mutex) {
            if (closed) {
                if (parentCancelled) { checkSseContext(this.context) }
                if (completedNormally) { return None<SseEvent> }
                throw SseException(SseErrorCode.Closed, "SSE session closed")
            }
            if (active) { throw SseException(SseErrorCode.ConcurrentOperation, "SSE receive already active") }
            active = true
        }
        try {
            ensureWorkspace()
            while (true) {
                checkSseContext(context)
                if (synchronized(mutex) { response.isNone() }) {
                    try {
                        if (!openResponse()) { endNormally(); return None<SseEvent> }
                    } catch (error: Exception) {
                        if (!recoverableSseFailure(error)) { throw error }
                        synchronized(mutex) { failure = Some(error) }
                        reconnectAfterEnd(error: Some(error))
                        continue
                    }
                }
                if (offset < count) {
                    let codec = decoder.getOrThrow()
                    let parsed = codec.decode(buffer, offset: offset, length: Some(count - offset))
                    offset += parsed.consumed
                    synchronized(mutex) { cursor = codec.lastEventId }
                    if (let Some(value) <- codec.retryMilliseconds) {
                        retryDelay = min(policy.maximumRetryDelay,
                            max(policy.minimumRetryDelay, Int64(value) * Duration.millisecond))
                    }
                    if (parsed.event.isSome()) { checkSseContext(context); return parsed.event }
                }
                let body = synchronized(mutex) { response.getOrThrow().body }
                var readFailure: ?Exception = None<Exception>
                count = try { body.read(buffer) } catch (error: Exception) {
                    readFailure = Some(error); 0
                }
                offset = 0
                if (let Some(error) <- readFailure) {
                    synchronized(mutex) { failure = Some(error) }
                    if (!recoverableSseFailure(error)) { throw error }
                    reconnectAfterEnd(error: Some(error))
                } else if (count == 0) {
                    decoder.getOrThrow().finish()
                    if (!reconnect || policy.maximumReconnects == 0) { endNormally(); return None<SseEvent> }
                    reconnectAfterEnd()
                }
            }
            throw IllegalStateException("unreachable SSE receive")
        } catch (error: Exception) {
            let localClose = synchronized(mutex) { closed && !parentCancelled && !completedNormally }
            close()
            if (localClose) { throw SseException(SseErrorCode.Closed, "SSE session closed", cause: Some(error)) }
            throw error
        } finally {
            synchronized(mutex) { active = false }
            releaseWorkspaceIfClosed()
        }
    }

    private func ensureWorkspace(): Unit {
        if (reservation.isSome()) { return }
        let lease = client.reserveResponseBuffer(request.url, reservedBufferBytes, context: context)
        var kept = false
        try {
            checkSseContext(context)
            synchronized(mutex) {
                if (!closed) { reservation = Some(lease); kept = true }
            }
            if (!kept) { checkSseContext(context); throw SseException(SseErrorCode.Closed, "SSE session closed") }
            buffer = Array<Byte>(readBufferBytes, repeat: 0u8)
            decoder = Some(SseDecoder(limits: limits))
        } finally { if (!kept) { lease.close() } }
    }

    private func openResponse(): Bool {
        checkSseContext(context)
        let headers = HttpHeaders.builder(limits: client.configuredLimits())
        for (entry in request.headers.entries) {
            let name = entry.name.toAsciiLower()
            if (name != "accept" && (!reconnect || name != "last-event-id")) {
                headers.add(entry.name, entry.value)
            }
        }
        headers.add("Accept", "text/event-stream")
        if (reconnect && !cursor.isEmpty()) {
            try { headers.add("Last-Event-ID", cursor) } catch (error: Exception) {
                throw SseException(SseErrorCode.InvalidMetadata, "SSE cursor cannot be used as a header", cause: Some(error))
            }
        }
        let opened = client.sendOnce(request.withHeaders(headers.build()), context: context)
        var kept = false
        try {
            checkSseContext(context)
            if (opened.status == 204) { return false }
            let contentType = opened.headers.getFirst("content-type").getOrDefault({ => "" })
            let fields = contentType.split(";")
            let mime = if (fields.isEmpty()) { "" } else { fields[0].trimAscii().toAsciiLower() }
            if (opened.status != 200 || mime != "text/event-stream") {
                throw SseException(SseErrorCode.InvalidResponse, "SSE requires status 200 and text/event-stream")
            }
            synchronized(mutex) {
                if (!closed) { response = Some(opened); kept = true }
            }
            if (!kept) { checkSseContext(context); throw SseException(SseErrorCode.Closed, "SSE session closed") }
            return true
        } finally { if (!kept) { opened.close() } }
    }

    private func reconnectAfterEnd(error!: ?Exception = None<Exception>): Unit {
        releaseResponse()
        checkSseContext(context)
        if (!reconnect || reconnects >= policy.maximumReconnects) {
            throw SseException(SseErrorCode.ReconnectLimit, "SSE reconnect budget exhausted", cause: error)
        }
        let duration = jitteredDelay()
        waitBackoff(duration)
        decoder.getOrThrow().close()
        decoder = Some(SseDecoder(limits: limits, lastEventId: cursor))
        offset = 0; count = 0
        synchronized(mutex) { reconnects++ }
        retryDelay = min(policy.maximumRetryDelay, retryDelay * 2)
    }

    private func jitteredDelay(): Duration {
        let base = retryDelay.toNanoseconds()
        let magnitude = base / 1000 * policy.jitterPermille
        if (magnitude == 0) { return retryDelay }
        let delta = Int64(random.nextUInt64(UInt64(magnitude * 2 + 1))) - magnitude
        min(policy.maximumRetryDelay,
            max(policy.minimumRetryDelay, Duration.nanosecond * (base + delta)))
    }

    private func waitBackoff(delay: Duration): Unit {
        let until = MonoTime.now() + delay
        let wake = context.cancellation.register({ => synchronized(mutex) { changed.notifyAll() } })
        try {
            while (true) {
                checkSseContext(context)
                let now = MonoTime.now()
                if (now >= until) { return }
                let remaining = context.deadline.getOrThrow().remaining()
                synchronized(mutex) {
                    if (!closed && !context.isCancellationRequested()) {
                        changed.wait(timeout: min(until - now, remaining))
                    }
                }
            }
        } finally { wake.unregister() }
    }

    private func releaseResponse(): Unit {
        let owned = synchronized(mutex) { let value = response; response = None<HttpResponse>; value }
        if (let Some(value) <- owned) { value.close() }
    }

    private func endNormally(): Unit {
        let claimed = synchronized(mutex) {
            if (closed || parentCancelled) { false } else { completedNormally = true; true }
        }
        if (!claimed) {
            // A concurrent local close or parent cancellation already owns the terminal outcome.
            let cancelled = synchronized(mutex) { parentCancelled }
            close()
            if (cancelled) { checkSseContext(context) }
            throw SseException(SseErrorCode.Closed, "SSE session closed")
        }
        close()
    }

    /** Closes this response/stream and wakes backoff; shared HTTP clients and siblings survive. */
    public func close(): Unit {
        let changedState = synchronized(mutex) {
            if (closed) { false } else { closed = true; changed.notifyAll(); true }
        }
        if (changedState) {
            source.cancel()
            if (let Some(value) <- registration) { value.unregister() }
            releaseResponse()
        }
        releaseWorkspaceIfClosed()
    }
    /** Whether this session can no longer receive events. */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func releaseWorkspaceIfClosed(): Unit {
        let release = synchronized(mutex) {
            if (!closed || active || workspaceReleased) { false }
            else { workspaceReleased = true; true }
        }
        if (release) {
            if (let Some(value) <- decoder) { value.close(); decoder = None<SseDecoder> }
            buffer = Array<Byte>(); offset = 0; count = 0
            if (let Some(value) <- reservation) { reservation = None<Resource>; value.close() }
        }
    }
}

internal func checkSseContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody,
            NetworkErrorCode.Cancelled, "SSE operation cancelled", retryability: Retryability.Never)
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody,
            NetworkErrorCode.TimedOut, "SSE operation deadline exceeded", retryability: Retryability.Temporary)
    }
}

private func recoverableSseFailure(error: Exception): Bool {
    match (error) {
        case value: NetworkException => match (value.code) {
            case NetworkErrorCode.ConnectionReset | NetworkErrorCode.BrokenPipe |
                NetworkErrorCode.UnexpectedEof | NetworkErrorCode.ConnectRefused |
                NetworkErrorCode.NetworkUnreachable | NetworkErrorCode.HostUnreachable => true
            case _ => false
        }
        case value: HttpException => match (value.code) {
            case HttpErrorCode.StreamReset | HttpErrorCode.ConnectionGoAway => true
            case _ => false
        }
        case _ => false
    }
}
