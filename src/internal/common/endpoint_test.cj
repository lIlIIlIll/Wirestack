package wirestack.internal.common

import std.unittest.*
import std.unittest.testmacro.*

@Test
class EndpointTest {
    @TestCase
    func acceptsTypedIpv4AndIpv6WithoutDns(): Unit {
        let v4 = IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1])
        let v6 = IpAddress(IpAddressFamily.Ipv6, Array<Byte>(16, repeat: 0), zone: Some("eth0"))
        let endpoint = SocketEndpoint(v4, 443)

        @Expect(v4.toOctets().size, 4)
        @Expect(v6.toOctets().size, 16)
        @Expect(v6.zone, Some("eth0"))
        @Expect(endpoint.port, 443)
    }

    @TestCase
    func addressOwnsAnImmutableOctetSnapshot(): Unit {
        let input: Array<Byte> = [127, 0, 0, 1]
        let address = IpAddress(IpAddressFamily.Ipv4, input)
        input[0] = 10
        let exposed = address.toOctets()
        exposed[0] = 11

        @Expect(address.toOctets()[0], 127)
    }

    @TestCase
    func rejectsWrongLengthsAndIpv4Zones(): Unit {
        var wrongV4 = false
        try {
            let _ = IpAddress(IpAddressFamily.Ipv4, [127, 0, 0])
        } catch (_: IllegalArgumentException) {
            wrongV4 = true
        }

        var wrongV6 = false
        try {
            let _ = IpAddress(IpAddressFamily.Ipv6, Array<Byte>(15, repeat: 0))
        } catch (_: IllegalArgumentException) {
            wrongV6 = true
        }

        var zoneRejected = false
        try {
            let _ = IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1], zone: Some("eth0"))
        } catch (_: IllegalArgumentException) {
            zoneRejected = true
        }

        @Expect(wrongV4)
        @Expect(wrongV6)
        @Expect(zoneRejected)
    }
}
