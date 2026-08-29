package wirestack.tls

import wirestack.internal.tls_engine as engine

/** Read-only provider and build identity retained by a completed handshake. */
public class TlsProviderInfo {
    public let id: String
    public let version: String
    public let buildFingerprint: String
    public let cryptoBackend: String
    public let securityPatchLevel: String

    internal init(value: engine.TlsProviderManifest) {
        id = value.providerId
        version = value.version
        buildFingerprint = value.fingerprint
        cryptoBackend = value.backend
        securityPatchLevel = value.patchLevel
    }
}

/** Provider-neutral immutable capability view. */
public class TlsCapabilities {
    private let value: engine.TlsCapabilities

    internal init(value: engine.TlsCapabilities) { this.value = value }

    public func supports(capability: TlsCapability): Bool {
        value.supports(capability)
    }
}

/** Immutable negotiated TLS facts retained before engine ownership transfers. */
public class TlsHandshakeInfo {
    public let version: TlsVersion
    public let cipherSuite: String
    public let negotiatedAlpn: ?String
    public let peerCertificateChain: ?CertificateChain
    public let verificationEvidence: ?TrustVerificationEvidence
    public let resumed: Bool
    public let provider: TlsProviderInfo
    public let requestedServerName: ?String

    internal init(value: engine.TlsHandshakeInfo) {
        version = value.version
        cipherSuite = value.cipherSuite
        negotiatedAlpn = value.negotiatedAlpn
        peerCertificateChain = value.peerCertificateChain
        verificationEvidence = value.verificationEvidence
        resumed = value.resumed
        provider = TlsProviderInfo(value.providerManifest)
        requestedServerName = value.requestedServerName
    }
}

/** Immutable, concurrently shareable Linux TLS client context. */
public class TlsClientContext {
    private let provider: engine.AwsLcTlsProvider
    private let value: engine.TlsClientContext
    public let capabilities: TlsCapabilities

    internal init(provider: engine.AwsLcTlsProvider, value: engine.TlsClientContext) {
        this.provider = provider
        this.value = value
        capabilities = TlsCapabilities(value.capabilities)
    }

    public static func builder(): TlsClientContextBuilder { TlsClientContextBuilder() }

    public prop securityProfile: TlsSecurityProfile { get() { value.security.profile } }
    public prop minimumVersion: TlsVersion { get() { value.security.minimumVersion } }
    public prop maximumVersion: TlsVersion { get() { value.security.maximumVersion } }
    public prop trust: TrustPolicy { get() { value.trust } }
    public func alpnProtocols(): Array<String> { value.alpnProtocols() }

    /** Uses one canonical DNS name for both SNI and reference-identity verification. */
    public func handshake(
        transport: DuplexTransport,
        serverName: HostName,
        context!: OperationContext = OperationContext.background()
    ): TlsConnection {
        handshake(
            transport,
            ReferenceIdentity.Dns(serverName),
            serverName: Some(serverName),
            context: context
        )
    }

    /**
     * Consumes `transport` and keeps SNI separate from the verified reference
     * identity. Engine creation failures and handshake failures abort it.
     */
    public func handshake(
        transport: DuplexTransport,
        referenceIdentity: ReferenceIdentity,
        serverName!: ?HostName = None<HostName>,
        context!: OperationContext = OperationContext.background()
    ): TlsConnection {
        let tlsEngine = try {
            provider.createClientEngine(value, referenceIdentity, serverName: serverName)
        } catch (error: Exception) {
            transport.abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        }
        let secured = engine.TlsConnection.handshake(tlsEngine, transport, context: context)
        TlsConnection(secured, provider)
    }
}

/** Mutable builder state never enters a built client context. */
public class TlsClientContextBuilder {
    private let provider: engine.AwsLcTlsProvider
    private let value: engine.TlsClientContextBuilder

    public init() {
        let selected = engine.AwsLcTlsProvider()
        provider = selected
        value = engine.TlsClientContext.builder(selected.manifest(), selected.linuxCapabilities())
    }

    public func securityProfile(profile: TlsSecurityProfile): TlsClientContextBuilder {
        let _ = value.securityProfile(profile)
        this
    }

    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsClientContextBuilder {
        let _ = value.versions(minimum, maximum)
        this
    }

    public func trust(policy: TrustPolicy): TlsClientContextBuilder {
        let _ = value.trust(policy)
        this
    }

    public func identity(identity: LocalIdentity): TlsClientContextBuilder {
        let _ = value.identity(identity.value)
        this
    }

