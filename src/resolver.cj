package wirestack

import std.time.MonoTime
import std.collection.ArrayList

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum ResolveAddressFamily {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Any
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Ipv4
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Ipv6
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public enum ResolverSource {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | System
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | HostsFile
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Static
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Custom
}

/**
 * Wirestack 公开 API：表示稳定的错误分类。
 */
public enum ResolveErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | NameNotFound
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | NoData
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | TemporaryFailure
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Timeout
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Cancelled
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidName
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | UnsupportedFamily
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | SystemFailure
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public struct ResolveOptions {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let family: ResolveAddressFamily
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maxResults: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param family 地址使用的 IP 地址族。
 * @param maxResults 调用方提供的输入值。
 */
    public init(
        family!: ResolveAddressFamily = ResolveAddressFamily.Any,
        maxResults!: Int64 = 64
    ) {
        if (maxResults <= 0 || maxResults > 1024) {
            throw IllegalArgumentException("maxResults must be between 1 and 1024")
        }
        this.family = family
        this.maxResults = maxResults
    }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public struct ResolveDiagnostics {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let source: ResolverSource
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let candidateCount: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let duplicatesRemoved: Int64
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let startedAt: MonoTime
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let completedAt: MonoTime

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param candidateCount 调用方提供的输入值。
 * @param completedAt 调用方提供的输入值。
 * @param duplicatesRemoved 调用方提供的输入值。
 * @param source 调用方提供的输入值。
 * @param startedAt 调用方提供的输入值。
 */
    public init(
        source: ResolverSource,
        candidateCount: Int64,
        duplicatesRemoved: Int64,
        startedAt: MonoTime,
        completedAt: MonoTime
    ) {
        if (candidateCount < 0 || duplicatesRemoved < 0 || completedAt < startedAt) {
            throw IllegalArgumentException("invalid resolver diagnostics")
        }
        this.source = source
        this.candidateCount = candidateCount
        this.duplicatesRemoved = duplicatesRemoved
        this.startedAt = startedAt
        this.completedAt = completedAt
    }
}

/**
 * Wirestack 公开 API：表示一次操作的结果及其状态。
 */
public struct ResolveResult {
    private let ownedAddresses: Array<IpAddress>
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let canonicalHost: HostName
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let source: ResolverSource
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let expiration: ?MonoTime
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let diagnostics: ResolveDiagnostics

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param addresses 调用方提供的输入值。
 * @param canonicalHost 调用方提供的输入值。
 * @param completedAt 调用方提供的输入值。
 * @param expiration 调用方提供的输入值。
 * @param source 调用方提供的输入值。
 * @param startedAt 调用方提供的输入值。
 */
    public init(
        addresses: Array<IpAddress>,
        canonicalHost: HostName,
        source: ResolverSource,
        expiration!: ?MonoTime = None<MonoTime>,
        startedAt!: MonoTime = MonoTime.now(),
        completedAt!: MonoTime = MonoTime.now()
    ) {
        let normalized = deduplicate(addresses)
        if (normalized.size > 1024) {
            throw IllegalArgumentException("resolver result exceeds the hard candidate limit")
        }
        ownedAddresses = normalized
        this.canonicalHost = canonicalHost
        this.source = source
        this.expiration = expiration
        diagnostics = ResolveDiagnostics(
            source,
            normalized.size,
            addresses.size - normalized.size,
            startedAt,
            completedAt
        )
    }

/**
 * Wirestack 公开 API：更新当前构建器或集合的受约束状态。
 */
    public prop addresses: Array<IpAddress> {
        get() { ownedAddresses.clone() }
    }
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class ResolveException <: NetworkException {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let resolveCode: ResolveErrorCode

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cause 导致当前错误的底层异常。
 * @param message 面向调用方的诊断文本。
 * @param resolveCode 调用方提供的输入值。
 */
    public init(resolveCode: ResolveErrorCode, message: String, cause!: ?Exception = None<Exception>) {
        super(
            NetworkErrorCategory.Resolve,
            NetworkPhase.Dns,
            toNetworkCode(resolveCode),
            message,
            retryability: resolveRetryability(resolveCode),
            cause: cause
        )
        this.resolveCode = resolveCode
    }

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cause 导致当前错误的底层异常。
 * @param message 面向调用方的诊断文本。
 * @param nativeCode 调用方提供的输入值。
 * @param resolveCode 调用方提供的输入值。
 */
    public init(
        resolveCode: ResolveErrorCode,
        message: String,
        nativeCode: ?Int64,
        cause!: ?Exception = None<Exception>
    ) {
        super(
            NetworkErrorCategory.Resolve,
            NetworkPhase.Dns,
            toNetworkCode(resolveCode),
            message,
            retryability: resolveRetryability(resolveCode),
            nativeCode: nativeCode,
            cause: cause
        )
        this.resolveCode = resolveCode
    }

    internal init(
        resolveCode: ResolveErrorCode,
        message: String,
        nativeCode: ?Int64,
        localEndpoint: ?NetworkEndpoint,
        remoteEndpoint: ?NetworkEndpoint,
        cause: ?Exception
    ) {
        super(
            NetworkErrorCategory.Resolve,
            NetworkPhase.Dns,
            toNetworkCode(resolveCode),
            message,
            retryability: resolveRetryability(resolveCode),
            nativeCode: nativeCode,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            cause: cause
        )
        this.resolveCode = resolveCode
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String {
        "ResolveException"
    }
}

/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
public interface Resolver {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param host 待解析的主机名或地址字面量。
 * @param options 解析或连接时使用的选项。
 * @param service 服务名称或端口别名。
 */
    func resolve(
        host: HostName,
        service: ?String,
        options: ResolveOptions,
        context: OperationContext
    ): ResolveResult
}

/** Deterministic resolver used by connector, TLS and HTTP tests. */
public class StaticResolver <: Resolver {
    private let result: ResolveResult

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param result 调用方提供的输入值。
 */
    public init(result: ResolveResult) {
        this.result = result
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
        let _ = service
        checkResolveContext(context)
        if (host != result.canonicalHost) {
            throw ResolveException(ResolveErrorCode.NameNotFound, "static resolver has no matching host")
        }
        let filtered = ArrayList<IpAddress>()
        for (address in result.addresses) {
            if (matchesFamily(address, options.family) && filtered.size < options.maxResults) {
                filtered.add(address)
            }
        }
        if (filtered.isEmpty()) {
            throw ResolveException(ResolveErrorCode.NoData, "resolver returned no address for the requested family")
        }
        ResolveResult(
            filtered.toArray(),
            result.canonicalHost,
            result.source,
            expiration: result.expiration,
            startedAt: result.diagnostics.startedAt,
            completedAt: result.diagnostics.completedAt
        )
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
        resolve(host, None<String>, options, context)
    }
}

private func deduplicate(addresses: Array<IpAddress>): Array<IpAddress> {
    let result = ArrayList<IpAddress>()
    for (candidate in addresses) {
        var duplicate = false
        for (existing in result) {
            if (candidate == existing) {
                duplicate = true
                break
            }
        }
        if (!duplicate) {
            result.add(candidate)
        }
    }
    result.toArray()
}

private func matchesFamily(address: IpAddress, requested: ResolveAddressFamily): Bool {
    match (requested) {
        case ResolveAddressFamily.Any => true
        case ResolveAddressFamily.Ipv4 => address.family == IpAddressFamily.Ipv4
        case ResolveAddressFamily.Ipv6 => address.family == IpAddressFamily.Ipv6
    }
}

private func checkResolveContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw ResolveException(ResolveErrorCode.Cancelled, "resolution cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw ResolveException(ResolveErrorCode.Timeout, "resolution deadline exceeded")
    }
}

private func toNetworkCode(code: ResolveErrorCode): NetworkErrorCode {
    match (code) {
        case ResolveErrorCode.NameNotFound => NetworkErrorCode.NameNotFound
        case ResolveErrorCode.NoData => NetworkErrorCode.NoData
        case ResolveErrorCode.TemporaryFailure => NetworkErrorCode.TemporaryFailure
        case ResolveErrorCode.Timeout => NetworkErrorCode.TimedOut
        case ResolveErrorCode.Cancelled => NetworkErrorCode.Cancelled
        case ResolveErrorCode.InvalidName => NetworkErrorCode.InvalidName
        case ResolveErrorCode.UnsupportedFamily => NetworkErrorCode.UnsupportedFamily
        case ResolveErrorCode.SystemFailure => NetworkErrorCode.SystemFailure
    }
}

private func resolveRetryability(code: ResolveErrorCode): Retryability {
    match (code) {
        case ResolveErrorCode.TemporaryFailure => Retryability.Temporary
        case ResolveErrorCode.Timeout => Retryability.Temporary
        case ResolveErrorCode.SystemFailure => Retryability.Unknown
        case _ => Retryability.Never
    }
}
