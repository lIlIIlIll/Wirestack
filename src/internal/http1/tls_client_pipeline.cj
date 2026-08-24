package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.internal.http_model.*
import wirestack.internal.common.*
import wirestack.internal.connector.*
import wirestack.internal.resolver.*
import wirestack.internal.tls_engine.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

/** TLS policy/engine boundary retained in every HTTPS pool partition. */
public interface Http1TlsHandshaker <: Resource {
    prop tlsContextIdentity: String
    prop trustContextIdentity: String
    prop clientIdentity: String
    prop providerIdentity: String
    prop alpnPolicy: String
    func handshake(host: HostName, transport: DuplexTransport, context: OperationContext): DuplexTransport
}

/** Linux AWS-LC HTTPS handshaker. It owns its provider and closes it after every pooled connection. */
public class AwsLcHttp1TlsHandshaker <: Http1TlsHandshaker {
    private let provider: AwsLcTlsProvider
    private let context: TlsClientContext
    private let ownedPrivateKey: ?PrivateKeyRef
    private let mutex = Mutex()
    private var closed = false

    private init(provider: AwsLcTlsProvider, context: TlsClientContext,
        ownedPrivateKey: ?PrivateKeyRef) {
        this.provider = provider
        this.context = context
        this.ownedPrivateKey = ownedPrivateKey
    }

    public static func systemDefault(): AwsLcHttp1TlsHandshaker {
        create(TrustPolicy.system())
    }

    public static func create(
        trust: TrustPolicy,
        identity!: ?LocalIdentity = None<LocalIdentity>,
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): AwsLcHttp1TlsHandshaker {
        createOwned(trust, identity, None<PrivateKeyRef>, securityProfile)
    }

    /** Creates a handshaker that exclusively owns an optional DER client identity. */
    public static func createWithDer(
        customTrustRootsDer: Array<Array<Byte>>,
        clientCertificateChainDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        clientPrivateKeyPkcs8Der!: Array<Byte> = Array<Byte>(),
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): AwsLcHttp1TlsHandshaker {
        let roots = ArrayList<DerCertificate>()
        for (encoded in customTrustRootsDer) { roots.add(DerCertificate(encoded)) }
        let trust = TrustPolicy.customRoots(CertificateChain(roots.toArray()))
        if (clientCertificateChainDer.isEmpty() != clientPrivateKeyPkcs8Der.isEmpty()) {
            throw IllegalArgumentException(
                "HTTPS client certificate chain and PKCS#8 key must be configured together"
            )
        }
        if (clientCertificateChainDer.isEmpty()) {
            return createOwned(
                trust, None<LocalIdentity>, None<PrivateKeyRef>, securityProfile
            )
        }
        let certificates = ArrayList<DerCertificate>()
        for (encoded in clientCertificateChainDer) { certificates.add(DerCertificate(encoded)) }
        let key = PrivateKeyRef.pkcs8(clientPrivateKeyPkcs8Der)
        try {
            let identity = LocalIdentity(CertificateChain(certificates.toArray()), key)
            createOwned(trust, Some(identity), Some(key), securityProfile)
        } catch (error: Exception) {
            key.close()
            throw error
        }
    }

    private static func createOwned(
        trust: TrustPolicy,
        identity: ?LocalIdentity,
        ownedPrivateKey: ?PrivateKeyRef,
        securityProfile: TlsSecurityProfile
    ): AwsLcHttp1TlsHandshaker {
        let provider = AwsLcTlsProvider()
        try {
            let builder = TlsClientContext.builder(provider.manifest(), provider.linuxCapabilities())
                .securityProfile(securityProfile)
                .alpn(["http/1.1"])
            builder.trust(trust)
            if (let Some(value) <- identity) { builder.identity(value) }
            let context = builder.build()
            AwsLcHttp1TlsHandshaker(provider, context, ownedPrivateKey)
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
    public prop alpnPolicy: String { get() { joinHttp1Alpn(context.alpnProtocols()) } }

    public func handshake(host: HostName, transport: DuplexTransport,
        operation: OperationContext): DuplexTransport {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTPS handshaker is closed") }
        }
        emitTlsHandshakeEvent(operation, NetworkEventOutcome.Started, None<NetworkErrorCode>)
        try {
            let engine = provider.createClientEngine(
                context,
                ReferenceIdentity.Dns(host),
                serverName: Some(host)
            )
            let connection = TlsConnection.handshake(engine, transport, context: operation)
            match (connection.handshakeInfo) {
                case Some(info) => match (info.negotiatedAlpn) {
                    case Some(protocol) =>
                        if (protocol != "http/1.1") {
                            connection.abort(reason: Some(AbortReason.ProtocolFailure))
                            throw TlsEngineException(TlsEngineErrorCode.NoSharedAlpn,
                                "HTTPS HTTP/1 connection negotiated an unexpected ALPN protocol")
                        }
                    case None => () // RFC 7301 absence falls back to HTTP/1.1 for HTTPS.
                }
                case None =>
                    connection.abort(reason: Some(AbortReason.ProtocolFailure))
                    throw TlsEngineException(TlsEngineErrorCode.ProviderFailure,
                        "HTTPS handshake returned no negotiated TLS evidence")
            }
            emitTlsHandshakeEvent(operation, NetworkEventOutcome.Succeeded, None<NetworkErrorCode>)
            connection
        } catch (error: Exception) {
            let code = match (error) {
                case value: NetworkException => Some(value.code)
                case _ => Some(NetworkErrorCode.SystemFailure)
            }
            emitTlsHandshakeEvent(operation, NetworkEventOutcome.Failed, code)
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
        continueTimeout!: Duration = Duration.second
    ) {
        this.handshaker = handshaker
        pool = Http1ConnectionPool(config: poolConfig)
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

    public func create(key: HttpConnectionPoolKey, context: OperationContext): Http1ClientConnection {
        if (key.scheme != "https") { throw IllegalArgumentException("TLS factory requires https pool key") }
        let connected = connector.connect(HostName(key.originHost), key.originPort, context: context)
        try {
            let tls = handshaker.handshake(HostName(key.originHost), connected.transport, context)
            Http1ClientConnection(tls, limits: limits, continueTimeout: continueTimeout)
        } catch (error: Exception) {
            connected.transport.abort(reason: Some(AbortReason.ProtocolFailure))
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

private func joinHttp1Alpn(values: Array<String>): String {
    if (values.isEmpty()) { return "http/1.1-fallback" }
    let result = ArrayList<Byte>()
    for ((index, value) in values.enumerate()) {
        if (index > 0) { result.add(b',') }
        for (byte in value.toArray()) { result.add(byte) }
    }
    String.fromUtf8(result.toArray())
}
