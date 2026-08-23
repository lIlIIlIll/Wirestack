package wirestack.internal.tls_engine

import std.collection.*
import std.fs.*
import std.sync.*
import wirestack.internal.trust.*

private let IDENTITY_NATIVE_OK: Int32 = 0
private let IDENTITY_NATIVE_INVALID: Int32 = 6
private let MAXIMUM_PKCS8_BYTES: Int64 = 256 * 1024

foreign func wirestack_tls_private_key_validate_pkcs8(
    input: CPointer<UInt8>,
    size: UInt64
): Int32
foreign func wirestack_tls_identity_validate_pkcs8(
    leafCertificate: CPointer<UInt8>,
    leafCertificateSize: UInt64,
    privateKey: CPointer<UInt8>,
    privateKeySize: UInt64
): Int32
foreign func wirestack_tls_sha256(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>
): Int32

public enum PrivateKeyKind {
    | Pkcs8
    | SystemHandle
    | ExternalSigner
}

public enum PrivateKeyErrorCode {
    | InvalidPkcs8
    | InvalidFile
    | KeyCertificateMismatch
    | Closed
    | UnsupportedKeyKind
}

/** Stable private-key failure which never contains key material or native handles. */
public class PrivateKeyException <: Exception {
    public let code: PrivateKeyErrorCode

    public init(code: PrivateKeyErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "PrivateKeyException" }
}

/**
 * Opaque private-key reference. PKCS#8 bytes remain instance-owned, are copied
 * only for one native configuration call, and are zeroed on close.
 */
public class PrivateKeyRef <: Resource {
    private let mutex = Mutex()
    public let kind: PrivateKeyKind
    public let referenceIdentity: String
    public let requiresHardwareKey: Bool
    private var pkcs8Bytes: Array<Byte>
    private var closed = false

    private init(
        kind: PrivateKeyKind,
        referenceIdentity: String,
        requiresHardwareKey: Bool,
        pkcs8Bytes: Array<Byte>
    ) {
        this.kind = kind
        this.referenceIdentity = referenceIdentity
        this.requiresHardwareKey = requiresHardwareKey
        this.pkcs8Bytes = pkcs8Bytes
    }

    public static func pkcs8(bytes: Array<Byte>): PrivateKeyRef {
        if (bytes.isEmpty() || bytes.size > MAXIMUM_PKCS8_BYTES) {
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidPkcs8,
                "PKCS#8 private key must contain 1..${MAXIMUM_PKCS8_BYTES} bytes"
            )
        }
        let owned = bytes.clone()
        let status = unsafe {
            let input = acquireArrayRawData(owned)
            try {
                wirestack_tls_private_key_validate_pkcs8(input.pointer, UInt64(owned.size))
            } finally {
                releaseArrayRawData(input)
            }
        }
        if (status != IDENTITY_NATIVE_OK) {
            zeroBytes(owned)
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidPkcs8,
                "private key is not one exact unencrypted DER PKCS#8 object"
            )
        }
        PrivateKeyRef(
            PrivateKeyKind.Pkcs8,
            "pkcs8",
            false,
            owned
        )
    }

    /** Loads one bounded, readable, regular DER PKCS#8 file without retaining its path. */
    public static func pkcs8File(path: String): PrivateKeyRef {
        if (path.isEmpty() || path.contains("\0") || !Path(path).isAbsolute()) {
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidFile,
                "PKCS#8 private key path must be a non-empty absolute path"
            )
        }
        try {
            let info = FileInfo(path)
            if (!info.isRegular() || !info.canRead() || info.size <= 0 ||
                info.size > MAXIMUM_PKCS8_BYTES) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.InvalidFile,
                    "PKCS#8 private key file must be readable, regular, and bounded"
                )
            }
            let contents = File.readFrom(path)
            try {
                if (contents.size != info.size) {
                    throw PrivateKeyException(
                        PrivateKeyErrorCode.InvalidFile,
                        "PKCS#8 private key file changed while being read"
                    )
                }
                PrivateKeyRef.pkcs8(contents)
            } finally {
                zeroBytes(contents)
            }
        } catch (error: PrivateKeyException) {
            throw error
        } catch (_: Exception) {
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidFile,
                "PKCS#8 private key file could not be read"
            )
        }
    }

    internal func withPkcs8(action: (Array<Byte>) -> Unit): Unit {
        synchronized(mutex) {
            if (closed) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.Closed,
                    "private key reference is closed"
                )
            }
            match (kind) {
                case PrivateKeyKind.Pkcs8 =>
                    let transient = pkcs8Bytes.clone()
                    try {
                        action(transient)
                    } finally {
                        zeroBytes(transient)
                    }
                case _ => throw PrivateKeyException(
                    PrivateKeyErrorCode.UnsupportedKeyKind,
                    "private key kind is not available through the PKCS#8 adapter"
                )
            }
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroBytes(pkcs8Bytes)
                pkcs8Bytes = Array<Byte>()
                closed = true
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    ~init() {
        if (!closed) {
            zeroBytes(pkcs8Bytes)
            pkcs8Bytes = Array<Byte>()
            closed = true
        }
    }
}

