package wirestack

/**
 * Wirestack 公开 API：TlsCapability。
 */
public enum TlsCapability {
/**
 * Wirestack 公开 API：SystemTrust。
 */
    | SystemTrust
/**
 * Wirestack 公开 API：CustomRoots。
 */
    | CustomRoots
/**
 * Wirestack 公开 API：HardwareKeys。
 */
    | HardwareKeys
/**
 * Wirestack 公开 API：ClientCertificate。
 */
    | ClientCertificate
/**
 * Wirestack 公开 API：ServerMode。
 */
    | ServerMode
/**
 * Wirestack 公开 API：Tls12。
 */
    | Tls12
/**
 * Wirestack 公开 API：Tls13。
 */
    | Tls13
/**
 * Wirestack 公开 API：Http2。
 */
    | Http2
/**
 * Wirestack 公开 API：NetworkBinding。
 */
    | NetworkBinding
}

/**
 * Wirestack 公开 API：TlsVersion。
 */
public enum TlsVersion {
/**
 * Wirestack 公开 API：Tls12。
 */
    | Tls12
/**
 * Wirestack 公开 API：Tls13。
 */
    | Tls13
}

/**
 * Wirestack 公开 API：TlsSecurityProfile。
 */
public enum TlsSecurityProfile {
/**
 * Wirestack 公开 API：Compatible。
 */
    | Compatible
/**
 * Wirestack 公开 API：Modern。
 */
    | Modern
/**
 * Wirestack 公开 API：StrictTls13。
 */
    | StrictTls13
}

/**
 * Wirestack 公开 API：ClientAuthentication。
 */
public enum ClientAuthentication {
/**
 * Wirestack 公开 API：None。
 */
    | None
/**
 * Wirestack 公开 API：Optional。
 */
    | Optional
/**
 * Wirestack 公开 API：Required。
 */
    | Required
}

/**
 * Wirestack 公开 API：TlsContextErrorCode。
 */
public enum TlsContextErrorCode {
/**
 * Wirestack 公开 API：MissingTrust。
 */
    | MissingTrust
/**
 * Wirestack 公开 API：MissingIdentity。
 */
    | MissingIdentity
/**
 * Wirestack 公开 API：InvalidVersionRange。
 */
    | InvalidVersionRange
/**
 * Wirestack 公开 API：InvalidAlpn。
 */
    | InvalidAlpn
/**
 * Wirestack 公开 API：UnsupportedCapability。
 */
    | UnsupportedCapability
}

/**
 * Wirestack 公开 API：TlsContextException。
 */
public class TlsContextException <: Exception {
/**
 * Wirestack 公开 API：code。
 */
    public let code: TlsContextErrorCode
/**
 * Wirestack 公开 API：capability。
 */
    public let capability: ?TlsCapability

/**
 * Wirestack 公开 API：init。
 * @param capability 参数 capability。
 * @param code 参数 code。
 * @param message 参数 message。
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
 * Wirestack 公开 API：tlsCode。
 */
    public let tlsCode: TlsEngineErrorCode
/**
 * Wirestack 公开 API：verificationCode。
 */
    public let verificationCode: ?Int64
/**
 * Wirestack 公开 API：peerAlert。
 */
    public let peerAlert: ?Int32

/**
 * Wirestack 公开 API：init。
 * @param cause 参数 cause。
 * @param code 参数 code。
 * @param message 参数 message。
 * @param nativeCode 参数 nativeCode。
 * @param peerAlert 参数 peerAlert。
 * @param phase 参数 phase。
 * @param verificationCode 参数 verificationCode。
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
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "TlsEngineException" }
}

/**
 * Wirestack 公开 API：TlsConnectionState。
 */
public enum TlsConnectionState {
/**
 * Wirestack 公开 API：Open。
 */
    | Open
/**
 * Wirestack 公开 API：Closing。
 */
    | Closing
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：Aborted。
 */
    | Aborted
}

/**
 * Wirestack 公开 API：TlsClosureEvidence。
 */
public enum TlsClosureEvidence {
/**
 * Wirestack 公开 API：CloseNotify。
 */
    | CloseNotify
/**
 * Wirestack 公开 API：PeerClosedWithoutCloseNotify。
 */
    | PeerClosedWithoutCloseNotify
/**
 * Wirestack 公开 API：LocalAbort。
 */
    | LocalAbort
}
