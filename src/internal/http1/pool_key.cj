package wirestack.internal.http1

/** Complete security and routing partition key for HTTP connection reuse. */
public struct HttpConnectionPoolKey <: Equatable<HttpConnectionPoolKey> & Hashable {
    public let scheme: String
    public let originHost: String
    public let originPort: UInt16
    public let proxyRoute: ?String
    public let networkBinding: String
    public let tlsContextIdentity: String
    public let trustContextIdentity: String
    public let clientIdentity: String
    public let providerIdentity: String
    public let alpnPolicy: String

    public init(
        scheme: String,
        originHost: String,
        originPort: UInt16,
        proxyRoute: ?String,
        networkBinding: String,
        tlsContextIdentity: String,
        trustContextIdentity: String,
        clientIdentity: String,
        providerIdentity: String,
        alpnPolicy: String
    ) {
        let normalizedScheme = scheme.toAsciiLower()
        let normalizedHost = originHost.toAsciiLower()
        if ((normalizedScheme != "http" && normalizedScheme != "https") ||
            normalizedHost.isEmpty() || originPort == 0 || networkBinding.isEmpty() ||
            tlsContextIdentity.isEmpty() || trustContextIdentity.isEmpty() ||
            clientIdentity.isEmpty() || providerIdentity.isEmpty() || alpnPolicy.isEmpty()) {
            throw IllegalArgumentException("HTTP pool key requires every security and routing partition")
        }
        if (let Some(value) <- proxyRoute) {
            if (value.isEmpty()) { throw IllegalArgumentException("HTTP proxy route identity cannot be empty") }
        }
        this.scheme = normalizedScheme
        this.originHost = normalizedHost
        this.originPort = originPort
        this.proxyRoute = proxyRoute
        this.networkBinding = networkBinding
        this.tlsContextIdentity = tlsContextIdentity
        this.trustContextIdentity = trustContextIdentity
        this.clientIdentity = clientIdentity
        this.providerIdentity = providerIdentity
        this.alpnPolicy = alpnPolicy
    }

    public operator func ==(other: HttpConnectionPoolKey): Bool {
        scheme == other.scheme && originHost == other.originHost && originPort == other.originPort &&
            proxyRoute == other.proxyRoute && networkBinding == other.networkBinding &&
            tlsContextIdentity == other.tlsContextIdentity &&
            trustContextIdentity == other.trustContextIdentity && clientIdentity == other.clientIdentity &&
            providerIdentity == other.providerIdentity && alpnPolicy == other.alpnPolicy
    }

    public operator func !=(other: HttpConnectionPoolKey): Bool { !(this == other) }

    public func hashCode(): Int64 {
        var hasher = DefaultHasher()
        hasher.write(scheme)
        hasher.write(originHost)
        hasher.write(originPort)
        match (proxyRoute) {
            case Some(value) => hasher.write(1u8); hasher.write(value)
            case None => hasher.write(0u8)
        }
        hasher.write(networkBinding)
        hasher.write(tlsContextIdentity)
        hasher.write(trustContextIdentity)
        hasher.write(clientIdentity)
        hasher.write(providerIdentity)
        hasher.write(alpnPolicy)
        hasher.finish()
    }
}
