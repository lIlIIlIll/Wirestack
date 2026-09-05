package wirestack

import std.collection.*

foreign func wirestack_tls_sha256(
    input: CPointer<UInt8>,
    size: UInt64,
    output: CPointer<UInt8>
): Int32
foreign func wirestack_tls_certificate_validate_der(
    input: CPointer<UInt8>,
    size: UInt64,
    maximumExtensions: UInt64,
    outputExtensionCount: CPointer<UInt64>
): Int32

private let NATIVE_OK: Int32 = 0
private let NATIVE_CERTIFICATE_INVALID: Int32 = 6
private let NATIVE_LIMIT_EXCEEDED: Int32 = 7
private let HARD_MAXIMUM_CHAIN_LENGTH: Int64 = 16
private let HARD_MAXIMUM_CERTIFICATE_BYTES: Int64 = 256 * 1024
private let HARD_MAXIMUM_CHAIN_BYTES: Int64 = 1024 * 1024
private let HARD_MAXIMUM_EXTENSIONS: Int64 = 128

/**
 * Wirestack 公开 API：TrustPolicyKind。
 */
public enum TrustPolicyKind {
/**
 * Wirestack 公开 API：System。
 */
    | System
/**
 * Wirestack 公开 API：CustomRoots。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：SystemPlusCustomRoots。
 */
    | SystemPlusCustomRoots
/**
 * Wirestack 公开 API：PinnedPublicKeys。
 */
    | PinnedPublicKeys
}

/**
 * Wirestack 公开 API：TrustAnchorSource。
 */
public enum TrustAnchorSource {
/**
 * Wirestack 公开 API：System。
 */
    | System
/**
 * Wirestack 公开 API：CustomRoots。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：SystemPlusCustomRoots。
 */
    | SystemPlusCustomRoots
/**
 * Wirestack 公开 API：PublicKeyPin。
 */
    | PublicKeyPin
}

/**
 * Wirestack 公开 API：TrustVerificationStatus。
 */
public enum TrustVerificationStatus {
/**
 * Wirestack 公开 API：Verified。
 */
    | Verified
/**
 * Wirestack 公开 API：UntrustedChain。
 */
    | UntrustedChain
/**
 * Wirestack 公开 API：IdentityMismatch。
 */
    | IdentityMismatch
/**
 * Wirestack 公开 API：PinMismatch。
 */
    | PinMismatch
/**
 * Wirestack 公开 API：InvalidCertificate。
 */
    | InvalidCertificate
}

/**
 * Wirestack 公开 API：CertificateInputErrorCode。
 */
public enum CertificateInputErrorCode {
/**
 * Wirestack 公开 API：EmptyChain。
 */
    | EmptyChain
/**
 * Wirestack 公开 API：ChainTooLong。
 */
    | ChainTooLong
/**
 * Wirestack 公开 API：CertificateTooLarge。
 */
    | CertificateTooLarge
/**
 * Wirestack 公开 API：ChainTooLarge。
 */
    | ChainTooLarge
/**
 * Wirestack 公开 API：TooManyExtensions。
 */
    | TooManyExtensions
/**
 * Wirestack 公开 API：DuplicateCertificate。
 */
    | DuplicateCertificate
/**
 * Wirestack 公开 API：InvalidDer。
 */
    | InvalidDer
/**
 * Wirestack 公开 API：InvalidLimit。
 */
    | InvalidLimit
}

/**
 * Wirestack 公开 API：CertificateInputException。
 */
public class CertificateInputException <: Exception {
/**
 * Wirestack 公开 API：code。
 */
    public let code: CertificateInputErrorCode
/**
 * Wirestack 公开 API：certificateIndex。
 */
    public let certificateIndex: ?Int64

/**
 * Wirestack 公开 API：init。
 * @param certificateIndex 参数 certificateIndex。
 * @param code 参数 code。
 * @param message 参数 message。
 */
    public init(
        code: CertificateInputErrorCode,
        message: String,
        certificateIndex!: ?Int64 = None<Int64>
    ) {
        super(message)
        this.code = code
        this.certificateIndex = certificateIndex
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "CertificateInputException" }
}

