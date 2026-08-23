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

    public func build(): HttpClient {
        let selected = match (configuredResolver) {
            case Some(value) => value
            case None => UnavailableSystemResolver()
        }
        HttpClient(selected, configuredRequestTimeout, configuredLimits)
    }
}

/** Linux HTTP/1 facade. HTTPS initializes the AWS-LC handshaker lazily. */
public class HttpClient <: Resource {
    private let resolver: resolver.Resolver
    private let requestTimeout: ?Duration
    private let limits: HttpLimits
    private let transportFactory = stdnet.StdNetTransportFactory()
    private let cleartext: http1.Http1CleartextClient
    private let mutex = Mutex()
    private var https: ?http1.Http1HttpsClient = None<http1.Http1HttpsClient>
    private var closed = false

    init(resolver: resolver.Resolver, requestTimeout: ?Duration, limits: HttpLimits) {
        this.resolver = resolver
        this.requestTimeout = requestTimeout
        this.limits = limits
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
        if (isClosed()) { throw IllegalStateException("HTTP client is closed") }
        match (request.url.scheme) {
            case "http" => cleartext.execute(request, context: operation, trailer: trailer)
            case "https" => httpsClient().execute(request, context: operation, trailer: trailer)
            case _ => throw IllegalArgumentException("HTTP client accepts only http and https URLs")
        }
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
