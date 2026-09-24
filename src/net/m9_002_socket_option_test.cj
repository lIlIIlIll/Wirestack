package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.transport_stdnet as stdnet

private func m9002Endpoint(ipv6!: Bool = false): api.SocketEndpoint {
    let bytes = if (ipv6) { Array<Byte>(16, { i => if (i == 15) { 1u8 } else { 0u8 } }) }
        else { [127u8, 0u8, 0u8, 1u8] }
    api.SocketEndpoint(api.IpAddress(if (ipv6) { api.IpAddressFamily.Ipv6 } else { api.IpAddressFamily.Ipv4 }, bytes), 0)
}

private func m9002Context(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(5 * Duration.second)))
}

private func m9002Value(value: SocketOption): Int64 {
    match (value) {
        case SocketOption.ReuseAddress(v) => if (v) { 1 } else { 0 }
        case SocketOption.ReusePort(v) => if (v) { 1 } else { 0 }
        case SocketOption.NoDelay(v) => if (v) { 1 } else { 0 }
        case SocketOption.KeepAlive(v) => if (v) { 1 } else { 0 }
        case SocketOption.Broadcast(v) => if (v) { 1 } else { 0 }
        case SocketOption.ReceiveBuffer(v) => v
        case SocketOption.SendBuffer(v) => v
        case SocketOption.MulticastTtl(v) => Int64(v)
        case SocketOption.Ipv6Only(v) => if (v) { 1 } else { 0 }
        case SocketOption.MulticastInterface(v) => Int64(v)
        case SocketOption.MulticastHopLimit(v) => Int64(v)
        case SocketOption.MulticastLoopback(v) => if (v) { 1 } else { 0 }
    }
}

private func m9002Failure(action: () -> Unit, expected: api.NetworkErrorCode,
    phase!: api.NetworkPhase = api.NetworkPhase.DatagramSend): Bool {
    try { action(); false }
    catch (error: api.NetworkException) {
        let category = match (error.category) { case api.NetworkErrorCategory.Option => true case _ => false }
        let samePhase = match ((error.phase, phase)) {
            case (api.NetworkPhase.DatagramSend, api.NetworkPhase.DatagramSend) |
                 (api.NetworkPhase.TcpConnect, api.NetworkPhase.TcpConnect) |
                 (api.NetworkPhase.ServerAccept, api.NetworkPhase.ServerAccept) => true
            case _ => false
        }
        if (!category || !samePhase || error.localEndpoint.isNone()) { return false }
        match ((error.code, expected)) {
            case (api.NetworkErrorCode.Unsupported, api.NetworkErrorCode.Unsupported) |
                 (api.NetworkErrorCode.InvalidState, api.NetworkErrorCode.InvalidState) |
                 (api.NetworkErrorCode.Cancelled, api.NetworkErrorCode.Cancelled) |
                 (api.NetworkErrorCode.TimedOut, api.NetworkErrorCode.TimedOut) |
                 (api.NetworkErrorCode.SystemFailure, api.NetworkErrorCode.SystemFailure) |
                 (api.NetworkErrorCode.Closed, api.NetworkErrorCode.Closed) => true
            case _ => false
        }
    }
}

