package wirestack.internal.tls_engine

import std.sync.AtomicUInt64

import wirestack.internal.trust.*
import wirestack as api

public type TlsCapability = api.TlsCapability

private let PLATFORM_SYSTEM_TRUST: UInt64 = 1u64 << 0
private let PLATFORM_CUSTOM_ROOTS: UInt64 = 1u64 << 1
private let PLATFORM_HARDWARE_KEYS: UInt64 = 1u64 << 2
private let PLATFORM_CLIENT_CERT: UInt64 = 1u64 << 3
private let PLATFORM_SERVER: UInt64 = 1u64 << 4
private let PLATFORM_TLS12: UInt64 = 1u64 << 5
private let PLATFORM_TLS13: UInt64 = 1u64 << 6
private let PLATFORM_HTTP2: UInt64 = 1u64 << 7
private let PLATFORM_NETWORK_BINDING: UInt64 = 1u64 << 8
private let PLATFORM_EXTERNAL_DECRYPTOR: UInt64 = 1u64 << 9
private let PLATFORM_KEY_LOG: UInt64 = 1u64 << 10

private func platformCapabilityMask(capability: TlsCapability): UInt64 {
    match (capability) {
        case TlsCapability.SystemTrust => PLATFORM_SYSTEM_TRUST
        case TlsCapability.CustomRoots => PLATFORM_CUSTOM_ROOTS
        case TlsCapability.HardwareKeys => PLATFORM_HARDWARE_KEYS
        case TlsCapability.ClientCertificate => PLATFORM_CLIENT_CERT
        case TlsCapability.ServerMode => PLATFORM_SERVER
        case TlsCapability.Tls12 => PLATFORM_TLS12
        case TlsCapability.Tls13 => PLATFORM_TLS13
        case TlsCapability.Http2 => PLATFORM_HTTP2
        case TlsCapability.NetworkBinding => PLATFORM_NETWORK_BINDING
        case TlsCapability.ExternalDecryptor => PLATFORM_EXTERNAL_DECRYPTOR
        case TlsCapability.KeyLog => PLATFORM_KEY_LOG
    }
}

/** Read-only aggregate of provider and platform-adapter capabilities. */
public struct TlsCapabilities {
    private let bits: UInt64

    private init(bits: UInt64) { this.bits = bits }

    public static func fromProvider(
        manifest: TlsProviderManifest,
        systemTrustAvailable!: Bool = false,
        hardwareKeysAvailable!: Bool = false,
        networkBindingAvailable!: Bool = false
    ): TlsCapabilities {
        var value: UInt64 = 0u64
        if (systemTrustAvailable) { value |= PLATFORM_SYSTEM_TRUST }
        if (hardwareKeysAvailable) { value |= PLATFORM_HARDWARE_KEYS }
        if (networkBindingAvailable) { value |= PLATFORM_NETWORK_BINDING }
        if (manifest.supports(TlsProviderCapability.CustomRoots)) {
            value |= PLATFORM_CUSTOM_ROOTS
        }
        if (manifest.supports(TlsProviderCapability.ClientCertificate)) {
            value |= PLATFORM_CLIENT_CERT
        }
        if (manifest.supports(TlsProviderCapability.Server)) {
            value |= PLATFORM_SERVER
        }
        if (manifest.supports(TlsProviderCapability.Tls12)) {
            value |= PLATFORM_TLS12
        }
        if (manifest.supports(TlsProviderCapability.Tls13)) {
            value |= PLATFORM_TLS13
        }
        if (manifest.supports(TlsProviderCapability.Http2)) {
            value |= PLATFORM_HTTP2
        }
        if (manifest.supports(TlsProviderCapability.ExternalDecryptor)) {
            value |= PLATFORM_EXTERNAL_DECRYPTOR
        }
        if (manifest.supports(TlsProviderCapability.KeyLog)) {
            value |= PLATFORM_KEY_LOG
        }
        TlsCapabilities(value)
    }

    public func supports(capability: TlsCapability): Bool {
        (bits & platformCapabilityMask(capability)) != 0u64
    }
}

public type TlsVersion = api.TlsVersion
public type TlsSecurityProfile = api.TlsSecurityProfile

