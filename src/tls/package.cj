package wirestack.tls

import wirestack.internal.tls_engine.*

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

    internal init(snapshot: TlsRuntimeSnapshot) {
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
        let provider = AwsLcTlsProvider()
        try {
            TlsRuntimeInfo(provider.runtimeSnapshot())
        } finally {
            provider.close()
        }
    }
}
