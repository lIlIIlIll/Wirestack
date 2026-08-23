package wirestack.internal.tls_engine

import std.collection.*
import std.fs.*
import std.sync.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private let IDENTITY_NATIVE_OK: Int32 = 0
private let IDENTITY_NATIVE_INVALID: Int32 = 6
private let MAXIMUM_PKCS8_BYTES: Int64 = 256 * 1024
private let MAXIMUM_SPKI_BYTES: Int64 = 16 * 1024

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
foreign func wirestack_tls_identity_validate_spki(
    leafCertificate: CPointer<UInt8>,
    leafCertificateSize: UInt64,
    subjectPublicKeyInfo: CPointer<UInt8>,
    subjectPublicKeyInfoSize: UInt64
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
    | InvalidSigner
    | SignerFailure
}

public enum TlsSignatureAlgorithm {
    | RsaPssRsaeSha256
    | RsaPssRsaeSha384
    | RsaPssRsaeSha512
    | RsaPkcs1Sha256
    | RsaPkcs1Sha384
    | RsaPkcs1Sha512
    | EcdsaSecp256r1Sha256
    | EcdsaSecp384r1Sha384
    | EcdsaSecp521r1Sha512
    | Ed25519
}

/** Immutable request. The input is the exact TLS transcript bytes AWS-LC asks to sign. */
public struct ExternalSignatureRequest {
    public let algorithm: TlsSignatureAlgorithm
    private let message: Array<Byte>

    public init(algorithm: TlsSignatureAlgorithm, message: Array<Byte>) {
        if (message.isEmpty() || message.size > 64 * 1024) {
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidSigner,
                "external signature input must contain 1..65536 bytes"
            )
        }
        this.algorithm = algorithm
        this.message = message.clone()
    }

    public func messageBytes(): Array<Byte> { message.clone() }
}

/** Provider-neutral signer; implementations may wrap aliases or non-exportable handles. */
public interface ExternalSigner {
    func supportedAlgorithms(): Array<TlsSignatureAlgorithm>
    func sign(request: ExternalSignatureRequest, context: OperationContext): Array<Byte>
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
    private var publicKeyBytes: Array<Byte>
    private var algorithms: Array<TlsSignatureAlgorithm>
    private var signer: ?ExternalSigner
    private var closed = false

