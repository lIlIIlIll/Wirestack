package wirestack

import std.sync.Mutex

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum HttpRetrySafety {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Default
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ExplicitlySafe
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Disabled
}

/** Immutable request description. Protocol execution owns the body's opened stream, not this model. */
public class HttpRequest {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let method: HttpMethod
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let url: HttpUrl
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let headers: HttpHeaders
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let body: RequestBody
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let retrySafety: HttpRetrySafety

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param body 调用方提供的输入值。
 * @param headers 调用方提供的输入值。
 * @param method 调用方提供的输入值。
 * @param retrySafety 调用方提供的输入值。
 * @param url 调用方提供的输入值。
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
 * Wirestack 公开 API：返回与当前对象关联的值。
 * @param url 调用方提供的输入值。
 */
    public static func get(url: String): HttpRequest {
        HttpRequest(HttpMethod("GET"), HttpUrl.parse(url))
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param body 调用方提供的输入值。
 * @param url 调用方提供的输入值。
 */
    public static func post(url: String, body: RequestBody): HttpRequest {
        HttpRequest(HttpMethod("POST"), HttpUrl.parse(url), body: body)
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param headers 调用方提供的输入值。
 */
    public func withHeaders(headers: HttpHeaders): HttpRequest {
        HttpRequest(method, url, headers: headers, body: body, retrySafety: retrySafety)
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func withRetrySafety(value: HttpRetrySafety): HttpRequest {
        HttpRequest(method, url, headers: headers, body: body, retrySafety: value)
    }
}

/** Pool/connection lifecycle hook. Implementations must not expose their transport through this API. */
public interface ResponseBodyObserver {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    func completed(): Unit
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop contentLength: ?Int64 { get() { stream.contentLength } }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop trailer: ?HttpTrailer { get() { trailerProvider() } }
    /** Whether consuming the declared length proves protocol completion without a later EOF. */
    public prop completesAtDeclaredLength: Bool { get() { completeAtDeclaredLength } }

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param completeAtDeclaredLength 调用方提供的输入值。
 * @param observer 调用方提供的输入值。
 * @param stream 提供连续数据的输入流。
 * @param trailerProvider 调用方提供的输入值。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param observer 调用方提供的输入值。
 */
    public static func empty(observer!: ResponseBodyObserver = NoopResponseBodyObserver()): ResponseBody {
        ResponseBody(RequestBody.empty().open(), observer: observer)
    }

/**
 * Wirestack 公开 API：读取下一段数据并返回实际进度。
 * @param destination 调用方提供的输入值。
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
 * @param bufferSize 调用方提供的输入值。
 * @param maximumBytes 允许读取的最大字节数。
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
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
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
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { synchronized(stateMutex) { closed } }

/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
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
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let status: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let reason: String
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let version: HttpVersion
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let headers: HttpHeaders
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let body: ResponseBody

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param body 调用方提供的输入值。
 * @param headers 调用方提供的输入值。
 * @param reason 描述终止原因的稳定值。
 * @param status 待记录的协议状态码。
 * @param version 调用方提供的输入值。
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
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit { body.close() }
/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { body.isClosed() }
}

private class NoopResponseBodyObserver <: ResponseBodyObserver {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func completed(): Unit {}
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
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
