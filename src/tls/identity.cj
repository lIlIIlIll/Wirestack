package wirestack.tls

import wirestack.internal.tls_engine as engine

/** Public owner of a provider-neutral private-key reference. */
public class PrivateKeyRef <: Resource {
    internal let value: engine.PrivateKeyRef

    private init(value: engine.PrivateKeyRef) {
        this.value = value
    }

    public prop kind: PrivateKeyKind { get() { value.kind } }
    public prop referenceIdentity: String { get() { value.referenceIdentity } }
    public prop requiresHardwareKey: Bool { get() { value.requiresHardwareKey } }

    public static func pkcs8(bytes: Array<Byte>): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8(bytes))
    }

    public static func pkcs8File(path: String): PrivateKeyRef {
        PrivateKeyRef(engine.PrivateKeyRef.pkcs8File(path))
    }

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

    public func close(): Unit { value.close() }
    public func isClosed(): Bool { value.isClosed() }
}

/** Public certificate-chain/private-key association. */
public class LocalIdentity {
    internal let value: engine.LocalIdentity
    public let certificateChain: CertificateChain
    public let privateKeyRef: PrivateKeyRef
    public let contextIdentity: String

    public init(certificateChain: CertificateChain, privateKeyRef: PrivateKeyRef) {
        value = engine.LocalIdentity(certificateChain, privateKeyRef.value)
        this.certificateChain = certificateChain
        this.privateKeyRef = privateKeyRef
        contextIdentity = value.contextIdentity
    }
}
