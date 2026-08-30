package wirestack.http

import wirestack.internal.resolver as resolver

/** Platform system resolver with explicit worker and queue bounds. */
public class SystemResolver <: Resolver & Resource {
    private let delegate: resolver.SystemResolver

    public init(workerCount!: Int64 = 4, queueCapacity!: Int64 = 64) {
        delegate = resolver.SystemResolver(
            workerCount: workerCount,
            queueCapacity: queueCapacity
        )
    }

    public func resolve(
        host: HostName,
        service: ?String,
        options: ResolveOptions,
        context: OperationContext
    ): ResolveResult {
        delegate.resolve(host, service, options, context)
    }

    public func resolve(
        host: HostName,
        options!: ResolveOptions = ResolveOptions(),
        context!: OperationContext = OperationContext.background()
    ): ResolveResult {
        delegate.resolve(host, options: options, context: context)
    }

    public func close(): Unit {
        delegate.close()
    }

    public func isClosed(): Bool {
        delegate.isClosed()
    }
}
