package wirestack.http

import std.collection.ArrayList
import wirestack as api

/** SameSite metadata retained for later request-site policy integration. */
public enum CookieSameSite {
/** Strict same-site metadata. */
    | Strict
/** Lax same-site metadata. */
    | Lax
/** Cross-site metadata; construction also requires `secure`. */
    | None
}

/**
 * Immutable cookie metadata. This type does not parse `Set-Cookie`.
 *
 * A cookie without `domain` has no request-host association. `CookieJar`
 * retains such a value but never emits it in a request header. Callers that
 * construct cookies directly must provide an explicit domain.
 */
public struct Cookie {
/** Cookie name, restricted to HTTP token bytes. */
    public let name: String
/** Cookie value, restricted to RFC cookie-octet bytes. */
    public let value: String
/** Optional canonical lowercase host suffix. */
    public let domain: ?String
/** Request path restriction. */
    public let path: String
/** Sends the cookie only over HTTPS. */
    public let secure: Bool
/** HTTP-only metadata; this value alone does not enforce script access. */
    public let httpOnly: Bool
/** Same-site metadata; request-site policy belongs to the later HTTP integration. */
    public let sameSite: CookieSameSite

    /** Creates bounded, injection-safe cookie metadata.
     *
     * @param domain Optional host suffix. `None` is retained but never emitted.
     * @param httpOnly Whether the cookie carries HTTP-only metadata.
     * @param name Cookie name.
     * @param path Absolute request-path prefix.
     * @param sameSite Same-site metadata.
     * @param secure Whether HTTPS is required.
     * @param value Cookie value.
     */
    public init(
        name: String,
        value: String,
        domain!: ?String = None<String>,
        path!: String = "/",
        secure!: Bool = false,
        httpOnly!: Bool = false,
        sameSite!: CookieSameSite = CookieSameSite.Lax
    ) {
        if (name.size > 256 || value.size > 4096 || !cookieNameSafe(name) ||
            !cookieValueSafe(value) || !cookiePathSafe(path)) {
            throw IllegalArgumentException("cookie value is outside the bounded syntax")
        }
        let checkedDomain = match (domain) {
            case Some(host) =>
                let canonical = host.toAsciiLower()
                if (!cookieDomainSafe(canonical)) {
                    throw IllegalArgumentException("cookie domain is invalid")
                }
                Some(canonical)
            case None => None<String>
        }
        match (sameSite) {
            case CookieSameSite.None =>
                if (!secure) {
                    throw IllegalArgumentException("SameSite=None cookie must be secure")
                }
            case _ => ()
        }
        this.name = name
        this.value = value
        this.domain = checkedDomain
        this.path = path
        this.secure = secure
        this.httpOnly = httpOnly
        this.sameSite = sameSite
    }
}

/**
 * Optional cookie persistence adapter. Implementations own and bound their
 * storage; the jar retains only the configured prefix returned by `load`.
 */
public interface CookieStore {
    /** Loads a caller-owned snapshot of persisted cookies. */
    func load(): Array<Cookie>
    /** Persists one cookie replacement.
     * @param cookie Cookie to persist.
     */
    func save(cookie: Cookie): Unit
    /** Removes one persisted cookie key.
     *
     * @param domain Optional cookie domain.
     * @param name Cookie name.
     * @param path Cookie path.
     */
    func remove(name: String, domain: ?String, path: String): Unit
}

/** Bounded, in-memory cookie jar with an explicit optional persistence hook. */
public class CookieJar <: Resource {
    private let maximumCookies: Int64
    private let store: ?CookieStore
    private var cookies = ArrayList<Cookie>()
    private var closed = false

    /** Creates a jar and loads at most `maximumCookies` persisted entries.
     *
     * @param maximumCookies Maximum number of entries.
     * @param store Optional persistence implementation.
     */
    public init(maximumCookies!: Int64 = 256, store!: ?CookieStore = None<CookieStore>) {
        if (maximumCookies <= 0 || maximumCookies > 4096) { throw IllegalArgumentException("cookie jar bound is invalid") }
        this.maximumCookies = maximumCookies
        this.store = store
        match (store) {
            case Some(value) =>
                for (cookie in value.load()) {
                    if (cookies.size >= maximumCookies) { break }
                    cookies.add(cookie)
                }
            case None => ()
        }
    }

