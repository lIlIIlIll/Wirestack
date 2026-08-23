package wirestack.internal.tls_engine

import std.sync.*

private let PROVIDER_OK: Int32 = 0

private let CAP_CUSTOM_ROOTS: UInt64 = 1u64 << 0
private let CAP_CLIENT_CERT: UInt64 = 1u64 << 1
private let CAP_SERVER: UInt64 = 1u64 << 2
private let CAP_TLS12: UInt64 = 1u64 << 3
private let CAP_TLS13: UInt64 = 1u64 << 4
private let CAP_HTTP2: UInt64 = 1u64 << 5
private let CAP_EXTERNAL_SIGNER: UInt64 = 1u64 << 6
private let CAP_SESSION_RESUMPTION: UInt64 = 1u64 << 7
private let CAP_SECURE_RANDOM: UInt64 = 1u64 << 8

foreign func wirestack_tls_provider_create(outHandle: CPointer<UInt64>): Int32
foreign func wirestack_tls_provider_destroy(handle: UInt64): Unit
foreign func wirestack_tls_provider_id(handle: UInt64): CString
foreign func wirestack_tls_provider_version(handle: UInt64): CString
foreign func wirestack_tls_provider_fingerprint(handle: UInt64): CString
foreign func wirestack_tls_provider_backend(handle: UInt64): CString
foreign func wirestack_tls_provider_patch_level(handle: UInt64): CString
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
    | Closed
    | SecureRandomFailed
}

public class TlsProviderException <: Exception {
    public let code: TlsProviderErrorCode

    public init(code: TlsProviderErrorCode, message: String) {
        super(message)
        this.code = code
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

    public init(
        providerId: String,
        version: String,
        fingerprint: String,
        backend: String,
        patchLevel: String,
        capabilityBits: UInt64
    ) {
        if (providerId.isEmpty() || version.isEmpty() || fingerprint.isEmpty() ||
            backend.isEmpty() || patchLevel.isEmpty()) {
            throw IllegalArgumentException("TLS provider manifest fields must not be empty")
        }
        this.providerId = providerId
        this.version = version
        this.fingerprint = fingerprint
        this.backend = backend
        this.patchLevel = patchLevel
        this.capabilityBits = capabilityBits
    }

    public func supports(capability: TlsProviderCapability): Bool {
        (capabilityBits & capabilityMask(capability)) != 0u64
    }
}

/** Internal provider SPI. No native handle crosses this boundary. */
public interface TlsProvider {
    func manifest(): TlsProviderManifest
    func fillSecureRandom(output: Array<Byte>): Unit
    func close(): Unit
}

private func requiredString(value: CString, field: String): String {
    if (value.getChars().isNull()) {
        throw TlsProviderException(
            TlsProviderErrorCode.InvalidManifest,
            "TLS provider returned no ${field}"
        )
    }
    value.toString()
}

/** Instance-owned Linux AWS-LC provider. */
public class AwsLcTlsProvider <: TlsProvider {
    private let mutex = Mutex()
    private var handle: UInt64
    private let providerManifest: TlsProviderManifest

    public init() {
        let out = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let raw = acquireArrayRawData(out)
            try { wirestack_tls_provider_create(raw.pointer) }
            finally { releaseArrayRawData(raw) }
        }
        if (status != PROVIDER_OK || out[0] == 0u64) {
            throw TlsProviderException(
                TlsProviderErrorCode.InitializationFailed,
                "failed to create Linux TLS provider: ${status}"
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
                    wirestack_tls_provider_capabilities(handle)
                )
            }
        } catch (error: Exception) {
            unsafe { wirestack_tls_provider_destroy(handle) }
            handle = 0u64
            throw error
        }
    }

    public func manifest(): TlsProviderManifest { providerManifest }

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

    public func close(): Unit {
        synchronized(mutex) {
            let current = handle
            if (current != 0u64) {
                handle = 0u64
                unsafe { wirestack_tls_provider_destroy(current) }
            }
        }
    }

    ~init() {
        let current = handle
        if (current != 0u64) {
            handle = 0u64
            unsafe { wirestack_tls_provider_destroy(current) }
        }
    }
}
