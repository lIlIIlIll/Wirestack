package wirestack.internal.resolver

import wirestack.internal.common.HostName
import wirestack.internal.transport.OperationContext
import wirestack as api

/**
 * Platform system resolver backed by a fixed native worker pool.
 *
 * Stops admission immediately. Closed snapshots retain the last native sample
 * with isLive false because native work may still be blocked after close.
 */
public class SystemResolver <: Resolver & Resource & api.ResolverResourceOwner {
    private let backend: BoundedSystemResolverBackend

    /** Creates one resolver with explicit worker and queue bounds. */
    public init(workerCount!: Int64 = 4, queueCapacity!: Int64 = 64) {
        backend = BoundedSystemResolverBackend(
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
        backend.resolve(host, service, options, context)
    }

    /** Resolves a host without a service name. */
    public func resolve(
        host: HostName,
        options!: ResolveOptions = ResolveOptions(),
        context!: OperationContext = OperationContext.background()
    ): ResolveResult {
        resolve(host, None<String>, options, context)
    }

    /** Internal DNS adapter path that skips platform search suffixes. */
    public func resolveExact(
        host: HostName,
        options: ResolveOptions,
        context: OperationContext
    ): ResolveResult {
        backend.resolve(host, None<String>, options, context, absolute: true)
    }

    public func close(): Unit {
        backend.close()
    }

    public func isClosed(): Bool {
        backend.isClosed()
    }

    /** Returns bounded scheduler counters for diagnostics and deterministic tests. */
    public func metrics(): ResolverPoolMetrics {
        backend.metrics()
    }

    /** Samples actual native work while live, or returns the unchanged last sample after close. */
    public func resolverResourceSnapshot(): api.ResolverResourceSnapshot {
        backend.resourceSnapshot()
    }
}
