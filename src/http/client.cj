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

    public func build(): HttpClient {
        let selected = match (configuredResolver) {
            case Some(value) => value
            case None => UnavailableSystemResolver()
        }
        HttpClient(
            selected, configuredRequestTimeout, configuredLimits,
            configuredRedirectPolicy, configuredRetryPolicy
        )
    }
}

/** Linux HTTP/1 facade. HTTPS initializes the AWS-LC handshaker lazily. */
public class HttpClient <: Resource {
    private let resolver: resolver.Resolver
    private let requestTimeout: ?Duration
    private let limits: HttpLimits
    private let redirectPolicy: HttpRedirectPolicy
    private let retryPolicy: HttpRetryPolicy
    private let transportFactory = stdnet.StdNetTransportFactory()
    private let cleartext: http1.Http1CleartextClient
    private let mutex = Mutex()
    private var https: ?http1.Http1HttpsClient = None<http1.Http1HttpsClient>
    private var closed = false

    init(resolver: resolver.Resolver, requestTimeout: ?Duration, limits: HttpLimits,
        redirectPolicy: HttpRedirectPolicy, retryPolicy: HttpRetryPolicy) {
        this.resolver = resolver
        this.requestTimeout = requestTimeout
        this.limits = limits
        this.redirectPolicy = redirectPolicy
        this.retryPolicy = retryPolicy
        cleartext = http1.Http1CleartextClient(resolver, transportFactory, limits: limits)
    }

    public static func default(): HttpClient { HttpClient.builder().build() }
    public static func builder(): HttpClientBuilder { HttpClientBuilder() }

    public func get(url: String,
        context!: OperationContext = OperationContext.background()): HttpResponse {
        send(HttpRequest.get(url), context: context)
    }

    public func send(request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()): HttpResponse {
        let operation = match (requestTimeout) {
            case Some(value) => context.shortenDeadline(value)
            case None => context
        }
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
    }

    private func executeOnce(request: HttpRequest, operation: OperationContext,
        trailer: HttpTrailer): HttpResponse {
        if (isClosed()) { throw IllegalStateException("HTTP client is closed") }
        match (request.url.scheme) {
            case "http" => cleartext.execute(request, context: operation, trailer: trailer)
            case "https" => httpsClient().execute(request, context: operation, trailer: trailer)
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
        let secure = synchronized(mutex) {
            if (closed) {
                None<http1.Http1HttpsClient>
            } else {
                closed = true
                https
            }
        }
        cleartext.close()
        match (secure) { case Some(value) => value.close(); case None => () }
    }

    public func isClosed(): Bool { synchronized(mutex) { closed } }

    private func httpsClient(): http1.Http1HttpsClient {
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("HTTP client is closed") }
            match (https) {
                case Some(value) => value
                case None =>
                    let value = http1.Http1HttpsClient(
                        resolver,
                        transportFactory,
                        http1.AwsLcHttp1TlsHandshaker.systemDefault(),
                        limits: limits
                    )
                    https = Some(value)
                    value
            }
        }
    }
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
