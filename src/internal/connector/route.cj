package wirestack.internal.connector

import std.deriving.Derive
import wirestack.internal.common.*
import wirestack.internal.resolver.*

/** States who resolves a route target. No constructor performs DNS. */
@Derive[Equatable]
public enum RouteResolutionKind {
    | LocalDns
    | RemoteDns
    | Resolved
}

/**
 * One typed route target. A local DNS target owns its Resolver selection, a
 * remote DNS target delegates name resolution to an explicit proxy, and an IP
 * target is already resolved.
 */
public class RouteTarget {
    public let hostName: ?HostName
    public let socketEndpoint: ?SocketEndpoint
    public let resolver: ?Resolver
    public let resolution: RouteResolutionKind
    public let port: UInt16

    private init(
        hostName: ?HostName,
        socketEndpoint: ?SocketEndpoint,
        resolver: ?Resolver,
        resolution: RouteResolutionKind,
        port: UInt16
    ) {
        if (port == 0) {
            throw IllegalArgumentException("route target port must be non-zero")
        }
        this.hostName = hostName
        this.socketEndpoint = socketEndpoint
        this.resolver = resolver
        this.resolution = resolution
        this.port = port
    }

    /** A DNS name resolved locally by exactly this resolver. */
    public static func localName(host: HostName, port: UInt16, resolver: Resolver): RouteTarget {
        RouteTarget(Some(host), None<SocketEndpoint>, Some(resolver), RouteResolutionKind.LocalDns, port)
    }

    /** A DNS name intentionally resolved by an explicit proxy. */
    public static func remoteName(host: HostName, port: UInt16): RouteTarget {
        RouteTarget(Some(host), None<SocketEndpoint>, None<Resolver>, RouteResolutionKind.RemoteDns, port)
    }

    /** An already-resolved IP endpoint. This form can never enter DNS. */
    public static func address(endpoint: SocketEndpoint): RouteTarget {
        RouteTarget(None<HostName>, Some(endpoint), None<Resolver>, RouteResolutionKind.Resolved, endpoint.port)
    }
}

/** Opaque, non-native identity used to partition connections by network. */
@Derive[Equatable, Hashable]
public struct NetworkBinding {
    public let identity: String

    public init(identity: String) {
        validateRouteIdentity(identity, "network binding", 256)
        this.identity = identity
    }
}

/** Parameters forwarded to the later TLS and ALPN stage. */
public class RouteTlsParameters {
    public let contextIdentity: String
    private let ownedAlpnProtocols: Array<String>

    public init(contextIdentity: String, alpnProtocols: Array<String>) {
        validateRouteIdentity(contextIdentity, "TLS context", 512)
        validateRouteAlpn(alpnProtocols)
        this.contextIdentity = contextIdentity
        ownedAlpnProtocols = alpnProtocols.clone()
    }

    public prop alpnProtocols: Array<String> {
        get() { ownedAlpnProtocols.clone() }
    }
}

/** The protocol stage after TCP or proxy establishment. */
public enum RouteSecurity {
    | Plaintext
    | Tls(RouteTlsParameters)
}

/**
 * Immutable direct or explicit HTTP-proxy route. Origin identity remains
 * separate from the connect target, network binding and TLS parameters.
 */
public class ConnectionRoute {
    public let origin: RouteTarget
    public let proxy: ?RouteTarget
    public let networkBinding: NetworkBinding
    public let security: RouteSecurity

    private init(
        origin: RouteTarget,
        proxy: ?RouteTarget,
        networkBinding: NetworkBinding,
        security: RouteSecurity
    ) {
        this.origin = origin
        this.proxy = proxy
        this.networkBinding = networkBinding
        this.security = security
    }

    /** A direct route. A remote-DNS origin has no proxy and is rejected. */
    public static func direct(
        origin: RouteTarget,
        networkBinding: NetworkBinding,
        security: RouteSecurity
    ): ConnectionRoute {
        match (origin.resolution) {
            case RouteResolutionKind.RemoteDns =>
                throw IllegalArgumentException("a direct route cannot delegate origin DNS")
            case _ => ConnectionRoute(origin, None<RouteTarget>, networkBinding, security)
        }
    }

    /** An explicit HTTP proxy route. The proxy itself must be locally connectable. */
    public static func httpProxy(
        origin: RouteTarget,
        proxy: RouteTarget,
        networkBinding: NetworkBinding,
        security: RouteSecurity
    ): ConnectionRoute {
        match (proxy.resolution) {
            case RouteResolutionKind.RemoteDns =>
                throw IllegalArgumentException("an HTTP proxy target cannot delegate its own DNS")
            case _ => ConnectionRoute(origin, Some(proxy), networkBinding, security)
        }
    }

    /** The target used by TCP connect. Origin identity remains available separately. */
    public prop connectTarget: RouteTarget {
        get() { proxy ?? origin }
    }

    public prop isProxied: Bool {
        get() { proxy.isSome() }
    }
}

private func validateRouteIdentity(value: String, label: String, maximumBytes: Int64): Unit {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > maximumBytes) {
        throw IllegalArgumentException("${label} identity must contain 1 to ${maximumBytes} bytes")
    }
    for (byte in bytes) {
        if (byte < 0x20u8 || byte == 0x7fu8) {
            throw IllegalArgumentException("${label} identity cannot contain control bytes")
        }
    }
}

private func validateRouteAlpn(values: Array<String>): Unit {
    var wireBytes: Int64 = 0
    for (index in 0..values.size) {
        let encodedSize = values[index].toArray().size
        if (encodedSize == 0 || encodedSize > 255) {
            throw IllegalArgumentException("ALPN protocol names must contain 1 to 255 bytes")
        }
        if (wireBytes > 4096 - encodedSize - 1) {
            throw IllegalArgumentException("ALPN protocol list must fit within 4096 encoded bytes")
        }
        wireBytes += encodedSize + 1
        for (prior in 0..index) {
            if (values[prior] == values[index]) {
                throw IllegalArgumentException("ALPN protocol names must not repeat")
            }
        }
    }
}
