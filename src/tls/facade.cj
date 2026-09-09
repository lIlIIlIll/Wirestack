package wirestack.tls

import wirestack.internal.tls_engine as engine

/** Read-only provider and build identity retained by a completed handshake. */
public class TlsProviderInfo {
/**
 * Wirestack 公开 API：id。
 */
    public let id: String
/**
 * Wirestack 公开 API：version。
 */
    public let version: String
/**
 * Wirestack 公开 API：buildFingerprint。
 */
    public let buildFingerprint: String
/**
 * Wirestack 公开 API：cryptoBackend。
 */
    public let cryptoBackend: String
/**
 * Wirestack 公开 API：securityPatchLevel。
 */
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

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param capability 调用方提供的输入值。
 */
    public func supports(capability: TlsCapability): Bool {
        value.supports(capability)
    }
}

/** Immutable negotiated TLS facts retained before engine ownership transfers. */
public class TlsHandshakeInfo {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let version: TlsVersion
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let cipherSuite: String
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let negotiatedAlpn: ?String
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let peerCertificateChain: ?CertificateChain
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let verificationEvidence: ?TrustVerificationEvidence
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let resumed: Bool
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let provider: TlsProviderInfo
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
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
    private let provider: engine.TlsProvider
    private let value: engine.TlsClientContext
/**
 * Wirestack 公开 API：capabilities。
 */
    public let capabilities: TlsCapabilities

    internal init(provider: engine.TlsProvider, value: engine.TlsClientContext) {
        this.provider = provider
        this.value = value
        capabilities = TlsCapabilities(value.capabilities)
    }

/**
 * Wirestack 公开 API：builder。
 */
    public static func builder(): TlsClientContextBuilder { TlsClientContextBuilder() }

/**
 * Wirestack 公开 API：securityProfile。
 */
    public prop securityProfile: TlsSecurityProfile { get() { value.security.profile } }
/**
 * Wirestack 公开 API：minimumVersion。
 */
    public prop minimumVersion: TlsVersion { get() { value.security.minimumVersion } }
/**
 * Wirestack 公开 API：maximumVersion。
 */
    public prop maximumVersion: TlsVersion { get() { value.security.maximumVersion } }
/**
 * Wirestack 公开 API：trust。
 */
    public prop trust: TrustPolicy { get() { value.trust } }
/**
 * Wirestack 公开 API：alpnProtocols。
 */
    public func alpnProtocols(): Array<String> { value.alpnProtocols() }

/**
 * Uses one canonical DNS name for both SNI and reference-identity verification.
 * @param context 参数 context。
 * @param serverName 参数 serverName。
 * @param transport 参数 transport。
 */
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
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param referenceIdentity 连接所期望的身份。
 * @param serverName 调用方提供的输入值。
 * @param transport 调用方提供的输入值。
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
    private let provider: engine.TlsProvider
    private let value: engine.TlsClientContextBuilder

/**
 * Wirestack 公开 API：init。
 */
    public init() {
        let selected = engine.selectedTlsProvider()
        provider = selected
        value = engine.TlsClientContext.builder(selected.manifest(), selected.capabilities())
    }

