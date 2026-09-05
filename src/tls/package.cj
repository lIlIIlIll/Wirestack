package wirestack.tls

import wirestack.internal.tls_engine as engine
import wirestack as api

// Provider-neutral primitives needed to implement or wrap an existing
// transport. The resolved declarations contain no std.net or native provider
// type.
/**
 * Wirestack 公开 API：IpAddressFamily。
 */
public type IpAddressFamily = api.IpAddressFamily
/**
 * Wirestack 公开 API：IpAddress。
 */
public type IpAddress = api.IpAddress
/**
 * Wirestack 公开 API：SocketEndpoint。
 */
public type SocketEndpoint = api.SocketEndpoint
/**
 * Wirestack 公开 API：HostName。
 */
public type HostName = api.HostName

/**
 * Wirestack 公开 API：ByteSpan。
 */
public type ByteSpan = api.ByteSpan
/**
 * Wirestack 公开 API：MutableByteSpan。
 */
public type MutableByteSpan = api.MutableByteSpan
/**
 * Wirestack 公开 API：ReadResult。
 */
public type ReadResult = api.ReadResult
/**
 * Wirestack 公开 API：ShutdownDirection。
 */
public type ShutdownDirection = api.ShutdownDirection
/**
 * Wirestack 公开 API：AbortReason。
 */
public type AbortReason = api.AbortReason
/**
 * Wirestack 公开 API：TransportInfo。
 */
public type TransportInfo = api.TransportInfo
/**
 * Wirestack 公开 API：DuplexTransport。
 */
public type DuplexTransport = api.DuplexTransport
/**
 * Wirestack 公开 API：TransportListener。
 */
public type TransportListener = api.TransportListener
/**
 * Wirestack 公开 API：OperationContext。
 */
public type OperationContext = api.OperationContext
/**
 * Wirestack 公开 API：Deadline。
 */
public type Deadline = api.Deadline
/**
 * Wirestack 公开 API：CancellationToken。
 */
public type CancellationToken = api.CancellationToken
/**
 * Wirestack 公开 API：CancellationSource。
 */
public type CancellationSource = api.CancellationSource
/**
 * Wirestack 公开 API：NetworkTraceContext。
 */
public type NetworkTraceContext = api.NetworkTraceContext
/**
 * Wirestack 公开 API：NetworkErrorCategory。
 */
public type NetworkErrorCategory = api.NetworkErrorCategory
/**
 * Wirestack 公开 API：NetworkPhase。
 */
public type NetworkPhase = api.NetworkPhase
/**
 * Wirestack 公开 API：NetworkErrorCode。
 */
public type NetworkErrorCode = api.NetworkErrorCode
/**
 * Wirestack 公开 API：Retryability。
 */
public type Retryability = api.Retryability
/**
 * Wirestack 公开 API：NetworkException。
 */
public type NetworkException = api.NetworkException

/**
 * Wirestack 公开 API：TlsCapability。
 */
public type TlsCapability = api.TlsCapability
/**
 * Wirestack 公开 API：TlsVersion。
 */
public type TlsVersion = api.TlsVersion
/**
 * Wirestack 公开 API：TlsSecurityProfile。
 */
public type TlsSecurityProfile = api.TlsSecurityProfile
/**
 * Wirestack 公开 API：TlsContextErrorCode。
 */
public type TlsContextErrorCode = api.TlsContextErrorCode
/**
 * Wirestack 公开 API：TlsContextException。
 */
public type TlsContextException = api.TlsContextException
/**
 * Wirestack 公开 API：TlsEngineErrorCode。
 */
public type TlsEngineErrorCode = api.TlsEngineErrorCode
/**
 * Wirestack 公开 API：TlsEngineException。
 */
public type TlsEngineException = api.TlsEngineException
/**
 * Wirestack 公开 API：TlsConnectionState。
 */
public type TlsConnectionState = api.TlsConnectionState
/**
 * Wirestack 公开 API：TlsClosureEvidence。
 */
public type TlsClosureEvidence = api.TlsClosureEvidence
/**
 * Wirestack 公开 API：ClientAuthentication。
 */
public type ClientAuthentication = api.ClientAuthentication

/**
 * Wirestack 公开 API：TrustPolicyKind。
 */
public type TrustPolicyKind = api.TrustPolicyKind
/**
 * Wirestack 公开 API：TrustAnchorSource。
 */
public type TrustAnchorSource = api.TrustAnchorSource
/**
 * Wirestack 公开 API：TrustVerificationStatus。
 */
public type TrustVerificationStatus = api.TrustVerificationStatus
/**
 * Wirestack 公开 API：TrustVerificationEvidence。
 */
public type TrustVerificationEvidence = api.TrustVerificationEvidence
/**
 * Wirestack 公开 API：TrustPolicy。
 */
public type TrustPolicy = api.TrustPolicy
/**
 * Wirestack 公开 API：CertificateInputLimits。
 */
