package wirestack.http

import wirestack as api

/** Absolute ws/wss URL validated without DNS or network I/O.
 * Reuses HttpUrl's 8192-byte ASCII authority/escape validator and the RFC 3986 target profile.
 * Userinfo, fragments, backslashes, malformed escapes and non-ASCII input are rejected.
 * Ordinary HTTP APIs continue to accept only HTTP(S) URLs.
 */
public class WebSocketUrl <: ToString {
    /** Canonical lowercase ws or wss scheme. */
    public let scheme: String
    /** Lowercase DNS/IPv4 host or unbracketed IPv6 literal; never percent-decoded. */
    public prop host: String { get() { httpUrl.host } }
    /** Explicit port or the scheme default: 80 for ws and 443 for wss. */
    public prop port: UInt16 { get() { httpUrl.port } }
    /** Whether the URL supplied a port, including an explicit default port. */
    public prop explicitPort: Bool { get() { httpUrl.explicitPort } }
    /** Canonical Host/:authority value, retaining an explicit port and IPv6 brackets. */
    public prop authority: String { get() { httpUrl.authority } }
    /** Origin-form path and optional query; absent path becomes / and escapes retain their bytes. */
    public prop requestTarget: String { get() { httpUrl.requestTarget } }

    internal let httpUrl: api.HttpUrl
    private let serialized: String

    private init(httpUrl: api.HttpUrl) {
        this.httpUrl = httpUrl
        scheme = if (httpUrl.scheme == "https") { "wss" } else { "ws" }
        serialized = "${scheme}://${httpUrl.authority}${httpUrl.requestTarget}"
    }

    /** Parses a bounded absolute WebSocket URL using the canonical authority/path validator.
     * Parsing performs no resolver, connector or TLS operation.
     * @param value Between 1 and 8192 ASCII bytes with a case-insensitive ws or wss scheme.
     */
    public static func parse(value: String): WebSocketUrl {
        WebSocketUrl(api.HttpUrl.parseWebSocket(value))
    }

    /** Returns the canonical ws/wss URL; this value can contain application-sensitive query data. */
    public func toString(): String { serialized }
}
