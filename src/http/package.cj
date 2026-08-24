package wirestack.http

import wirestack.internal.http_model as model
import wirestack.internal.common as common
import wirestack.internal.resolver as resolver
import wirestack.internal.transport as transport
import wirestack.internal.http1 as http1

public type HttpMethod = model.HttpMethod
public type HttpVersion = model.HttpVersion
public type HttpLimits = model.HttpLimits
public type HttpHeader = model.HttpHeader
public type HttpHeaders = model.HttpHeaders
public type HttpHeadersBuilder = model.HttpHeadersBuilder
public type HttpTrailer = model.HttpTrailer
public type HttpUrl = model.HttpUrl
public type BodyReplayability = model.BodyReplayability
public type HttpBodyErrorCode = model.HttpBodyErrorCode
public type HttpBodyException = model.HttpBodyException
public type HttpBodyStream = model.HttpBodyStream
public type RequestBody = model.RequestBody
public type HttpRequest = model.HttpRequest
public type HttpRetrySafety = model.HttpRetrySafety
public type ResponseBodyObserver = model.ResponseBodyObserver
public type ResponseBody = model.ResponseBody
public type HttpResponse = model.HttpResponse

// Provider-neutral network contracts used by the public HTTP facade. These
// aliases keep std.net and the TLS provider out of public method signatures.
public type IpAddressFamily = common.IpAddressFamily
public type IpAddress = common.IpAddress
public type SocketEndpoint = common.SocketEndpoint
public type HostName = common.HostName

public type NetworkTraceContext = transport.NetworkTraceContext
public type OperationContext = transport.OperationContext
public type MonotonicClock = transport.MonotonicClock
public type Deadline = transport.Deadline
public type CancellationRegistration = transport.CancellationRegistration
public type CancellationToken = transport.CancellationToken
public type CancellationSource = transport.CancellationSource

public type ResolveAddressFamily = resolver.ResolveAddressFamily
public type ResolverSource = resolver.ResolverSource
public type ResolveErrorCode = resolver.ResolveErrorCode
public type ResolveOptions = resolver.ResolveOptions
public type ResolveDiagnostics = resolver.ResolveDiagnostics
public type ResolveResult = resolver.ResolveResult
public type ResolveException = resolver.ResolveException
public type Resolver = resolver.Resolver
public type StaticResolver = resolver.StaticResolver

public type NetworkErrorCategory = transport.NetworkErrorCategory
public type NetworkPhase = transport.NetworkPhase
public type NetworkErrorCode = transport.NetworkErrorCode
public type Retryability = transport.Retryability
public type NetworkException = transport.NetworkException
public type HttpProxyConnectException = http1.Http1ProxyConnectException
