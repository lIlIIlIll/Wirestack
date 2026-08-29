package wirestack.internal.tls_engine

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.common.*
import wirestack.internal.platform.linux.*
import wirestack.internal.trust.*

private let PROVIDER_OK: Int32 = 0
private let PROVIDER_ABI_VERSION: UInt32 = 1u32

private let CAP_CUSTOM_ROOTS: UInt64 = 1u64 << 0
private let CAP_CLIENT_CERT: UInt64 = 1u64 << 1
private let CAP_SERVER: UInt64 = 1u64 << 2
private let CAP_TLS12: UInt64 = 1u64 << 3
private let CAP_TLS13: UInt64 = 1u64 << 4
private let CAP_HTTP2: UInt64 = 1u64 << 5
private let CAP_EXTERNAL_SIGNER: UInt64 = 1u64 << 6
private let CAP_SESSION_RESUMPTION: UInt64 = 1u64 << 7
private let CAP_SECURE_RANDOM: UInt64 = 1u64 << 8

foreign func wirestack_tls_provider_abi_version(): UInt32
foreign func wirestack_tls_provider_create(outHandle: CPointer<UInt64>): Int32
foreign func wirestack_tls_provider_destroy(handle: UInt64): Unit
foreign func wirestack_tls_provider_id(handle: UInt64): CString
foreign func wirestack_tls_provider_version(handle: UInt64): CString
foreign func wirestack_tls_provider_fingerprint(handle: UInt64): CString
foreign func wirestack_tls_provider_build_fingerprint(handle: UInt64): CString
foreign func wirestack_tls_provider_backend(handle: UInt64): CString
foreign func wirestack_tls_provider_patch_level(handle: UInt64): CString
foreign func wirestack_tls_provider_target_triple(handle: UInt64): CString
foreign func wirestack_tls_provider_external_openssl_dependency(handle: UInt64): Int32
foreign func wirestack_tls_provider_capabilities(handle: UInt64): UInt64
foreign func wirestack_tls_provider_random(
    handle: UInt64,
    output: CPointer<UInt8>,
    size: UInt64
): Int32

public enum TlsProviderCapability {
    | CustomRoots
    | ClientCertificate
    | Server
    | Tls12
    | Tls13
    | Http2
    | ExternalSigner
    | SessionResumption
    | SecureRandom
}

public enum TlsProviderErrorCode {
    | InitializationFailed
    | InvalidManifest
    | ProviderMismatch
    | InvalidNativeState
    | Closed
    | SecureRandomFailed
}

public class TlsProviderException <: Exception {
    public let code: TlsProviderErrorCode
    public let nativeStatus: ?Int64
    public let cause: ?Exception

    public init(
        code: TlsProviderErrorCode,
        message: String,
        nativeStatus!: ?Int64 = None<Int64>,
        cause!: ?Exception = None<Exception>
    ) {
        super(message)
        this.code = code
        this.nativeStatus = nativeStatus
        this.cause = cause
    }

    protected override func getClassName(): String { "TlsProviderException" }
}

private func capabilityMask(capability: TlsProviderCapability): UInt64 {
    match (capability) {
        case TlsProviderCapability.CustomRoots => CAP_CUSTOM_ROOTS
        case TlsProviderCapability.ClientCertificate => CAP_CLIENT_CERT
        case TlsProviderCapability.Server => CAP_SERVER
        case TlsProviderCapability.Tls12 => CAP_TLS12
        case TlsProviderCapability.Tls13 => CAP_TLS13
        case TlsProviderCapability.Http2 => CAP_HTTP2
        case TlsProviderCapability.ExternalSigner => CAP_EXTERNAL_SIGNER
        case TlsProviderCapability.SessionResumption => CAP_SESSION_RESUMPTION
        case TlsProviderCapability.SecureRandom => CAP_SECURE_RANDOM
    }
}

/** Immutable, provider-neutral build and runtime identity. */
public struct TlsProviderManifest {
    public let providerId: String
    public let version: String
    public let fingerprint: String
    public let backend: String
    public let patchLevel: String
    private let capabilityBits: UInt64
    private let bindingIdentity: String

    public init(
        providerId: String,
        version: String,
        fingerprint: String,
        backend: String,
        patchLevel: String,
        capabilityBits: UInt64,
        bindingIdentity!: String = "detached"
    ) {
        if (providerId.isEmpty() || version.isEmpty() || fingerprint.isEmpty() ||
            backend.isEmpty() || patchLevel.isEmpty() || bindingIdentity.isEmpty()) {
            throw IllegalArgumentException("TLS provider manifest fields must not be empty")
        }
        this.providerId = providerId
        this.version = version
        this.fingerprint = fingerprint
        this.backend = backend
        this.patchLevel = patchLevel
        this.capabilityBits = capabilityBits
        this.bindingIdentity = bindingIdentity
    }

