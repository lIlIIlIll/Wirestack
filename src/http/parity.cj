package wirestack.http

import std.collection.ArrayList
import wirestack as api

/** SameSite policy for the bounded in-memory cookie jar. */
public enum CookieSameSite {
/** Strict same-site requests only. */
    | Strict
/** Lax same-site requests. */
    | Lax
/** Cross-site requests are allowed when the caller opts in. */
    | None
}

/** Immutable HTTP cookie value. */
public struct Cookie {
/** Cookie name. */
    public let name: String
/** Cookie value. */
    public let value: String
/** Optional domain restriction. */
    public let domain: ?String
/** Request path restriction. */
    public let path: String
/** Sends the cookie only over HTTPS. */
    public let secure: Bool
/** Marks the cookie as HTTP-only metadata. */
    public let httpOnly: Bool
/** Same-site request policy. */
    public let sameSite: CookieSameSite

    /** Creates a bounded cookie without parsing a `Set-Cookie` header.
     *
     * @param domain Optional host suffix.
     * @param httpOnly Whether the cookie is HTTP-only.
     * @param name Cookie name.
     * @param path Path prefix for requests.
     * @param sameSite Same-site policy.
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
        if (name.isEmpty() || name.size > 256 || value.size > 4096 || path.isEmpty() ||
            path.size > 1024 || name.contains(";") || name.contains("=") ||
            value.contains("\r") || value.contains("\n")) {
            throw IllegalArgumentException("cookie value is outside the bounded syntax")
        }
        match (domain) {
            case Some(host) => if (host.isEmpty() || host.size > 253) { throw IllegalArgumentException("cookie domain is invalid") }
            case None => ()
        }
        this.name = name
        this.value = value
        this.domain = domain
        this.path = path
        this.secure = secure
        this.httpOnly = httpOnly
        this.sameSite = sameSite
    }
}

/** Optional persistence boundary for a cookie jar; implementations own storage. */
public interface CookieStore {
    /** Loads persisted cookies. */
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
        cookies = updated
        match (store) { case Some(value) => value.save(cookie); case None => () }
    }

    /**
     * Removes one cookie identity. A missing identity is a no-op.
     * @param name Cookie name to remove.
     * @param domain Optional domain associated with the cookie.
     * @param path Path scope associated with the cookie.
     */
    public func remove(name: String, domain!: ?String = None<String>, path!: String = "/"): Unit {
        if (closed) { throw IllegalStateException("cookie jar is closed") }
        let retained = ArrayList<Cookie>()
        for (entry in cookies) {
            if (entry.name == name && entry.domain == domain && entry.path == path) {
                match (store) {
                    case Some(value) => value.remove(name, domain, path)
                    case None => ()
                }
            } else {
                retained.add(entry)
            }
        }
        cookies = retained
    }

