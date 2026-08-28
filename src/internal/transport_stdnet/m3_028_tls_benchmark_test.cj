package wirestack.internal.transport_stdnet

import std.collection.*
import std.convert.Parsable
import std.env.getVariable
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.tls_engine.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private func m3028Variable(name: String): String {
    match (getVariable(name)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing M3-028 variable ${name}")
    }
}

private func m3028Loopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]), port)
}

private struct M3028Contexts {
    let clientProvider: AwsLcTlsProvider
    let serverProvider: AwsLcTlsProvider
    let client: TlsClientContext
    let server: TlsServerContext
    let key: PrivateKeyRef

    init(version: String, certificate: Array<Byte>, keyBytes: Array<Byte>) {
        clientProvider = AwsLcTlsProvider()
        serverProvider = AwsLcTlsProvider()
        key = PrivateKeyRef.pkcs8(keyBytes)
        let minimum = if (version == "tls12") { TlsVersion.Tls12 } else { TlsVersion.Tls13 }
        let maximum = minimum
        client = TlsClientContext.builder(
            clientProvider.manifest(), clientProvider.linuxCapabilities()
        ).trust(TrustPolicy.customRoots(CertificateChain([DerCertificate(certificate)])))
            .versions(minimum, maximum)
            .build()
        server = TlsServerContext.builder(
            serverProvider.manifest(), serverProvider.linuxCapabilities()
        ).identity(LocalIdentity(
            CertificateChain([DerCertificate(certificate)]), key
        )).versions(minimum, maximum).build()
    }

    func close(): Unit {
        key.close()
        clientProvider.close()
        serverProvider.close()
    }
}

private func m3028RawPair(
    listener: StdNetTransportListener,
    context: OperationContext
): (DuplexTransport, DuplexTransport) {
    let accepting = spawn { listener.accept(context) }
    let client = StdNetTransport.connect(listener.localEndpoint, context: context)
    (client, accepting.get(3 * Duration.second))
}

private func m3028HandshakePair(
    contexts: M3028Contexts,
    clientRaw: DuplexTransport,
    serverRaw: DuplexTransport,
    context: OperationContext
): (TlsConnection, TlsConnection, Int64) {
    let clientEngine = contexts.clientProvider.createClientEngine(
        contexts.client,
        ReferenceIdentity.Dns(HostName("example.com")),
        serverName: Some(HostName("example.com"))
    )
    let serverEngine = contexts.serverProvider.createServerEngine(contexts.server)
    let accepting = spawn {
        TlsConnection.handshake(serverEngine, serverRaw, context: context)
    }
    let started = MonoTime.now()
    let client = TlsConnection.handshake(clientEngine, clientRaw, context: context)
    let server = accepting.get(3 * Duration.second)
    let duration = (MonoTime.now() - started).toNanoseconds()
    (client, server, duration)
}

private func m3028AbortPair(client: TlsConnection, server: TlsConnection): Unit {
    client.abort(reason: Some(AbortReason.ApplicationAbort))
    server.abort(reason: Some(AbortReason.ApplicationAbort))
}

private func m3028ProcessTicket(client: TlsConnection, server: TlsConnection): Unit {
    writeAll(server, ByteSpan([0x5a]))
    let input = Array<Byte>(1, repeat: 0)
    match (client.readSome(MutableByteSpan(input))) {
        case ReadResult.Data(count) => @Assert(count, 1)
        case ReadResult.EndOfStream => @Assert(false)
    }
}

private func m3028FullHandshake(
    contexts: M3028Contexts,
    listener: StdNetTransportListener,
    context: OperationContext,
    iterations: Int64,
    requireResumed: Bool
): Int64 {
    var duration: Int64 = 0
    if (requireResumed) {
        let (clientRaw, serverRaw) = m3028RawPair(listener, context)
        let (client, server, _) = m3028HandshakePair(
            contexts, clientRaw, serverRaw, context
        )
        m3028ProcessTicket(client, server)
        m3028AbortPair(client, server)
    }
    for (_ in 0..iterations) {
        let (clientRaw, serverRaw) = m3028RawPair(listener, context)
        let (client, server, elapsed) = m3028HandshakePair(
            contexts, clientRaw, serverRaw, context
        )
        try {
            @Assert(client.handshakeInfo.isSome())
            @Assert(server.handshakeInfo.isSome())
            if (requireResumed) {
                @Assert(client.handshakeInfo.getOrThrow().resumed)
                @Assert(server.handshakeInfo.getOrThrow().resumed)
                m3028ProcessTicket(client, server)
            }
            duration += elapsed
        } finally {
            m3028AbortPair(client, server)
        }
    }
    duration
}

private func m3028Bulk(
    contexts: M3028Contexts,
    listener: StdNetTransportListener,
    context: OperationContext,
    bytes: Int64
): Int64 {
    let (clientRaw, serverRaw) = m3028RawPair(listener, context)
    let (client, server, _) = m3028HandshakePair(contexts, clientRaw, serverRaw, context)
    let reading: Future<Int64> = spawn {
        let input = Array<Byte>(16 * 1024, repeat: 0)
        var received: Int64 = 0
        while (received < bytes) {
            let requested = min(input.size, bytes - received)
            match (server.readSome(MutableByteSpan(input, length: requested), context: context)) {
                case ReadResult.Data(count) => received += count
                case ReadResult.EndOfStream => throw IllegalStateException("early TLS EOF")
            }
        }
        received
    }
    let output = Array<Byte>(16 * 1024, repeat: 0x5a)
    let started = MonoTime.now()
    var sent: Int64 = 0
    try {
        while (sent < bytes) {
            let count = min(output.size, bytes - sent)
            writeAll(client, ByteSpan(output, length: count), context: context)
            sent += count
        }
        @Assert(reading.get(30 * Duration.second), bytes)
        (MonoTime.now() - started).toNanoseconds()
    } finally {
        m3028AbortPair(client, server)
    }
}

