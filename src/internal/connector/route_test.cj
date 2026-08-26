package wirestack.internal.connector

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.resolver.*
import wirestack.internal.transport.*

@Test
class ConnectionRouteTest {
    @TestCase
    func directRouteRetainsItsLocalOriginResolver(): Unit {
        let originResolver = staticResolver("origin.test", 10u8)
        let origin = RouteTarget.localName(HostName("origin.test"), 443, originResolver)
        let route = ConnectionRoute.direct(
            origin,
            NetworkBinding("default"),
            RouteSecurity.Tls(RouteTlsParameters("tls-origin", ["h2", "http/1.1"]))
        )

        @Expect(!route.isProxied)
        @Expect(route.connectTarget.hostName, Some(HostName("origin.test")))
        @Expect(route.connectTarget.resolution == RouteResolutionKind.LocalDns)
        let resolved = route.connectTarget.resolver.getOrThrow().resolve(
            HostName("origin.test"), None<String>, ResolveOptions(), OperationContext.background()
        )
        @Expect(resolved.addresses[0].toOctets()[3], 10u8)
    }

    @TestCase
    func explicitProxySeparatesOriginAndProxyDns(): Unit {
        let proxyResolver = staticResolver("proxy.test", 20u8)
        let origin = RouteTarget.remoteName(HostName("origin.test"), 443)
        let proxy = RouteTarget.localName(HostName("proxy.test"), 8080, proxyResolver)
        let route = ConnectionRoute.httpProxy(
            origin,
            proxy,
            NetworkBinding("wifi-primary"),
            RouteSecurity.Tls(RouteTlsParameters("tls-origin", ["h2"]))
        )

        @Expect(route.isProxied)
        @Expect(route.origin.resolution == RouteResolutionKind.RemoteDns)
        @Expect(route.origin.resolver.isNone())
        @Expect(route.connectTarget.hostName, Some(HostName("proxy.test")))
        @Expect(route.connectTarget.resolution == RouteResolutionKind.LocalDns)
        @Expect(route.networkBinding.identity, "wifi-primary")
        match (route.security) {
            case RouteSecurity.Tls(parameters) =>
                @Expect(parameters.contextIdentity, "tls-origin")
                @Expect(parameters.alpnProtocols, ["h2"])
            case _ => @FailExpect("proxy route lost its TLS parameters")
        }
        let resolved = route.connectTarget.resolver.getOrThrow().resolve(
            HostName("proxy.test"), None<String>, ResolveOptions(), OperationContext.background()
        )
        @Expect(resolved.addresses[0].toOctets()[3], 20u8)
    }

    @TestCase
    func typedIpTargetsNeverCarryResolvers(): Unit {
        let origin = RouteTarget.address(SocketEndpoint(ipv4(30u8), 80))
        let proxy = RouteTarget.address(SocketEndpoint(ipv4(40u8), 3128))
        let direct = ConnectionRoute.direct(
            origin, NetworkBinding("ethernet"), RouteSecurity.Plaintext
        )
        let proxied = ConnectionRoute.httpProxy(
            origin, proxy, NetworkBinding("ethernet"), RouteSecurity.Plaintext
        )

        @Expect(direct.connectTarget.resolution == RouteResolutionKind.Resolved)
        @Expect(direct.connectTarget.resolver.isNone())
        @Expect(proxied.connectTarget.socketEndpoint, Some(SocketEndpoint(ipv4(40u8), 3128)))
        @Expect(proxied.connectTarget.resolver.isNone())
    }

    @TestCase
    func rejectsDelegatedDnsWithoutAnOwningProxyAndInvalidConnectTargets(): Unit {
        let remoteOrigin = RouteTarget.remoteName(HostName("origin.test"), 443)
        let _ = @ExpectThrows[IllegalArgumentException](ConnectionRoute.direct(
            remoteOrigin, NetworkBinding("default"), RouteSecurity.Plaintext
        ))
        let _ = @ExpectThrows[IllegalArgumentException](ConnectionRoute.httpProxy(
            remoteOrigin,
            RouteTarget.remoteName(HostName("proxy.test"), 8080),
            NetworkBinding("default"),
            RouteSecurity.Plaintext
        ))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTarget.localName(
            HostName("origin.test"), 0, staticResolver("origin.test", 10u8)
        ))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTarget.address(
            SocketEndpoint(ipv4(10u8), 0)
        ))
    }

    @TestCase
    func networkAndTlsParametersAreBoundedAndOwned(): Unit {
        let input = ["h2", "http/1.1"]
        let tls = RouteTlsParameters("tls-context", input)
        input[0] = "mutated"
        let returned = tls.alpnProtocols
        returned[1] = "also-mutated"

        @Expect(tls.alpnProtocols, ["h2", "http/1.1"])
        @Expect(NetworkBinding("network-a"), NetworkBinding("network-a"))
        @Expect(NetworkBinding("network-a").hashCode(), NetworkBinding("network-a").hashCode())
        @Expect(NetworkBinding(String.fromUtf8(Array<Byte>(256, repeat: b'n'))).identity.size, 256)
        for (identity in ["", "bad\nnetwork", String.fromUtf8(Array<Byte>(257, repeat: b'n'))]) {
            let _ = @ExpectThrows[IllegalArgumentException]({ let _ = NetworkBinding(identity) })
        }
        @Expect(RouteTlsParameters(
            String.fromUtf8(Array<Byte>(512, repeat: b't')), Array<String>()
        ).alpnProtocols.isEmpty())
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters("", ["h2"]))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters("bad\rtls", ["h2"]))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters(
            String.fromUtf8(Array<Byte>(513, repeat: b't')), ["h2"]
        ))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters("tls", [""]))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters("tls", ["h2", "h2"]))
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters(
            "tls", [String.fromUtf8(Array<Byte>(256, repeat: b'a'))]
        ))
        let oversized = Array<String>(17, {index =>
            String.fromUtf8(Array<Byte>(255, {offset =>
                if (offset == 254) { UInt8(index + 65) } else { b'a' }
            }))
        })
        @Expect(RouteTlsParameters("tls", oversized[..16]).alpnProtocols.size, 16)
        let _ = @ExpectThrows[IllegalArgumentException](RouteTlsParameters("tls", oversized))
    }
}

private func staticResolver(host: String, lastOctet: Byte): Resolver {
    StaticResolver(ResolveResult([ipv4(lastOctet)], HostName(host), ResolverSource.Static))
}

private func ipv4(lastOctet: Byte): IpAddress {
    IpAddress(IpAddressFamily.Ipv4, [192u8, 0u8, 2u8, lastOctet])
}