    /**
     * Parses one bounded Set-Cookie value against a request URL.
     * Invalid attributes are ignored; an invalid name/value returns false.
     * Max-Age=0 removes the matching identity.
     * @param value Set-Cookie header value received from the peer.
     * @param url Request URL used to apply domain and path defaults.
     */
    public func acceptSetCookie(value: String, url: HttpUrl): Bool {
        if (closed || value.isEmpty() || value.size > 8192) { return false }
        let fields = value.split(";")
        if (fields.isEmpty()) { return false }
        let pair = fields[0].trimAscii()
        let equals = pair.toArray()
        var separator: Int64 = -1
        for (index in 0..equals.size) {
            if (equals[index] == b'=') { separator = index; break }
        }
        if (separator <= 0 || separator + 1 > equals.size) { return false }
        let name = String.fromUtf8(sliceCookieBytes(equals, 0, separator)).trimAscii()
        let cookieValue = String.fromUtf8(sliceCookieBytes(equals, separator + 1, equals.size)).trimAscii()
        if (name.isEmpty() || name.size > 256 || cookieValue.size > 4096 ||
            name.contains(";") || name.contains("\r") || name.contains("\n") ||
            cookieValue.contains("\r") || cookieValue.contains("\n")) { return false }
        var domain = Some(url.host)
        var path = defaultCookiePath(url.requestTarget)
        var secure = false
        var httpOnly = false
        var sameSite = CookieSameSite.Lax
        var deleteCookie = false
        for (index in 1..fields.size) {
            let attribute = fields[index].trimAscii()
            if (attribute.isEmpty()) { continue }
            let lower = attribute.toAsciiLower()
            if (lower == "secure") { secure = true; continue }
            if (lower == "httponly") { httpOnly = true; continue }
            if (lower == "max-age=0" || lower == "expires=0") { deleteCookie = true; continue }
            if (lower.startsWith("domain=")) {
                var candidate = cookieAttributeValue(attribute, 7).trimAscii().toAsciiLower()
                if (candidate.startsWith(".")) { candidate = cookieAttributeValue(candidate, 1) }
                if (!candidate.isEmpty() && candidate.size <= 253) { domain = Some(candidate) }
                continue
            }
            if (lower.startsWith("path=")) {
                let candidate = cookieAttributeValue(attribute, 5).trimAscii()
                if (!candidate.isEmpty() && candidate.startsWith("/") && candidate.size <= 1024) { path = candidate }
                continue
            }
            if (lower.startsWith("samesite=")) {
                match (cookieAttributeValue(lower, 9)) {
                    case "strict" => sameSite = CookieSameSite.Strict
                    case "none" => sameSite = CookieSameSite.None
                    case _ => sameSite = CookieSameSite.Lax
                }
            }
        }
        let cookie = try {
            Cookie(name, cookieValue, domain: domain, path: path, secure: secure,
                httpOnly: httpOnly, sameSite: sameSite)
        } catch (_: Exception) { return false }
        if (deleteCookie) { remove(cookie.name, domain: cookie.domain, path: cookie.path) }
        else { put(cookie) }
        true
    }

    /** Returns a defensive snapshot of all stored cookies. */
    public func snapshot(): Array<Cookie> { cookies.toArray() }

    /** Builds a bounded Cookie request header for one URL.
     * @param url URL used for secure, domain and path matching.
     */
    public func headerFor(url: HttpUrl): String {
        if (closed) { throw IllegalStateException("cookie jar is closed") }
        let values = ArrayList<String>()
        let secureRequest = url.scheme == "https"
        for (cookie in cookies) {
            if (cookie.secure && !secureRequest) { continue }
            if (!cookiePathMatches(cookie.path, url.requestTarget)) { continue }
            match (cookie.domain) {
                case Some(domain) => if (!cookieDomainMatches(domain, url.host)) { continue }
                case None => ()
            }
            values.add("${cookie.name}=${cookie.value}")
        }
        joinCookieValues(values.toArray())
    }

    /** Closes the jar; repeated calls are harmless. */
    public func close(): Unit { closed = true }
    /** Reports whether this jar has been closed. */
    public func isClosed(): Bool { closed }
}

/** One multipart form-data part with bounded metadata and payload. */
public struct MultipartPart {
/** Form field name. */
    public let name: String
/** Optional uploaded filename. */
    public let filename: ?String
/** MIME content type. */
    public let contentType: String
    private let payload: Array<Byte>