/** Frozen protocol policy. No provider-specific cipher string is accepted. */
public struct TlsSecurityPolicy {
    public let profile: TlsSecurityProfile
    public let minimumVersion: TlsVersion
    public let maximumVersion: TlsVersion
    public let compressionEnabled: Bool
    public let renegotiationEnabled: Bool
    public let nullOrAnonymousCiphersEnabled: Bool
    public let zeroRttEnabled: Bool

    internal init(
        profile: TlsSecurityProfile,
        minimumVersion: TlsVersion,
        maximumVersion: TlsVersion
    ) {
        this.profile = profile
        this.minimumVersion = minimumVersion
        this.maximumVersion = maximumVersion
        compressionEnabled = false
        renegotiationEnabled = false
        nullOrAnonymousCiphersEnabled = false
        zeroRttEnabled = false
    }

    public static func forProfile(profile: TlsSecurityProfile): TlsSecurityPolicy {
        match (profile) {
            case TlsSecurityProfile.StrictTls13 =>
                TlsSecurityPolicy(profile, TlsVersion.Tls13, TlsVersion.Tls13)
            case _ => TlsSecurityPolicy(profile, TlsVersion.Tls12, TlsVersion.Tls13)
        }
    }
}

public type ClientAuthentication = api.ClientAuthentication
public type TlsContextErrorCode = api.TlsContextErrorCode
public type TlsContextException = api.TlsContextException
public type ExternalDecryptor = api.ExternalDecryptor
public type KeyLogSink = api.KeyLogSink

private let NEXT_TLS_CONTEXT_VERSION = AtomicUInt64(1u64)

private func allocateTlsContextVersion(): UInt64 {
    var current = NEXT_TLS_CONTEXT_VERSION.load()
    while (true) {
        if (current == 0u64 || current == UInt64.Max) {
            throw IllegalStateException("TLS context version space is exhausted")
        }
        if (NEXT_TLS_CONTEXT_VERSION.compareAndSwap(current, current + 1u64)) {
            return current
        }
        current = NEXT_TLS_CONTEXT_VERSION.load()
    }
    throw IllegalStateException("unreachable TLS context version state")
}

/** Immutable, concurrently shareable client configuration. */
public class TlsClientContext {
    public let providerManifest: TlsProviderManifest
    public let capabilities: TlsCapabilities
    public let security: TlsSecurityPolicy
    public let trust: TrustPolicy
    public let identity: ?LocalIdentity
    public let contextVersion: UInt64
    public let externalDecryptor: ?ExternalDecryptor
    public let keyLogSink: ?KeyLogSink
    private let protocolNames: Array<String>

    private init(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        trust: TrustPolicy,
        identity: ?LocalIdentity,
        protocolNames: Array<String>,
        contextVersion: UInt64,
        externalDecryptor: ?ExternalDecryptor,
        keyLogSink: ?KeyLogSink
    ) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
        this.security = security
        this.trust = trust
        this.identity = identity
        this.protocolNames = copyStrings(protocolNames)
        this.contextVersion = contextVersion
        this.externalDecryptor = externalDecryptor
        this.keyLogSink = keyLogSink
    }

    public static func builder(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities
    ): TlsClientContextBuilder {
        TlsClientContextBuilder(providerManifest, capabilities)
    }

    public func alpnProtocols(): Array<String> { copyStrings(protocolNames) }

    internal static func create(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        trust: TrustPolicy,
        identity: ?LocalIdentity,
        protocolNames: Array<String>,
        contextVersion: UInt64,
        externalDecryptor: ?ExternalDecryptor,
        keyLogSink: ?KeyLogSink
    ): TlsClientContext {
        TlsClientContext(
            providerManifest,
            capabilities,
            security,
            trust,
            identity,
            protocolNames,
            contextVersion,
            externalDecryptor,
            keyLogSink
        )
    }
}

/** Immutable, concurrently shareable server configuration. */
public class TlsServerContext {
    public let providerManifest: TlsProviderManifest
    public let capabilities: TlsCapabilities
    public let security: TlsSecurityPolicy
    public let identity: LocalIdentity
    public let clientAuthentication: ClientAuthentication
    public let clientTrust: ?TrustPolicy
    public let contextVersion: UInt64
    public let externalDecryptor: ?ExternalDecryptor
    public let keyLogSink: ?KeyLogSink
    private let protocolNames: Array<String>

