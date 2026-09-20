package wirestack.http

import std.collection.ArrayList
import std.convert.Parsable
import std.sync.Mutex
import std.time.DateTime
import wirestack as api
import wirestack.internal.http_model.cookieDomainCrossesPublicSuffix

private const COOKIE_NAME_BYTES: Int64 = 256
private const COOKIE_VALUE_BYTES: Int64 = 4096
private const COOKIE_DOMAIN_BYTES: Int64 = 253
private const COOKIE_PATH_BYTES: Int64 = 1024
private const SET_COOKIE_BYTES: Int64 = 8192
private const SET_COOKIE_FIELDS: Int64 = 64

/** Immutable, bounded HTTP cookie metadata and value. */
public class Cookie {
    /** Cookie name. */
    public let cookieName: String
    /** Cookie value. */
    public let cookieValue: String
    /** Absolute expiry metadata, when supplied. */
    public let expires: ?DateTime
    /** Relative lifetime in seconds. Max-Age takes precedence over Expires in a jar. */
    public let maxAge: ?Int64
    /** Normalized Domain attribute, or an empty string for a host-only cookie. */
    public let domain: String
    /** Path attribute, or an empty string when a jar must apply the RFC default path. */
    public let path: String
    /** Whether the cookie may be sent only over HTTPS. */
    public let secure: Bool
    /** HTTP-only metadata. This non-browser client does not expose a script API. */
    public let httpOnly: Bool

    /**
     * Constructs a validated cookie. Values use the RFC cookie-octet subset and are not quoted or escaped.
     * @param name Cookie name.
     * @param value Cookie value.
     * @param expires Optional absolute expiry.
     * @param maxAge Optional relative lifetime in seconds.
     * @param domain Optional Domain attribute; a leading dot is normalized away.
     * @param path Optional Path attribute.
     * @param secure Whether the Secure attribute is present.
     * @param httpOnly Whether the HttpOnly attribute is present.
     */
    public init(
        name: String,
        value: String,
        expires!: ?DateTime = None<DateTime>,
        maxAge!: ?Int64 = None<Int64>,
        domain!: String = "",
        path!: String = "",
        secure!: Bool = false,
        httpOnly!: Bool = false
    ) {
        requireCookieName(name)
        requireCookieValue(value)
        let normalizedDomain = normalizeCookieDomain(domain, allowEmpty: true)
        requireCookiePath(path, allowEmpty: true)
        if (let Some(at) <- expires) {
            let year = at.inUTC().year
            if (year < 1601 || year > 9999) {
                throw IllegalArgumentException("cookie expiry year must be in 1601..9999")
            }
        }
        cookieName = name
        cookieValue = value
        this.expires = expires
        this.maxAge = maxAge
        this.domain = normalizedDomain
        this.path = path
        this.secure = secure
        this.httpOnly = httpOnly
    }

    /** Serializes this cookie as one safe Set-Cookie field value. */
    public func toSetCookieString(): String {
        var result = "${cookieName}=${cookieValue}"
        if (let Some(value) <- expires) { result += "; Expires=${formatCookieDate(value)}" }
        if (let Some(value) <- maxAge) { result += "; Max-Age=${value}" }
        if (!domain.isEmpty()) { result += "; Domain=${domain}" }
        if (!path.isEmpty()) { result += "; Path=${path}" }
        if (secure) { result += "; Secure" }
        if (httpOnly) { result += "; HttpOnly" }
        result
    }
}

/** Thread-safe bounded in-memory HTTP-client cookie jar; it does not implement browser SameSite policy. */
public class CookieJar {
    /** Maximum number of live cookie identities retained by the jar. */
    public let maximumCookies: Int64
    /** Maximum Cookie request-header bytes produced by headerFor. */
    public let maximumHeaderBytes: Int64

    private let suffixes: Array<String>
    private let mutex = Mutex()
    private var entries = ArrayList<StoredCookie>()
    private var nextSequence: Int64 = 1