    /** Creates an owned multipart part.
     *
     * @param contentType MIME content type.
     * @param filename Optional uploaded filename.
     * @param name Form field name.
     * @param payload Part bytes.
     */
    public init(name: String, payload: Array<Byte>, filename!: ?String = None<String>,
        contentType!: String = "application/octet-stream") {
        if (name.isEmpty() || name.size > 256 || payload.size > 64 * 1024 * 1024 ||
            contentType.isEmpty() || contentType.size > 256 || !multipartMetadataSafe(name) ||
            !multipartMetadataSafe(contentType)) {
            throw IllegalArgumentException("multipart part is outside the bounded range")
        }
        match (filename) {
            case Some(value) => if (value.isEmpty() || value.size > 1024 || !multipartMetadataSafe(value)) {
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
}

/** Bounded multipart/form-data encoder; parsing is performed by the HTTP body layer. */
public class MultipartWriter {
/** Multipart boundary token. */
    public let boundary: String
    private let parts = ArrayList<MultipartPart>()
    private let maximumParts: Int64

    /** Creates a writer with a bounded part count.
     *
     * @param boundary Multipart boundary token.
     * @param maximumParts Maximum number of parts.
     */
    public init(boundary: String, maximumParts!: Int64 = 128) {
        if (boundary.isEmpty() || boundary.size > 70 || maximumParts <= 0 || maximumParts > 4096) {
            throw IllegalArgumentException("multipart boundary or part bound is invalid")
        }
        for (value in boundary.toArray()) {
            if (value <= 32u8 || value >= 127u8 || value == b'"' || value == b'\\') {
                throw IllegalArgumentException("multipart boundary contains an unsafe byte")
            }
        }
        this.boundary = boundary
        this.maximumParts = maximumParts
    }

    /** Adds one part while retaining an owned copy.
     * @param part Multipart part to add.
     */
    public func add(part: MultipartPart): Unit {
        if (parts.size >= maximumParts) { throw IllegalStateException("multipart part limit exceeded") }
        parts.add(part)
    }

    /** Returns the current part snapshot. */
    public func snapshot(): Array<MultipartPart> { parts.toArray() }

    /** Returns the media type used by the encoded body. */
    public func contentType(): String { "multipart/form-data; boundary=${boundary}" }

    /**
     * Encodes the bounded parts as a replayable request body.
     * @param maximumBytes Upper bound for the encoded body.
     */
    public func body(maximumBytes!: Int64 = 128 * 1024 * 1024): RequestBody {
        if (maximumBytes <= 0) { throw IllegalArgumentException("multipart body bound must be positive") }
        let output = ArrayList<Byte>()
        for (part in parts) {
            appendMultipartAscii(output, "--${boundary}\r\n")
            var disposition = "Content-Disposition: form-data; name=\"${part.name}\""
            match (part.filename) {
                case Some(value) => disposition += "; filename=\"${value}\""
                case None => ()
            }
            appendMultipartAscii(output, "${disposition}\r\n")
            appendMultipartAscii(output, "Content-Type: ${part.contentType}\r\n\r\n")
            for (value in part.bytes()) { output.add(value) }
            appendMultipartAscii(output, "\r\n")
            if (output.size > maximumBytes) { throw IllegalStateException("multipart body limit exceeded") }
        }
        appendMultipartAscii(output, "--${boundary}--\r\n")
        if (output.size > maximumBytes) { throw IllegalStateException("multipart body limit exceeded") }
        RequestBody.bytes(output.toArray())
    }
}

/** File serving boundary; implementations must enforce a root and size limit. */
public interface FileHandler {
    /** Opens one bounded file response.
     *
     * @param context Shared request operation context.
     * @param path Relative file path.
     */
    func open(path: String, context: api.OperationContext): ResponseBody
}

/** Result of a typed HTTP Upgrade negotiation. */
public struct HttpUpgradeResult {
/** Whether negotiation succeeded. */
    public let accepted: Bool
/** Negotiated protocol name when accepted. */
    public let protocolName: ?String
/** Additional response headers. */
    public let headers: HttpHeaders

    /** Creates an immutable negotiation result.
     *
     * @param accepted Whether negotiation succeeded.
     * @param headers Additional response headers.
     * @param protocolName Negotiated protocol name.
     */
    public init(accepted: Bool, protocolName!: ?String = None<String>,
        headers!: HttpHeaders = HttpHeaders()) {
        this.accepted = accepted
        this.protocolName = protocolName
        this.headers = headers
    }
}

/** Protocol names accepted by the upgrade facade. */
public enum HttpUpgradeProtocol {
/** WebSocket upgrade. */
    | WebSocket
/** HTTP/2 cleartext upgrade. */
    | H2c
/** Caller-defined upgrade token. */
    | Custom(String)
}

/** Validates Upgrade headers without exposing an implementation socket. */
public class HttpUpgrade {
    /** Validates one request for a selected protocol.
     *
     * @param headers Request headers.
     * @param protocol Protocol to negotiate.
     */
    public static func negotiate(headers: HttpHeaders, protocol: HttpUpgradeProtocol): HttpUpgradeResult {
        let connection = headers.getFirst("connection")
        let upgrade = headers.getFirst("upgrade")
        if (connection.isNone() || upgrade.isNone()) { return HttpUpgradeResult(false) }
        let requested = match (protocol) {
            case HttpUpgradeProtocol.WebSocket => "websocket"
            case HttpUpgradeProtocol.H2c => "h2c"
            case HttpUpgradeProtocol.Custom(value) => value
        }
        let upgradeValue = match (upgrade) { case Some(value) => value.toAsciiLower(); case None => "" }
        if (!headerTokenContains(match (connection) { case Some(value) => value; case None => "" }, "upgrade") ||
            upgradeValue != requested.toAsciiLower()) {
            return HttpUpgradeResult(false)
        }
        HttpUpgradeResult(true, protocolName: Some(requested))
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

/** Immutable bounded WebSocket frame. */
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

    /**
     * Encodes one RFC 6455 frame without per-message compression.
     * @param maskingKey Optional four-byte key for a masked frame.
     */
    public func encode(maskingKey!: ?Array<Byte> = None<Array<Byte>>): Array<Byte> {
        let mask = match (maskingKey) {
            case Some(value) => if (value.size != 4) { throw IllegalArgumentException("WebSocket masking key must contain four bytes") }; true
            case None => false
        }
        let output = ArrayList<Byte>()
        output.add(if (fin) { 0x80u8 } else { 0u8 } | webSocketOpcodeCode(opcode))
        let length = payload.size
        let maskBit = if (mask) { 0x80u8 } else { 0u8 }
        if (length <= 125) {
            output.add(maskBit | UInt8(length))
        } else if (length <= 65535) {
            output.add(maskBit | 126u8)
            output.add(UInt8(UInt64((length >> 8) & 0xff)))
            output.add(UInt8(UInt64(length & 0xff)))
        } else {
            output.add(maskBit | 127u8)
            for (shift in [56, 48, 40, 32, 24, 16, 8, 0]) {
                output.add(UInt8(UInt64((length >> shift) & 0xff)))
            }
        }
        match (maskingKey) {
            case Some(key) =>
                for (value in key) { output.add(value) }
                for (index in 0..payload.size) { output.add(payload[index] ^ key[index % 4]) }
            case None => for (value in payload) { output.add(value) }
        }
        output.toArray()
    }

    /**
     * Decodes exactly one bounded RFC 6455 frame.
     * @param encoded Serialized frame bytes to decode.
     */
    public static func decode(encoded: Array<Byte>): WebSocketFrame {
        if (encoded.size < 2) { throw IllegalArgumentException("WebSocket frame is truncated") }
        let fin = (encoded[0] & 0x80u8) != 0u8
        if ((encoded[0] & 0x70u8) != 0u8) { throw IllegalArgumentException("WebSocket RSV bits are not supported") }
        let opcode = webSocketOpcodeFromCode(encoded[0] & 0x0fu8)
        let masked = (encoded[1] & 0x80u8) != 0u8
        let marker = Int64(encoded[1] & 0x7fu8)
        var cursor: Int64 = 2
        var length: Int64 = marker
        if (marker == 126) {
            if (encoded.size < cursor + 2) { throw IllegalArgumentException("WebSocket frame length is truncated") }
            length = (Int64(encoded[cursor]) << 8) | Int64(encoded[cursor + 1])
            cursor += 2
        } else if (marker == 127) {
            if (encoded.size < cursor + 8 || (encoded[cursor] & 0x80u8) != 0u8) {
                throw IllegalArgumentException("WebSocket frame length is invalid")
            }
            length = 0
            for (_ in 0..8) { length = (length << 8) | Int64(encoded[cursor]); cursor += 1 }
        }
        if (length < 0 || length > 16 * 1024 * 1024) { throw IllegalArgumentException("WebSocket payload exceeds the bound") }
        var mask = Array<Byte>()
        if (masked) {
            if (encoded.size < cursor + 4) { throw IllegalArgumentException("WebSocket masking key is truncated") }
            mask = Array<Byte>(4, repeat: 0u8)
            for (index in 0..4) { mask[index] = encoded[cursor + index] }
            cursor += 4
        }
        if (encoded.size != cursor + length) { throw IllegalArgumentException("WebSocket frame has trailing or missing bytes") }
        let payload = Array<Byte>(length, repeat: 0u8)
        for (index in 0..length) {
            let value = encoded[cursor + index]
            payload[index] = if (masked) { value ^ mask[index % 4] } else { value }
        }
        WebSocketFrame(fin, opcode, payload)
    }
}

/** Provider-neutral synchronous WebSocket connection boundary. */
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

/** Public connector hook; DNS and socket ownership stay in the implementation. */
public interface HttpConnector {
    /** Connects to one resolved endpoint.
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

/** Default explicit HTTP/2 policy. The current core rejects server push. */
public class DenyHttp2PushPolicy <: Http2PushPolicy {
    /** Creates a policy that rejects every server-push promise. */
    public init() {}

    /**
     * Rejects one promised resource under the current operation context.
     * @param parent Request that would own the promised stream.
     * @param promised Resource advertised by the peer.
     * @param context Deadline and cancellation scope for the decision.
     */
    public func allow(parent: HttpUrl, promised: HttpUrl, context: api.OperationContext): Bool {
        let _ = parent
        let _ = promised
        let _ = context
        false
    }
}

private func sliceCookieBytes(value: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    for (index in start..end) { output.add(value[index]) }
    output.toArray()
}

private func defaultCookiePath(target: String): String {
    let bytes = target.toArray()
    var lastSlash: Int64 = 0
    for (index in 0..bytes.size) {
        if (bytes[index] == b'/') { lastSlash = index }
        if (bytes[index] == b'?') { break }
    }
    if (lastSlash <= 0) { "/" } else { String.fromUtf8(sliceCookieBytes(bytes, 0, lastSlash + 1)) }
}

private func cookieAttributeValue(value: String, start: Int64): String {
    let bytes = value.toArray()
    if (start >= bytes.size) { return "" }
    String.fromUtf8(sliceCookieBytes(bytes, start, bytes.size))
}

private func appendMultipartAscii(output: ArrayList<Byte>, value: String): Unit {
    for (byte in value.toArray()) { output.add(byte) }
}

private func multipartMetadataSafe(value: String): Bool {
    for (byte in value.toArray()) {
        if (byte == b'\r' || byte == b'\n' || byte == b'"' || byte == b'\\' || byte < 0x20u8) {
            return false
        }
    }
    true
}

private func webSocketOpcodeCode(opcode: WebSocketOpcode): Byte {
    match (opcode) {
        case WebSocketOpcode.Continuation => 0x0u8
        case WebSocketOpcode.Text => 0x1u8
        case WebSocketOpcode.Binary => 0x2u8
        case WebSocketOpcode.Close => 0x8u8
        case WebSocketOpcode.Ping => 0x9u8
        case WebSocketOpcode.Pong => 0xAu8
    }
}

private func webSocketOpcodeFromCode(value: Byte): WebSocketOpcode {
    match (value) {
        case 0x0u8 => WebSocketOpcode.Continuation
        case 0x1u8 => WebSocketOpcode.Text
        case 0x2u8 => WebSocketOpcode.Binary
        case 0x8u8 => WebSocketOpcode.Close
        case 0x9u8 => WebSocketOpcode.Ping
        case 0xAu8 => WebSocketOpcode.Pong
        case _ => throw IllegalArgumentException("WebSocket opcode is unsupported")
    }
}

private func cookieDomainMatches(domain: String, host: String): Bool {
    if (domain == host) { return true }
    host.endsWith(".${domain}")
}

private func cookiePathMatches(path: String, requestTarget: String): Bool {
    if (path == "/") { return true }
    requestTarget.startsWith(path)
}

private func joinCookieValues(values: Array<String>): String {
    var result = ""
    for (index in 0..values.size) {
        if (index > 0) { result += "; " }
        result += values[index]
    }
    result
}

private func headerTokenContains(value: String, token: String): Bool {
    for (part in value.toAsciiLower().split(",")) {
        if (part.trimAscii() == token) { return true }
    }
    false
}