    internal init(
        kind: PrivateKeyKind,
        referenceIdentity: String,
        requiresHardwareKey: Bool,
        pkcs8Bytes: Array<Byte>,
        publicKeyBytes: Array<Byte>,
        algorithms: Array<TlsSignatureAlgorithm>,
        signer: ?ExternalSigner
    ) {
        this.kind = kind
        this.referenceIdentity = referenceIdentity
        this.requiresHardwareKey = requiresHardwareKey
        this.pkcs8Bytes = pkcs8Bytes
        this.publicKeyBytes = publicKeyBytes
        this.algorithms = algorithms
        this.signer = signer
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
            owned,
            [],
            [],
            None<ExternalSigner>
        )
    }

    public static func externalSigner(
        referenceIdentity: String,
        subjectPublicKeyInfoDer: Array<Byte>,
        signer: ExternalSigner
    ): PrivateKeyRef {
        createSignerReference(
            PrivateKeyKind.ExternalSigner,
            referenceIdentity,
            false,
            subjectPublicKeyInfoDer,
            signer
        )
    }

    /** Opaque platform alias/handle implemented through the common signer contract. */
    public static func systemHandle(
        platform: String,
        alias: String,
        subjectPublicKeyInfoDer: Array<Byte>,
        signer: ExternalSigner,
        hardwareBacked!: Bool = true
    ): PrivateKeyRef {
        if (platform.isEmpty() || alias.isEmpty() || platform.contains("\0") ||
            alias.contains("\0")) {
            throw PrivateKeyException(
                PrivateKeyErrorCode.InvalidSigner,
                "system private-key platform and alias must not be empty"
            )
        }
        createSignerReference(
            PrivateKeyKind.SystemHandle,
            "${platform}:${alias}",
            hardwareBacked,
            subjectPublicKeyInfoDer,
            signer
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

    internal func externalSignerReference(): ExternalSigner {
        synchronized(mutex) {
            if (closed) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.Closed,
                    "private key reference is closed"
                )
            }
            match (signer) {
                case Some(value) => value
                case None => throw PrivateKeyException(
                    PrivateKeyErrorCode.UnsupportedKeyKind,
                    "private key reference has no external signer"
                )
            }
        }
    }

    internal func signatureAlgorithms(): Array<TlsSignatureAlgorithm> {
        synchronized(mutex) {
            if (closed) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.Closed,
                    "private key reference is closed"
                )
            }
            algorithms.clone()
        }
    }

    internal func subjectPublicKeyInfoBytes(): Array<Byte> {
        synchronized(mutex) {
            if (closed) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.Closed,
                    "private key reference is closed"
                )
            }
            publicKeyBytes.clone()
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroBytes(pkcs8Bytes)
                zeroBytes(publicKeyBytes)
                pkcs8Bytes = Array<Byte>()
                publicKeyBytes = Array<Byte>()
                algorithms = Array<TlsSignatureAlgorithm>()
                signer = None<ExternalSigner>
                closed = true
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    ~init() {
        if (!closed) {
            zeroBytes(pkcs8Bytes)
            zeroBytes(publicKeyBytes)
            pkcs8Bytes = Array<Byte>()
            publicKeyBytes = Array<Byte>()
            algorithms = Array<TlsSignatureAlgorithm>()
            signer = None<ExternalSigner>
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
        match (privateKeyRef.kind) {
            case PrivateKeyKind.Pkcs8 => privateKeyRef.withPkcs8({key =>
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
            case _ =>
                let publicKey = privateKeyRef.subjectPublicKeyInfoBytes()
                let status = unsafe {
                    let certificateInput = acquireArrayRawData(leaf)
                    let publicKeyInput = acquireArrayRawData(publicKey)
                    try {
                        wirestack_tls_identity_validate_spki(
                            certificateInput.pointer,
                            UInt64(leaf.size),
                            publicKeyInput.pointer,
                            UInt64(publicKey.size)
                        )
                    } finally {
                        releaseArrayRawData(publicKeyInput)
                        releaseArrayRawData(certificateInput)
                    }
                }
                if (status != IDENTITY_NATIVE_OK) {
                    throw PrivateKeyException(
                        PrivateKeyErrorCode.KeyCertificateMismatch,
                        "leaf certificate does not match the external signer public key"
                    )
                }
        }
        this.certificateChain = certificateChain
        this.privateKeyRef = privateKeyRef
        contextIdentity = identityDigest(
            certificateChain,
            privateKeyRef.kind,
            privateKeyRef.referenceIdentity
        )
    }
}

private func identityDigest(
    chain: CertificateChain,
    kind: PrivateKeyKind,
    referenceIdentity: String
): String {
    let material = ArrayList<Byte>()
    material.add(privateKeyKindByte(kind))
    let referenceBytes = referenceIdentity.toArray()
    appendIdentityLength(material, referenceBytes.size)
    material.add(all: referenceBytes)
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

private func createSignerReference(
    kind: PrivateKeyKind,
    referenceIdentity: String,
    requiresHardwareKey: Bool,
    subjectPublicKeyInfoDer: Array<Byte>,
    signer: ExternalSigner
): PrivateKeyRef {
    if (referenceIdentity.isEmpty() || referenceIdentity.contains("\0") ||
        subjectPublicKeyInfoDer.isEmpty() ||
        subjectPublicKeyInfoDer.size > MAXIMUM_SPKI_BYTES) {
        throw PrivateKeyException(
            PrivateKeyErrorCode.InvalidSigner,
            "external signer identity and SubjectPublicKeyInfo must be bounded"
        )
    }
    let supported = try {
        signer.supportedAlgorithms()
    } catch (_: Exception) {
        throw PrivateKeyException(
            PrivateKeyErrorCode.InvalidSigner,
            "external signer failed while reporting algorithms"
        )
    }
    if (supported.isEmpty() || supported.size > 16) {
        throw PrivateKeyException(
            PrivateKeyErrorCode.InvalidSigner,
            "external signer must report 1..16 signature algorithms"
        )
    }
    for (index in 0..supported.size) {
        for (prior in 0..index) {
            if (nativeSignatureAlgorithm(supported[index]) ==
                nativeSignatureAlgorithm(supported[prior])) {
                throw PrivateKeyException(
                    PrivateKeyErrorCode.InvalidSigner,
                    "external signer algorithms must not repeat"
                )
            }
        }
    }
    PrivateKeyRef(
        kind,
        referenceIdentity,
        requiresHardwareKey,
        [],
        subjectPublicKeyInfoDer.clone(),
        supported.clone(),
        Some(signer)
    )
}

internal func nativeSignatureAlgorithm(value: TlsSignatureAlgorithm): UInt16 {
    match (value) {
        case TlsSignatureAlgorithm.RsaPssRsaeSha256 => 0x0804
        case TlsSignatureAlgorithm.RsaPssRsaeSha384 => 0x0805
        case TlsSignatureAlgorithm.RsaPssRsaeSha512 => 0x0806
        case TlsSignatureAlgorithm.RsaPkcs1Sha256 => 0x0401
        case TlsSignatureAlgorithm.RsaPkcs1Sha384 => 0x0501
        case TlsSignatureAlgorithm.RsaPkcs1Sha512 => 0x0601
        case TlsSignatureAlgorithm.EcdsaSecp256r1Sha256 => 0x0403
        case TlsSignatureAlgorithm.EcdsaSecp384r1Sha384 => 0x0503
        case TlsSignatureAlgorithm.EcdsaSecp521r1Sha512 => 0x0603
        case TlsSignatureAlgorithm.Ed25519 => 0x0807
    }
}

internal func tlsSignatureAlgorithmFromNative(value: UInt16): TlsSignatureAlgorithm {
    if (value == 0x0804) { TlsSignatureAlgorithm.RsaPssRsaeSha256 }
    else if (value == 0x0805) { TlsSignatureAlgorithm.RsaPssRsaeSha384 }
    else if (value == 0x0806) { TlsSignatureAlgorithm.RsaPssRsaeSha512 }
    else if (value == 0x0401) { TlsSignatureAlgorithm.RsaPkcs1Sha256 }
    else if (value == 0x0501) { TlsSignatureAlgorithm.RsaPkcs1Sha384 }
    else if (value == 0x0601) { TlsSignatureAlgorithm.RsaPkcs1Sha512 }
    else if (value == 0x0403) { TlsSignatureAlgorithm.EcdsaSecp256r1Sha256 }
    else if (value == 0x0503) { TlsSignatureAlgorithm.EcdsaSecp384r1Sha384 }
    else if (value == 0x0603) { TlsSignatureAlgorithm.EcdsaSecp521r1Sha512 }
    else if (value == 0x0807) { TlsSignatureAlgorithm.Ed25519 }
    else {
        throw PrivateKeyException(
            PrivateKeyErrorCode.InvalidSigner,
            "TLS provider requested an unsupported signature algorithm"
        )
    }
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