    /**
     * Constructs a bounded jar. The maintained bundled PSL is always enforced; rejectPublicSuffixes adds exact rejections.
     * @param maximumCookies Maximum live cookie identities.
     * @param maximumHeaderBytes Maximum serialized Cookie request-header bytes.
     * @param rejectPublicSuffixes Additional exact normalized Domain values to reject.
     */
    public init(
        maximumCookies!: Int64 = 256,
        maximumHeaderBytes!: Int64 = 8192,
        rejectPublicSuffixes!: Array<String> = Array<String>()
    ) {
        if (maximumCookies <= 0 || maximumCookies > 4096) {
            throw IllegalArgumentException("cookie jar count bound must be in 1..4096")
        }
        if (maximumHeaderBytes <= 0 || maximumHeaderBytes > 1048576) {
            throw IllegalArgumentException("cookie header byte bound must be in 1..1048576")
        }
        if (rejectPublicSuffixes.size > 256) {
            throw IllegalArgumentException("cookie public-suffix blacklist has too many entries")
        }
        let normalized = ArrayList<String>()
        for (suffix in rejectPublicSuffixes) {
            let value = normalizeCookieDomain(suffix, allowEmpty: false)
            if (cookieIpHost(value)) {
                throw IllegalArgumentException("cookie public-suffix blacklist must contain DNS names")
            }
            if (!normalized.contains(value)) { normalized.add(value) }
        }
        this.maximumCookies = maximumCookies
        this.maximumHeaderBytes = maximumHeaderBytes
        suffixes = normalized.toArray()
    }

    /** Returns an owned copy of the configured exact-domain rejection list. */
    public prop rejectPublicSuffixes: Array<String> { get() { suffixes.clone() } }

    /**
     * Stores a validated cookie relative to url. Empty Domain creates a host-only cookie.
     * @param cookie Cookie to store.
     * @param url URL defining origin host and default path.
     * @param context Shared operation context; local bounded storage does not wait.
     * @return true when accepted, including an expiry-driven removal.
     */
    public func store(
        cookie: Cookie,
        url: HttpUrl,
        context!: api.OperationContext = api.OperationContext.background()
    ): Bool {
        let _ = context
        let prepared = prepareStoredCookie(cookie, url)
        match (prepared) {
            case None => false
            case Some(candidate) => commitPrepared(candidate, url)
        }
    }

    /**
     * Parses and applies one bounded Set-Cookie field value relative to url.
     * Invalid syntax, foreign or public-suffix domains, insecure overlays and header injection are rejected.
     * @param value One Set-Cookie field value.
     * @param url Response URL defining origin scope.
     * @param context Shared operation context; local bounded parsing does not wait.
     * @return true when the field was accepted, including deletion of a missing identity.
     */
    public func acceptSetCookie(
        value: String,
        url: HttpUrl,
        context!: api.OperationContext = api.OperationContext.background()
    ): Bool {
        let _ = context
        if (!safeSetCookieInput(value)) { return false }
        let fields = value.split(";")
        if (fields.isEmpty() || fields.size > SET_COOKIE_FIELDS) { return false }
        let pair = fields[0].trimAscii()
        let separator = cookieFirstEquals(pair)
        if (separator <= 0) { return false }
        let pairBytes = pair.toArray()
        let name = cookieStringRange(pairBytes, 0, separator).trimAscii()
        let rawValue = cookieStringRange(pairBytes, separator + 1, pairBytes.size).trimAscii()
        let cookieValue = unwrapCookieValue(rawValue)
        if (cookieValue.isNone()) { return false }

        var domain = ""
        var path = ""
        var secure = false
        var httpOnly = false
        var expires = None<DateTime>
        var maxAge = None<Int64>
        for (index in 1..fields.size) {
            let field = fields[index].trimAscii()
            if (field.isEmpty()) { continue }
            let equals = cookieFirstEquals(field)
            let bytes = field.toArray()
            let attributeName = if (equals < 0) { field.toAsciiLower() }
                else { cookieStringRange(bytes, 0, equals).trimAscii().toAsciiLower() }
            let attributeValue = if (equals < 0) { "" }
                else { cookieStringRange(bytes, equals + 1, bytes.size).trimAscii() }
            if (attributeName == "secure") {
                secure = true
            } else if (attributeName == "httponly") {
                httpOnly = true
            } else if (attributeName == "domain" && equals >= 0) {
                if (attributeValue.isEmpty()) { return false }
                domain = try {
                    normalizeCookieDomain(attributeValue, allowEmpty: false)
                } catch (_: IllegalArgumentException) { return false }
            } else if (attributeName == "path" && equals >= 0) {
                if (validCookiePath(attributeValue, allowEmpty: false)) { path = attributeValue }
            } else if (attributeName == "expires" && equals >= 0) {
                if (let Some(parsed) <- parseCookieDate(attributeValue)) { expires = Some(parsed) }
            } else if (attributeName == "max-age" && equals >= 0) {
                if (let Some(parsed) <- parseCookieMaxAge(attributeValue)) { maxAge = Some(parsed) }
            }
        }

        let parsed = try {
            Cookie(
                name,
                cookieValue.getOrThrow(),
                expires: expires,
                maxAge: maxAge,
                domain: domain,
                path: path,
                secure: secure,
                httpOnly: httpOnly
            )
        } catch (_: IllegalArgumentException) { return false }
        let prepared = prepareStoredCookie(parsed, url)
        match (prepared) {
            case None => false
            case Some(candidate) => commitPrepared(candidate, url)
        }
    }