/** Hard-bounded X.509 input limits. Callers may only make them stricter. */
public struct CertificateInputLimits {
/**
 * Wirestack 公开 API：maximumChainLength。
 */
    public let maximumChainLength: Int64
/**
 * Wirestack 公开 API：maximumCertificateBytes。
 */
    public let maximumCertificateBytes: Int64
/**
 * Wirestack 公开 API：maximumChainBytes。
 */
    public let maximumChainBytes: Int64
/**
 * Wirestack 公开 API：maximumExtensions。
 */
    public let maximumExtensions: Int64

/**
 * Wirestack 公开 API：init。
 * @param maximumCertificateBytes 参数 maximumCertificateBytes。
 * @param maximumChainBytes 参数 maximumChainBytes。
 * @param maximumChainLength 参数 maximumChainLength。
 * @param maximumExtensions 参数 maximumExtensions。
 */
    public init(
        maximumChainLength!: Int64 = 10,
        maximumCertificateBytes!: Int64 = 256 * 1024,
        maximumChainBytes!: Int64 = 1024 * 1024,
        maximumExtensions!: Int64 = 128
    ) {
        if (maximumChainLength <= 0 || maximumChainLength > HARD_MAXIMUM_CHAIN_LENGTH ||
            maximumCertificateBytes <= 0 ||
            maximumCertificateBytes > HARD_MAXIMUM_CERTIFICATE_BYTES ||
            maximumChainBytes <= 0 || maximumChainBytes > HARD_MAXIMUM_CHAIN_BYTES ||
            maximumCertificateBytes > maximumChainBytes ||
            maximumExtensions <= 0 || maximumExtensions > HARD_MAXIMUM_EXTENSIONS) {
            throw CertificateInputException(
                CertificateInputErrorCode.InvalidLimit,
                "certificate limits must be positive and cannot exceed Wirestack hard limits"
            )
        }
        this.maximumChainLength = maximumChainLength
        this.maximumCertificateBytes = maximumCertificateBytes
        this.maximumChainBytes = maximumChainBytes
        this.maximumExtensions = maximumExtensions
    }
}

/** Provider-neutral immutable DER certificate after full native X.509 parsing. */
public struct DerCertificate {
    private let encoded: Array<Byte>
/**
 * Wirestack 公开 API：extensionCount。
 */
    public let extensionCount: Int64

/**
 * Wirestack 公开 API：init。
 * @param bytes 参数 bytes。
 * @param limits 参数 limits。
 */
    public init(
        bytes: Array<Byte>,
        limits!: CertificateInputLimits = CertificateInputLimits()
    ) {
        if (bytes.isEmpty() || bytes.size > limits.maximumCertificateBytes) {
            throw CertificateInputException(
                CertificateInputErrorCode.CertificateTooLarge,
                "certificate DER must contain 1..${limits.maximumCertificateBytes} bytes"
            )
        }
        let extensionCountOutput = Array<UInt64>(1, repeat: 0u64)
        let status = unsafe {
            let input = acquireArrayRawData(bytes)
            let output = acquireArrayRawData(extensionCountOutput)
            try {
                wirestack_tls_certificate_validate_der(
                    input.pointer,
                    UInt64(bytes.size),
                    UInt64(limits.maximumExtensions),
                    output.pointer
                )
            } finally {
                releaseArrayRawData(output)
                releaseArrayRawData(input)
            }
        }
        if (status == NATIVE_LIMIT_EXCEEDED) {
            throw CertificateInputException(
                CertificateInputErrorCode.TooManyExtensions,
                "certificate exceeds the configured extension limit"
            )
        }
        if (status == NATIVE_CERTIFICATE_INVALID) {
            throw CertificateInputException(
                CertificateInputErrorCode.InvalidDer,
                "certificate is not one exact DER-encoded X.509 object"
            )
        }
        if (status != NATIVE_OK) {
            throw CertificateInputException(
                CertificateInputErrorCode.InvalidDer,
                "certificate parser rejected the input"
            )
        }
        encoded = bytes.clone()
        extensionCount = Int64(extensionCountOutput[0])
    }

/**
 * Wirestack 公开 API：derBytes。
 */
    public func derBytes(): Array<Byte> { encoded.clone() }

/**
 * Wirestack 公开 API：subjectAlternativeNames。
 */
    public func subjectAlternativeNames(): CertificateSubjectAlternativeNames {
        parseCertificateSubjectAlternativeNames(encoded)
    }
}

