package wirestack.internal.tls_engine

import std.sync.*
import wirestack.internal.common.*
import wirestack.internal.platform.linux.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private let ENGINE_CLIENT: Int32 = 0
private let ENGINE_SERVER: Int32 = 1
private let ENGINE_COMPLETE: Int32 = 0
private let ENGINE_WANT_READ: Int32 = 1
private let ENGINE_WANT_WRITE: Int32 = 2
private let ENGINE_NEED_SIGNATURE: Int32 = 3
private let ENGINE_NEED_SERVER_SELECTION: Int32 = 4
private let ENGINE_IO_COMPLETE: Int32 = 0
private let ENGINE_IO_WANT_READ: Int32 = 1
private let ENGINE_IO_WANT_WRITE: Int32 = 2
private let ENGINE_IO_CLOSED: Int32 = 3
private let ENGINE_IO_SHUTDOWN_SENT: Int32 = 4
private let NATIVE_OK: Int32 = 0
private let MAX_SIGNED_INT64: UInt64 = 0x7fffffffffffffffu64

foreign func wirestack_tls_engine_create(
    providerHandle: UInt64,
    role: Int32,
    minimumTlsVersion: Int32,
    maximumTlsVersion: Int32,
    outEngineHandle: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_destroy(engineHandle: UInt64): Unit
foreign func wirestack_tls_engine_add_trust_anchor_der(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64
): Int32
foreign func wirestack_tls_engine_add_spki_sha256_pin(
    engineHandle: UInt64,
    digest: CPointer<UInt8>,
    scope: Int32
): Int32
foreign func wirestack_tls_engine_load_verify_bundle(
    engineHandle: UInt64,
    certificateBundle: CString
): Int32
foreign func wirestack_tls_engine_load_verify_directory(
    engineHandle: UInt64,
    hashedCertificateDirectory: CString
): Int32
foreign func wirestack_tls_engine_set_server_name(
    engineHandle: UInt64,
    serverName: CString
): Int32
foreign func wirestack_tls_engine_set_dns_reference_identity(
    engineHandle: UInt64,
    dnsName: CString
): Int32
foreign func wirestack_tls_engine_set_ip_reference_identity(
    engineHandle: UInt64,
    address: CPointer<UInt8>,
    size: UInt64
): Int32
foreign func wirestack_tls_engine_enable_peer_verification(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_configure_client_authentication(
    engineHandle: UInt64,
    required: Int32
): Int32
foreign func wirestack_tls_engine_set_alpn_protocols(
    engineHandle: UInt64,
    protocols: CPointer<UInt8>,
    protocolsSize: UInt64
): Int32
foreign func wirestack_tls_engine_set_protocol_versions(
    engineHandle: UInt64,
    minimumTlsVersion: Int32,
    maximumTlsVersion: Int32
): Int32
foreign func wirestack_tls_engine_set_session_id_context(
    engineHandle: UInt64,
    context: CPointer<UInt8>,
    contextSize: UInt64
): Int32
foreign func wirestack_tls_engine_offer_session(
    engineHandle: UInt64,
    session: CPointer<UInt8>,
    sessionSize: UInt64
): Int32
foreign func wirestack_tls_engine_pending_session(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outRequiredSize: CPointer<UInt64>,
    outLifetimeSeconds: CPointer<UInt64>,
    outSingleUse: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_enable_server_name_selection(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_server_name_selection_request(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outRequiredSize: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_complete_server_name_selection(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_fail_server_name_selection(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_set_identity_pkcs8(
    engineHandle: UInt64,
    leafCertificate: CPointer<UInt8>,
    leafCertificateSize: UInt64,
    privateKey: CPointer<UInt8>,
    privateKeySize: UInt64
): Int32
foreign func wirestack_tls_engine_add_identity_chain_certificate_der(
    engineHandle: UInt64,
    certificate: CPointer<UInt8>,
    certificateSize: UInt64
): Int32
foreign func wirestack_tls_engine_set_external_signer(
    engineHandle: UInt64,
    leafCertificate: CPointer<UInt8>,
    leafCertificateSize: UInt64,
    signatureAlgorithms: CPointer<UInt16>,
    signatureAlgorithmCount: UInt64
): Int32
foreign func wirestack_tls_engine_external_signature_request(
    engineHandle: UInt64,
    outSignatureAlgorithm: CPointer<UInt16>,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outRequiredSize: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_complete_external_signature(
    engineHandle: UInt64,
    signature: CPointer<UInt8>,
    signatureSize: UInt64
): Int32
foreign func wirestack_tls_engine_fail_external_signature(engineHandle: UInt64): Int32
foreign func wirestack_tls_engine_handshake_step(
    engineHandle: UInt64,
    outStep: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_last_error(
    engineHandle: UInt64,
    outErrorClass: CPointer<Int32>,
    outNativeReason: CPointer<Int64>,
    outVerifyResult: CPointer<Int64>,
    outPeerAlert: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_handshake_info(
    engineHandle: UInt64,
    outTlsVersion: CPointer<Int32>,
    cipherName: CPointer<UInt8>,
    cipherNameCapacity: UInt64,
    outCipherNameSize: CPointer<UInt64>,
    negotiatedAlpn: CPointer<UInt8>,
    negotiatedAlpnCapacity: UInt64,
    outNegotiatedAlpnSize: CPointer<UInt64>,
    outSessionReused: CPointer<Int32>,
    outMatchedPinIndex: CPointer<Int64>
): Int32
foreign func wirestack_tls_engine_peer_chain_der(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    outputCapacity: UInt64,
    outRequiredSize: CPointer<UInt64>,
    outCertificateCount: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_pending_ciphertext(
    engineHandle: UInt64,
    outSize: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_drain_ciphertext(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    size: UInt64,
    outRead: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_feed_ciphertext(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64,
    outWritten: CPointer<UInt64>
): Int32
foreign func wirestack_tls_engine_read_plaintext(
    engineHandle: UInt64,
    output: CPointer<UInt8>,
    size: UInt64,
    outRead: CPointer<UInt64>,
    outStep: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_write_plaintext(
    engineHandle: UInt64,
    input: CPointer<UInt8>,
    size: UInt64,
    outWritten: CPointer<UInt64>,
    outStep: CPointer<Int32>
): Int32
foreign func wirestack_tls_engine_shutdown_step(
    engineHandle: UInt64,
    outStep: CPointer<Int32>
): Int32

public enum TlsEngineRole {
    | Client
    | Server
}

public enum TlsEngineStep {
    | Complete
    | WantRead
    | WantWrite
    | NeedSignature
    | NeedServerSelection
}

public enum TlsEngineReadResult {
    | Data(Int64)
    | WantRead
    | WantWrite
    | PeerClosed
}

public enum TlsEngineWriteResult {
    | Consumed(Int64)
    | WantRead
    | WantWrite
    | PeerClosed
}

public enum TlsEngineShutdownResult {
    | Complete
    | Sent
    | WantRead
    | WantWrite
}

/** Provider-neutral external-I/O TLS state machine. */
public interface TlsEngine <: Resource {
    func handshakeStep(): TlsEngineStep
    func pendingCiphertext(): Int64
    func drainCiphertext(destination: MutableByteSpan): Int64
    func feedCiphertext(source: ByteSpan): Int64
    func readPlaintext(destination: MutableByteSpan): TlsEngineReadResult
    func writePlaintext(source: ByteSpan): TlsEngineWriteResult
    func shutdownStep(): TlsEngineShutdownResult
    func close(): Unit
}

/** Optional engine facet used only when a local identity delegates signing. */
public interface ExternalSigningTlsEngine {
    func serviceExternalSignature(context: OperationContext): Unit
}

/** Optional provider-neutral handshake result facet. */
public interface HandshakeInfoTlsEngine {
    func handshakeInfo(): TlsHandshakeInfo
}

/** Optional engine facet used for asynchronous SNI context selection. */
public interface ServerNameSelectingTlsEngine {
    func serviceServerNameSelection(context: OperationContext): Unit
}

/** Immutable negotiated TLS facts. No provider-native object is retained. */
public class TlsHandshakeInfo {
    public let version: TlsVersion
    public let cipherSuite: String
    public let negotiatedAlpn: ?String
    public let peerCertificateChain: ?CertificateChain
    public let verificationEvidence: ?TrustVerificationEvidence
    public let resumed: Bool
    public let providerManifest: TlsProviderManifest
    public let requestedServerName: ?String

    public init(
        version: TlsVersion,
        cipherSuite: String,
        negotiatedAlpn: ?String,
        peerCertificateChain: ?CertificateChain,
        verificationEvidence: ?TrustVerificationEvidence,
        resumed: Bool,
        providerManifest: TlsProviderManifest,
        requestedServerName!: ?String = None<String>
    ) {
        if (cipherSuite.isEmpty()) {
            throw IllegalArgumentException("TLS cipher suite must not be empty")
        }
        this.version = version
        this.cipherSuite = cipherSuite
        this.negotiatedAlpn = negotiatedAlpn
        this.peerCertificateChain = peerCertificateChain
        this.verificationEvidence = verificationEvidence
        this.resumed = resumed
        this.providerManifest = providerManifest
        this.requestedServerName = requestedServerName
    }
}

public enum TlsEngineErrorCode {
    | ProtocolViolation
    | UnsupportedVersion
    | NoSharedCipher
    | NoSharedAlpn
    | CertificateUntrusted
    | IdentityMismatch
    | CertificateExpired
    | CertificateRevoked
    | ClientCertificateRequired
    | HandshakeTimeout
    | HandshakeCancelled
    | PeerAlert
    | PeerClosedWithoutCloseNotify
    | InvalidRecord
    | BadMac
    | SessionFailure
    | ProviderFailure
    | UnsupportedCapability
    | Closed
    | NoProgress
    | UnexpectedTransportEof
    | PrivateKeyFailure
    | ServerNameSelectionFailure
}

/** Stable TLS-pump failure without provider-native types or secret material. */
public class TlsEngineException <: NetworkException {
    public let tlsCode: TlsEngineErrorCode
    /** X.509 verification result, when certificate verification failed. */
    public let verificationCode: ?Int64
    /** TLS alert description received from the peer, without provider text. */
    public let peerAlert: ?Int32

    public init(
        code: TlsEngineErrorCode,
        message: String,
        phase!: NetworkPhase = NetworkPhase.TlsHandshake,
        nativeCode!: ?Int64 = None<Int64>,
        verificationCode!: ?Int64 = None<Int64>,
        peerAlert!: ?Int32 = None<Int32>,
        cause!: ?Exception = None<Exception>
    ) {
        super(
            match (code) {
                case TlsEngineErrorCode.HandshakeCancelled => NetworkErrorCategory.Cancelled
                case TlsEngineErrorCode.HandshakeTimeout => NetworkErrorCategory.DeadlineExceeded
                case _ => NetworkErrorCategory.System
            },
            phase,
            match (code) {
                case TlsEngineErrorCode.Closed => NetworkErrorCode.Closed
                case TlsEngineErrorCode.UnexpectedTransportEof => NetworkErrorCode.UnexpectedEof
                case TlsEngineErrorCode.PeerClosedWithoutCloseNotify => NetworkErrorCode.UnexpectedEof
                case TlsEngineErrorCode.HandshakeTimeout => NetworkErrorCode.TimedOut
                case TlsEngineErrorCode.HandshakeCancelled => NetworkErrorCode.Cancelled
                case TlsEngineErrorCode.UnsupportedCapability => NetworkErrorCode.Unsupported
                case _ => NetworkErrorCode.SystemFailure
            },
            message,
            retryability: match (code) {
                case TlsEngineErrorCode.HandshakeTimeout => Retryability.SafeBeforeWrite
                case TlsEngineErrorCode.HandshakeCancelled => Retryability.Never
                case TlsEngineErrorCode.ProviderFailure => Retryability.Unknown
                case _ => Retryability.Never
            },
            nativeCode: nativeCode,
            cause: cause
        )
        tlsCode = code
        this.verificationCode = verificationCode
        this.peerAlert = peerAlert
    }

    protected override func getClassName(): String { "TlsEngineException" }
}

private func nativeRole(role: TlsEngineRole): Int32 {
    match (role) {
        case TlsEngineRole.Client => ENGINE_CLIENT
        case TlsEngineRole.Server => ENGINE_SERVER
    }
}

private func providerFailure(operation: String, status: Int32): TlsEngineException {
    TlsEngineException(
        TlsEngineErrorCode.ProviderFailure,
        "TLS provider ${operation} failed: ${status}"
    )
}

private func decodeNativeTlsError(value: Int32): TlsEngineErrorCode {
    if (value == 1) { TlsEngineErrorCode.ProtocolViolation }
    else if (value == 2) { TlsEngineErrorCode.UnsupportedVersion }
    else if (value == 3) { TlsEngineErrorCode.NoSharedCipher }
    else if (value == 4) { TlsEngineErrorCode.NoSharedAlpn }
    else if (value == 5) { TlsEngineErrorCode.CertificateUntrusted }
    else if (value == 6) { TlsEngineErrorCode.IdentityMismatch }
    else if (value == 7) { TlsEngineErrorCode.CertificateExpired }
    else if (value == 8) { TlsEngineErrorCode.CertificateRevoked }
    else if (value == 9) { TlsEngineErrorCode.ClientCertificateRequired }
    else if (value == 10) { TlsEngineErrorCode.PrivateKeyFailure }
    else if (value == 11) { TlsEngineErrorCode.PeerAlert }
    else if (value == 12) { TlsEngineErrorCode.InvalidRecord }
    else if (value == 13) { TlsEngineErrorCode.BadMac }
    else if (value == 14) { TlsEngineErrorCode.SessionFailure }
    else { TlsEngineErrorCode.ProviderFailure }
}

private func engineFailure(
    engineHandle: UInt64,
    operation: String,
    status: Int32,
    phase: NetworkPhase
): TlsEngineException {
    let errorClass = Array<Int32>(1, repeat: 0)
    let nativeReason = Array<Int64>(1, repeat: 0)
    let verifyResult = Array<Int64>(1, repeat: 0)
    let peerAlert = Array<Int32>(1, repeat: -1)
    let queryStatus = unsafe {
        let errorRaw = acquireArrayRawData(errorClass)
        let nativeRaw = acquireArrayRawData(nativeReason)
        let verifyRaw = acquireArrayRawData(verifyResult)
        let alertRaw = acquireArrayRawData(peerAlert)
        try {
            wirestack_tls_engine_last_error(
                engineHandle,
                errorRaw.pointer,
                nativeRaw.pointer,
                verifyRaw.pointer,
                alertRaw.pointer
            )
        } finally {
            releaseArrayRawData(alertRaw)
            releaseArrayRawData(verifyRaw)
            releaseArrayRawData(nativeRaw)
            releaseArrayRawData(errorRaw)
        }
    }
    if (queryStatus != NATIVE_OK) {
        return TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider ${operation} failed: ${status}",
            phase: phase
        )
    }
    let code = decodeNativeTlsError(errorClass[0])
    TlsEngineException(
        code,
        "TLS ${operation} failed",
        phase: phase,
        nativeCode: if (nativeReason[0] == 0) { None<Int64> } else { Some(nativeReason[0]) },
        verificationCode: if (verifyResult[0] == 0) { None<Int64> } else { Some(verifyResult[0]) },
        peerAlert: if (peerAlert[0] < 0) { None<Int32> } else { Some(peerAlert[0]) }
    )
}

/** AWS-LC memory-BIO engine. It never owns or accesses a socket. */
public class AwsLcTlsEngine <: TlsEngine & ExternalSigningTlsEngine &
    HandshakeInfoTlsEngine & ServerNameSelectingTlsEngine {
    private let mutex = Mutex()
    private var handle: UInt64
    private var externalSigner: ?ExternalSigner = None<ExternalSigner>
    private let role: TlsEngineRole
    private let providerManifest: TlsProviderManifest
    private var configuredTrust: ?TrustPolicy = None<TrustPolicy>
    private var verifiedReferenceIdentity: ?String = None<String>
    private var serverContextSelector: ?TlsServerContextSelector = None<TlsServerContextSelector>
    private var requestedServerName: ?String = None<String>
    private var sessionStore: ?TlsSessionStore = None<TlsSessionStore>
    private var sessionKey: ?TlsSessionKey = None<TlsSessionKey>

    internal init(
        providerHandle: UInt64,
        role: TlsEngineRole,
        security: TlsSecurityPolicy,
        providerManifest: TlsProviderManifest
    ) {
        this.role = role
        this.providerManifest = providerManifest
        let output = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let raw = acquireArrayRawData(output)
            try {
                wirestack_tls_engine_create(
                    providerHandle,
                    nativeRole(role),
                    Int32(tlsVersionNumber(security.minimumVersion)),
                    Int32(tlsVersionNumber(security.maximumVersion)),
                    raw.pointer
                )
            } finally {
                releaseArrayRawData(raw)
            }
        }
        if (status != NATIVE_OK || output[0] == 0u64) {
            throw providerFailure("engine creation", status)
        }
        handle = output[0]
    }

    internal func configureClientAuthentication(
        trust: TrustPolicy,
        referenceIdentity: ReferenceIdentity,
        serverName: ?HostName,
        systemTrustLocation: ?LinuxSystemTrustLocation
    ): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            configureTrust(current, trust, systemTrustLocation)
            if (let Some(name) <- serverName) {
                withCString(name.ascii, {value =>
                    requireConfigurationSuccess(
                        "SNI server name",
                        unsafe { wirestack_tls_engine_set_server_name(current, value) }
                    )
                })
            }
            match (referenceIdentity) {
                case ReferenceIdentity.Dns(host) =>
                    withCString(host.ascii, {value =>
                        requireConfigurationSuccess(
                            "DNS reference identity",
                            unsafe {
                                wirestack_tls_engine_set_dns_reference_identity(current, value)
                            }
                        )
                    })
                case ReferenceIdentity.Ip(address) =>
                    if (address.zone.isSome()) {
                        throw TlsEngineException(
                            TlsEngineErrorCode.ProviderFailure,
                            "TLS IP reference identity cannot contain a zone"
                        )
                    }
                    let octets = address.toOctets()
                    let status = unsafe {
                        let input = acquireArrayRawData(octets)
                        try {
                            wirestack_tls_engine_set_ip_reference_identity(
                                current,
                                input.pointer,
                                UInt64(octets.size)
                            )
                        } finally {
                            releaseArrayRawData(input)
                        }
                    }
                    requireConfigurationSuccess("IP reference identity", status)
            }
            requireConfigurationSuccess(
                "peer verification",
                unsafe { wirestack_tls_engine_enable_peer_verification(current) }
            )
            configuredTrust = Some(trust)
            verifiedReferenceIdentity = Some(referenceIdentityText(referenceIdentity))
        }
    }

    internal func configureSessionStore(store: TlsSessionStore, key: TlsSessionKey): Unit {
        let offered = store.take(key)
        synchronized(mutex) {
            let current = requireOpen()
            if (let Some(encoded) <- offered) {
                let status = unsafe {
                    let input = acquireArrayRawData(encoded)
                    try {
                        wirestack_tls_engine_offer_session(
                            current,
                            input.pointer,
                            UInt64(encoded.size)
                        )
                    } finally {
                        releaseArrayRawData(input)
                    }
                }
                for (index in 0..encoded.size) { encoded[index] = 0 }
                requireConfigurationSuccess("cached TLS session", status)
            }
            sessionStore = Some(store)
            sessionKey = Some(key)
        }
    }

    internal func configureServerSessionIdContext(context: Array<Byte>): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            let status = unsafe {
                let input = acquireArrayRawData(context)
                try {
                    wirestack_tls_engine_set_session_id_context(
                        current,
                        input.pointer,
                        UInt64(context.size)
                    )
                } finally {
                    releaseArrayRawData(input)
                }
            }
            requireConfigurationSuccess("server session partition", status)
        }
    }

    internal func configureServerNameSelection(selector: TlsServerContextSelector): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            requireConfigurationSuccess(
                "SNI context selection",
                unsafe { wirestack_tls_engine_enable_server_name_selection(current) }
            )
            serverContextSelector = Some(selector)
        }
    }

    internal func configureAlpn(protocols: Array<String>): Unit {
        if (protocols.isEmpty()) {
            return
        }
        let wire = encodeAlpnProtocols(protocols)
        synchronized(mutex) {
            let current = requireOpen()
            let status = unsafe {
                let input = acquireArrayRawData(wire)
                try {
                    wirestack_tls_engine_set_alpn_protocols(
                        current,
                        input.pointer,
                        UInt64(wire.size)
                    )
                } finally {
                    releaseArrayRawData(input)
                }
            }
            requireConfigurationSuccess("ALPN protocol list", status)
        }
    }

    internal func configureClientAuthentication(
        authentication: ClientAuthentication,
        trust: ?TrustPolicy,
        systemTrustLocation: ?LinuxSystemTrustLocation
    ): Unit {
        match (authentication) {
            case ClientAuthentication.None => return
            case _ => ()
        }
        let resolvedTrust = match (trust) {
            case Some(value) => value
            case None => throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "TLS server client authentication has no trust policy"
            )
        }
        synchronized(mutex) {
            let current = requireOpen()
            configureTrust(current, resolvedTrust, systemTrustLocation)
            let required: Int32 = match (authentication) {
                case ClientAuthentication.Required => 1i32
                case _ => 0i32
            }
            requireConfigurationSuccess(
                "client certificate authentication",
                unsafe {
                    wirestack_tls_engine_configure_client_authentication(current, required)
                }
            )
            configuredTrust = Some(resolvedTrust)
        }
    }

    internal func configureLocalIdentity(identity: LocalIdentity): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            let certificates = identity.certificateChain.certificates()
            let leaf = certificates[0].derBytes()
            match (identity.privateKeyRef.kind) {
                case PrivateKeyKind.Pkcs8 => identity.privateKeyRef.withPkcs8({key =>
                    let status = unsafe {
                        let certificateInput = acquireArrayRawData(leaf)
                        let keyInput = acquireArrayRawData(key)
                        try {
                            wirestack_tls_engine_set_identity_pkcs8(
                                current,
                                certificateInput.pointer,
                                UInt64(leaf.size),
                                keyInput.pointer,
                                UInt64(key.size)
                            )
                        } finally {
                            releaseArrayRawData(keyInput)
                            releaseArrayRawData(certificateInput)
                        }
                    }
                    requireConfigurationSuccess("local PKCS#8 identity", status)
                })
                case _ =>
                    let configuredAlgorithms = identity.privateKeyRef.signatureAlgorithms()
                    let nativeAlgorithms = Array<UInt16>(
                        configuredAlgorithms.size,
                        {index => nativeSignatureAlgorithm(configuredAlgorithms[index])}
                    )
                    let status = unsafe {
                        let certificateInput = acquireArrayRawData(leaf)
                        let algorithmInput = acquireArrayRawData(nativeAlgorithms)
                        try {
                            wirestack_tls_engine_set_external_signer(
                                current,
                                certificateInput.pointer,
                                UInt64(leaf.size),
                                algorithmInput.pointer,
                                UInt64(nativeAlgorithms.size)
                            )
                        } finally {
                            releaseArrayRawData(algorithmInput)
                            releaseArrayRawData(certificateInput)
                        }
                    }
                    requireConfigurationSuccess("external signer identity", status)
                    externalSigner = Some(identity.privateKeyRef.externalSignerReference())
            }
            for (index in 1..certificates.size) {
                let der = certificates[index].derBytes()
                let status = unsafe {
                    let input = acquireArrayRawData(der)
                    try {
                        wirestack_tls_engine_add_identity_chain_certificate_der(
                            current,
                            input.pointer,
                            UInt64(der.size)
                        )
                    } finally {
                        releaseArrayRawData(input)
                    }
                }
                requireConfigurationSuccess("local identity chain certificate", status)
            }
        }
    }

    public func handshakeStep(): TlsEngineStep {
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let raw = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_handshake_step(current, raw.pointer)
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != NATIVE_OK) {
                throw engineFailure(current, "handshake step", status, NetworkPhase.TlsHandshake)
            }
            capturePendingSession(current)
            let value = output[0]
            if (value == ENGINE_COMPLETE) {
                TlsEngineStep.Complete
            } else if (value == ENGINE_WANT_READ) {
                TlsEngineStep.WantRead
            } else if (value == ENGINE_WANT_WRITE) {
                TlsEngineStep.WantWrite
            } else if (value == ENGINE_NEED_SIGNATURE) {
                TlsEngineStep.NeedSignature
            } else if (value == ENGINE_NEED_SERVER_SELECTION) {
                TlsEngineStep.NeedServerSelection
            } else {
                throw providerFailure("handshake step result", value)
            }
        }
    }

    public func serviceServerNameSelection(context: OperationContext): Unit {
        try {
            checkTlsOperationContext(context)
        } catch (error: NetworkException) {
            failPendingServerNameSelection()
            throw error
        }
        let selectionInput = synchronized(mutex) {
            let current = requireOpen()
            let selector = match (serverContextSelector) {
                case Some(value) => value
                case None => throw TlsEngineException(
                    TlsEngineErrorCode.ServerNameSelectionFailure,
                    "TLS engine requested SNI selection without a selector"
                )
            }
            let sizeOutput = Array<UInt64>(1, repeat: 0u64)
            let queryStatus = unsafe {
                let size = acquireArrayRawData(sizeOutput)
                try {
                    wirestack_tls_engine_server_name_selection_request(
                        current,
                        CPointer<UInt8>(),
                        0u64,
                        size.pointer
                    )
                } finally {
                    releaseArrayRawData(size)
                }
            }
            if (queryStatus != NATIVE_OK || sizeOutput[0] > 253u64) {
                throw providerFailure("SNI selection request", queryStatus)
            }
            let storageSize = if (sizeOutput[0] == 0u64) { 1 } else { Int64(sizeOutput[0]) }
            let encoded = Array<Byte>(storageSize, repeat: 0)
            if (sizeOutput[0] != 0u64) {
                let readStatus = unsafe {
                    let output = acquireArrayRawData(encoded)
                    let size = acquireArrayRawData(sizeOutput)
                    try {
                        wirestack_tls_engine_server_name_selection_request(
                            current,
                            output.pointer,
                            UInt64(encoded.size),
                            size.pointer
                        )
                    } finally {
                        releaseArrayRawData(size)
                        releaseArrayRawData(output)
                    }
                }
                requireConfigurationSuccess("SNI selection request", readStatus)
            }
            let name = if (sizeOutput[0] == 0u64) {
                None<String>
            } else {
                Some(String.fromUtf8(Array<Byte>(
                    Int64(sizeOutput[0]),
                    {index => encoded[index]}
                )))
            }
            (selector, name)
        }
        let selectedContext = try {
            selectionInput[0].select(selectionInput[1])
        } catch (error: TlsServerNameSelectionException) {
            failPendingServerNameSelection()
            throw TlsEngineException(
                TlsEngineErrorCode.ServerNameSelectionFailure,
                "TLS server name selection failed",
                cause: Some(error)
            )
        }
        try {
            checkTlsOperationContext(context)
            configureSelectedServerContext(selectedContext)
            synchronized(mutex) {
                let current = requireOpen()
                requireConfigurationSuccess(
                    "SNI selection completion",
                    unsafe { wirestack_tls_engine_complete_server_name_selection(current) }
                )
                requestedServerName = selectionInput[1]
            }
        } catch (error: Exception) {
            failPendingServerNameSelection()
            throw error
        }
    }

    private func configureSelectedServerContext(context: TlsServerContext): Unit {
        synchronized(mutex) {
            let current = requireOpen()
            requireConfigurationSuccess(
                "selected SNI protocol policy",
                unsafe {
                    wirestack_tls_engine_set_protocol_versions(
                        current,
                        Int32(tlsVersionNumber(context.security.minimumVersion)),
                        Int32(tlsVersionNumber(context.security.maximumVersion))
                    )
                }
            )
        }
        configureLocalIdentity(context.identity)
        configureAlpn(context.alpnProtocols())
        let systemTrust = match (context.clientTrust) {
            case Some(value) => if (engineRequiresSystemTrust(value)) {
                Some(LinuxSystemTrustAdapter.discover())
            } else {
                None<LinuxSystemTrustLocation>
            }
            case None => None<LinuxSystemTrustLocation>
        }
        configureClientAuthentication(
            context.clientAuthentication,
            context.clientTrust,
            systemTrust
        )
        configureServerSessionIdContext(serverSessionIdContext(context, systemTrust))
    }

    private func failPendingServerNameSelection(): Unit {
        synchronized(mutex) {
            if (handle != 0u64) {
                let _ = unsafe { wirestack_tls_engine_fail_server_name_selection(handle) }
            }
        }
    }

    public func handshakeInfo(): TlsHandshakeInfo {
        synchronized(mutex) {
            let current = requireOpen()
            let versionOutput = Array<Int32>(1, repeat: 0)
            let cipherSizeOutput = Array<UInt64>(1, repeat: 0u64)
            let alpnSizeOutput = Array<UInt64>(1, repeat: 0u64)
            let resumedOutput = Array<Int32>(1, repeat: 0)
            let matchedPinOutput = Array<Int64>(1, repeat: -1)
            let queryStatus = unsafe {
                let version = acquireArrayRawData(versionOutput)
                let cipherSize = acquireArrayRawData(cipherSizeOutput)
                let alpnSize = acquireArrayRawData(alpnSizeOutput)
                let resumed = acquireArrayRawData(resumedOutput)
                let matchedPin = acquireArrayRawData(matchedPinOutput)
                try {
                    wirestack_tls_engine_handshake_info(
                        current,
                        version.pointer,
                        CPointer<UInt8>(),
                        0u64,
                        cipherSize.pointer,
                        CPointer<UInt8>(),
                        0u64,
                        alpnSize.pointer,
                        resumed.pointer,
                        matchedPin.pointer
                    )
                } finally {
                    releaseArrayRawData(matchedPin)
                    releaseArrayRawData(resumed)
                    releaseArrayRawData(alpnSize)
                    releaseArrayRawData(cipherSize)
                    releaseArrayRawData(version)
                }
            }
            if (queryStatus != NATIVE_OK || cipherSizeOutput[0] == 0u64 ||
                cipherSizeOutput[0] > 255u64 || alpnSizeOutput[0] > 255u64) {
                throw providerFailure("handshake information query", queryStatus)
            }
            let cipher = Array<Byte>(Int64(cipherSizeOutput[0]), repeat: 0)
            let alpnStorageSize = if (alpnSizeOutput[0] == 0u64) { 1 } else {
                Int64(alpnSizeOutput[0])
            }
            let alpn = Array<Byte>(alpnStorageSize, repeat: 0)
            let readStatus = unsafe {
                let version = acquireArrayRawData(versionOutput)
                let cipherBytes = acquireArrayRawData(cipher)
                let cipherSize = acquireArrayRawData(cipherSizeOutput)
                let alpnBytes = acquireArrayRawData(alpn)
                let alpnSize = acquireArrayRawData(alpnSizeOutput)
                let resumed = acquireArrayRawData(resumedOutput)
                let matchedPin = acquireArrayRawData(matchedPinOutput)
                try {
                    wirestack_tls_engine_handshake_info(
                        current,
                        version.pointer,
                        cipherBytes.pointer,
                        UInt64(cipher.size),
                        cipherSize.pointer,
                        alpnBytes.pointer,
                        UInt64(alpnSizeOutput[0]),
                        alpnSize.pointer,
                        resumed.pointer,
                        matchedPin.pointer
                    )
                } finally {
                    releaseArrayRawData(matchedPin)
                    releaseArrayRawData(resumed)
                    releaseArrayRawData(alpnSize)
                    releaseArrayRawData(alpnBytes)
                    releaseArrayRawData(cipherSize)
                    releaseArrayRawData(cipherBytes)
                    releaseArrayRawData(version)
                }
            }
            requireConfigurationSuccess("handshake information", readStatus)
            let peerChain = readPeerCertificateChain(current)
            if (isClientRole(role) && peerChain.isNone()) {
                throw TlsEngineException(
                    TlsEngineErrorCode.ProviderFailure,
                    "verified TLS client handshake returned no peer certificate chain"
                )
            }
            let evidence = makeVerificationEvidence(
                configuredTrust,
                peerChain,
                matchedPinOutput[0],
                verifiedReferenceIdentity
            )
            TlsHandshakeInfo(
                decodeTlsVersion(versionOutput[0]),
                String.fromUtf8(cipher),
                if (alpnSizeOutput[0] == 0u64) {
                    None<String>
                } else {
                    Some(String.fromUtf8(Array<Byte>(
                        Int64(alpnSizeOutput[0]),
                        {index => alpn[index]}
                    )))
                },
                peerChain,
                evidence,
                resumedOutput[0] != 0,
                providerManifest,
                requestedServerName: requestedServerName
            )
        }
    }

    public func serviceExternalSignature(context: OperationContext): Unit {
        try {
            checkTlsOperationContext(context)
        } catch (error: NetworkException) {
            failPendingExternalSignature()
            throw error
        }
        let requestAndSigner = synchronized(mutex) {
            let current = requireOpen()
            let signer = match (externalSigner) {
                case Some(value) => value
                case None => throw TlsEngineException(
                    TlsEngineErrorCode.PrivateKeyFailure,
                    "TLS engine requested a signature without an external signer"
                )
            }
            let algorithmOutput = Array<UInt16>(1, repeat: 0u16)
            let sizeOutput = Array<UInt64>(1, repeat: 0u64)
            let queryStatus = unsafe {
                let algorithm = acquireArrayRawData(algorithmOutput)
                let size = acquireArrayRawData(sizeOutput)
                try {
                    wirestack_tls_engine_external_signature_request(
                        current,
                        algorithm.pointer,
                        CPointer<UInt8>(),
                        0u64,
                        size.pointer
                    )
                } finally {
                    releaseArrayRawData(size)
                    releaseArrayRawData(algorithm)
                }
            }
            if (queryStatus != NATIVE_OK || sizeOutput[0] == 0u64 ||
                sizeOutput[0] > 64u64 * 1024u64) {
                throw providerFailure("external signature request", queryStatus)
            }
            let message = Array<Byte>(Int64(sizeOutput[0]), repeat: 0)
            let readStatus = unsafe {
                let algorithm = acquireArrayRawData(algorithmOutput)
                let input = acquireArrayRawData(message)
                let size = acquireArrayRawData(sizeOutput)
                try {
                    wirestack_tls_engine_external_signature_request(
                        current,
                        algorithm.pointer,
                        input.pointer,
                        UInt64(message.size),
                        size.pointer
                    )
                } finally {
                    releaseArrayRawData(size)
                    releaseArrayRawData(input)
                    releaseArrayRawData(algorithm)
                }
            }
            requireConfigurationSuccess("external signature request", readStatus)
            (signer, ExternalSignatureRequest(
                tlsSignatureAlgorithmFromNative(algorithmOutput[0]),
                message
            ))
        }
        let signature = try {
            requestAndSigner[0].sign(requestAndSigner[1], context)
        } catch (error: Exception) {
            synchronized(mutex) {
                let current = requireOpen()
                let _ = unsafe { wirestack_tls_engine_fail_external_signature(current) }
            }
            throw TlsEngineException(
                TlsEngineErrorCode.PrivateKeyFailure,
                "external TLS signer failed",
                cause: Some(error)
            )
        }
        try {
            checkTlsOperationContext(context)
        } catch (error: NetworkException) {
            failPendingExternalSignature()
            throw error
        }
        if (signature.isEmpty() || signature.size > 16 * 1024) {
            synchronized(mutex) {
                let current = requireOpen()
                let _ = unsafe { wirestack_tls_engine_fail_external_signature(current) }
            }
            throw TlsEngineException(
                TlsEngineErrorCode.PrivateKeyFailure,
                "external TLS signer returned an invalid signature size"
            )
        }
        synchronized(mutex) {
            let current = requireOpen()
            let status = unsafe {
                let input = acquireArrayRawData(signature)
                try {
                    wirestack_tls_engine_complete_external_signature(
                        current,
                        input.pointer,
                        UInt64(signature.size)
                    )
                } finally {
                    releaseArrayRawData(input)
                }
            }
            requireConfigurationSuccess("external signature completion", status)
        }
    }

    private func failPendingExternalSignature(): Unit {
        synchronized(mutex) {
            if (handle != 0u64) {
                let _ = unsafe { wirestack_tls_engine_fail_external_signature(handle) }
            }
        }
    }

    public func pendingCiphertext(): Int64 {
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let raw = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_pending_ciphertext(current, raw.pointer)
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != NATIVE_OK || output[0] > MAX_SIGNED_INT64) {
                throw providerFailure("pending ciphertext query", status)
            }
            Int64(output[0])
        }
    }

    public func drainCiphertext(destination: MutableByteSpan): Int64 {
        if (destination.isEmpty()) {
            return 0
        }
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let bytes = acquireArrayRawData(destination.bytes)
                let count = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_drain_ciphertext(
                        current,
                        bytes.pointer + destination.offset,
                        UInt64(destination.length),
                        count.pointer
                    )
                } finally {
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || output[0] > UInt64(destination.length)) {
                throw providerFailure("ciphertext drain", status)
            }
            Int64(output[0])
        }
    }

    public func feedCiphertext(source: ByteSpan): Int64 {
        if (source.isEmpty()) {
            return 0
        }
        synchronized(mutex) {
            let current = requireOpen()
            let output = Array<UInt64>(1, repeat: 0u64)
            let status = unsafe {
                let bytes = acquireArrayRawData(source.bytes)
                let count = acquireArrayRawData(output)
                try {
                    wirestack_tls_engine_feed_ciphertext(
                        current,
                        bytes.pointer + source.offset,
                        UInt64(source.length),
                        count.pointer
                    )
                } finally {
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || output[0] > UInt64(source.length)) {
                throw providerFailure("ciphertext feed", status)
            }
            Int64(output[0])
        }
    }

    public func readPlaintext(destination: MutableByteSpan): TlsEngineReadResult {
        if (destination.isEmpty()) {
            return TlsEngineReadResult.Data(0)
        }
        synchronized(mutex) {
            let current = requireOpen()
            let countOutput = Array<UInt64>(1, repeat: 0u64)
            let stepOutput = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let bytes = acquireArrayRawData(destination.bytes)
                let count = acquireArrayRawData(countOutput)
                let step = acquireArrayRawData(stepOutput)
                try {
                    wirestack_tls_engine_read_plaintext(
                        current,
                        bytes.pointer + destination.offset,
                        UInt64(destination.length),
                        count.pointer,
                        step.pointer
                    )
                } finally {
                    releaseArrayRawData(step)
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || countOutput[0] > UInt64(destination.length)) {
                throw engineFailure(current, "plaintext read", status, NetworkPhase.TlsRead)
            }
            capturePendingSession(current)
            decodeReadResult(stepOutput[0], Int64(countOutput[0]))
        }
    }

    public func writePlaintext(source: ByteSpan): TlsEngineWriteResult {
        if (source.isEmpty()) {
            return TlsEngineWriteResult.Consumed(0)
        }
        synchronized(mutex) {
            let current = requireOpen()
            let countOutput = Array<UInt64>(1, repeat: 0u64)
            let stepOutput = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let bytes = acquireArrayRawData(source.bytes)
                let count = acquireArrayRawData(countOutput)
                let step = acquireArrayRawData(stepOutput)
                try {
                    wirestack_tls_engine_write_plaintext(
                        current,
                        bytes.pointer + source.offset,
                        UInt64(source.length),
                        count.pointer,
                        step.pointer
                    )
                } finally {
                    releaseArrayRawData(step)
                    releaseArrayRawData(count)
                    releaseArrayRawData(bytes)
                }
            }
            if (status != NATIVE_OK || countOutput[0] > UInt64(source.length)) {
                throw engineFailure(current, "plaintext write", status, NetworkPhase.TlsWrite)
            }
            decodeWriteResult(stepOutput[0], Int64(countOutput[0]))
        }
    }

    public func shutdownStep(): TlsEngineShutdownResult {
        synchronized(mutex) {
            let current = requireOpen()
            let stepOutput = Array<Int32>(1, repeat: -1)
            let status = unsafe {
                let step = acquireArrayRawData(stepOutput)
                try {
                    wirestack_tls_engine_shutdown_step(current, step.pointer)
                } finally {
                    releaseArrayRawData(step)
                }
            }
            if (status != NATIVE_OK) {
                throw engineFailure(current, "shutdown", status, NetworkPhase.TransportClose)
            }
            decodeShutdownResult(stepOutput[0])
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                externalSigner = None<ExternalSigner>
                unsafe { wirestack_tls_engine_destroy(current) }
            }
        }
    }

    public func isClosed(): Bool {
        synchronized(mutex) { handle == 0u64 }
    }

    private func requireOpen(): UInt64 {
        if (handle == 0u64) {
            throw TlsEngineException(TlsEngineErrorCode.Closed, "TLS engine is closed")
        }
        handle
    }

    private func capturePendingSession(current: UInt64): Unit {
        let storeAndKey = match ((sessionStore, sessionKey)) {
            case (Some(store), Some(key)) => Some((store, key))
            case _ => None<(TlsSessionStore, TlsSessionKey)>
        }
        if (storeAndKey.isNone()) {
            return
        }
        let sizeOutput = Array<UInt64>(1, repeat: 0u64)
        let lifetimeOutput = Array<UInt64>(1, repeat: 0u64)
        let singleUseOutput = Array<Int32>(1, repeat: 0)
        let queryStatus = unsafe {
            let size = acquireArrayRawData(sizeOutput)
            let lifetime = acquireArrayRawData(lifetimeOutput)
            let singleUse = acquireArrayRawData(singleUseOutput)
            try {
                wirestack_tls_engine_pending_session(
                    current,
                    CPointer<UInt8>(),
                    0u64,
                    size.pointer,
                    lifetime.pointer,
                    singleUse.pointer
                )
            } finally {
                releaseArrayRawData(singleUse)
                releaseArrayRawData(lifetime)
                releaseArrayRawData(size)
            }
        }
        if (queryStatus != NATIVE_OK || sizeOutput[0] > 256u64 * 1024u64) {
            throw providerFailure("pending TLS session query", queryStatus)
        }
        if (sizeOutput[0] == 0u64) {
            return
        }
        let encoded = Array<Byte>(Int64(sizeOutput[0]), repeat: 0)
        let readStatus = unsafe {
            let output = acquireArrayRawData(encoded)
            let size = acquireArrayRawData(sizeOutput)
            let lifetime = acquireArrayRawData(lifetimeOutput)
            let singleUse = acquireArrayRawData(singleUseOutput)
            try {
                wirestack_tls_engine_pending_session(
                    current,
                    output.pointer,
                    UInt64(encoded.size),
                    size.pointer,
                    lifetime.pointer,
                    singleUse.pointer
                )
            } finally {
                releaseArrayRawData(singleUse)
                releaseArrayRawData(lifetime)
                releaseArrayRawData(size)
                releaseArrayRawData(output)
            }
        }
        if (readStatus != NATIVE_OK) {
            for (index in 0..encoded.size) { encoded[index] = 0 }
            throw providerFailure("pending TLS session", readStatus)
        }
        match (storeAndKey) {
            case Some(value) => value[0].put(
                value[1],
                encoded,
                lifetimeOutput[0],
                singleUseOutput[0] != 0
            )
            case None => ()
        }
    }

    ~init() {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            externalSigner = None<ExternalSigner>
            unsafe { wirestack_tls_engine_destroy(current) }
        }
    }
}