    /** Stores or replaces one cookie and never exceeds the configured bound.
     * A persistence failure leaves the in-memory snapshot unchanged.
     * @param cookie Cookie to store.
     */
    public func put(cookie: Cookie): Unit {
        if (closed) { throw IllegalStateException("cookie jar is closed") }
        var replaced = false
        let updated = ArrayList<Cookie>()
        for (entry in cookies) {
            if (entry.name == cookie.name && entry.domain == cookie.domain && entry.path == cookie.path) {
                updated.add(cookie)
                replaced = true
            } else {
                updated.add(entry)
            }
        }
        if (!replaced) {
            if (updated.size >= maximumCookies) { updated.remove(at: 0) }
            updated.add(cookie)
        }
        match (store) { case Some(value) => value.save(cookie); case None => () }
        cookies = updated
    }

    /** Returns a defensive snapshot. Closed jars reject access. */
    public func snapshot(): Array<Cookie> {
        if (closed) { throw IllegalStateException("cookie jar is closed") }
        cookies.toArray()
    }

    /**
     * Builds a bounded Cookie request-header value for one URL.
     *
     * Cookies without a domain are omitted because this initial contract has
     * no origin with which to associate a host-only cookie. This method has no
     * initiating-site or navigation input, so it does not evaluate SameSite
     * metadata. The later HTTP integration must supply that policy.
     * Longer matching paths precede shorter paths; equal paths retain order.
     *
     * @param url URL used for secure, domain and path matching.
     */
    public func headerFor(url: HttpUrl): String {
        if (closed) { throw IllegalStateException("cookie jar is closed") }
        let matched = ArrayList<Cookie>()
        let secureRequest = url.scheme == "https"
        for (cookie in cookies) {
            if (cookie.secure && !secureRequest) { continue }
            if (!cookiePathMatches(cookie.path, url.requestTarget)) { continue }
            let scopedToHost = match (cookie.domain) {
                case Some(domain) => cookieDomainMatches(domain, url.host)
                case None => false
            }
            if (!scopedToHost) { continue }
            var position = matched.size
            matched.add(cookie)
            while (position > 0 && matched[position - 1].path.size < cookie.path.size) {
                matched[position] = matched[position - 1]
                position--
            }
            matched[position] = cookie
        }
        var result = ""
        for (cookie in matched) {
            if (!result.isEmpty()) { result += "; " }
            result += "${cookie.name}=${cookie.value}"
        }
        result
    }

    /** Closes the jar, releases retained entries and rejects later access. */
    public func close(): Unit {
        if (!closed) {
            closed = true
            cookies = ArrayList<Cookie>()
        }
    }
    /** Reports whether this jar has been closed. */
    public func isClosed(): Bool { closed }
}

/**
 * Owned multipart part metadata and payload.
 *
 * This value does not serialize a multipart body. A later protocol adapter
 * may encode the validated ASCII metadata and owned payload.
 */
public struct MultipartPart {
/** Form field name for a quoted Content-Disposition parameter. */
    public let name: String
/** Optional filename for a quoted Content-Disposition parameter. */
    public let filename: ?String
/** Bare `type/subtype` media type. */
    public let contentType: String
    private let payload: Array<Byte>

    /** Creates one bounded metadata and payload value.
     *
     * @param contentType Bare ASCII `type/subtype` media type.
     * @param filename Optional ASCII filename.
     * @param name ASCII form field name.
     * @param payload Part bytes.
     */
    public init(name: String, payload: Array<Byte>, filename!: ?String = None<String>,
        contentType!: String = "application/octet-stream") {
        if (name.isEmpty() || name.size > 256 || payload.size > 64 * 1024 * 1024 ||
            !multipartQuotedMetadataSafe(name) || !multipartContentTypeSafe(contentType)) {
            throw IllegalArgumentException("multipart part is outside the bounded range")
        }
        match (filename) {
            case Some(value) => if (value.isEmpty() || value.size > 1024 ||
                !multipartQuotedMetadataSafe(value)) {
                throw IllegalArgumentException("multipart filename is outside the bounded range")
            }
            case None => ()
        }
        this.name = name
        this.filename = filename
        this.contentType = contentType
        this.payload = payload.clone()
    }

    /** Returns an owned payload copy. */
    public func bytes(): Array<Byte> { payload.clone() }
    internal prop payloadSize: Int64 { get() { payload.size } }
}

/**
 * Bounded collection of multipart metadata and owned payloads.
 *
 * It does not encode bytes or create a request body. `contentType` only
 * returns the media-type metadata that a later serializer may use.
 */
public class MultipartWriter {
/** Multipart boundary token. */
    public let boundary: String
    private let parts = ArrayList<MultipartPart>()
    private let maximumParts: Int64
    private let maximumPayloadBytes: Int64
    private var retainedPayloadBytes: Int64 = 0

