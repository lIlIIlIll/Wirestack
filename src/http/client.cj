package wirestack.http

import std.sync.Mutex
import wirestack.internal.http1 as http1
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum HttpClientCapabilityErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemResolverUnavailable
}

/** A requested default capability is unavailable rather than silently weakened. */
public class HttpClientCapabilityException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: HttpClientCapabilityErrorCode

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 */
    public init(code: HttpClientCapabilityErrorCode, message: String) {
        super(message)
        this.code = code
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "HttpClientCapabilityException" }
}

/**
 * Wirestack 公开 API：提供构造不可变公开值的步骤。
 */
public class HttpClientBuilder {
    private var configuredResolver: ?Resolver = None<Resolver>
    private var configuredRequestTimeout: ?Duration = None<Duration>
    private var configuredLimits = HttpLimits()
    private var configuredRedirectPolicy = HttpRedirectPolicy()
    private var configuredRetryPolicy = HttpRetryPolicy()
    private var configuredProxy: ?HttpProxyConfig = None<HttpProxyConfig>
    private var configuredTls: ?HttpClientTlsConfig = None<HttpClientTlsConfig>
    private var configuredCookieJar: ?CookieJar = None<CookieJar>
    private var configuredConnector: ?HttpConnector = None<HttpConnector>
    private var configuredPoolHook: ?HttpConnectionPoolHook = None<HttpConnectionPoolHook>
    private var configuredPush: ?Http2PushConfig = None<Http2PushConfig>

/**
 * Wirestack 公开 API：init。
 */
    public init() {}

/**
 * Installs a caller-owned provider-neutral resolver instead of the Linux system resolver.
 * @param value 参数 value。
 */
    public func resolver(value: Resolver): HttpClientBuilder {
        configuredResolver = Some(value)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func requestTimeout(value: Duration): HttpClientBuilder {
        if (value <= Duration.Zero) { throw IllegalArgumentException("request timeout must be positive") }
        configuredRequestTimeout = Some(value)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func limits(value: HttpLimits): HttpClientBuilder {
        configuredLimits = value
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func redirectPolicy(value: HttpRedirectPolicy): HttpClientBuilder {
        configuredRedirectPolicy = value
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func retryPolicy(value: HttpRetryPolicy): HttpClientBuilder {
        configuredRetryPolicy = value
        this
    }

/**
 * Installs one explicit proxy route. Environment, PAC, and WPAD are never consulted.
 * @param value 待写入或配置的值。
 */
    public func proxy(value: HttpProxyConfig): HttpClientBuilder {
        configuredProxy = Some(value)
        this
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param value 待写入或配置的值。
 */
    public func tls(value: HttpClientTlsConfig): HttpClientBuilder {
        configuredTls = Some(value)
        this
    }

    /**
     * Installs a caller-owned jar. Explicit request Cookie headers take precedence over jar selection.
     * @param value Jar shared by requests, retries and redirects.
     */
    public func cookieJar(value: CookieJar): HttpClientBuilder {
        configuredCookieJar = Some(value)
        this
    }

    /**
     * Replaces DNS-free connection attempts while retaining resolver, route and pool policy.
     * @param value Caller-owned factory; returned transports transfer to the client.
     */
    public func connector(value: HttpConnector): HttpClientBuilder {
        configuredConnector = Some(value)
        this
    }

    /**
     * Observes actual pool lease transitions without exposing security credentials or body data.
     * @param value Caller-owned, non-blocking observer.
     */
    public func poolHook(value: HttpConnectionPoolHook): HttpClientBuilder {
        configuredPoolHook = Some(value)
        this
    }

    /**
     * Enables bounded HTTP/2 push acceptance. Omission keeps SETTINGS_ENABLE_PUSH disabled.
     * @param value Caller-owned policy and delivery limits.
     */
    public func http2Push(value: Http2PushConfig): HttpClientBuilder {
        configuredPush = Some(value)
        this
    }

/**
 * Wirestack 公开 API：build。
 */
    public func build(): HttpClient {
        var ownedSystemResolver = None<SystemResolver>
        let selected: Resolver = match (configuredResolver) {
            case Some(value) => value
            case None =>
                let value = SystemResolver(workerCount: 4, queueCapacity: 64)
                ownedSystemResolver = Some(value)
                value
        }
        var directTls = None<http1.HttpAlpnTlsHandshaker>
        var proxyTls = None<http1.Http1TlsHandshaker>
        try {
            if (let Some(value) <- configuredTls) {
                directTls = Some(value.createAlpnHandshaker())
                if (configuredProxy.isSome()) { proxyTls = Some(value.createHandshaker()) }
            }
            let selectedConnector: transport.TransportFactory = match (configuredConnector) {
                case Some(value) => value
                case None => stdnet.StdNetTransportFactory()
            }
            HttpClient(
                selected, configuredRequestTimeout, configuredLimits,
                configuredRedirectPolicy, configuredRetryPolicy, configuredProxy,
                directTls, proxyTls, ownedSystemResolver,
                selectedConnector, configuredCookieJar, configuredPoolHook, configuredPush
            )
        } catch (error: Exception) {
            match (directTls) { case Some(value) => value.close(); case None => () }
            match (proxyTls) { case Some(value) => value.close(); case None => () }
            match (ownedSystemResolver) { case Some(value) => value.close(); case None => () }
            throw error
        }
    }
}

/** HTTP facade. HTTPS initializes the build-selected TLS handshaker lazily. */
public class HttpClient <: Resource {
    private let resolver: Resolver
    private let ownedSystemResolver: ?SystemResolver
    private let requestTimeout: ?Duration
    private let limits: HttpLimits
    private let redirectPolicy: HttpRedirectPolicy
    private let retryPolicy: HttpRetryPolicy
    private let proxy: ?HttpProxyConfig
    private let transportFactory: transport.TransportFactory
    private let cookieJar: ?CookieJar
    private let poolHook: ?HttpConnectionPoolHook
    private let pushConfig: ?Http2PushConfig
    private let cleartext: http1.Http1CleartextClient
    private let forwardProxy: ?http1.Http1ForwardProxyClient
    private let mutex = Mutex()
    private var https: ?http1.HttpAutomaticHttpsClient = None<http1.HttpAutomaticHttpsClient>
    private var httpsProxy: ?http1.Http1HttpsProxyClient = None<http1.Http1HttpsProxyClient>
    private var closed = false

    init(resolver: Resolver, requestTimeout: ?Duration, limits: HttpLimits,
        redirectPolicy: HttpRedirectPolicy, retryPolicy: HttpRetryPolicy,
        proxy: ?HttpProxyConfig,
        directTlsHandshaker: ?http1.HttpAlpnTlsHandshaker,
        proxyTlsHandshaker: ?http1.Http1TlsHandshaker,
        ownedSystemResolver: ?SystemResolver,
        transportFactory: transport.TransportFactory,
        cookieJar: ?CookieJar,
        poolHook: ?HttpConnectionPoolHook,
        pushConfig: ?Http2PushConfig) {
        this.resolver = resolver
        this.ownedSystemResolver = ownedSystemResolver
        this.requestTimeout = requestTimeout
        this.limits = limits
        this.redirectPolicy = redirectPolicy
        this.retryPolicy = retryPolicy
        this.proxy = proxy
        this.transportFactory = transportFactory
        this.cookieJar = cookieJar
        this.poolHook = poolHook
        this.pushConfig = pushConfig
        cleartext = http1.Http1CleartextClient(resolver, transportFactory, limits: limits)
        forwardProxy = match (proxy) {
            case Some(value) => Some(http1.Http1ForwardProxyClient(
                toInternalProxyEndpoint(value.endpoint), value.resolver, transportFactory, limits: limits
            ))
            case None => None<http1.Http1ForwardProxyClient>
        }
        https = match (directTlsHandshaker) {
            case Some(value) => Some(http1.HttpAutomaticHttpsClient(
                resolver, transportFactory, value, limits: limits, pushConfig: pushConfig
            ))
            case None => None<http1.HttpAutomaticHttpsClient>
        }
        httpsProxy = match ((proxy, proxyTlsHandshaker)) {
            case (Some(value), Some(handshaker)) => Some(http1.Http1HttpsProxyClient(
                toInternalProxyEndpoint(value.endpoint), value.resolver, transportFactory,
                handshaker, limits: limits
            ))
            case _ => None<http1.Http1HttpsProxyClient>
        }
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public static func default(): HttpClient { HttpClient.builder().build() }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public static func builder(): HttpClientBuilder { HttpClientBuilder() }

/**
 * Wirestack 公开 API：返回与当前对象关联的值。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param url 调用方提供的输入值。
 */
    public func get(url: String,
        context!: OperationContext = OperationContext.background()): HttpResponse {
        send(parseGetRequest(url), context: context)
    }

/**
 * Wirestack 公开 API：返回与当前对象关联的值。
 * @param cancellation 调用方提供的输入值。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param url 调用方提供的输入值。
 */
    public func getControlled(
        url: String,
        cancellation: HttpCancellationHandles,
        context!: OperationContext = OperationContext.background()
    ): HttpResponse {
        sendControlled(parseGetRequest(url), cancellation, context: context)
    }

    private func parseGetRequest(url: String): HttpRequest {
        let request = try {
            HttpRequest.get(url)
        } catch (error: Exception) {
            throw HttpException(HttpErrorCode.InvalidUrl, "invalid HTTP URL", cause: error)
        }
        request
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param request 待处理的 HTTP 请求。
 * @param trailer 调用方提供的输入值。
 */
    public func send(request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()
    ): HttpResponse {
        sendInternal(
            request, context, trailer,
            None<HttpRequestCancellationHandle>,
            None<HttpConnectionCancellationHandle>,
            None<HttpStreamCancellationHandle>
        )
    }

    /**
     * Establishes an uncompressed WebSocket over HTTP/1.1 or negotiated HTTP/2.
     * Rejected handshakes return an owned response. No redirects or retries replay the handshake.
     * @param url Absolute HTTP or HTTPS URL of the WebSocket resource.
     * @param protocols Ordered acceptable subprotocols.
     * @param headers Additional headers excluding protocol-managed fields.
     * @param webSocketLimits Session frame, message and close bounds.
     * @param context Shared handshake deadline and cancellation.
     */
    public func connectWebSocket(
        url: HttpUrl,
        protocols!: Array<String> = [],
        headers!: HttpHeaders = HttpHeaders(),
        webSocketLimits!: WebSocketLimits = WebSocketLimits(),
        context!: OperationContext = OperationContext.background()
    ): WebSocketConnectResult {
        if (isClosed()) { throw IllegalStateException("HTTP client is closed") }
        let bounded = match (requestTimeout) {
            case Some(value) => context.shortenDeadline(value)
            case None => context
        }
        let operation = withHttpPoolHook(bounded, poolHook)
        let handshake = WebSocketHandshake(url, protocols, headers, limits)
        let h1Request = requestWithCookies(handshake.http1Request, operation)
        let h2Request = requestWithCookies(handshake.http2Request, operation)
        let result = executeDuplex(h1Request, h2Request, Some("websocket"), operation)
        handshake.accept(result, webSocketLimits)
    }

    /**
     * Transfers a successful HTTP/1.1 Upgrade or CONNECT connection without replay.
     * HTTPS may negotiate HTTP/2, where the exchange uses a stream-scoped CONNECT.
     * @param request Bodyless CONNECT or HTTP/1.1 Upgrade handshake request.
     * @param protocol Required extended CONNECT protocol offered by Upgrade; absent only for ordinary CONNECT.
     * @param context Shared operation deadline and cancellation.
     */
    public func upgrade(request: HttpRequest, protocol!: ?String = None<String>,
        context!: OperationContext = OperationContext.background()): HttpUpgradeResult {
        if (isClosed()) { throw IllegalStateException("HTTP client is closed") }
        if (request.body.contentLength != Some(0)) {
            throw IllegalArgumentException("HTTP duplex handshakes require a known empty request body")
        }
        match (protocol) {
            case Some(value) =>
                let _ = HttpMethod(value)
                if (request.method == HttpMethod("CONNECT") ||
                    !http1.headerContainsToken(request.headers, "connection", "upgrade") ||
                    !http1.headerContainsToken(request.headers, "upgrade", value)) {
                    throw IllegalArgumentException("an Upgrade protocol requires a matching non-CONNECT Upgrade request")
                }
            case None =>
                if (request.method != HttpMethod("CONNECT")) {
                    throw IllegalArgumentException("an Upgrade request requires its extended CONNECT protocol")
                }
        }
        let bounded = match (requestTimeout) {
            case Some(value) => context.shortenDeadline(value)
            case None => context
        }
        let operation = withHttpPoolHook(bounded, poolHook)
        let outgoing = requestWithCookies(request, operation)
        let headers = HttpHeaders.builder(limits: limits)
        for (entry in outgoing.headers.entries) {
            let name = entry.name.toAsciiLower()
            if (name != "connection" && name != "upgrade" && name != "host") {
                headers.add(entry.name, entry.value)
            }
        }
        let h2Request = HttpRequest(HttpMethod("CONNECT"), request.url,
            headers: headers.build(), body: request.body, retrySafety: request.retrySafety)
        let result = executeDuplex(outgoing, h2Request, protocol, operation)
        publicHttpUpgradeResult(result)
    }

    private func executeDuplex(h1Request: HttpRequest, h2Request: HttpRequest,
        protocol: ?String, context: OperationContext): http1.HttpDuplexExchangeResult {
        let route = match (proxy) {
            case Some(value) => value.routeFor(h1Request.url)
            case None => HttpProxyRoute.Direct
        }
        let result = match ((h1Request.url.scheme, route)) {
            case ("http", HttpProxyRoute.Direct) =>
                http1.mapHttp1Upgrade(cleartext.upgrade(
                    withProxyAuthorization(h1Request, None<String>), context: context))
            case ("http", HttpProxyRoute.Proxy(value)) =>
                let authorization = value.authorization(h1Request.url, context)
                http1.mapHttp1Upgrade(forwardProxy.getOrThrow().upgrade(
                    withProxyAuthorization(h1Request, authorization), context: context))
            case ("https", HttpProxyRoute.Direct) =>
                httpsClient().upgrade(
                    withProxyAuthorization(h1Request, None<String>),
                    withProxyAuthorization(h2Request, None<String>),
                    protocol: protocol, context: context)
            case ("https", HttpProxyRoute.Proxy(value)) =>
                let authorization = value.authorization(h1Request.url, context)
                http1.mapHttp1Upgrade(httpsProxyClient(value).upgrade(
                    withProxyAuthorization(h1Request, None<String>),
                    proxyAuthorization: authorization, context: context))
            case _ => throw IllegalArgumentException("HTTP duplex exchange requires an HTTP or HTTPS URL")
        }
        match (result) {
            case http1.HttpDuplexExchangeResult.Response(response) =>
                try { captureCookies(response.headers, h1Request.url, context) }
                catch (error: Exception) { response.close(); throw error }
            case http1.HttpDuplexExchangeResult.Connected(connection) =>
                try { captureCookies(connection.headers, h1Request.url, context) }
                catch (error: Exception) { connection.transport.close(); throw error }
        }
        result
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param cancellation 调用方提供的输入值。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param request 待处理的 HTTP 请求。
 * @param trailer 调用方提供的输入值。
 */
    public func sendControlled(
        request: HttpRequest,
        cancellation: HttpCancellationHandles,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()
    ): HttpResponse {
        sendInternal(
            request, context, trailer,
            cancellation.request, cancellation.connection, cancellation.stream
        )
    }

    private func sendInternal(
        request: HttpRequest,
        context: OperationContext,
        trailer: HttpTrailer,
        requestCancellation: ?HttpRequestCancellationHandle,
        connectionCancellation: ?HttpConnectionCancellationHandle,
        streamCancellation: ?HttpStreamCancellationHandle
    ): HttpResponse {
        let bounded = match (requestTimeout) {
            case Some(value) => context.shortenDeadline(value)
            case None => context
        }
        let cancellation = HttpRequestCancellationOperation(
            bounded, requestCancellation, connectionCancellation, streamCancellation
        )
        let operation = withHttpPoolHook(cancellation.context, poolHook)
        try {
            var current = request
            var redirectCount: Int64 = 0
            while (true) {
                let response = executeWithRetries(
                    current, operation, trailer, cancellation.connectionCancellation
                )
                let next = try {
                    redirectPolicy.nextRequest(
                        current, response, redirectsFollowed: redirectCount, limits: limits
                    )
                } catch (error: Exception) {
                    response.close()
                    throw error
                }
                match (next) {
                    case Some(value) =>
                        try { let _ = response.body.drain(redirectPolicy.maximumDrainBytes) }
                        finally { response.close() }
                        current = value
                        redirectCount++
                    case None => return cancellation.wrap(response)
                }
            }
            throw Exception("unreachable HTTP redirect loop exit")
        } catch (error: Exception) {
            cancellation.fail()
            throw wrapHttpError(error)
        }
    }

    private func executeOnce(request: HttpRequest, operation: OperationContext,
        trailer: HttpTrailer,
        connectionCancellation: transport.CancellationToken
    ): HttpResponse {
        if (isClosed()) { throw IllegalStateException("HTTP client is closed") }
        let route = match (proxy) {
            case Some(value) => value.routeFor(request.url)
            case None => HttpProxyRoute.Direct
        }
        match ((request.url.scheme, route)) {
            case ("http", HttpProxyRoute.Direct) =>
                cleartext.execute(withProxyAuthorization(request, None<String>),
                    context: operation, trailer: trailer)
            case ("http", HttpProxyRoute.Proxy(value)) =>
                let authorization = value.authorization(request.url, operation)
                forwardProxy.getOrThrow().execute(
                    withProxyAuthorization(request, authorization), context: operation, trailer: trailer
                )
            case ("https", HttpProxyRoute.Direct) =>
                httpsClient().execute(withProxyAuthorization(request, None<String>),
                    context: operation, trailer: trailer,
                    connectionCancellation: connectionCancellation)
            case ("https", HttpProxyRoute.Proxy(value)) =>
                let authorization = value.authorization(request.url, operation)
                httpsProxyClient(value).execute(
                    withProxyAuthorization(request, None<String>),
                    proxyAuthorization: authorization,
                    context: operation,
                    trailer: trailer
                )
            case _ => throw IllegalArgumentException("HTTP client accepts only http and https URLs")
        }
    }

    private func executeWithRetries(request: HttpRequest, operation: OperationContext,
        trailer: HttpTrailer,
        connectionCancellation: transport.CancellationToken
    ): HttpResponse {
        var attempt: Int64 = 1
        while (true) {
            try {
                let outgoing = requestWithCookies(request, operation)
                let response = executeOnce(outgoing, operation, trailer, connectionCancellation)
                try {
                    captureCookies(response.headers, request.url, operation)
                } catch (error: Exception) {
                    response.close()
                    throw error
                }
                return response
            } catch (error: Exception) {
                if (!retryPolicy.shouldRetry(request, error, attempt, operation)) { throw error }
                attempt++
            }
        }
        throw Exception("unreachable HTTP retry loop exit")
    }

    private func requestWithCookies(request: HttpRequest, context: OperationContext): HttpRequest {
        if (request.headers.getFirst("cookie").isSome()) { return request }
        let jar = match (cookieJar) { case Some(value) => value; case None => return request }
        let selected = jar.headerFor(request.url, context: context)
        if (selected.isEmpty()) { return request }
        let headers = HttpHeaders.builder(limits: limits)
        for (entry in request.headers.entries) { headers.add(entry.name, entry.value) }
        headers.add("Cookie", selected)
        request.withHeaders(headers.build())
    }

    private func captureCookies(headers: HttpHeaders, url: HttpUrl, context: OperationContext): Unit {
        if (let Some(jar) <- cookieJar) {
            for (value in headers.getAll("set-cookie")) {
                let _ = jar.acceptSetCookie(value, url, context: context)
            }
        }
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        let (secure, tunneled) = synchronized(mutex) {
            if (closed) {
                (None<http1.HttpAutomaticHttpsClient>, None<http1.Http1HttpsProxyClient>)
            } else {
                closed = true
                (https, httpsProxy)
            }
        }
        cleartext.close()
        match (forwardProxy) { case Some(value) => value.close(); case None => () }
        match (secure) { case Some(value) => value.close(); case None => () }
        match (tunneled) { case Some(value) => value.close(); case None => () }
        match (ownedSystemResolver) { case Some(value) => value.close(); case None => () }
    }

/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func httpsClient(): http1.HttpAutomaticHttpsClient {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            match (https) {
                case Some(value) => value
                case None =>
                    let value = http1.HttpAutomaticHttpsClient(
                        resolver,
                        transportFactory,
                        http1.DefaultHttp1TlsHandshaker.systemDefaultAlpn(),
                        limits: limits, pushConfig: pushConfig
                    )
                    https = Some(value)
                    value
            }
        }
    }

    private func httpsProxyClient(value: HttpProxyConfig): http1.Http1HttpsProxyClient {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            match (httpsProxy) {
                case Some(client) => client
                case None =>
                    let client = http1.Http1HttpsProxyClient(
                        toInternalProxyEndpoint(value.endpoint),
                        value.resolver,
                        transportFactory,
                        http1.DefaultHttp1TlsHandshaker.systemDefault(),
                        limits: limits
                    )
                    httpsProxy = Some(client)
                    client
            }
        }
    }
}

private func toInternalProxyEndpoint(value: HttpProxyEndpoint): http1.Http1ProxyEndpoint {
    match ((value.hostName, value.ipAddress)) {
        case (Some(host), None) => http1.Http1ProxyEndpoint.hostname(host, value.port, value.identity)
        case (None, Some(address)) => http1.Http1ProxyEndpoint.address(address, value.port, value.identity)
        case _ => throw IllegalArgumentException("HTTP proxy endpoint has an invalid address form")
    }
}

/** Removes caller-supplied proxy credentials and adds only the route hook's validated value. */
private func withProxyAuthorization(request: HttpRequest, value: ?String): HttpRequest {
    let builder = HttpHeaders.builder()
    for (entry in request.headers.entries) {
        if (entry.name.toAsciiLower() != "proxy-authorization") {
            builder.add(entry.name, entry.value)
        }
    }
    if (let Some(authorization) <- value) {
        builder.add("Proxy-Authorization", authorization)
    }
    request.withHeaders(builder.build())
}
