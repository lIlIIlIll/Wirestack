package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http1 as http1
import wirestack.internal.tls_engine as tls

public enum HttpClientTlsSecurityProfile {
    | Modern
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
            http1.AwsLcHttp1TlsHandshaker.createWithDer(
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

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroHttpClientBytes(clientPrivateKey)
                clientPrivateKey = Array<Byte>()
                closed = true
            }
        }
    }

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
