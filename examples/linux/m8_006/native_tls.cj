package wirestack_m8_006_native_tls

import std.collection.HashSet
import std.env.getStdOut
import std.fs.*
import std.process.execute
import std.sync.*
import wirestack as api
import wirestack.net.{TcpListener, TcpStream}
import wirestack.tls as tls

func require(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func announce(value: String): Unit { println(value); getStdOut().flush() }
func loopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}

class NativeAcceptor <: api.TransportListener {
    let listener = TcpListener.bind(loopback(0))
    private let mutex = Mutex()
    private var accepted = None<TcpStream>
    public func accept(context: api.OperationContext): api.DuplexTransport {
        let stream = listener.accept(context: context)
        synchronized(mutex) { accepted = Some(stream) }
        stream
    }
    func acceptedClosed(): Bool {
        synchronized(mutex) {
            match (accepted) { case Some(value) => value.isClosed(); case None => false }
        }
    }
    public func close(): Unit { listener.close() }
    public func isClosed(): Bool { listener.isClosed() }
}

class HookScope {
    let cancellation = api.CancellationSource()
    let deadline = api.Deadline.after(5 * Duration.second)
    let context: api.OperationContext
    let action: String
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    init(action: String) {
        this.action = action
        context = api.OperationContext(deadline: Some(deadline), cancellation: cancellation.token,
            trace: Some(api.NetworkTraceContext("m8-006", spanId: action)))
    }
    func check(actual: api.OperationContext): Unit {
        match (actual.deadline) {
            case Some(value) => require(value.expiresAt == deadline.expiresAt, "hook deadline changed")
            case None => throw IllegalStateException("hook deadline missing")
        }
        match (actual.trace) {
            case Some(value) => require(value.traceId == "m8-006" && value.spanId == action,
                "hook trace changed")
            case None => throw IllegalStateException("hook trace missing")
        }
        require(!actual.cancellation.isCancellationRequested, "hook entered after cancellation")
    }
    func after(actual: api.OperationContext): Unit {
        if (action == "hold") {
            entered.store(true)
            while (!released.load()) {
                require(!deadline.isExpired(), "held callback exceeded its original deadline")
                sleep(Duration.millisecond)
            }
        }
        if (action == "cancel") {
            cancellation.cancel()
            require(actual.cancellation.isCancellationRequested, "hook cancellation token changed")
        } else if (action == "deadline") {
            while (!deadline.isExpired()) { sleep(Duration.millisecond) }
        } else if (action == "throw") {
            throw IllegalStateException("deliberate external hook failure")
        }
    }
}

class ExternalRsaKey <: tls.ExternalSigner & tls.ExternalDecryptor {
    let keyPath: String
    let scope: HookScope
    let signatures = AtomicInt64(0)
    let decryptions = AtomicInt64(0)
    init(keyPath: String, scope: HookScope) { this.keyPath = keyPath; this.scope = scope }
    public func supportedAlgorithms(): Array<tls.TlsSignatureAlgorithm> {
        [tls.TlsSignatureAlgorithm.RsaPssRsaeSha256]
    }
    func operation(input: Array<Byte>, decrypt: Bool): Array<Byte> {
        let inputFile = File.createTemp("/tmp")
        let outputFile = File.createTemp("/tmp")
        let inputPath = inputFile.info.path.toString()
        let outputPath = outputFile.info.path.toString()
        inputFile.close()
        outputFile.close()
        try {
            File.writeTo(inputPath, input)
            let arguments = if (decrypt) {
                ["pkeyutl", "-decrypt", "-inkey", keyPath, "-keyform", "DER",
                    "-pkeyopt", "rsa_padding_mode:none", "-in", inputPath, "-out", outputPath]
            } else {
                ["dgst", "-sha256", "-sign", keyPath, "-keyform", "DER",
                    "-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:digest",
                    "-out", outputPath, inputPath]
            }
            require(execute("/usr/bin/openssl", arguments) == 0, "external RSA operation failed")
            File.readFrom(outputPath)
        } finally {
            remove(inputPath)
            remove(outputPath)
        }
    }
    public func sign(request: tls.ExternalSignatureRequest, context: api.OperationContext): Array<Byte> {
        scope.check(context)
        let _ = signatures.fetchAdd(1)
        let result = operation(request.messageBytes(), false)
        scope.after(context)
        result
    }
    public func decrypt(request: tls.ExternalDecryptionRequest, context: api.OperationContext): Array<Byte> {
        scope.check(context)
        require(request.algorithm == "RSA_RAW", "provider requested unknown decryption")
        let input = request.ciphertextBytes()
        let _ = decryptions.fetchAdd(1)
        let result = operation(input, true)
        require(result.size == input.size, "external RSA output length changed")
        try {
            scope.after(context)
            if (scope.action == "short") {
                for (index in 0..result.size) { result[index] = 0 }
                return [0u8]
            }
            result
        } catch (error: Exception) {
            for (index in 0..result.size) { result[index] = 0 }
            throw error
        }
    }
}

