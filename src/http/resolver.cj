package wirestack.http

import wirestack.internal.resolver as resolver

/** Platform system resolver with explicit worker and queue bounds. */
public class SystemResolver <: Resolver & Resource {
    private let delegate: resolver.SystemResolver

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param queueCapacity 等待队列允许保存的最大项目数。
 * @param workerCount 解析工作线程的数量。
 */
    public init(workerCount!: Int64 = 4, queueCapacity!: Int64 = 64) {
        delegate = resolver.SystemResolver(
            workerCount: workerCount,
            queueCapacity: queueCapacity
        )
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param host 待解析的主机名或地址字面量。
 * @param options 解析或连接时使用的选项。
 * @param service 服务名称或端口别名。
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
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param host 待解析的主机名或地址字面量。
 * @param options 解析或连接时使用的选项。
 */
    public func resolve(
        host: HostName,
        options!: ResolveOptions = ResolveOptions(),
        context!: OperationContext = OperationContext.background()
    ): ResolveResult {
        delegate.resolve(host, options: options, context: context)
    }

/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit {
        delegate.close()
    }

/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool {
        delegate.isClosed()
    }
}