/** A leaf-first immutable certificate chain with aggregate resource bounds. */
public class CertificateChain {
    private let entries: Array<DerCertificate>
/**
 * Wirestack 公开 API：totalBytes。
 */
    public let totalBytes: Int64

/**
 * Wirestack 公开 API：init。
 * @param certificates 参数 certificates。
 * @param limits 参数 limits。
 */
    public init(
        certificates: Array<DerCertificate>,
        limits!: CertificateInputLimits = CertificateInputLimits()
    ) {
        if (certificates.isEmpty()) {
            throw CertificateInputException(
                CertificateInputErrorCode.EmptyChain,
                "certificate chain must not be empty"
            )
        }
        if (certificates.size > limits.maximumChainLength) {
            throw CertificateInputException(
                CertificateInputErrorCode.ChainTooLong,
                "certificate chain exceeds the configured chain-length limit"
            )
        }
        var count: Int64 = 0
        for ((index, certificate) in certificates.enumerate()) {
            let bytes = certificate.derBytes()
            let size = bytes.size
            if (size > limits.maximumCertificateBytes) {
                throw CertificateInputException(
                    CertificateInputErrorCode.CertificateTooLarge,
                    "certificate exceeds the configured per-certificate limit",
                    certificateIndex: Some(Int64(index))
                )
            }
            if (count > limits.maximumChainBytes - size) {
                throw CertificateInputException(
                    CertificateInputErrorCode.ChainTooLarge,
                    "certificate chain exceeds the configured aggregate-byte limit",
                    certificateIndex: Some(Int64(index))
                )
            }
            for (prior in 0..index) {
                if (certificates[prior].derBytes() == bytes) {
                    throw CertificateInputException(
                        CertificateInputErrorCode.DuplicateCertificate,
                        "certificate chain must not contain duplicate DER objects",
                        certificateIndex: Some(Int64(index))
                    )
                }
            }
            count += size
        }
        entries = certificates.clone()
        totalBytes = count
    }

/**
 * Wirestack 公开 API：size。
 */
    public func size(): Int64 { entries.size }
/**
 * Wirestack 公开 API：certificateAt。
 * @param index 参数 index。
 */
    public func certificateAt(index: Int64): DerCertificate { entries[index] }
/**
 * Wirestack 公开 API：certificates。
 */
    public func certificates(): Array<DerCertificate> { entries.clone() }
}

/**
 * Wirestack 公开 API：PinScope。
 */
public enum PinScope {
/**
 * Wirestack 公开 API：LeafSubjectPublicKeyInfo。
 */
    | LeafSubjectPublicKeyInfo
/**
 * Wirestack 公开 API：AnyCertificateSubjectPublicKeyInfo。
 */
    | AnyCertificateSubjectPublicKeyInfo
}

/** SHA-256 digest of a DER SubjectPublicKeyInfo, never a certificate digest. */
public struct SpkiSha256Pin {
    private let digest: Array<Byte>
/**
 * Wirestack 公开 API：scope。
 */
    public let scope: PinScope

/**
 * Wirestack 公开 API：init。
 * @param digest 参数 digest。
 * @param scope 参数 scope。
 */
    public init(digest: Array<Byte>, scope!: PinScope = PinScope.LeafSubjectPublicKeyInfo) {
        if (digest.size != 32) {
            throw IllegalArgumentException("SPKI SHA-256 pin must contain exactly 32 bytes")
        }
        this.digest = digest.clone()
        this.scope = scope
    }

/**
 * Wirestack 公开 API：digestBytes。
 */
    public func digestBytes(): Array<Byte> { digest.clone() }
}

/** Immutable trust configuration; there is deliberately no TrustAll variant. */
public class TrustPolicy {
/**
 * Wirestack 公开 API：kind。
 */
    public let kind: TrustPolicyKind
/**
 * Wirestack 公开 API：contextIdentity。
 */
    public let contextIdentity: String
    private let roots: ?CertificateChain
    private let publicKeyPins: Array<SpkiSha256Pin>

    private init(
        kind: TrustPolicyKind,
        roots: ?CertificateChain,
        pins: Array<SpkiSha256Pin>
    ) {
        this.kind = kind
        this.roots = roots
        publicKeyPins = pins.clone()
        contextIdentity = digestHex(trustIdentityMaterial(kind, roots, pins))
    }

/**
 * Wirestack 公开 API：system。
 */
    public static func system(): TrustPolicy {
        TrustPolicy(TrustPolicyKind.System, None<CertificateChain>, [])
    }

/**
 * Wirestack 公开 API：customRoots。
 * @param roots 参数 roots。
 */
    public static func customRoots(roots: CertificateChain): TrustPolicy {
        TrustPolicy(TrustPolicyKind.CustomRoots, Some(roots), [])
    }

/**
 * Wirestack 公开 API：systemPlusCustomRoots。
 * @param roots 参数 roots。
 */
    public static func systemPlusCustomRoots(roots: CertificateChain): TrustPolicy {
        TrustPolicy(TrustPolicyKind.SystemPlusCustomRoots, Some(roots), [])
    }

/**
 * Wirestack 公开 API：pinnedPublicKeys。
 * @param pins 参数 pins。
 */
    public static func pinnedPublicKeys(pins: Array<SpkiSha256Pin>): TrustPolicy {
        if (pins.isEmpty() || pins.size > 32) {
            throw IllegalArgumentException("pinned-public-key trust requires 1..32 pins")
        }
        for (index in 0..pins.size) {
            for (prior in 0..index) {
                if (pins[index].digestBytes() == pins[prior].digestBytes() &&
                    pinScopeByte(pins[index].scope) == pinScopeByte(pins[prior].scope)) {
                    throw IllegalArgumentException("pinned-public-key trust must not repeat pins")
                }
            }
        }
        TrustPolicy(TrustPolicyKind.PinnedPublicKeys, None<CertificateChain>, pins)
    }

/**
 * Wirestack 公开 API：customRootChain。
 */
    public func customRootChain(): ?CertificateChain { roots }
/**
 * Wirestack 公开 API：pins。
 */
    public func pins(): Array<SpkiSha256Pin> { publicKeyPins.clone() }
}

