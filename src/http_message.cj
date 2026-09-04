package wirestack

import std.sync.Mutex

/**
 * Wirestack 公开 API：HttpRetrySafety。
 */
public enum HttpRetrySafety {
/**
 * Wirestack 公开 API：Default。
 */
    | Default
/**
 * Wirestack 公开 API：ExplicitlySafe。
 */
    | ExplicitlySafe
/**
 * Wirestack 公开 API：Disabled。
 */
    | Disabled
}

/** Immutable request description. Protocol execution owns the body's opened stream, not this model. */
public class HttpRequest {
/**
 * Wirestack 公开 API：method。
 */
    public let method: HttpMethod
/**
 * Wirestack 公开 API：url。
 */
    public let url: HttpUrl
/**
 * Wirestack 公开 API：headers。
 */
    public let headers: HttpHeaders
/**
 * Wirestack 公开 API：body。
 */
    public let body: RequestBody
/**
 * Wirestack 公开 API：retrySafety。
 */
    public let retrySafety: HttpRetrySafety

/**
 * Wirestack 公开 API：init。
 * @param body 参数 body。
 * @param headers 参数 headers。
 * @param method 参数 method。
 * @param retrySafety 参数 retrySafety。
 * @param url 参数 url。
 */
    public init(
        method: HttpMethod,
        url: HttpUrl,
        headers!: HttpHeaders = HttpHeaders(),
        body!: RequestBody = RequestBody.empty(),
        retrySafety!: HttpRetrySafety = HttpRetrySafety.Default
    ) {
        this.method = method
        this.url = url
        this.headers = headers
        this.body = body
        this.retrySafety = retrySafety
    }

/**
 * Wirestack 公开 API：get。
 * @param url 参数 url。
 */
    public static func get(url: String): HttpRequest {
        HttpRequest(HttpMethod("GET"), HttpUrl.parse(url))
    }

/**
 * Wirestack 公开 API：post。
 * @param body 参数 body。
 * @param url 参数 url。
 */
    public static func post(url: String, body: RequestBody): HttpRequest {
        HttpRequest(HttpMethod("POST"), HttpUrl.parse(url), body: body)
    }

/**
 * Wirestack 公开 API：withHeaders。
 * @param headers 参数 headers。
 */
    public func withHeaders(headers: HttpHeaders): HttpRequest {
        HttpRequest(method, url, headers: headers, body: body, retrySafety: retrySafety)
    }

/**
 * Wirestack 公开 API：withRetrySafety。
 * @param value 参数 value。
 */
    public func withRetrySafety(value: HttpRetrySafety): HttpRequest {
        HttpRequest(method, url, headers: headers, body: body, retrySafety: value)
    }
}

/** Pool/connection lifecycle hook. Implementations must not expose their transport through this API. */
public interface ResponseBodyObserver {
/**
 * Wirestack 公开 API：completed。
 */
    func completed(): Unit
/**
 * Wirestack 公开 API：abandoned。
 */
    func abandoned(): Unit
}

/**
 * Single-owner response body. EOF completes reuse eligibility; an early close abandons it.
 * Exactly one observer callback is made, including when reading or closing fails.
 */