    /**
     * Returns matching live cookies in deterministic request order: longest path, then oldest identity.
     * @param url Request URL.
     * @param context Shared operation context; local bounded selection does not wait.
     */
    public func cookiesFor(
        url: HttpUrl,
        context!: api.OperationContext = api.OperationContext.background()
    ): Array<Cookie> {
        let _ = context
        synchronized(mutex) {
            purgeExpired(DateTime.nowUTC())
            let selected = select(url)
            let result = ArrayList<Cookie>()
            for (entry in selected) { result.add(entry.cookie) }
            result.toArray()
        }
    }

    /**
     * Builds a bounded Cookie request-header value for url.
     * @param url Request URL.
     * @param context Shared operation context; local bounded selection does not wait.
     */
    public func headerFor(
        url: HttpUrl,
        context!: api.OperationContext = api.OperationContext.background()
    ): String {
        let _ = context
        synchronized(mutex) {
            purgeExpired(DateTime.nowUTC())
            let selected = select(url)
            var result = ""
            for (entry in selected) {
                let pairBytes = entry.cookie.cookieName.size + 1 + entry.cookie.cookieValue.size
                let separatorBytes = if (result.isEmpty()) { 0 } else { 2 }
                if (pairBytes + separatorBytes > maximumHeaderBytes - result.size) { break }
                if (!result.isEmpty()) { result += "; " }
                result += "${entry.cookie.cookieName}=${entry.cookie.cookieValue}"
            }
            result
        }
    }

    /**
     * Removes one identity scoped to url.host and path. A missing identity is a no-op.
     * @param name Cookie name.
     * @param url URL whose exact host identifies the stored domain.
     * @param path Exact cookie path.
     * @return true when an identity was removed.
     */
    public func remove(name: String, url: HttpUrl, path!: String = "/"): Bool {
        requireCookieName(name)
        requireCookiePath(path, allowEmpty: false)
        synchronized(mutex) {
            purgeExpired(DateTime.nowUTC())
            removeKey(name, url.host.toAsciiLower(), path)
        }
    }

    /**
     * Removes every cookie whose effective domain exactly equals domain.
     * @param domain Exact effective domain to remove.
     * @return number of removed identities.
     */
    public func removeCookies(domain: String): Int64 {
        let normalized = normalizeCookieDomain(domain, allowEmpty: false)
        synchronized(mutex) {
            purgeExpired(DateTime.nowUTC())
            var removed: Int64 = 0
            var index: Int64 = entries.size - 1
            while (index >= 0) {
                if (entries[index].effectiveDomain == normalized) {
                    let _ = entries.remove(at: index)
                    removed++
                }
                index--
            }
            removed
        }
    }