class SecretSink <: tls.KeyLogSink {
    let scope: HookScope
    private let mutex = Mutex()
    private let labels = HashSet<String>()
    let calls = AtomicInt64(0)
    init(scope: HookScope) { this.scope = scope }
    public func emit(line: tls.TlsKeyLogLine, context: api.OperationContext): Unit {
        scope.check(context)
        let random = line.clientRandomBytes()
        let secret = line.secretBytes()
        try {
            require(random.size == 32 && secret.size >= 1 && secret.size <= 64,
                "key-log record fields exceeded bounds")
            synchronized(mutex) { labels.add(line.label) }
            let _ = calls.fetchAdd(1)
            scope.after(context)
        } finally {
            for (index in 0..secret.size) { secret[index] = 0 }
        }
    }
    func saw(label: String): Bool { synchronized(mutex) { labels.contains(label) } }
}

func certificate(path: String): tls.CertificateChain {
    tls.CertificateChain([tls.DerCertificate(File.readFrom(path))])
}
func clientContext(chain: tls.CertificateChain, version: tls.TlsVersion): tls.TlsClientContext {
    tls.TlsClientContext.builder().trust(tls.TrustPolicy.customRoots(chain))
        .versions(version, version).alpn(["old", "new"]).build()
}
func readByte(connection: tls.TlsConnection, context: api.OperationContext): Byte {
    let output = Array<Byte>(1, repeat: 0)
    match (connection.readSome(api.MutableByteSpan(output), context: context)) {
        case api.ReadResult.Data(count) => require(count == 1, "TLS application byte missing")
        case api.ReadResult.EndOfStream => throw IllegalStateException("TLS peer ended early")
    }
    output[0]
}
func writeByte(connection: tls.TlsConnection, value: Byte, context: api.OperationContext): Unit {
    require(connection.writeSome(api.ByteSpan([value]), context: context) == 1,
        "TLS application byte not accepted")
}
func expectedHookFailure(error: api.NetworkException, action: String): Bool {
    match (error) {
        case failure: tls.TlsEngineException => match (failure.tlsCode) {
            case tls.TlsEngineErrorCode.HandshakeCancelled => action == "cancel"
            case tls.TlsEngineErrorCode.HandshakeTimeout => action == "deadline"
            case tls.TlsEngineErrorCode.PrivateKeyFailure => action == "throw" || action == "short"
            case tls.TlsEngineErrorCode.ProviderFailure => action == "throw"
            case _ => false
        }
        case _ => false
    }
}

