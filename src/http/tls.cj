package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http1 as http1
import wirestack.internal.tls_engine as tls

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum HttpClientTlsSecurityProfile {
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
 * Reusable custom-root TLS client material. An optional client certificate and
 * PKCS#8 key enable mTLS; close zeroes the retained key copy.
 */
public class HttpClientTlsConfig <: Resource {
    private let mutex = Mutex()
    private let trustRoots: Array<Array<Byte>>
    private let clientCertificates: Array<Array<Byte>>
    private var clientPrivateKey: Array<Byte>
    private let profile: HttpClientTlsSecurityProfile
    private var closed = false

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param clientCertificateChainDer 调用方提供的输入值。
 * @param clientPrivateKeyPkcs8Der 调用方提供的输入值。
 * @param customTrustRootsDer 调用方提供的输入值。
 * @param securityProfile 调用方提供的输入值。
 */
    public init(
        customTrustRootsDer: Array<Array<Byte>>,
        clientCertificateChainDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        clientPrivateKeyPkcs8Der!: Array<Byte> = Array<Byte>(),
        securityProfile!: HttpClientTlsSecurityProfile = HttpClientTlsSecurityProfile.Modern
    ) {
        trustRoots = cloneHttpClientDerChain(customTrustRootsDer)
        clientCertificates = cloneHttpClientDerChain(clientCertificateChainDer)
        clientPrivateKey = clientPrivateKeyPkcs8Der.clone()
        profile = securityProfile
    }

    internal func createHandshaker(): http1.Http1TlsHandshaker {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client TLS configuration is closed") }
            http1.DefaultHttp1TlsHandshaker.createWithDer(
                cloneHttpClientDerChain(trustRoots),
                clientCertificateChainDer: cloneHttpClientDerChain(clientCertificates),
                clientPrivateKeyPkcs8Der: clientPrivateKey.clone(),
                securityProfile: match (profile) {
                    case HttpClientTlsSecurityProfile.Modern => tls.TlsSecurityProfile.Modern
                    case HttpClientTlsSecurityProfile.StrictTls13 => tls.TlsSecurityProfile.StrictTls13
                }
            )
        }
    }

    internal func createAlpnHandshaker(): http1.HttpAlpnTlsHandshaker {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client TLS configuration is closed") }
            http1.DefaultHttp1TlsHandshaker.createWithDerAlpn(
                cloneHttpClientDerChain(trustRoots),
                clientCertificateChainDer: cloneHttpClientDerChain(clientCertificates),
                clientPrivateKeyPkcs8Der: clientPrivateKey.clone(),
                securityProfile: match (profile) {
                    case HttpClientTlsSecurityProfile.Modern => tls.TlsSecurityProfile.Modern
                    case HttpClientTlsSecurityProfile.StrictTls13 => tls.TlsSecurityProfile.StrictTls13
                }
            )
        }
    }

/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroHttpClientBytes(clientPrivateKey)
                clientPrivateKey = Array<Byte>()
                closed = true
            }
        }
    }

/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    ~init() { zeroHttpClientBytes(clientPrivateKey) }
}

private func cloneHttpClientDerChain(values: Array<Array<Byte>>): Array<Array<Byte>> {
    let result = ArrayList<Array<Byte>>()
    for (value in values) { result.add(value.clone()) }
    result.toArray()
}

private func zeroHttpClientBytes(value: Array<Byte>): Unit {
    for (index in 0..value.size) { value[index] = 0 }
}
