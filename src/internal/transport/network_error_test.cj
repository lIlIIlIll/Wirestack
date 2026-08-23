package wirestack.internal.transport

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

@Test
class NetworkErrorTest {
    @TestCase
    func retainsStableClassificationAndEndpointEvidence(): Unit {
        let remote = SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), 443)
        let error = NetworkException(
            NetworkErrorCategory.Connect,
            NetworkPhase.TcpConnect,
            NetworkErrorCode.ConnectRefused,
            "connection refused",
            retryability: Retryability.SafeBeforeWrite,
            nativeCode: Some<Int64>(111),
            remoteEndpoint: Some(remote)
        )

        match (error.category) {
            case NetworkErrorCategory.Connect => @Expect(true)
            case _ => @Expect(false)
        }
        match (error.phase) {
            case NetworkPhase.TcpConnect => @Expect(true)
            case _ => @Expect(false)
        }
        match (error.code) {
            case NetworkErrorCode.ConnectRefused => @Expect(true)
            case _ => @Expect(false)
        }
        match (error.retryability) {
            case Retryability.SafeBeforeWrite => @Expect(true)
            case _ => @Expect(false)
        }
        @Expect(error.nativeCode, Some<Int64>(111))
        @Expect(error.remoteEndpoint.getOrThrow().port, 443)
        @Expect(error.toString(), "NetworkException: connection refused")
    }
}
