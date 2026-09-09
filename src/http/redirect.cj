package wirestack.http

import std.collection.ArrayList

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum HttpRedirectErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TooManyRedirects
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InsecureDowngrade
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidLocation
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | BodyNotReplayable
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class HttpRedirectException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: HttpRedirectErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let cause: ?Exception

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cause 导致当前错误的底层异常。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 */
    public init(code: HttpRedirectErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "HttpRedirectException" }
}

/** Immutable redirect policy. Decisions are made before the prior response is drained. */
public class HttpRedirectPolicy {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumRedirects: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let allowHttpsDowngrade: Bool
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumDrainBytes: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param allowHttpsDowngrade 调用方提供的输入值。
 * @param maximumDrainBytes 调用方提供的输入值。
 * @param maximumRedirects 调用方提供的输入值。
 */
    public init(maximumRedirects!: Int64 = 10, allowHttpsDowngrade!: Bool = false,
        maximumDrainBytes!: Int64 = 64 * 1024) {
        if (maximumRedirects < 0 || maximumRedirects > 100 || maximumDrainBytes < 0) {
            throw IllegalArgumentException("HTTP redirect limits are invalid")
        }
        this.maximumRedirects = maximumRedirects
        this.allowHttpsDowngrade = allowHttpsDowngrade
        this.maximumDrainBytes = maximumDrainBytes
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param limits 调用方提供的输入值。
 * @param redirectsFollowed 调用方提供的输入值。
 * @param request 待处理的 HTTP 请求。
 * @param response 处理后的 HTTP 响应。
 */
    public func nextRequest(request: HttpRequest, response: HttpResponse,
        redirectsFollowed!: Int64 = 0, limits!: HttpLimits = HttpLimits()): ?HttpRequest {
        if (!isRedirectStatus(response.status)) { return None<HttpRequest> }
        let location = match (response.headers.getFirst("location")) {
            case Some(value) => value
            case None => return None<HttpRequest>
        }
        if (redirectsFollowed >= maximumRedirects) {
            throw HttpRedirectException(HttpRedirectErrorCode.TooManyRedirects,
                "HTTP redirect limit was exceeded")
        }
        let target = try {
            resolveRedirectUrl(request.url, location)
        } catch (error: Exception) {
            throw HttpRedirectException(HttpRedirectErrorCode.InvalidLocation,
                "HTTP redirect Location is invalid", cause: error)
        }
        if (!allowHttpsDowngrade && request.url.scheme == "https" && target.scheme == "http") {
            throw HttpRedirectException(HttpRedirectErrorCode.InsecureDowngrade,
                "HTTPS to HTTP redirect is disabled")
        }

        let rewriteToGet = response.status == 303 ||
            ((response.status == 301 || response.status == 302) && request.method.value == "POST")
        let nextMethod = if (rewriteToGet && request.method.value != "HEAD") {
            HttpMethod("GET")
        } else {
            request.method
        }
        let nextBody = if (rewriteToGet) { RequestBody.empty() } else { request.body }
        if (!rewriteToGet && request.body.replayability != BodyReplayability.Replayable) {
            throw HttpRedirectException(HttpRedirectErrorCode.BodyNotReplayable,
                "redirect requires replaying a one-shot request body")
        }
        let crossOrigin = request.url.scheme != target.scheme || request.url.host != target.host ||
            request.url.port != target.port
        let headers = redirectedHeaders(
            request.headers,
            crossOrigin,
            rewriteToGet,
            limits
        )
        Some(HttpRequest(
            nextMethod, target, headers: headers, body: nextBody,
            retrySafety: request.retrySafety
        ))
    }
}

private func isRedirectStatus(status: Int64): Bool {
    status == 301 || status == 302 || status == 303 || status == 307 || status == 308
}

private func resolveRedirectUrl(base: HttpUrl, location: String): HttpUrl {
    let lower = location.toAsciiLower()
    if (lower.startsWith("http://") || lower.startsWith("https://")) {
        return canonicalizeRedirectUrl(HttpUrl.parse(location))
    }
    if (location.startsWith("//")) {
        return canonicalizeRedirectUrl(HttpUrl.parse("${base.scheme}:${location}"))
    }
    if (location.startsWith("/")) {
        return HttpUrl.parse("${base.scheme}://${base.authority}${normalizeRedirectTarget(location)}")
    }
    if (location.startsWith("?")) {
        let path = requestPathWithoutQuery(base.requestTarget)
        return HttpUrl.parse("${base.scheme}://${base.authority}${path}${location}")
    }
    if (location.isEmpty()) { return base }
    let combined = "${requestDirectory(base.requestTarget)}${location}"
    HttpUrl.parse("${base.scheme}://${base.authority}${normalizeRedirectTarget(combined)}")
}

private func canonicalizeRedirectUrl(value: HttpUrl): HttpUrl {
    let normalized = normalizeRedirectTarget(value.requestTarget)
    if (normalized == value.requestTarget) { value }
    else { HttpUrl.parse("${value.scheme}://${value.authority}${normalized}") }
}

private func requestPathWithoutQuery(target: String): String {
    let bytes = target.toArray()
    for (index in 0..bytes.size) {
        if (bytes[index] == b'?') {
            let path = Array<Byte>(index, repeat: 0)
            for (offset in 0..index) { path[offset] = bytes[offset] }
            return String.fromUtf8(path)
        }
    }
    target
}

private func requestDirectory(target: String): String {
    let path = requestPathWithoutQuery(target)
    let bytes = path.toArray()
    var lastSlash: Int64 = 0
    for (index in 0..bytes.size) {
        if (bytes[index] == b'/') { lastSlash = index }
    }
    stringPrefix(bytes, lastSlash + 1)
}

private func normalizeRedirectTarget(target: String): String {
    if (!target.startsWith("/")) {
        throw IllegalArgumentException("redirect target path must be absolute")
    }
    let bytes = target.toArray()
    var queryStart = bytes.size
    for (index in 0..bytes.size) {
        if (bytes[index] == b'?') { queryStart = index; break }
    }
    let path = stringPrefix(bytes, queryStart)
    let query = stringRange(bytes, queryStart, bytes.size)
    let segments = ArrayList<String>()
    let parts = path.split("/")
    for (index in 1..parts.size) {
        let part = parts[index]
        if (part == ".") {
            if (index == parts.size - 1) { segments.add("") }
        } else if (part == "..") {
            if (!segments.isEmpty()) { let _ = segments.remove(at: segments.size - 1) }
            if (index == parts.size - 1) { segments.add("") }
        } else {
            segments.add(part)
        }
    }
    var normalized = "/"
    for ((index, segment) in segments.enumerate()) {
        if (index > 0) { normalized += "/" }
        normalized += segment
    }
    "${normalized}${query}"
}

private func stringPrefix(bytes: Array<Byte>, end: Int64): String {
    stringRange(bytes, 0, end)
}

private func stringRange(bytes: Array<Byte>, start: Int64, end: Int64): String {
    let result = Array<Byte>(end - start, repeat: 0)
    for (index in start..end) { result[index - start] = bytes[index] }
    String.fromUtf8(result)
}

private func redirectedHeaders(source: HttpHeaders, crossOrigin: Bool,
    removeBodyHeaders: Bool, limits: HttpLimits): HttpHeaders {
    let builder = HttpHeaders.builder(limits: limits)
    for (entry in source.entries) { builder.add(entry.name, entry.value) }
    if (crossOrigin) {
        builder.remove("authorization")
        builder.remove("proxy-authorization")
        builder.remove("cookie")
        builder.remove("cookie2")
    }
    if (removeBodyHeaders) {
        builder.remove("content-length")
        builder.remove("transfer-encoding")
        builder.remove("content-type")
        builder.remove("content-encoding")
        builder.remove("trailer")
    }
    builder.build()
}
