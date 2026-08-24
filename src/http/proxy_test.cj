package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpProxyPolicyTest {
    @TestCase
    func noProxyMatchesDnsBoundariesAndOptionalPorts(): Unit {
        let policy = NoProxyPolicy(["example.com", ".internal.test", "api.test:8443"])
        @Expect(policy.matches(HttpUrl.parse("https://example.com/")))
        @Expect(policy.matches(HttpUrl.parse("https://www.example.com/")))
        @Expect(!policy.matches(HttpUrl.parse("https://notexample.com/")))
        @Expect(policy.matches(HttpUrl.parse("http://deep.internal.test/")))
        @Expect(policy.matches(HttpUrl.parse("https://api.test:8443/")))
        @Expect(!policy.matches(HttpUrl.parse("https://api.test/")))
    }

    @TestCase
    func noProxyMatchesTypedIpLiteralsExactlyAndWildcardExplicitly(): Unit {
        let policy = NoProxyPolicy(["127.0.0.1", "[2001:db8::1]:443"])
        @Expect(policy.matches(HttpUrl.parse("http://127.0.0.1/")))
        @Expect(!policy.matches(HttpUrl.parse("http://127.0.0.2/")))
        @Expect(policy.matches(HttpUrl.parse("https://[2001:db8::1]/")))
        @Expect(!policy.matches(HttpUrl.parse("http://[2001:db8::1]/")))
        @Expect(NoProxyPolicy(["*"]).matches(HttpUrl.parse("https://anything.test/")))
    }

    @TestCase
    func endpointsRetainDnsIpv4AndIpv6RouteIdentity(): Unit {
        let dns = HttpProxyEndpoint.hostname("Proxy.Example", 8080)
        @Expect(dns.identity, "proxy.example:8080")
        @Expect(dns.hostName.isSome())
        let ipv4 = HttpProxyEndpoint.address(
            IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8]), 3128
        )
        @Expect(ipv4.identity, "192.0.2.1:3128")
        let ipv6 = HttpProxyEndpoint.address(
            IpAddress(IpAddressFamily.Ipv6, Array<Byte>(16, repeat: 0)), 3128
        )
        @Expect(ipv6.identity.startsWith("["))
        @Expect(ipv6.identity.endsWith("]:3128"))
    }

    @TestCase
    func routeSelectionUsesNoProxyWithoutCallingAuthorizationHook(): Unit {
        let resolver = StaticResolver(ResolveResult(
            [IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, 1u8])],
            HostName("proxy.test"), ResolverSource.Static
        ))
        let config = HttpProxyConfig(
            HttpProxyEndpoint.hostname("proxy.test", 8080),
            resolver,
            noProxy: NoProxyPolicy(["direct.test"])
        )
        match (config.routeFor(HttpUrl.parse("http://direct.test/"))) {
            case HttpProxyRoute.Direct => @Expect(true)
            case _ => @Expect(false)
        }
        match (config.routeFor(HttpUrl.parse("http://origin.test/"))) {
            case HttpProxyRoute.Proxy(selected) => @Expect(selected.endpoint.identity, "proxy.test:8080")
            case _ => @Expect(false)
        }
        @Expect(config.authorization(HttpUrl.parse("http://origin.test/"), OperationContext.background()).isNone())
    }

    @TestCase
    func rejectsAmbiguousNoProxyPatternsAndEndpointPorts(): Unit {
        for (pattern in ["", "*example.com", "example.com/path", "user@example.com"]) {
            var rejected = false
            try { let _ = NoProxyPolicy([pattern]) } catch (_: IllegalArgumentException) { rejected = true }
            @Expect(rejected)
        }
        var portRejected = false
        try { let _ = HttpProxyEndpoint.hostname("proxy.test", 0) }
        catch (_: IllegalArgumentException) { portRejected = true }
        @Expect(portRejected)
    }
}
