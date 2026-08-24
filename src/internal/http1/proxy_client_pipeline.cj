package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

/** DNS and typed-address proxy endpoint forms retained without string reparsing. */
public class Http1ProxyEndpoint {
    public let hostName: ?HostName
    public let ipAddress: ?IpAddress
    public let port: UInt16
    public let identity: String

    private init(hostName: ?HostName, ipAddress: ?IpAddress, port: UInt16, identity: String) {
        if (port == 0 || identity.isEmpty()) {
            throw IllegalArgumentException("HTTP/1 proxy endpoint requires a non-zero port and identity")
        }
        this.hostName = hostName
        this.ipAddress = ipAddress
        this.port = port
        this.identity = identity
    }

    public static func hostname(value: HostName, port: UInt16, identity: String): Http1ProxyEndpoint {
        Http1ProxyEndpoint(Some(value), None<IpAddress>, port, identity)
    }

    public static func address(value: IpAddress, port: UInt16, identity: String): Http1ProxyEndpoint {
        Http1ProxyEndpoint(None<HostName>, Some(value), port, identity)
    }
}

/** HTTP forward-proxy pipeline. It resolves/connects only the proxy and emits absolute-form. */
public class Http1ForwardProxyClient <: Resource {
    private let endpoint: Http1ProxyEndpoint
    private let pool: Http1ConnectionPool
    private let factory: Http1ForwardProxyConnectionFactory

    public init(
        endpoint: Http1ProxyEndpoint,
        resolver: Resolver,
        transportFactory: TransportFactory,
        poolConfig!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        limits!: HttpLimits = HttpLimits(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        continueTimeout!: Duration = Duration.second
    ) {
        this.endpoint = endpoint
        pool = Http1ConnectionPool(config: poolConfig)
        factory = Http1ForwardProxyConnectionFactory(
            endpoint, resolver, transportFactory, limits, attemptDelay, continueTimeout
        )
    }

    public func execute(request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()): HttpResponse {
        if (request.url.scheme != "http") {
            throw IllegalArgumentException("HTTP forward proxy client accepts only http URLs")
        }
        let key = HttpConnectionPoolKey(
            "http", request.url.host, request.url.port, Some(endpoint.identity), "default",
            "none", "none", "none", "none", "http/1.1"
        )
        let lease = pool.acquire(key, factory, context: context)
        try {
            let result = lease.connection.executeTracked(request, context: context, trailer: trailer,
                onTerminated: { reusable =>
                    if (reusable) { pool.release(lease) } else { pool.discard(lease) }
                })
            result.response
        } catch (error: Exception) {
            pool.discard(lease)
            throw error
        }
    }

    public func snapshot(): Http1ConnectionPoolSnapshot { pool.snapshot() }
    public func close(): Unit { pool.close() }
    public func isClosed(): Bool { pool.isClosed() }
}

private class Http1ForwardProxyConnectionFactory <: Http1ConnectionFactory {
    private let endpoint: Http1ProxyEndpoint
    private let connector: HappyEyeballsConnector
    private let transportFactory: TransportFactory
    private let limits: HttpLimits
    private let continueTimeout: Duration

    init(endpoint: Http1ProxyEndpoint, resolver: Resolver, transportFactory: TransportFactory,
        limits: HttpLimits, attemptDelay: Duration, continueTimeout: Duration) {
        this.endpoint = endpoint
        connector = HappyEyeballsConnector(resolver, transportFactory, attemptDelay: attemptDelay)
        this.transportFactory = transportFactory
        this.limits = limits
        this.continueTimeout = continueTimeout
    }

    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        if (key.proxyRoute != Some(endpoint.identity)) {
            throw IllegalArgumentException("HTTP forward proxy factory received a mismatched route key")
        }
        let transport = match (endpoint.ipAddress) {
            case Some(address) => transportFactory.connect(SocketEndpoint(address, endpoint.port), context)
            case None =>
                let host = endpoint.hostName.getOrThrow()
                connector.connect(host, endpoint.port, context: context).transport
        }
        Http1ClientConnection(
            transport, limits: limits, continueTimeout: continueTimeout,
            targetForm: Http1RequestTargetForm.Absolute
        )
    }
}
