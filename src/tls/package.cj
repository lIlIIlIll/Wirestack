package wirestack.tls

import wirestack.internal.common as common
import wirestack.internal.tls_engine as engine
import wirestack.internal.transport as transport
import wirestack.internal.trust as trust

// Provider-neutral primitives needed to implement or wrap an existing
// transport. The resolved declarations contain no std.net or native provider
// type.
public type IpAddressFamily = common.IpAddressFamily
public type IpAddress = common.IpAddress
public type SocketEndpoint = common.SocketEndpoint
public type HostName = common.HostName

public type ByteSpan = transport.ByteSpan
public type MutableByteSpan = transport.MutableByteSpan
public type ReadResult = transport.ReadResult
public type ShutdownDirection = transport.ShutdownDirection
public type AbortReason = transport.AbortReason
public type TransportInfo = transport.TransportInfo
public type DuplexTransport = transport.DuplexTransport
public type TransportListener = transport.TransportListener
public type OperationContext = transport.OperationContext
public type Deadline = transport.Deadline
public type CancellationToken = transport.CancellationToken
public type CancellationSource = transport.CancellationSource
public type NetworkTraceContext = transport.NetworkTraceContext
public type NetworkErrorCategory = transport.NetworkErrorCategory
public type NetworkPhase = transport.NetworkPhase
public type NetworkErrorCode = transport.NetworkErrorCode
public type Retryability = transport.Retryability
public type NetworkException = transport.NetworkException

public type TlsVersion = engine.TlsVersion
public type TlsSecurityProfile = engine.TlsSecurityProfile
public type TlsContextErrorCode = engine.TlsContextErrorCode
public type TlsContextException = engine.TlsContextException
public type TlsEngineErrorCode = engine.TlsEngineErrorCode
public type TlsEngineException = engine.TlsEngineException
public type TlsConnectionState = engine.TlsConnectionState
public type TlsClosureEvidence = engine.TlsClosureEvidence
public type ClientAuthentication = engine.ClientAuthentication

public type TrustPolicyKind = trust.TrustPolicyKind
public type TrustAnchorSource = trust.TrustAnchorSource
public type TrustVerificationStatus = trust.TrustVerificationStatus
public type TrustVerificationEvidence = trust.TrustVerificationEvidence
public type TrustPolicy = trust.TrustPolicy
public type CertificateInputLimits = trust.CertificateInputLimits
public type CertificateInputErrorCode = trust.CertificateInputErrorCode
public type CertificateInputException = trust.CertificateInputException
public type DerCertificate = trust.DerCertificate
public type CertificateChain = trust.CertificateChain
public type PinScope = trust.PinScope
public type SpkiSha256Pin = trust.SpkiSha256Pin
public type ReferenceIdentity = trust.ReferenceIdentity
public type IdentityVerificationErrorCode = trust.IdentityVerificationErrorCode
public type IdentityVerificationException = trust.IdentityVerificationException
public type IdentityVerificationEvidence = trust.IdentityVerificationEvidence

public type PrivateKeyKind = engine.PrivateKeyKind
public type PrivateKeyErrorCode = engine.PrivateKeyErrorCode
public type PrivateKeyException = engine.PrivateKeyException
public type TlsSignatureAlgorithm = engine.TlsSignatureAlgorithm
public type ExternalSignatureRequest = engine.ExternalSignatureRequest
public type ExternalSigner = engine.ExternalSigner
public type PrivateKeyRef = engine.PrivateKeyRef
public type LocalIdentity = engine.LocalIdentity

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
        let provider = engine.AwsLcTlsProvider()
        try {
            TlsRuntimeInfo(provider.runtimeSnapshot())
        } finally {
            provider.close()
        }
    }
}
