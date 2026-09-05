package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2
import wirestack.internal.tls_engine as tls
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet
import wirestack as api

/**
 * Wirestack 公开 API：HttpServerClientAuthentication。
 */
public enum HttpServerClientAuthentication {
/**
 * Wirestack 公开 API：None。
 */
    | None
/**
 * Wirestack 公开 API：Optional。
 */
    | Optional
/**
 * Wirestack 公开 API：Required。
 */
    | Required
}

/**
 * Wirestack 公开 API：HttpServerTlsSecurityProfile。
 */
public enum HttpServerTlsSecurityProfile {
/**
 * Wirestack 公开 API：Modern。
 */
    | Modern
/**
 * Wirestack 公开 API：StrictTls13。
 */
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

/**
 * Wirestack 公开 API：init。
 * @param certificateChainDer 参数 certificateChainDer。
 * @param clientAuthentication 参数 clientAuthentication。
 * @param clientTrustRootsDer 参数 clientTrustRootsDer。
 * @param privateKeyPkcs8Der 参数 privateKeyPkcs8Der。
 * @param securityProfile 参数 securityProfile。
 */
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

    internal func createHandshaker(): http1.HttpServerAlpnHandshaker {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP server TLS configuration is closed") }
            http1.DefaultHttp1ServerTlsHandshaker.createAlpn(
                cloneHttpServerDerChain(certificateChain),
                privateKey.clone(),
                clientAuthentication: toInternalClientAuthentication(authentication),
                clientTrustRootsDer: cloneHttpServerDerChain(trustRoots),
                securityProfile: toInternalSecurityProfile(profile)
            )
        }
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        synchronized(mutex) {
            if (!closed) {
                zeroHttpServerBytes(privateKey)
                privateKey = Array<Byte>()
                closed = true
            }
        }
    }

/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    ~init() { zeroHttpServerBytes(privateKey) }
}

/** Public, protocol-neutral view of one incoming HTTP request. */
public class HttpServerRequest {
/**
 * Wirestack 公开 API：method。
 */
    public let method: HttpMethod
/**
 * Wirestack 公开 API：target。
 */
    public let target: String
/**
 * Wirestack 公开 API：version。
 */
    public let version: HttpVersion
/**
 * Wirestack 公开 API：headers。
 */
    public let headers: HttpHeaders
/**
 * Wirestack 公开 API：body。
 */
    public let body: ResponseBody
/**
 * Wirestack 公开 API：requestCancellation。
 */
    public let requestCancellation: HttpRequestCancellationHandle
/**
 * Wirestack 公开 API：connectionCancellation。
 */
    public let connectionCancellation: HttpConnectionCancellationHandle
/**
 * Wirestack 公开 API：streamCancellation。
 */
    public let streamCancellation: ?HttpStreamCancellationHandle

    init(
        value: http1.Http1ServerRequest,
        requestCancellation: HttpRequestCancellationHandle,
        connectionCancellation: HttpConnectionCancellationHandle,
        body: ResponseBody
    ) {
        method = value.head.method
        target = value.head.target
        version = value.head.version
        headers = value.head.headers
        this.body = body
        this.requestCancellation = requestCancellation
        this.connectionCancellation = connectionCancellation
        streamCancellation = None<HttpStreamCancellationHandle>
    }

    init(
        value: http2.Http2ServerRequest,
        requestCancellation: HttpRequestCancellationHandle,
        connectionCancellation: HttpConnectionCancellationHandle,
        streamCancellation: HttpStreamCancellationHandle,
        body: ResponseBody
    ) {
        method = value.head.method
        target = value.head.target
        version = HttpVersion.Http2
        headers = value.head.headers
        this.body = body
        this.requestCancellation = requestCancellation
        this.connectionCancellation = connectionCancellation
        this.streamCancellation = Some(streamCancellation)
    }
}

/** Handler-owned response and optional chunk trailer. */
public class HttpServerResponse {
/**
 * Wirestack 公开 API：response。
 */
    public let response: HttpResponse
/**
 * Wirestack 公开 API：trailer。
 */
    public let trailer: HttpTrailer

/**
 * Wirestack 公开 API：init。
 * @param response 参数 response。
 * @param trailer 参数 trailer。
 */
    public init(response: HttpResponse, trailer!: HttpTrailer = HttpTrailer()) {
        this.response = response
        this.trailer = trailer
    }
}

