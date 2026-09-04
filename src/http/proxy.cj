package wirestack.http

import std.collection.ArrayList

/** Provider-neutral proxy endpoint. A typed IP never enters DNS. */
public class HttpProxyEndpoint {
/**
 * Wirestack 公开 API：hostName。
 */
    public let hostName: ?HostName
/**
 * Wirestack 公开 API：ipAddress。
 */
    public let ipAddress: ?IpAddress
/**
 * Wirestack 公开 API：port。
 */
    public let port: UInt16
/**
 * Wirestack 公开 API：identity。
 */
    public let identity: String

    private init(hostName: ?HostName, ipAddress: ?IpAddress, port: UInt16, identity: String) {
        if (port == 0) { throw IllegalArgumentException("HTTP proxy port must be non-zero") }
        this.hostName = hostName
        this.ipAddress = ipAddress
        this.port = port
        this.identity = identity
    }

/**
 * Wirestack 公开 API：hostname。
 * @param port 参数 port。
 * @param value 参数 value。
 */
    public static func hostname(value: String, port: UInt16): HttpProxyEndpoint {
        let host = HostName(value)
        HttpProxyEndpoint(Some(host), None<IpAddress>, port, "${host.ascii}:${port}")
    }

/**
 * Wirestack 公开 API：address。
 * @param port 参数 port。
 * @param value 参数 value。
 */
    public static func address(value: IpAddress, port: UInt16): HttpProxyEndpoint {
        let encoded = proxyAddressIdentity(value)
        HttpProxyEndpoint(None<HostName>, Some(value), port, "${encoded}:${port}")
    }
}

/** Called only when constructing a request to the configured proxy. */
public interface HttpProxyAuthorizationProvider {
/**
 * Wirestack 公开 API：authorization。
 * @param context 参数 context。
 * @param proxy 参数 proxy。
 * @param target 参数 target。
 */
    func authorization(proxy: HttpProxyEndpoint, target: HttpUrl,
        context: OperationContext): ?String
}

/**
 * Wirestack 公开 API：NoProxyPolicy。
 */
public class NoProxyPolicy {
    private let ownedRules: Array<NoProxyRule>

/**
 * Wirestack 公开 API：init。
 */
    public init() { ownedRules = Array<NoProxyRule>() }

/**
 * Wirestack 公开 API：init。
 * @param patterns 参数 patterns。
 */
    public init(patterns: Array<String>) {
        if (patterns.size > 256) { throw IllegalArgumentException("NO_PROXY has too many patterns") }
        let rules = ArrayList<NoProxyRule>()
        for (pattern in patterns) { rules.add(parseNoProxyRule(pattern)) }
        ownedRules = rules.toArray()
    }

/**
 * Wirestack 公开 API：matches。
 * @param url 参数 url。
 */
    public func matches(url: HttpUrl): Bool {
        for (rule in ownedRules) {
            if (rule.matches(url.host, url.port)) { return true }
        }
        false
    }
}

/**
 * Wirestack 公开 API：HttpProxyRoute。
 */
public enum HttpProxyRoute {
/**
 * Wirestack 公开 API：Direct。
 */
    | Direct
/**
 * Wirestack 公开 API：Proxy。
 */
    | Proxy(HttpProxyConfig)
}

/** Explicit proxy configuration; no environment, PAC, or WPAD lookup occurs. */
public class HttpProxyConfig {
/**
 * Wirestack 公开 API：endpoint。
 */
    public let endpoint: HttpProxyEndpoint
/**
 * Wirestack 公开 API：resolver。
 */
    public let resolver: Resolver
/**
 * Wirestack 公开 API：noProxy。
 */
    public let noProxy: NoProxyPolicy
/**
 * Wirestack 公开 API：authorizationProvider。
 */
    public let authorizationProvider: ?HttpProxyAuthorizationProvider

/**
 * Wirestack 公开 API：init。
 * @param authorizationProvider 参数 authorizationProvider。
 * @param endpoint 参数 endpoint。
 * @param noProxy 参数 noProxy。
 * @param resolver 参数 resolver。
 */
    public init(endpoint: HttpProxyEndpoint, resolver: Resolver,
        noProxy!: NoProxyPolicy = NoProxyPolicy(),
        authorizationProvider!: ?HttpProxyAuthorizationProvider = None<HttpProxyAuthorizationProvider>) {
        this.endpoint = endpoint
        this.resolver = resolver
        this.noProxy = noProxy
        this.authorizationProvider = authorizationProvider
    }

/**
 * Wirestack 公开 API：routeFor。
 * @param url 参数 url。
 */
    public func routeFor(url: HttpUrl): HttpProxyRoute {
        if (noProxy.matches(url)) { HttpProxyRoute.Direct } else { HttpProxyRoute.Proxy(this) }
    }

/**
 * Wirestack 公开 API：authorization。
 * @param context 参数 context。
 * @param target 参数 target。
 */
    public func authorization(target: HttpUrl, context: OperationContext): ?String {
        match (authorizationProvider) {
            case Some(value) => value.authorization(endpoint, target, context)
            case None => None<String>
        }
    }
}

