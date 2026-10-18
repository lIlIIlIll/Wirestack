package wirestack.http

import std.sync.Mutex
import std.collection.ArrayList
import wirestack.internal.http1 as http1
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet
import wirestack.internal as internal

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
    private var configuredResourceLimits = HttpResourceLimits.clientDefault()
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
     * Sets the aggregate limits shared by every route and protocol pool.
     *
     * @param value The per-instance aggregate resource limits for this client.
     */
    public func resourceLimits(value: HttpResourceLimits): HttpClientBuilder {
        configuredResourceLimits = value
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
        let resourceBudget = internal.HttpResourceBudget(configuredResourceLimits.toBudgetPolicy())
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
                configuredResourceLimits, resourceBudget,
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
    private var resolver: Resolver
    private let ownedSystemResolver: ?SystemResolver
    private let requestTimeout: ?Duration
    private let limits: HttpLimits
    private let resourceLimits: HttpResourceLimits
    private let resourceBudget: internal.HttpResourceBudget
    private let redirectPolicy: HttpRedirectPolicy
    private let retryPolicy: HttpRetryPolicy
    private let proxy: ?HttpProxyConfig
    private let transportFactory: transport.TransportFactory
    private let cookieJar: ?CookieJar
    private let poolHook: ?HttpConnectionPoolHook
    private let pushConfig: ?Http2PushConfig
    private var cleartext: http1.Http1CleartextClient
    private var forwardProxy: ?http1.Http1ForwardProxyClient
    private let mutex = Mutex()
    private var https: ?http1.HttpAutomaticHttpsClient = None<http1.HttpAutomaticHttpsClient>
    private var httpsProxy: ?http1.Http1HttpsProxyClient = None<http1.Http1HttpsProxyClient>
    private var closed = false
    private var proxyResolver: ?Resolver = None<Resolver>
    private var directTlsLease: ?ClientAlpnTlsLease = None<ClientAlpnTlsLease>
    private var proxyTlsLease: ?ClientProxyTlsLease = None<ClientProxyTlsLease>
    private var cleartextSlot: ClientRotationSlot
    private var forwardSlot: ?ClientRotationSlot = None<ClientRotationSlot>
    private var secureSlot: ?ClientRotationSlot = None<ClientRotationSlot>
    private var tunnelSlot: ?ClientRotationSlot = None<ClientRotationSlot>
    private let generations = ArrayList<ClientRotationSlot>()
    private var tlsGeneration: UInt64 = 1
    private var directDnsGeneration: UInt64 = 1
    private var proxyDnsGeneration: UInt64 = 1
    private var nextTlsOwner: UInt64 = 3

    init(resolver: Resolver, requestTimeout: ?Duration, limits: HttpLimits,
        resourceLimits: HttpResourceLimits,
        resourceBudget: internal.HttpResourceBudget,
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
        this.resourceLimits = resourceLimits
        this.resourceBudget = resourceBudget
        this.redirectPolicy = redirectPolicy
        this.retryPolicy = retryPolicy
        this.proxy = proxy
        this.transportFactory = transportFactory
        this.cookieJar = cookieJar
        this.poolHook = poolHook
        this.pushConfig = pushConfig
        cleartext = http1.Http1CleartextClient(
            resolver, transportFactory, limits: limits, resourceBudget: Some(resourceBudget)
        )
        forwardProxy = match (proxy) {
            case Some(value) => Some(http1.Http1ForwardProxyClient(
                toInternalProxyEndpoint(value.endpoint), value.resolver, transportFactory,
                limits: limits, resourceBudget: Some(resourceBudget)
            ))
            case None => None<http1.Http1ForwardProxyClient>
        }
        let initialCleartext = cleartext
        cleartextSlot = ClientRotationSlot(initialCleartext, 0,
            { strict => if (strict) { initialCleartext.abortConnections() } else { initialCleartext.retire() } },
            { => emptyClientPool(initialCleartext.snapshot()) })
        directTlsLease = match (directTlsHandshaker) {
            case Some(value) => Some(ClientAlpnTlsLease(ClientTlsOwner(1, value), value))
            case None => None<ClientAlpnTlsLease>
        }
        proxyTlsLease = match (proxyTlsHandshaker) {
            case Some(value) => Some(ClientProxyTlsLease(ClientTlsOwner(2, value), value))
            case None => None<ClientProxyTlsLease>
        }
        proxyResolver = match (proxy) { case Some(value) => Some(value.resolver); case None => None<Resolver> }
        https = match (directTlsLease) {
            case Some(value) => Some(makeHttps(resolver, value))
            case None => None<http1.HttpAutomaticHttpsClient>
        }
        httpsProxy = match ((proxy, proxyTlsLease)) {
            case (Some(value), Some(handshaker)) => Some(makeTunnel(value, value.resolver, handshaker))
            case _ => None<http1.Http1HttpsProxyClient>
        }
        generations.add(cleartextSlot)
        if (let Some(value) <- forwardProxy) { forwardSlot = Some(wrapForward(value)); generations.add(forwardSlot.getOrThrow()) }
        if (let Some(value) <- https) { secureSlot = Some(wrapHttps(value, directTlsLease.getOrThrow().owner)); generations.add(secureSlot.getOrThrow()) }
        if (let Some(value) <- httpsProxy) { tunnelSlot = Some(wrapTunnel(value, proxyTlsLease.getOrThrow().owner)); generations.add(tunnelSlot.getOrThrow()) }
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
        let result = executeAdmittedDuplex(h1Request, h2Request, Some("websocket"), operation)
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
        let result = executeAdmittedDuplex(outgoing, h2Request, protocol, operation)
        publicHttpUpgradeResult(result)
    }

    private func executeDuplex(h1Request: HttpRequest, h2Request: HttpRequest,
        protocol: ?String, parent: OperationContext): http1.HttpDuplexExchangeResult {
        let (slot, invocation, lifetime) = selectGeneration(h1Request.url)
        let cancellation = HttpRequestCancellationOperation(parent, Some(slot.cancellation),
            None<HttpConnectionCancellationHandle>, None<HttpStreamCancellationHandle>)
        let context = cancellation.context
        var transferred = false
        try {
            let result = match (slot.client) {
                case value: http1.Http1CleartextClient =>
                    http1.mapHttp1Upgrade(value.upgrade(withProxyAuthorization(h1Request, None<String>), context: context))
                case value: http1.Http1ForwardProxyClient =>
                    let authorization = proxy.getOrThrow().authorization(h1Request.url, context)
                    http1.mapHttp1Upgrade(value.upgrade(withProxyAuthorization(h1Request, authorization), context: context))
                case value: http1.HttpAutomaticHttpsClient =>
                    value.upgrade(withProxyAuthorization(h1Request, None<String>),
                        withProxyAuthorization(h2Request, None<String>), protocol: protocol, context: context)
                case value: http1.Http1HttpsProxyClient =>
                    let authorization = proxy.getOrThrow().authorization(h1Request.url, context)
                    http1.mapHttp1Upgrade(value.upgrade(withProxyAuthorization(h1Request, None<String>),
                        proxyAuthorization: authorization, context: context))
                case _ => throw IllegalStateException("invalid HTTP duplex route generation")
            }
            match (result) {
                case http1.HttpDuplexExchangeResult.Response(response) =>
                    try { captureCookies(response.headers, h1Request.url, context) }
                    catch (error: Exception) { response.close(); throw error }
                    cancellation.retainResource(lifetime)
                    transferred = true
                    http1.HttpDuplexExchangeResult.Response(cancellation.wrap(response))
                case http1.HttpDuplexExchangeResult.Connected(connection) =>
                    try { captureCookies(connection.headers, h1Request.url, context) }
                    catch (error: Exception) { connection.transport.close(); throw error }
                    cancellation.fail()
                    transferred = true
                    http1.HttpDuplexExchangeResult.Connected(http1.HttpDuplexConnection(
                        connection.status, connection.headers, connection.version,
                        ClientRotationTransport(connection.transport, lifetime)))
            }
        } catch (error: Exception) { cancellation.fail(); throw error }
        finally {
            if (!transferred) { lifetime.close() }
            invocation.close()
        }
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
                let requestLease = resourceBudget.acquireRequest(
                    resourceOwner(current.url), operation.forStage(transport.OperationTimeoutStage.RequestAdmission)
                )
                cancellation.retainResource(requestLease)
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
                        finally {
                            response.close()
                            requestLease.close()
                        }
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

    private func resourceOwner(url: HttpUrl): internal.HttpResourceOwnerKey {
        let route = match (proxy) {
            case Some(value) =>
                match (value.routeFor(url)) {
                    case HttpProxyRoute.Direct => "direct"
                    case HttpProxyRoute.Proxy(config) => "proxy:${config.endpoint.identity}"
                }
            case None => "direct"
        }
        internal.HttpResourceOwnerKey("${url.scheme}://${url.host}:${url.port}", route)
    }

    private func executeOnce(request: HttpRequest, operation: OperationContext,
        trailer: HttpTrailer, connectionCancellation: transport.CancellationToken): HttpResponse {
        let (slot, invocation, lifetime) = selectGeneration(request.url)
        let cancellation = HttpRequestCancellationOperation(operation, Some(slot.cancellation),
            None<HttpConnectionCancellationHandle>, None<HttpStreamCancellationHandle>)
        cancellation.retainResource(lifetime)
        let context = cancellation.context
        try {
            let response = match (slot.client) {
                case value: http1.Http1CleartextClient =>
                    value.execute(withProxyAuthorization(request, None<String>), context: context, trailer: trailer)
                case value: http1.Http1ForwardProxyClient =>
                    let authorization = proxy.getOrThrow().authorization(request.url, context)
                    value.execute(withProxyAuthorization(request, authorization), context: context, trailer: trailer)
                case value: http1.HttpAutomaticHttpsClient =>
                    value.execute(withProxyAuthorization(request, None<String>), context: context,
                        trailer: trailer, connectionCancellation: connectionCancellation)
                case value: http1.Http1HttpsProxyClient =>
                    let authorization = proxy.getOrThrow().authorization(request.url, context)
                    value.execute(withProxyAuthorization(request, None<String>), proxyAuthorization: authorization,
                        context: context, trailer: trailer)
                case _ => throw IllegalStateException("invalid HTTP route generation")
            }
            cancellation.wrap(response)
        } catch (error: Exception) { cancellation.fail(); throw error }
        finally { invocation.close() }
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
        resourceBudget.closeAdmission()
        let retiring = synchronized(mutex) {
            if (closed) { Array<ClientRotationSlot>() } else {
                closed = true
                for (slot in generations) { slot.markRetired() }
                generations.toArray()
            }
        }
        for (slot in retiring) { slot.retire(HttpConfigurationRotation.SecurityReplacement) }
        match (ownedSystemResolver) { case Some(value) => value.close(); case None => () }
    }

/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    /** Returns a read-only snapshot of live aggregate resource counters. */
    public func resourceSnapshot(): HttpResourceSnapshot {
        resourceSnapshotFromLedger(resourceBudget.snapshot())
    }

    /**
     * Atomically installs validated TLS contexts in fresh direct/proxy pools.
     * Graceful drains admitted exchanges. SecurityReplacement cancels old work.
     * Transferred HTTP/1 duplex sessions retain their original context until close.
     * @param value Caller-owned reusable TLS material; validation precedes publication.
     * @param policy Explicit rotation policy, never inferred from certificate contents.
     * @return New TLS generation. Failed validation or retention capacity preserves the old configuration.
     */
    public func rotateTls(value: HttpClientTlsConfig,
        policy!: HttpConfigurationRotation = HttpConfigurationRotation.Graceful): UInt64 {
        let direct = value.createAlpnHandshaker()
        var tunneled = None<http1.Http1TlsHandshaker>
        var published = false
        try {
            if (proxy.isSome()) { tunneled = Some(value.createHandshaker()) }
            let (generation, retiring) = synchronized(mutex) {
                if (closed) { throw IllegalStateException("HTTP client is closed") }
                if (tlsGeneration == 18446744073709551615u64 || nextTlsOwner >= 18446744073709551613u64) {
                    throw IllegalStateException("HTTP TLS configuration generation exhausted")
                }
                reserveGenerationSlots(if (proxy.isSome()) { 2 } else { 1 })
                let directLease = ClientAlpnTlsLease(ClientTlsOwner(nextTlsOwner, direct), direct)
                let secure = makeHttps(resolver, directLease)
                let secureGeneration = wrapHttps(secure, directLease.owner)
                var tunnel = None<http1.Http1HttpsProxyClient>
                var tunnelGeneration = None<ClientRotationSlot>
                var proxyLease = None<ClientProxyTlsLease>
                if (let Some(native) <- tunneled) {
                    let owner = ClientProxyTlsLease(ClientTlsOwner(nextTlsOwner + 1, native), native)
                    let client = makeTunnel(proxy.getOrThrow(), proxyResolver.getOrThrow(), owner)
                    proxyLease = Some(owner); tunnel = Some(client)
                    tunnelGeneration = Some(wrapTunnel(client, owner.owner))
                }
                let oldSecure = secureSlot
                let oldTunnel = tunnelSlot
                directTlsLease = Some(directLease); https = Some(secure); secureSlot = Some(secureGeneration)
                proxyTlsLease = proxyLease; httpsProxy = tunnel; tunnelSlot = tunnelGeneration
                generations.add(secureGeneration)
                if (let Some(slot) <- tunnelGeneration) { generations.add(slot) }
                tlsGeneration++; nextTlsOwner += 2
                published = true
                (tlsGeneration, retirementSet(oldSecure, oldTunnel, 2, 3, policy))
            }
            for (slot in retiring) { slot.retire(policy) }
            generation
        } finally {
            if (!published) {
                direct.close()
                match (tunneled) { case Some(native) => native.close(); case None => () }
            }
        }
    }

    /**
     * Replaces only direct-route DNS and its pools with a caller-owned immutable resolver snapshot.
     * Existing queries keep the old resolver; no result or cache is transferred.
     * @param value New resolver, normally freshly constructed for hosts/search/nameserver changes.
     * @param policy Explicit in-flight policy. DNS TTL expiry alone never invokes rotation.
     * @return New direct DNS generation.
     */
    public func rotateResolver(value: Resolver,
        policy!: HttpConfigurationRotation = HttpConfigurationRotation.Graceful): UInt64 {
        let (generation, retiring) = synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            if (directDnsGeneration == 18446744073709551615u64) {
                throw IllegalStateException("HTTP direct DNS configuration generation exhausted")
            }
            reserveGenerationSlots(if (secureSlot.isSome()) { 2 } else { 1 })
            let clear = http1.Http1CleartextClient(value, transportFactory, limits: limits,
                resourceBudget: Some(resourceBudget))
            let clearGeneration = wrapCleartext(clear)
            var secure = None<http1.HttpAutomaticHttpsClient>
            var secureGeneration = None<ClientRotationSlot>
            var handshaker = None<ClientAlpnTlsLease>
            if (let Some(current) <- directTlsLease) {
                let copied = current.copyOwner()
                let client = makeHttps(value, copied)
                handshaker = Some(copied); secure = Some(client)
                secureGeneration = Some(wrapHttps(client, copied.owner))
            }
            let oldClear = cleartextSlot
            let oldSecure = secureSlot
            resolver = value; cleartext = clear; cleartextSlot = clearGeneration
            directTlsLease = handshaker; https = secure; secureSlot = secureGeneration
            generations.add(clearGeneration)
            if (let Some(slot) <- secureGeneration) { generations.add(slot) }
            directDnsGeneration++
            (directDnsGeneration, retirementSet(Some(oldClear), oldSecure, 0, 2, policy))
        }
        for (slot in retiring) { slot.retire(policy) }
        generation
    }

    /**
     * Replaces proxy-endpoint DNS without changing direct DNS, NO_PROXY rules or authentication hooks.
     * @param value Caller-owned immutable proxy resolver snapshot.
     * @param policy Explicit in-flight policy.
     * @return New proxy DNS generation; absence of an explicit proxy is rejected atomically.
     */
    public func rotateProxyResolver(value: Resolver,
        policy!: HttpConfigurationRotation = HttpConfigurationRotation.Graceful): UInt64 {
        let (generation, retiring) = synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            let route = proxy.getOrThrow()
            if (proxyDnsGeneration == 18446744073709551615u64) {
                throw IllegalStateException("HTTP proxy DNS configuration generation exhausted")
            }
            reserveGenerationSlots(if (tunnelSlot.isSome()) { 2 } else { 1 })
            let forward = http1.Http1ForwardProxyClient(toInternalProxyEndpoint(route.endpoint), value,
                transportFactory, limits: limits, resourceBudget: Some(resourceBudget))
            let forwardGeneration = wrapForward(forward)
            var tunnel = None<http1.Http1HttpsProxyClient>
            var tunnelGeneration = None<ClientRotationSlot>
            var handshaker = None<ClientProxyTlsLease>
            if (let Some(current) <- proxyTlsLease) {
                let copied = current.copyOwner()
                let client = makeTunnel(route, value, copied)
                handshaker = Some(copied); tunnel = Some(client)
                tunnelGeneration = Some(wrapTunnel(client, copied.owner))
            }
            let oldForward = forwardSlot.getOrThrow()
            let oldTunnel = tunnelSlot
            proxyResolver = Some(value); forwardProxy = Some(forward); forwardSlot = Some(forwardGeneration)
            proxyTlsLease = handshaker; httpsProxy = tunnel; tunnelSlot = tunnelGeneration
            generations.add(forwardGeneration)
            if (let Some(slot) <- tunnelGeneration) { generations.add(slot) }
            proxyDnsGeneration++
            (proxyDnsGeneration, retirementSet(Some(oldForward), oldTunnel, 1, 3, policy))
        }
        for (slot in retiring) { slot.retire(policy) }
        generation
    }

    /** Returns non-sensitive generations and bounded live retention counters without polling. */
    public func configurationSnapshot(): HttpClientConfigurationSnapshot {
        synchronized(mutex) {
            reserveGenerationSlots(0)
            let owners = ArrayList<UInt64>()
            for (slot in generations) {
                if (let Some(owner) <- slot.tlsOwner) {
                    var found = false
                    for (id in owners) { if (id == owner.id) { found = true; break } }
                    if (!found) { owners.add(owner.id) }
                }
            }
            HttpClientConfigurationSnapshot(tlsGeneration, directDnsGeneration, proxyDnsGeneration,
                generations.size, owners.size)
        }
    }

    private func retirementSet(oldFirst: ?ClientRotationSlot, oldSecond: ?ClientRotationSlot,
        first: Int64, second: Int64, policy: HttpConfigurationRotation): Array<ClientRotationSlot> {
        let retiring = ArrayList<ClientRotationSlot>()
        match (policy) {
            case HttpConfigurationRotation.Graceful => ()
            case HttpConfigurationRotation.SecurityReplacement =>
                for (slot in generations) {
                    if (slot.isRetired() && (slot.kind == first || slot.kind == second)) { retiring.add(slot) }
                }
        }
        match (oldFirst) { case Some(slot) => retiring.add(slot); case None => () }
        match (oldSecond) { case Some(slot) => retiring.add(slot); case None => () }
        for (slot in retiring) { slot.markRetired() }
        retiring.toArray()
    }

    private func makeHttps(selected: Resolver, handshaker: ClientAlpnTlsLease): http1.HttpAutomaticHttpsClient {
        http1.HttpAutomaticHttpsClient(selected, transportFactory, handshaker,
            limits: limits, pushConfig: pushConfig, resourceBudget: Some(resourceBudget))
    }

    private func makeTunnel(value: HttpProxyConfig, selected: Resolver,
        handshaker: ClientProxyTlsLease): http1.Http1HttpsProxyClient {
        http1.Http1HttpsProxyClient(toInternalProxyEndpoint(value.endpoint), selected,
            transportFactory, handshaker, limits: limits, resourceBudget: Some(resourceBudget))
    }

    private func wrapCleartext(value: http1.Http1CleartextClient): ClientRotationSlot {
        ClientRotationSlot(value, 0, { strict => if (strict) { value.abortConnections() } else { value.retire() } },
            { => emptyClientPool(value.snapshot()) })
    }
    private func wrapForward(value: http1.Http1ForwardProxyClient): ClientRotationSlot {
        ClientRotationSlot(value, 1, { strict => if (strict) { value.abortConnections() } else { value.retire() } },
            { => emptyClientPool(value.snapshot()) })
    }
    private func wrapHttps(value: http1.HttpAutomaticHttpsClient, owner: ClientTlsOwner): ClientRotationSlot {
        ClientRotationSlot(value, 2, { strict => if (strict) { value.abortConnections() } else { value.retire() } },
            { =>
                let h2 = value.h2Snapshot()
                emptyClientPool(value.h1Snapshot()) && h2.connections == 0 && h2.reservations == 0 && h2.waiters == 0
            }, tlsOwner: Some(owner))
    }
    private func wrapTunnel(value: http1.Http1HttpsProxyClient, owner: ClientTlsOwner): ClientRotationSlot {
        ClientRotationSlot(value, 3, { strict => if (strict) { value.abortConnections() } else { value.retire() } },
            { => emptyClientPool(value.snapshot()) }, tlsOwner: Some(owner))
    }

    private func selectGeneration(url: HttpUrl): (ClientRotationSlot, ClientRotationLease, ClientRotationLease) {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            let proxied = match (proxy) {
                case Some(value) => match (value.routeFor(url)) { case HttpProxyRoute.Direct => false; case _ => true }
                case None => false
            }
            if (url.scheme == "https" && !proxied && secureSlot.isNone()) {
                reserveGenerationSlots(1)
                let native = http1.DefaultHttp1TlsHandshaker.systemDefaultAlpn()
                let handshaker = ClientAlpnTlsLease(ClientTlsOwner(nextTlsOwner, native), native)
                nextTlsOwner++
                let value = makeHttps(resolver, handshaker)
                directTlsLease = Some(handshaker); https = Some(value)
                secureSlot = Some(wrapHttps(value, handshaker.owner)); generations.add(secureSlot.getOrThrow())
            }
            if (url.scheme == "https" && proxied && tunnelSlot.isNone()) {
                reserveGenerationSlots(1)
                let native = http1.DefaultHttp1TlsHandshaker.systemDefault()
                let handshaker = ClientProxyTlsLease(ClientTlsOwner(nextTlsOwner, native), native)
                nextTlsOwner++
                let value = makeTunnel(proxy.getOrThrow(), proxyResolver.getOrThrow(), handshaker)
                proxyTlsLease = Some(handshaker); httpsProxy = Some(value)
                tunnelSlot = Some(wrapTunnel(value, handshaker.owner)); generations.add(tunnelSlot.getOrThrow())
            }
            let slot = match ((url.scheme, proxied)) {
                case ("http", false) => cleartextSlot
                case ("http", true) => forwardSlot.getOrThrow()
                case ("https", false) => secureSlot.getOrThrow()
                case ("https", true) => tunnelSlot.getOrThrow()
                case _ => throw IllegalArgumentException("HTTP client accepts only http and https URLs")
            }
            (slot, slot.hold(), slot.hold())
        }
    }

    private func reserveGenerationSlots(count: Int64): Unit {
        var index = generations.size
        while (index > 0) {
            index--
            if (generations[index].collect()) { let _ = generations.remove(at: index) }
        }
        if (generations.size + count > 64) {
            throw IllegalStateException("HTTP client retained configuration generation limit reached")
        }
    }

    /**
     * Runs one duplex handshake under the caller's aggregate request admission.
     * The owner-scoped request lease is released with the rejected response body or,
     * after a successful handshake, only when the transferred transport terminates.
     */
    private func executeAdmittedDuplex(h1Request: HttpRequest, h2Request: HttpRequest,
        protocol: ?String, context: OperationContext): http1.HttpDuplexExchangeResult {
        let requestLease = resourceBudget.acquireRequest(
            resourceOwner(h1Request.url),
            context.forStage(transport.OperationTimeoutStage.RequestAdmission)
        )
        let cancellation = HttpRequestCancellationOperation(
            context,
            None<HttpRequestCancellationHandle>,
            None<HttpConnectionCancellationHandle>,
            None<HttpStreamCancellationHandle>
        )
        cancellation.retainResource(requestLease)
        let result = try {
            executeDuplex(h1Request, h2Request, protocol, context)
        } catch (error: Exception) {
            cancellation.fail()
            throw error
        }
        match (result) {
            case http1.HttpDuplexExchangeResult.Response(response) =>
                http1.HttpDuplexExchangeResult.Response(cancellation.wrap(response))
            case http1.HttpDuplexExchangeResult.Connected(connection) =>
                http1.HttpDuplexExchangeResult.Connected(http1.HttpDuplexConnection(
                    connection.status, connection.headers, connection.version,
                    HttpAdmissionRetainedTransport(connection.transport, cancellation)
                ))
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

/** Retains one admitted request lease until the transferred duplex transport terminates. */
private class HttpAdmissionRetainedTransport <: transport.DuplexTransport {
    private let delegate: transport.DuplexTransport
    private let cancellation: HttpRequestCancellationOperation
    private let mutex = Mutex()
    private var terminal = false

    /**
     * Wraps one exclusively transferred duplex transport.
     * @param delegate Underlying transferred duplex transport.
     * @param cancellation Request-cancellation owner that holds the admitted request lease.
     */
    init(delegate: transport.DuplexTransport, cancellation: HttpRequestCancellationOperation) {
        this.delegate = delegate
        this.cancellation = cancellation
    }

    /** Reports the delegated provider-neutral transport diagnostics. */
    public prop info: transport.TransportInfo { get() { delegate.info } }

    /**
     * Reads at most destination.length bytes from the delegated transport.
     * @param destination Caller-provided destination buffer.
     * @param context Operation deadline and cancellation passed through unchanged.
     */
    public func readSome(
        destination: transport.MutableByteSpan,
        context!: OperationContext = OperationContext.background()
    ): transport.ReadResult {
        delegate.readSome(destination, context: context)
    }

    /**
     * Writes at most source.length bytes to the delegated transport.
     * @param source Caller-provided source bytes.
     * @param context Operation deadline and cancellation passed through unchanged.
     */
    public func writeSome(
        source: transport.ByteSpan,
        context!: OperationContext = OperationContext.background()
    ): Int64 {
        delegate.writeSome(source, context: context)
    }

    /**
     * Closes only the selected direction on the delegated transport.
     * @param direction Direction to close.
     */
    public func shutdown(direction: transport.ShutdownDirection): Unit {
        delegate.shutdown(direction)
    }

    /**
     * Gracefully closes the delegated transport, then releases the admitted request lease.
     * @param context Operation deadline and cancellation for the delegated close.
     */
    public func close(context: OperationContext): Unit {
        if (!claimTerminal()) { return }
        try { delegate.close(context) }
        finally { cancellation.fail() }
    }

    /** Gracefully closes the delegated transport with the background context. */
    public func close(): Unit { close(OperationContext.background()) }

    /** Reports whether this transport or its delegate has terminated. */
    public func isClosed(): Bool {
        if (synchronized(mutex) { terminal }) { return true }
        if (!delegate.isClosed()) { return false }
        // Delegate termination is terminal for this wrapper: release the retained
        // request admission even when the caller only observes isClosed().
        if (claimTerminal()) { cancellation.fail() }
        true
    }

    /**
     * Immediately terminates the delegated transport, then releases the admitted request lease.
     * @param reason Stable abort reason forwarded to the delegate.
     */
    public func abort(reason!: ?transport.AbortReason = None<transport.AbortReason>): Unit {
        if (!claimTerminal()) { return }
        try { delegate.abort(reason: reason) }
        finally { cancellation.fail() }
    }

    private func claimTerminal(): Bool {
        synchronized(mutex) {
            if (terminal) { false } else { terminal = true; true }
        }
    }
}