    public func supports(capability: TlsProviderCapability): Bool {
        (capabilityBits & capabilityMask(capability)) != 0u64
    }

    internal func sameProviderInstance(other: TlsProviderManifest): Bool {
        providerId == other.providerId && fingerprint == other.fingerprint &&
        bindingIdentity == other.bindingIdentity
    }
}

/** Stable Linux TLS provider/build diagnostics, detached from native handles. */
public class TlsRuntimeSnapshot {
    public let provider: TlsProviderManifest
    public let targetTriple: String
    public let buildFingerprint: String
    public let externalOpenSslDependency: Bool
    public let trustBackend: String
    private let ownedTlsVersions: Array<String>
    private let ownedHttpVersions: Array<String>
    private let ownedFeatureFlags: Array<String>

    public prop supportedTlsVersions: Array<String> {
        get() { ownedTlsVersions.clone() }
    }
    public prop httpVersions: Array<String> {
        get() { ownedHttpVersions.clone() }
    }
    public prop featureFlags: Array<String> {
        get() { ownedFeatureFlags.clone() }
    }

    internal init(
        provider: TlsProviderManifest,
        targetTriple: String,
        buildFingerprint: String,
        externalOpenSslDependency: Bool,
        trustBackend: String,
        supportedTlsVersions: Array<String>,
        httpVersions: Array<String>,
        featureFlags: Array<String>
    ) {
        this.provider = provider
        this.targetTriple = targetTriple
        this.buildFingerprint = buildFingerprint
        this.externalOpenSslDependency = externalOpenSslDependency
        this.trustBackend = trustBackend
        ownedTlsVersions = supportedTlsVersions.clone()
        ownedHttpVersions = httpVersions.clone()
        ownedFeatureFlags = featureFlags.clone()
    }
}

/** Internal provider SPI. No native handle crosses this boundary. */
public interface TlsProvider {
    func manifest(): TlsProviderManifest
    func capabilities(): TlsCapabilities
    func runtimeSnapshot(): TlsRuntimeSnapshot
    func fillSecureRandom(output: Array<Byte>): Unit
    func createEngine(role: TlsEngineRole, security: TlsSecurityPolicy): TlsEngine
    func createClientEngine(
        context: TlsClientContext,
        referenceIdentity: ReferenceIdentity,
        serverName!: ?HostName
    ): TlsEngine
    func createServerEngine(context: TlsServerContext): TlsEngine
    func createServerEngine(selector: TlsServerContextSelector): TlsEngine
    func close(): Unit
}

/** Build-selected provider factory. Tests use the same contract without entering release builds. */
public interface TlsProviderFactory {
    func create(): TlsProvider
}

public class SelectedTlsProviderFactory <: TlsProviderFactory {
    public init() {}
    public func create(): TlsProvider { NativeTlsProvider() }
}

public func selectedTlsProvider(): TlsProvider { SelectedTlsProviderFactory().create() }

private func requiredString(value: CString, field: String): String {
    if (value.getChars().isNull()) {
        throw TlsProviderException(
            TlsProviderErrorCode.InvalidManifest,
            "TLS provider returned no ${field}"
        )
    }
    value.toString()
}

/** Instance-owned adapter for the provider-neutral native ABI selected by the build. */
public class NativeTlsProvider <: TlsProvider {
    private let mutex = Mutex()
    private var handle: UInt64
    private let providerManifest: TlsProviderManifest
    private let sessionStore = TlsSessionStore()