private func configureTrust(
    engineHandle: UInt64,
    trust: TrustPolicy,
    systemTrustLocation: ?LinuxSystemTrustLocation
): Unit {
    match (trust.kind) {
        case TrustPolicyKind.System => loadSystemTrust(engineHandle, systemTrustLocation)
        case TrustPolicyKind.CustomRoots => addCustomRoots(engineHandle, trust)
        case TrustPolicyKind.SystemPlusCustomRoots =>
            loadSystemTrust(engineHandle, systemTrustLocation)
            addCustomRoots(engineHandle, trust)
        case TrustPolicyKind.PinnedPublicKeys => addPublicKeyPins(engineHandle, trust)
    }
}

private func addPublicKeyPins(engineHandle: UInt64, trust: TrustPolicy): Unit {
    for (pin in trust.pins()) {
        let digest = pin.digestBytes()
        let status = unsafe {
            let input = acquireArrayRawData(digest)
            try {
                wirestack_tls_engine_add_spki_sha256_pin(
                    engineHandle,
                    input.pointer,
                    nativePinScope(pin.scope)
                )
            } finally {
                releaseArrayRawData(input)
            }
        }
        requireConfigurationSuccess("SPKI SHA-256 pin", status)
    }
}

private func nativePinScope(value: PinScope): Int32 {
    match (value) {
        case PinScope.LeafSubjectPublicKeyInfo => 0
        case PinScope.AnyCertificateSubjectPublicKeyInfo => 1
    }
}

