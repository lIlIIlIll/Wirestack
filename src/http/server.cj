package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http1 as http1
import wirestack.internal.tls_engine as tls
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet

public enum HttpServerClientAuthentication {
    | None
    | Optional
    | Required
}

public enum HttpServerTlsSecurityProfile {
    | Modern
    | StrictTls13
}

/**
 * Reusable, explicitly owned TLS server material. DER inputs are validated
 * when a server is built; close zeroes the retained PKCS#8 copy.
 */
public class HttpServerTlsConfig <: Resource {
    private let mutex = Mutex()
    private let certificateChain: Array<Array<Byte>>
    private var privateKey: Array<Byte>
    private let authentication: HttpServerClientAuthentication
    private let trustRoots: Array<Array<Byte>>
    private let profile: HttpServerTlsSecurityProfile
    private var closed = false

    public init(
        certificateChainDer: Array<Array<Byte>>,
        privateKeyPkcs8Der: Array<Byte>,
        clientAuthentication!: HttpServerClientAuthentication = HttpServerClientAuthentication.None,
        clientTrustRootsDer!: Array<Array<Byte>> = Array<Array<Byte>>(),
        securityProfile!: HttpServerTlsSecurityProfile = HttpServerTlsSecurityProfile.Modern
    ) {
        certificateChain = cloneHttpServerDerChain(certificateChainDer)
        privateKey = privateKeyPkcs8Der.clone()
        authentication = clientAuthentication
        trustRoots = cloneHttpServerDerChain(clientTrustRootsDer)
        profile = securityProfile
    }

    internal func createHandshaker(): http1.Http1ServerTlsHandshaker {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP server TLS configuration is closed") }
            http1.AwsLcHttp1ServerTlsHandshaker.create(
                cloneHttpServerDerChain(certificateChain),
                privateKey.clone(),
                clientAuthentication: toInternalClientAuthentication(authentication),
                clientTrustRootsDer: cloneHttpServerDerChain(trustRoots),
                securityProfile: toInternalSecurityProfile(profile)
            )
        }
    }

    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroHttpServerBytes(privateKey)
                privateKey = Array<Byte>()
                closed = true
            }
        }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    ~init() { zeroHttpServerBytes(privateKey) }
}

/** Public, protocol-neutral view of one incoming HTTP request. */
public class HttpServerRequest {
    public let method: HttpMethod
    public let target: String
    public let version: HttpVersion
    public let headers: HttpHeaders
    public let body: ResponseBody

    init(value: http1.Http1ServerRequest) {
        method = value.head.method
        target = value.head.target
        version = value.head.version
        headers = value.head.headers
        body = value.body
    }
}

/** Handler-owned response and optional chunk trailer. */
public class HttpServerResponse {
    public let response: HttpResponse
    public let trailer: HttpTrailer

    public init(response: HttpResponse, trailer!: HttpTrailer = HttpTrailer()) {
        this.response = response
        this.trailer = trailer
    }
}

public interface HttpServerHandler {
    func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse
}

public type HttpServerShutdownResult = http1.Http1ServerShutdownResult

public class HttpServerBuilder {
    private var endpoint: ?SocketEndpoint = None<SocketEndpoint>
    private var configuredHandler: ?HttpServerHandler = None<HttpServerHandler>
    private var configuredLimits = HttpLimits()
    private var maximumConnections: Int64 = 1024
    private var maximumRequestsPerConnection: Int64 = 1000
    private var backlog: Int64 = 128
    private var tlsConfig: ?HttpServerTlsConfig = None<HttpServerTlsConfig>

    public init() {}

    public func listen(value: SocketEndpoint): HttpServerBuilder { endpoint = Some(value); this }
    public func handler(value: HttpServerHandler): HttpServerBuilder { configuredHandler = Some(value); this }
    public func limits(value: HttpLimits): HttpServerBuilder { configuredLimits = value; this }
    public func tls(value: HttpServerTlsConfig): HttpServerBuilder { tlsConfig = Some(value); this }

