package wirestack.tls

import wirestack.internal.tls_engine as engine

/** Public owner of a provider-neutral private-key reference. */
public class PrivateKeyRef <: Resource {
    internal let value: engine.PrivateKeyRef

    private init(value: engine.PrivateKeyRef) {
        this.value = value
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop kind: PrivateKeyKind { get() { value.kind } }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop referenceIdentity: String { get() { value.referenceIdentity } }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop requiresHardwareKey: Bool { get() { value.requiresHardwareKey } }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param bytes 保存原始内容的字节序列。
 */
    public static func pkcs8(bytes: Array<Byte>): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8(bytes))
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param path 要打开或保存的文件系统路径。
 */
    public static func pkcs8File(path: String): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8File(path))
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param referenceIdentity 连接所期望的身份。
 * @param signer 调用方提供的输入值。
 * @param subjectPublicKeyInfoDer 调用方提供的输入值。
 */
    public static func externalSigner(
        referenceIdentity: String,
        subjectPublicKeyInfoDer: Array<Byte>,
        signer: ExternalSigner
    ): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.externalSigner(
            referenceIdentity,
            subjectPublicKeyInfoDer,
            signer
        ))
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param alias 调用方提供的输入值。
 * @param hardwareBacked 调用方提供的输入值。
 * @param platform 调用方提供的输入值。
 * @param signer 调用方提供的输入值。
 * @param subjectPublicKeyInfoDer 调用方提供的输入值。
 */
    public static func systemHandle(
        platform: String,
        alias: String,
        subjectPublicKeyInfoDer: Array<Byte>,
        signer: ExternalSigner,
        hardwareBacked!: Bool = true
    ): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.systemHandle(
            platform,
            alias,
            subjectPublicKeyInfoDer,
            signer,
            hardwareBacked: hardwareBacked
        ))
    }

/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit { value.close() }
/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { value.isClosed() }
}

/** Public certificate-chain/private-key association. */
public class LocalIdentity {
    internal let value: engine.LocalIdentity
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let certificateChain: CertificateChain
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let privateKeyRef: PrivateKeyRef
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let contextIdentity: String

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param certificateChain 调用方提供的输入值。
 * @param privateKeyRef 调用方提供的输入值。
 */
    public init(certificateChain: CertificateChain, privateKeyRef: PrivateKeyRef) {
        value = engine.LocalIdentity(certificateChain, privateKeyRef.value)
        this.certificateChain = certificateChain
        this.privateKeyRef = privateKeyRef
        contextIdentity = value.contextIdentity
    }
}
