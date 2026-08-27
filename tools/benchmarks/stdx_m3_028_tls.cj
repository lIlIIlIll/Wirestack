import std.convert.Parsable
import std.env.getVariable
import std.fs.*
import std.net.*
import std.time.*
import stdx.crypto.keys.GeneralPrivateKey
import stdx.crypto.x509.X509Certificate
import stdx.net.tls.*
import stdx.net.tls.common.*

func variable(name: String): String {
    getVariable(name) ?? throw IllegalStateException("missing ${name}")
}

struct Configs {
    let server: TlsServerConfig
    let client: TlsClientConfig

    init(version: String, certPath: String, keyPath: String) {
        let certificate = X509Certificate.decodeFromPem(
            String.fromUtf8(File.readFrom(certPath))
        )
        let key = GeneralPrivateKey.decodeFromPem(
            String.fromUtf8(File.readFrom(keyPath))
        )
        let selected = if (version == "tls12") { TlsVersion.V1_2 } else { TlsVersion.V1_3 }
        var serverConfig = TlsServerConfig(certificate, key)
        serverConfig.supportedVersions = [selected]
        var clientConfig = TlsClientConfig()
        clientConfig.verifyMode = CertificateVerifyMode.TrustAll
        clientConfig.serverName = Some("example.com")
        clientConfig.supportedVersions = [selected]
        server = serverConfig
        client = clientConfig
    }
}

func tcpPair(server: TcpServerSocket, port: UInt16): (TcpSocket, TcpSocket) {
    let accepting = spawn { server.accept() }
    let client = TcpSocket("127.0.0.1", port)
    client.connect()
    (client, accepting.get())
}

func handshakePair(
    rawClient: TcpSocket,
    rawServer: TcpSocket,
    configs: Configs,
    serverSession: TlsServerSession,
    clientSession: ?TlsClientSession
): (TlsSocket, TlsSocket, ?TlsClientSession, Int64) {
    let client = TlsSocket.client(
        rawClient, clientConfig: configs.client, session: clientSession
    )
    let server = TlsSocket.server(
        rawServer, serverConfig: configs.server, session: serverSession
    )
    let accepting = spawn { server.handshake() }
    let started = MonoTime.now()
    let result = client.handshake()
    let _ = accepting.get()
    let elapsed = (MonoTime.now() - started).toNanoseconds()
    let session = result.session as TlsClientSession
    (client, server, session, elapsed)
}

func closePair(client: TlsSocket, server: TlsSocket): Unit {
    client.close()
    server.close()
}

func processSession(client: TlsSocket, server: TlsSocket): TlsClientSession {
    server.write([0x5a])
    let input = Array<Byte>(1, repeat: 0)
    if (client.read(input) != 1) {
        throw IllegalStateException("stdx session probe byte was not delivered")
    }
    let result = client.handshakeResult.getOrThrow()
    (result.session as TlsClientSession).getOrThrow()
}

func handshakeProfile(
    listener: TcpServerSocket,
    port: UInt16,
    configs: Configs,
    iterations: Int64,
    resumed: Bool
): (Int64, Bool) {
    let serverSession = TlsServerSession.fromName("wirestack-m3-028")
    var previous = None<TlsClientSession>
    if (resumed) {
        let (rawClient, rawServer) = tcpPair(listener, port)
        let (client, server, _, _) = handshakePair(
            rawClient, rawServer, configs, serverSession, previous
        )
        previous = Some(processSession(client, server))
        closePair(client, server)
    }
    var duration: Int64 = 0
    var proved = resumed
    for (_ in 0..iterations) {
        let supplied = previous
        let (rawClient, rawServer) = tcpPair(listener, port)
        let (client, server, _, elapsed) = handshakePair(
            rawClient, rawServer, configs, serverSession, supplied
        )
        try {
            if (resumed) {
                let session = processSession(client, server)
                proved = proved && supplied.isSome() && supplied.getOrThrow() == session
                previous = Some(session)
            }
            duration += elapsed
        } finally {
            closePair(client, server)
        }
    }
    (duration, proved)
}

func bulkProfile(
    listener: TcpServerSocket,
    port: UInt16,
    configs: Configs,
    bytes: Int64
): Int64 {
    let (rawClient, rawServer) = tcpPair(listener, port)
    let (client, server, _, _) = handshakePair(
        rawClient, rawServer, configs,
        TlsServerSession.fromName("wirestack-m3-028-bulk"), None<TlsClientSession>
    )
    let reading: Future<Int64> = spawn {
        let input = Array<Byte>(16 * 1024, repeat: 0)
        var received: Int64 = 0
        while (received < bytes) {
            let count = server.read(input)
            if (count <= 0) { throw IllegalStateException("early stdx TLS EOF") }
            received += count
        }
        received
    }
    let output = Array<Byte>(16 * 1024, repeat: 0x5a)
    var sent: Int64 = 0
    let started = MonoTime.now()
    try {
        while (sent < bytes) {
            let count = min(output.size, bytes - sent)
            if (count == output.size) {
                client.write(output)
            } else {
                client.write(output[0..count].clone())
            }
            sent += count
        }
        if (reading.get() != bytes) { throw IllegalStateException("stdx byte mismatch") }
        (MonoTime.now() - started).toNanoseconds()
    } finally {
        closePair(client, server)
    }
}

main(): Int64 {
    let scenario = variable("WIRESTACK_M3_028_SCENARIO")
    let version = variable("WIRESTACK_M3_028_VERSION")
    let iterations = Int64.parse(variable("WIRESTACK_M3_028_ITERATIONS"))
    let bytes = Int64.parse(variable("WIRESTACK_M3_028_BYTES"))
    let configs = Configs(
        version,
        variable("WIRESTACK_M3_028_CERT_PEM"),
        variable("WIRESTACK_M3_028_KEY_PEM")
    )
    let listener = TcpServerSocket(bindAt: 0)
    listener.bind()
    let port = (listener.localAddress as IPSocketAddress)?.port ??
        throw IllegalStateException("stdx listener has no IP port")
    try {
        var duration: Int64 = 0
        var resumed = false
        match (scenario) {
            case "full" =>
                let (value, _) = handshakeProfile(
                    listener, port, configs, iterations, false
                )
                duration = value
            case "resumed" =>
                let result = handshakeProfile(listener, port, configs, iterations, true)
                duration = result[0]
                resumed = result[1]
            case "bulk" => duration = bulkProfile(listener, port, configs, bytes)
            case _ => throw IllegalArgumentException("unsupported stdx TLS scenario")
        }
        println(
            "M3028_STDX scenario=${scenario}_${version} iterations=${iterations} " +
            "durationNs=${duration} bytes=${bytes} resumed=${resumed}"
        )
    } finally {
        listener.close()
    }
    0
}
