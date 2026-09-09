package wirestack

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum PrivateKeyKind {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Pkcs8
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemHandle
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ExternalSigner
}

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum PrivateKeyErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidPkcs8
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidFile
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | KeyCertificateMismatch
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Closed
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | UnsupportedKeyKind
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidSigner
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SignerFailure
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum TlsSignatureAlgorithm {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPssRsaeSha256
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPssRsaeSha384
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPssRsaeSha512
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPkcs1Sha256
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPkcs1Sha384
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RsaPkcs1Sha512
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | EcdsaSecp256r1Sha256
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | EcdsaSecp384r1Sha384
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | EcdsaSecp521r1Sha512
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Ed25519
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class PrivateKeyException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: PrivateKeyErrorCode

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 */
    public init(code: PrivateKeyErrorCode, message: String) {
        super(message)
        this.code = code
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "PrivateKeyException" }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public struct ExternalSignatureRequest {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let algorithm: TlsSignatureAlgorithm
    private let message: Array<Byte>

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param algorithm 调用方提供的输入值。
 * @param message 面向调用方的诊断文本。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public func messageBytes(): Array<Byte> { message.clone() }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public interface ExternalSigner {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    func supportedAlgorithms(): Array<TlsSignatureAlgorithm>
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param request 待处理的 HTTP 请求。
 */
    func sign(request: ExternalSignatureRequest, context: OperationContext): Array<Byte>
}