    public init() {
        let abiVersion = unsafe { wirestack_tls_provider_abi_version() }
        if (abiVersion != PROVIDER_ABI_VERSION) {
            throw TlsProviderException(
                TlsProviderErrorCode.InvalidManifest,
                "TLS provider ABI version mismatch",
                nativeStatus: Some(Int64(abiVersion))
            )
        }
        let out = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let raw = acquireArrayRawData(out)
            try { wirestack_tls_provider_create(raw.pointer) }
            finally { releaseArrayRawData(raw) }
        }
        if (status != PROVIDER_OK || out[0] == 0u64) {
            throw TlsProviderException(
                TlsProviderErrorCode.InitializationFailed,
                "failed to create selected TLS provider",
                nativeStatus: Some(Int64(status))
            )
        }
        handle = out[0]
        try {
            providerManifest = unsafe {
                TlsProviderManifest(
                    requiredString(wirestack_tls_provider_id(handle), "provider id"),
                    requiredString(wirestack_tls_provider_version(handle), "version"),
                    requiredString(wirestack_tls_provider_fingerprint(handle), "fingerprint"),
                    requiredString(wirestack_tls_provider_backend(handle), "backend"),
                    requiredString(wirestack_tls_provider_patch_level(handle), "patch level"),
                    wirestack_tls_provider_capabilities(handle),
                    bindingIdentity: "native-${handle}"
                )
            }
        } catch (error: Exception) {
            unsafe { wirestack_tls_provider_destroy(handle) }
            handle = 0u64
            throw error
        }
    }

    public func manifest(): TlsProviderManifest { providerManifest }

    public func runtimeSnapshot(): TlsRuntimeSnapshot {
        synchronized(mutex) {
            let current = handle
            if (current == 0u64) {
                throw TlsProviderException(TlsProviderErrorCode.Closed, "TLS provider is closed")
            }
            let target = unsafe {
                requiredString(wirestack_tls_provider_target_triple(current), "target triple")
            }
            let buildFingerprint = unsafe {
                requiredString(
                    wirestack_tls_provider_build_fingerprint(current),
                    "build fingerprint"
                )
            }
            let external = unsafe {
                wirestack_tls_provider_external_openssl_dependency(current)
            }
            if (external < 0) {
                throw TlsProviderException(
                    TlsProviderErrorCode.InvalidManifest,
                    "TLS provider returned no dependency identity"
                )
            }
            let systemTrust = try {
                let _ = LinuxSystemTrustAdapter.discover()
                true
            } catch (_: LinuxSystemTrustException) {
                false
            }
            let tlsVersions = ArrayList<String>()
            if (providerManifest.supports(TlsProviderCapability.Tls12)) {
                tlsVersions.add("1.2")
            }
            if (providerManifest.supports(TlsProviderCapability.Tls13)) {
                tlsVersions.add("1.3")
            }
            let httpVersions = ArrayList<String>()
            httpVersions.add("1.1")
            if (providerManifest.supports(TlsProviderCapability.Http2)) {
                httpVersions.add("2")
            }
            let flags = ArrayList<String>()
            if (providerManifest.supports(TlsProviderCapability.CustomRoots)) {
                flags.add("custom-roots")
            }
            if (providerManifest.supports(TlsProviderCapability.ClientCertificate)) {
                flags.add("client-certificate")
            }
            if (providerManifest.supports(TlsProviderCapability.Server)) {
                flags.add("server")
            }
            if (providerManifest.supports(TlsProviderCapability.ExternalSigner)) {
                flags.add("external-signer")
            }
            if (providerManifest.supports(TlsProviderCapability.SessionResumption)) {
                flags.add("session-resumption")
            }
            TlsRuntimeSnapshot(
                providerManifest,
                target,
                buildFingerprint,
                external != 0,
                if (systemTrust) { "linux-system" } else { "custom-roots-only" },
                tlsVersions.toArray(),
                httpVersions.toArray(),
                flags.toArray()
            )
        }
    }

    public func sessionStoreSnapshot(): TlsSessionStoreSnapshot { sessionStore.snapshot() }

    public func fillSecureRandom(output: Array<Byte>): Unit {
        synchronized(mutex) {
            if (handle == 0u64) {
                throw TlsProviderException(
                    TlsProviderErrorCode.Closed,
                    "TLS provider is closed"
                )
            }
            if (output.isEmpty()) {
                return
            }
            let status = unsafe {
                let raw = acquireArrayRawData(output)
                try {
                    wirestack_tls_provider_random(handle, raw.pointer, UInt64(output.size))
                } finally {
                    releaseArrayRawData(raw)
                }
            }
            if (status != PROVIDER_OK) {
                throw TlsProviderException(
                    TlsProviderErrorCode.SecureRandomFailed,
                    "secure random generation failed: ${status}"
                )
            }
        }
    }

    public func createEngine(role: TlsEngineRole, security: TlsSecurityPolicy): TlsEngine {
        synchronized(mutex) {
            if (handle == 0u64) {
                throw TlsProviderException(
                    TlsProviderErrorCode.Closed,
                    "TLS provider is closed"
                )
            }
            createNativeTlsEngine(handle, role, security, providerManifest)
        }
    }

    public func capabilities(): TlsCapabilities {
        try {
            let _ = LinuxSystemTrustAdapter.discover()
            TlsCapabilities.fromProvider(providerManifest, systemTrustAvailable: true)
        } catch (_: LinuxSystemTrustException) {
            TlsCapabilities.fromProvider(providerManifest)
        }
    }

    /**
     * Creates a verification-enabled client engine. SNI and reference identity
     * are separate inputs even when callers intentionally give them the same host.
     */
    public func createClientEngine(
        context: TlsClientContext,
        referenceIdentity: ReferenceIdentity,
        serverName!: ?HostName
    ): TlsEngine {
        createClientEngineWithTrustLocation(
            context,
            referenceIdentity,
            serverName: serverName
        )
    }

    public func createClientEngineWithTrustLocation(
        context: TlsClientContext,
        referenceIdentity: ReferenceIdentity,
        serverName!: ?HostName = None<HostName>,
        systemTrustLocation!: ?LinuxSystemTrustLocation = None<LinuxSystemTrustLocation>
    ): TlsEngine {
        synchronized(mutex) {
            if (handle == 0u64) {
                throw TlsProviderException(
                    TlsProviderErrorCode.Closed,
                    "TLS provider is closed"
                )
            }
            if (!context.providerManifest.sameProviderInstance(providerManifest)) {
                throw TlsProviderException(
                    TlsProviderErrorCode.ProviderMismatch,
                    "TLS context was built for a different provider instance identity"
                )
            }
            let resolvedSystemTrust = if (requiresSystemTrust(context.trust) &&
                systemTrustLocation.isNone()) {
                Some(LinuxSystemTrustAdapter.discover())
            } else {
                systemTrustLocation
            }
            let engine = NativeTlsEngine(
                handle,
                TlsEngineRole.Client,
                context.security,
                providerManifest
            )
            try {
                engine.configureClientAuthentication(
                    context.trust,
                    referenceIdentity,
                    serverName,
                    resolvedSystemTrust
                )
                engine.configureAlpn(context.alpnProtocols())
                if (let Some(identity) <- context.identity) {
                    engine.configureLocalIdentity(identity)
                }
                engine.configureSessionStore(
                    sessionStore,
                    clientSessionKey(context, referenceIdentity, resolvedSystemTrust)
                )
                engine
            } catch (error: Exception) {
                engine.close()
                throw error
            }
        }
    }

    /** Creates a server engine with an already validated immutable local identity. */
    public func createServerEngine(context: TlsServerContext): TlsEngine {
        createServerEngineWithTrustLocation(context)
    }

    public func createServerEngineWithTrustLocation(
        context: TlsServerContext,
        systemTrustLocation!: ?LinuxSystemTrustLocation = None<LinuxSystemTrustLocation>
    ): TlsEngine {
        synchronized(mutex) {
            if (handle == 0u64) {
                throw TlsProviderException(
                    TlsProviderErrorCode.Closed,
                    "TLS provider is closed"
                )
            }
            if (!context.providerManifest.sameProviderInstance(providerManifest)) {
                throw TlsProviderException(
                    TlsProviderErrorCode.ProviderMismatch,
                    "TLS context was built for a different provider instance identity"
                )
            }
            let resolvedSystemTrust = match (context.clientTrust) {
                case Some(trust) => if (requiresSystemTrust(trust) &&
                    systemTrustLocation.isNone()) {
                    Some(LinuxSystemTrustAdapter.discover())
                } else {
                    systemTrustLocation
                }
                case None => systemTrustLocation
            }
            let engine = NativeTlsEngine(
                handle,
                TlsEngineRole.Server,
                context.security,
                providerManifest
            )
            try {
                engine.configureLocalIdentity(context.identity)
                engine.configureAlpn(context.alpnProtocols())
                engine.configureClientAuthentication(
                    context.clientAuthentication,
                    context.clientTrust,
                    resolvedSystemTrust
                )
                engine.configureServerSessionIdContext(
                    serverSessionIdContext(context, resolvedSystemTrust)
                )
                engine
            } catch (error: Exception) {
                engine.close()
                throw error
            }
        }
    }

    /** Creates a server engine that selects a complete immutable context by exact SNI. */
    public func createServerEngine(selector: TlsServerContextSelector): TlsEngine {
        synchronized(mutex) {
            if (handle == 0u64) {
                throw TlsProviderException(
                    TlsProviderErrorCode.Closed,
                    "TLS provider is closed"
                )
            }
            if (!selector.providerManifest.sameProviderInstance(providerManifest)) {
                throw TlsProviderException(
                    TlsProviderErrorCode.ProviderMismatch,
                    "TLS SNI selector was built for a different provider identity"
                )
            }
            let engine = NativeTlsEngine(
                handle,
                TlsEngineRole.Server,
                selector.initialSecurityPolicy(),
                providerManifest
            )
            try {
                engine.configureServerNameSelection(selector)
                engine
            } catch (error: Exception) {
                engine.close()
                throw error
            }
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                unsafe { wirestack_tls_provider_destroy(current) }
                sessionStore.close()
            }
        }
    }

    ~init() {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            unsafe { wirestack_tls_provider_destroy(current) }
            sessionStore.close()
        }
    }
}

private func requiresSystemTrust(value: TrustPolicy): Bool {
    match (value.kind) {
        case TrustPolicyKind.System => true
        case TrustPolicyKind.SystemPlusCustomRoots => true
        case _ => false
    }
}
