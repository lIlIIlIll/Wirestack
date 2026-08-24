package wirestack.http

import std.collection.ArrayList

public enum HttpRedirectErrorCode {
    | TooManyRedirects
    | InsecureDowngrade
    | InvalidLocation
    | BodyNotReplayable
}

public class HttpRedirectException <: Exception {
    public let code: HttpRedirectErrorCode
    public let cause: ?Exception

    public init(code: HttpRedirectErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

    protected override func getClassName(): String { "HttpRedirectException" }
}

/** Immutable redirect policy. Decisions are made before the prior response is drained. */
public class HttpRedirectPolicy {
    public let maximumRedirects: Int64
    public let allowHttpsDowngrade: Bool
    public let maximumDrainBytes: Int64

    public init(maximumRedirects!: Int64 = 10, allowHttpsDowngrade!: Bool = false,
        maximumDrainBytes!: Int64 = 64 * 1024) {
        if (maximumRedirects < 0 || maximumRedirects > 100 || maximumDrainBytes < 0) {
            throw IllegalArgumentException("HTTP redirect limits are invalid")
        }
        this.maximumRedirects = maximumRedirects
        this.allowHttpsDowngrade = allowHttpsDowngrade
        this.maximumDrainBytes = maximumDrainBytes
    }

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
        Some(HttpRequest(nextMethod, target, headers: headers, body: nextBody))
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