private func addCustomRoots(engineHandle: UInt64, trust: TrustPolicy): Unit {
    let roots = match (trust.customRootChain()) {
        case Some(value) => value
        case None => throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "custom-root trust policy contains no roots"
        )
    }
    for (certificate in roots.certificates()) {
        let der = certificate.derBytes()
        let status = unsafe {
            let input = acquireArrayRawData(der)
            try {
                wirestack_tls_engine_add_trust_anchor_der(
                    engineHandle,
                    input.pointer,
                    UInt64(der.size)
                )
            } finally {
                releaseArrayRawData(input)
            }
        }
        requireConfigurationSuccess("custom trust anchor", status)
    }
}

private func loadSystemTrust(
    engineHandle: UInt64,
    location: ?LinuxSystemTrustLocation
): Unit {
    let source = match (location) {
        case Some(value) => value
        case None => throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "Linux system trust requires an explicit discovered CA source"
        )
    }
    match (source.certificateBundle) {
        case Some(path) => withCString(path, {value =>
            requireConfigurationSuccess(
                "Linux CA bundle",
                unsafe { wirestack_tls_engine_load_verify_bundle(engineHandle, value) }
            )
        })
        case None => match (source.hashedCertificateDirectory) {
            case Some(path) => withCString(path, {value =>
                requireConfigurationSuccess(
                    "Linux hashed CA directory",
                    unsafe { wirestack_tls_engine_load_verify_directory(engineHandle, value) }
                )
            })
            case None => throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "Linux system trust location contains no source"
            )
        }
    }
}

