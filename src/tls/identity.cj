package wirestack.tls

import wirestack.internal.tls_engine as engine

/** Public owner of a provider-neutral private-key reference. */
public class PrivateKeyRef <: Resource {
    internal let value: engine.PrivateKeyRef

    private init(value: engine.PrivateKeyRef) {
        this.value = value
    }

/**
 * Wirestack 公开 API：kind。
 */
    public prop kind: PrivateKeyKind { get() { value.kind } }
/**
 * Wirestack 公开 API：referenceIdentity。
 */
    public prop referenceIdentity: String { get() { value.referenceIdentity } }
/**
 * Wirestack 公开 API：requiresHardwareKey。
 */
    public prop requiresHardwareKey: Bool { get() { value.requiresHardwareKey } }

/**
 * Wirestack 公开 API：pkcs8。
 * @param bytes 参数 bytes。
 */
    public static func pkcs8(bytes: Array<Byte>): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8(bytes))
    }

/**
 * Wirestack 公开 API：pkcs8File。
 * @param path 参数 path。
 */
    public static func pkcs8File(path: String): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8File(path))
    }

/**
 * Wirestack 公开 API：externalSigner。
 * @param referenceIdentity 参数 referenceIdentity。
 * @param signer 参数 signer。
 * @param subjectPublicKeyInfoDer 参数 subjectPublicKeyInfoDer。
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
 * Wirestack 公开 API：systemHandle。
 * @param alias 参数 alias。
 * @param hardwareBacked 参数 hardwareBacked。
 * @param platform 参数 platform。
 * @param signer 参数 signer。
 * @param subjectPublicKeyInfoDer 参数 subjectPublicKeyInfoDer。
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
 * Wirestack 公开 API：close。
 */
    public func close(): Unit { value.close() }
/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { value.isClosed() }
}

/** Public certificate-chain/private-key association. */
public class LocalIdentity {
    internal let value: engine.LocalIdentity
/**
 * Wirestack 公开 API：certificateChain。
 */
    public let certificateChain: CertificateChain
/**
 * Wirestack 公开 API：privateKeyRef。
 */
    public let privateKeyRef: PrivateKeyRef
/**
 * Wirestack 公开 API：contextIdentity。
 */
    public let contextIdentity: String

/**
 * Wirestack 公开 API：init。
 * @param certificateChain 参数 certificateChain。
 * @param privateKeyRef 参数 privateKeyRef。
 */
    public init(certificateChain: CertificateChain, privateKeyRef: PrivateKeyRef) {
        value = engine.LocalIdentity(certificateChain, privateKeyRef.value)
        this.certificateChain = certificateChain
        this.privateKeyRef = privateKeyRef
        contextIdentity = value.contextIdentity
    }
}
