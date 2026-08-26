package wirestack.internal.http1

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.internal.tls_engine.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

/** Accept-side TLS boundary owned for the complete HTTP server lifetime. */
public interface Http1ServerTlsHandshaker <: Resource {
    func handshake(transport: DuplexTransport, context: OperationContext): DuplexTransport
}

public enum HttpServerNegotiatedProtocol {
    | Http2
    | Http11
}

public class HttpServerNegotiatedTransport {
    public let protocol: HttpServerNegotiatedProtocol
    public let transport: DuplexTransport
    public init(protocol: HttpServerNegotiatedProtocol, transport: DuplexTransport) {
        this.protocol = protocol
        this.transport = transport
    }
}

public interface HttpServerAlpnHandshaker <: Resource {
    func handshakeNegotiated(
        transport: DuplexTransport,
        context: OperationContext
    ): HttpServerNegotiatedTransport
}

/** Linux AWS-LC TLS 1.2/1.3 server restricted to HTTP/1.1 ALPN. */
public class AwsLcHttp1ServerTlsHandshaker <: Http1ServerTlsHandshaker & HttpServerAlpnHandshaker {
    private let provider: AwsLcTlsProvider
    private let serverContext: TlsServerContext
    private let privateKey: PrivateKeyRef
    private let mutex = Mutex()
    private var closed = false

    private init(provider: AwsLcTlsProvider, serverContext: TlsServerContext,
        privateKey: PrivateKeyRef) {
        this.provider = provider
        this.serverContext = serverContext
        this.privateKey = privateKey
    }

    public static func create(
        certificateChainDer: Array<Array<Byte>>,
        privateKeyPkcs8Der: Array<Byte>,
        clientAuthentication!: ClientAuthentication = ClientAuthentication.None,
        clientTrustRootsDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): AwsLcHttp1ServerTlsHandshaker {
        createWithProtocols(
            certificateChainDer, privateKeyPkcs8Der, ["http/1.1"],
            clientAuthentication, clientTrustRootsDer, securityProfile
        )
    }

    public static func createAlpn(
        certificateChainDer: Array<Array<Byte>>,
        privateKeyPkcs8Der: Array<Byte>,
        clientAuthentication!: ClientAuthentication = ClientAuthentication.None,
        clientTrustRootsDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        securityProfile!: TlsSecurityProfile = TlsSecurityProfile.Modern
    ): AwsLcHttp1ServerTlsHandshaker {
        createWithProtocols(
            certificateChainDer, privateKeyPkcs8Der, ["h2", "http/1.1"],
            clientAuthentication, clientTrustRootsDer, securityProfile
        )
    }

    private static func createWithProtocols(
        certificateChainDer: Array<Array<Byte>>,
        privateKeyPkcs8Der: Array<Byte>,
        protocols: Array<String>,
        clientAuthentication: ClientAuthentication,
        clientTrustRootsDer: Array<Array<Byte>>,
        securityProfile: TlsSecurityProfile
    ): AwsLcHttp1ServerTlsHandshaker {
        let certificates = ArrayList<DerCertificate>()
        for (encoded in certificateChainDer) { certificates.add(DerCertificate(encoded)) }
        let chain = CertificateChain(certificates.toArray())
        let key = PrivateKeyRef.pkcs8(privateKeyPkcs8Der)
        var provider: ?AwsLcTlsProvider = None<AwsLcTlsProvider>
        try {
            let identity = LocalIdentity(chain, key)
            let created = AwsLcTlsProvider()
            provider = Some(created)
            let builder = TlsServerContext.builder(
                created.manifest(), created.linuxCapabilities()
            ).securityProfile(securityProfile).identity(identity).alpn(protocols)
                .clientAuthentication(clientAuthentication)
            match (clientAuthentication) {
                case ClientAuthentication.None =>
                    if (!clientTrustRootsDer.isEmpty()) {
                        throw IllegalArgumentException(
                            "HTTP TLS client trust roots require optional or required client authentication"
                        )
                    }
                case _ =>
                    let roots = ArrayList<DerCertificate>()
                    for (encoded in clientTrustRootsDer) { roots.add(DerCertificate(encoded)) }
                    builder.clientTrust(TrustPolicy.customRoots(CertificateChain(roots.toArray())))
            }
            AwsLcHttp1ServerTlsHandshaker(created, builder.build(), key)
        } catch (error: Exception) {
            key.close()
            match (provider) { case Some(value) => value.close(); case None => () }
            throw error
        }
    }

    public func handshake(transport: DuplexTransport, context: OperationContext): DuplexTransport {
        let negotiated = handshakeNegotiated(transport, context)
        match (negotiated.protocol) {
            case HttpServerNegotiatedProtocol.Http11 => negotiated.transport
            case HttpServerNegotiatedProtocol.Http2 =>
                negotiated.transport.abort(reason: Some(AbortReason.ProtocolFailure))
                throw TlsEngineException(
                    TlsEngineErrorCode.NoSharedAlpn,
                    "TLS HTTP/1 server negotiated an unexpected ALPN protocol"
                )
        }
    }

    public func handshakeNegotiated(
        transport: DuplexTransport,
        context: OperationContext
    ): HttpServerNegotiatedTransport {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP TLS server handshaker is closed") }
        }
        emitServerTlsEvent(context, NetworkEventOutcome.Started, None<NetworkErrorCode>)
        try {
            let connection = TlsConnection.handshake(
                provider.createServerEngine(serverContext), transport, context: context
            )
            let protocol = match (connection.handshakeInfo) {
                case Some(info) => match (info.negotiatedAlpn) {
                    case Some(value) =>
                        if (value == "h2") { HttpServerNegotiatedProtocol.Http2 }
                        else if (value == "http/1.1") { HttpServerNegotiatedProtocol.Http11 }
                        else {
                            connection.abort(reason: Some(AbortReason.ProtocolFailure))
                            throw TlsEngineException(
                                TlsEngineErrorCode.NoSharedAlpn,
                                "TLS HTTP server negotiated an unsupported ALPN protocol"
                            )
                        }
                    case None =>
                        connection.abort(reason: Some(AbortReason.ProtocolFailure))
                        throw TlsEngineException(
                            TlsEngineErrorCode.NoSharedAlpn,
                            "TLS HTTP server completed without a negotiated ALPN protocol"
                        )
                }
                case None =>
                    connection.abort(reason: Some(AbortReason.ProtocolFailure))
                    throw TlsEngineException(
                        TlsEngineErrorCode.ProviderFailure,
                        "TLS HTTP/1 server handshake returned no negotiated evidence"
                    )
            }
            emitServerTlsEvent(context, NetworkEventOutcome.Succeeded, None<NetworkErrorCode>)
            HttpServerNegotiatedTransport(protocol, connection)
        } catch (error: Exception) {
            let code = match (error) {
                case value: NetworkException => Some(value.code)
                case _ => Some(NetworkErrorCode.SystemFailure)
            }
            emitServerTlsEvent(context, NetworkEventOutcome.Failed, code)
            throw error
        }
    }

    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) {
            provider.close()
            privateKey.close()
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private func emitServerTlsEvent(context: OperationContext,
    outcome: NetworkEventOutcome, code: ?NetworkErrorCode): Unit {
    let kind = match (outcome) {
        case NetworkEventOutcome.Started => NetworkEventKind.TlsHandshakeStarted
        case _ => NetworkEventKind.TlsHandshakeCompleted
    }
    emitNetworkEvent(context, NetworkEvent(
        kind,
        outcome,
        trace: context.trace,
        phase: Some(NetworkPhase.TlsHandshake),
        errorCode: code
    ))
}
