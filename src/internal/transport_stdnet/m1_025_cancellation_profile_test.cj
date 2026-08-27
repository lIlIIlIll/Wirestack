package wirestack.internal.transport_stdnet

import std.env.getVariable
import std.convert.*
import std.net.*
import std.sync.AtomicInt64
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func m125Loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private func m125Port(address: SocketAddress): UInt16 {
    match (address) {
        case endpoint: IPSocketAddress => endpoint.port
        case _ => throw IllegalStateException("M1-025 requires an IP listener")
    }
}

private func m125Count(name: String, defaultValue: Int64): Int64 {
    match (getVariable(name)) {
        case Some(value) =>
            let parsed = Int64.parse(value)
            if (parsed <= 0 || parsed > 1000) {
                throw IllegalArgumentException("${name} must be in 1..1000")
            }
            parsed
        case None => defaultValue
    }
}

private func m125Cancelled(error: NetworkException, read: Bool): Bool {
    let categoryMatches = if (read) {
        match (error.category) {
            case NetworkErrorCategory.Read => true
            case _ => false
        }
    } else {
        match (error.category) {
            case NetworkErrorCategory.Write => true
            case _ => false
        }
    }
    let phaseMatches = if (read) {
        match (error.phase) {
            case NetworkPhase.TcpRead => true
            case _ => false
        }
    } else {
        match (error.phase) {
            case NetworkPhase.TcpWrite => true
            case _ => false
        }
    }
    let codeMatches = match (error.code) {
        case NetworkErrorCode.Cancelled => true
        case _ => false
    }
    categoryMatches && phaseMatches && codeMatches
}

private func m125Print(
    scenario: String,
    index: Int64,
    warmup: Int64,
    active: Bool,
    cancelled: Bool,
    latencyNs: Int64,
    progress: Int64
): Unit {
    let terminal = if (cancelled) { "cancelled" } else { "other" }
    println(
        "M125_CANCEL scenario=${scenario} index=${index} measured=${index >= warmup} " +
        "active=${active} terminal=${terminal} " +
        "latencyNs=${latencyNs} completed=true progress=${progress}"
    )
}

@Test
@Tag[Performance]
class M125TransportCancellationProfileTest {
    @TestCase
    func blockedRead(): Unit {
        let warmup = m125Count("WIRESTACK_M125_WARMUP", 1)
        let repetitions = m125Count("WIRESTACK_M125_REPETITIONS", 20)
        let listener = StdNetTransportListener.bind(m125Loopback(0), backlog: 16)
        try {
            for (index in 0..(warmup + repetitions)) {
                let accepted: Future<DuplexTransport> = spawn { listener.accept() }
                let client = StdNetTransport.connect(listener.localEndpoint)
                let server = accepted.get(5 * Duration.second)
                let source = CancellationSource()
                let result: Future<Bool> = spawn {
                    try {
                        let _ = client.readSome(
                            MutableByteSpan(Array<Byte>(1, repeat: 0)),
                            context: OperationContext(cancellation: source.token)
                        )
                        false
                    } catch (error: NetworkException) {
                        m125Cancelled(error, true)
                    }
                }
                try {
                    let active = client.waitUntilReadActive(5 * Duration.second)
                    @Assert(active)
                    let started = MonoTime.now()
                    source.cancel()
                    let cancelled = result.get(5 * Duration.second)
                    let latencyNs = (MonoTime.now() - started).toNanoseconds()
                    @Assert(cancelled)
                    @Assert(client.isClosed())
                    m125Print("blocked-read", index, warmup, active, cancelled, latencyNs, 0)
                } finally {
                    client.abort()
                    server.close()
                }
            }
        } finally {
            listener.close()
        }
    }

    @TestCase
    func blockedWrite(): Unit {
        let warmup = m125Count("WIRESTACK_M125_WARMUP", 1)
        let repetitions = m125Count("WIRESTACK_M125_REPETITIONS", 20)
        let listener = TcpServerSocket(bindAt: 0u16)
        listener.backlogSize = 16
        listener.bind()
        try {
            for (index in 0..(warmup + repetitions)) {
                let accepted: Future<TcpSocket> = spawn { listener.accept() }
                let socket = TcpSocket("127.0.0.1", m125Port(listener.localAddress))
                socket.sendBufferSize = 4096
                socket.connect()
                let peer = accepted.get(5 * Duration.second)
                peer.receiveBufferSize = 4096
                let client = StdNetTransport.fromAccepted(socket, stagingBufferSize: 64 * 1024)
                let source = CancellationSource()
                let progress = AtomicInt64(0)
                let result: Future<Bool> = spawn {
                    try {
                        let payload = ByteSpan(Array<Byte>(64 * 1024, repeat: 37))
                        while (true) {
                            progress.fetchAdd(1)
                            let _ = client.writeSome(
                                payload,
                                context: OperationContext(cancellation: source.token)
                            )
                        }
                        false
                    } catch (error: NetworkException) {
                        m125Cancelled(error, false)
                    }
                }
                try {
                    let active = client.waitUntilWriteActive(5 * Duration.second)
                    @Assert(active)
                    sleep(100 * Duration.millisecond)
                    let before = progress.load()
                    sleep(100 * Duration.millisecond)
                    @Assert(progress.load(), before)
                    let started = MonoTime.now()
                    source.cancel()
                    let cancelled = result.get(5 * Duration.second)
                    let latencyNs = (MonoTime.now() - started).toNanoseconds()
                    @Assert(cancelled)
                    @Assert(client.isClosed())
                    m125Print("blocked-write", index, warmup, active, cancelled, latencyNs, before)
                } finally {
                    client.abort()
                    peer.close()
                }
            }
        } finally {
            listener.close()
        }
    }
}
