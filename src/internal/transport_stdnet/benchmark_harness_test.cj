package wirestack.internal.transport_stdnet

import std.convert.*
import std.env.getVariable
import std.net.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private func benchmarkVariable(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing benchmark variable ${name}")
    }
}

private func benchmarkEndpoint(): SocketEndpoint {
    let host = benchmarkVariable("WIRESTACK_NET05_HOST")
    if (host != "127.0.0.1") {
        throw IllegalArgumentException("the M0-010 harness accepts only 127.0.0.1")
    }
    SocketEndpoint(
        IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]),
        UInt16.parse(benchmarkVariable("WIRESTACK_NET05_PORT"))
    )
}

private func runRawStdNetBenchmark(): Unit {
    let expected = Int64.parse(benchmarkVariable("WIRESTACK_NET05_EXPECTED"))
    let bufferSize = Int64.parse(benchmarkVariable("WIRESTACK_NET05_BUFFER_SIZE"))
    if (expected <= 0 || bufferSize <= 0) {
        throw IllegalArgumentException("benchmark sizes must be positive")
    }
    let endpoint = benchmarkEndpoint()
    let socket = TcpSocket("127.0.0.1", endpoint.port)
    socket.connect()
    let buffer = Array<Byte>(bufferSize, repeat: 0)
    let started = MonoTime.now()
    var total: Int64 = 0
    var reads: Int64 = 0
    var invalid: Int64 = 0
    var eof = false
    var durationNs: Int64 = -1
    try {
        while (total < expected) {
            let count = socket.read(buffer)
            if (count == 0) {
                eof = true
                break
            }
            for (index in 0..count) {
                if (buffer[index] != 37u8) { invalid += 1 }
            }
            total += count
            reads += 1
            println("READ size=${count}")
        }
        durationNs = (MonoTime.now() - started).toNanoseconds()
    } finally {
        socket.close()
    }
    println(
        "RESULT bytes=${total} readCalls=${reads} invalid=${invalid} eof=${eof} " +
        "durationNs=${durationNs} closeCode=0 bufferSize=${bufferSize}"
    )
    @Expect(total, expected)
    @Expect(invalid, 0)
    @Expect(!eof)
}

private func runStdNetTransportBenchmark(): Unit {
    let expected = Int64.parse(benchmarkVariable("WIRESTACK_NET05_EXPECTED"))
    let bufferSize = Int64.parse(benchmarkVariable("WIRESTACK_NET05_BUFFER_SIZE"))
    if (expected <= 0 || bufferSize <= 0) {
        throw IllegalArgumentException("benchmark sizes must be positive")
    }
    let transport = StdNetTransport.connect(
        benchmarkEndpoint(), stagingBufferSize: bufferSize
    )
    let buffer = Array<Byte>(bufferSize, repeat: 0)
    let destination = MutableByteSpan(buffer)
    let started = MonoTime.now()
    var total: Int64 = 0
    var reads: Int64 = 0
    var invalid: Int64 = 0
    var eof = false
    var durationNs: Int64 = -1
    try {
        while (total < expected) {
            match (transport.readSome(destination)) {
                case Data(count) =>
                    for (index in 0..count) {
                        if (buffer[index] != 37u8) { invalid += 1 }
                    }
                    total += count
                    reads += 1
                    println("READ size=${count}")
                case EndOfStream =>
                    eof = true
                    break
            }
        }
        durationNs = (MonoTime.now() - started).toNanoseconds()
    } finally {
        transport.close()
    }
    let (copiedReadBytes, copiedWriteBytes) = transport.stagingCopiedBytes
    println(
        "RESULT bytes=${total} readCalls=${reads} invalid=${invalid} eof=${eof} " +
        "durationNs=${durationNs} closeCode=0 bufferSize=${bufferSize} " +
        "copiedReadBytes=${copiedReadBytes} copiedWriteBytes=${copiedWriteBytes}"
    )
    @Expect(total, expected)
    @Expect(invalid, 0)
    @Expect(!eof)
    @Expect(copiedReadBytes, 0)
    @Expect(copiedWriteBytes, 0)
}

/** Machine-readable adapter leg for M0-010. Threshold decisions live in the Python gate. */
@Test
@Tag[Performance]
class Net05StdNetTransportBenchmarkTest {
    @TestCase
    func receive(): Unit { runStdNetTransportBenchmark() }
}

/** Raw std.net leg in the same process shape as the adapter comparison. */
@Test
@Tag[Performance]
class Net05RawStdNetBenchmarkTest {
    @TestCase
    func receive(): Unit { runRawStdNetBenchmark() }
}