    /** Removes all stored cookies. */
    public func clear(): Unit { synchronized(mutex) { entries = ArrayList<StoredCookie>() } }

    /** Returns an immutable-cookie snapshot in stable creation order after removing expired entries. */
    public func snapshot(): Array<Cookie> {
        synchronized(mutex) {
            purgeExpired(DateTime.nowUTC())
            let result = ArrayList<Cookie>()
            for (entry in entries) { result.add(entry.cookie) }
            result.toArray()
        }
    }

    private func prepareStoredCookie(cookie: Cookie, url: HttpUrl): ?PreparedCookie {
        if (cookie.secure && url.scheme != "https") { return None<PreparedCookie> }
        let origin = url.host.toAsciiLower()
        let hostOnly = cookie.domain.isEmpty()
        let effectiveDomain = if (hostOnly) { origin } else { cookie.domain }
        if (!hostOnly) {
            if (cookieIpHost(origin) || !cookieDomainMatches(effectiveDomain, origin) ||
                cookieDomainCrossesPublicSuffix(effectiveDomain, origin) || rejectedSuffix(effectiveDomain)) {
                return None<PreparedCookie>
            }
        }
        let effectivePath = if (cookie.path.isEmpty()) { defaultCookiePath(url.requestTarget) } else { cookie.path }
        let scoped = if (effectivePath == cookie.path) { cookie } else {
            Cookie(
                cookie.cookieName,
                cookie.cookieValue,
                expires: cookie.expires,
                maxAge: cookie.maxAge,
                domain: cookie.domain,
                path: effectivePath,
                secure: cookie.secure,
                httpOnly: cookie.httpOnly
            )
        }
        Some(PreparedCookie(scoped, effectiveDomain, hostOnly))
    }

    private func rejectedSuffix(domain: String): Bool {
        for (suffix in suffixes) { if (domain == suffix) { return true } }
        false
    }

    private func commitPrepared(candidate: PreparedCookie, url: HttpUrl): Bool {
        synchronized(mutex) {
            let now = DateTime.nowUTC()
            purgeExpired(now)
            if (!admittedPrepared(candidate, url)) {
                false
            } else {
                storePrepared(candidate, now, url.scheme == "https")
            }
        }
    }

    private func admittedPrepared(candidate: PreparedCookie, url: HttpUrl): Bool {
        if (url.scheme == "https") { return true }
        // The storage rule is intentionally asymmetric: an equal or deeper candidate path overlays.
        for (existing in entries) {
            if (existing.cookie.secure &&
                existing.cookie.cookieName == candidate.cookie.cookieName &&
                (cookieDomainMatches(existing.effectiveDomain, candidate.effectiveDomain) ||
                    cookieDomainMatches(candidate.effectiveDomain, existing.effectiveDomain)) &&
                cookiePathMatches(existing.cookie.path, candidate.cookie.path)) {
                return false
            }
        }
        true
    }

    private func storePrepared(candidate: PreparedCookie, now: DateTime, secureOrigin: Bool): Bool {
        let expiry = cookieExpiry(candidate.cookie, now)
        let existing = findKey(
            candidate.cookie.cookieName,
            candidate.effectiveDomain,
            candidate.cookie.path
        )
        if (expiry.deleteNow) {
            if (existing >= 0) { let _ = entries.remove(at: existing) }
            return true
        }
        if (existing >= 0) {
            let sequence = entries[existing].sequence
            entries[existing] = StoredCookie(
                candidate.cookie,
                candidate.effectiveDomain,
                candidate.hostOnly,
                expiry.at,
                sequence
            )
            return true
        }
        if (entries.size >= maximumCookies) {
            var victim: Int64 = 0
            if (!secureOrigin) {
                while (victim < entries.size && entries[victim].cookie.secure) { victim++ }
                if (victim == entries.size) { return false }
            }
            let _ = entries.remove(at: victim)
        }
        entries.add(StoredCookie(
            candidate.cookie,
            candidate.effectiveDomain,
            candidate.hostOnly,
            expiry.at,
            nextSequence
        ))
        nextSequence++
        true
    }