private func m3028ReadExact(
    transport: DuplexTransport,
    expected: String,
    context: OperationContext
): Unit {
    let wanted = expected.toArray()
    let input = Array<Byte>(wanted.size, repeat: 0)
    var offset: Int64 = 0
    while (offset < input.size) {
        match (transport.readSome(MutableByteSpan(
            input, offset: offset, length: input.size - offset
        ), context: context)) {
            case ReadResult.Data(count) => offset += count
            case ReadResult.EndOfStream => throw IllegalStateException("early interop EOF")
        }
    }
    @Assert(input, wanted)
}

private func m3028InteropClient(
    contexts: M3028Contexts,
    port: UInt16,
    context: OperationContext
): Int64 {
    let raw = StdNetTransport.connect(m3028Loopback(port), context: context)
    let started = MonoTime.now()
    let secured = TlsConnection.handshake(
        contexts.clientProvider.createClientEngine(
            contexts.client,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        ),
        raw,
        context: context
    )
    try {
        writeAll(secured, ByteSpan("ping\n".toArray()), context: context)
        m3028ReadExact(secured, "gnip\n", context)
        (MonoTime.now() - started).toNanoseconds()
    } finally {
        secured.close(context)
    }
}

private func m3028InteropServer(
    contexts: M3028Contexts,
    listener: StdNetTransportListener,
    context: OperationContext
): Int64 {
    println("M3028_READY port=${listener.localEndpoint.port}")
    let raw = listener.accept(context)
    let started = MonoTime.now()
    let secured = TlsConnection.handshake(
        contexts.serverProvider.createServerEngine(contexts.server),
        raw,
        context: context
    )
    try {
        m3028ReadExact(secured, "ping\n", context)
        writeAll(secured, ByteSpan("pong\n".toArray()), context: context)
        (MonoTime.now() - started).toNanoseconds()
    } finally {
        secured.close(context)
    }
}

private func m3028Idle(
    contexts: M3028Contexts,
    listener: StdNetTransportListener,
    context: OperationContext,
    pairs: Int64
): Int64 {
    let clients = ArrayList<TlsConnection>()
    let servers = ArrayList<TlsConnection>()
    let started = MonoTime.now()
    try {
        for (_ in 0..pairs) {
            let (clientRaw, serverRaw) = m3028RawPair(listener, context)
            let (client, server, _) = m3028HandshakePair(
                contexts, clientRaw, serverRaw, context
            )
            clients.add(client)
            servers.add(server)
        }
        println("M3028_IDLE_READY pairs=${pairs} connections=${pairs * 2}")
        sleep(2 * Duration.second)
        (MonoTime.now() - started).toNanoseconds()
    } finally {
        for (client in clients) {
            client.abort(reason: Some(AbortReason.ApplicationAbort))
        }
        for (server in servers) {
            server.abort(reason: Some(AbortReason.ApplicationAbort))
        }
    }
}

/** Machine-readable native Linux TLS benchmark entrypoint. */
@Test
@Tag[Performance]
class M3028TlsBenchmarkTest {
    @TestCase
    func runProfile(): Unit {
        let scenario = m3028Variable("WIRESTACK_M3_028_SCENARIO")
        let version = m3028Variable("WIRESTACK_M3_028_VERSION")
        let iterations = Int64.parse(m3028Variable("WIRESTACK_M3_028_ITERATIONS"))
        let bytes = Int64.parse(m3028Variable("WIRESTACK_M3_028_BYTES"))
        if (version != "tls12" && version != "tls13") {
            throw IllegalArgumentException("unsupported M3-028 TLS version")
        }
        if (iterations <= 0 || bytes < 0) {
            throw IllegalArgumentException("invalid M3-028 benchmark dimensions")
        }
        let certificate = File.readFrom(m3028Variable("WIRESTACK_M3_028_CERT_DER"))
        let key = File.readFrom(m3028Variable("WIRESTACK_M3_028_KEY_DER"))
        let contexts = M3028Contexts(version, certificate, key)
        let requestedPort = match (getVariable("WIRESTACK_M3_028_PORT")) {
            case Some(value) => UInt16.parse(value)
            case None => 0u16
        }
        let listener = StdNetTransportListener.bind(
            m3028Loopback(if (scenario == "interop-client") { 0u16 } else { requestedPort }),
            backlog: 128
        )
        let context = OperationContext(
            deadline: Some(Deadline.after(60 * Duration.second))
        )
        try {
            let duration = match (scenario) {
                case "full" => m3028FullHandshake(
                    contexts, listener, context, iterations, false
                )
                case "resumed" => m3028FullHandshake(
                    contexts, listener, context, iterations, true
                )
                case "bulk" => m3028Bulk(contexts, listener, context, bytes)
                case "interop-client" => m3028InteropClient(
                    contexts, requestedPort, context
                )
                case "interop-server" => m3028InteropServer(
                    contexts, listener, context
                )
                case "idle" => m3028Idle(
                    contexts, listener, context, iterations
                )
                case _ => throw IllegalArgumentException("unsupported M3-028 scenario")
            }
            let resumed = if (scenario == "resumed") { "true" } else { "false" }
            println(
                "M3028_WIRESTACK scenario=${scenario}_${version} iterations=${iterations} " +
                "durationNs=${duration} bytes=${bytes} " +
                "resumed=${resumed}"
            )
        } finally {
            listener.close()
            contexts.close()
        }
    }
}
