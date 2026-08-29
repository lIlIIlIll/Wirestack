package wirestack.http

import wirestack as api

public type HttpMethod = api.HttpMethod
public type HttpVersion = api.HttpVersion
public type HttpLimits = api.HttpLimits
public type HttpHeader = api.HttpHeader
public type HttpHeaders = api.HttpHeaders
public type HttpHeadersBuilder = api.HttpHeadersBuilder
public type HttpTrailer = api.HttpTrailer
public type HttpUrl = api.HttpUrl
public type BodyReplayability = api.BodyReplayability
public type HttpBodyErrorCode = api.HttpBodyErrorCode
public type HttpBodyException = api.HttpBodyException
public type HttpBodyStream = api.HttpBodyStream
public type RequestBody = api.RequestBody
public type HttpRequest = api.HttpRequest
public type HttpRetrySafety = api.HttpRetrySafety
public type ResponseBodyObserver = api.ResponseBodyObserver
public type ResponseBody = api.ResponseBody
public type HttpResponse = api.HttpResponse

// Provider-neutral network contracts used by the public HTTP facade. These
// aliases keep std.net and the TLS provider out of public method signatures.
public type IpAddressFamily = api.IpAddressFamily
public type IpAddress = api.IpAddress
public type SocketEndpoint = api.SocketEndpoint
public type HostName = api.HostName

public type NetworkTraceContext = api.NetworkTraceContext
public type NetworkEventKind = api.NetworkEventKind
public type NetworkEventOutcome = api.NetworkEventOutcome
public type NetworkEvent = api.NetworkEvent
public type NetworkEventSink = api.NetworkEventSink
public type OperationContext = api.OperationContext
public type MonotonicClock = api.MonotonicClock
public type Deadline = api.Deadline
public type CancellationRegistration = api.CancellationRegistration
public type CancellationToken = api.CancellationToken
public type CancellationSource = api.CancellationSource

public type ResolveAddressFamily = api.ResolveAddressFamily
public type ResolverSource = api.ResolverSource
public type ResolveErrorCode = api.ResolveErrorCode
public type ResolveOptions = api.ResolveOptions
public type ResolveDiagnostics = api.ResolveDiagnostics
public type ResolveResult = api.ResolveResult
public type ResolveException = api.ResolveException
public type Resolver = api.Resolver
public type StaticResolver = api.StaticResolver

public type NetworkErrorCategory = api.NetworkErrorCategory
public type NetworkPhase = api.NetworkPhase
public type NetworkErrorCode = api.NetworkErrorCode
public type Retryability = api.Retryability
public type NetworkException = api.NetworkException
public type HttpProxyConnectException = api.HttpProxyConnectException