/** Stable diagnostic result with no native certificate/provider object. */
public struct TrustVerificationEvidence {
/**
 * Wirestack 公开 API：status。
 */
    public let status: TrustVerificationStatus
/**
 * Wirestack 公开 API：trustSource。
 */
    public let trustSource: TrustAnchorSource
/**
 * Wirestack 公开 API：trustContextIdentity。
 */
    public let trustContextIdentity: String
/**
 * Wirestack 公开 API：peerChainLength。
 */
    public let peerChainLength: Int64
/**
 * Wirestack 公开 API：matchedPinIndex。
 */
    public let matchedPinIndex: ?Int64
/**
 * Wirestack 公开 API：verifiedReferenceIdentity。
 */
    public let verifiedReferenceIdentity: ?String

/**
 * Wirestack 公开 API：init。
 * @param matchedPinIndex 参数 matchedPinIndex。
 * @param peerChainLength 参数 peerChainLength。
 * @param status 参数 status。
 * @param trustContextIdentity 参数 trustContextIdentity。
 * @param trustSource 参数 trustSource。
 * @param verifiedReferenceIdentity 参数 verifiedReferenceIdentity。
 */
    public init(
        status: TrustVerificationStatus,
        trustSource: TrustAnchorSource,
        trustContextIdentity: String,
        peerChainLength: Int64,
        matchedPinIndex!: ?Int64 = None<Int64>,
        verifiedReferenceIdentity!: ?String = None<String>
    ) {
        if (trustContextIdentity.isEmpty() || peerChainLength < 0) {
            throw IllegalArgumentException("trust evidence identity and chain length are invalid")
        }
        this.status = status
        this.trustSource = trustSource
        this.trustContextIdentity = trustContextIdentity
        this.peerChainLength = peerChainLength
        this.matchedPinIndex = matchedPinIndex
        this.verifiedReferenceIdentity = verifiedReferenceIdentity
    }
}

private func trustIdentityMaterial(
    kind: TrustPolicyKind,
    roots: ?CertificateChain,
    pins: Array<SpkiSha256Pin>
): Array<Byte> {
    let output = ArrayList<Byte>()
    output.add(trustKindByte(kind))
    match (roots) {
        case Some(chain) =>
            appendLength(output, chain.size())
            for (certificate in chain.certificates()) {
                let bytes = certificate.derBytes()
                appendLength(output, bytes.size)
                output.add(all: bytes)
            }
        case None => appendLength(output, 0)
    }
    appendLength(output, pins.size)
    for (pin in pins) {
        output.add(pinScopeByte(pin.scope))
        output.add(all: pin.digestBytes())
    }
    output.toArray()
}

private func appendLength(output: ArrayList<Byte>, value: Int64): Unit {
    for (shift in [56, 48, 40, 32, 24, 16, 8, 0]) {
        output.add(UInt8((UInt64(value) >> UInt64(shift)) & 0xffu64))
    }
}

private func trustKindByte(value: TrustPolicyKind): Byte {
    match (value) {
        case TrustPolicyKind.System => 1
        case TrustPolicyKind.CustomRoots => 2
        case TrustPolicyKind.SystemPlusCustomRoots => 3
        case TrustPolicyKind.PinnedPublicKeys => 4
    }
}

private func pinScopeByte(value: PinScope): Byte {
    match (value) {
        case PinScope.LeafSubjectPublicKeyInfo => 1
        case PinScope.AnyCertificateSubjectPublicKeyInfo => 2
    }
}

private func digestHex(input: Array<Byte>): String {
    let digest = Array<Byte>(32, repeat: 0)
    let status = unsafe {
        let source = acquireArrayRawData(input)
        let destination = acquireArrayRawData(digest)
        try {
            wirestack_tls_sha256(source.pointer, UInt64(input.size), destination.pointer)
        } finally {
            releaseArrayRawData(destination)
            releaseArrayRawData(source)
        }
    }
    if (status != NATIVE_OK) {
        throw IllegalStateException("failed to compute trust-context identity")
    }
    let encoded = Array<Byte>(64, repeat: 0)
    let digits: Array<Byte> = "0123456789abcdef".toArray()
    for ((index, value) in digest.enumerate()) {
        encoded[index * 2] = digits[Int64(value >> 4)]
        encoded[index * 2 + 1] = digits[Int64(value & 0x0f)]
    }
    String.fromUtf8(encoded)
}