func runLoopbackHook(mode: String, chain: tls.CertificateChain, keyPath: String, spkiPath: String): Unit {
    let parts = mode.split("-")
    let kind = parts[0]
    let action = parts[1]
    let scope = HookScope(action)
    let external = ExternalRsaKey(keyPath, scope)
    let sink = SecretSink(scope)
    let key = if (kind == "sign") {
        tls.PrivateKeyRef.externalSigner("native-external-rsa", File.readFrom(spkiPath), external)
    } else { tls.PrivateKeyRef.pkcs8(File.readFrom(keyPath)) }
    let builder = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
        .alpn(["old"])
    if (kind == "keylog12") { builder.versions(tls.TlsVersion.Tls12, tls.TlsVersion.Tls12) }
    else { builder.versions(tls.TlsVersion.Tls13, tls.TlsVersion.Tls13) }
    if (kind != "sign") { builder.withKeyLogSink(sink) }
    let serverContext = builder.build()
    let payloadDelivered = AtomicBool(false)
    key.close()
    let version = if (kind == "keylog12") { tls.TlsVersion.Tls12 } else { tls.TlsVersion.Tls13 }
    let client = clientContext(chain, version)
    let acceptor = NativeAcceptor()
    let listener = tls.TlsListener(acceptor, serverContext)
    let server: Future<Bool> = spawn {
        try {
            let connection = listener.accept(context: scope.context)
            try {
                require(action == "ok", "failing hook unexpectedly completed a handshake")
                require(readByte(connection, scope.context) == b'q', "server received wrong byte")
                writeByte(connection, b'a', scope.context)
                while (!payloadDelivered.load()) {
                    require(!scope.deadline.isExpired(), "client did not receive TLS payload")
                    sleep(Duration.millisecond)
                }
                true
            } finally { connection.abort() }
        } catch (error: api.NetworkException) {
            require(action != "ok" && expectedHookFailure(error, action),
                "hook lost its structured cancellation/deadline/error class")
            require(acceptor.acceptedClosed(), "failed TLS handshake retained its TCP stream")
            true
        }
    }
    let transport = TcpStream.connect(acceptor.listener.localEndpoint,
        context: api.OperationContext(deadline: Some(api.Deadline.after(10 * Duration.second))))
    var clientFailed = false
    try {
        try {
            let connection = client.handshake(transport, tls.HostName("example.com"),
                context: api.OperationContext(deadline: Some(api.Deadline.after(10 * Duration.second))))
            try {
                writeByte(connection, b'q', api.OperationContext.background())
                require(readByte(connection, api.OperationContext(
                    deadline: Some(api.Deadline.after(10 * Duration.second)))) == b'a', "client received wrong byte")
                payloadDelivered.store(true)
            } finally { connection.abort() }
        } catch (_: api.NetworkException) { clientFailed = true }
        require(server.get(12 * Duration.second), "server hook scenario failed")
        require(clientFailed == (action != "ok"), "peer did not observe expected hook outcome")
        if (kind == "sign") { require(external.signatures.load() == 1, "native signer not invoked once") }
        else {
            require(sink.calls.load() > 0, "native key-log sink was not invoked")
            if (action == "ok") {
                if (kind == "keylog12") { require(sink.saw("CLIENT_RANDOM"), "TLS 1.2 NSS secret missing") }
                else {
                    require(sink.saw("CLIENT_HANDSHAKE_TRAFFIC_SECRET") &&
                        sink.saw("SERVER_HANDSHAKE_TRAFFIC_SECRET") &&
                        sink.saw("CLIENT_TRAFFIC_SECRET_0") && sink.saw("SERVER_TRAFFIC_SECRET_0"),
                        "TLS 1.3 NSS traffic secrets missing")
                }
            }
        }
        announce("NATIVE_TLS_" + mode + "=PASS")
    } finally {
        transport.abort()
        listener.close()
    }
}

