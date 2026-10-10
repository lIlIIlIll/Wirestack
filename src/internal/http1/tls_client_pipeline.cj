package wirestack.internal.http1

import wirestack.NetworkConnectionPoolSnapshot

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.internal.http_model.*
import wirestack.internal.http2.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.tls_engine.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*
import wirestack.internal as internal
/** TLS policy/engine boundary retained in every HTTPS pool partition. */
public interface Http1TlsHandshaker <: Resource {
    prop tlsContextIdentity: String
    prop trustContextIdentity: String
    prop clientIdentity: String
    prop providerIdentity: String
    prop alpnPolicy: String
    func handshake(reference: ReferenceIdentity, transport: DuplexTransport, context: OperationContext): DuplexTransport
}

/** One TLS transport plus the protocol selected by its immutable ALPN policy. */
public class HttpNegotiatedTlsTransport {
    public let protocol: HttpNegotiatedProtocol
    public let transport: DuplexTransport

    public init(protocol: HttpNegotiatedProtocol, transport: DuplexTransport) {
        this.protocol = protocol
        this.transport = transport
    }
}

/** Automatic HTTPS handshaker offering h2 first and retaining complete pool identity. */
public interface HttpAlpnTlsHandshaker <: Resource {
    prop tlsContextIdentity: String
    prop trustContextIdentity: String
    prop clientIdentity: String
    prop providerIdentity: String
    prop alpnPolicy: String
    func handshakeNegotiated(
        reference: ReferenceIdentity,
        transport: DuplexTransport,
        context: OperationContext
    ): HttpNegotiatedTlsTransport
}

/** Selected TLS HTTPS handshaker. It owns its provider and closes it after every pooled connection. */
public class DefaultHttp1TlsHandshaker <: Http1TlsHandshaker & HttpAlpnTlsHandshaker {
    private let provider: TlsProvider
    private let context: TlsClientContext
    private let ownedPrivateKey: ?PrivateKeyRef
    private let mutex = Mutex()
    private var closed = false

    private init(provider: TlsProvider, context: TlsClientContext,
        ownedPrivateKey: ?PrivateKeyRef) {
        this.provider = provider
        this.context = context
        this.ownedPrivateKey = ownedPrivateKey
    }

    public static func systemDefault(): DefaultHttp1TlsHandshaker {
        create(TrustPolicy.system())
    }

    public static func systemDefaultAlpn(): DefaultHttp1TlsHandshaker {
        createAlpn(TrustPolicy.system())
    }

    public static func create(
        trust: TrustPolicy,
        identity!: ?LocalIdentity = None<LocalIdentity>,
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): DefaultHttp1TlsHandshaker {
        createOwned(trust, identity, None<PrivateKeyRef>, securityProfile, ["http/1.1"])
    }

    public static func createAlpn(
        trust: TrustPolicy,
        identity!: ?LocalIdentity = None<LocalIdentity>,
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): DefaultHttp1TlsHandshaker {
        createOwned(
            trust, identity, None<PrivateKeyRef>, securityProfile, httpClientAlpnProtocols()
        )
    }

    /** Creates a handshaker that exclusively owns an optional DER client identity. */
    public static func createWithDer(
        customTrustRootsDer: Array<Array<Byte>>,
        clientCertificateChainDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        clientPrivateKeyPkcs8Der!: Array<Byte> = Array<Byte>(),
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): DefaultHttp1TlsHandshaker {
        let roots = ArrayList<DerCertificate>()
        for (encoded in customTrustRootsDer) { roots.add(DerCertificate(encoded)) }
        let trust = TrustPolicy.customRoots(CertificateChain(roots.toArray()))
        if (clientCertificateChainDer.isEmpty() != clientPrivateKeyPkcs8Der.isEmpty()) {
            throw IllegalArgumentException(
                "HTTPS client certificate chain and PKCS#8 key must be configured together"
            )
        }
        if (clientCertificateChainDer.isEmpty()) {
            return createOwned(trust, None<LocalIdentity>, None<PrivateKeyRef>,
                securityProfile, ["http/1.1"])
        }
        let certificates = ArrayList<DerCertificate>()
        for (encoded in clientCertificateChainDer) { certificates.add(DerCertificate(encoded)) }
        let key = PrivateKeyRef.pkcs8(clientPrivateKeyPkcs8Der)
        try {
            let identity = LocalIdentity(CertificateChain(certificates.toArray()), key)
            createOwned(trust, Some(identity), Some(key), securityProfile, ["http/1.1"])
        } catch (error: Exception) {
            key.close()
            throw error
        }
    }