    /** Creates a collection with count and retained-payload bounds.
     *
     * @param boundary MIME boundary restricted to unquoted parameter-safe bytes.
     * @param maximumParts Maximum number of retained parts.
     * @param maximumPayloadBytes Maximum total retained payload bytes.
     */
    public init(
        boundary: String,
        maximumParts!: Int64 = 128,
        maximumPayloadBytes!: Int64 = 128 * 1024 * 1024
    ) {
        if (boundary.isEmpty() || boundary.size > 70 || !multipartBoundarySafe(boundary) ||
            maximumParts <= 0 || maximumParts > 4096 || maximumPayloadBytes < 0 ||
            maximumPayloadBytes > 1024 * 1024 * 1024) {
            throw IllegalArgumentException("multipart boundary or collection bound is invalid")
        }
        this.boundary = boundary
        this.maximumParts = maximumParts
        this.maximumPayloadBytes = maximumPayloadBytes
    }

    /** Adds one part without exceeding either configured bound.
     * @param part Multipart part to retain.
     */
    public func add(part: MultipartPart): Unit {
        if (parts.size >= maximumParts) {
            throw IllegalStateException("multipart part limit exceeded")
        }
        if (part.payloadSize > maximumPayloadBytes - retainedPayloadBytes) {
            throw IllegalStateException("multipart payload limit exceeded")
        }
        parts.add(part)
        retainedPayloadBytes += part.payloadSize
    }

    /** Returns a snapshot of the immutable part values. */
    public func snapshot(): Array<MultipartPart> { parts.toArray() }

    /** Returns media-type metadata; it does not imply that a body was encoded. */
    public func contentType(): String { "multipart/form-data; boundary=${boundary}" }
}

/**
 * Adapter interface for opening a response body from a relative path.
 *
 * Wirestack does not provide path normalization, root enforcement or file
 * size enforcement through this interface. Implementations must provide those
 * checks. Ownership of the returned body transfers to the caller.
 */
public interface FileHandler {
    /** Opens one caller-owned response body.
     *
     * @param context Shared request operation context.
     * @param path Untrusted relative path to validate against the adapter root.
     */
    func open(path: String, context: api.OperationContext): ResponseBody
}

/**
 * Result of matching the two HTTP Upgrade header tokens.
 *
 * A match does not validate WebSocket handshakes, HTTP2-Settings, a 101
 * response, transport handoff or any upgraded protocol bytes.
 */
public struct HttpUpgradeHeaderMatch {
/** Whether the required Connection and Upgrade tokens were present. */
    public let matched: Bool
/** Selected protocol token when matched. */
    public let protocolName: ?String

    internal init(matched: Bool, protocolName!: ?String = None<String>) {
        this.matched = matched
        this.protocolName = protocolName
    }
}

/** Protocol token selected for an Upgrade header match. */
public enum HttpUpgradeProtocol {
/** WebSocket upgrade token. */
    | WebSocket
/** HTTP/2 cleartext upgrade token. */
    | H2c
/** Caller-defined upgrade token, validated when matched. */
    | Custom(String)
}

/** Matches Upgrade header tokens without negotiating or switching protocols. */
public class HttpUpgrade {
    /**
     * Matches one selected token in Connection and Upgrade header values.
     *
     * This function performs no protocol-specific handshake validation.
     *
     * @param headers Request headers.
     * @param protocol Protocol token to match.
     */
    public static func matchRequestHeaders(
        headers: HttpHeaders,
        protocol: HttpUpgradeProtocol
    ): HttpUpgradeHeaderMatch {
        let requested = match (protocol) {
            case HttpUpgradeProtocol.WebSocket => "websocket"
            case HttpUpgradeProtocol.H2c => "h2c"
            case HttpUpgradeProtocol.Custom(value) => value
        }
        if (!httpTokenSafe(requested)) { return HttpUpgradeHeaderMatch(false) }

        var connectionMatches = false
        for (value in headers.getAll("connection")) {
            if (headerTokenContains(value, "upgrade")) {
                connectionMatches = true
                break
            }
        }
        if (!connectionMatches) { return HttpUpgradeHeaderMatch(false) }

        for (value in headers.getAll("upgrade")) {
            if (headerTokenContains(value, requested)) {
                return HttpUpgradeHeaderMatch(true, protocolName: Some(requested))
            }
        }
        HttpUpgradeHeaderMatch(false)
    }
}

/** WebSocket frame opcodes supported without per-message compression. */
public enum WebSocketOpcode {
/** Continuation frame. */
    | Continuation
/** UTF-8 text frame. */
    | Text
/** Binary frame. */
    | Binary
/** Close control frame. */
    | Close
/** Ping control frame. */
    | Ping
/** Pong control frame. */
    | Pong
}

