package wirestack.internal.resolver

import std.unittest.*
import std.unittest.testmacro.*
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