    /** Creates an h2-first automatic handshaker that owns optional DER client identity material. */
    public static func createWithDerAlpn(
        customTrustRootsDer: Array<Array<Byte>>,
        clientCertificateChainDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        clientPrivateKeyPkcs8Der!: Array<Byte> = Array<Byte>(),
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): DefaultHttp1TlsHandshaker {
        let roots = ArrayList<DerCertificate>()
        for (encoded in customTrustRootsDer) { roots.add(DerCertificate(encoded)) }
        let trust = TrustPolicy.customRoots(CertificateChain(roots.toArray()))
        if (clientCertificateChainDer.isEmpty() != clientPrivateKeyPkcs8Der.isEmpty()) {
            throw IllegalArgumentException(
                "HTTPS client certificate chain and PKCS#8 key must be configured together"
            )
        }
        if (clientCertificateChainDer.isEmpty()) {
            return createOwned(trust, None<LocalIdentity>, None<PrivateKeyRef>,
                securityProfile, httpClientAlpnProtocols())
        }
        let certificates = ArrayList<DerCertificate>()
        for (encoded in clientCertificateChainDer) { certificates.add(DerCertificate(encoded)) }
        let key = PrivateKeyRef.pkcs8(clientPrivateKeyPkcs8Der)
        try {
            let identity = LocalIdentity(CertificateChain(certificates.toArray()), key)
            createOwned(trust, Some(identity), Some(key), securityProfile, httpClientAlpnProtocols())
        } catch (error: Exception) {
            key.close()
            throw error
        }
    }

    private static func createOwned(
        trust: TrustPolicy,
        identity: ?LocalIdentity,
        ownedPrivateKey: ?PrivateKeyRef,
        securityProfile: TlsSecurityProfile,
        alpnProtocols: Array<String>
    ): DefaultHttp1TlsHandshaker {
        let provider = selectedTlsProvider()
        try {
            let builder = TlsClientContext.builder(provider.manifest(), provider.capabilities())
                .securityProfile(securityProfile)
                .alpn(alpnProtocols)
            builder.trust(trust)
            if (let Some(value) <- identity) { builder.identity(value) }
            let context = builder.build()
            // Validate native trust/key installation before a configuration can
            // become current. This creates no transport and starts no handshake.
            let validationHost = HostName("configuration.invalid")
            let validationEngine = provider.createClientEngine(context,
                ReferenceIdentity.Dns(validationHost), serverName: Some(validationHost))
            validationEngine.close()
            DefaultHttp1TlsHandshaker(provider, context, ownedPrivateKey)
        } catch (error: Exception) {
            provider.close()
            match (ownedPrivateKey) { case Some(value) => value.close(); case None => () }
            throw error
        }
    }

    public prop tlsContextIdentity: String {
        get() {
            "${provider.manifest().fingerprint}:${tlsProfileIdentity(context.security.profile)}:" +
            "${tlsVersionIdentity(context.security.minimumVersion)}-${tlsVersionIdentity(context.security.maximumVersion)}"
        }
    }
    public prop trustContextIdentity: String { get() { context.trust.contextIdentity } }
    public prop clientIdentity: String {
        get() { match (context.identity) { case Some(value) => value.contextIdentity; case None => "none" } }
    }
    public prop providerIdentity: String { get() { provider.manifest().fingerprint } }
    public prop alpnPolicy: String { get() { joinHttpAlpn(context.alpnProtocols()) } }

    public func handshake(reference: ReferenceIdentity, transport: DuplexTransport,
        operation: OperationContext): DuplexTransport {
        let negotiated = handshakeNegotiated(reference, transport, operation)
        if (!isNegotiatedHttp11(negotiated.protocol)) {
            negotiated.transport.abort(reason: Some(AbortReason.ProtocolFailure))
            throw TlsEngineException(TlsEngineErrorCode.NoSharedAlpn,
                "HTTPS HTTP/1 connection negotiated an unexpected ALPN protocol")
        }
        negotiated.transport
    }