private func withCString(value: String, action: (CString) -> Unit): Unit {
    unsafe {
        let encoded = LibC.mallocCString(value)
        try {
            action(encoded)
        } finally {
            LibC.free(encoded)
        }
    }
}

private func requireConfigurationSuccess(operation: String, status: Int32): Unit {
    if (status != NATIVE_OK) {
        throw providerFailure(operation, status)
    }
}

private func encodeAlpnProtocols(protocols: Array<String>): Array<Byte> {
    var total: Int64 = 0
    for (protocol in protocols) {
        let size = protocol.toArray().size
        if (size <= 0 || size > 255 || total > 4096 - size - 1) {
            throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "ALPN protocol list exceeds the native 4096-byte limit"
            )
        }
        total += size + 1
    }
    let output = Array<Byte>(total, repeat: 0)
    var offset: Int64 = 0
    for (protocol in protocols) {
        let bytes = protocol.toArray()
        output[offset] = UInt8(bytes.size)
        offset++
        for (value in bytes) {
            output[offset] = value
            offset++
        }
    }
    output
}

private func decodeTlsVersion(value: Int32): TlsVersion {
    if (value == 12) {
        TlsVersion.Tls12
    } else if (value == 13) {
        TlsVersion.Tls13
    } else {
        throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider returned an unsupported negotiated version"
        )
    }
}

