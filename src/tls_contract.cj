package wirestack

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsCapability {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemTrust
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | HardwareKeys
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ClientCertificate
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ServerMode
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Tls12
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Tls13
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Http2
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | NetworkBinding
/**
 * External private-key decryption backed by a caller-owned service.
 */
    | ExternalDecryptor
/**
 * Explicit test-build TLS key logging.
 */
    | KeyLog
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsVersion {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Tls12
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Tls13
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsSecurityProfile {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Compatible
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Modern
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | StrictTls13
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum ClientAuthentication {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | None
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Optional
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Required
}

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum TlsContextErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | MissingTrust
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | MissingIdentity
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidVersionRange
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidAlpn
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | UnsupportedCapability
/**
 * A hook is invalid for the selected TLS role or identity.
 */
    | InvalidHook
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class TlsContextException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: TlsContextErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let capability: ?TlsCapability

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param capability 调用方提供的输入值。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 */
    public init(
        code: TlsContextErrorCode,
        message: String,
        capability!: ?TlsCapability = None<TlsCapability>
    ) {
        super(message)
        this.code = code
        this.capability = capability
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "TlsContextException" }
}

/**
 * One bounded RSA ciphertext supplied to an external private-key decryptor.
 *
 * `algorithm` is deliberately restricted to `RSA_RAW`: the callback returns
 * the raw RSA private-operation block while the TLS provider owns PKCS#1
 * validation and removal.
 */
public struct ExternalDecryptionRequest {
    /** The provider-neutral algorithm identifier; always `RSA_RAW`. */
    public let algorithm: String
    private let ciphertext: Array<Byte>

    /**
     * Creates an engine-owned request.
     * @param algorithm Must be exactly `RSA_RAW`.
     * @param ciphertext RSA ciphertext containing 1..1024 bytes.
     */
    public init(algorithm: String, ciphertext: Array<Byte>) {
        if (algorithm != "RSA_RAW" || ciphertext.isEmpty() || ciphertext.size > 1024) {
            throw TlsContextException(
                TlsContextErrorCode.InvalidHook,
                "external decryption requires RSA_RAW ciphertext containing 1..1024 bytes"
            )
        }
        this.algorithm = algorithm
        this.ciphertext = ciphertext.clone()
    }

    /** Returns an owned copy of the ciphertext. */
    public func ciphertextBytes(): Array<Byte> { ciphertext.clone() }
}

/**
 * Caller-owned, thread-safe service for an external RSA private operation.
 *
 * The TLS engine passes the exact handshake `OperationContext`. A successful
 * callback transfers ownership of its returned array to Wirestack: it must
 * contain exactly `request.ciphertextBytes().size` raw-RSA block bytes and the
 * callback must not retain, reuse, or mutate it. Wirestack zeroes that array
 * after native completion on every path.
 */
public interface ExternalDecryptor {
    /**
     * Performs one bounded raw RSA private operation.
     * @param request Validated `RSA_RAW` ciphertext.
     * @param context The caller's exact handshake operation context.
     */
    func decrypt(request: ExternalDecryptionRequest, context: OperationContext): Array<Byte>
}

/**
 * One owned, bounded NSS key-log record for an explicit test build.
 *
 * The label is an ASCII token of 1..128 uppercase letters, decimal digits, or
 * underscores. `clientRandom` is exactly 32 bytes and `secret` is 1..64 bytes.
 */
public struct TlsKeyLogLine {
    /** NSS-compatible key-log label. */
    public let label: String
    private let clientRandom: Array<Byte>
    private let secret: Array<Byte>

    /**
     * Creates a validated key-log record and copies both byte arrays.
     * @param label Bounded NSS-compatible ASCII label.
     * @param clientRandom Exact 32-byte TLS client random.
     * @param secret Secret containing 1..64 bytes.
     */
    public init(label: String, clientRandom: Array<Byte>, secret: Array<Byte>) {
        let labelBytes = label.toArray()
        var validLabel = !labelBytes.isEmpty() && labelBytes.size <= 128
        for (value in labelBytes) {
            if (!((value >= b'A' && value <= b'Z') ||
                (value >= b'0' && value <= b'9') || value == b'_')) {
                validLabel = false
            }
        }
        if (!validLabel || clientRandom.size != 32 || secret.isEmpty() || secret.size > 64) {
            throw TlsContextException(
                TlsContextErrorCode.InvalidHook,
                "TLS key-log line requires an NSS label, 32-byte random, and 1..64-byte secret"
            )
        }
        this.label = label
        this.clientRandom = clientRandom.clone()
        this.secret = secret.clone()
    }

    /** Returns an owned client-random copy. */
    public func clientRandomBytes(): Array<Byte> { clientRandom.clone() }
    /** Returns an owned secret copy. */
    public func secretBytes(): Array<Byte> { secret.clone() }
}

/**
 * Caller-owned, thread-safe sink available only in explicit test-keylog builds.
 *
 * Wirestack passes the exact handshake `OperationContext`. The sink must copy
 * data it retains and must not log outside the explicitly enabled context.
 */
public interface KeyLogSink {
    /**
     * Receives one validated key-log record.
     * @param line Bounded, owned key-log data.
     * @param context The caller's exact handshake operation context.
     */
    func emit(line: TlsKeyLogLine, context: OperationContext): Unit
}

/**
 * Wirestack 公开 API：TlsEngineErrorCode。
 */
public enum TlsEngineErrorCode {
/**
 * Wirestack 公开 API：ProtocolViolation。
 */
    | ProtocolViolation
/**
 * Wirestack 公开 API：UnsupportedVersion。
 */
    | UnsupportedVersion
/**
 * Wirestack 公开 API：NoSharedCipher。
 */
    | NoSharedCipher
/**
 * Wirestack 公开 API：NoSharedAlpn。
 */
    | NoSharedAlpn
/**
 * Wirestack 公开 API：CertificateUntrusted。
 */
    | CertificateUntrusted
/**
 * Wirestack 公开 API：IdentityMismatch。
 */
    | IdentityMismatch
/**
 * Wirestack 公开 API：CertificateExpired。
 */
    | CertificateExpired
/**
 * Wirestack 公开 API：CertificateRevoked。
 */
    | CertificateRevoked
/**
 * Wirestack 公开 API：ClientCertificateRequired。
 */
    | ClientCertificateRequired
/**
 * Wirestack 公开 API：HandshakeTimeout。
 */
    | HandshakeTimeout
/**
 * Wirestack 公开 API：HandshakeCancelled。
 */
    | HandshakeCancelled
/**
 * Wirestack 公开 API：PeerAlert。
 */
    | PeerAlert
/**
 * Wirestack 公开 API：PeerClosedWithoutCloseNotify。
 */
    | PeerClosedWithoutCloseNotify
/**
 * Wirestack 公开 API：InvalidRecord。
 */
    | InvalidRecord
/**
 * Wirestack 公开 API：BadMac。
 */
    | BadMac
/**
 * Wirestack 公开 API：SessionFailure。
 */
    | SessionFailure
/**
 * Wirestack 公开 API：ProviderFailure。
 */
    | ProviderFailure
/**
 * Wirestack 公开 API：UnsupportedCapability。
 */
    | UnsupportedCapability
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：NoProgress。
 */
    | NoProgress
/**
 * Wirestack 公开 API：UnexpectedTransportEof。
 */
    | UnexpectedTransportEof
/**
 * Wirestack 公开 API：PrivateKeyFailure。
 */
    | PrivateKeyFailure
/**
 * Wirestack 公开 API：ServerNameSelectionFailure。
 */
    | ServerNameSelectionFailure
}

/** Stable TLS failure without provider-native types or secret material. */
public class TlsEngineException <: NetworkException {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let tlsCode: TlsEngineErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let verificationCode: ?Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let peerAlert: ?Int32

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cause 导致当前错误的底层异常。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 * @param nativeCode 调用方提供的输入值。
 * @param peerAlert 调用方提供的输入值。
 * @param phase 调用方提供的输入值。
 * @param verificationCode 调用方提供的输入值。
 */
    public init(
        code: TlsEngineErrorCode,
        message: String,
        phase!: NetworkPhase = NetworkPhase.TlsHandshake,
        nativeCode!: ?Int64 = None<Int64>,
        verificationCode!: ?Int64 = None<Int64>,
        peerAlert!: ?Int32 = None<Int32>,
        cause!: ?Exception = None<Exception>
    ) {
        super(
            match (code) {
                case TlsEngineErrorCode.HandshakeCancelled => NetworkErrorCategory.Cancelled
                case TlsEngineErrorCode.HandshakeTimeout => NetworkErrorCategory.DeadlineExceeded
                case _ => NetworkErrorCategory.System
            },
            phase,
            match (code) {
                case TlsEngineErrorCode.Closed => NetworkErrorCode.Closed
                case TlsEngineErrorCode.UnexpectedTransportEof => NetworkErrorCode.UnexpectedEof
                case TlsEngineErrorCode.PeerClosedWithoutCloseNotify => NetworkErrorCode.UnexpectedEof
                case TlsEngineErrorCode.HandshakeTimeout => NetworkErrorCode.TimedOut
                case TlsEngineErrorCode.HandshakeCancelled => NetworkErrorCode.Cancelled
                case TlsEngineErrorCode.UnsupportedCapability => NetworkErrorCode.Unsupported
                case _ => NetworkErrorCode.SystemFailure
            },
            message,
            retryability: match (code) {
                case TlsEngineErrorCode.HandshakeTimeout => Retryability.SafeBeforeWrite
                case TlsEngineErrorCode.HandshakeCancelled => Retryability.Never
                case TlsEngineErrorCode.ProviderFailure => Retryability.Unknown
                case _ => Retryability.Never
            },
            nativeCode: nativeCode,
            cause: cause
        )
        tlsCode = code
        this.verificationCode = verificationCode
        this.peerAlert = peerAlert
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "TlsEngineException" }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsConnectionState {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Open
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Closing
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Closed
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Aborted
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsClosureEvidence {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | CloseNotify
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | PeerClosedWithoutCloseNotify
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | LocalAbort
}