    public func handshakeNegotiated(reference: ReferenceIdentity, transport: DuplexTransport,
        operation: OperationContext): HttpNegotiatedTlsTransport {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTPS handshaker is closed") }
        }
        let handshakeContext = operation.forStage(OperationTimeoutStage.TlsHandshake)
        emitTlsHandshakeEvent(handshakeContext, NetworkEventOutcome.Started, None<NetworkErrorCode>)
        try {
            let engine = provider.createClientEngine(
                context,
                reference,
                serverName: match (reference) {
                    case ReferenceIdentity.Dns(host) => Some(host)
                    case ReferenceIdentity.Ip(_) => None<HostName>
                }
            )
            let connection = TlsConnection.handshake(
                engine, transport, context: handshakeContext, pump: TlsEnginePump()
            )
            let protocol = try {
                match (connection.handshakeInfo) {
                    case Some(info) => match (info.negotiatedAlpn) {
                        case Some(value) => selectHttpNegotiatedProtocol(Some(value))
                        case None => selectHttpNegotiatedProtocol(None<String>)
                    }
                    case None => throw TlsEngineException(TlsEngineErrorCode.ProviderFailure,
                        "HTTPS handshake returned no negotiated TLS evidence")
                }
            } catch (error: Exception) {
                connection.abort(reason: Some(AbortReason.ProtocolFailure))
                throw error
            }
            emitTlsHandshakeEvent(handshakeContext, NetworkEventOutcome.Succeeded, None<NetworkErrorCode>)
            HttpNegotiatedTlsTransport(protocol, connection)
        } catch (error: Exception) {
            let code = match (error) {
                case value: NetworkException => Some(value.code)
                case _ => Some(NetworkErrorCode.SystemFailure)
            }
            emitTlsHandshakeEvent(handshakeContext, NetworkEventOutcome.Failed, code)
            throw error
        }
    }

    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) {
            provider.close()
            match (ownedPrivateKey) { case Some(value) => value.close(); case None => () }
        }
    }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private func emitTlsHandshakeEvent(context: OperationContext,
    outcome: NetworkEventOutcome, code: ?NetworkErrorCode): Unit {
    let kind = match (outcome) {
        case NetworkEventOutcome.Started => NetworkEventKind.TlsHandshakeStarted
        case _ => NetworkEventKind.TlsHandshakeCompleted
    }
    emitNetworkEvent(context, NetworkEvent(
        kind,
        outcome,
        trace: context.trace,
        phase: Some(NetworkPhase.TlsHandshake),
        errorCode: code
    ))
}

/** DNS-to-TLS-to-HTTP/1 pipeline with complete security partitioning. */
public class Http1HttpsClient <: Resource {
    private let pool: Http1ConnectionPool
    private let handshaker: Http1TlsHandshaker
    private let factory: Http1TlsConnectionFactory

