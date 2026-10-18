package wirestack_m12_001

import std.time.MonoTime
import std.fs.File
import std.sync.AtomicBool
import std.convert.Parsable
import wirestack as api
import wirestack.net.{TcpListener, TcpStream, UdpSocket, SocketOptionName}
import wirestack.tls as tls

func ns(start: MonoTime): Int64 { (MonoTime.now() - start).toNanoseconds() }
func endpoint(): api.SocketEndpoint { api.SocketEndpoint(perfLoopback(), 0) }
func pattern(size: Int64): Array<Byte> {
    let result = Array<Byte>(size, repeat: 0)
    for (i in 0..size) { result[i] = UInt8(i % 251) }
    result
}
func sum(bytes: Array<Byte>): Int64 {
    var value = 0i64
    for (b in bytes) { value += Int64(b) }
    value
}
class IoCount {
    var reads = 0i64
    var writes = 0i64
    var partialWrites = 0i64
    var partialReads = 0i64
}
func send(stream: api.DuplexTransport, bytes: Array<Byte>, chunk: Int64,
    owner: api.OperationContext, counts: IoCount): Unit {
    var offset = 0i64
    while (offset < bytes.size) {
        let length = min(chunk, bytes.size - offset)
        let n = stream.writeSome(api.ByteSpan(bytes, offset: offset, length: length), context: owner)
        counts.writes++
        perfRequire(n > 0 && n <= length, "invalid native write count")
        if (n < length) { counts.partialWrites++ }
        offset += n
    }
}
func receive(stream: api.DuplexTransport, bytes: Array<Byte>, chunk: Int64,
    owner: api.OperationContext, counts: IoCount): Unit {
    var offset = 0i64
    while (offset < bytes.size) {
        let length = min(chunk, bytes.size - offset)
        match (stream.readSome(api.MutableByteSpan(bytes, offset: offset, length: length), context: owner)) {
            case api.ReadResult.Data(n) =>
                counts.reads++
                perfRequire(n > 0 && n <= length, "invalid native read count")
                if (n < length) { counts.partialReads++ }
                offset += n
            case _ => throw IllegalStateException("native stream ended before exact payload")
        }
    }
}
func ioMetrics(client: IoCount, server: IoCount, buffer: Int64, connections: Int64): String {
    "{\"cleanup_owners\":0,\"io_calls_include_warmup\":true,\"read_calls\":${client.reads + server.reads},\"write_calls\":${client.writes + server.writes}," +
    "\"partial_write_calls\":${client.partialWrites + server.partialWrites},\"partial_read_calls\":${client.partialReads + server.partialReads}," +
    "\"buffer_high_water_bytes\":${buffer},\"native_connection_count\":${connections}}"
}
func runTcp(name: String, count: Int64): Unit {
    let owner = perfOwner()
    let size = if (name == "tcp_bulk") { 8 * 1024 * 1024 } else { 128 }
    let chunk = if (name == "tcp_partial") { 7 } else { size }
    let expected = pattern(size)
    let reply = Array<Byte>(size, repeat: 0)
    let incoming = Array<Byte>(size, repeat: 0)
    let listener = TcpListener.bind(endpoint(), context: owner)
    let client = TcpStream.connect(listener.localEndpoint, context: owner)
    let server = listener.accept(context: owner)
    let clientCount = IoCount()
    let serverCount = IoCount()
    let latencies = Array<Int64>(count, repeat: 0)
    var measuredStart = MonoTime.now()
    let worker: Future<Unit> = spawn {
        try {
            for (_ in 0..count + 4) {
                receive(server, incoming, chunk, owner, serverCount)
                perfRequire(incoming == expected, "TCP received bytes differ")
                send(server, incoming, chunk, owner, serverCount)
            }
        } finally { server.close() }
    }
    try {
        for (i in 0..count + 4) {
            if (i == 4) { measuredStart = MonoTime.now() }
            let start = MonoTime.now()
            send(client, expected, chunk, owner, clientCount)
            receive(client, reply, chunk, owner, clientCount)
            perfRequire(reply == expected, "TCP echoed bytes differ")
            if (i >= 4) { latencies[i - 4] = ns(start) }
        }
        worker.get(60 * Duration.second)
    } finally { client.close(); server.close(); listener.close() }
    perfRequire(client.isClosed() && server.isClosed() && listener.isClosed(), "TCP cleanup incomplete")
    let duration = ns(measuredStart)
    emitSample(name, "normal", duration, latencies, count, count, 0, count * size * 2,
        count * sum(expected) * 2, metrics: ioMetrics(clientCount, serverCount, size * 3, 1))
}
func runUdp(count: Int64): Unit {
    let owner = perfOwner()
    let left = UdpSocket.bind(endpoint(), context: owner)
    let right = UdpSocket.bind(endpoint(), context: owner)
    let payload = pattern(1200)
    let latencies = Array<Int64>(count, repeat: 0)
    var measuredStart = MonoTime.now()
    var reads = 0i64
    var writes = 0i64
    try {
        for (i in 0..count + 16) {
            if (i == 16) { measuredStart = MonoTime.now() }
            let start = MonoTime.now()
            perfRequire(left.sendTo(right.localEndpoint.getOrThrow(), api.ByteSpan(payload), context: owner) == payload.size,
                "UDP packet send was not atomic")
            writes++
            let packet = right.receive(payload.size, context: owner)
            reads++
            perfRequire(!packet.truncated && packet.payload == payload, "UDP packet changed")
            perfRequire(right.sendTo(packet.source.getOrThrow(), api.ByteSpan(packet.payload), context: owner) == payload.size,
                "UDP reply was not atomic")
            writes++
            let reply = left.receive(payload.size, context: owner)
            reads++
            perfRequire(!reply.truncated && reply.payload == payload, "UDP reply changed")
            if (i >= 16) { latencies[i - 16] = ns(start) }
        }
    } finally { left.close(); right.close() }
    perfRequire(left.isClosed() && right.isClosed(), "UDP cleanup incomplete")
    let duration = ns(measuredStart)
    emitSample("udp_packets", "normal", duration, latencies, count, count, 0, count * payload.size * 2,
        count * sum(payload) * 2, metrics: "{\"cleanup_owners\":0,\"read_calls\":${reads},\"write_calls\":${writes},\"packet_buffer_bytes\":1200}" )
}
func runCancel(count: Int64): Unit {
    let latencies = Array<Int64>(count, repeat: 0)
    var wakeNs = 0i64
    var measuredStart = MonoTime.now()
    var closeNs = 0i64
    for (i in 0..count + 4) {
        if (i == 4) { measuredStart = MonoTime.now() }
        let owner = perfOwner()
        let listener = TcpListener.bind(endpoint(), context: owner)
        let client = TcpStream.connect(listener.localEndpoint, context: owner)
        let peer = listener.accept(context: owner)
        let cancellation = api.CancellationSource()
        let entered = AtomicBool(false)
        let buffer = Array<Byte>(1, repeat: 0)
        let pending: Future<Unit> = spawn {
            entered.store(true)
            try {
                let _ = client.read(api.MutableByteSpan(buffer), context: api.OperationContext(
                    deadline: owner.deadline, cancellation: cancellation.token))
                throw IllegalStateException("stalled read unexpectedly completed")
            } catch (error: api.NetworkException) {
                match (error.code) { case api.NetworkErrorCode.Cancelled => (); case _ => throw error }
            }
        }
        try {
            while (!entered.load()) { perfRequire(!owner.deadline.getOrThrow().isExpired(), "read did not enter"); sleep(Duration.millisecond) }
            sleep(5 * Duration.millisecond)
            // An option query cannot overlap an admitted native read.
            try {
                let _ = client.getOption(SocketOptionName.NoDelay, context: owner)
                throw IllegalStateException("cancel benchmark read was not active")
            } catch (error: api.NetworkException) {
                match (error.code) { case api.NetworkErrorCode.ConcurrentOperation => (); case _ => throw error }
            }
            let start = MonoTime.now()
            cancellation.cancel()
            pending.get(60 * Duration.second)
            let latency = ns(start)
            let closeStart = MonoTime.now()
            client.close(); peer.close(); listener.close()
            let closed = ns(closeStart)
            perfRequire(client.isClosed() && peer.isClosed() && listener.isClosed(), "cancel cleanup incomplete")
            if (i >= 4) { latencies[i - 4] = latency; wakeNs += latency; closeNs += closed }
        } finally { cancellation.cancel(); client.close(); peer.close(); listener.close() }
    }
    let duration = ns(measuredStart)
    emitSample("tcp_cancel", "cleanup", duration, latencies, count, 0, 0, 0, 0,
        expectedRejections: count, metrics: "{\"cleanup_owners\":0,\"cancel_wakeup_ns\":${wakeNs},\"close_latency_ns\":${closeNs},\"native_connection_count\":${count + 4}}")
}
class TlsSetup {
    let chain: tls.CertificateChain
    let server: tls.TlsServerContext
    let client: tls.TlsClientContext
    init(cert: String, keyPath: String) {
        chain = tls.CertificateChain([tls.DerCertificate(File.readFrom(cert))])
        let key = tls.PrivateKeyRef.pkcs8(File.readFrom(keyPath))
        try {
            server = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
                .versions(tls.TlsVersion.Tls12, tls.TlsVersion.Tls12).build()
        } finally { key.close() }
        client = tls.TlsClientContext.builder().trust(tls.TrustPolicy.customRoots(chain))
            .versions(tls.TlsVersion.Tls12, tls.TlsVersion.Tls12).build()
    }
    func freshClient(): tls.TlsClientContext {
        tls.TlsClientContext.builder().trust(tls.TrustPolicy.customRoots(chain))
            .versions(tls.TlsVersion.Tls12, tls.TlsVersion.Tls12).build()
    }
}
func runTls(name: String, count: Int64, setup: TlsSetup): Unit {
    let latencies = Array<Int64>(count, repeat: 0)
    let handshakeCase = name == "tls_full" || name == "tls_resumed"
    let size = if (name == "tls_bulk") { 8 * 1024 * 1024 } else { 128 }
    let expected = pattern(size)
    let reply = Array<Byte>(size, repeat: 0)
    let incoming = Array<Byte>(size, repeat: 0)
    let clientCount = IoCount()
    let serverCount = IoCount()
    var measuredStart = MonoTime.now()
    var closeNs = 0i64
    var resumed = 0i64
    let listener = TcpListener.bind(endpoint(), context: perfOwner())
    try {
    for (i in 0..count + 4) {
        if (i == 4) { measuredStart = MonoTime.now() }
        let owner = perfOwner()
        let clientContext = if (name == "tls_full") { setup.freshClient() } else { setup.client }
        let accepted: Future<tls.TlsConnection> = spawn {
            setup.server.handshake(listener.accept(context: owner), context: owner)
        }
        let raw = TcpStream.connect(listener.localEndpoint, context: owner)
        let handshakeStart = MonoTime.now()
        let client = clientContext.handshake(raw, tls.HostName("example.test"), context: owner)
        let server = accepted.get(60 * Duration.second)
        let handshakeNs = ns(handshakeStart)
        try {
            if (name == "tls_full") {
                perfRequire(!client.handshakeInfo.resumed && !server.handshakeInfo.resumed, "full handshake resumed")
            }
            if (name == "tls_resumed" && i > 0) {
                perfRequire(client.handshakeInfo.resumed && server.handshakeInfo.resumed, "resumed handshake was full")
            }
            let worker: Future<Unit> = spawn {
                receive(server, incoming, 16384, owner, serverCount)
                perfRequire(incoming == expected, "TLS server bytes differ")
                send(server, incoming, 16384, owner, serverCount)
            }
            let ioStart = MonoTime.now()
            send(client, expected, 16384, owner, clientCount)
            receive(client, reply, 16384, owner, clientCount)
            perfRequire(reply == expected, "TLS client bytes differ")
            worker.get(60 * Duration.second)
            let ioNs = ns(ioStart)
            let closing: Future<Unit> = spawn { server.close(owner) }
            let closeStart = MonoTime.now()
            client.close(owner)
            closing.get(60 * Duration.second)
            let elapsedClose = ns(closeStart)
            perfRequire(client.isClosed() && server.isClosed() && raw.isClosed(), "TLS cleanup incomplete")
            if (i >= 4) {
                let latency = if (handshakeCase) { handshakeNs } else if (name == "tls_close") { elapsedClose } else { ioNs }
                latencies[i - 4] = latency; closeNs += elapsedClose
                if (client.handshakeInfo.resumed) { resumed++ }
            }
        } finally { client.abort(); server.abort(); raw.close() }
    }
    } finally { listener.close() }
    perfRequire(listener.isClosed(), "TLS listener retained")
    let duration = ns(measuredStart)
    let metrics = ioMetrics(clientCount, serverCount, size * 3, count + 4)
    emitSample(name, if (name == "tls_close") { "cleanup" } else { "normal" }, duration, latencies, count, count, 0, count * size * 2,
        count * sum(expected) * 2, metrics: metrics[0..metrics.size - 1] +
        ",\"resumed_handshakes\":${resumed},\"full_handshakes\":${count - resumed},\"close_latency_ns\":${closeNs}}")
}
func runFailure(count: Int64, setup: TlsSetup): Unit {
    let latencies = Array<Int64>(count, repeat: 0)
    var measuredStart = MonoTime.now()
    var closeNs = 0i64
    for (i in 0..count + 2) {
        if (i == 2) { measuredStart = MonoTime.now() }
        let owner = perfOwner()
        let listener = TcpListener.bind(endpoint(), context: owner)
        let raw = TcpStream.connect(listener.localEndpoint, context: owner)
        let stalled = listener.accept(context: owner)
        let deadline = api.Deadline.after(10 * Duration.millisecond)
        let start = MonoTime.now()
        try {
            try {
                let connection = setup.client.handshake(raw, tls.HostName("example.test"),
                    context: api.OperationContext(deadline: Some(deadline)))
                connection.abort()
                throw IllegalStateException("stalled TLS handshake unexpectedly succeeded")
            } catch (error: api.NetworkException) {
                match (error.code) { case api.NetworkErrorCode.TimedOut => (); case _ => throw error }
            }
            let latency = ns(start)
            perfRequire(raw.isClosed(), "failed TLS handshake retained native transport")
            let closeStart = MonoTime.now()
            stalled.close(); listener.close()
            let elapsed = ns(closeStart)
            perfRequire(stalled.isClosed() && listener.isClosed(), "failed TLS peer cleanup incomplete")
            if (i >= 2) { latencies[i - 2] = latency; closeNs += elapsed }
        } finally { raw.close(); stalled.close(); listener.close() }
    }
    let duration = ns(measuredStart)
    emitSample("tls_failure", "failure", duration, latencies, count, 0, 0, 0, 0,
        expectedRejections: count, metrics: "{\"cleanup_owners\":0,\"handshake_timeout_count\":${count},\"close_latency_ns\":${closeNs},\"native_connection_count\":${count + 2}}")
}
main(args: Array<String>): Int64 {
    perfRequire(args.size >= 1, "scenario required")
    let name = args[0]
    let defaultCount = if (name == "tls_full" || name == "tls_resumed" || name == "tls_failure") { 64 } else { 256 }
    let count = if (args.size > 3) { Int64.parse(args[3]) } else { defaultCount }
    perfRequire(count > 0 && count <= 4096, "count outside bounded range")
    match (name) {
        case "tcp_bulk" | "tcp_partial" => runTcp(name, count)
        case "tcp_cancel" => runCancel(count)
        case "udp_packets" => runUdp(count)
        case "tls_full" | "tls_resumed" | "tls_small" | "tls_bulk" | "tls_close" | "tls_failure" =>
            perfRequire(args.size >= 3, "TLS certificate and key required")
            let setup = TlsSetup(args[1], args[2])
            if (name == "tls_failure") { runFailure(count, setup) } else { runTls(name, count, setup) }
        case _ => throw IllegalArgumentException("unknown transport benchmark scenario")
    }
    0
}