private func readPeerCertificateChain(engineHandle: UInt64): ?CertificateChain {
    let metadata = Array<UInt64>(2, repeat: 0u64)
    let queryStatus = unsafe {
        let values = acquireArrayRawData(metadata)
        try {
            wirestack_tls_engine_peer_chain_der(
                engineHandle,
                CPointer<UInt8>(),
                0u64,
                values.pointer,
                values.pointer + 1
            )
        } finally {
            releaseArrayRawData(values)
        }
    }
    if (queryStatus != NATIVE_OK || metadata[0] > 1024u64 * 1024u64 ||
        metadata[1] > 16u64) {
        throw providerFailure("peer certificate chain query", queryStatus)
    }
    if (metadata[1] == 0u64) {
        return None<CertificateChain>
    }
    if (metadata[0] == 0u64) {
        throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider returned an empty encoded peer chain"
        )
    }
    let packed = Array<Byte>(Int64(metadata[0]), repeat: 0)
    let readStatus = unsafe {
        let output = acquireArrayRawData(packed)
        let values = acquireArrayRawData(metadata)
        try {
            wirestack_tls_engine_peer_chain_der(
                engineHandle,
                output.pointer,
                UInt64(packed.size),
                values.pointer,
                values.pointer + 1
            )
        } finally {
            releaseArrayRawData(values)
            releaseArrayRawData(output)
        }
    }
    requireConfigurationSuccess("peer certificate chain", readStatus)
    let certificates = Array<DerCertificate>(Int64(metadata[1]), {index =>
        let offset = peerCertificateOffset(packed, index)
        let size = peerCertificateSize(packed, offset)
        DerCertificate(Array<Byte>(size, {byteIndex => packed[offset + 4 + byteIndex]}))
    })
    let finalOffset = peerCertificateOffset(packed, certificates.size)
    if (finalOffset != packed.size) {
        throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider returned malformed peer certificate framing"
        )
    }
    Some(CertificateChain(certificates))
}