    private init(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        identity: LocalIdentity,
        clientAuthentication: ClientAuthentication,
        clientTrust: ?TrustPolicy,
        protocolNames: Array<String>,
        contextVersion: UInt64,
        externalDecryptor: ?ExternalDecryptor,
        keyLogSink: ?KeyLogSink
    ) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
        this.security = security
        this.identity = identity
        this.clientAuthentication = clientAuthentication
        this.clientTrust = clientTrust
        this.protocolNames = copyStrings(protocolNames)
        this.contextVersion = contextVersion
        this.externalDecryptor = externalDecryptor
        this.keyLogSink = keyLogSink
    }

    public static func builder(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities
    ): TlsServerContextBuilder {
        TlsServerContextBuilder(providerManifest, capabilities)
    }

    public func alpnProtocols(): Array<String> { copyStrings(protocolNames) }

    internal static func create(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        identity: LocalIdentity,
        clientAuthentication: ClientAuthentication,
        clientTrust: ?TrustPolicy,
        protocolNames: Array<String>,
        contextVersion: UInt64,
        externalDecryptor: ?ExternalDecryptor,
        keyLogSink: ?KeyLogSink
    ): TlsServerContext {
        TlsServerContext(
            providerManifest,
            capabilities,
            security,
            identity,
            clientAuthentication,
            clientTrust,
            protocolNames,
            contextVersion,
            externalDecryptor,
            keyLogSink
        )
    }
}

public class TlsClientContextBuilder {
    private let providerManifest: TlsProviderManifest
    private let capabilities: TlsCapabilities
    private var profile = TlsSecurityProfile.Modern
    private var minimum = TlsVersion.Tls12
    private var maximum = TlsVersion.Tls13
    private var trustRequirement: ?TrustPolicy = Some(TrustPolicy.system())
    private var identityRequirement: ?LocalIdentity = None<LocalIdentity>
    private var decryptor: ?ExternalDecryptor = None<ExternalDecryptor>
    private var keyLogger: ?KeyLogSink = None<KeyLogSink>
    private var protocols = Array<String>()

    internal init(providerManifest: TlsProviderManifest, capabilities: TlsCapabilities) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
    }

    public func securityProfile(value: TlsSecurityProfile): TlsClientContextBuilder {
        profile = value
        match (value) {
            case TlsSecurityProfile.StrictTls13 =>
                minimum = TlsVersion.Tls13
                maximum = TlsVersion.Tls13
            case _ =>
                minimum = TlsVersion.Tls12
                maximum = TlsVersion.Tls13
        }
        this
    }

    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsClientContextBuilder {
        this.minimum = minimum
        this.maximum = maximum
        this
    }

    public func trust(value: TrustPolicy): TlsClientContextBuilder {
        trustRequirement = Some(value)
        this
    }

    public func identity(value: LocalIdentity): TlsClientContextBuilder {
        identityRequirement = Some(value)
        this
    }

    public func withExternalDecryptor(value: ExternalDecryptor): TlsClientContextBuilder {
        decryptor = Some(value)
        this
    }

    public func withKeyLogSink(value: KeyLogSink): TlsClientContextBuilder {
        keyLogger = Some(value)
        this
    }

    public func alpn(values: Array<String>): TlsClientContextBuilder {
        protocols = copyStrings(values)
        this
    }

    public func build(): TlsClientContext {
        validateVersions(profile, minimum, maximum, capabilities)
        validateAlpn(protocols, capabilities)
        let resolvedTrust = match (trustRequirement) {
            case Some(value) => value
            case None => throw TlsContextException(
                TlsContextErrorCode.MissingTrust,
                "TLS client context requires a trust policy"
            )
        }
        validateTrust(resolvedTrust, capabilities)
        match (identityRequirement) {
            case Some(value) => validateIdentity(value, true, capabilities)
            case None => ()
        }
        if (decryptor.isSome()) {
            throw TlsContextException(
                TlsContextErrorCode.InvalidHook,
                "external decryption is valid only for TLS server contexts",
                capability: Some(TlsCapability.ExternalDecryptor)
            )
        }
        if (keyLogger.isSome()) {
            requireCapability(capabilities, TlsCapability.KeyLog, "test-build TLS key logging")
        }
        let ownedIdentity = match (identityRequirement) {
            case Some(value) => Some(value.snapshotForContext())
            case None => None<LocalIdentity>
        }
        TlsClientContext.create(
            providerManifest,
            capabilities,
            TlsSecurityPolicy(profile, minimum, maximum),
            resolvedTrust,
            ownedIdentity,
            protocols,
            allocateTlsContextVersion(),
            decryptor,
            keyLogger
        )
    }
}