/**
 * Immutable bounded WebSocket frame metadata and owned payload.
 *
 * This value does not encode, decode or mask wire frames. It also does not
 * validate UTF-8 text, close payloads or fragmentation sequences.
 */
public struct WebSocketFrame {
/** Final-fragment marker. */
    public let fin: Bool
/** Frame opcode. */
    public let opcode: WebSocketOpcode
    private let payload: Array<Byte>

    /** Creates a frame with a bounded payload.
     *
     * @param fin Whether this is the final fragment.
     * @param opcode Frame opcode.
     * @param payload Frame bytes.
     */
    public init(fin: Bool, opcode: WebSocketOpcode, payload: Array<Byte>) {
        if (payload.size > 16 * 1024 * 1024) { throw IllegalArgumentException("WebSocket payload exceeds the bound") }
        match (opcode) {
            case WebSocketOpcode.Close | WebSocketOpcode.Ping | WebSocketOpcode.Pong =>
                if (!fin || payload.size > 125) { throw IllegalArgumentException("WebSocket control frame is invalid") }
            case _ => ()
        }
        this.fin = fin
        this.opcode = opcode
        this.payload = payload.clone()
    }

    /** Returns an owned payload copy. */
    public func bytes(): Array<Byte> { payload.clone() }

}

/**
 * Adapter interface for a synchronous WebSocket connection.
 *
 * Implementations own RFC 6455 wire framing, endpoint-specific masking and
 * fragmentation state. The inherited parameterless `close` releases the
 * resource; the overload below requests a protocol close handshake.
 */
public interface WebSocketConnection <: Resource {
    /** Sends one frame under the shared operation context.
     *
     * @param context Shared operation context.
     * @param frame Frame to send.
     */
    func send(frame: WebSocketFrame, context: api.OperationContext): Unit
    /** Receives one frame under the shared operation context.
     * @param context Shared operation context.
     */
    func receive(context: api.OperationContext): WebSocketFrame
    /** Closes the connection with a WebSocket close code.
     *
     * @param code WebSocket close code.
     * @param context Shared operation context.
     * @param reason Human-readable close reason.
     */
    func close(code: UInt16, reason: String, context: api.OperationContext): Unit
}

/** Bounded HTTP/2 push decision hook. */
public interface Http2PushPolicy {
    /** Decides whether a promised resource may be pushed.
     *
     * @param context Shared operation context.
     * @param parent Parent request URL.
     * @param promised Promised resource URL.
     */
    func allow(parent: HttpUrl, promised: HttpUrl, context: api.OperationContext): Bool
}

/**
 * Connector adapter interface. DNS and socket creation remain outside this
 * initial HTTP contract.
 */
public interface HttpConnector {
    /** Connects to one already-resolved endpoint and transfers transport ownership.
     *
     * @param context Shared operation context.
     * @param endpoint Resolved network endpoint.
     */
    func connect(endpoint: api.SocketEndpoint, context: api.OperationContext): api.DuplexTransport
}

/** Public connection-pool lifecycle hook with no native handle exposure. */
public interface HttpConnectionPoolHook {
    /** Reports a connection acquisition.
     *
     * @param context Shared operation context.
     * @param key Pool key.
     */
    func acquired(key: String, context: api.OperationContext): Unit
    /** Reports a connection release.
     *
     * @param context Shared operation context.
     * @param key Pool key.
     * @param reusable Whether the connection remains reusable.
     */
    func released(key: String, reusable: Bool, context: api.OperationContext): Unit
}

/** Public service lifecycle hook for instrumentation and policy. */
public interface HttpServiceHook {
    /** Runs before request dispatch.
     *
     * @param context Shared operation context.
     * @param request Incoming request.
     */
    func before(request: HttpServerRequest, context: api.OperationContext): Unit
    /** Runs after response dispatch.
     *
     * @param context Shared operation context.
     * @param response Outgoing response.
     */
    func after(response: HttpServerResponse, context: api.OperationContext): Unit
}

/** Default policy that rejects every HTTP/2 server-push promise. */
public class DenyHttp2PushPolicy <: Http2PushPolicy {
    /** Creates a stateless deny policy. */
    public init() {}
    /** Rejects the promise without retaining its values.
     * @param context Operation context supplied by the caller.
     * @param parent Request that would own the promised stream.
     * @param promised Resource advertised by the peer.
     */
    public func allow(parent: HttpUrl, promised: HttpUrl, context: api.OperationContext): Bool {
        let _ = parent
        let _ = promised
        let _ = context
        false
    }
}

