package wirestack

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

public enum TlsVersion {
    | Tls12
    | Tls13
}

public enum TlsSecurityProfile {
    | Compatible
    | Modern
    | StrictTls13
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

public enum TlsEngineErrorCode {
    | ProtocolViolation
    | UnsupportedVersion
    | NoSharedCipher
    | NoSharedAlpn
    | CertificateUntrusted
    | IdentityMismatch
    | CertificateExpired
    | CertificateRevoked
    | ClientCertificateRequired
    | HandshakeTimeout
    | HandshakeCancelled
    | PeerAlert
    | PeerClosedWithoutCloseNotify
    | InvalidRecord
    | BadMac
    | SessionFailure
    | ProviderFailure
    | UnsupportedCapability
    | Closed
    | NoProgress
    | UnexpectedTransportEof
    | PrivateKeyFailure
    | ServerNameSelectionFailure
}

/** Stable TLS failure without provider-native types or secret material. */
public class TlsEngineException <: NetworkException {
    public let tlsCode: TlsEngineErrorCode
    public let verificationCode: ?Int64
    public let peerAlert: ?Int32

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

    protected override func getClassName(): String { "TlsEngineException" }
}

public enum TlsConnectionState {
    | Open
    | Closing
    | Closed
    | Aborted
}

public enum TlsClosureEvidence {
    | CloseNotify
    | PeerClosedWithoutCloseNotify
    | LocalAbort
}