    private func select(url: HttpUrl): ArrayList<StoredCookie> {
        let selected = ArrayList<StoredCookie>()
        let host = url.host.toAsciiLower()
        let path = cookieRequestPath(url.requestTarget)
        let secureRequest = url.scheme == "https"
        for (entry in entries) {
            if (entry.cookie.secure && !secureRequest) { continue }
            if (entry.hostOnly) {
                if (host != entry.effectiveDomain) { continue }
            } else if (!cookieDomainMatches(entry.effectiveDomain, host)) {
                continue
            }
            if (!cookiePathMatches(entry.cookie.path, path)) { continue }
            var at: Int64 = selected.size
            for (index in 0..selected.size) {
                let current = selected[index]
                if (entry.cookie.path.size > current.cookie.path.size ||
                    (entry.cookie.path.size == current.cookie.path.size && entry.sequence < current.sequence)) {
                    at = index
                    break
                }
            }
            selected.add(entry, at: at)
        }
        selected
    }

    private func purgeExpired(now: DateTime): Unit {
        var index: Int64 = entries.size - 1
        while (index >= 0) {
            if (let Some(expiry) <- entries[index].expiresAt) {
                if (expiry <= now) { let _ = entries.remove(at: index) }
            }
            index--
        }
    }

    private func findKey(name: String, domain: String, path: String): Int64 {
        for (index in 0..entries.size) {
            let entry = entries[index]
            if (entry.cookie.cookieName == name && entry.effectiveDomain == domain && entry.cookie.path == path) {
                return index
            }
        }
        -1
    }

    private func removeKey(name: String, domain: String, path: String): Bool {
        let index = findKey(name, domain, path)
        if (index < 0) { return false }
        let _ = entries.remove(at: index)
        true
    }
}

private class PreparedCookie {
    let cookie: Cookie
    let effectiveDomain: String
    let hostOnly: Bool
    init(cookie: Cookie, effectiveDomain: String, hostOnly: Bool) {
        this.cookie = cookie
        this.effectiveDomain = effectiveDomain
        this.hostOnly = hostOnly
    }
}

private class StoredCookie {
    let cookie: Cookie
    let effectiveDomain: String
    let hostOnly: Bool
    let expiresAt: ?DateTime
    let sequence: Int64
    init(cookie: Cookie, effectiveDomain: String, hostOnly: Bool, expiresAt: ?DateTime, sequence: Int64) {
        this.cookie = cookie
        this.effectiveDomain = effectiveDomain
        this.hostOnly = hostOnly
        this.expiresAt = expiresAt
        this.sequence = sequence
    }
}

private class CookieExpiry {
    let at: ?DateTime
    let deleteNow: Bool
    init(at: ?DateTime, deleteNow: Bool) { this.at = at; this.deleteNow = deleteNow }
}

private class ParsedCookieTime {
    let hour: Int64
    let minute: Int64
    let second: Int64
    init(hour: Int64, minute: Int64, second: Int64) {
        this.hour = hour
        this.minute = minute
        this.second = second
    }
}

private func cookieExpiry(cookie: Cookie, now: DateTime): CookieExpiry {
    match (cookie.maxAge) {
        case Some(seconds) =>
            if (seconds <= 0) { return CookieExpiry(None<DateTime>, true) }
            let at = try { now.addSeconds(seconds) }
                catch (_: Exception) {
                    DateTime.ofUTC(year: 9999, month: 12, dayOfMonth: 31, hour: 23, minute: 59, second: 59)
                }
            CookieExpiry(Some(at), false)
        case None => match (cookie.expires) {
            case Some(at) => CookieExpiry(Some(at), at <= now)
            case None => CookieExpiry(None<DateTime>, false)
        }
    }
}

private func safeSetCookieInput(value: String): Bool {
    if (value.isEmpty() || value.size > SET_COOKIE_BYTES) { return false }
    for (byte in value.toArray()) {
        if (byte < 32u8 || byte >= 127u8) { return false }
    }
    true
}

