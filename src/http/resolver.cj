package wirestack.http

import wirestack.internal.resolver as resolver

/** Platform system resolver with explicit worker and queue bounds. */
public class SystemResolver <: Resolver & Resource {
    private let delegate: resolver.SystemResolver

/**
 * Wirestack 公开 API：init。
 * @param queueCapacity 参数 queueCapacity。
 * @param workerCount 参数 workerCount。
 */
    public init(workerCount!: Int64 = 4, queueCapacity!: Int64 = 64) {
        delegate = resolver.SystemResolver(
            workerCount: workerCount,
            queueCapacity: queueCapacity
        )
    }

/**
 * Wirestack 公开 API：resolve。
 * @param context 参数 context。
 * @param host 参数 host。
 * @param options 参数 options。
 * @param service 参数 service。
 */
    public func resolve(
        host: HostName,
        service: ?String,
        options: ResolveOptions,
        context: OperationContext
    ): ResolveResult {
        delegate.resolve(host, service, options, context)
    }

/**
 * Wirestack 公开 API：resolve。
 * @param context 参数 context。
 * @param host 参数 host。
 * @param options 参数 options。
 */
    public func resolve(
        host: HostName,
        options!: ResolveOptions = ResolveOptions(),
        context!: OperationContext = OperationContext.background()
    ): ResolveResult {
        delegate.resolve(host, options: options, context: context)
    }

/**
 * Wirestack 公开 API：close。
 */
    public func close(): Unit {
        delegate.close()
    }

/**
 * Wirestack 公开 API：isClosed。
 */
    public func isClosed(): Bool {
        delegate.isClosed()
    }
}
