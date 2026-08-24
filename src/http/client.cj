package wirestack.http

import std.sync.Mutex
import wirestack.internal.common as common
import wirestack.internal.http1 as http1
import wirestack.internal.resolver as resolver
import wirestack.internal.transport as transport
import wirestack.internal.transport_stdnet as stdnet

public enum HttpClientCapabilityErrorCode {
    | SystemResolverUnavailable
}

/** A requested default capability is unavailable rather than silently weakened. */
public class HttpClientCapabilityException <: Exception {
    public let code: HttpClientCapabilityErrorCode

    public init(code: HttpClientCapabilityErrorCode, message: String) {
        super(message)
        this.code = code
    }

    protected override func getClassName(): String { "HttpClientCapabilityException" }
}

public class HttpClientBuilder {
    private var configuredResolver: ?resolver.Resolver = None<resolver.Resolver>
    private var configuredRequestTimeout: ?Duration = None<Duration>
    private var configuredLimits = HttpLimits()
    private var configuredRedirectPolicy = HttpRedirectPolicy()
    private var configuredRetryPolicy = HttpRetryPolicy()
    private var configuredProxy: ?HttpProxyConfig = None<HttpProxyConfig>
    private var configuredTls: ?HttpClientTlsConfig = None<HttpClientTlsConfig>

    public init() {}

    /** Installs a provider-neutral resolver. Required for hostnames until SystemResolver lands. */
    public func resolver(value: Resolver): HttpClientBuilder {
        configuredResolver = Some(value)
        this
    }

    public func requestTimeout(value: Duration): HttpClientBuilder {
        if (value <= Duration.Zero) { throw IllegalArgumentException("request timeout must be positive") }
        configuredRequestTimeout = Some(value)
        this
    }

    public func limits(value: HttpLimits): HttpClientBuilder {
        configuredLimits = value
        this
    }

    public func redirectPolicy(value: HttpRedirectPolicy): HttpClientBuilder {
        configuredRedirectPolicy = value
        this
    }

    public func retryPolicy(value: HttpRetryPolicy): HttpClientBuilder {
        configuredRetryPolicy = value
        this
    }

    /** Installs one explicit proxy route. Environment, PAC, and WPAD are never consulted. */
    public func proxy(value: HttpProxyConfig): HttpClientBuilder {
        configuredProxy = Some(value)
        this
    }

    public func tls(value: HttpClientTlsConfig): HttpClientBuilder {
        configuredTls = Some(value)
        this
    }

    public func build(): HttpClient {
        let selected = match (configuredResolver) {
            case Some(value) => value
            case None => UnavailableSystemResolver()
        }
        var directTls = None<http1.HttpAlpnTlsHandshaker>
        var proxyTls = None<http1.Http1TlsHandshaker>
        try {
            if (let Some(value) <- configuredTls) {
                directTls = Some(value.createAlpnHandshaker())
                if (configuredProxy.isSome()) { proxyTls = Some(value.createHandshaker()) }
            }
            HttpClient(
                selected, configuredRequestTimeout, configuredLimits,
                configuredRedirectPolicy, configuredRetryPolicy, configuredProxy,
                directTls, proxyTls
            )
        } catch (error: Exception) {
            match (directTls) { case Some(value) => value.close(); case None => () }
            match (proxyTls) { case Some(value) => value.close(); case None => () }
            throw error
        }
    }
}

/** Linux HTTP/1 facade. HTTPS initializes the AWS-LC handshaker lazily. */
public class HttpClient <: Resource {
    private let resolver: resolver.Resolver
    private let requestTimeout: ?Duration
    private let limits: HttpLimits
    private let redirectPolicy: HttpRedirectPolicy
    private let retryPolicy: HttpRetryPolicy
    private let proxy: ?HttpProxyConfig
    private let transportFactory = stdnet.StdNetTransportFactory()
    private let cleartext: http1.Http1CleartextClient
    private let forwardProxy: ?http1.Http1ForwardProxyClient
    private let mutex = Mutex()
    private var https: ?http1.HttpAutomaticHttpsClient = None<http1.HttpAutomaticHttpsClient>
    private var httpsProxy: ?http1.Http1HttpsProxyClient = None<http1.Http1HttpsProxyClient>
    private var closed = false

