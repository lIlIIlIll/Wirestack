package wirestack

import std.time.MonoTime
import std.collection.ArrayList

/**
 * Wirestack 公开 API：ResolveAddressFamily。
 */
public enum ResolveAddressFamily {
/**
 * Wirestack 公开 API：Any。
 */
    | Any
/**
 * Wirestack 公开 API：Ipv4。
 */
    | Ipv4
/**
 * Wirestack 公开 API：Ipv6。
 */
    | Ipv6
}

/**
 * Wirestack 公开 API：ResolverSource。
 */
public enum ResolverSource {
/**
 * Wirestack 公开 API：System。
 */
    | System
/**
 * Wirestack 公开 API：HostsFile。
 */
    | HostsFile
/**
 * Wirestack 公开 API：Static。
 */
    | Static
/**
 * Wirestack 公开 API：Custom。
 */
    | Custom
}

/**
 * Wirestack 公开 API：ResolveErrorCode。
 */
public enum ResolveErrorCode {
/**
 * Wirestack 公开 API：NameNotFound。
 */
    | NameNotFound
/**
 * Wirestack 公开 API：NoData。
 */
    | NoData
/**
 * Wirestack 公开 API：TemporaryFailure。
 */
    | TemporaryFailure
/**
 * Wirestack 公开 API：Timeout。
 */
    | Timeout
/**
 * Wirestack 公开 API：Cancelled。
 */
    | Cancelled
/**
 * Wirestack 公开 API：InvalidName。
 */
    | InvalidName
/**
 * Wirestack 公开 API：UnsupportedFamily。
 */
    | UnsupportedFamily
/**
 * Wirestack 公开 API：SystemFailure。
 */
    | SystemFailure
}

/**
 * Wirestack 公开 API：ResolveOptions。
 */
public struct ResolveOptions {
/**
 * Wirestack 公开 API：family。
 */
    public let family: ResolveAddressFamily
/**
 * Wirestack 公开 API：maxResults。
 */
    public let maxResults: Int64

/**
 * Wirestack 公开 API：init。
 * @param family 参数 family。
 * @param maxResults 参数 maxResults。
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
 * Wirestack 公开 API：ResolveDiagnostics。
 */
public struct ResolveDiagnostics {
/**
 * Wirestack 公开 API：source。
 */
    public let source: ResolverSource
/**
 * Wirestack 公开 API：candidateCount。
 */
    public let candidateCount: Int64
/**
 * Wirestack 公开 API：duplicatesRemoved。
 */
    public let duplicatesRemoved: Int64
/**
 * Wirestack 公开 API：startedAt。
 */
    public let startedAt: MonoTime
/**
 * Wirestack 公开 API：completedAt。
 */
    public let completedAt: MonoTime

/**
 * Wirestack 公开 API：init。
 * @param candidateCount 参数 candidateCount。
 * @param completedAt 参数 completedAt。
 * @param duplicatesRemoved 参数 duplicatesRemoved。
 * @param source 参数 source。
 * @param startedAt 参数 startedAt。
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
 * Wirestack 公开 API：ResolveResult。
 */
public struct ResolveResult {
    private let ownedAddresses: Array<IpAddress>
/**
 * Wirestack 公开 API：canonicalHost。
 */
    public let canonicalHost: HostName
/**
 * Wirestack 公开 API：source。
 */
    public let source: ResolverSource
/**
 * Wirestack 公开 API：expiration。
 */
    public let expiration: ?MonoTime
/**
 * Wirestack 公开 API：diagnostics。
 */
    public let diagnostics: ResolveDiagnostics

/**
 * Wirestack 公开 API：init。
 * @param addresses 参数 addresses。
 * @param canonicalHost 参数 canonicalHost。
 * @param completedAt 参数 completedAt。
 * @param expiration 参数 expiration。
 * @param source 参数 source。
 * @param startedAt 参数 startedAt。
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
 * Wirestack 公开 API：addresses。
 */
    public prop addresses: Array<IpAddress> {
        get() { ownedAddresses.clone() }
    }
}

/**
 * Wirestack 公开 API：ResolveException。
 */
public class ResolveException <: NetworkException {
/**
 * Wirestack 公开 API：resolveCode。
 */
    public let resolveCode: ResolveErrorCode

/**
 * Wirestack 公开 API：init。
 * @param cause 参数 cause。
 * @param message 参数 message。
 * @param resolveCode 参数 resolveCode。
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
 * Wirestack 公开 API：init。
 * @param cause 参数 cause。
 * @param message 参数 message。
 * @param nativeCode 参数 nativeCode。
 * @param resolveCode 参数 resolveCode。
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

/**
 * Wirestack 公开 API：getClassName。
 */
    protected override func getClassName(): String {
        "ResolveException"
    }
}

/**
 * Wirestack 公开 API：Resolver。
 */
public interface Resolver {
/**
 * Wirestack 公开 API：resolve。
 * @param context 参数 context。
 * @param host 参数 host。
 * @param options 参数 options。
 * @param service 参数 service。
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
 * Wirestack 公开 API：init。
 * @param result 参数 result。
 */
    public init(result: ResolveResult) {
        this.result = result
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