private func httpTokenSafe(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty()) { return false }
    for (byte in bytes) {
        if (!httpTokenByte(byte)) { return false }
    }
    true
}

private func httpTokenByte(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'A' && value <= b'Z') ||
        (value >= b'a' && value <= b'z') || value == b'!' || value == b'#' ||
        value == b'$' || value == b'%' || value == b'&' || value == b'\'' ||
        value == b'*' || value == b'+' || value == b'-' || value == b'.' ||
        value == b'^' || value == b'_' || value == b'`' || value == b'|' ||
        value == b'~'
}

private func cookieNameSafe(value: String): Bool { httpTokenSafe(value) }

private func cookieValueSafe(value: String): Bool {
    for (byte in value.toArray()) {
        let allowed = byte == 0x21u8 || (byte >= 0x23u8 && byte <= 0x2bu8) ||
            (byte >= 0x2du8 && byte <= 0x3au8) ||
            (byte >= 0x3cu8 && byte <= 0x5bu8) ||
            (byte >= 0x5du8 && byte <= 0x7eu8)
        if (!allowed) { return false }
    }
    true
}

private func cookieDomainSafe(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 253 || bytes[0] == b'.' ||
        bytes[bytes.size - 1] == b'.') {
        return false
    }
    var labelBytes: Int64 = 0
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (byte == b'.') {
            if (labelBytes == 0 || bytes[index - 1] == b'-') { return false }
            labelBytes = 0
        } else {
            let alphaNumeric = (byte >= b'0' && byte <= b'9') ||
                (byte >= b'a' && byte <= b'z')
            if (!alphaNumeric && byte != b'-') { return false }
            if ((labelBytes == 0 && byte == b'-') || labelBytes >= 63) {
                return false
            }
            labelBytes++
        }
    }
    labelBytes > 0 && bytes[bytes.size - 1] != b'-'
}

private func cookiePathSafe(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 1024 || bytes[0] != b'/') { return false }
    for (byte in bytes) {
        if (byte < 0x20u8 || byte >= 0x7fu8 || byte == b'?') {
            return false
        }
    }
    true
}

private func multipartBoundarySafe(value: String): Bool {
    for (byte in value.toArray()) {
        let allowed = (byte >= b'0' && byte <= b'9') ||
            (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            byte == b'\'' || byte == b'+' || byte == b'_' ||
            byte == b'-' || byte == b'.'
        if (!allowed) { return false }
    }
    true
}

private func multipartQuotedMetadataSafe(value: String): Bool {
    for (byte in value.toArray()) {
        if (byte < 0x20u8 || byte >= 0x7fu8 || byte == b'"' || byte == b'\\') {
            return false
        }
    }
    true
}

private func multipartContentTypeSafe(value: String): Bool {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 256) { return false }
    var slash: Int64 = -1
    for (index in 0..bytes.size) {
        if (bytes[index] == b'/') {
            if (slash >= 0) { return false }
            slash = index
        } else if (!httpTokenByte(bytes[index])) {
            return false
        }
    }
    slash > 0 && slash + 1 < bytes.size
}

private func cookieDomainMatches(domain: String, host: String): Bool {
    let canonicalHost = host.toAsciiLower()
    if (domain == canonicalHost) { return true }
    if (cookieDomainIsIpv4(domain)) { return false }
    canonicalHost.endsWith(".${domain}")
}

private func cookieDomainIsIpv4(value: String): Bool {
    for (byte in value.toArray()) {
        if ((byte < b'0' || byte > b'9') && byte != b'.') { return false }
    }
    true
}

private func cookiePathMatches(path: String, requestTarget: String): Bool {
    let pathBytes = path.toArray()
    let targetBytes = requestTarget.toArray()
    var targetPathEnd = targetBytes.size
    for (index in 0..targetBytes.size) {
        if (targetBytes[index] == b'?') {
            targetPathEnd = index
            break
        }
    }
    if (pathBytes.size > targetPathEnd) { return false }
    for (index in 0..pathBytes.size) {
        if (pathBytes[index] != targetBytes[index]) { return false }
    }
    if (pathBytes.size == targetPathEnd || pathBytes[pathBytes.size - 1] == b'/') {
        return true
    }
    targetBytes[pathBytes.size] == b'/'
}


private func headerTokenContains(value: String, token: String): Bool {
    let expected = token.toAsciiLower()
    for (part in value.toAsciiLower().split(",")) {
        if (part.trimAscii() == expected) { return true }
    }
    false
}