    public func alpn(protocols: Array<String>): TlsClientContextBuilder {
        let _ = value.alpn(protocols)
        this
    }

    public func build(): TlsClientContext { TlsClientContext(provider, value.build()) }
}

/** Immutable, concurrently shareable Linux TLS server context. */
public class TlsServerContext {
    private let provider: engine.AwsLcTlsProvider
    private let value: engine.TlsServerContext
    public let capabilities: TlsCapabilities

    internal init(provider: engine.AwsLcTlsProvider, value: engine.TlsServerContext) {
        this.provider = provider
        this.value = value
        capabilities = TlsCapabilities(value.capabilities)
    }

    public static func builder(): TlsServerContextBuilder { TlsServerContextBuilder() }

    public prop securityProfile: TlsSecurityProfile { get() { value.security.profile } }
    public prop minimumVersion: TlsVersion { get() { value.security.minimumVersion } }
    public prop maximumVersion: TlsVersion { get() { value.security.maximumVersion } }
    public prop clientAuthentication: ClientAuthentication { get() { value.clientAuthentication } }
    public prop clientTrust: ?TrustPolicy { get() { value.clientTrust } }
    public func alpnProtocols(): Array<String> { value.alpnProtocols() }

    /** Consumes one accepted transport and returns its exclusively owned TLS connection. */
    public func handshake(
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): TlsConnection {
        let tlsEngine = try {
            provider.createServerEngine(value)
        } catch (error: Exception) {
            transport.abort(reason: Some(AbortReason.ProtocolFailure))
            throw error
        }
        let secured = engine.TlsConnection.handshake(tlsEngine, transport, context: context)
        TlsConnection(secured, provider)
    }
}

/** Mutable builder state never enters a built server context. */
public class TlsServerContextBuilder {
    private let provider: engine.AwsLcTlsProvider
    private let value: engine.TlsServerContextBuilder

    public init() {
        let selected = engine.AwsLcTlsProvider()
        provider = selected
        value = engine.TlsServerContext.builder(selected.manifest(), selected.linuxCapabilities())
    }

    public func securityProfile(profile: TlsSecurityProfile): TlsServerContextBuilder {
        let _ = value.securityProfile(profile)
        this
    }

    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsServerContextBuilder {
        let _ = value.versions(minimum, maximum)
        this
    }

    public func identity(identity: LocalIdentity): TlsServerContextBuilder {
        let _ = value.identity(identity.value)
        this
    }

    public func clientAuthentication(value: ClientAuthentication): TlsServerContextBuilder {
        let _ = this.value.clientAuthentication(value)
        this
    }

    public func clientTrust(policy: TrustPolicy): TlsServerContextBuilder {
        let _ = value.clientTrust(policy)
        this
    }

    public func alpn(protocols: Array<String>): TlsServerContextBuilder {
        let _ = value.alpn(protocols)
        this
    }

    public func build(): TlsServerContext { TlsServerContext(provider, value.build()) }
}

/** Public provider-neutral TLS stream that retains its provider for its lifetime. */
public class TlsConnection <: DuplexTransport {
    private let value: engine.TlsConnection
    private let provider: engine.AwsLcTlsProvider
    public let handshakeInfo: TlsHandshakeInfo

    internal init(value: engine.TlsConnection, provider: engine.AwsLcTlsProvider) {
        this.value = value
        this.provider = provider
        handshakeInfo = TlsHandshakeInfo(value.handshakeInfo.getOrThrow())
    }

    public prop info: TransportInfo { get() { value.info } }
    public prop state: TlsConnectionState { get() { value.state } }
    public prop closureEvidence: ?TlsClosureEvidence { get() { value.closureEvidence } }

    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult { value.readSome(destination, context: context) }

    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 { value.writeSome(source, context: context) }

    public func shutdown(direction: ShutdownDirection): Unit { value.shutdown(direction) }
    public func close(context: OperationContext): Unit { value.close(context) }
    public func close(): Unit { value.close() }
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { value.abort(reason: reason) }
    public func isClosed(): Bool { value.isClosed() }
}

/** TLS acceptor over a caller-owned provider-neutral transport listener. */
public class TlsListener <: Resource {
    private let listener: TransportListener
    private let context: TlsServerContext

    public init(listener: TransportListener, context: TlsServerContext) {
        this.listener = listener
        this.context = context
    }

    public func accept(
        context!: OperationContext = OperationContext.background()
    ): TlsConnection {
        let accepted = listener.accept(context)
        this.context.handshake(accepted, context: context)
    }

    public func close(): Unit { listener.close() }
    public func isClosed(): Bool { listener.isClosed() }
}
