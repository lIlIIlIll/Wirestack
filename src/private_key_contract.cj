package wirestack

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

public class PrivateKeyException <: Exception {
    public let code: PrivateKeyErrorCode

    public init(code: PrivateKeyErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "PrivateKeyException" }
}

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

public interface ExternalSigner {
    func supportedAlgorithms(): Array<TlsSignatureAlgorithm>
    func sign(request: ExternalSignatureRequest, context: OperationContext): Array<Byte>
}
