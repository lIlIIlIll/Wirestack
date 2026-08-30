package wirestack.internal.resolver

import wirestack.internal.common.HostName
import wirestack.internal.transport.OperationContext

/**
 * Platform system resolver backed by a fixed native worker pool.
 *
 * Call close when the resolver is no longer needed. Closing is idempotent and
 * waits for native work that outlived caller cancellation or Deadline expiry.
 */
public class SystemResolver <: Resolver & Resource {
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

    public func close(): Unit {
        backend.close()
    }

    public func isClosed(): Bool {
        backend.isClosed()
    }
}
