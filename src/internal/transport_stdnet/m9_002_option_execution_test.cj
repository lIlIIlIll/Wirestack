package wirestack.internal.transport_stdnet

import std.net as native
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func optionTestEndpoint(): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0)
}

private func optionTestContext(): api.OperationContext {
    api.OperationContext(deadline: Some(api.Deadline.after(5 * Duration.second)))
}

private func optionTestCode(action: () -> Unit, code: String): Bool {
    try { action(); false }
    catch (error: api.NetworkException) {
        match (error.code) {
            case api.NetworkErrorCode.ConcurrentOperation => code == "concurrent"
            case api.NetworkErrorCode.Cancelled => code == "cancelled"
            case api.NetworkErrorCode.Closed => code == "closed"
            case api.NetworkErrorCode.SystemFailure =>
                let option = match (error.category) { case api.NetworkErrorCategory.Option => true case _ => false }
                let unknown = match (error.retryability) { case api.Retryability.Unknown => true case _ => false }
                code == "system" && option && unknown && error.nativeCode.isNone() && error.cause.isSome()
            case _ => false
        }
    }
}

private func optionTestNativeClosed(value: ?NativeOptionSocket): Bool {
    if (let Some(socket) <- value) {
        try { let _ = queryNativeOption(socket, StdSocketOptionName.ReceiveBuffer, false); false }
        catch (_: native.SocketException) { true }
    } else { false }
}

private class OptionTestFault {
    var observed: ?NativeOptionSocket = None
    var calls: Int64 = 0
    private let failure: Int64

    init(failure: Int64) { this.failure = failure }

    func execute(socket: NativeOptionSocket, option: StdSocketOption, ipv6: Bool): Unit {
        observed = Some(socket)
        calls++
        if (calls == failure) { throw native.SocketException("injected option failure") }
        applyNativeOption(socket, option, ipv6)
    }

    func reset(): Unit { observed = None; calls = 0 }
}

private class OptionTestCounter {
    var calls: Int64 = 0
    func record(): Unit { calls++ }
}

private class OptionTestBarrier {
    private let entered = AtomicBool(false)
    private let released = AtomicBool(false)

    func block(): Unit {
        entered.store(true)
        let expires = MonoTime.now() + 5 * Duration.second
        while (!released.load()) {
            if (MonoTime.now() >= expires) { throw IllegalStateException("option barrier timed out") }
            sleep(Duration.millisecond)
        }
    }

    func awaitEntry(): Unit {
        let expires = MonoTime.now() + 5 * Duration.second
        while (!entered.load()) {
            if (MonoTime.now() >= expires) { throw IllegalStateException("option executor did not enter") }
            sleep(Duration.millisecond)
        }
    }

    func release(): Unit { released.store(true) }
}

@Test
class M9002OptionExecutionTest {
    @TestCase
    func unqualifiedTargetsAllowEmptyOptionsAndRejectExplicitOptions(): Unit {
        for (target in [StdSocketOptionTarget.Listener, StdSocketOptionTarget.Tcp, StdSocketOptionTarget.Udp]) {
            validateSocketOptionsForPlatform([], target, false, true, api.NetworkPhase.TcpConnect, false)
        }
        var rejected = false
        try {
            validateSocketOptionsForPlatform(
                [StdSocketOption(StdSocketOptionName.NoDelay, 1)], StdSocketOptionTarget.Tcp,
                false, true, api.NetworkPhase.TcpConnect, false)
        } catch (error: api.NetworkException) {
            rejected = match ((error.code, error.category, error.phase)) {
                case (api.NetworkErrorCode.Unsupported, api.NetworkErrorCategory.Option,
                    api.NetworkPhase.TcpConnect) => true
                case _ => false
            }
        }
        @Expect(rejected, true)
    }

