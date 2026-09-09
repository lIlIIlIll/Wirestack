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
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TrustPolicyKind {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | System
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemPlusCustomRoots
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | PinnedPublicKeys
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TrustAnchorSource {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | System
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemPlusCustomRoots
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | PublicKeyPin
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TrustVerificationStatus {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Verified
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | UntrustedChain
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | IdentityMismatch
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | PinMismatch
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidCertificate
}

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum CertificateInputErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | EmptyChain
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ChainTooLong
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | CertificateTooLarge
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ChainTooLarge
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TooManyExtensions
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | DuplicateCertificate
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidDer
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidLimit
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class CertificateInputException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: CertificateInputErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let certificateIndex: ?Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param certificateIndex 证书链中的零基索引。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
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
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "CertificateInputException" }
}

/** Hard-bounded X.509 input limits. Callers may only make them stricter. */
public struct CertificateInputLimits {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumChainLength: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumCertificateBytes: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumChainBytes: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumExtensions: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param maximumCertificateBytes 单个证书允许占用的最大字节数。
 * @param maximumChainBytes 证书链允许占用的最大字节数。
 * @param maximumChainLength 证书链允许的最大长度。
 * @param maximumExtensions 单个证书允许包含的最大扩展数。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let extensionCount: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param bytes 保存原始内容的字节序列。
 * @param limits 调用方提供的输入值。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func derBytes(): Array<Byte> { encoded.clone() }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func subjectAlternativeNames(): CertificateSubjectAlternativeNames {
        parseCertificateSubjectAlternativeNames(encoded)
    }
}

/** A leaf-first immutable certificate chain with aggregate resource bounds. */
public class CertificateChain {
    private let entries: Array<DerCertificate>
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let totalBytes: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param certificates 调用方提供的输入值。
 * @param limits 调用方提供的输入值。
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
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public func size(): Int64 { entries.size }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param index 调用方提供的输入值。
 */
    public func certificateAt(index: Int64): DerCertificate { entries[index] }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func certificates(): Array<DerCertificate> { entries.clone() }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum PinScope {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | LeafSubjectPublicKeyInfo
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | AnyCertificateSubjectPublicKeyInfo
}

/** SHA-256 digest of a DER SubjectPublicKeyInfo, never a certificate digest. */
public struct SpkiSha256Pin {
    private let digest: Array<Byte>
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let scope: PinScope

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param digest 调用方提供的输入值。
 * @param scope 调用方提供的输入值。
 */
    public init(digest: Array<Byte>, scope!: PinScope = PinScope.LeafSubjectPublicKeyInfo) {
        if (digest.size != 32) {
            throw IllegalArgumentException("SPKI SHA-256 pin must contain exactly 32 bytes")
        }
        this.digest = digest.clone()
        this.scope = scope
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func digestBytes(): Array<Byte> { digest.clone() }
}

/** Immutable trust configuration; there is deliberately no TrustAll variant. */
public class TrustPolicy {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let kind: TrustPolicyKind
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public static func system(): TrustPolicy {
        TrustPolicy(TrustPolicyKind.System, None<CertificateChain>, [])
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param roots 调用方提供的输入值。
 */
    public static func customRoots(roots: CertificateChain): TrustPolicy {
        TrustPolicy(TrustPolicyKind.CustomRoots, Some(roots), [])
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param roots 调用方提供的输入值。
 */
    public static func systemPlusCustomRoots(roots: CertificateChain): TrustPolicy {
        TrustPolicy(TrustPolicyKind.SystemPlusCustomRoots, Some(roots), [])
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param pins 调用方提供的输入值。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func customRootChain(): ?CertificateChain { roots }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func pins(): Array<SpkiSha256Pin> { publicKeyPins.clone() }
}

/** Stable diagnostic result with no native certificate/provider object. */
public struct TrustVerificationEvidence {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let status: TrustVerificationStatus
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let trustSource: TrustAnchorSource
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let trustContextIdentity: String
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let peerChainLength: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let matchedPinIndex: ?Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let verifiedReferenceIdentity: ?String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param matchedPinIndex 调用方提供的输入值。
 * @param peerChainLength 调用方提供的输入值。
 * @param status 待记录的协议状态码。
 * @param trustContextIdentity 调用方提供的输入值。
 * @param trustSource 调用方提供的输入值。
 * @param verifiedReferenceIdentity 调用方提供的输入值。
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