func runVersionReplacement(
    chain: tls.CertificateChain, keyPath: String, spkiPath: String, version: tls.TlsVersion
): Unit {
    let scope = HookScope("hold")
    let external = ExternalRsaKey(keyPath, scope)
    let externalKey = tls.PrivateKeyRef.externalSigner("held-context-key", File.readFrom(spkiPath), external)
    let key = tls.PrivateKeyRef.pkcs8(File.readFrom(keyPath))
    let oldServer = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, externalKey))
        .versions(version, version).alpn(["old"]).build()
    let newServer = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
        .versions(version, version).alpn(["new"]).build()
    let intermediateServer = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
        .versions(version, version).alpn(["intermediate"]).build()
    let oldClient = clientContext(chain, version)
    let newClient = clientContext(chain, version)
    let intermediateClient = clientContext(chain, version)
    key.close()
    externalKey.close()
    require(oldServer.contextVersion != 0u64 && oldClient.contextVersion != 0u64 &&
        oldServer.contextVersion != newServer.contextVersion &&
        oldClient.contextVersion != newClient.contextVersion, "context version reused or zero")
    let serverStore = tls.TlsServerContextStore(oldServer)
    let clientStore = tls.TlsClientContextStore(oldClient)
    let acceptor = NativeAcceptor()
    let listener = tls.TlsListener(acceptor, serverStore)
    let context = scope.context
    let serverHandshake: Future<tls.TlsConnection> = spawn { listener.accept(context: context) }
    let clientHandshake: Future<tls.TlsConnection> = spawn {
        clientStore.handshake(TcpStream.connect(acceptor.listener.localEndpoint, context: context),
            tls.HostName("example.com"), context: context)
    }
    try {
        while (!scope.entered.load()) {
            require(!scope.deadline.isExpired(), "initial handshake did not reach the signer")
            sleep(Duration.millisecond)
        }
        serverStore.replace(intermediateServer)
        clientStore.replace(intermediateClient)
        scope.released.store(true)
        let activeClient = clientHandshake.get(10 * Duration.second)
        let active = serverHandshake.get(10 * Duration.second)
        require(external.signatures.load() == 1, "held native signer did not complete exactly once")
        serverStore.replace(newServer)
        clientStore.replace(newClient)
        writeByte(active, b'o', context)
        require(readByte(activeClient, context) == b'o', "replacement disrupted in-flight TLS handshake")
        require(activeClient.handshakeInfo.negotiatedAlpn == Some("old") &&
            active.handshakeInfo.negotiatedAlpn == Some("old"), "in-flight handshake changed context")
        for (round in 0..2) {
            let future: Future<tls.TlsConnection> = spawn { listener.accept(context: context) }
            try {
                let connection = clientStore.handshake(
                    TcpStream.connect(acceptor.listener.localEndpoint, context: context),
                    tls.ReferenceIdentity.Dns(tls.HostName("example.com")),
                    serverName: Some(tls.HostName("example.com")), context: context)
                try {
                    let peer = future.get(10 * Duration.second)
                    require(connection.handshakeInfo.negotiatedAlpn == Some("new") &&
                        peer.handshakeInfo.negotiatedAlpn == Some("new"), "future handshake retained old context")
                    require(connection.handshakeInfo.resumed == (round == 1) &&
                        peer.handshakeInfo.resumed == (round == 1), "versioned native resumption changed")
                    writeByte(peer, UInt8(round + 1), context)
                    require(readByte(connection, context) == UInt8(round + 1), "resumed connection payload changed")
                } finally { connection.abort() }
            } finally {
                try { future.get(10 * Duration.second).abort() } catch (_: Exception) {}
            }
        }
        listener.close()
        writeByte(active, b'l', context)
        require(readByte(activeClient, context) == b'l', "listener close terminated a returned connection")
        announce("NATIVE_TLS_VERSIONS=PASS")
    } finally {
        scope.released.store(true)
        listener.close()
        try { clientHandshake.get(10 * Duration.second).abort() } catch (_: Exception) {}
        try { serverHandshake.get(10 * Duration.second).abort() } catch (_: Exception) {}
    }
}