    internal init(factory: engine.TlsProviderFactory) {
        let selected = factory.create()
        provider = selected
        value = engine.TlsClientContext.builder(selected.manifest(), selected.capabilities())
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param profile 调用方提供的输入值。
 */
    public func securityProfile(profile: TlsSecurityProfile): TlsClientContextBuilder {
        let _ = value.securityProfile(profile)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param maximum 调用方提供的输入值。
 * @param minimum 调用方提供的输入值。
 */
    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsClientContextBuilder {
        let _ = value.versions(minimum, maximum)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param policy 调用方提供的输入值。
 */
    public func trust(policy: TrustPolicy): TlsClientContextBuilder {
        let _ = value.trust(policy)
        this
    }

/**
 * Wirestack 公开 API：identity。
 * @param identity 参数 identity。
 */
    public func identity(identity: LocalIdentity): TlsClientContextBuilder {
        let _ = value.identity(identity.value)
        this
    }

/**
 * Wirestack 公开 API：alpn。
 * @param protocols 参数 protocols。
 */
    public func alpn(protocols: Array<String>): TlsClientContextBuilder {
        let _ = value.alpn(protocols)
        this
    }

/**
 * Wirestack 公开 API：构造不可变结果并执行边界校验。
 */
    public func build(): TlsClientContext { TlsClientContext(provider, value.build()) }
}

/** Immutable, concurrently shareable Linux TLS server context. */
public class TlsServerContext {
    private let provider: engine.TlsProvider
    private let value: engine.TlsServerContext
/**
 * Wirestack 公开 API：capabilities。
 */
    public let capabilities: TlsCapabilities

    internal init(provider: engine.TlsProvider, value: engine.TlsServerContext) {
        this.provider = provider
        this.value = value
        capabilities = TlsCapabilities(value.capabilities)
    }

/**
 * Wirestack 公开 API：builder。
 */
    public static func builder(): TlsServerContextBuilder { TlsServerContextBuilder() }

/**
 * Wirestack 公开 API：securityProfile。
 */
    public prop securityProfile: TlsSecurityProfile { get() { value.security.profile } }
/**
 * Wirestack 公开 API：minimumVersion。
 */
    public prop minimumVersion: TlsVersion { get() { value.security.minimumVersion } }
/**
 * Wirestack 公开 API：maximumVersion。
 */
    public prop maximumVersion: TlsVersion { get() { value.security.maximumVersion } }
/**
 * Wirestack 公开 API：clientAuthentication。
 */
    public prop clientAuthentication: ClientAuthentication { get() { value.clientAuthentication } }
/**
 * Wirestack 公开 API：clientTrust。
 */
    public prop clientTrust: ?TrustPolicy { get() { value.clientTrust } }
/**
 * Wirestack 公开 API：alpnProtocols。
 */
    public func alpnProtocols(): Array<String> { value.alpnProtocols() }

/**
 * Consumes one accepted transport and returns its exclusively owned TLS connection.
 * @param context 参数 context。
 * @param transport 参数 transport。
 */
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
    private let provider: engine.TlsProvider
    private let value: engine.TlsServerContextBuilder

/**
 * Wirestack 公开 API：init。
 */
    public init() {
        let selected = engine.selectedTlsProvider()
        provider = selected
        value = engine.TlsServerContext.builder(selected.manifest(), selected.capabilities())
    }

    internal init(factory: engine.TlsProviderFactory) {
        let selected = factory.create()
        provider = selected
        value = engine.TlsServerContext.builder(selected.manifest(), selected.capabilities())
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param profile 调用方提供的输入值。
 */
    public func securityProfile(profile: TlsSecurityProfile): TlsServerContextBuilder {
        let _ = value.securityProfile(profile)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param maximum 调用方提供的输入值。
 * @param minimum 调用方提供的输入值。
 */
    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsServerContextBuilder {
        let _ = value.versions(minimum, maximum)
        this
    }

/**
 * Wirestack 公开 API：identity。
 * @param identity 参数 identity。
 */
    public func identity(identity: LocalIdentity): TlsServerContextBuilder {
        let _ = value.identity(identity.value)
        this
    }

/**
 * Wirestack 公开 API：clientAuthentication。
 * @param value 参数 value。
 */
    public func clientAuthentication(value: ClientAuthentication): TlsServerContextBuilder {
        let _ = this.value.clientAuthentication(value)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param policy 调用方提供的输入值。
 */
    public func clientTrust(policy: TrustPolicy): TlsServerContextBuilder {
        let _ = value.clientTrust(policy)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param protocols 调用方提供的输入值。
 */
    public func alpn(protocols: Array<String>): TlsServerContextBuilder {
        let _ = value.alpn(protocols)
        this
    }

/**
 * Wirestack 公开 API：构造不可变结果并执行边界校验。
 */
    public func build(): TlsServerContext { TlsServerContext(provider, value.build()) }
}

/** Public provider-neutral TLS stream that retains its provider for its lifetime. */
public class TlsConnection <: DuplexTransport {
    private let value: engine.TlsConnection
    private let provider: engine.TlsProvider
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let handshakeInfo: TlsHandshakeInfo

    internal init(value: engine.TlsConnection, provider: engine.TlsProvider) {
        this.value = value
        this.provider = provider
        handshakeInfo = TlsHandshakeInfo(value.handshakeInfo.getOrThrow())
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop info: TransportInfo { get() { value.info } }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop state: TlsConnectionState { get() { value.state } }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop closureEvidence: ?TlsClosureEvidence { get() { value.closureEvidence } }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param destination 调用方提供的输入值。
 */
    public func readSome(
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult { value.readSome(destination, context: context) }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param source 调用方提供的输入值。
 */
    public func writeSome(
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 { value.writeSome(source, context: context) }

/**
 * Wirestack 公开 API：请求服务有序停止并返回停止状态。
 * @param direction 调用方提供的输入值。
 */
    public func shutdown(direction: ShutdownDirection): Unit { value.shutdown(direction) }
/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 */
    public func close(context: OperationContext): Unit { value.close(context) }
/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit { value.close() }
/**
 * Wirestack 公开 API：立即中止资源并释放底层状态。
 * @param reason 描述终止原因的稳定值。
 */
    public func abort(reason!: ?AbortReason = None<AbortReason>): Unit { value.abort(reason: reason) }
/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { value.isClosed() }
}

/** TLS acceptor over a caller-owned provider-neutral transport listener. */
public class TlsListener <: Resource {
    private let listener: TransportListener
    private let context: TlsServerContext

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param listener 调用方提供的输入值。
 */
    public init(listener: TransportListener, context: TlsServerContext) {
        this.listener = listener
        this.context = context
    }

/**
 * Wirestack 公开 API：接受一个待处理连接。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 */
    public func accept(
        context!: OperationContext = OperationContext.background()
    ): TlsConnection {
        let accepted = listener.accept(context)
        this.context.handshake(accepted, context: context)
    }

/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit { listener.close() }
/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { listener.isClosed() }
}
