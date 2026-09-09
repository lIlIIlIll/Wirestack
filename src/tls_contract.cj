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