private func peerCertificateOffset(packed: Array<Byte>, targetIndex: Int64): Int64 {
    var offset: Int64 = 0
    for (_ in 0..targetIndex) {
        let size = peerCertificateSize(packed, offset)
        offset += 4 + size
        if (offset > packed.size) {
            throw TlsEngineException(
                TlsEngineErrorCode.ProviderFailure,
                "TLS provider returned truncated peer certificate framing"
            )
        }
    }
    offset
}

private func peerCertificateSize(packed: Array<Byte>, offset: Int64): Int64 {
    if (offset < 0 || packed.size - offset < 4) {
        throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider returned truncated peer certificate length"
        )
    }
    let size = Int64(packed[offset]) * 16777216 +
        Int64(packed[offset + 1]) * 65536 +
        Int64(packed[offset + 2]) * 256 + Int64(packed[offset + 3])
    if (size <= 0 || size > 256 * 1024 || size > packed.size - offset - 4) {
        throw TlsEngineException(
            TlsEngineErrorCode.ProviderFailure,
            "TLS provider returned an invalid peer certificate length"
        )
    }
    size
}

private func makeVerificationEvidence(
    trust: ?TrustPolicy,
    peerChain: ?CertificateChain,
    matchedPinIndex: Int64,
    verifiedReferenceIdentity: ?String
): ?TrustVerificationEvidence {
    let policy = match (trust) {
        case Some(value) => value
        case None => return None<TrustVerificationEvidence>
    }
    let chain = match (peerChain) {
        case Some(value) => value
        case None => return None<TrustVerificationEvidence>
    }
    Some(TrustVerificationEvidence(
        TrustVerificationStatus.Verified,
        trustAnchorSource(policy.kind),
        policy.contextIdentity,
        chain.size(),
        matchedPinIndex: if (matchedPinIndex >= 0) {
            Some(matchedPinIndex)
        } else {
            None<Int64>
        },
        verifiedReferenceIdentity: verifiedReferenceIdentity
    ))
}

