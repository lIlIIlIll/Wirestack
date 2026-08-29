package wirestack.internal.resolver

import wirestack as api

public type ResolveAddressFamily = api.ResolveAddressFamily
public type ResolverSource = api.ResolverSource
public type ResolveErrorCode = api.ResolveErrorCode
public type ResolveOptions = api.ResolveOptions
public type ResolveDiagnostics = api.ResolveDiagnostics
public type ResolveResult = api.ResolveResult
public type ResolveException = api.ResolveException
public type Resolver = api.Resolver
public type StaticResolver = api.StaticResolver

internal func checkResolveContext(context: api.OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw api.ResolveException(api.ResolveErrorCode.Cancelled, "resolution cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw api.ResolveException(api.ResolveErrorCode.Timeout, "resolution deadline exceeded")
    }
}