    public func connectionLimit(value: Int64): HttpServerBuilder {
        maximumConnections = value
        this
    }

    public func requestsPerConnectionLimit(value: Int64): HttpServerBuilder {
        maximumRequestsPerConnection = value
        this
    }

    public func listenBacklog(value: Int64): HttpServerBuilder { backlog = value; this }

    public func build(): HttpServer {
        let selectedEndpoint = match (endpoint) {
            case Some(value) => value
            case None => throw IllegalStateException("HTTP server listen endpoint is required")
        }
        let selectedHandler = match (configuredHandler) {
            case Some(value) => value
            case None => throw IllegalStateException("HTTP server handler is required")
        }
        let handshaker = match (tlsConfig) {
            case Some(value) => Some<http1.Http1ServerTlsHandshaker>(value.createHandshaker())
            case None => None<http1.Http1ServerTlsHandshaker>
        }
        var listener: ?stdnet.StdNetTransportListener = None<stdnet.StdNetTransportListener>
        try {
            let bound = stdnet.StdNetTransportListener.bind(selectedEndpoint, backlog: backlog)
            listener = Some(bound)
            let core = http1.Http1Server(
                bound,
                PublicHttp1Handler(selectedHandler),
                config: http1.Http1ServerConfig(
                    maximumConnections: maximumConnections,
                    maximumRequestsPerConnection: maximumRequestsPerConnection,
                    limits: configuredLimits
                ),
                tlsHandshaker: handshaker
            )
            HttpServer(core, bound.localEndpoint)
        } catch (error: Exception) {
            match (listener) { case Some(value) => value.close(); case None => () }
            match (handshaker) { case Some(value) => value.close(); case None => () }
            throw error
        }
    }
}

private func cloneHttpServerDerChain(values: Array<Array<Byte>>): Array<Array<Byte>> {
    let result = ArrayList<Array<Byte>>()
    for (value in values) { result.add(value.clone()) }
    result.toArray()
}

private func zeroHttpServerBytes(value: Array<Byte>): Unit {
    for (index in 0..value.size) { value[index] = 0 }
}

private func toInternalClientAuthentication(
    value: HttpServerClientAuthentication
): tls.ClientAuthentication {
    match (value) {
        case HttpServerClientAuthentication.None => tls.ClientAuthentication.None
        case HttpServerClientAuthentication.Optional => tls.ClientAuthentication.Optional
        case HttpServerClientAuthentication.Required => tls.ClientAuthentication.Required
    }
}

private func toInternalSecurityProfile(
    value: HttpServerTlsSecurityProfile
): tls.TlsSecurityProfile {
    match (value) {
        case HttpServerTlsSecurityProfile.Modern => tls.TlsSecurityProfile.Modern
        case HttpServerTlsSecurityProfile.StrictTls13 => tls.TlsSecurityProfile.StrictTls13
    }
}

public class HttpServer <: Resource {
    private let core: http1.Http1Server
    public let localEndpoint: SocketEndpoint

    init(core: http1.Http1Server, localEndpoint: SocketEndpoint) {
        this.core = core
        this.localEndpoint = localEndpoint
    }

    public static func builder(): HttpServerBuilder { HttpServerBuilder() }
    public func serve(context!: OperationContext = OperationContext.background()): Unit {
        core.serve(context: context)
    }
    public func shutdown(context!: OperationContext = OperationContext.background()): HttpServerShutdownResult {
        core.shutdown(context: context)
    }
    public func close(): Unit { core.close() }
    public func isClosed(): Bool { core.isClosed() }
}

private class PublicHttp1Handler <: http1.Http1ServerHandler {
    private let delegate: HttpServerHandler
    init(delegate: HttpServerHandler) { this.delegate = delegate }

    public func handle(request: http1.Http1ServerRequest,
        context: transport.OperationContext): http1.Http1ServerResponse {
        let response = delegate.handle(HttpServerRequest(request), context)
        http1.Http1ServerResponse(response.response, trailer: response.trailer)
    }
}
