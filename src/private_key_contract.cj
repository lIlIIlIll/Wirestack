package wirestack

/**
 * Wirestack 公开 API：PrivateKeyKind。
 */
public enum PrivateKeyKind {
/**
 * Wirestack 公开 API：Pkcs8。
 */
    | Pkcs8
/**
 * Wirestack 公开 API：SystemHandle。
 */
    | SystemHandle
/**
 * Wirestack 公开 API：ExternalSigner。
 */
    | ExternalSigner
}

/**
 * Wirestack 公开 API：PrivateKeyErrorCode。
 */
public enum PrivateKeyErrorCode {
/**
 * Wirestack 公开 API：InvalidPkcs8。
 */
    | InvalidPkcs8
/**
 * Wirestack 公开 API：InvalidFile。
 */
    | InvalidFile
/**
 * Wirestack 公开 API：KeyCertificateMismatch。
 */
    | KeyCertificateMismatch
/**
 * Wirestack 公开 API：Closed。
 */
    | Closed
/**
 * Wirestack 公开 API：UnsupportedKeyKind。
 */
    | UnsupportedKeyKind
/**
 * Wirestack 公开 API：InvalidSigner。
 */
    | InvalidSigner
/**
 * Wirestack 公开 API：SignerFailure。
 */
    | SignerFailure
}

/**
 * Wirestack 公开 API：TlsSignatureAlgorithm。
 */
public enum TlsSignatureAlgorithm {
/**
 * Wirestack 公开 API：RsaPssRsaeSha256。
 */
    | RsaPssRsaeSha256
/**
 * Wirestack 公开 API：RsaPssRsaeSha384。
 */
    | RsaPssRsaeSha384
/**
 * Wirestack 公开 API：RsaPssRsaeSha512。
 */
    | RsaPssRsaeSha512
/**
 * Wirestack 公开 API：RsaPkcs1Sha256。
 */
    | RsaPkcs1Sha256
/**
 * Wirestack 公开 API：RsaPkcs1Sha384。
 */
    | RsaPkcs1Sha384
/**
 * Wirestack 公开 API：RsaPkcs1Sha512。
 */
    | RsaPkcs1Sha512
/**
 * Wirestack 公开 API：EcdsaSecp256r1Sha256。
 */
    | EcdsaSecp256r1Sha256
/**
 * Wirestack 公开 API：EcdsaSecp384r1Sha384。
 */
    | EcdsaSecp384r1Sha384
/**
 * Wirestack 公开 API：EcdsaSecp521r1Sha512。
 */
    | EcdsaSecp521r1Sha512
/**
 * Wirestack 公开 API：Ed25519。
 */
    | Ed25519
}

/**
 * Wirestack 公开 API：PrivateKeyException。
 */
public class PrivateKeyException <: Exception {
/**
 * Wirestack 公开 API：code。
 */
    public let code: PrivateKeyErrorCode

/**
 * Wirestack 公开 API：init。
 * @param code 参数 code。
 * @param message 参数 message。
 */
    public init(code: PrivateKeyErrorCode, message: String) {
        super(message)
        this.code = code
    }

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String { "PrivateKeyException" }
}

/**
 * Wirestack 公开 API：ExternalSignatureRequest。
 */
public struct ExternalSignatureRequest {
/**
 * Wirestack 公开 API：algorithm。
 */
    public let algorithm: TlsSignatureAlgorithm
    private let message: Array<Byte>

/**
 * Wirestack 公开 API：init。
 * @param algorithm 参数 algorithm。
 * @param message 参数 message。
 */
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

/**
 * Wirestack 公开 API：messageBytes。
 */
    public func messageBytes(): Array<Byte> { message.clone() }
}

/**
 * Wirestack 公开 API：ExternalSigner。
 */
public interface ExternalSigner {
/**
 * Wirestack 公开 API：supportedAlgorithms。
 */
    func supportedAlgorithms(): Array<TlsSignatureAlgorithm>
/**
 * Wirestack 公开 API：sign。
 * @param context 参数 context。
 * @param request 参数 request。
 */
    func sign(request: ExternalSignatureRequest, context: OperationContext): Array<Byte>
}