private class NoProxyRule {
    private let any: Bool
    private let host: String
    private let port: ?UInt16
    private let addressLiteral: Bool

    init(any: Bool, host: String, port: ?UInt16, addressLiteral: Bool) {
        this.any = any
        this.host = host
        this.port = port
        this.addressLiteral = addressLiteral
    }

    func matches(candidateHost: String, candidatePort: UInt16): Bool {
        if (any) { return true }
        if (let Some(required) <- port) {
            if (required != candidatePort) { return false }
        }
        let candidate = candidateHost.toAsciiLower()
        if (addressLiteral) { return candidate == host }
        candidate == host || candidate.endsWith(".${host}")
    }
}

private func parseNoProxyRule(value: String): NoProxyRule {
    if (value.isEmpty() || value.toArray().size > 512) {
        throw IllegalArgumentException("NO_PROXY pattern length is invalid")
    }
    if (value == "*") { return NoProxyRule(true, "", None<UInt16>, false) }
    var authority = value
    if (authority.startsWith("*.")) { authority = dropAsciiPrefix(authority, 2) }
    else if (authority.startsWith(".")) { authority = dropAsciiPrefix(authority, 1) }
    if (authority.isEmpty() || authority.contains("*") || authority.contains("/") ||
        authority.contains("?") || authority.contains("#") || authority.contains("@")) {
        throw IllegalArgumentException("NO_PROXY pattern is invalid")
    }
    let parsed = HttpUrl.parse("http://${authority}/")
    let explicit = if (parsed.explicitPort) { Some(parsed.port) } else { None<UInt16> }
    NoProxyRule(false, parsed.host, explicit, isIpLiteralHost(parsed.host))
}

private func isIpLiteralHost(host: String): Bool {
    if (host.contains(":")) { return true }
    for (byte in host.toArray()) {
        if ((byte < b'0' || byte > b'9') && byte != b'.') { return false }
    }
    true
}

private func proxyAddressIdentity(value: IpAddress): String {
    match (value.family) {
        case IpAddressFamily.Ipv4 =>
            let bytes = value.toOctets()
            "${bytes[0]}.${bytes[1]}.${bytes[2]}.${bytes[3]}"
        case IpAddressFamily.Ipv6 =>
            var result = "["
            let bytes = value.toOctets()
            for (index in 0..8) {
                if (index > 0) { result += ":" }
                let high = UInt16(bytes[index * 2])
                let low = UInt16(bytes[index * 2 + 1])
                result += hexUInt16((high << 8) | low)
            }
            match (value.zone) { case Some(zone) => result += "%${zone}"; case None => () }
            result += "]"
            result
    }
}

private func dropAsciiPrefix(value: String, count: Int64): String {
    let bytes = value.toArray()
    let result = Array<Byte>(bytes.size - count, repeat: 0)
    for (index in count..bytes.size) { result[index - count] = bytes[index] }
    String.fromUtf8(result)
}

private func hexUInt16(value: UInt16): String {
    let bytes = Array<Byte>(4, repeat: b'0')
    var remaining = value
    var index: Int64 = 3
    while (index >= 0) {
        let digit = UInt8(UInt64(remaining & 15u16))
        bytes[index] = if (digit < 10u8) { b'0' + digit } else { b'a' + digit - 10u8 }
        remaining = remaining >> 4
        index--
    }
    String.fromUtf8(bytes)
}