    public init(
        resolver: Resolver,
        transportFactory: TransportFactory,
        handshaker: Http1TlsHandshaker,
        poolConfig!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        limits!: HttpLimits = HttpLimits(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        continueTimeout!: Duration = Duration.second,
        resourceBudget!: ?internal.HttpResourceBudget = None<internal.HttpResourceBudget>
    ) {
        this.handshaker = handshaker
        pool = Http1ConnectionPool(config: poolConfig, resourceBudget: resourceBudget)
        factory = Http1TlsConnectionFactory(
            HappyEyeballsConnector(resolver, transportFactory, attemptDelay: attemptDelay),
            handshaker,
            limits,
            continueTimeout
        )
    }

    public func execute(request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()): HttpResponse {
        if (request.url.scheme != "https") {
            throw IllegalArgumentException("HTTPS HTTP/1 client accepts only https URLs")
        }
        let lease = pool.acquire(tlsPoolKey(request.url, handshaker), factory, context: context)
        try {
            let result = lease.connection.executeTracked(request, context: connectionEventContext(context, lease.connectionId), trailer: trailer,
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

    public func upgrade(request: HttpRequest,
        context!: OperationContext = OperationContext.background()): Http1UpgradeExchangeResult {
        if (request.url.scheme != "https") {
            throw IllegalArgumentException("HTTPS HTTP/1 upgrade requires an https URL")
        }
        upgradeHttp1Lease(pool, factory, tlsPoolKey(request.url, handshaker), request, context)
    }

    public func observationSnapshot(): NetworkConnectionPoolSnapshot { pool.observationSnapshot() }
    public func snapshot(): Http1ConnectionPoolSnapshot { pool.snapshot() }
    public func retire(): Unit { pool.retire() }
    public func abortConnections(): Unit { pool.close() }
    public func close(): Unit { pool.close(); handshaker.close() }
    public func isClosed(): Bool { pool.isClosed() }
}

private enum CachedHttpProtocol {
    | Http2
    | Http11
}

private class CachedHttpProtocolEntry {
    let key: HttpConnectionPoolKey
    let protocol: CachedHttpProtocol
    init(key: HttpConnectionPoolKey, protocol: CachedHttpProtocol) {
        this.key = key
        this.protocol = protocol
    }
}

/** Bounded ALPN routing memory; it is a hint, never a security partition. */
private class HttpProtocolCache {
    private let maximumEntries: Int64
    private let mutex = Mutex()
    private let entries = ArrayList<CachedHttpProtocolEntry>()

    init(maximumEntries: Int64) {
        if (maximumEntries <= 0) { throw IllegalArgumentException("HTTP protocol cache bound must be positive") }
        this.maximumEntries = maximumEntries
    }

    func get(key: HttpConnectionPoolKey): ?CachedHttpProtocol {
        synchronized(mutex) {
            for (entry in entries) { if (entry.key == key) { return Some(entry.protocol) } }
            None<CachedHttpProtocol>
        }
    }

    func put(key: HttpConnectionPoolKey, protocol: CachedHttpProtocol): Unit {
        synchronized(mutex) {
            for (index in 0..entries.size) {
                if (entries[index].key == key) {
                    let _ = entries.remove(at: index)
                    entries.add(CachedHttpProtocolEntry(key, protocol))
                    return
                }
            }
            if (entries.size >= maximumEntries) { let _ = entries.remove(at: 0) }
            entries.add(CachedHttpProtocolEntry(key, protocol))
        }
    }
}

private class Http11NegotiatedException <: Exception {
    let connection: ?Http1ClientConnection
    let resourceLease: ?internal.HttpResourceLease
    let connectionId: ?Int64
    init(
        connectionId!: ?Int64 = None<Int64>,
        connection!: ?Http1ClientConnection = None<Http1ClientConnection>,
        resourceLease!: ?internal.HttpResourceLease = None<internal.HttpResourceLease>
    ) {
        super("HTTPS ALPN selected HTTP/1.1")
        this.connectionId = connectionId
        this.connection = connection
        this.resourceLease = resourceLease
    }
    protected override func getClassName(): String { "Http11NegotiatedException" }
}

private class Http2NegotiatedException <: Exception {
    let connection: Http2ClientPoolConnection
    let resourceLease: ?internal.HttpResourceLease
    let connectionId: ?Int64
    init(connection: Http2ClientPoolConnection, resourceLease: ?internal.HttpResourceLease, connectionId!: ?Int64) {
        super("HTTPS ALPN selected h2")
        this.connectionId = connectionId
        this.connection = connection
        this.resourceLease = resourceLease
    }
    protected override func getClassName(): String { "Http2NegotiatedException" }
}

private func retainOptionalHttpResourceLease(
    resourceLease: ?internal.HttpResourceLease
): ?internal.HttpResourceLease {
    match (resourceLease) {
        case Some(value) => Some(value.retain())
        case None => None<internal.HttpResourceLease>
    }
}

private class AutomaticTlsNegotiator {
    private let connector: HappyEyeballsConnector
    private let handshaker: HttpAlpnTlsHandshaker
    private let cache: HttpProtocolCache
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let continueTimeout: Duration
    private let pushConfig: ?Http2PushConfig
    private let resourceBudget: ?internal.HttpResourceBudget
    init(
        connector: HappyEyeballsConnector,
        handshaker: HttpAlpnTlsHandshaker,
        cache: HttpProtocolCache,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        continueTimeout: Duration,
        pushConfig: ?Http2PushConfig,
        resourceBudget: ?internal.HttpResourceBudget
    ) {
        this.connector = connector
        this.pushConfig = pushConfig
        this.resourceBudget = resourceBudget
        this.handshaker = handshaker
        this.cache = cache
        this.limits = limits
        this.http2Limits = http2Limits
        this.continueTimeout = continueTimeout
    }

    func createHttp2(
        key: HttpConnectionPoolKey,
        context: OperationContext,
        resourceLease: ?internal.HttpResourceLease
    ): Http2MultiplexedConnection {
        if (let Some(CachedHttpProtocol.Http11) <- cache.get(key)) {
            throw Http11NegotiatedException()
        }
        let resourceOwner = match (resourceBudget) {
            case Some(_) => Some(httpResourceOwnerForPoolKey(key))
            case None => None<internal.HttpResourceOwnerKey>
        }
        let negotiated = connect(key, context)
        match (negotiated.protocol) {
            case HttpNegotiatedProtocol.Http2 =>
                cache.put(key, CachedHttpProtocol.Http2)
                try {
                    Http2ClientPoolConnection(Http2ClientConnection.connect(
                        negotiated.transport, context: context, limits: limits,
                        http2Limits: http2Limits, pushConfig: pushConfig,
                        resourceBudget: resourceBudget,
                        resourceOwner: resourceOwner
                    ))
                } catch (error: Exception) {
                    negotiated.transport.abort(reason: Some(AbortReason.ProtocolFailure))
                    throw error
                }
            case HttpNegotiatedProtocol.Http11 =>
                cache.put(key, CachedHttpProtocol.Http11)
                throw Http11NegotiatedException(
                    connectionId: context.connectionId,
                    connection: Some(Http1ClientConnection(
                        negotiated.transport, limits: limits, continueTimeout: continueTimeout
                    )),
                    resourceLease: retainOptionalHttpResourceLease(resourceLease)
                )
        }
    }

    func createHttp1(
        key: HttpConnectionPoolKey,
        context: OperationContext,
        resourceLease: ?internal.HttpResourceLease
    ): Http1ClientConnection {
        let negotiated = connect(key, context)
        match (negotiated.protocol) {
            case HttpNegotiatedProtocol.Http11 =>
                cache.put(key, CachedHttpProtocol.Http11)
                Http1ClientConnection(negotiated.transport, limits: limits, continueTimeout: continueTimeout)
            case HttpNegotiatedProtocol.Http2 =>
                cache.put(key, CachedHttpProtocol.Http2)
                try {
                    throw Http2NegotiatedException(
                        Http2ClientPoolConnection(Http2ClientConnection.connect(
                            negotiated.transport,
                            context: context,
                            limits: limits,
                            http2Limits: http2Limits,
                            pushConfig: pushConfig,
                            resourceBudget: resourceBudget,
                            resourceOwner: Some(httpResourceOwnerForPoolKey(key))
                        )),
                        retainOptionalHttpResourceLease(resourceLease), connectionId: context.connectionId
                    )
                } catch (error: Http2NegotiatedException) {
                    throw error
                } catch (error: Exception) {
                    negotiated.transport.abort(reason: Some(AbortReason.ProtocolFailure))
                    throw error
                }
        }
    }

    private func connect(
        key: HttpConnectionPoolKey,
        context: OperationContext
    ): HttpNegotiatedTlsTransport {
        if (key.scheme != "https") { throw IllegalArgumentException("automatic TLS factory requires https") }
        let reference = httpOriginIdentity(key.originHost)
        let connected = connectHttpOrigin(connector, reference, key.originPort, context)
        try {
            handshaker.handshakeNegotiated(
                reference, connected,
                context.forStage(OperationTimeoutStage.TlsHandshake)
            )
        } catch (error: Exception) {
            connected.abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        }
    }
}

private class AutomaticHttp2Factory <: Http2MultiplexedConnectionFactory {
    private let negotiator: AutomaticTlsNegotiator
    init(negotiator: AutomaticTlsNegotiator) { this.negotiator = negotiator }
    public func create(key: HttpConnectionPoolKey, context: OperationContext,
        resourceLease: ?internal.HttpResourceLease): Http2MultiplexedConnection {
        negotiator.createHttp2(key, context, resourceLease)
    }
}

private class AutomaticHttp1Factory <: Http1ConnectionFactory {
    private let negotiator: AutomaticTlsNegotiator
    init(negotiator: AutomaticTlsNegotiator) { this.negotiator = negotiator }
    public func create(key: HttpConnectionPoolKey, context: OperationContext,
        resourceLease: ?internal.HttpResourceLease): Http1ClientConnection {
        negotiator.createHttp1(key, context, resourceLease)
    }
}

/**
 * h2-first HTTPS client. The first negotiated connection selects a bounded
 * protocol route; HTTP/2 leases stream capacity while HTTP/1.1 keeps exclusive
 * connection ownership and bounded response-drain reuse.
 */
public class HttpAutomaticHttpsClient <: Resource {
    private let h1Pool: Http1ConnectionPool
    private let h2Pool: Http2ConnectionPool
    private let handshaker: HttpAlpnTlsHandshaker
    private let cache: HttpProtocolCache
    private let h1Factory: AutomaticHttp1Factory
    private let h2Factory: AutomaticHttp2Factory
    private let limits: HttpLimits
    private let http2Limits: Http2Limits

    public init(
        resolver: Resolver,
        transportFactory: TransportFactory,
        handshaker: HttpAlpnTlsHandshaker,
        h1PoolConfig!: Http1ConnectionPoolConfig = Http1ConnectionPoolConfig(),
        h2PoolConfig!: Http2ConnectionPoolConfig = Http2ConnectionPoolConfig(),
        limits!: HttpLimits = HttpLimits(),
        http2Limits!: Http2Limits = Http2Limits(),
        attemptDelay!: Duration = 250 * Duration.millisecond,
        continueTimeout!: Duration = Duration.second,
        pushConfig!: ?Http2PushConfig = None<Http2PushConfig>,
        resourceBudget!: ?internal.HttpResourceBudget = None<internal.HttpResourceBudget>
    ) {
        this.handshaker = handshaker
        this.limits = limits
        this.http2Limits = http2Limits
        h1Pool = Http1ConnectionPool(config: h1PoolConfig, resourceBudget: resourceBudget)
        h2Pool = Http2ConnectionPool(config: h2PoolConfig, resourceBudget: resourceBudget)
        cache = HttpProtocolCache(h1PoolConfig.maximumConnections + h2PoolConfig.maximumConnections)
        let negotiator = AutomaticTlsNegotiator(
            HappyEyeballsConnector(resolver, transportFactory, attemptDelay: attemptDelay),
            handshaker, cache, limits, http2Limits, continueTimeout, pushConfig, resourceBudget
        )
        h1Factory = AutomaticHttp1Factory(negotiator)
        h2Factory = AutomaticHttp2Factory(negotiator)
    }

    public func execute(
        request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer(),
        connectionCancellation!: CancellationToken = CancellationToken.none()
    ): HttpResponse {
        if (request.url.scheme != "https") {
            throw IllegalArgumentException("automatic HTTPS client accepts only https URLs")
        }
        let key = automaticTlsPoolKey(request.url, handshaker)
        match (cache.get(key)) {
            case Some(CachedHttpProtocol.Http11) =>
                try {
                    executeHttp1(key, request, context, trailer)
                } catch (switched: Http2NegotiatedException) {
                    executeAdoptedHttp2(
                        key, switched.connection, switched.resourceLease, request,
                        negotiatedEventContext(context, switched.connectionId), trailer,
                        connectionCancellation
                    )
                }
            case _ =>
                try {
                    executeHttp2(key, request, context, trailer, connectionCancellation)
                } catch (fallback: Http11NegotiatedException) {
                    match (fallback.connection) {
                        case Some(connection) =>
                            executeAdoptedHttp1(
                                key, connection, fallback.resourceLease, request,
                                negotiatedEventContext(context, fallback.connectionId), trailer
                            )
                        case None => executeHttp1(key, request, context, trailer)
                    }
                }
        }
    }

    /** Negotiates a duplex exchange without replaying a committed handshake. */
    public func upgrade(
        http1Request: HttpRequest,
        http2Request: HttpRequest,
        protocol!: ?String = None<String>,
        context!: OperationContext = OperationContext.background(),
        connectionCancellation!: CancellationToken = CancellationToken.none()
    ): HttpDuplexExchangeResult {
        if (http1Request.url.scheme != "https" || http2Request.url.toString() != http1Request.url.toString()) {
            throw IllegalArgumentException("duplex protocol requests must share an HTTPS origin and target")
        }
        let key = automaticTlsPoolKey(http1Request.url, handshaker)
        match (cache.get(key)) {
            case Some(CachedHttpProtocol.Http11) =>
                try {
                    upgradeHttp1Claim(h1Pool.acquire(key, h1Factory, context: context), http1Request, context)
                } catch (switched: Http2NegotiatedException) {
                    let signal = Http2ClientExecutionSignal()
                    let lease = try {
                        h2Pool.adopt(
                            key, switched.connection, signal,
                            context: negotiatedEventContext(context, switched.connectionId), endStream: false,
                            resourceLease: switched.resourceLease
                        )
                    } catch (error: Exception) { switched.connection.close(); throw error }
                    upgradeHttp2Claim(lease, signal, http2Request, protocol, context, connectionCancellation)
                }
            case _ =>
                try {
                    let signal = Http2ClientExecutionSignal()
                    let lease = h2Pool.acquire(key, signal, h2Factory, context: context, endStream: false)
                    upgradeHttp2Claim(lease, signal, http2Request, protocol, context, connectionCancellation)
                } catch (fallback: Http11NegotiatedException) {
                    let lease = match (fallback.connection) {
                        case Some(connection) =>
                            try {
                                h1Pool.adopt(key, connection,
                                    context: negotiatedEventContext(context, fallback.connectionId),
                                    resourceLease: fallback.resourceLease)
                            }
                            catch (error: Exception) { connection.close(); throw error }
                        case None => h1Pool.acquire(key, h1Factory, context: context)
                    }
                    upgradeHttp1Claim(lease, http1Request, context)
                }
        }
    }

    private func upgradeHttp1Claim(
        lease: Http1PoolLease, request: HttpRequest, context: OperationContext
    ): HttpDuplexExchangeResult {
        try {
            let result = lease.connection.upgradeTracked(
                request, context: connectionEventContext(context, lease.connectionId), onTerminated: { reusable =>
                    if (reusable) { h1Pool.release(lease, context: context) }
                    else { h1Pool.discard(lease, context: context) }
                }
            )
            match (result) {
                case Http1UpgradeExchangeResult.Upgraded(_) => h1Pool.transfer(lease)
                case _ => ()
            }
            mapHttp1Upgrade(result)
        } catch (error: Exception) { h1Pool.discard(lease, context: context); throw error }
    }

    private func upgradeHttp2Claim(
        lease: Http2PoolLease,
        signal: Http2ClientExecutionSignal,
        request: HttpRequest,
        protocol: ?String,
        context: OperationContext,
        connectionCancellation: CancellationToken
    ): HttpDuplexExchangeResult {
        try {
            let executable = match (lease.connection) {
                case value: Http2ExecutableConnection => value
                case _ => throw IllegalStateException("HTTP/2 pool returned a non-executable connection")
            }
            mapHttp2Connect(executable.connectClaimed(
                request, protocol, lease.admission, signal, connectionEventContext(context, lease.connectionId), connectionCancellation,
                { => h2Pool.release(lease, context: context) }
            ))
        } catch (error: Exception) { h2Pool.release(lease, context: context); throw error }
    }

    public func observationSnapshot(): NetworkConnectionPoolSnapshot {
        h1Pool.observationSnapshot().combinedWith(h2Pool.observationSnapshot())
    }
    public func h1Snapshot(): Http1ConnectionPoolSnapshot { h1Pool.snapshot() }
    public func h2Snapshot(): Http2ConnectionPoolSnapshot { h2Pool.snapshot() }
    public func retire(): Unit { h2Pool.retire(); h1Pool.retire() }
    public func abortConnections(): Unit { h2Pool.close(); h1Pool.close() }

    public func close(): Unit { h2Pool.close(); h1Pool.close(); handshaker.close() }
    public func isClosed(): Bool { h1Pool.isClosed() && h2Pool.isClosed() }

    private func executeHttp2(
        key: HttpConnectionPoolKey,
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer,
        connectionCancellation: CancellationToken
    ): HttpResponse {
        let plan = mapHttp2ClientRequest(request, trailer: trailer, limits: limits, http2Limits: http2Limits)
        let signal = Http2ClientExecutionSignal()
        let lease = h2Pool.acquire(
            key, signal, h2Factory, context: context, endStream: plan.endStreamOnHeaders
        )
        let executable = match (lease.connection) {
            case value: Http2ExecutableConnection => value
            case _ =>
                h2Pool.release(lease, context: context)
                throw IllegalStateException("HTTP/2 pool returned a non-executable connection")
        }
        try {
            executable.executeClaimed(
                request, plan, lease.admission, signal, connectionEventContext(context, lease.connectionId), connectionCancellation,
                { => h2Pool.release(lease, context: context) }
            )
        } catch (error: Exception) {
            h2Pool.release(lease, context: context)
            throw error
        }
    }

    private func executeHttp1(
        key: HttpConnectionPoolKey,
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer
    ): HttpResponse {
        executeHttp1Lease(h1Pool.acquire(key, h1Factory, context: context), request, context, trailer)
    }

    private func executeAdoptedHttp2(
        key: HttpConnectionPoolKey,
        connection: Http2ClientPoolConnection,
        resourceLease: ?internal.HttpResourceLease,
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer,
        connectionCancellation: CancellationToken
    ): HttpResponse {
        let plan = mapHttp2ClientRequest(request, trailer: trailer, limits: limits, http2Limits: http2Limits)
        let signal = Http2ClientExecutionSignal()
        let lease = try {
            h2Pool.adopt(
                key, connection, signal, context: context, endStream: plan.endStreamOnHeaders,
                resourceLease: resourceLease
            )
        } catch (error: Exception) {
            connection.close()
            return executeHttp2(key, request, context, trailer, connectionCancellation)
        }
        try {
            connection.executeClaimed(
                request, plan, lease.admission, signal, connectionEventContext(context, lease.connectionId), connectionCancellation,
                { => h2Pool.release(lease, context: context) }
            )
        } catch (error: Exception) {
            h2Pool.release(lease, context: context)
            throw error
        }
    }

    private func executeAdoptedHttp1(
        key: HttpConnectionPoolKey,
        connection: Http1ClientConnection,
        resourceLease: ?internal.HttpResourceLease,
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer
    ): HttpResponse {
        let lease = try {
            h1Pool.adopt(key, connection, context: context, resourceLease: resourceLease)
        } catch (error: Exception) { connection.close(); throw error }
        executeHttp1Lease(lease, request, context, trailer)
    }

    private func executeHttp1Lease(
        lease: Http1PoolLease,
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer
    ): HttpResponse {
        try {
            lease.connection.executeTracked(
                request,
                context: connectionEventContext(context, lease.connectionId),
                trailer: trailer,
                onTerminated: { reusable =>
                    if (reusable) { h1Pool.release(lease, context: context) }
                    else { h1Pool.discard(lease, context: context) }
                }
            ).response
        } catch (error: Exception) {
            h1Pool.discard(lease, context: context)
            throw error
        }
    }
}

private class Http1TlsConnectionFactory <: Http1ConnectionFactory {
    private let connector: HappyEyeballsConnector
    private let handshaker: Http1TlsHandshaker
    private let limits: HttpLimits
    private let continueTimeout: Duration

    init(connector: HappyEyeballsConnector, handshaker: Http1TlsHandshaker,
        limits: HttpLimits, continueTimeout: Duration) {
        this.connector = connector
        this.handshaker = handshaker
        this.limits = limits
        this.continueTimeout = continueTimeout
    }

    public func create(key: HttpConnectionPoolKey, context: OperationContext,
        resourceLease: ?internal.HttpResourceLease): Http1ClientConnection {
        if (key.scheme != "https") { throw IllegalArgumentException("TLS factory requires https pool key") }
        let reference = httpOriginIdentity(key.originHost)
        let connected = connectHttpOrigin(connector, reference, key.originPort, context)
        try {
            let tls = handshaker.handshake(
                reference, connected,
                context.forStage(OperationTimeoutStage.TlsHandshake)
            )
            Http1ClientConnection(tls, limits: limits, continueTimeout: continueTimeout)
        } catch (error: Exception) {
            connected.abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        }
    }
}

private func tlsPoolKey(url: HttpUrl, handshaker: Http1TlsHandshaker): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", url.host, url.port, None<String>, "default",
        handshaker.tlsContextIdentity, handshaker.trustContextIdentity,
        handshaker.clientIdentity, handshaker.providerIdentity, handshaker.alpnPolicy
    )
}

private func automaticTlsPoolKey(
    url: HttpUrl,
    handshaker: HttpAlpnTlsHandshaker
): HttpConnectionPoolKey {
    HttpConnectionPoolKey(
        "https", url.host, url.port, None<String>, "default",
        handshaker.tlsContextIdentity, handshaker.trustContextIdentity,
        handshaker.clientIdentity, handshaker.providerIdentity, handshaker.alpnPolicy
    )
}

private func tlsProfileIdentity(value: TlsSecurityProfile): String {
    match (value) {
        case TlsSecurityProfile.Compatible => "compatible"
        case TlsSecurityProfile.Modern => "modern"
        case TlsSecurityProfile.StrictTls13 => "strict-tls13"
    }
}

private func tlsVersionIdentity(value: TlsVersion): String {
    match (value) { case TlsVersion.Tls12 => "1.2"; case TlsVersion.Tls13 => "1.3" }
}

private func joinHttpAlpn(values: Array<String>): String {
    if (values.isEmpty()) { return "http/1.1-fallback" }
    let result = ArrayList<Byte>()
    for ((index, value) in values.enumerate()) {
        if (index > 0) { result.add(b',') }
        for (byte in value.toArray()) { result.add(byte) }
    }
    String.fromUtf8(result.toArray())
}

private func isNegotiatedHttp11(value: HttpNegotiatedProtocol): Bool {
    match (value) { case HttpNegotiatedProtocol.Http11 => true; case _ => false }
}
