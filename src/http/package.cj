package wirestack.http

import wirestack as api

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpMethod = api.HttpMethod
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpVersion = api.HttpVersion
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpLimits = api.HttpLimits
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpHeader = api.HttpHeader
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpHeaders = api.HttpHeaders
/**
 * Wirestack 公开 API：提供构造不可变公开值的步骤。
 */
public type HttpHeadersBuilder = api.HttpHeadersBuilder
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpTrailer = api.HttpTrailer
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpUrl = api.HttpUrl
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type BodyReplayability = api.BodyReplayability
/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public type HttpBodyErrorCode = api.HttpBodyErrorCode
/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public type HttpBodyException = api.HttpBodyException
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpBodyStream = api.HttpBodyStream
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type RequestBody = api.RequestBody
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpRequest = api.HttpRequest
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpRetrySafety = api.HttpRetrySafety
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResponseBodyObserver = api.ResponseBodyObserver
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResponseBody = api.ResponseBody
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HttpResponse = api.HttpResponse

// Provider-neutral network contracts used by the public HTTP facade. These
// aliases keep std.net and the TLS provider out of public method signatures.
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type IpAddressFamily = api.IpAddressFamily
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type IpAddress = api.IpAddress
/**
 * Wirestack 公开 API：表示一个可连接的网络端点。
 */
public type SocketEndpoint = api.SocketEndpoint
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type HostName = api.HostName

/**
 * Wirestack 公开 API：保存一次网络操作共享的执行上下文。
 */
public type NetworkTraceContext = api.NetworkTraceContext
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkEventKind = api.NetworkEventKind
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkEventOutcome = api.NetworkEventOutcome
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkEvent = api.NetworkEvent
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkEventSink = api.NetworkEventSink
/**
 * Wirestack 公开 API：保存一次网络操作共享的执行上下文。
 */
public type OperationContext = api.OperationContext
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type MonotonicClock = api.MonotonicClock
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type Deadline = api.Deadline
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type CancellationRegistration = api.CancellationRegistration
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type CancellationToken = api.CancellationToken
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type CancellationSource = api.CancellationSource

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResolveAddressFamily = api.ResolveAddressFamily
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResolverSource = api.ResolverSource
/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public type ResolveErrorCode = api.ResolveErrorCode
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResolveOptions = api.ResolveOptions
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type ResolveDiagnostics = api.ResolveDiagnostics
/**
 * Wirestack 公开 API：表示一次操作的结果及其状态。
 */
public type ResolveResult = api.ResolveResult
/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public type ResolveException = api.ResolveException
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type Resolver = api.Resolver
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type StaticResolver = api.StaticResolver

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkErrorCategory = api.NetworkErrorCategory
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type NetworkPhase = api.NetworkPhase
/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public type NetworkErrorCode = api.NetworkErrorCode
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public type Retryability = api.Retryability
/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public type NetworkException = api.NetworkException
/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public type HttpProxyConnectException = api.HttpProxyConnectException
