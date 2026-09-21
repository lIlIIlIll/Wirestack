package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class NetworkFoundationContractTest {
    @TestCase
    func unixEndpointFormsAreDistinctAndOwned(): Unit {
        let abstractBytes = [0u8, 0xFFu8, 0x01u8]
        let endpoint = UnixEndpoint.abstractName(abstractBytes)
        abstractBytes[1] = 0x02u8

        match (endpoint.kind) {
            case UnixEndpointKind.Abstract => ()
            case _ => @Fail("abstract endpoint kind was changed")
        }
        @Expect(endpoint.nameBytes(), [0u8, 0xFFu8, 0x01u8])
    }

    @TestCase
    func unixEndpointRejectsUnboundedNames(): Unit {
        var rejected = false
        try {
            let _ = UnixEndpoint.abstractName(Array<Byte>(108, repeat: 0u8))
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func rawSocketExclusionsFailClosed(): Unit {
        var rejected = false
        try {
            let _ = RawSocket.open(RawSocketDomain.Packet)
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.Unsupported => rejected = true
                case _ => ()
            }
        }
        @Expect(rejected)
    }

    @TestCase
    func dnsParserAcceptsResponseHeaderAndRejectsQueries(): Unit {
        let parser = DnsMessageParser()
        let summary = parser.parse([
            0x12u8, 0x34u8, 0x81u8, 0x80u8,
            0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8
        ])
        @Expect(summary.transactionId, 0x1234u16)
        @Expect(summary.answerCount, 0)
        @Expect(!summary.truncated)

        var rejected = false
        try {
            let _ = parser.parse([
                0x12u8, 0x34u8, 0u8, 0u8,
                0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8
            ])
        } catch (_: api.ResolveException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func cancelledConnectFailsBeforeSocketCreation(): Unit {
        let source = api.CancellationSource()
        source.cancel()
        let loopback = api.IpAddress(
            api.IpAddressFamily.Ipv4,
            [127u8, 0u8, 0u8, 1u8]
        )
        var cancelled = false
        try {
            let _ = TcpStream.connect(
                api.SocketEndpoint(loopback, 1u16),
                context: api.OperationContext(cancellation: source.token)
            )
        } catch (error: api.NetworkException) {
            match (error.code) {
                case api.NetworkErrorCode.Cancelled => cancelled = true
                case _ => ()
            }
        }
        @Expect(cancelled)
    }
}
