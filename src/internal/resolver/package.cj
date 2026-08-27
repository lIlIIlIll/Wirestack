package wirestack.internal.resolver

import std.time.MonoTime
import std.collection.ArrayList
import wirestack.internal.common.*
import wirestack.internal.transport.*

public enum ResolveAddressFamily {
    | Any
    | Ipv4
    | Ipv6
}

public enum ResolverSource {
    | System
    | HostsFile
    | Static
    | Custom
}

public enum ResolveErrorCode {
    | NameNotFound
    | NoData
    | TemporaryFailure
    | Timeout
    | Cancelled
    | InvalidName
    | UnsupportedFamily
    | SystemFailure
}

public struct ResolveOptions {
    public let family: ResolveAddressFamily
    public let maxResults: Int64

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

public struct ResolveDiagnostics {
    public let source: ResolverSource
    public let candidateCount: Int64
    public let duplicatesRemoved: Int64
    public let startedAt: MonoTime
    public let completedAt: MonoTime

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

public struct ResolveResult {
    private let ownedAddresses: Array<IpAddress>
    public let canonicalHost: HostName
    public let source: ResolverSource
    public let expiration: ?MonoTime
    public let diagnostics: ResolveDiagnostics

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

    public prop addresses: Array<IpAddress> {
        get() { ownedAddresses.clone() }
    }
}

public class ResolveException <: NetworkException {
    public let resolveCode: ResolveErrorCode

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

    protected override func getClassName(): String {
        "ResolveException"
    }
}

public interface Resolver {
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

    public init(result: ResolveResult) {
        this.result = result
    }

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

internal func checkResolveContext(context: OperationContext): Unit {
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
