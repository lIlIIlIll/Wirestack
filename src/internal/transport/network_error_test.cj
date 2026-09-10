package wirestack.internal.transport

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.{NetworkEndpoint, UnixEndpoint, UnixEndpointKind}

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
            remoteEndpoint: Some(NetworkEndpoint.Internet(remote))
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
        match (error.remoteEndpoint) {
            case Some(NetworkEndpoint.Internet(endpoint)) => @Expect(endpoint.port, 443)
            case _ => @Fail("expected Internet remote endpoint evidence")
        }
        @Expect(error.toString(), "NetworkException: connection refused")
    }

    @TestCase
    func retainsLocalEndpointCauseAndOptionalDefaults(): Unit {
        let local = SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), 32100)
        let underlying = Exception("socket setup failed")
        let error = NetworkException(
            NetworkErrorCategory.System,
            NetworkPhase.TcpRead,
            NetworkErrorCode.SystemFailure,
            "read failed",
            localEndpoint: Some(NetworkEndpoint.Internet(local)),
            cause: Some<Exception>(underlying)
        )

        match (error.retryability) {
            case Retryability.Unknown => @Expect(true)
            case _ => @Expect(false)
        }
        @Expect(error.nativeCode.isNone())
        @Expect(error.remoteEndpoint.isNone())
        match (error.localEndpoint) {
            case Some(NetworkEndpoint.Internet(endpoint)) => @Expect(endpoint.port, 32100)
            case _ => @Fail("expected Internet local endpoint evidence")
        }
        @Expect(error.cause.getOrThrow().toString(), underlying.toString())
    }

    @TestCase
    func caughtErrorRetainsUnixEndpointBytesNativeCodeAndCause(): Unit {
        let path = UnixEndpoint.pathname("/tmp/wirestack.sock")
        let abstractInput = [0u8, 0xFFu8, 0x2Fu8, 0x00u8, 0x41u8]
        let abstractEndpoint = UnixEndpoint.abstractName(abstractInput)
        abstractInput[1] = 0x01u8
        let underlying = Exception("native Unix socket failure")
        var caught = false

        try {
            throw NetworkException(
                NetworkErrorCategory.Connect,
                NetworkPhase.RawSocket,
                NetworkErrorCode.SystemFailure,
                "Unix socket operation failed",
                nativeCode: Some<Int64>(98),
                localEndpoint: Some(NetworkEndpoint.Unix(path)),
                remoteEndpoint: Some(NetworkEndpoint.Unix(abstractEndpoint)),
                cause: Some<Exception>(underlying)
            )
        } catch (error: NetworkException) {
            caught = true
            @Expect(error.nativeCode, Some<Int64>(98))
            @Expect(error.cause.getOrThrow().toString(), underlying.toString())
            match (error.localEndpoint) {
                case Some(NetworkEndpoint.Unix(endpoint)) =>
                    match (endpoint.kind) {
                        case UnixEndpointKind.Pathname => ()
                        case _ => @Fail("expected pathname local endpoint evidence")
                    }
                    @Expect(endpoint.nameBytes(), "/tmp/wirestack.sock".toArray())
                case _ => @Fail("expected Unix local endpoint evidence")
            }
            match (error.remoteEndpoint) {
                case Some(NetworkEndpoint.Unix(endpoint)) =>
                    match (endpoint.kind) {
                        case UnixEndpointKind.Abstract => ()
                        case _ => @Fail("expected abstract remote endpoint evidence")
                    }
                    @Expect(endpoint.nameBytes(), [0u8, 0xFFu8, 0x2Fu8, 0x00u8, 0x41u8])
                    let returned = endpoint.nameBytes()
                    returned[1] = 0x01u8
                    @Expect(endpoint.nameBytes(), [0u8, 0xFFu8, 0x2Fu8, 0x00u8, 0x41u8])
                case _ => @Fail("expected Unix remote endpoint evidence")
            }
        }
        @Expect(caught)
    }

    @TestCase
    func pathnameRejectsNulWhileAbstractRetainsIt(): Unit {
        var pathnameRejected = false
        try {
            let _ = UnixEndpoint.pathname("/tmp/wire\0stack.sock")
        } catch (_: IllegalArgumentException) {
            pathnameRejected = true
        }
        @Expect(pathnameRejected)

        let abstractEndpoint = UnixEndpoint.abstractName([0x41u8, 0u8, 0x42u8])
        match (abstractEndpoint.kind) {
            case UnixEndpointKind.Abstract => ()
            case _ => @Fail("expected abstract endpoint kind")
        }
        @Expect(abstractEndpoint.nameBytes(), [0x41u8, 0u8, 0x42u8])
    }
}
