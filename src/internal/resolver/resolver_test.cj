package wirestack.internal.resolver

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func v4(last: Byte): IpAddress {
    IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, last])
}

private func v6(last: Byte): IpAddress {
    let bytes = Array<Byte>(16, repeat: 0)
    bytes[15] = last
    IpAddress(IpAddressFamily.Ipv6, bytes)
}

@Test
class ResolverContractTest {
    @TestCase
    func resultOwnsDeduplicatedAddressesAndDoesNotInventTtl(): Unit {
        let input = [v6(1), v4(1), v6(1)]
        let result = ResolveResult(input, HostName("example.test"), ResolverSource.Static)
        input[0] = v4(9)

        @Expect(result.addresses.size, 2)
        @Expect(result.diagnostics.duplicatesRemoved, 1)
        @Expect(result.expiration.isNone())
        let copy = result.addresses
        copy[0] = v4(8)
        @Expect(result.addresses[0], v6(1))
    }

    @TestCase
    func staticResolverFiltersFamiliesAndHonorsPreCancellation(): Unit {
        let host = HostName("example.test")
        let resolver = StaticResolver(ResolveResult([v6(1), v4(1)], host, ResolverSource.Static))
        let onlyV4 = resolver.resolve(host, options: ResolveOptions(family: ResolveAddressFamily.Ipv4))
        @Expect(onlyV4.addresses.size, 1)
        @Expect(onlyV4.addresses[0].family, IpAddressFamily.Ipv4)

        let source = CancellationSource()
        source.cancel()
        var cancelled = false
        try {
            let _ = resolver.resolve(host, context: OperationContext(cancellation: source.token))
        } catch (error: ResolveException) {
            match (error.resolveCode) {
                case ResolveErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
    }

    @TestCase
    func rejectsEmptyFamilyResultAndInvalidLimits(): Unit {
        let host = HostName("example.test")
        let resolver = StaticResolver(ResolveResult([v4(1)], host, ResolverSource.Static))
        var noData = false
        try {
            let _ = resolver.resolve(host, options: ResolveOptions(family: ResolveAddressFamily.Ipv6))
        } catch (error: ResolveException) {
            match (error.resolveCode) {
                case ResolveErrorCode.NoData => noData = true
                case _ => ()
            }
        }
        @Expect(noData)

        var invalid = false
        try {
            let _ = ResolveOptions(maxResults: 0)
        } catch (_: IllegalArgumentException) {
            invalid = true
        }
        @Expect(invalid)
    }
}

@Test
class M2002ResolverPublicContractTest {
    @TestCase
    func resultOwnsAllTypedCandidatesWithoutInventingTtl(): Unit {
        let input = [m2002V6(1), m2002V4(1), m2002V6(1)]
        let host = api.HostName("resolver.m2-002.test")
        let result = api.ResolveResult(input, host, api.ResolverSource.Static)
        input[0] = m2002V4(9)

        @Expect(result.addresses.size, 2)
        @Expect(result.addresses[0], m2002V6(1))
        @Expect(result.addresses[1], m2002V4(1))
        @Expect(result.canonicalHost, host)
        @Expect(m2002IsStatic(result.source))
        @Expect(result.expiration.isNone())
        @Expect(result.diagnostics.candidateCount, 2)
        @Expect(result.diagnostics.duplicatesRemoved, 1)

        let returned = result.addresses
        returned[0] = m2002V4(8)
        @Expect(result.addresses[0], m2002V6(1))
    }

    @TestCase
    func staticResolverAppliesFamilyAndResultBounds(): Unit {
        let host = api.HostName("resolver.m2-002.test")
        let resolver = api.StaticResolver(api.ResolveResult(
            [m2002V6(1), m2002V4(1), m2002V4(2)], host, api.ResolverSource.Static
        ))

        let ipv4 = resolver.resolve(
            host,
            options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4, maxResults: 1)
        )
        @Expect(ipv4.addresses.size, 1)
        @Expect(ipv4.addresses[0], m2002V4(1))
        @Expect(m2002IsIpv4(ipv4.addresses[0].family))
    }

    @TestCase
    func errorsRetainStablePublicCoordinates(): Unit {
        let host = api.HostName("resolver.m2-002.test")
        let resolver = api.StaticResolver(api.ResolveResult(
            [m2002V4(1)], host, api.ResolverSource.Static
        ))

        let missing = m2002ResolveError({=>
            let _ = resolver.resolve(api.HostName("missing.m2-002.test"))
        })
        @Expect(m2002IsResolveCode(missing.resolveCode, api.ResolveErrorCode.NameNotFound))
        @Expect(m2002IsResolveCategory(missing.category))
        @Expect(m2002IsDnsPhase(missing.phase))
        @Expect(m2002IsNameNotFoundCode(missing.code))
        @Expect(m2002IsNeverRetry(missing.retryability))
        @Expect(missing.nativeCode.isNone())

        let noData = m2002ResolveError({=>
            let _ = resolver.resolve(
                host,
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv6)
            )
        })
        @Expect(m2002IsResolveCode(noData.resolveCode, api.ResolveErrorCode.NoData))
    }