private func requireCookieName(value: String): Unit {
    if (value.isEmpty() || value.size > COOKIE_NAME_BYTES) {
        throw IllegalArgumentException("cookie name length is invalid")
    }
    for (byte in value.toArray()) {
        if (byte <= 32u8 || byte >= 127u8 || byte == b'(' || byte == b')' || byte == b'<' ||
            byte == b'>' || byte == b'@' || byte == b',' || byte == b';' || byte == b':' ||
            byte == b'\\' || byte == b'"' || byte == b'/' || byte == b'[' || byte == b']' ||
            byte == b'?' || byte == b'=' || byte == b'{' || byte == b'}') {
            throw IllegalArgumentException("cookie name is not an HTTP token")
        }
    }
}

private func requireCookieValue(value: String): Unit {
    if (value.size > COOKIE_VALUE_BYTES) {
        throw IllegalArgumentException("cookie value exceeds its byte bound")
    }
    for (byte in value.toArray()) {
        if (!cookieOctet(byte)) { throw IllegalArgumentException("cookie value contains an invalid byte") }
    }
}

private func cookieOctet(value: Byte): Bool {
    value == 0x21u8 || (value >= 0x23u8 && value <= 0x2bu8) ||
        (value >= 0x2du8 && value <= 0x3au8) ||
        (value >= 0x3cu8 && value <= 0x5bu8) ||
        (value >= 0x5du8 && value <= 0x7eu8)
}

private func unwrapCookieValue(value: String): ?String {
    if (value.size >= 2 && value.startsWith("\"") && value.endsWith("\"")) {
        let bytes = value.toArray()
        let inner = cookieStringRange(bytes, 1, bytes.size - 1)
        try { requireCookieValue(inner); Some(inner) }
        catch (_: IllegalArgumentException) { None<String> }
    } else {
        try { requireCookieValue(value); Some(value) }
        catch (_: IllegalArgumentException) { None<String> }
    }
}

private func normalizeCookieDomain(value: String, allowEmpty!: Bool): String {
    if (value.isEmpty()) {
        if (allowEmpty) { return "" }
        throw IllegalArgumentException("cookie domain must not be empty")
    }
    if (value.size > COOKIE_DOMAIN_BYTES + 1) {
        throw IllegalArgumentException("cookie domain exceeds its byte bound")
    }
    var normalized = value.toAsciiLower()
    if (normalized.startsWith(".")) {
        let bytes = normalized.toArray()
        normalized = cookieStringRange(bytes, 1, bytes.size)
    }
    if (normalized.isEmpty() || normalized.size > COOKIE_DOMAIN_BYTES || normalized.endsWith(".")) {
        throw IllegalArgumentException("cookie domain is invalid")
    }
    let labels = normalized.split(".")
    for (label in labels) {
        let bytes = label.toArray()
        if (bytes.isEmpty() || bytes.size > 63 || !cookieAlphaNumeric(bytes[0]) ||
            !cookieAlphaNumeric(bytes[bytes.size - 1])) {
            throw IllegalArgumentException("cookie domain contains an invalid DNS label")
        }
        for (byte in bytes) {
            if (!cookieAlphaNumeric(byte) && byte != b'-') {
                throw IllegalArgumentException("cookie domain must be an ASCII DNS name")
            }
        }
    }
    normalized
}

private func requireCookiePath(value: String, allowEmpty!: Bool): Unit {
    if (!validCookiePath(value, allowEmpty: allowEmpty)) {
        throw IllegalArgumentException("cookie path is invalid")
    }
}

private func validCookiePath(value: String, allowEmpty!: Bool): Bool {
    if (value.isEmpty()) { return allowEmpty }
    if (value.size > COOKIE_PATH_BYTES || !value.startsWith("/")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x21u8 || byte >= 0x7fu8 || byte == b';') { return false }
    }
    true
}

private func cookieAlphaNumeric(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'0' && value <= b'9')
}