@Test
class M9002SocketOptionTest {
    @TestCase
    func udpReadsEffectiveBuffersAndAppliesIpv4Controls(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint(), options: [SocketOption.ReuseAddress(true), SocketOption.ReusePort(true)], context: m9002Context())
        try {
            @Expect(m9002Value(socket.getOption(SocketOptionName.ReuseAddress)), 1)
            @Expect(m9002Value(socket.getOption(SocketOptionName.ReusePort)), 1)
            socket.configure([SocketOption.ReceiveBuffer(4096), SocketOption.SendBuffer(4096), SocketOption.Broadcast(true),
                SocketOption.MulticastTtl(255), SocketOption.MulticastLoopback(false), SocketOption.MulticastInterface(0)])
            @Expect(m9002Value(socket.getOption(SocketOptionName.ReceiveBuffer)), 8192)
            @Expect(m9002Value(socket.getOption(SocketOptionName.SendBuffer)), 8192)
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 1)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastTtl)), 255)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastLoopback)), 0)
            @Expect(m9002Failure({ => let _ = socket.getOption(SocketOptionName.MulticastInterface) }, api.NetworkErrorCode.Unsupported))
            socket.configure([SocketOption.MulticastTtl(0), SocketOption.Broadcast(false), SocketOption.MulticastLoopback(true)])
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastTtl)), 0)
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 0)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastLoopback)), 1)
        } finally { socket.close() }
    }

    @TestCase
    func udpBroadcastCapabilityRequiresQualifiedIpv4Support(): Unit {
        let ipv4 = api.NetworkEndpoint.Internet(m9002Endpoint())
        let ipv6 = api.NetworkEndpoint.Internet(m9002Endpoint(ipv6: true))
        @Expect(udpSocketCapabilities(ipv4, true).broadcast, true)
        @Expect(udpSocketCapabilities(ipv4, false).broadcast, false)
        @Expect(udpSocketCapabilities(ipv6, true).broadcast, false)
        @Expect(udpSocketCapabilities(ipv6, false).broadcast, false)

        let socket = UdpSocket.bind(m9002Endpoint(), context: m9002Context())
        try {
            @Expect(socket.capabilities.broadcast, stdnet.socketOptionsQualified())
        } finally { socket.close() }
    }

    @TestCase
    func ipv6ControlsRejectIpv4OptionsAndPostBindMutation(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint(ipv6: true), options: [SocketOption.Ipv6Only(true)], context: m9002Context())
        try {
            @Expect(m9002Value(socket.getOption(SocketOptionName.Ipv6Only)), 1)
            socket.configure([SocketOption.MulticastHopLimit(255), SocketOption.MulticastInterface(0), SocketOption.MulticastLoopback(false)])
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastHopLimit)), 255)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastInterface)), 0)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastLoopback)), 0)
            @Expect(m9002Failure({ => socket.configure([SocketOption.Broadcast(true)]) }, api.NetworkErrorCode.Unsupported))
            @Expect(m9002Failure({ => socket.configure([SocketOption.MulticastTtl(1)]) }, api.NetworkErrorCode.Unsupported))
            @Expect(m9002Failure({ => socket.configure([SocketOption.Ipv6Only(false)]) }, api.NetworkErrorCode.InvalidState))
            @Expect(m9002Value(socket.getOption(SocketOptionName.Ipv6Only)), 1)
        } finally { socket.close() }
    }

    @TestCase
    func wholeListValidationPrecedesAnyMutation(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint())
        try {
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.Broadcast(true), SocketOption.ReceiveBuffer(0)]))
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.Broadcast(true), SocketOption.Broadcast(false)]))
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.SendBuffer(2147483648)]))
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.MulticastInterface(2147483648)]))
            @AssertThrows[IllegalArgumentException](socket.configure(Array<SocketOption>(13, repeat: SocketOption.Broadcast(true))))
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 0)
            @Expect(m9002Failure({ => socket.configure([SocketOption.NoDelay(true)]) }, api.NetworkErrorCode.Unsupported))
            @Expect(m9002Failure({ => socket.configure([SocketOption.ReuseAddress(true)]) }, api.NetworkErrorCode.InvalidState))
        } finally { socket.close() }
    }

    @TestCase
    func nativeFailureRetainsEarlierEffectsAndSkipsLaterOptions(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint())
        try {
            socket.configure([SocketOption.MulticastTtl(1)])
            @Expect(m9002Failure({ => socket.configure([SocketOption.Broadcast(true), SocketOption.MulticastInterface(2147483647), SocketOption.MulticastTtl(77)]) }, api.NetworkErrorCode.SystemFailure))
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 1)
            @Expect(m9002Value(socket.getOption(SocketOptionName.MulticastTtl)), 1)
            let peer = UdpSocket.bind(m9002Endpoint())
            try {
                @Expect(socket.sendTo(peer.localEndpoint.getOrThrow(), api.ByteSpan([91u8]), context: m9002Context()), 1)
                @Expect(peer.receive(4, context: m9002Context()).payload, [91u8])
            } finally { peer.close() }
        } finally { socket.close() }
    }

    @TestCase
    func cancelledControlDoesNotAbortHealthySocket(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint())
        let source = api.CancellationSource()
        source.cancel()
        try {
            @Expect(m9002Failure({ => socket.configure([SocketOption.Broadcast(true)], context: api.OperationContext(cancellation: source.token)) }, api.NetworkErrorCode.Cancelled))
            let expired = api.OperationContext(deadline: Some(api.Deadline.after(Duration.Zero)))
            @Expect(m9002Failure({ => socket.configure([SocketOption.Broadcast(true)], context: expired) }, api.NetworkErrorCode.TimedOut))
            @Expect(m9002Failure({ => let _ = socket.getOption(SocketOptionName.Broadcast, context: expired) }, api.NetworkErrorCode.TimedOut))
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 0)
            socket.configure([SocketOption.Broadcast(true)])
            @Expect(m9002Value(socket.getOption(SocketOptionName.Broadcast)), 1)
            socket.close()
            @Expect(m9002Failure({ => let _ = socket.getOption(SocketOptionName.Broadcast, context: api.OperationContext(cancellation: source.token)) }, api.NetworkErrorCode.Closed))
        } finally { socket.close() }
    }

    @TestCase
    func acceptedOptionsOverrideDefaultsBeforePublication(): Unit {
        let listener = TcpListener.bind(m9002Endpoint(), acceptedOptions: [SocketOption.NoDelay(false), SocketOption.KeepAlive(true)])
        try {
            @Expect(m9002Value(listener.getOption(SocketOptionName.ReuseAddress)), 1)
            let client = TcpStream.connect(listener.localEndpoint, context: m9002Context())
            try {
                let accepted = listener.accept(context: m9002Context())
                try {
                    @Expect(m9002Value(client.getOption(SocketOptionName.NoDelay)), 1)
                    @Expect(m9002Value(client.getOption(SocketOptionName.KeepAlive)), 0)
                    @Expect(m9002Value(accepted.getOption(SocketOptionName.NoDelay)), 0)
                    @Expect(m9002Value(accepted.getOption(SocketOptionName.KeepAlive)), 1)
                    accepted.configure([SocketOption.NoDelay(true), SocketOption.KeepAlive(false)])
                    @Expect(m9002Value(accepted.getOption(SocketOptionName.NoDelay)), 1)
                    @Expect(m9002Value(accepted.getOption(SocketOptionName.KeepAlive)), 0)
                    @Expect(client.write(api.ByteSpan([17u8]), context: m9002Context()), 1)
                    let buffer = Array<Byte>(1, repeat: 0u8)
                    accepted.readExact(api.MutableByteSpan(buffer), context: m9002Context())
                    @Expect(buffer, [17u8])
                } finally { accepted.close() }
            } finally { client.close() }
        } finally { listener.close() }
    }

    @TestCase
    func reusePortAllowsTwoNativeListeners(): Unit {
        let first = TcpListener.bind(m9002Endpoint(), options: [SocketOption.ReusePort(true)])
        try {
            let second = TcpListener.bind(first.localEndpoint, options: [SocketOption.ReusePort(true)])
            try {
                @Expect(second.localEndpoint, first.localEndpoint)
                @Expect(m9002Value(second.getOption(SocketOptionName.ReusePort)), 1)
                @Expect(m9002Failure({ => let _ = second.getOption(SocketOptionName.NoDelay) }, api.NetworkErrorCode.Unsupported, phase: api.NetworkPhase.ServerAccept))
            } finally { second.close() }
        } finally { first.close() }
    }

    @TestCase
    func bufferExtremesAreClampedAndInvalidDomainsDoNotMutate(): Unit {
        let socket = UdpSocket.bind(m9002Endpoint(), options: [SocketOption.ReceiveBuffer(1), SocketOption.SendBuffer(1)])
        try {
            @Expect(m9002Value(socket.getOption(SocketOptionName.ReceiveBuffer)) > 1)
            @Expect(m9002Value(socket.getOption(SocketOptionName.SendBuffer)) > 1)
            socket.configure([SocketOption.ReceiveBuffer(2147483647), SocketOption.SendBuffer(2147483647)])
            let receive = m9002Value(socket.getOption(SocketOptionName.ReceiveBuffer))
            let send = m9002Value(socket.getOption(SocketOptionName.SendBuffer))
            @Expect(receive > 1 && receive < 2147483647)
            @Expect(send > 1 && send < 2147483647)
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.ReceiveBuffer(-1)]))
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.SendBuffer(0)]))
            @AssertThrows[IllegalArgumentException](socket.configure([SocketOption.ReceiveBuffer(2147483648)]))
            @Expect(m9002Value(socket.getOption(SocketOptionName.ReceiveBuffer)), receive)
            @Expect(m9002Value(socket.getOption(SocketOptionName.SendBuffer)), send)
        } finally { socket.close() }
    }

    @TestCase
    func optionKindsRejectWrongTargetsFamiliesAndCreationStages(): Unit {
        let listener = TcpListener.bind(m9002Endpoint(), options: [SocketOption.ReuseAddress(false), SocketOption.ReusePort(false)])
        let stream = TcpStream.connect(listener.localEndpoint, context: m9002Context())
        let accepted = listener.accept(context: m9002Context())
        try {
            @Expect(m9002Value(listener.getOption(SocketOptionName.ReuseAddress)), 0)
            @Expect(m9002Value(listener.getOption(SocketOptionName.ReusePort)), 0)
            for (option in [SocketOption.ReuseAddress(true), SocketOption.ReusePort(true), SocketOption.Broadcast(true),
                SocketOption.MulticastTtl(1), SocketOption.Ipv6Only(true), SocketOption.MulticastInterface(0),
                SocketOption.MulticastHopLimit(1), SocketOption.MulticastLoopback(true)]) {
                @Expect(m9002Failure({ => stream.configure([option]) }, api.NetworkErrorCode.Unsupported, phase: api.NetworkPhase.TcpConnect))
            }
            for (name in [SocketOptionName.NoDelay, SocketOptionName.KeepAlive, SocketOptionName.Broadcast,
                SocketOptionName.MulticastTtl, SocketOptionName.MulticastInterface, SocketOptionName.MulticastHopLimit,
                SocketOptionName.MulticastLoopback]) {
                @Expect(m9002Failure({ => let _ = listener.getOption(name) }, api.NetworkErrorCode.Unsupported, phase: api.NetworkPhase.ServerAccept))
            }
            stream.configure([SocketOption.ReceiveBuffer(4096), SocketOption.SendBuffer(4096)])
            @Expect(m9002Value(stream.getOption(SocketOptionName.ReceiveBuffer)) > 4096)
            @Expect(m9002Value(stream.getOption(SocketOptionName.SendBuffer)) > 4096)
            let udp = UdpSocket.bind(m9002Endpoint())
            try {
                for (option in [SocketOption.NoDelay(true), SocketOption.KeepAlive(true), SocketOption.Ipv6Only(true), SocketOption.MulticastHopLimit(1)]) {
                    @Expect(m9002Failure({ => udp.configure([option]) }, api.NetworkErrorCode.Unsupported))
                }
                for (option in [SocketOption.ReuseAddress(true), SocketOption.ReusePort(true)]) {
                    @Expect(m9002Failure({ => udp.configure([option]) }, api.NetworkErrorCode.InvalidState))
                }
            } finally { udp.close() }
            for (option in [SocketOption.Broadcast(true), SocketOption.MulticastTtl(1), SocketOption.MulticastInterface(0), SocketOption.MulticastLoopback(true)]) {
                @Expect(m9002Failure({ => let _ = UdpSocket.bind(m9002Endpoint(), options: [option]) }, api.NetworkErrorCode.InvalidState))
            }
        } finally { stream.close(); accepted.close(); listener.close() }
    }

    @TestCase
    func ipv6OnlyChangesRealDualStackBindBehavior(): Unit {
        let wildcard = api.IpAddress(api.IpAddressFamily.Ipv6, Array<Byte>(16, repeat: 0u8))
        let listener = TcpListener.bind(api.SocketEndpoint(wildcard, 0), options: [SocketOption.Ipv6Only(true)])
        try {
            let ipv4 = TcpListener.bind(api.SocketEndpoint(m9002Endpoint().address, listener.localEndpoint.port))
            try { @Expect(ipv4.localEndpoint.port, listener.localEndpoint.port) }
            finally { ipv4.close() }
        } finally { listener.close() }
        let dual = TcpListener.bind(api.SocketEndpoint(wildcard, 0), options: [SocketOption.Ipv6Only(false)])
        try {
            let client = TcpStream.connect(api.SocketEndpoint(m9002Endpoint().address, dual.localEndpoint.port), context: m9002Context())
            let accepted = dual.accept(context: m9002Context())
            try {
                client.writeAll(api.ByteSpan([71u8]), context: m9002Context())
                let bytes = Array<Byte>(1, repeat: 0u8)
                accepted.readExact(api.MutableByteSpan(bytes), context: m9002Context())
                @Expect(bytes, [71u8])
                @Expect(m9002Value(dual.getOption(SocketOptionName.Ipv6Only)), 0)
            } finally { client.close(); accepted.close() }
        } finally { dual.close() }
    }
}
