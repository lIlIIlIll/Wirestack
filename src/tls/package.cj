package wirestack.tls

import wirestack.internal.tls_engine as engine
import wirestack as api

// Provider-neutral primitives needed to implement or wrap an existing
// transport. The resolved declarations contain no std.net or native provider
// type.
public type IpAddressFamily = api.IpAddressFamily
public type IpAddress = api.IpAddress
public type SocketEndpoint = api.SocketEndpoint
public type HostName = api.HostName

public type ByteSpan = api.ByteSpan
public type MutableByteSpan = api.MutableByteSpan
public type ReadResult = api.ReadResult
public type ShutdownDirection = api.ShutdownDirection
public type AbortReason = api.AbortReason
public type TransportInfo = api.TransportInfo
public type DuplexTransport = api.DuplexTransport
public type TransportListener = api.TransportListener
public type OperationContext = api.OperationContext
public type Deadline = api.Deadline
public type CancellationToken = api.CancellationToken
public type CancellationSource = api.CancellationSource
public type NetworkTraceContext = api.NetworkTraceContext
public type NetworkErrorCategory = api.NetworkErrorCategory
public type NetworkPhase = api.NetworkPhase
public type NetworkErrorCode = api.NetworkErrorCode
public type Retryability = api.Retryability
public type NetworkException = api.NetworkException

public type TlsCapability = api.TlsCapability
public type TlsVersion = api.TlsVersion
public type TlsSecurityProfile = api.TlsSecurityProfile
public type TlsContextErrorCode = api.TlsContextErrorCode
public type TlsContextException = api.TlsContextException
public type TlsEngineErrorCode = api.TlsEngineErrorCode
public type TlsEngineException = api.TlsEngineException
public type TlsConnectionState = api.TlsConnectionState
public type TlsClosureEvidence = api.TlsClosureEvidence
public type ClientAuthentication = api.ClientAuthentication

public type TrustPolicyKind = api.TrustPolicyKind
public type TrustAnchorSource = api.TrustAnchorSource
public type TrustVerificationStatus = api.TrustVerificationStatus
public type TrustVerificationEvidence = api.TrustVerificationEvidence
public type TrustPolicy = api.TrustPolicy
public type CertificateInputLimits = api.CertificateInputLimits
public type CertificateInputErrorCode = api.CertificateInputErrorCode
public type CertificateInputException = api.CertificateInputException
public type DerCertificate = api.DerCertificate
public type CertificateChain = api.CertificateChain
public type PinScope = api.PinScope
public type SpkiSha256Pin = api.SpkiSha256Pin
public type ReferenceIdentity = api.ReferenceIdentity
public type IdentityVerificationErrorCode = api.IdentityVerificationErrorCode
public type IdentityVerificationException = api.IdentityVerificationException
public type IdentityVerificationEvidence = api.IdentityVerificationEvidence

public type PrivateKeyKind = api.PrivateKeyKind
public type PrivateKeyErrorCode = api.PrivateKeyErrorCode
public type PrivateKeyException = api.PrivateKeyException
public type TlsSignatureAlgorithm = api.TlsSignatureAlgorithm
public type ExternalSignatureRequest = api.ExternalSignatureRequest
public type ExternalSigner = api.ExternalSigner

/** Runtime/build identity for the active Linux TLS implementation. */
public class TlsRuntimeInfo {
    public let transportBackend: String
    public let runtimeIoBackend: String
    public let tlsProvider: String
    public let tlsProviderVersion: String
    public let trustBackend: String
    public let targetTriple: String
    public let externalOpenSslDependency: Bool
    public let buildFingerprint: String
    private let ownedTlsVersions: Array<String>
    private let ownedHttpVersions: Array<String>
    private let ownedFeatureFlags: Array<String>

    public prop supportedTlsVersions: Array<String> { get() { ownedTlsVersions.clone() } }
    public prop httpVersions: Array<String> { get() { ownedHttpVersions.clone() } }
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
    public static func info(): TlsRuntimeInfo {
        let provider = engine.selectedTlsProvider()
        try {
            TlsRuntimeInfo(provider.runtimeSnapshot())
        } finally {
            provider.close()
        }
    }
}
