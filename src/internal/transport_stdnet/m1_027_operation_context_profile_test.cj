package wirestack.internal.transport_stdnet

import std.env.getVariable
import std.net.*
import std.sync.*
import std.time.MonoTime
import std.convert.Parsable
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func m127Loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private func m127Iterations(): Int64 {
    match (getVariable("WIRESTACK_M127_ITERATIONS")) {
        case Some(value) =>
            let parsed = Int64.parse(value)
            if (parsed <= 0) {
                throw IllegalArgumentException("WIRESTACK_M127_ITERATIONS must be positive")
            }
            parsed
        case None => 10000
    }
}

private func m127Profile(stage: String, body: (Int64) -> Int64): Unit {
    let iterations = m127Iterations()
    let started = MonoTime.now()
    let checksum = body(iterations)
    let durationNs = (MonoTime.now() - started).toNanoseconds()
    println(
        "M127_PROFILE stage=${stage} iterations=${iterations} " +
        "durationNs=${durationNs} checksum=${checksum}"
    )
    @Assert(durationNs >= 0)
}

private class M127OperationGate {
    private let active = AtomicBool(true)

    func complete(): Bool {
        active.compareAndSwap(true, false)
    }
}

private func m127ReadyRead(stage: String, context: OperationContext): Unit {
    let listener = StdNetTransportListener.bind(m127Loopback(0), stagingBufferSize: 1)
    let accepted = spawn { listener.accept() }
    let client = StdNetTransport.connect(listener.localEndpoint, stagingBufferSize: 1)
    let server = accepted.get(Duration.second)
    let payload = Array<Byte>(m127Iterations(), repeat: 37u8)
    let buffer = Array<Byte>(1, repeat: 0u8)
    let destination = MutableByteSpan(buffer)
    try {
        writeAll(server, ByteSpan(payload))
        m127Profile(stage) { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                match (client.readSome(destination, context: context)) {
                    case ReadResult.Data(count) =>
                        if (count != 1 || buffer[0] != 37u8) {
                            throw Exception("M1-027 ready read returned invalid data")
                        }
                        checksum += count + Int64(buffer[0])
                    case ReadResult.EndOfStream =>
                        throw Exception("M1-027 ready read reached early EOF")
                }
            }
            checksum
        }
    } finally {
        client.close()
        server.close()
        listener.close()
    }
}

/**
 * M1-027 diagnostic entrypoints. They are Performance-tagged so scripts/check
 * compiles them but does not mix profiling loops into the correctness suite.
 */
@Test
@Tag[Performance]
class M127OperationContextCostProfileTest {
    @TestCase
    func controlLoop(): Unit {
        m127Profile("control-loop") { iterations =>
            var checksum: Int64 = 0
            for (index in 0..iterations) {
                checksum += index & 1
            }
            checksum
        }
    }

    @TestCase
    func backgroundContextCheck(): Unit {
        let context = OperationContext.background()
        m127Profile("background-context-check") { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                if (context.isCancellationRequested()) { checksum += 1 }
                if (context.isDeadlineExceeded()) { checksum += 1 }
            }
            checksum
        }
    }

    @TestCase
    func deadlineCheck(): Unit {
        let context = OperationContext(
            deadline: Some(Deadline.after(24 * Duration.hour))
        )
        m127Profile("deadline-check") { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                if (context.isCancellationRequested()) { checksum += 1 }
                if (context.isDeadlineExceeded()) { checksum += 1 }
            }
            checksum
        }
    }

    @TestCase
    func noneCancellationRegistration(): Unit {
        let token = CancellationToken.none()
        m127Profile("none-cancellation-registration") { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                let registration = token.register { => }
                registration.unregister()
                checksum += 1
            }
            checksum
        }
    }

    @TestCase
    func cancellableRegistration(): Unit {
        let source = CancellationSource()
        m127Profile("cancellable-registration") { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                let registration = source.token.register { => }
                registration.unregister()
                checksum += 1
            }
            checksum
        }
    }

    @TestCase
    func operationGate(): Unit {
        m127Profile("operation-gate") { iterations =>
            var checksum: Int64 = 0
            for (_ in 0..iterations) {
                if (M127OperationGate().complete()) { checksum += 1 }
            }
            checksum
        }
    }

    @TestCase
    func emptyBackgroundRead(): Unit {
        let listener = StdNetTransportListener.bind(m127Loopback(0))
        let accepted = spawn { listener.accept() }
        let client = StdNetTransport.connect(listener.localEndpoint)
        let server = accepted.get(Duration.second)
        let destination = MutableByteSpan(Array<Byte>())
        try {
            m127Profile("empty-background-read") { iterations =>
                var checksum: Int64 = 0
                for (_ in 0..iterations) {
                    match (client.readSome(destination)) {
                        case ReadResult.Data(count) => checksum += count + 1
                        case ReadResult.EndOfStream => ()
                    }
                }
                checksum
            }
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func noneReadTimeoutAssignment(): Unit {
        let listener = StdNetTransportListener.bind(m127Loopback(0))
        let accepted = spawn { listener.accept() }
        let socket = TcpSocket("127.0.0.1", listener.localEndpoint.port)
        socket.connect()
        let server = accepted.get(Duration.second)
        try {
            m127Profile("none-read-timeout-assignment") { iterations =>
                var checksum: Int64 = 0
                for (_ in 0..iterations) {
                    socket.readTimeout = None<Duration>
                    checksum += 1
                }
                checksum
            }
        } finally {
            socket.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func readyBackgroundRead(): Unit {
        m127ReadyRead("ready-background-read", OperationContext.background())
    }

    @TestCase
    func readyObservedRead(): Unit {
        m127ReadyRead(
            "ready-observed-read",
            OperationContext(trace: Some(NetworkTraceContext("m1-027-profile")))
        )
    }
}