public class TlsServerContextBuilder {
    private let providerManifest: TlsProviderManifest
    private let capabilities: TlsCapabilities
    private var profile = TlsSecurityProfile.Modern
    private var minimum = TlsVersion.Tls12
    private var maximum = TlsVersion.Tls13
    private var identityRequirement: ?LocalIdentity = None<LocalIdentity>
    private var authentication = ClientAuthentication.None
    private var trustRequirement: ?TrustPolicy = None<TrustPolicy>
    private var decryptor: ?ExternalDecryptor = None<ExternalDecryptor>
    private var keyLogger: ?KeyLogSink = None<KeyLogSink>
    private var protocols = Array<String>()

    internal init(providerManifest: TlsProviderManifest, capabilities: TlsCapabilities) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
    }

    public func securityProfile(value: TlsSecurityProfile): TlsServerContextBuilder {
        profile = value
        match (value) {
            case TlsSecurityProfile.StrictTls13 =>
                minimum = TlsVersion.Tls13
                maximum = TlsVersion.Tls13
            case _ =>
                minimum = TlsVersion.Tls12
                maximum = TlsVersion.Tls13
        }
        this
    }

    public func versions(minimum: TlsVersion, maximum: TlsVersion): TlsServerContextBuilder {
        this.minimum = minimum
        this.maximum = maximum
        this
    }

    public func identity(value: LocalIdentity): TlsServerContextBuilder {
        identityRequirement = Some(value)
        this
    }

    public func clientAuthentication(value: ClientAuthentication): TlsServerContextBuilder {
        authentication = value
        this
    }

    public func clientTrust(value: TrustPolicy): TlsServerContextBuilder {
        trustRequirement = Some(value)
        this
    }

    public func withExternalDecryptor(value: ExternalDecryptor): TlsServerContextBuilder {
        decryptor = Some(value)
        this
    }

    public func withKeyLogSink(value: KeyLogSink): TlsServerContextBuilder {
        keyLogger = Some(value)
        this
    }

    public func alpn(values: Array<String>): TlsServerContextBuilder {
        protocols = copyStrings(values)
        this
    }

    public func build(): TlsServerContext {
        requireCapability(capabilities, TlsCapability.ServerMode, "TLS server mode")
        validateVersions(profile, minimum, maximum, capabilities)
        validateAlpn(protocols, capabilities)
        let resolvedIdentity = match (identityRequirement) {
            case Some(value) => value
            case None => throw TlsContextException(
                TlsContextErrorCode.MissingIdentity,
                "TLS server context requires a local identity"
            )
        }
        validateIdentity(resolvedIdentity, false, capabilities)
        match (authentication) {
            case ClientAuthentication.None => ()
            case _ =>
                let resolvedTrust = match (trustRequirement) {
                    case Some(value) => value
                    case None => throw TlsContextException(
                        TlsContextErrorCode.MissingTrust,
                        "TLS server client authentication requires a trust policy"
                    )
                }
                validateTrust(resolvedTrust, capabilities)
                requireCapability(
                    capabilities,
                    TlsCapability.ClientCertificate,
                    "TLS client certificate authentication"
                )
        }
        if (decryptor.isSome()) {
            requireCapability(
                capabilities,
                TlsCapability.ExternalDecryptor,
                "external RSA private-key decryption"
            )
            if (!resolvedIdentity.supportsExternalDecryption()) {
                throw TlsContextException(
                    TlsContextErrorCode.InvalidHook,
                    "external decryption requires an RSA external/system signer identity",
                    capability: Some(TlsCapability.ExternalDecryptor)
                )
            }
        }
        if (keyLogger.isSome()) {
            requireCapability(capabilities, TlsCapability.KeyLog, "test-build TLS key logging")
        }
        let ownedIdentity = resolvedIdentity.snapshotForContext()
        TlsServerContext.create(
            providerManifest,
            capabilities,
            TlsSecurityPolicy(profile, minimum, maximum),
            ownedIdentity,
            authentication,
            trustRequirement,
            protocols,
            allocateTlsContextVersion(),
            decryptor,
            keyLogger
        )
    }
}