    @TestCase
    func unqualifiedTargetsSkipOptionDefaults(): Unit {
        let unqualifiedTcp = OptionTestCounter()
        applySocketOptionListForPlatform([], StdSocketOptionTarget.Tcp, optionTestContext(),
            api.NetworkPhase.TcpConnect, true, false, { _ => unqualifiedTcp.record() })
        @Expect(unqualifiedTcp.calls, 0)

        let unqualifiedListener = OptionTestCounter()
        applySocketOptionListForPlatform([], StdSocketOptionTarget.Listener, optionTestContext(),
            api.NetworkPhase.TcpConnect, true, false, { _ => unqualifiedListener.record() })
        @Expect(unqualifiedListener.calls, 0)

        let qualifiedTcp = OptionTestCounter()
        applySocketOptionListForPlatform([], StdSocketOptionTarget.Tcp, optionTestContext(),
            api.NetworkPhase.TcpConnect, true, true, { _ => qualifiedTcp.record() })
        @Expect(qualifiedTcp.calls, 2)

        let qualifiedListener = OptionTestCounter()
        applySocketOptionListForPlatform([], StdSocketOptionTarget.Listener, optionTestContext(),
            api.NetworkPhase.TcpConnect, true, true, { _ => qualifiedListener.record() })
        @Expect(qualifiedListener.calls, 1)
    }
    @TestCase
    func factoriesCloseTheirSocketAtEveryExecutorFailurePosition(): Unit {
        for (failure in 1..=3) {
            let fault = OptionTestFault(failure)
            let execute = { socket: NativeOptionSocket, option: StdSocketOption, ipv6: Bool => fault.execute(socket, option, ipv6) }
            @Expect(optionTestCode({ =>
                let _ = StdNetTransportListener.bindConfigured(optionTestEndpoint(), 8, 4096,
                    [StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096), StdSocketOption(StdSocketOptionName.SendBuffer, 4096)],
                    [], optionTestContext(), execute)
            }, "system"))
            @Expect(fault.calls, failure)
            @Expect(optionTestNativeClosed(fault.observed))
            fault.reset()
            @Expect(optionTestCode({ =>
                let _ = StdNetTransport.connectConfigured(optionTestEndpoint(), optionTestContext(), 4096,
                    [StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096)], execute)
            }, "system"))
            @Expect(fault.calls, failure)
            @Expect(optionTestNativeClosed(fault.observed))
            fault.reset()
            @Expect(optionTestCode({ =>
                let _ = StdNetDatagramSocket.bindConfigured(optionTestEndpoint(),
                    [StdSocketOption(StdSocketOptionName.ReuseAddress, 1), StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096),
                     StdSocketOption(StdSocketOptionName.SendBuffer, 4096)], optionTestContext(), execute)
            }, "system"))
            @Expect(fault.calls, failure)
            @Expect(optionTestNativeClosed(fault.observed))
        }
    }

    @TestCase
    func acceptedFailureClosesOnlyAcceptedSocketAndListenerContinues(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint(),
            acceptedOptions: [StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096)])
        try {
            for (failure in 1..=3) {
                let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
                let fault = OptionTestFault(failure)
                try {
                    @Expect(optionTestCode({ =>
                        let _ = listener.acceptConfigured(optionTestContext(), { socket, option, ipv6 =>
                            fault.execute(socket, option, ipv6)
                        })
                    }, "system"))
                    @Expect(fault.calls, failure)
                    @Expect(optionTestNativeClosed(fault.observed))
                } finally { client.close() }
            }
            let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
            try {
                let accepted = listener.accept(optionTestContext())
                try {
                    @Expect(client.writeSome(api.ByteSpan([31u8]), context: optionTestContext()), 1)
                    let bytes = Array<Byte>(1, repeat: 0u8)
                    let _ = accepted.readSome(api.MutableByteSpan(bytes), context: optionTestContext())
                    @Expect(bytes, [31u8])
                } finally { accepted.close() }
            } finally { client.close() }
        } finally { listener.close() }
    }

    @TestCase
    func cancellationBetweenOptionsRetainsEarlierKernelEffectWithoutAbort(): Unit {
        let socket = StdNetDatagramSocket.bind(optionTestEndpoint())
        let source = api.CancellationSource()
        let calls = AtomicInt64(0)
        try {
            @Expect(optionTestCode({ => socket.configureOptionsUsing(
                [StdSocketOption(StdSocketOptionName.Broadcast, 1), StdSocketOption(StdSocketOptionName.MulticastTtl, 77)],
                api.OperationContext(cancellation: source.token), { selected, option, ipv6 =>
                    calls.fetchAdd(1)
                    applyNativeOption(selected, option, ipv6)
                    source.cancel()
                }) }, "cancelled"))
            @Expect(calls.load(), 1)
            @Expect(socket.queryOption(StdSocketOptionName.Broadcast, optionTestContext()).value, 1)
            @Expect(socket.queryOption(StdSocketOptionName.MulticastTtl, optionTestContext()).value, 1)
            let peer = StdNetDatagramSocket.bind(optionTestEndpoint())
            try {
                @Expect(socket.sendTo(peer.localEndpoint, api.ByteSpan([23u8]), context: optionTestContext()), 1)
                @Expect(peer.receive(1, context: optionTestContext())[0], [23u8])
            } finally { peer.close() }
        } finally { socket.close() }
    }

    @TestCase
    func tcpReadAndControlExcludeEachOtherWithoutStoppingRead(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint())
        let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
        let accepted = listener.accept(optionTestContext())
        try {
            let bytes = Array<Byte>(1, repeat: 0u8)
            let reader = spawn { client.readSome(api.MutableByteSpan(bytes), context: optionTestContext()) }
            @Assert(client.waitUntilReadActive(Duration.second))
            @Expect(optionTestCode({ => client.configureOptions([StdSocketOption(StdSocketOptionName.NoDelay, 0)], optionTestContext()) }, "concurrent"))
            @Expect(optionTestCode({ => let _ = client.queryOption(StdSocketOptionName.NoDelay, optionTestContext()) }, "concurrent"))
            let _ = accepted.writeSome(api.ByteSpan([19u8]), context: optionTestContext())
            let _ = reader.get(5 * Duration.second)
            @Expect(bytes, [19u8])
            let barrier = OptionTestBarrier()
            let configure = spawn { client.configureOptionsUsing([StdSocketOption(StdSocketOptionName.NoDelay, 0)],
                optionTestContext(), { selected, option, ipv6 => barrier.block(); applyNativeOption(selected, option, ipv6) }) }
            try {
                barrier.awaitEntry()
                @Expect(optionTestCode({ => let _ = client.readSome(api.MutableByteSpan(bytes), context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = client.writeSome(api.ByteSpan([1u8]), context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = client.queryOption(StdSocketOptionName.NoDelay, optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => client.configureOptions([], optionTestContext()) }, "concurrent"))
            } finally { barrier.release() }
            configure.get(5 * Duration.second)
            @Expect(client.queryOption(StdSocketOptionName.NoDelay, optionTestContext()).value, 0)
        } finally { client.close(); accepted.close(); listener.close() }
    }

    @TestCase
    func udpControlExcludesSendReceiveConnectAndOtherControl(): Unit {
        let socket = StdNetDatagramSocket.bind(optionTestEndpoint())
        let peer = StdNetDatagramSocket.bind(optionTestEndpoint())
        let barrier = OptionTestBarrier()
        let configure = spawn { socket.configureOptionsUsing([StdSocketOption(StdSocketOptionName.Broadcast, 1)],
            optionTestContext(), { selected, option, ipv6 => barrier.block(); applyNativeOption(selected, option, ipv6) }) }
        try {
            try {
                barrier.awaitEntry()
                @Expect(optionTestCode({ => let _ = socket.sendTo(peer.localEndpoint, api.ByteSpan([1u8]), context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = socket.receive(1, context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => socket.connect(peer.localEndpoint, context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = socket.queryOption(StdSocketOptionName.Broadcast, optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => socket.configureOptions([], optionTestContext()) }, "concurrent"))
            } finally { barrier.release() }
            configure.get(5 * Duration.second)
            @Expect(socket.queryOption(StdSocketOptionName.Broadcast, optionTestContext()).value, 1)
            @Expect(socket.sendTo(peer.localEndpoint, api.ByteSpan([29u8]), context: optionTestContext()), 1)
            @Expect(peer.receive(1, context: optionTestContext())[0], [29u8])
        } finally { barrier.release(); socket.close(); peer.close() }
    }

    @TestCase
    func closeRacingControlRetainsCloseRatherThanLaterAbort(): Unit {
        for (abortFirst in [false, true]) {
            let socket = StdNetDatagramSocket.bind(optionTestEndpoint())
            let barrier = OptionTestBarrier()
            let result = spawn { optionTestCode({ => socket.configureOptionsUsing(
                [StdSocketOption(StdSocketOptionName.Broadcast, 1)], optionTestContext(),
                { selected, option, ipv6 => barrier.block(); applyNativeOption(selected, option, ipv6) }) }, "closed") }
            try {
                barrier.awaitEntry()
                if (abortFirst) { socket.abort() } else { socket.close() }
                if (abortFirst) { socket.close() } else { socket.abort() }
                barrier.release()
                @Expect(result.get(5 * Duration.second))
                @Expect(socket.wasClosedByAbort(), abortFirst)
            } finally { barrier.release(); socket.close() }
        }
    }

    @TestCase
    func blockedAcceptRejectsQueryAndRemainsUsable(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint())
        try {
            let accepted = spawn { listener.accept(optionTestContext()) }
            @Assert(listener.waitUntilAcceptActive(Duration.second))
            @Expect(optionTestCode({ => let _ = listener.queryOption(StdSocketOptionName.ReuseAddress, optionTestContext()) }, "concurrent"))
            let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
            let peer = accepted.get(5 * Duration.second)
            try {
                @Expect(client.writeSome(api.ByteSpan([11u8]), context: optionTestContext()), 1)
                let bytes = Array<Byte>(1, repeat: 0u8)
                let _ = peer.readSome(api.MutableByteSpan(bytes), context: optionTestContext())
                @Expect(bytes, [11u8])
            } finally { client.close(); peer.close() }
            @Expect(listener.queryOption(StdSocketOptionName.ReuseAddress, optionTestContext()).value, 1)
        } finally { listener.close() }
    }

    @TestCase
    func queryControlExcludesListenerAcceptAndTcpIo(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint())
        let listenBarrier = OptionTestBarrier()
        let listenerQuery = spawn { listener.queryOptionUsing(StdSocketOptionName.ReuseAddress, optionTestContext(),
            { selected, name, ipv6 => listenBarrier.block(); queryNativeOption(selected, name, ipv6) }) }
        try {
            try {
                listenBarrier.awaitEntry()
                @Expect(optionTestCode({ => let _ = listener.accept(optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = listener.queryOption(StdSocketOptionName.ReuseAddress, optionTestContext()) }, "concurrent"))
            } finally { listenBarrier.release() }
            @Expect(listenerQuery.get(5 * Duration.second).value, 1)
            let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
            let peer = listener.accept(optionTestContext())
            let barrier = OptionTestBarrier()
            let query = spawn { client.queryOptionUsing(StdSocketOptionName.NoDelay, optionTestContext(),
                { selected, name, ipv6 => barrier.block(); queryNativeOption(selected, name, ipv6) }) }
            try {
                try {
                    barrier.awaitEntry()
                    @Expect(optionTestCode({ => let _ = client.readSome(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)), context: optionTestContext()) }, "concurrent"))
                    @Expect(optionTestCode({ => let _ = client.writeSome(api.ByteSpan([1u8]), context: optionTestContext()) }, "concurrent"))
                    @Expect(optionTestCode({ => client.configureOptions([], optionTestContext()) }, "concurrent"))
                } finally { barrier.release() }
                @Expect(query.get(5 * Duration.second).value, 1)
                let _ = client.writeSome(api.ByteSpan([47u8]), context: optionTestContext())
                let bytes = Array<Byte>(1, repeat: 0u8)
                let _ = peer.readSome(api.MutableByteSpan(bytes), context: optionTestContext())
                @Expect(bytes, [47u8])
            } finally { barrier.release(); client.close(); peer.close() }
        } finally { listenBarrier.release(); listener.close() }
    }

    @TestCase
    func udpReceiveAndQueryControlExcludeEachOther(): Unit {
        let socket = StdNetDatagramSocket.bind(optionTestEndpoint())
        let peer = StdNetDatagramSocket.bind(optionTestEndpoint())
        try {
            let receive = spawn { socket.receive(1, context: optionTestContext()) }
            let expires = MonoTime.now() + 5 * Duration.second
            var concurrent = false
            while (!concurrent && MonoTime.now() < expires) {
                concurrent = optionTestCode({ => let _ = socket.queryOption(StdSocketOptionName.Broadcast, optionTestContext()) }, "concurrent")
                if (!concurrent) { sleep(Duration.millisecond) }
            }
            @Assert(concurrent)
            @Expect(optionTestCode({ => socket.configureOptions([], optionTestContext()) }, "concurrent"))
            let _ = peer.sendTo(socket.localEndpoint, api.ByteSpan([53u8]), context: optionTestContext())
            @Expect(receive.get(5 * Duration.second)[0], [53u8])
            let barrier = OptionTestBarrier()
            let query = spawn { socket.queryOptionUsing(StdSocketOptionName.Broadcast, optionTestContext(),
                { selected, name, ipv6 => barrier.block(); queryNativeOption(selected, name, ipv6) }) }
            try {
                barrier.awaitEntry()
                @Expect(optionTestCode({ => let _ = socket.sendTo(peer.localEndpoint, api.ByteSpan([1u8]), context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => let _ = socket.receive(1, context: optionTestContext()) }, "concurrent"))
                @Expect(optionTestCode({ => socket.connect(peer.localEndpoint, context: optionTestContext()) }, "concurrent"))
            } finally { barrier.release() }
            @Expect(query.get(5 * Duration.second).value, 0)
        } finally { socket.close(); peer.close() }
    }

    @TestCase
    func blockedTcpWriteRejectsControlAndCompletesAfterPeerReads(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint(),
            options: [StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096)],
            acceptedOptions: [StdSocketOption(StdSocketOptionName.ReceiveBuffer, 4096)])
        let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext(),
            stagingBufferSize: 128 * 1024, options: [StdSocketOption(StdSocketOptionName.SendBuffer, 4096)])
        let peer = listener.accept(optionTestContext())
        try {
            let payload = Array<Byte>(128 * 1024, repeat: 61u8)
            let writer = spawn { client.writeSome(api.ByteSpan(payload), context: optionTestContext()) }
            @Assert(client.waitUntilWriteActive(Duration.second))
            @Expect(optionTestCode({ => client.configureOptions([], optionTestContext()) }, "concurrent"))
            @Expect(optionTestCode({ => let _ = client.queryOption(StdSocketOptionName.NoDelay, optionTestContext()) }, "concurrent"))
            let bytes = Array<Byte>(65536, repeat: 0u8)
            var received: Int64 = 0
            while (received < payload.size) {
                match (peer.readSome(api.MutableByteSpan(bytes), context: optionTestContext())) {
                    case api.ReadResult.Data(count) =>
                        @Assert(count > 0 && count <= payload.size - received)
                        for (i in 0..count) {
                            if (bytes[i] != 61u8) { throw IllegalStateException("backpressured payload changed") }
                        }
                        received += count
                    case api.ReadResult.EndOfStream => throw IllegalStateException("writer ended early")
                }
            }
            @Expect(writer.get(5 * Duration.second), payload.size)
            @Expect(received, payload.size)
        } finally { client.close(); peer.close(); listener.close() }
    }

    @TestCase
    func listenerCloseDuringAcceptedOptionsPreventsPublication(): Unit {
        let listener = StdNetTransportListener.bind(optionTestEndpoint())
        let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
        let barrier = OptionTestBarrier()
        let fault = OptionTestFault(99)
        let accepting = spawn { optionTestCode({ =>
            let accepted = listener.acceptConfigured(optionTestContext(), { socket, option, ipv6 =>
                fault.execute(socket, option, ipv6)
                barrier.block()
            })
            accepted.close()
        }, "closed") }
        try {
            barrier.awaitEntry()
            listener.close()
            barrier.release()
            @Expect(accepting.get(5 * Duration.second))
            @Expect(optionTestNativeClosed(fault.observed))
        } finally { barrier.release(); client.close(); listener.close() }
    }

    @TestCase
    func runtimeFailurePreservesExactlyTheSuccessfulPrefix(): Unit {
        for (failure in 1..=3) {
            let socket = StdNetDatagramSocket.bind(optionTestEndpoint())
            let fault = OptionTestFault(failure)
            try {
                socket.configureOptions([StdSocketOption(StdSocketOptionName.Broadcast, 0),
                    StdSocketOption(StdSocketOptionName.MulticastTtl, 1),
                    StdSocketOption(StdSocketOptionName.MulticastLoopback, 1)], optionTestContext())
                @Expect(optionTestCode({ => socket.configureOptionsUsing([
                    StdSocketOption(StdSocketOptionName.Broadcast, 1),
                    StdSocketOption(StdSocketOptionName.MulticastTtl, 77),
                    StdSocketOption(StdSocketOptionName.MulticastLoopback, 0)], optionTestContext(),
                    { selected, option, ipv6 => fault.execute(selected, option, ipv6) }) }, "system"))
                @Expect(fault.calls, failure)
                @Expect(socket.queryOption(StdSocketOptionName.Broadcast, optionTestContext()).value, if (failure > 1) { 1 } else { 0 })
                @Expect(socket.queryOption(StdSocketOptionName.MulticastTtl, optionTestContext()).value, if (failure > 2) { 77 } else { 1 })
                @Expect(socket.queryOption(StdSocketOptionName.MulticastLoopback, optionTestContext()).value, 1)
                let peer = StdNetDatagramSocket.bind(optionTestEndpoint())
                try {
                    @Expect(socket.sendTo(peer.localEndpoint, api.ByteSpan([37u8]), context: optionTestContext()), 1)
                    @Expect(peer.receive(1, context: optionTestContext())[0], [37u8])
                } finally { peer.close() }
            } finally { socket.close() }
        }
    }

    @TestCase
    func acceptedOptionPolicyDoesNotRetainCallerArray(): Unit {
        let options = [StdSocketOption(StdSocketOptionName.NoDelay, 0)]
        let listener = StdNetTransportListener.bind(optionTestEndpoint(), acceptedOptions: options)
        options[0] = StdSocketOption(StdSocketOptionName.NoDelay, 1)
        try {
            let client = StdNetTransport.connect(listener.localEndpoint, context: optionTestContext())
            let peer = (listener.accept(optionTestContext()) as StdNetTransport).getOrThrow()
            try {
                @Expect(peer.queryOption(StdSocketOptionName.NoDelay, optionTestContext()).value, 0)
            } finally { client.close(); peer.close() }
        } finally { listener.close() }
    }
}