private func cookieIpHost(value: String): Bool {
    if (value.contains(":")) { return true }
    var numeric = true
    for (byte in value.toArray()) {
        if ((byte < b'0' || byte > b'9') && byte != b'.') { numeric = false }
    }
    numeric
}

private func cookieDomainMatches(domain: String, host: String): Bool {
    host == domain || host.endsWith(".${domain}")
}

private func cookieRequestPath(target: String): String {
    let bytes = target.toArray()
    for (index in 0..bytes.size) {
        if (bytes[index] == b'?') { return cookieStringRange(bytes, 0, index) }
    }
    target
}

private func defaultCookiePath(target: String): String {
    let path = cookieRequestPath(target)
    if (path.isEmpty() || !path.startsWith("/")) { return "/" }
    let bytes = path.toArray()
    var lastSlash: Int64 = 0
    for (index in 1..bytes.size) { if (bytes[index] == b'/') { lastSlash = index } }
    if (lastSlash == 0) { "/" } else { cookieStringRange(bytes, 0, lastSlash) }
}

private func cookiePathMatches(cookiePath: String, requestPath: String): Bool {
    if (cookiePath == requestPath) { return true }
    if (!requestPath.startsWith(cookiePath)) { return false }
    if (cookiePath.endsWith("/")) { return true }
    let bytes = requestPath.toArray()
    cookiePath.size < bytes.size && bytes[cookiePath.size] == b'/'
}

private func cookieFirstEquals(value: String): Int64 {
    let bytes = value.toArray()
    for (index in 0..bytes.size) { if (bytes[index] == b'=') { return index } }
    -1
}

private func cookieStringRange(bytes: Array<Byte>, start: Int64, end: Int64): String {
    let result = Array<Byte>(end - start, repeat: 0u8)
    for (index in start..end) { result[index - start] = bytes[index] }
    String.fromUtf8(result)
}

private func parseCookieMaxAge(value: String): ?Int64 {
    if (value.isEmpty() || value.size > 20 || value.startsWith("+")) { return None<Int64> }
    let bytes = value.toArray()
    var start: Int64 = 0
    if (bytes[0] == b'-') {
        if (bytes.size == 1) { return None<Int64> }
        start = 1
    }
    for (index in start..bytes.size) {
        if (bytes[index] < b'0' || bytes[index] > b'9') { return None<Int64> }
    }
    try { Some(Int64.parse(value)) } catch (_: Exception) { None<Int64> }
}

private func parseCookieDate(value: String): ?DateTime {
    if (value.isEmpty() || value.size > 128) { return None<DateTime> }
    let tokens = cookieDateTokens(value)
    if (tokens.isNone()) { return None<DateTime> }
    var day: Int64 = -1
    var month: Int64 = -1
    var year: Int64 = -1
    var clock = None<ParsedCookieTime>
    for (token in tokens.getOrThrow()) {
        if (clock.isNone() && token.contains(":")) {
            clock = parseCookieClock(token)
            continue
        }
        let parsedMonth = cookieMonth(token)
        if (month < 0 && parsedMonth > 0) {
            month = parsedMonth
            continue
        }
        if (!cookieDigits(token)) { continue }
        if (token.size >= 3 && year < 0) {
            year = try { Int64.parse(token) } catch (_: Exception) { return None<DateTime> }
        } else if (token.size <= 2 && day < 0) {
            day = try { Int64.parse(token) } catch (_: Exception) { return None<DateTime> }
        } else if (token.size == 2 && year < 0) {
            year = try { Int64.parse(token) } catch (_: Exception) { return None<DateTime> }
        }
    }
    if (year >= 0 && year <= 69) { year += 2000 }
    else if (year >= 70 && year <= 99) { year += 1900 }
    if (day < 1 || day > 31 || month < 1 || year < 1601 || clock.isNone()) { return None<DateTime> }
    let time = clock.getOrThrow()
    try {
        Some(DateTime.ofUTC(
            year: year,
            month: month,
            dayOfMonth: day,
            hour: time.hour,
            minute: time.minute,
            second: time.second
        ))
    } catch (_: Exception) { None<DateTime> }
}

