package wirestack.http

import wirestack as api

/**
 * Wirestack 公开 API：HttpMethod。
 */
public type HttpMethod = api.HttpMethod
/**
 * Wirestack 公开 API：HttpVersion。
 */
public type HttpVersion = api.HttpVersion
/**
 * Wirestack 公开 API：HttpLimits。
 */
public type HttpLimits = api.HttpLimits
/**
 * Wirestack 公开 API：HttpHeader。
 */
public type HttpHeader = api.HttpHeader
/**
 * Wirestack 公开 API：HttpHeaders。
 */
public type HttpHeaders = api.HttpHeaders
/**
 * Wirestack 公开 API：HttpHeadersBuilder。
 */
public type HttpHeadersBuilder = api.HttpHeadersBuilder
/**
 * Wirestack 公开 API：HttpTrailer。
 */
public type HttpTrailer = api.HttpTrailer
/**
 * Wirestack 公开 API：HttpUrl。
 */
public type HttpUrl = api.HttpUrl
/**
 * Wirestack 公开 API：BodyReplayability。
 */
public type BodyReplayability = api.BodyReplayability
/**
 * Wirestack 公开 API：HttpBodyErrorCode。
 */
public type HttpBodyErrorCode = api.HttpBodyErrorCode
/**
 * Wirestack 公开 API：HttpBodyException。
 */
public type HttpBodyException = api.HttpBodyException
/**
 * Wirestack 公开 API：HttpBodyStream。
 */
public type HttpBodyStream = api.HttpBodyStream
/**
 * Wirestack 公开 API：RequestBody。
 */
public type RequestBody = api.RequestBody
/**
 * Wirestack 公开 API：HttpRequest。
 */
public type HttpRequest = api.HttpRequest
/**
 * Wirestack 公开 API：HttpRetrySafety。
 */
public type HttpRetrySafety = api.HttpRetrySafety
/**
 * Wirestack 公开 API：ResponseBodyObserver。
 */
public type ResponseBodyObserver = api.ResponseBodyObserver
/**
 * Wirestack 公开 API：ResponseBody。
 */
public type ResponseBody = api.ResponseBody
/**
 * Wirestack 公开 API：HttpResponse。
 */
public type HttpResponse = api.HttpResponse

// Provider-neutral network contracts used by the public HTTP facade. These
// aliases keep std.net and the TLS provider out of public method signatures.
/**
 * Wirestack 公开 API：IpAddressFamily。
 */
public type IpAddressFamily = api.IpAddressFamily
/**
 * Wirestack 公开 API：IpAddress。
 */
public type IpAddress = api.IpAddress
/**
 * Wirestack 公开 API：SocketEndpoint。
 */
public type SocketEndpoint = api.SocketEndpoint
/**
 * Wirestack 公开 API：HostName。
 */
public type HostName = api.HostName

/**
 * Wirestack 公开 API：NetworkTraceContext。
 */
public type NetworkTraceContext = api.NetworkTraceContext
/**
 * Wirestack 公开 API：NetworkEventKind。
 */
public type NetworkEventKind = api.NetworkEventKind
/**
 * Wirestack 公开 API：NetworkEventOutcome。
 */
public type NetworkEventOutcome = api.NetworkEventOutcome
/**
 * Wirestack 公开 API：NetworkEvent。
 */
public type NetworkEvent = api.NetworkEvent
/**
 * Wirestack 公开 API：NetworkEventSink。
 */
public type NetworkEventSink = api.NetworkEventSink
/**
 * Wirestack 公开 API：OperationContext。
 */
public type OperationContext = api.OperationContext
/**
 * Wirestack 公开 API：MonotonicClock。
 */
public type MonotonicClock = api.MonotonicClock
/**
 * Wirestack 公开 API：Deadline。
 */
public type Deadline = api.Deadline
/**
 * Wirestack 公开 API：CancellationRegistration。
 */
public type CancellationRegistration = api.CancellationRegistration
/**
 * Wirestack 公开 API：CancellationToken。
 */
public type CancellationToken = api.CancellationToken
/**
 * Wirestack 公开 API：CancellationSource。
 */
public type CancellationSource = api.CancellationSource

/**
 * Wirestack 公开 API：ResolveAddressFamily。
 */
public type ResolveAddressFamily = api.ResolveAddressFamily
/**
 * Wirestack 公开 API：ResolverSource。
 */
public type ResolverSource = api.ResolverSource
/**
 * Wirestack 公开 API：ResolveErrorCode。
 */
public type ResolveErrorCode = api.ResolveErrorCode
/**
 * Wirestack 公开 API：ResolveOptions。
 */
public type ResolveOptions = api.ResolveOptions
/**
 * Wirestack 公开 API：ResolveDiagnostics。
 */
public type ResolveDiagnostics = api.ResolveDiagnostics
/**
 * Wirestack 公开 API：ResolveResult。
 */
public type ResolveResult = api.ResolveResult
/**
 * Wirestack 公开 API：ResolveException。
 */
public type ResolveException = api.ResolveException
/**
 * Wirestack 公开 API：Resolver。
 */
public type Resolver = api.Resolver
/**
 * Wirestack 公开 API：StaticResolver。
 */
public type StaticResolver = api.StaticResolver

/**
 * Wirestack 公开 API：NetworkErrorCategory。
 */
public type NetworkErrorCategory = api.NetworkErrorCategory
/**
 * Wirestack 公开 API：NetworkPhase。
 */
public type NetworkPhase = api.NetworkPhase
/**
 * Wirestack 公开 API：NetworkErrorCode。
 */
public type NetworkErrorCode = api.NetworkErrorCode
/**
 * Wirestack 公开 API：Retryability。
 */
public type Retryability = api.Retryability
/**
 * Wirestack 公开 API：NetworkException。
 */
public type NetworkException = api.NetworkException
/**
 * Wirestack 公开 API：HttpProxyConnectException。
 */
public type HttpProxyConnectException = api.HttpProxyConnectException
