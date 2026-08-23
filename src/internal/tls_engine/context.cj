package wirestack.internal.tls_engine

import wirestack.internal.trust.*

public enum TlsCapability {
    | SystemTrust
    | CustomRoots
    | HardwareKeys
    | ClientCertificate
    | ServerMode
    | Tls12
    | Tls13
    | Http2
    | NetworkBinding
}

private let PLATFORM_SYSTEM_TRUST: UInt64 = 1u64 << 0
private let PLATFORM_CUSTOM_ROOTS: UInt64 = 1u64 << 1
private let PLATFORM_HARDWARE_KEYS: UInt64 = 1u64 << 2
private let PLATFORM_CLIENT_CERT: UInt64 = 1u64 << 3
private let PLATFORM_SERVER: UInt64 = 1u64 << 4
private let PLATFORM_TLS12: UInt64 = 1u64 << 5
private let PLATFORM_TLS13: UInt64 = 1u64 << 6
private let PLATFORM_HTTP2: UInt64 = 1u64 << 7
private let PLATFORM_NETWORK_BINDING: UInt64 = 1u64 << 8

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
        TlsCapabilities(value)
    }

    public func supports(capability: TlsCapability): Bool {
        (bits & platformCapabilityMask(capability)) != 0u64
    }
}

public enum TlsVersion {
    | Tls12
    | Tls13
}

public enum TlsSecurityProfile {
    | Compatible
    | Modern
    | StrictTls13
}

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

public enum ClientAuthentication {
    | None
    | Optional
    | Required
}

public enum TlsContextErrorCode {
    | MissingTrust
    | MissingIdentity
    | InvalidVersionRange
    | InvalidAlpn
    | UnsupportedCapability
}

public class TlsContextException <: Exception {
    public let code: TlsContextErrorCode
    public let capability: ?TlsCapability

    public init(
        code: TlsContextErrorCode,
        message: String,
        capability!: ?TlsCapability = None<TlsCapability>
    ) {
        super(message)
        this.code = code
        this.capability = capability
    }

    protected override func getClassName(): String { "TlsContextException" }
}

/** Immutable, concurrently shareable client configuration. */
public class TlsClientContext {
    public let providerManifest: TlsProviderManifest
    public let capabilities: TlsCapabilities
    public let security: TlsSecurityPolicy
    public let trust: TrustPolicy
    public let identity: ?LocalIdentity
    private let protocolNames: Array<String>

    private init(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        trust: TrustPolicy,
        identity: ?LocalIdentity,
        protocolNames: Array<String>
    ) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
        this.security = security
        this.trust = trust
        this.identity = identity
        this.protocolNames = copyStrings(protocolNames)
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
        protocolNames: Array<String>
    ): TlsClientContext {
        TlsClientContext(
            providerManifest,
            capabilities,
            security,
            trust,
            identity,
            protocolNames
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
    private let protocolNames: Array<String>

    private init(
        providerManifest: TlsProviderManifest,
        capabilities: TlsCapabilities,
        security: TlsSecurityPolicy,
        identity: LocalIdentity,
        clientAuthentication: ClientAuthentication,
        clientTrust: ?TrustPolicy,
        protocolNames: Array<String>
    ) {
        this.providerManifest = providerManifest
        this.capabilities = capabilities
        this.security = security
        this.identity = identity
        this.clientAuthentication = clientAuthentication
        this.clientTrust = clientTrust
        this.protocolNames = copyStrings(protocolNames)
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
        protocolNames: Array<String>
    ): TlsServerContext {
        TlsServerContext(
            providerManifest,
            capabilities,
            security,
            identity,
            clientAuthentication,
            clientTrust,
            protocolNames
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
        TlsClientContext.create(
            providerManifest,
            capabilities,
            TlsSecurityPolicy(profile, minimum, maximum),
            resolvedTrust,
            identityRequirement,
            protocols
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
        TlsServerContext.create(
            providerManifest,
            capabilities,
            TlsSecurityPolicy(profile, minimum, maximum),
            resolvedIdentity,
            authentication,
            trustRequirement,
            protocols
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