private func cookieDateTokens(value: String): ?Array<String> {
    let bytes = value.toArray()
    let tokens = ArrayList<String>()
    var start: Int64 = -1
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let tokenByte = (byte >= b'0' && byte <= b'9') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'a' && byte <= b'z') || byte == b':'
        if (tokenByte) {
            if (start < 0) { start = index }
        } else if (start >= 0) {
            tokens.add(cookieStringRange(bytes, start, index))
            if (tokens.size > 16) { return None<Array<String>> }
            start = -1
        }
    }
    if (start >= 0) { tokens.add(cookieStringRange(bytes, start, bytes.size)) }
    if (tokens.size > 16) { None<Array<String>> } else { Some(tokens.toArray()) }
}

private func parseCookieClock(value: String): ?ParsedCookieTime {
    let fields = value.split(":")
    if (fields.size != 3 || !cookieDigits(fields[0]) || !cookieDigits(fields[1]) ||
        !cookieDigits(fields[2]) || fields[0].size < 1 || fields[0].size > 2 ||
        fields[1].size != 2 || fields[2].size != 2) {
        return None<ParsedCookieTime>
    }
    let hour = try { Int64.parse(fields[0]) } catch (_: Exception) { return None<ParsedCookieTime> }
    let minute = try { Int64.parse(fields[1]) } catch (_: Exception) { return None<ParsedCookieTime> }
    let second = try { Int64.parse(fields[2]) } catch (_: Exception) { return None<ParsedCookieTime> }
    if (hour > 23 || minute > 59 || second > 59) { return None<ParsedCookieTime> }
    Some(ParsedCookieTime(hour, minute, second))
}

private func cookieDigits(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in value.toArray()) { if (byte < b'0' || byte > b'9') { return false } }
    true
}

private func cookieMonth(value: String): Int64 {
    let lower = value.toAsciiLower()
    if (lower.startsWith("jan")) { 1 }
    else if (lower.startsWith("feb")) { 2 }
    else if (lower.startsWith("mar")) { 3 }
    else if (lower.startsWith("apr")) { 4 }
    else if (lower.startsWith("may")) { 5 }
    else if (lower.startsWith("jun")) { 6 }
    else if (lower.startsWith("jul")) { 7 }
    else if (lower.startsWith("aug")) { 8 }
    else if (lower.startsWith("sep")) { 9 }
    else if (lower.startsWith("oct")) { 10 }
    else if (lower.startsWith("nov")) { 11 }
    else if (lower.startsWith("dec")) { 12 }
    else { -1 }
}

private func formatCookieDate(value: DateTime): String {
    let utc = value.inUTC()
    "${cookieWeekdayName(utc.dayOfWeek.toInteger())}, ${cookieTwoDigits(utc.dayOfMonth)} " +
        "${cookieMonthName(utc.month.toInteger())} ${cookieFourDigits(utc.year)} " +
        "${cookieTwoDigits(utc.hour)}:${cookieTwoDigits(utc.minute)}:${cookieTwoDigits(utc.second)} GMT"
}

private func cookieWeekdayName(value: Int64): String {
    match (value) {
        case 0 => "Sun"
        case 1 => "Mon"
        case 2 => "Tue"
        case 3 => "Wed"
        case 4 => "Thu"
        case 5 => "Fri"
        case _ => "Sat"
    }
}

private func cookieMonthName(value: Int64): String {
    match (value) {
        case 1 => "Jan"
        case 2 => "Feb"
        case 3 => "Mar"
        case 4 => "Apr"
        case 5 => "May"
        case 6 => "Jun"
        case 7 => "Jul"
        case 8 => "Aug"
        case 9 => "Sep"
        case 10 => "Oct"
        case 11 => "Nov"
        case _ => "Dec"
    }
}

private func cookieTwoDigits(value: Int64): String {
    if (value < 10) { "0${value}" } else { "${value}" }
}

private func cookieFourDigits(value: Int64): String {
    if (value < 10) { "000${value}" }
    else if (value < 100) { "00${value}" }
    else if (value < 1000) { "0${value}" }
    else { "${value}" }
}
