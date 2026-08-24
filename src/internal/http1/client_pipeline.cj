package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

/** DNS-to-HTTP/1 cleartext pipeline. HTTPS is added by the TLS connection factory. */
public class Http1CleartextClient <: Resource {
    private let pool: Http1ConnectionPool
    private let factory: Http1CleartextConnectionFactory

    public init(
        resolver: Resolver,
        transportFactory: TransportFactory,
        poolConfig!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        limits!: HttpLimits = HttpLimits(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        continueTimeout!: Duration = Duration.second
    ) {
        pool = Http1ConnectionPool(config: poolConfig)
        factory = Http1CleartextConnectionFactory(
            HappyEyeballsConnector(resolver, transportFactory, attemptDelay: attemptDelay),
            limits,
            continueTimeout
        )
    }

    public func execute(
        request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()
    ): HttpResponse {
        if (request.url.scheme != "http") {
            throw IllegalArgumentException("cleartext HTTP/1 client accepts only http URLs")
        }
        let key = cleartextPoolKey(request.url)
        let lease = pool.acquire(key, factory, context: context)
        try {
            let result = lease.connection.executeTracked(
                request,
                context: context,
                trailer: trailer,
                onTerminated: { reusable =>
                    if (reusable) {
                        pool.release(lease, context: context)
                    } else {
                        pool.discard(lease, context: context)
                    }
                }
            )
            result.response
        } catch (error: Exception) {
            pool.discard(lease, context: context)
            throw error
        }
    }

    public func snapshot(): Http1ConnectionPoolSnapshot { pool.snapshot() }
    public func close(): Unit { pool.close() }
    public func isClosed(): Bool { pool.isClosed() }
}

private class Http1CleartextConnectionFactory <: Http1ConnectionFactory {
    private let connector: HappyEyeballsConnector
    private let limits: HttpLimits
    private let continueTimeout: Duration

    init(connector: HappyEyeballsConnector, limits: HttpLimits, continueTimeout: Duration) {
        this.connector = connector
        this.limits = limits
        this.continueTimeout = continueTimeout
    }

    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        if (key.scheme != "http") { throw IllegalArgumentException("cleartext factory requires http pool key") }
        let connected = connector.connect(HostName(key.originHost), key.originPort, context: context)
        Http1ClientConnection(connected.transport, limits: limits, continueTimeout: continueTimeout)
    }
}

private func cleartextPoolKey(url: HttpUrl): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "http",
        url.host,
        url.port,
        None<String>,
        "default",
        "none",
        "none",
        "none",
        "none",
        "http/1.1"
    )
}