/** Immutable certificate-chain/private-key association. */
public class LocalIdentity {
    public let certificateChain: CertificateChain
    public let privateKeyRef: PrivateKeyRef
    public let contextIdentity: String

    public init(certificateChain: CertificateChain, privateKeyRef: PrivateKeyRef) {
        let leaf = certificateChain.certificateAt(0).derBytes()
        privateKeyRef.withPkcs8({key =>
            let status = unsafe {
                let certificateInput = acquireArrayRawData(leaf)
                let keyInput = acquireArrayRawData(key)
                try {
                    wirestack_tls_identity_validate_pkcs8(
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
            if (status == IDENTITY_NATIVE_INVALID) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.KeyCertificateMismatch,
                    "leaf certificate does not match the PKCS#8 private key"
                )
            }
            if (status != IDENTITY_NATIVE_OK) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.InvalidPkcs8,
                    "TLS provider rejected the local identity"
                )
            }
        })
        this.certificateChain = certificateChain
        this.privateKeyRef = privateKeyRef
        contextIdentity = identityDigest(certificateChain, privateKeyRef.kind)
    }
}

private func identityDigest(chain: CertificateChain, kind: PrivateKeyKind): String {
    let material = ArrayList<Byte>()
    material.add(privateKeyKindByte(kind))
    for (certificate in chain.certificates()) {
        let der = certificate.derBytes()
        appendIdentityLength(material, der.size)
        material.add(all: der)
    }
    let inputBytes = material.toArray()
    let digest = Array<Byte>(32, repeat: 0)
    let status = unsafe {
        let input = acquireArrayRawData(inputBytes)
        let output = acquireArrayRawData(digest)
        try {
            wirestack_tls_sha256(input.pointer, UInt64(inputBytes.size), output.pointer)
        } finally {
            releaseArrayRawData(output)
            releaseArrayRawData(input)
        }
    }
    if (status != IDENTITY_NATIVE_OK) {
        throw PrivateKeyException(
            PrivateKeyErrorCode.InvalidPkcs8,
            "failed to derive local identity"
        )
    }
    let alphabet = "0123456789abcdef".toArray()
    let encoded = ArrayList<Byte>()
    for (value in digest) {
        encoded.add(alphabet[Int64(value >> 4)])
        encoded.add(alphabet[Int64(value & 0x0f)])
    }
    String.fromUtf8(encoded.toArray())
}

private func privateKeyKindByte(kind: PrivateKeyKind): Byte {
    match (kind) {
        case PrivateKeyKind.Pkcs8 => 1
        case PrivateKeyKind.SystemHandle => 2
        case PrivateKeyKind.ExternalSigner => 3
    }
}

private func appendIdentityLength(output: ArrayList<Byte>, value: Int64): Unit {
    let converted = UInt64(value)
    for (shift in [56u64, 48u64, 40u64, 32u64, 24u64, 16u64, 8u64, 0u64]) {
        output.add(UInt8((converted >> shift) & 0xffu64))
    }
}

private func zeroBytes(bytes: Array<Byte>): Unit {
    for (index in 0..bytes.size) { bytes[index] = 0 }
}
