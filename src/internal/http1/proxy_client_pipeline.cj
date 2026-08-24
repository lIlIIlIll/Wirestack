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
                    if (reusable) {
                        pool.release(lease, context: context)
                    } else {
                        pool.discard(lease, context: context)
                    }
                })
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

/** A non-2xx proxy CONNECT response. Credentials and response bodies are never retained. */
public class Http1ProxyConnectException <: NetworkException {
    public let status: Int64
    public let reason: String

    public init(status: Int64, reason: String) {
        super(
            NetworkErrorCategory.Connect,
            NetworkPhase.ProxyConnect,
            NetworkErrorCode.ConnectRefused,
            "HTTP proxy rejected CONNECT with status ${status}",
            retryability: Retryability.Never
        )
        this.status = status
        this.reason = reason
    }

    protected override func getClassName(): String { "Http1ProxyConnectException" }
}

/** HTTPS-over-CONNECT pipeline. Proxy routing never changes TLS reference identity or SNI. */
public class Http1HttpsProxyClient <: Resource {
    private let endpoint: Http1ProxyEndpoint
    private let resolver: Resolver
    private let transportFactory: TransportFactory
    private let handshaker: Http1TlsHandshaker
    private let pool: Http1ConnectionPool
    private let limits: HttpLimits
    private let attemptDelay: Duration
    private let continueTimeout: Duration

    public init(
        endpoint: Http1ProxyEndpoint,
        resolver: Resolver,
        transportFactory: TransportFactory,
        handshaker: Http1TlsHandshaker,
        poolConfig!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        limits!: HttpLimits = HttpLimits(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        continueTimeout!: Duration = Duration.second
    ) {
        this.endpoint = endpoint
        this.resolver = resolver
        this.transportFactory = transportFactory
        this.handshaker = handshaker
        pool = Http1ConnectionPool(config: poolConfig)
        this.limits = limits
        this.attemptDelay = attemptDelay
        this.continueTimeout = continueTimeout
    }

    public func execute(request: HttpRequest,
        proxyAuthorization!: ?String = None<String>,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()): HttpResponse {
        if (request.url.scheme != "https") {
            throw IllegalArgumentException("HTTPS proxy client accepts only https URLs")
        }
        let key = HttpConnectionPoolKey(
            "https", request.url.host, request.url.port, Some(endpoint.identity), "default",
            handshaker.tlsContextIdentity, handshaker.trustContextIdentity,
            handshaker.clientIdentity, handshaker.providerIdentity, handshaker.alpnPolicy
        )
        let factory = Http1HttpsProxyConnectionFactory(
            endpoint, resolver, transportFactory, handshaker, request.url, proxyAuthorization,
            limits, attemptDelay, continueTimeout
        )
        let lease = pool.acquire(key, factory, context: context)
        try {
            let result = lease.connection.executeTracked(request, context: context, trailer: trailer,
                onTerminated: { reusable =>
                    if (reusable) {
                        pool.release(lease, context: context)
                    } else {
                        pool.discard(lease, context: context)
                    }
                })
            result.response
        } catch (error: Exception) {
            pool.discard(lease, context: context)
            throw error
        }
    }

    public func snapshot(): Http1ConnectionPoolSnapshot { pool.snapshot() }
    public func close(): Unit { pool.close(); handshaker.close() }
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
            case Some(address) =>
                let connected = transportFactory.connect(SocketEndpoint(address, endpoint.port), context)
                emitProxyTcpConnected(context)
                connected
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

private class Http1HttpsProxyConnectionFactory <: Http1ConnectionFactory {
    private let endpoint: Http1ProxyEndpoint
    private let connector: HappyEyeballsConnector
    private let transportFactory: TransportFactory
    private let handshaker: Http1TlsHandshaker
    private let target: HttpUrl
    private let connectHeaders: HttpHeaders
    private let limits: HttpLimits
    private let continueTimeout: Duration

    init(endpoint: Http1ProxyEndpoint, resolver: Resolver, transportFactory: TransportFactory,
        handshaker: Http1TlsHandshaker, target: HttpUrl, proxyAuthorization: ?String,
        limits: HttpLimits, attemptDelay: Duration, continueTimeout: Duration) {
        this.endpoint = endpoint
        connector = HappyEyeballsConnector(resolver, transportFactory, attemptDelay: attemptDelay)
        this.transportFactory = transportFactory
        this.handshaker = handshaker
        this.target = target
        let builder = HttpHeaders.builder(limits: limits)
        if (let Some(value) <- proxyAuthorization) { builder.add("Proxy-Authorization", value) }
        connectHeaders = builder.build()
        this.limits = limits
        this.continueTimeout = continueTimeout
    }

    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        if (key.scheme != "https" || key.proxyRoute != Some(endpoint.identity) ||
            key.originHost != target.host || key.originPort != target.port) {
            throw IllegalArgumentException("HTTPS proxy factory received a mismatched route key")
        }
        let proxyTransport = connectProxy(endpoint, connector, transportFactory, context)
        let exchanged = try {
            performHttp1Connect(
                proxyTransport, target, headers: connectHeaders, context: context, limits: limits
            )
        } catch (error: Exception) {
            emitProxyTunnelEvent(context, NetworkEventOutcome.Failed, proxyEventCode(error))
            throw error
        }
        match (exchanged) {
            case Http1ConnectExchangeResult.Tunnel(tunnel) =>
                emitProxyTunnelEvent(context, NetworkEventOutcome.Succeeded, None<NetworkErrorCode>)
                try {
                    let tls = handshaker.handshake(HostName(key.originHost), tunnel.transport, context)
                    Http1ClientConnection(tls, limits: limits, continueTimeout: continueTimeout)
                } catch (error: Exception) {
                    try { tunnel.transport.abort(reason: Some(AbortReason.ProtocolFailure)) }
                    catch (_: Exception) {}
                    throw error
                }
            case Http1ConnectExchangeResult.Response(result) =>
                let status = result.response.status
                let reason = result.response.reason
                try { let _ = result.response.body.drain(64 * 1024) }
                finally { result.response.close() }
                emitProxyTunnelEvent(context, NetworkEventOutcome.Failed,
                    Some(NetworkErrorCode.ConnectRefused))
                throw Http1ProxyConnectException(status, reason)
        }
    }
}

private func proxyEventCode(error: Exception): ?NetworkErrorCode {
    match (error) {
        case value: NetworkException => Some(value.code)
        case _ => Some(NetworkErrorCode.SystemFailure)
    }
}

private func emitProxyTunnelEvent(context: OperationContext,
    outcome: NetworkEventOutcome, code: ?NetworkErrorCode): Unit {
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.ProxyTunnelEstablished,
        outcome,
        trace: context.trace,
        phase: Some(NetworkPhase.ProxyConnect),
        errorCode: code
    ))
}

private func connectProxy(endpoint: Http1ProxyEndpoint, connector: HappyEyeballsConnector,
    transportFactory: TransportFactory, context: OperationContext): DuplexTransport {
    match (endpoint.ipAddress) {
        case Some(address) =>
            let connected = transportFactory.connect(SocketEndpoint(address, endpoint.port), context)
            emitProxyTcpConnected(context)
            connected
        case None => connector.connect(endpoint.hostName.getOrThrow(), endpoint.port, context: context).transport
    }
}

private func emitProxyTcpConnected(context: OperationContext): Unit {
    emitNetworkEvent(context, NetworkEvent(
        NetworkEventKind.TcpConnected,
        NetworkEventOutcome.Succeeded,
        trace: context.trace,
        phase: Some(NetworkPhase.TcpConnect)
    ))
}