/**
 * Wirestack 公开 API：HttpServerHandler。
 */
public interface HttpServerHandler {
/**
 * Wirestack 公开 API：handle。
 * @param context 参数 context。
 * @param request 参数 request。
 */
    func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse
}

/**
 * Wirestack 公开 API：HttpServerShutdownResult。
 */
public type HttpServerShutdownResult = api.HttpServerShutdownResult

/**
 * Wirestack 公开 API：HttpServerBuilder。
 */
public class HttpServerBuilder {
    private var endpoint: ?SocketEndpoint = None<SocketEndpoint>
    private var configuredHandler: ?HttpServerHandler = None<HttpServerHandler>
    private var configuredLimits = HttpLimits()
    private var maximumConnections: Int64 = 1024
    private var maximumRequestsPerConnection: Int64 = 1000
    private var backlog: Int64 = 128
    private var maximumHttp2Streams: UInt32 = 100u32
    private var tlsConfig: ?HttpServerTlsConfig = None<HttpServerTlsConfig>

/**
 * Wirestack 公开 API：init。
 */
    public init() {}

/**
 * Wirestack 公开 API：listen。
 * @param value 参数 value。
 */
    public func listen(value: SocketEndpoint): HttpServerBuilder { endpoint = Some(value); this }
/**
 * Wirestack 公开 API：handler。
 * @param value 参数 value。
 */
    public func handler(value: HttpServerHandler): HttpServerBuilder { configuredHandler = Some(value); this }
/**
 * Wirestack 公开 API：limits。
 * @param value 参数 value。
 */
    public func limits(value: HttpLimits): HttpServerBuilder { configuredLimits = value; this }
/**
 * Wirestack 公开 API：tls。
 * @param value 参数 value。
 */
    public func tls(value: HttpServerTlsConfig): HttpServerBuilder { tlsConfig = Some(value); this }

/**
 * Wirestack 公开 API：connectionLimit。
 * @param value 参数 value。
 */
    public func connectionLimit(value: Int64): HttpServerBuilder {
        maximumConnections = value
        this
    }

/**
 * Wirestack 公开 API：requestsPerConnectionLimit。
 * @param value 参数 value。
 */
    public func requestsPerConnectionLimit(value: Int64): HttpServerBuilder {
        maximumRequestsPerConnection = value
        this
    }

/**
 * Wirestack 公开 API：listenBacklog。
 * @param value 参数 value。
 */
    public func listenBacklog(value: Int64): HttpServerBuilder { backlog = value; this }

/**
 * Sets the hard concurrent stream bound advertised by each HTTP/2 connection.
 * @param value 参数 value。
 */
    public func http2StreamLimit(value: UInt32): HttpServerBuilder {
        if (value == 0u32) { throw IllegalArgumentException("HTTP/2 stream limit must be positive") }
        maximumHttp2Streams = value
        this
    }

/**
 * Wirestack 公开 API：build。
 */
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
            case Some(value) => Some<http1.HttpServerAlpnHandshaker>(value.createHandshaker())
            case None => None<http1.HttpServerAlpnHandshaker>
        }
        var listener: ?stdnet.StdNetTransportListener = None<stdnet.StdNetTransportListener>
        try {
            let bound = stdnet.StdNetTransportListener.bind(selectedEndpoint, backlog: backlog)
            listener = Some(bound)
            let dispatcher = PublicServerConnectionDispatcher(
                selectedHandler, handshaker, configuredLimits,
                http2.Http2Limits(maxConcurrentStreams: maximumHttp2Streams),
                maximumRequestsPerConnection
            )
            let core = http1.Http1Server(
                bound,
                PublicHttp1Handler(selectedHandler),
                config: http1.Http1ServerConfig(
                    maximumConnections: maximumConnections,
                    maximumRequestsPerConnection: maximumRequestsPerConnection,
                    limits: configuredLimits
                ),
                connectionHandler: Some<http1.HttpServerConnectionHandler>(dispatcher)
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

/**
 * Wirestack 公开 API：HttpServer。
 */
public class HttpServer <: Resource {
    private let core: http1.Http1Server
/**
 * Wirestack 公开 API：localEndpoint。
 */
    public let localEndpoint: SocketEndpoint

    init(core: http1.Http1Server, localEndpoint: SocketEndpoint) {
        this.core = core
        this.localEndpoint = localEndpoint
    }

/**
 * Wirestack 公开 API：builder。
 */
    public static func builder(): HttpServerBuilder { HttpServerBuilder() }
/**
 * Wirestack 公开 API：serve。
 * @param context 参数 context。
 */
    public func serve(context!: OperationContext = OperationContext.background()): Unit {
        core.serve(context: context)
    }
/**
 * Wirestack 公开 API：shutdown。
 * @param context 参数 context。
 */
    public func shutdown(context!: OperationContext = OperationContext.background()): HttpServerShutdownResult {
        core.shutdown(context: context)
    }
/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit { core.close() }
/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { core.isClosed() }
}

private class PublicHttp1Handler <: http1.Http1ServerHandler {
    private let delegate: HttpServerHandler
    private let connectionCancellation: HttpConnectionCancellationHandle
    init(
        delegate: HttpServerHandler,
        connectionCancellation!: HttpConnectionCancellationHandle = HttpConnectionCancellationHandle()
    ) {
        this.delegate = delegate
        this.connectionCancellation = connectionCancellation
    }

/**
 * Wirestack 公开 API：handle。
 * @param context 参数 context。
 * @param request 参数 request。
 */
    public func handle(request: http1.Http1ServerRequest,
        context: transport.OperationContext): http1.Http1ServerResponse {
        let requestCancellation = HttpRequestCancellationHandle()
        let cancellation = HttpRequestCancellationOperation(
            context, Some(requestCancellation), Some(connectionCancellation),
            None<HttpStreamCancellationHandle>
        )
        cancellation.retain(requestCancellation.cancellationToken.register { =>
            let _ = connectionCancellation.cancel()
        })
        try {
            let response = delegate.handle(
                HttpServerRequest(
                    request, requestCancellation, connectionCancellation,
                    cancellation.wrapRequestBody(request.body)
                ),
                cancellation.context
            )
            http1.Http1ServerResponse(
                cancellation.wrap(response.response), trailer: response.trailer
            )
        } catch (error: Exception) {
            cancellation.fail()
            throw error
        }
    }
}

private class PublicHttp2Handler <: http2.Http2ServerHandler {
    private let delegate: HttpServerHandler
    private let connectionCancellation: HttpConnectionCancellationHandle
    init(delegate: HttpServerHandler, connectionCancellation: HttpConnectionCancellationHandle) {
        this.delegate = delegate
        this.connectionCancellation = connectionCancellation
    }

/**
 * Wirestack 公开 API：handle。
 * @param context 参数 context。
 * @param request 参数 request。
 */
    public func handle(request: http2.Http2ServerRequest,
        context: transport.OperationContext): http2.Http2ServerResponse {
        let requestCancellation = HttpRequestCancellationHandle()
        let streamCancellation = HttpStreamCancellationHandle()
        let cancellation = HttpRequestCancellationOperation(
            context, Some(requestCancellation), Some(connectionCancellation),
            Some(streamCancellation)
        )
        cancellation.retain(requestCancellation.cancellationToken.register { => request.cancelStream() })
        cancellation.retain(streamCancellation.cancellationToken.register { => request.cancelStream() })
        try {
            let response = delegate.handle(
                HttpServerRequest(
                    request, requestCancellation, connectionCancellation, streamCancellation,
                    cancellation.wrapRequestBody(request.body)
                ),
                cancellation.context
            )
            http2.Http2ServerResponse(
                cancellation.wrap(response.response), trailer: response.trailer
            )
        } catch (error: Exception) {
            cancellation.fail()
            throw error
        }
    }
}

/** Owns TLS negotiation and keeps every live H2 connection available to graceful shutdown. */
private class PublicServerConnectionDispatcher <: http1.HttpServerConnectionHandler {
    private let publicHandler: HttpServerHandler
    private let tlsHandshaker: ?http1.HttpServerAlpnHandshaker
    private let limits: HttpLimits
    private let http2Limits: http2.Http2Limits
    private let maximumHttp1Requests: Int64
    private let mutex = Mutex()
    private let h2Connections = ArrayList<PublicHttp2ConnectionEntry>()
    private var nextConnectionId: Int64 = 1
    private var stopping = false
    private var closed = false

    init(
        handler: HttpServerHandler,
        tlsHandshaker: ?http1.HttpServerAlpnHandshaker,
        limits: HttpLimits,
        http2Limits: http2.Http2Limits,
        maximumHttp1Requests: Int64
    ) {
        publicHandler = handler
        this.tlsHandshaker = tlsHandshaker
        this.limits = limits
        this.http2Limits = http2Limits
        this.maximumHttp1Requests = maximumHttp1Requests
    }

/**
 * Wirestack 公开 API：serve。
 * @param context 参数 context。
 * @param value 参数 value。
 */
    public func serve(value: transport.DuplexTransport, context: transport.OperationContext): Unit {
        match (tlsHandshaker) {
            case None => serveHttp1(value, context)
            case Some(handshaker) =>
                let negotiated = handshaker.handshakeNegotiated(value, context)
                match (negotiated.protocol) {
                    case http1.HttpServerNegotiatedProtocol.Http11 =>
                        serveHttp1(negotiated.transport, context)
                    case http1.HttpServerNegotiatedProtocol.Http2 =>
                        serveHttp2(negotiated.transport, context)
                }
        }
    }

/**
 * Wirestack 公开 API：beginShutdown。
 */
    public func beginShutdown(): Unit {
        let current = synchronized(mutex) {
            stopping = true
            let result = ArrayList<http2.Http2ServerConnection>()
            for (entry in h2Connections) { result.add(entry.connection) }
            result.toArray()
        }
        for (connection in current) { connection.beginDrain() }
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            if (closed) { false } else { closed = true; true }
        }
        if (shouldClose) {
            beginShutdown()
            match (tlsHandshaker) { case Some(value) => value.close(); case None => () }
        }
    }

/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func serveHttp1(
        transportValue: transport.DuplexTransport,
        context: transport.OperationContext
    ): Unit {
        let cancellation = HttpConnectionCancellationHandle()
        let registration = cancellation.cancellationToken.register { =>
            try { transportValue.abort(reason: Some(transport.AbortReason.Cancelled)) }
            catch (_: Exception) {}
        }
        try {
            let _ = http1.serveHttp1Connection(
                transportValue, PublicHttp1Handler(
                    publicHandler, connectionCancellation: cancellation
                ),
                context: context, limits: limits,
                maximumRequests: maximumHttp1Requests
            )
        } finally { registration.unregister() }
    }

    private func serveHttp2(
        secured: transport.DuplexTransport,
        context: transport.OperationContext
    ): Unit {
        let cancellation = HttpConnectionCancellationHandle()
        let created = http2.Http2ServerConnection(
            secured, PublicHttp2Handler(publicHandler, cancellation),
            limits: limits, http2Limits: http2Limits
        )
        let cancellationRegistration = cancellation.cancellationToken.register { =>
            created.abort()
        }
        var connectionId: Int64 = 0
        let admitted = synchronized(mutex) {
            if (stopping) { false } else {
                connectionId = nextConnectionId
                nextConnectionId++
                h2Connections.add(PublicHttp2ConnectionEntry(connectionId, created))
                true
            }
        }
        if (!admitted) { cancellationRegistration.unregister(); created.abort(); return }
        try { created.serve(context: context) }
        finally {
            cancellationRegistration.unregister()
            synchronized(mutex) {
                for (index in 0..h2Connections.size) {
                    if (h2Connections[index].id == connectionId) {
                        let _ = h2Connections.remove(at: index)
                        break
                    }
                }
            }
        }
    }
}

private class PublicHttp2ConnectionEntry {
    let id: Int64
    let connection: http2.Http2ServerConnection
    init(id: Int64, connection: http2.Http2ServerConnection) {
        this.id = id
        this.connection = connection
    }
}