    init(resolver: resolver.Resolver, requestTimeout: ?Duration, limits: HttpLimits,
        redirectPolicy: HttpRedirectPolicy, retryPolicy: HttpRetryPolicy,
        proxy: ?HttpProxyConfig,
        directTlsHandshaker: ?http1.HttpAlpnTlsHandshaker,
        proxyTlsHandshaker: ?http1.Http1TlsHandshaker) {
        this.resolver = resolver
        this.requestTimeout = requestTimeout
        this.limits = limits
        this.redirectPolicy = redirectPolicy
        this.retryPolicy = retryPolicy
        this.proxy = proxy
        cleartext = http1.Http1CleartextClient(resolver, transportFactory, limits: limits)
        forwardProxy = match (proxy) {
            case Some(value) => Some(http1.Http1ForwardProxyClient(
                toInternalProxyEndpoint(value.endpoint), value.resolver, transportFactory, limits: limits
            ))
            case None => None<http1.Http1ForwardProxyClient>
        }
        https = match (directTlsHandshaker) {
            case Some(value) => Some(http1.HttpAutomaticHttpsClient(
                resolver, transportFactory, value, limits: limits
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

    public static func default(): HttpClient { HttpClient.builder().build() }
    public static func builder(): HttpClientBuilder { HttpClientBuilder() }

    public func get(url: String,
        context!: OperationContext = OperationContext.background()): HttpResponse {
        let request = try {
            HttpRequest.get(url)
        } catch (error: Exception) {
            throw HttpException(HttpErrorCode.InvalidUrl, "invalid HTTP URL", cause: error)
        }
        send(request, context: context)
    }

    public func send(request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()): HttpResponse {
        let operation = match (requestTimeout) {
            case Some(value) => context.shortenDeadline(value)
            case None => context
        }
        try {
            var current = request
            var redirectCount: Int64 = 0
            while (true) {
                let response = executeWithRetries(current, operation, trailer)
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
                        let _ = response.body.drain(redirectPolicy.maximumDrainBytes)
                        current = value
                        redirectCount++
                    case None => return response
                }
            }
            throw Exception("unreachable HTTP redirect loop exit")
        } catch (error: Exception) {
            throw wrapHttpError(error)
        }
    }

    private func executeOnce(request: HttpRequest, operation: OperationContext,
        trailer: HttpTrailer): HttpResponse {
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
                    context: operation, trailer: trailer)
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
        trailer: HttpTrailer): HttpResponse {
        var attempt: Int64 = 1
        while (true) {
            try {
                return executeOnce(request, operation, trailer)
            } catch (error: Exception) {
                if (!retryPolicy.shouldRetry(request, error, attempt, operation)) { throw error }
                attempt++
            }
        }
        throw Exception("unreachable HTTP retry loop exit")
    }

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
    }

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
                        http1.AwsLcHttp1TlsHandshaker.systemDefaultAlpn(),
                        limits: limits
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
                        http1.AwsLcHttp1TlsHandshaker.systemDefault(),
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

private class UnavailableSystemResolver <: resolver.Resolver {
    public func resolve(
        host: common.HostName,
        service: ?String,
        options: resolver.ResolveOptions,
        context: transport.OperationContext
    ): resolver.ResolveResult {
        let _ = host
        let _ = service
        let _ = options
        let _ = context
        throw HttpClientCapabilityException(
            HttpClientCapabilityErrorCode.SystemResolverUnavailable,
            "the pinned Linux SDK has no proven bounded asynchronous SystemResolver; configure HttpClient.builder().resolver(...)"
        )
    }
}