private func validateVersions(
    profile: TlsSecurityProfile,
    minimum: TlsVersion,
    maximum: TlsVersion,
    capabilities: TlsCapabilities
): Unit {
    let minValue = tlsVersionNumber(minimum)
    let maxValue = tlsVersionNumber(maximum)
    if (minValue > maxValue) {
        throw TlsContextException(
            TlsContextErrorCode.InvalidVersionRange,
            "TLS minimum version must not exceed maximum version"
        )
    }
    match (profile) {
        case TlsSecurityProfile.StrictTls13 =>
            if (minValue != 13 || maxValue != 13) {
                throw TlsContextException(
                    TlsContextErrorCode.InvalidVersionRange,
                    "StrictTls13 only permits TLS 1.3"
                )
            }
        case _ => ()
    }
    if (minValue <= 12) {
        requireCapability(capabilities, TlsCapability.Tls12, "TLS 1.2")
    }
    if (maxValue >= 13) {
        requireCapability(capabilities, TlsCapability.Tls13, "TLS 1.3")
    }
}

private func validateAlpn(values: Array<String>, capabilities: TlsCapabilities): Unit {
    var wireBytes: Int64 = 0
    for (index in 0..values.size) {
        let value = values[index]
        let encodedSize = value.toArray().size
        if (value.isEmpty() || encodedSize > 255) {
            throw TlsContextException(
                TlsContextErrorCode.InvalidAlpn,
                "ALPN protocol names must contain 1..255 bytes"
            )
        }
        if (wireBytes > 4096 - encodedSize - 1) {
            throw TlsContextException(
                TlsContextErrorCode.InvalidAlpn,
                "ALPN protocol list must fit within 4096 encoded bytes"
            )
        }
        wireBytes += encodedSize + 1
        for (prior in 0..index) {
            if (values[prior] == value) {
                throw TlsContextException(
                    TlsContextErrorCode.InvalidAlpn,
                    "ALPN protocol names must not repeat"
                )
            }
        }
        if (value == "h2") {
            requireCapability(capabilities, TlsCapability.Http2, "HTTP/2 ALPN")
        }
    }
}

private func validateTrust(value: TrustPolicy, capabilities: TlsCapabilities): Unit {
    match (value.kind) {
        case TrustPolicyKind.System =>
            requireCapability(capabilities, TlsCapability.SystemTrust, "system trust")
        case TrustPolicyKind.CustomRoots =>
            requireCapability(capabilities, TlsCapability.CustomRoots, "custom roots")
        case TrustPolicyKind.SystemPlusCustomRoots =>
            requireCapability(capabilities, TlsCapability.SystemTrust, "system trust")
            requireCapability(capabilities, TlsCapability.CustomRoots, "custom roots")
        case TrustPolicyKind.PinnedPublicKeys => ()
    }
}

private func validateIdentity(
    value: LocalIdentity,
    clientIdentity: Bool,
    capabilities: TlsCapabilities
): Unit {
    if (clientIdentity) {
        requireCapability(capabilities, TlsCapability.ClientCertificate, "client identity")
    } else {
        requireCapability(capabilities, TlsCapability.ServerMode, "server identity")
    }
    if (value.privateKeyRef.requiresHardwareKey) {
        requireCapability(capabilities, TlsCapability.HardwareKeys, "hardware-backed identity")
    }
}

private func requireCapability(
    capabilities: TlsCapabilities,
    capability: TlsCapability,
    feature: String
): Unit {
    if (!capabilities.supports(capability)) {
        throw TlsContextException(
            TlsContextErrorCode.UnsupportedCapability,
            "TLS capability is unavailable: ${feature}",
            capability: Some(capability)
        )
    }
}

internal func tlsVersionNumber(value: TlsVersion): Int64 {
    match (value) {
        case TlsVersion.Tls12 => 12
        case TlsVersion.Tls13 => 13
    }
}

private func copyStrings(values: Array<String>): Array<String> {
    Array<String>(values.size, {index => values[index]})
}
