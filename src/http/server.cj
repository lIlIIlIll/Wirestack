package wirestack.http

import wirestack.internal.http1 as http1
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet

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

    public init() {}

    public func listen(value: SocketEndpoint): HttpServerBuilder { endpoint = Some(value); this }
    public func handler(value: HttpServerHandler): HttpServerBuilder { configuredHandler = Some(value); this }
    public func limits(value: HttpLimits): HttpServerBuilder { configuredLimits = value; this }

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
        let listener = stdnet.StdNetTransportListener.bind(selectedEndpoint, backlog: backlog)
        try {
            let core = http1.Http1Server(
                listener,
                PublicHttp1Handler(selectedHandler),
                config: http1.Http1ServerConfig(
                    maximumConnections: maximumConnections,
                    maximumRequestsPerConnection: maximumRequestsPerConnection,
                    limits: configuredLimits
                )
            )
            HttpServer(core, listener.localEndpoint)
        } catch (error: Exception) {
            listener.close()
            throw error
        }
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