    @TestCase
    func cancellationAndDeadlineRemainDistinct(): Unit {
        let host = api.HostName("resolver.m2-002.test")
        let resolver = api.StaticResolver(api.ResolveResult(
            [m2002V4(1)], host, api.ResolverSource.Static
        ))
        let cancellation = api.CancellationSource()
        cancellation.cancel()

        let cancelled = m2002ResolveError({=>
            let _ = resolver.resolve(
                host,
                context: api.OperationContext(cancellation: cancellation.token)
            )
        })
        @Expect(m2002IsResolveCode(cancelled.resolveCode, api.ResolveErrorCode.Cancelled))

        let timedOut = m2002ResolveError({=>
            let _ = resolver.resolve(
                host,
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(Duration.Zero))
                )
            )
        })
        @Expect(m2002IsResolveCode(timedOut.resolveCode, api.ResolveErrorCode.Timeout))
    }

    @TestCase
    func constructorsRejectInvalidBoundsAndDiagnostics(): Unit {
        @Expect(m2002IllegalArgument({=> let _ = api.ResolveOptions(maxResults: 0) }))
        @Expect(m2002IllegalArgument({=> let _ = api.ResolveOptions(maxResults: 1025) }))

        let now = MonoTime.now()
        @Expect(m2002IllegalArgument({=>
            let _ = api.ResolveDiagnostics(api.ResolverSource.Custom, -1, 0, now, now)
        }))
        @Expect(m2002IllegalArgument({=>
            let _ = api.ResolveDiagnostics(api.ResolverSource.Custom, 0, -1, now, now)
        }))
    }
}

private func m2002V4(last: Byte): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv4, [127, 0, 0, last])
}

private func m2002V6(last: Byte): api.IpAddress {
    let bytes = Array<Byte>(16, repeat: 0)
    bytes[15] = last
    api.IpAddress(api.IpAddressFamily.Ipv6, bytes)
}

private func m2002ResolveError(action: () -> Unit): api.ResolveException {
    try {
        action()
    } catch (error: api.ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func m2002IllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func m2002IsStatic(value: api.ResolverSource): Bool {
    match (value) {
        case api.ResolverSource.Static => true
        case _ => false
    }
}

private func m2002IsIpv4(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv4 => true
        case _ => false
    }
}

private func m2002IsResolveCode(value: api.ResolveErrorCode, expected: api.ResolveErrorCode): Bool {
    match ((value, expected)) {
        case (api.ResolveErrorCode.NameNotFound, api.ResolveErrorCode.NameNotFound) |
             (api.ResolveErrorCode.NoData, api.ResolveErrorCode.NoData) |
             (api.ResolveErrorCode.Timeout, api.ResolveErrorCode.Timeout) |
             (api.ResolveErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) => true
        case _ => false
    }
}

private func m2002IsResolveCategory(value: api.NetworkErrorCategory): Bool {
    match (value) {
        case api.NetworkErrorCategory.Resolve => true
        case _ => false
    }
}

private func m2002IsDnsPhase(value: api.NetworkPhase): Bool {
    match (value) {
        case api.NetworkPhase.Dns => true
        case _ => false
    }
}

private func m2002IsNameNotFoundCode(value: api.NetworkErrorCode): Bool {
    match (value) {
        case api.NetworkErrorCode.NameNotFound => true
        case _ => false
    }
}

private func m2002IsNeverRetry(value: api.Retryability): Bool {
    match (value) {
        case api.Retryability.Never => true
        case _ => false
    }
}