public type CertificateInputLimits = api.CertificateInputLimits
/**
 * Wirestack 公开 API：CertificateInputErrorCode。
 */
public type CertificateInputErrorCode = api.CertificateInputErrorCode
/**
 * Wirestack 公开 API：CertificateInputException。
 */
public type CertificateInputException = api.CertificateInputException
/**
 * Wirestack 公开 API：DerCertificate。
 */
public type DerCertificate = api.DerCertificate
/**
 * Wirestack 公开 API：CertificateChain。
 */
public type CertificateChain = api.CertificateChain
/**
 * Wirestack 公开 API：PinScope。
 */
public type PinScope = api.PinScope
/**
 * Wirestack 公开 API：SpkiSha256Pin。
 */
public type SpkiSha256Pin = api.SpkiSha256Pin
/**
 * Wirestack 公开 API：ReferenceIdentity。
 */
public type ReferenceIdentity = api.ReferenceIdentity
/**
 * Wirestack 公开 API：IdentityVerificationErrorCode。
 */
public type IdentityVerificationErrorCode = api.IdentityVerificationErrorCode
/**
 * Wirestack 公开 API：IdentityVerificationException。
 */
public type IdentityVerificationException = api.IdentityVerificationException
/**
 * Wirestack 公开 API：IdentityVerificationEvidence。
 */
public type IdentityVerificationEvidence = api.IdentityVerificationEvidence

/**
 * Wirestack 公开 API：PrivateKeyKind。
 */
public type PrivateKeyKind = api.PrivateKeyKind
/**
 * Wirestack 公开 API：PrivateKeyErrorCode。
 */
public type PrivateKeyErrorCode = api.PrivateKeyErrorCode
/**
 * Wirestack 公开 API：PrivateKeyException。
 */
public type PrivateKeyException = api.PrivateKeyException
/**
 * Wirestack 公开 API：TlsSignatureAlgorithm。
 */
public type TlsSignatureAlgorithm = api.TlsSignatureAlgorithm
/**
 * Wirestack 公开 API：ExternalSignatureRequest。
 */
public type ExternalSignatureRequest = api.ExternalSignatureRequest
/**
 * Wirestack 公开 API：ExternalSigner。
 */
public type ExternalSigner = api.ExternalSigner

/** Runtime/build identity for the active Linux TLS implementation. */
public class TlsRuntimeInfo {
/**
 * Wirestack 公开 API：transportBackend。
 */
    public let transportBackend: String
/**
 * Wirestack 公开 API：runtimeIoBackend。
 */
    public let runtimeIoBackend: String
/**
 * Wirestack 公开 API：tlsProvider。
 */
    public let tlsProvider: String
/**
 * Wirestack 公开 API：tlsProviderVersion。
 */
    public let tlsProviderVersion: String
/**
 * Wirestack 公开 API：trustBackend。
 */
    public let trustBackend: String
/**
 * Wirestack 公开 API：targetTriple。
 */
    public let targetTriple: String
/**
 * Wirestack 公开 API：externalOpenSslDependency。
 */
    public let externalOpenSslDependency: Bool
/**
 * Wirestack 公开 API：buildFingerprint。
 */
    public let buildFingerprint: String
    private let ownedTlsVersions: Array<String>
    private let ownedHttpVersions: Array<String>
    private let ownedFeatureFlags: Array<String>

/**
 * Wirestack 公开 API：supportedTlsVersions。
 */
    public prop supportedTlsVersions: Array<String> { get() { ownedTlsVersions.clone() } }
/**
 * Wirestack 公开 API：httpVersions。
 */
    public prop httpVersions: Array<String> { get() { ownedHttpVersions.clone() } }
/**
 * Wirestack 公开 API：featureFlags。
 */
    public prop featureFlags: Array<String> { get() { ownedFeatureFlags.clone() } }

    internal init(snapshot: engine.TlsRuntimeSnapshot) {
        transportBackend = "std-net"
        runtimeIoBackend = "cjnative"
        tlsProvider = snapshot.provider.providerId
        tlsProviderVersion = snapshot.provider.version
        trustBackend = snapshot.trustBackend
        targetTriple = snapshot.targetTriple
        externalOpenSslDependency = snapshot.externalOpenSslDependency
        buildFingerprint = snapshot.buildFingerprint
        ownedTlsVersions = snapshot.supportedTlsVersions
        ownedHttpVersions = snapshot.httpVersions
        ownedFeatureFlags = snapshot.featureFlags
    }
}

/** Diagnostics only; each call returns a handle-free immutable snapshot. */
public class TlsRuntime {
/**
 * Wirestack 公开 API：info。
 */
    public static func info(): TlsRuntimeInfo {
        let provider = engine.selectedTlsProvider()
        try {
            TlsRuntimeInfo(provider.runtimeSnapshot())
        } finally {
            provider.close()
        }
    }
}