private func trustAnchorSource(kind: TrustPolicyKind): TrustAnchorSource {
    match (kind) {
        case TrustPolicyKind.System => TrustAnchorSource.System
        case TrustPolicyKind.CustomRoots => TrustAnchorSource.CustomRoots
        case TrustPolicyKind.SystemPlusCustomRoots => TrustAnchorSource.SystemPlusCustomRoots
        case TrustPolicyKind.PinnedPublicKeys => TrustAnchorSource.PublicKeyPin
    }
}

private func referenceIdentityText(value: ReferenceIdentity): String {
    match (value) {
        case ReferenceIdentity.Dns(host) => host.ascii
        case ReferenceIdentity.Ip(address) =>
            let input = address.toOctets()
            let digits: Array<Byte> = "0123456789abcdef".toArray()
            let output = Array<Byte>(3 + input.size * 2, repeat: 0)
            output[0] = b'i'
            output[1] = b'p'
            output[2] = b':'
            for ((index, octet) in input.enumerate()) {
                output[3 + index * 2] = digits[Int64(octet >> 4)]
                output[4 + index * 2] = digits[Int64(octet & 0x0f)]
            }
            String.fromUtf8(output)
    }
}

private func isClientRole(value: TlsEngineRole): Bool {
    match (value) {
        case TlsEngineRole.Client => true
        case TlsEngineRole.Server => false
    }
}

private func engineRequiresSystemTrust(value: TrustPolicy): Bool {
    match (value.kind) {
        case TrustPolicyKind.System | TrustPolicyKind.SystemPlusCustomRoots => true
        case _ => false
    }
}

internal func createAwsLcTlsEngine(
    providerHandle: UInt64,
    role: TlsEngineRole,
    security: TlsSecurityPolicy,
    providerManifest: TlsProviderManifest
): TlsEngine {
    AwsLcTlsEngine(providerHandle, role, security, providerManifest)
}

private func decodeReadResult(step: Int32, count: Int64): TlsEngineReadResult {
    if (step == ENGINE_IO_COMPLETE) {
        if (count <= 0) {
            throw providerFailure("plaintext read result", step)
        }
        TlsEngineReadResult.Data(count)
    } else if (step == ENGINE_IO_WANT_READ) {
        TlsEngineReadResult.WantRead
    } else if (step == ENGINE_IO_WANT_WRITE) {
        TlsEngineReadResult.WantWrite
    } else if (step == ENGINE_IO_CLOSED) {
        TlsEngineReadResult.PeerClosed
    } else {
        throw providerFailure("plaintext read result", step)
    }
}

private func decodeWriteResult(step: Int32, count: Int64): TlsEngineWriteResult {
    if (step == ENGINE_IO_COMPLETE) {
        if (count <= 0) {
            throw providerFailure("plaintext write result", step)
        }
        TlsEngineWriteResult.Consumed(count)
    } else if (step == ENGINE_IO_WANT_READ) {
        TlsEngineWriteResult.WantRead
    } else if (step == ENGINE_IO_WANT_WRITE) {
        TlsEngineWriteResult.WantWrite
    } else if (step == ENGINE_IO_CLOSED) {
        TlsEngineWriteResult.PeerClosed
    } else {
        throw providerFailure("plaintext write result", step)
    }
}

private func decodeShutdownResult(step: Int32): TlsEngineShutdownResult {
    if (step == ENGINE_IO_COMPLETE) {
        TlsEngineShutdownResult.Complete
    } else if (step == ENGINE_IO_SHUTDOWN_SENT) {
        TlsEngineShutdownResult.Sent
    } else if (step == ENGINE_IO_WANT_READ) {
        TlsEngineShutdownResult.WantRead
    } else if (step == ENGINE_IO_WANT_WRITE) {
        TlsEngineShutdownResult.WantWrite
    } else {
        throw providerFailure("shutdown result", step)
    }
}

/**
 * Bounded bridge between a provider memory-BIO engine and a DuplexTransport.
 * It preserves the caller's single absolute OperationContext across all loops.
 */
private class TlsPumpScratch {
    let input: Array<Byte>
    let output: Array<Byte>

    init(size: Int64) {
        input = Array<Byte>(size, repeat: 0)
        output = Array<Byte>(size, repeat: 0)
    }
}

public class TlsEnginePump {
    private static let HANDSHAKE_CHUNK_SIZE: Int64 = 2 * 1024
    private let ciphertextChunkSize: Int64
    private var readScratch = None<TlsPumpScratch>
    private var writeScratch = None<TlsPumpScratch>
    private let transportReadMutex = Mutex()
    private let transportWriteMutex = Mutex()

    public init(ciphertextChunkSize!: Int64 = 16 * 1024) {
        if (ciphertextChunkSize <= 0 || ciphertextChunkSize > 64 * 1024) {
            throw IllegalArgumentException("TLS ciphertext chunk size must be in 1..65536")
        }
        this.ciphertextChunkSize = ciphertextChunkSize
    }

    /** Drops data-plane scratch storage while the connection is idle. */
    internal func releaseIdleBuffers(): Unit {
        synchronized(transportReadMutex) { readScratch = None<TlsPumpScratch> }
        synchronized(transportWriteMutex) { writeScratch = None<TlsPumpScratch> }
    }

    private func takeReadScratch(): TlsPumpScratch {
        synchronized(transportReadMutex) {
            match (readScratch) {
                case Some(value) => readScratch = None<TlsPumpScratch>; value
                case None => TlsPumpScratch(ciphertextChunkSize)
            }
        }
    }

    private func returnReadScratch(value: TlsPumpScratch): Unit {
        synchronized(transportReadMutex) {
            if (readScratch.isNone()) { readScratch = Some(value) }
        }
    }

    private func takeWriteScratch(): TlsPumpScratch {
        synchronized(transportWriteMutex) {
            match (writeScratch) {
                case Some(value) => writeScratch = None<TlsPumpScratch>; value
                case None => TlsPumpScratch(ciphertextChunkSize)
            }
        }
    }

