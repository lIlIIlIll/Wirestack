package wirestack.internal.transport_stdnet

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func m123Loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

@Test
class M123TransportDiagnosticsTest {
    @TestCase
    func stdNetReportsRuntimeEndpointsAndCapabilitiesWithoutGuessingIoBackend(): Unit {
        let listener = StdNetTransportListener.bind(m123Loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        try {
            let clientInfo = client.info
            let serverInfo = server.info

            @Expect(clientInfo.backend, "std.net")
            @Expect(clientInfo.runtimeIoBackend, "cjnative")
            @Assert(clientInfo.localEndpoint.isSome())
            @Expect(clientInfo.remoteEndpoint, Some(listener.localEndpoint))
            @Expect(!clientInfo.supportsHalfClose)
            @Expect(clientInfo.supportsAbort)

            @Expect(serverInfo.backend, "std.net")
            @Expect(serverInfo.runtimeIoBackend, "cjnative")
            @Expect(serverInfo.localEndpoint, clientInfo.remoteEndpoint)
            @Expect(serverInfo.remoteEndpoint, clientInfo.localEndpoint)
            @Expect(!serverInfo.supportsHalfClose)
            @Expect(serverInfo.supportsAbort)

            client.close()
            @Expect(client.info.backend, clientInfo.backend)
            @Expect(client.info.runtimeIoBackend, clientInfo.runtimeIoBackend)
            @Expect(client.info.localEndpoint, clientInfo.localEndpoint)
            @Expect(client.info.remoteEndpoint, clientInfo.remoteEndpoint)
            @Expect(client.info.supportsHalfClose, clientInfo.supportsHalfClose)
            @Expect(client.info.supportsAbort, clientInfo.supportsAbort)
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func deterministicTransportUsesTheSameProviderNeutralContract(): Unit {
        let (left, right) = MemoryTransport.pair()
        try {
            let info = left.info
            @Expect(info.backend, "memory")
            @Expect(info.runtimeIoBackend, "deterministic")
            @Expect(info.localEndpoint.isNone())
            @Expect(info.remoteEndpoint.isNone())
            @Expect(info.supportsHalfClose)
            @Expect(info.supportsAbort)
        } finally {
            left.close()
            right.close()
        }
    }
}