public class ResponseBody <: Resource {
    private let stream: HttpBodyStream
    private let observer: ResponseBodyObserver
    private let trailerProvider: () -> ?HttpTrailer
    private let completeAtDeclaredLength: Bool
    private let stateMutex = Mutex()
    private var closed = false
    private var readInProgress = false
    private var terminal = false
    private var fullyConsumed = false
    private var consumedBytes: Int64 = 0

/**
 * Wirestack 公开 API：contentLength。
 */
    public prop contentLength: ?Int64 { get() { stream.contentLength } }
/**
 * Wirestack 公开 API：trailer。
 */
    public prop trailer: ?HttpTrailer { get() { trailerProvider() } }
    /** Whether consuming the declared length proves protocol completion without a later EOF. */
    public prop completesAtDeclaredLength: Bool { get() { completeAtDeclaredLength } }

/**
 * Wirestack 公开 API：init。
 * @param completeAtDeclaredLength 参数 completeAtDeclaredLength。
 * @param observer 参数 observer。
 * @param stream 参数 stream。
 * @param trailerProvider 参数 trailerProvider。
 */
    public init(
        stream: HttpBodyStream,
        observer!: ResponseBodyObserver = NoopResponseBodyObserver(),
        trailerProvider!: () -> ?HttpTrailer = { => None<HttpTrailer> },
        completeAtDeclaredLength!: Bool = true
    ) {
        this.stream = stream
        this.observer = observer
        this.trailerProvider = trailerProvider
        this.completeAtDeclaredLength = completeAtDeclaredLength
    }

/**
 * Wirestack 公开 API：empty。
 * @param observer 参数 observer。
 */
    public static func empty(observer!: ResponseBodyObserver = NoopResponseBodyObserver()): ResponseBody {
        ResponseBody(RequestBody.empty().open(), observer: observer)
    }

/**
 * Wirestack 公开 API：read。
 * @param destination 参数 destination。
 */
    public func read(destination: Array<Byte>): Int64 {
        synchronized(stateMutex) {
            if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "HTTP response body is closed") }
            if (readInProgress) {
                throw HttpBodyException(HttpBodyErrorCode.ConcurrentRead, "HTTP response body already has an active reader")
            }
            readInProgress = true
        }

        let count = try {
            stream.read(destination)
        } catch (error: Exception) {
            synchronized(stateMutex) { readInProgress = false }
            abandonAndClose()
            throw error
        }
        synchronized(stateMutex) { readInProgress = false }
        if (count < 0 || count > destination.size) {
            abandonAndClose()
            throw HttpBodyException(
                HttpBodyErrorCode.InvalidProgress,
                "HTTP response body stream returned an invalid read count"
            )
        }
        var reachedDeclaredEnd = false
        if (count > 0) {
            let total = synchronized(stateMutex) { consumedBytes += count; consumedBytes }
            match (contentLength) {
                case Some(expected) =>
                    if (total > expected) {
                        abandonAndClose()
                        throw HttpBodyException(
                            HttpBodyErrorCode.InvalidProgress,
                            "HTTP response body exceeded its declared content length"
                        )
                    }
                    reachedDeclaredEnd = total == expected
                case None => ()
            }
        }
        if (reachedDeclaredEnd && completeAtDeclaredLength) { completeAtEof() }
        if (count == 0 && !destination.isEmpty()) { completeAtEof() }
        count
    }

    /**
     * Consumes and closes at most `maximumBytes` of unread body data.
     * Returns true only when EOF was proven and the connection may remain reusable.
 * @param bufferSize 参数 bufferSize。
 * @param maximumBytes 参数 maximumBytes。
     */
    public func drain(maximumBytes: Int64, bufferSize!: Int64 = 16 * 1024): Bool {
        if (maximumBytes < 0 || bufferSize <= 0 || bufferSize > 1024 * 1024) {
            throw IllegalArgumentException("HTTP response drain limits are invalid")
        }
        let (wasClosed, wasFullyConsumed) = synchronized(stateMutex) { (closed, fullyConsumed) }
        if (wasClosed) { return wasFullyConsumed }
        if (wasFullyConsumed) { close(); return true }

        var drained: Int64 = 0
        while (drained < maximumBytes) {
            let capacity = min(bufferSize, maximumBytes - drained)
            let count = read(Array<Byte>(capacity, repeat: 0))
            if (count == 0) { close(); return true }
            drained += count
        }

        if (isFullyConsumed()) { close(); return true }
        close()
        false
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        var notifyAbandoned = false
        synchronized(stateMutex) {
            if (closed) { return }
            closed = true
            if (!terminal) {
                terminal = true
                notifyAbandoned = !fullyConsumed
            }
        }
        try {
            stream.close()
        } finally {
            if (notifyAbandoned) { observer.abandoned() }
        }
    }

/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { synchronized(stateMutex) { closed } }

/**
 * Wirestack 公开 API：isFullyConsumed。
 */
    public func isFullyConsumed(): Bool { synchronized(stateMutex) { fullyConsumed } }

    private func completeAtEof(): Unit {
        var notify = false
        synchronized(stateMutex) {
            if (!terminal) {
                terminal = true
                fullyConsumed = true
                notify = true
            }
        }
        if (notify) { observer.completed() }
    }

    private func abandonAndClose(): Unit {
        var notify = false
        synchronized(stateMutex) {
            if (!terminal) {
                terminal = true
                notify = true
            }
            closed = true
        }
        try { stream.close() } catch (_: Exception) {}
        if (notify) { observer.abandoned() }
    }
}

/** Immutable response head plus its uniquely-owned streaming body. */
public class HttpResponse <: Resource {
/**
 * Wirestack 公开 API：status。
 */
    public let status: Int64
/**
 * Wirestack 公开 API：reason。
 */
    public let reason: String
/**
 * Wirestack 公开 API：version。
 */
    public let version: HttpVersion
/**
 * Wirestack 公开 API：headers。
 */
    public let headers: HttpHeaders
/**
 * Wirestack 公开 API：body。
 */
    public let body: ResponseBody

/**
 * Wirestack 公开 API：init。
 * @param body 参数 body。
 * @param headers 参数 headers。
 * @param reason 参数 reason。
 * @param status 参数 status。
 * @param version 参数 version。
 */
    public init(
        status: Int64,
        reason: String,
        body: ResponseBody,
        version!: HttpVersion = HttpVersion.Http11,
        headers!: HttpHeaders = HttpHeaders()
    ) {
        if (status < 100 || status > 999) {
            throw IllegalArgumentException("HTTP status must be exactly three decimal digits")
        }
        validateReason(reason)
        this.status = status
        this.reason = reason
        this.version = version
        this.headers = headers
        this.body = body
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit { body.close() }
/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { body.isClosed() }
}

private class NoopResponseBodyObserver <: ResponseBodyObserver {
/**
 * Wirestack 公开 API：completed。
 */
    public func completed(): Unit {}
/**
 * Wirestack 公开 API：abandoned。
 */
    public func abandoned(): Unit {}
}

private func validateReason(reason: String): Unit {
    for (byte in reason.toArray()) {
        if (byte == 0u8 || byte == 10u8 || byte == 13u8 || byte < 32u8 || byte == 127u8) {
            throw IllegalArgumentException("HTTP reason phrase contains a control character")
        }
    }
}