    private func returnWriteScratch(value: TlsPumpScratch): Unit {
        synchronized(transportWriteMutex) {
            if (writeScratch.isNone()) { writeScratch = Some(value) }
        }
    }

    public func driveHandshake(
        engine: TlsEngine,
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): Unit {
        // Handshake flights are incrementally feedable/drainable. Keeping this
        // scratch smaller than the steady-state record buffers avoids charging
        // allocator high-water pages to every subsequently idle connection.
        let handshakeChunkSize = min(HANDSHAKE_CHUNK_SIZE, ciphertextChunkSize)
        let input = Array<Byte>(handshakeChunkSize, repeat: 0)
        let output = Array<Byte>(handshakeChunkSize, repeat: 0)
        while (true) {
            checkTlsOperationContext(context)
            let step = engine.handshakeStep()
            let flushed = flushCiphertext(engine, transport, output, context)
            match (step) {
                case TlsEngineStep.Complete => return
                case TlsEngineStep.WantWrite =>
                    if (flushed == 0) {
                        throw TlsEngineException(
                            TlsEngineErrorCode.NoProgress,
                            "TLS engine requested write without producing ciphertext"
                        )
                    }
                case TlsEngineStep.WantRead =>
                    receiveCiphertext(engine, transport, input, context)
                case TlsEngineStep.NeedSignature =>
                    match (engine) {
                        case signing: ExternalSigningTlsEngine =>
                            signing.serviceExternalSignature(context)
                        case _ => throw TlsEngineException(
                            TlsEngineErrorCode.PrivateKeyFailure,
                            "TLS engine cannot service its external signature request"
                        )
                    }
                case TlsEngineStep.NeedServerSelection =>
                    match (engine) {
                        case selecting: ServerNameSelectingTlsEngine =>
                            selecting.serviceServerNameSelection(context)
                        case _ => throw TlsEngineException(
                            TlsEngineErrorCode.ServerNameSelectionFailure,
                            "TLS engine cannot service its SNI selection request"
                        )
                    }
            }
        }
    }

    public func readPlaintext(
        engine: TlsEngine,
        transport: DuplexTransport,
        destination: MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): ReadResult {
        if (destination.isEmpty()) {
            return ReadResult.Data(0)
        }
        let scratch = takeReadScratch()
        try {
            while (true) {
                checkTlsOperationContext(context)
                let result = engine.readPlaintext(destination)
                let flushed = flushCiphertext(engine, transport, scratch.output, context)
                match (result) {
                    case TlsEngineReadResult.Data(count) =>
                        if (count <= 0 || count > destination.length) {
                            throw noProgress("TLS engine returned invalid plaintext read progress")
                        }
                        return ReadResult.Data(count)
                    case TlsEngineReadResult.PeerClosed => return ReadResult.EndOfStream
                    case TlsEngineReadResult.WantRead =>
                        receiveCiphertext(engine, transport, scratch.input, context)
                    case TlsEngineReadResult.WantWrite =>
                        if (flushed == 0) {
                            throw noProgress("TLS plaintext read requested write without ciphertext")
                    }
                }
            }
            throw noProgress("TLS plaintext read loop terminated without a result")
        } finally {
            returnReadScratch(scratch)
        }
    }

    public func writePlaintext(
        engine: TlsEngine,
        transport: DuplexTransport,
        source: ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        if (source.isEmpty()) {
            return 0
        }
        let scratch = takeWriteScratch()
        try {
            while (true) {
                checkTlsOperationContext(context)
                let result = engine.writePlaintext(source)
                let flushed = flushCiphertext(engine, transport, scratch.output, context)
                match (result) {
                    case TlsEngineWriteResult.Consumed(count) =>
                        if (count <= 0 || count > source.length) {
                            throw noProgress("TLS engine returned invalid plaintext write progress")
                        }
                        return count
                    case TlsEngineWriteResult.PeerClosed =>
                        throw TlsEngineException(
                            TlsEngineErrorCode.PeerClosedWithoutCloseNotify,
                            "TLS peer closed before plaintext write completed"
                        )
                    case TlsEngineWriteResult.WantRead =>
                        receiveCiphertext(engine, transport, scratch.input, context)
                    case TlsEngineWriteResult.WantWrite =>
                        if (flushed == 0) {
                            throw noProgress("TLS plaintext write requested write without ciphertext")
                    }
                }
            }
            throw noProgress("TLS plaintext write loop terminated without a result")
        } finally {
            returnWriteScratch(scratch)
        }
    }

    /** Sends close_notify and waits for the peer's close_notify on one caller budget. */
    public func shutdown(
        engine: TlsEngine,
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): Unit {
        let shutdownChunkSize = min(HANDSHAKE_CHUNK_SIZE, ciphertextChunkSize)
        let input = Array<Byte>(shutdownChunkSize, repeat: 0)
        let output = Array<Byte>(shutdownChunkSize, repeat: 0)
        while (true) {
            checkTlsOperationContext(context)
            let result = engine.shutdownStep()
            let flushed = flushCiphertext(engine, transport, output, context)
            match (result) {
                case TlsEngineShutdownResult.Complete => return
                case TlsEngineShutdownResult.Sent =>
                    if (flushed == 0) {
                        throw noProgress("TLS shutdown sent no close_notify ciphertext")
                    }
                case TlsEngineShutdownResult.WantRead =>
                    receiveCiphertext(engine, transport, input, context)
                case TlsEngineShutdownResult.WantWrite =>
                    if (flushed == 0) {
                        throw noProgress("TLS shutdown requested write without ciphertext")
                    }
            }
        }
        throw noProgress("TLS shutdown loop terminated without a result")
    }

    private func flushCiphertext(
        engine: TlsEngine,
        transport: DuplexTransport,
        buffer: Array<Byte>,
        context: OperationContext
    ): Int64 {
        synchronized(transportWriteMutex) {
            var total: Int64 = 0
            while (engine.pendingCiphertext() > 0) {
                checkTlsOperationContext(context)
                let requested = min(engine.pendingCiphertext(), buffer.size)
                let drained = engine.drainCiphertext(MutableByteSpan(buffer, length: requested))
                if (drained <= 0 || drained > requested) {
                    throw noProgress("TLS engine failed to drain pending ciphertext")
                }
                var remaining = ByteSpan(buffer, length: drained)
                while (!remaining.isEmpty()) {
                    checkTlsOperationContext(context)
                    let written = transport.writeSome(remaining, context: context)
                    if (written <= 0 || written > remaining.length) {
                        throw noProgress("transport failed to write TLS ciphertext")
                    }
                    remaining = remaining.advance(written)
                }
                total += drained
            }
            total
        }
    }

    private func receiveCiphertext(
        engine: TlsEngine,
        transport: DuplexTransport,
        buffer: Array<Byte>,
        context: OperationContext
    ): Unit {
        synchronized(transportReadMutex) {
            checkTlsOperationContext(context)
            match (transport.readSome(MutableByteSpan(buffer), context: context)) {
                case ReadResult.EndOfStream =>
                    throw TlsEngineException(
                        TlsEngineErrorCode.PeerClosedWithoutCloseNotify,
                        "transport reached EOF while TLS expected a record"
                    )
                case ReadResult.Data(count) =>
                    if (count <= 0 || count > buffer.size) {
                        throw noProgress("transport returned no TLS record progress")
                    }
                    feedAll(engine, ByteSpan(buffer, length: count))
            }
        }
    }

    private func feedAll(engine: TlsEngine, source: ByteSpan): Unit {
        var remaining = source
        while (!remaining.isEmpty()) {
            let accepted = engine.feedCiphertext(remaining)
            if (accepted <= 0 || accepted > remaining.length) {
                throw TlsEngineException(
                    TlsEngineErrorCode.NoProgress,
                    "TLS engine failed to accept transport ciphertext"
                )
            }
            remaining = remaining.advance(accepted)
        }
    }

    private func noProgress(message: String): TlsEngineException {
        TlsEngineException(TlsEngineErrorCode.NoProgress, message)
    }
}

private func checkTlsOperationContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw TlsEngineException(
            TlsEngineErrorCode.HandshakeCancelled,
            "TLS handshake was cancelled"
        )
    }
    if (context.isDeadlineExceeded()) {
        throw TlsEngineException(
            TlsEngineErrorCode.HandshakeTimeout,
            "TLS handshake deadline exceeded"
        )
    }
}