func runDecryptServer(action: String, chain: tls.CertificateChain, keyPath: String, spkiPath: String): Unit {
    let scope = HookScope(action)
    let external = ExternalRsaKey(keyPath, scope)
    let key = tls.PrivateKeyRef.externalSigner("external-rsa-decrypt", File.readFrom(spkiPath), external)
    let context = tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
        .versions(tls.TlsVersion.Tls12, tls.TlsVersion.Tls12)
        .withExternalDecryptor(external).build()
    key.close()
    let acceptor = NativeAcceptor()
    let listener = tls.TlsListener(acceptor, context)
    announce("LISTEN_PORT=" + acceptor.listener.localEndpoint.port.toString())
    try {
        var failed = false
        try {
            let connection = listener.accept(context: scope.context)
            try {
                require(action == "ok", "failing decryptor completed handshake")
                require(connection.handshakeInfo.cipherSuite == "TLS_RSA_WITH_AES_128_GCM_SHA256",
                    "external peer did not negotiate permitted TLS 1.2 static RSA")
                require(readByte(connection, scope.context) == b'q', "external peer request byte changed")
                writeByte(connection, b'a', scope.context)
                connection.close(scope.context)
            } finally { connection.abort() }
        } catch (error: api.NetworkException) {
            failed = true
            require(action != "ok" && expectedHookFailure(error, action),
                "native decryptor failure lost structured classification")
            require(acceptor.acceptedClosed(), "failed decryptor retained TCP stream")
        }
        require(failed == (action != "ok"), "external decryptor outcome changed")
        require(external.decryptions.load() == 1 && external.signatures.load() == 0,
            "native private-key operation kind was not decryption")
        announce("NATIVE_TLS_decrypt-" + action + "=PASS")
    } finally { listener.close() }
}

main(arguments: Array<String>): Int64 {
    require(arguments.size == 4, "expected mode, certificate DER, key DER and SPKI DER")
    let mode = arguments[0]
    let chain = certificate(arguments[1])
    if (mode == "versions12" || mode == "versions13") {
        runVersionReplacement(chain, arguments[2], arguments[3],
            if (mode == "versions12") { tls.TlsVersion.Tls12 } else { tls.TlsVersion.Tls13 })
    } else if (mode == "release-keylog-rejected") {
        var rejected = false
        try { tls.TlsClientContext.builder().withKeyLogSink(SecretSink(HookScope("ok"))).build() }
        catch (error: tls.TlsContextException) {
            match (error.capability) {
                case Some(value) => match (value) {
                    case tls.TlsCapability.KeyLog => rejected = true
                    case _ => ()
                }
                case None => ()
            }
        }
        require(rejected, "release context admitted secret logging")
        announce("NATIVE_TLS_RELEASE_KEYLOG_REJECTED=PASS")
    } else if (mode == "reject-non-rsa") {
        let external = ExternalRsaKey(arguments[2], HookScope("ok"))
        let key = tls.PrivateKeyRef.externalSigner("non-rsa", File.readFrom(arguments[3]), external)
        var rejected = false
        try {
            tls.TlsServerContext.builder().identity(tls.LocalIdentity(chain, key))
                .withExternalDecryptor(external).build()
        } catch (error: tls.TlsContextException) {
            match (error.capability) {
                case Some(value) => match (value) {
                    case tls.TlsCapability.ExternalDecryptor => rejected = true
                    case _ => ()
                }
                case None => ()
            }
        } finally { key.close() }
        require(rejected && external.signatures.load() == 0 && external.decryptions.load() == 0,
            "non-RSA identity reached native handshake or private-key callbacks")
        announce("NATIVE_TLS_reject-non-rsa=PASS")
    } else if (mode.startsWith("decrypt-")) {
        runDecryptServer(mode.split("-")[1], chain, arguments[2], arguments[3])
    } else { runLoopbackHook(mode, chain, arguments[2], arguments[3]) }
    0
}
