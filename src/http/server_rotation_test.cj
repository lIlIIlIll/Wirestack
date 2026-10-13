package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.net as net
import wirestack.tls as tlsapi

private func rotationLoopback(): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)
}

private func rotationContext(): OperationContext {
    OperationContext(deadline: Some(Deadline.after(5 * Duration.second)))
}

private func rotationMaterial(strict!: Bool = false, required!: Bool = false): HttpServerTlsConfig {
    HttpServerTlsConfig([publicTlsTestCertificateDer()], publicTlsTestPrivateKeyDer(),
        securityProfile: if (strict) { HttpServerTlsSecurityProfile.StrictTls13 } else { HttpServerTlsSecurityProfile.Modern },
        clientAuthentication: if (required) { HttpServerClientAuthentication.Required } else { HttpServerClientAuthentication.None },
        clientTrustRootsDer: if (required) { [publicTlsTestCertificateDer()] } else { [] })
}

private func rotationRawContext(version: tlsapi.TlsVersion): tlsapi.TlsClientContext {
    tlsapi.TlsClientContext.builder().versions(version, version).alpn(["http/1.1"])
        .trust(tlsapi.TrustPolicy.customRoots(tlsapi.CertificateChain([tlsapi.DerCertificate(publicTlsTestCertificateDer())])))
        .build()
}

private func rotationRaw(server: HttpServer, version: tlsapi.TlsVersion): tlsapi.TlsConnection {
    rotationRawContext(version).handshake(net.TcpStream.connect(server.localEndpoint, context: rotationContext()),
        HostName("example.com"), context: rotationContext())
}

private func rotationClient(server: HttpServer): HttpClient {
    let config = HttpClientTlsConfig([publicTlsTestCertificateDer()])
    try {
        HttpClient.builder().tls(config).resolver(StaticResolver(ResolveResult(
            [server.localEndpoint.address], HostName("example.com"), ResolverSource.Static)))
            .requestTimeout(5 * Duration.second).build()
    } finally { config.close() }
}

private func rotationUrl(server: HttpServer, target: String): String {
    "https://example.com:${server.localEndpoint.port}${target}"
}

private func rotationWrite(value: api.DuplexTransport, target: String): Unit {
    let bytes = "GET ${target} HTTP/1.1\r\nHost: example.com\r\n\r\n".toArray()
    var offset: Int64 = 0
    let context = rotationContext()
    while (offset < bytes.size) {
        offset += value.writeSome(api.ByteSpan(bytes, offset: offset, length: bytes.size - offset), context: context)
    }
}

private func rotationReadHead(value: api.DuplexTransport): String {
    let output = ArrayList<Byte>()
    let one = Array<Byte>(1, repeat: 0u8)
    let context = rotationContext()
    while (output.size < 8192) {
        match (value.readSome(api.MutableByteSpan(one), context: context)) {
            case api.ReadResult.Data(count) =>
                if (count != 1) { throw Exception("invalid rotation test read progress") }
                output.add(one[0])
                let size = output.size
                if (size >= 4 && output[size - 4] == 13u8 && output[size - 3] == 10u8 &&
                    output[size - 2] == 13u8 && output[size - 1] == 10u8) {
                    return String.fromUtf8(output.toArray())
                }
            case api.ReadResult.EndOfStream => throw Exception("rotation response ended before headers")
        }
    }
    throw Exception("rotation response header bound exceeded")
}

private func rotationWaitConnections(server: HttpServer, count: Int64): Unit {
    let deadline = Deadline.after(5 * Duration.second)
    while (server.resourceSnapshot().activeConnections != count) {
        if (deadline.isExpired()) { throw Exception("server connection ledger did not reach expected count") }
        sleep(Duration.millisecond)
    }
}

private func rotationShutdown(server: HttpServer, serving: Future<Unit>): Unit {
    let result = server.shutdown(context: rotationContext())
    @Expect(result.activeAtReturn, 0)
    serving.get(5 * Duration.second)
    @Expect(server.resourceSnapshot().activeConnections, 0)
    @Expect(server.resourceSnapshot().activeRequests, 0)
    @Expect(server.resourceSnapshot().activeStreams, 0)
}

/** The public handler boundary fixes the exchange admission point without sleeps. */
private class RotationGateHandler <: HttpServerHandler {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    private var cancelled = false

    func waitEntered(): Unit {
        let deadline = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (!entered) {
                if (deadline.isExpired()) { throw Exception("rotation handler was not admitted") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }

    func waitCancelled(): Unit {
        let deadline = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (!cancelled) {
                if (deadline.isExpired()) { throw Exception("obsolete handler was not cancelled") }
                changed.wait(timeout: deadline.remaining())
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
    func wasCancelled(): Bool { synchronized(mutex) { cancelled } }

    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        if (request.target == "/hold") {
            let registration = context.cancellation.register { =>
                synchronized(mutex) { cancelled = true; changed.notifyAll() }
            }
            try {
                synchronized(mutex) {
                    entered = true
                    changed.notifyAll()
                    while (!released && !context.isCancellationRequested()) {
                        if (context.isDeadlineExceeded()) { throw Exception("rotation handler deadline expired") }
                        changed.wait(timeout: Duration.second)
                    }
                    cancelled = context.isCancellationRequested()
                    changed.notifyAll()
                }
            } finally { registration.unregister() }
        }
        HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
    }
}

@Test
class HttpServerRotationTest {
    @TestCase
    func invalidAndClosedUpdatesRollbackWhileUnreferencedUpdatesStayBounded(): Unit {
        let material = rotationMaterial()
        let invalid = HttpServerTlsConfig([[1u8]], [2u8])
        let closed = rotationMaterial()
        closed.close()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationGateHandler()).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let client = rotationClient(server)
        try {
            @Expect(server.tlsGeneration(), 1u64)
            @AssertThrows[Exception](server.rotateTls(invalid))
            @AssertThrows[IllegalStateException](server.rotateTls(closed))
            @Expect(server.tlsGeneration(), 1u64)
            let response = client.get(rotationUrl(server, "/ready"))
            try { @Expect(response.status, 204) } finally { response.close() }
            client.close()
            rotationWaitConnections(server, 0)
            for (index in 0..80) {
                // Evaluate the mutation once, independently of assertion diagnostics.
                let published = server.rotateTls(material)
                @Expect(published, UInt64(index + 2))
            }
            @Expect(server.tlsGeneration(), 81u64)
            rotationShutdown(server, serving)
            @AssertThrows[IllegalStateException](server.rotateTls(material))
        } finally {
            client.close(); server.close(); material.close(); invalid.close()
        }
        let cleartext = HttpServer.builder().listen(rotationLoopback()).handler(RotationGateHandler()).build()
        let candidate = rotationMaterial()
        try {
            @Expect(cleartext.tlsGeneration(), 0u64)
            @AssertThrows[IllegalStateException](cleartext.rotateTls(candidate))
        } finally { cleartext.close(); candidate.close() }
    }

    @TestCase
    func gracefulHttp1FinishesAdmittedResponseAndRejectsOldKeepalive(): Unit {
        let material = rotationMaterial()
        let replacement = rotationMaterial(strict: true)
        let handler = RotationGateHandler()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(handler).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let old = rotationRaw(server, tlsapi.TlsVersion.Tls12)
        try {
            rotationWrite(old, "/hold")
            handler.waitEntered()
            @Expect(server.rotateTls(replacement), 2u64)
            material.close()
            handler.release()
            @Expect(rotationReadHead(old).startsWith("HTTP/1.1 204"))
            let ended = try {
                match (old.readSome(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)), context: rotationContext())) {
                    case api.ReadResult.EndOfStream => true
                    case _ => false
                }
            } catch (_: api.NetworkException) { true }
            @Expect(ended)
            @Expect(!handler.wasCancelled())
            @AssertThrows[Exception](rotationRaw(server, tlsapi.TlsVersion.Tls12))
            let fresh = rotationRaw(server, tlsapi.TlsVersion.Tls13)
            try {
                rotationWrite(fresh, "/ready")
                @Expect(rotationReadHead(fresh).startsWith("HTTP/1.1 204"))
            } finally { fresh.abort() }
            old.abort()
            rotationShutdown(server, serving)
        } finally {
            handler.release(); old.abort(); server.close(); material.close(); replacement.close()
        }
    }

    @TestCase
    func securityHttp1CancelsActiveExchangeAndGracefulRotationClosesIdleKeepalive(): Unit {
        let material = rotationMaterial()
        let handler = RotationGateHandler()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(handler).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let old = rotationRaw(server, tlsapi.TlsVersion.Tls13)
        try {
            rotationWrite(old, "/hold")
            handler.waitEntered()
            @Expect(server.rotateTls(material, policy: HttpConfigurationRotation.SecurityReplacement), 2u64)
            handler.waitCancelled()
            let ended = try { rotationReadHead(old); false } catch (_: Exception) { true }
            @Expect(ended)
            old.abort()
            rotationWaitConnections(server, 0)
            let idle = rotationRaw(server, tlsapi.TlsVersion.Tls13)
            try {
                rotationWrite(idle, "/ready")
                @Expect(rotationReadHead(idle).startsWith("HTTP/1.1 204"))
                @Expect(server.rotateTls(material), 3u64)
                rotationWaitConnections(server, 0)
            } finally { idle.abort() }
            rotationShutdown(server, serving)
        } finally { handler.release(); old.abort(); server.close(); material.close() }
    }

    @TestCase
    func gracefulHttp2DrainsOldStreamsAndNewHandshakesUseReplacementAuthentication(): Unit {
        let material = rotationMaterial()
        let replacement = rotationMaterial(required: true)
        let handler = RotationGateHandler()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(handler).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let old = rotationClient(server)
        let request: Future<HttpResponse> = spawn { old.get(rotationUrl(server, "/hold")) }
        var fresh: ?HttpClient = None<HttpClient>
        try {
            handler.waitEntered()
            @Expect(server.rotateTls(replacement), 2u64)
            material.close()
            let noIdentity = rotationClient(server)
            try { @AssertThrows[Exception](noIdentity.get(rotationUrl(server, "/ready"))) }
            finally { noIdentity.close() }
            handler.release()
            let response = request.get(5 * Duration.second)
            try { @Expect(response.version, HttpVersion.Http2); @Expect(response.status, 204) }
            finally { response.close() }
            @AssertThrows[Exception](old.get(rotationUrl(server, "/ready")))
            @Expect(!handler.wasCancelled())
            let restored = rotationMaterial()
            try { @Expect(server.rotateTls(restored), 3u64) } finally { restored.close() }
            let current = rotationClient(server)
            fresh = Some(current)
            let ready = current.get(rotationUrl(server, "/ready"))
            try { @Expect(ready.version, HttpVersion.Http2); @Expect(ready.status, 204) }
            finally { ready.close() }
            old.close(); current.close()
            rotationShutdown(server, serving)
        } finally {
            handler.release(); old.close()
            if (let Some(value) <- fresh) { value.close() }
            server.close(); material.close(); replacement.close()
        }
    }

    @TestCase
    func securityHttp2CancelsAdmittedStreamWithoutClosingListener(): Unit {
        let material = rotationMaterial()
        let replacement = rotationMaterial(strict: true)
        let handler = RotationGateHandler()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(handler).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let client = rotationClient(server)
        let request: Future<Bool> = spawn {
            try { let response = client.get(rotationUrl(server, "/hold")); response.close(); false }
            catch (_: Exception) { true }
        }
        try {
            handler.waitEntered()
            @Expect(server.rotateTls(replacement, policy: HttpConfigurationRotation.SecurityReplacement), 2u64)
            @Expect(request.get(5 * Duration.second))
            handler.waitCancelled()
            @Expect(handler.wasCancelled())
            let fresh = rotationClient(server)
            try {
                let response = fresh.get(rotationUrl(server, "/ready"))
                try { @Expect(response.status, 204); @Expect(response.version, HttpVersion.Http2) }
                finally { response.close() }
            } finally { fresh.close() }
            client.close()
            rotationShutdown(server, serving)
        } finally {
            handler.release(); client.close(); server.close(); material.close(); replacement.close()
        }
    }

    @TestCase
    func pendingHandshakeKeepsSnapshotAndSecurityReplacementAbortsPendingSocket(): Unit {
        let material = rotationMaterial()
        let replacement = rotationMaterial(strict: true)
        let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationGateHandler()).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let pending = net.TcpStream.connect(server.localEndpoint, context: rotationContext())
        try {
            rotationWaitConnections(server, 1)
            @Expect(server.rotateTls(replacement), 2u64)
            material.close()
            let old = rotationRawContext(tlsapi.TlsVersion.Tls12).handshake(pending, HostName("example.com"), context: rotationContext())
            @Expect(match (old.handshakeInfo.version) {
                case tlsapi.TlsVersion.Tls12 => true
                case _ => false
            })
            old.abort()
            rotationWaitConnections(server, 0)
            let stalled = net.TcpStream.connect(server.localEndpoint, context: rotationContext())
            try {
                rotationWaitConnections(server, 1)
                @Expect(server.rotateTls(replacement, policy: HttpConfigurationRotation.SecurityReplacement), 3u64)
                let ended = try {
                    match (stalled.readSome(api.MutableByteSpan(Array<Byte>(1, repeat: 0u8)), context: rotationContext())) {
                        case api.ReadResult.EndOfStream => true
                        case _ => false
                    }
                } catch (_: api.NetworkException) { true }
                @Expect(ended)
            } finally { stalled.abort() }
            let fresh = rotationRaw(server, tlsapi.TlsVersion.Tls13)
            fresh.abort()
            rotationShutdown(server, serving)
        } finally { pending.abort(); server.close(); material.close(); replacement.close() }
    }

    @TestCase
    func retainedHandshakeGenerationCapRejectsAtomicallyAndCloseReleasesAll(): Unit {
        let material = rotationMaterial()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationGateHandler()).tls(material).build()
        let serving: Future<Unit> = spawn { server.serve() }
        let pending = ArrayList<net.TcpStream>()
        try {
            for (index in 0..64) {
                pending.add(net.TcpStream.connect(server.localEndpoint, context: rotationContext()))
                rotationWaitConnections(server, index + 1)
                if (index < 63) { @Expect(server.rotateTls(material), UInt64(index + 2)) }
            }
            @Expect(server.tlsGeneration(), 64u64)
            @AssertThrows[IllegalStateException](server.rotateTls(material))
            @Expect(server.tlsGeneration(), 64u64)
            server.close()
            for (socket in pending) { socket.abort() }
            rotationWaitConnections(server, 0)
            serving.get(5 * Duration.second)
        } finally {
            for (socket in pending) { socket.abort() }
            server.close(); material.close()
        }
    }

    @TestCase
    func closeAndSecurityRotationRaceLeavesListenerClosedAndNoOwners(): Unit {
        let material = rotationMaterial()
        try {
            for (_ in 0..8) {
                let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationGateHandler()).tls(material).build()
                let serving: Future<Unit> = spawn { try { server.serve() } catch (_: IllegalStateException) {} }
                let pending = net.TcpStream.connect(server.localEndpoint, context: rotationContext())
                rotationWaitConnections(server, 1)
                let barrier = SyncCounter(2)
                let update = spawn {
                    barrier.dec(); barrier.waitUntilZero()
                    try { server.rotateTls(material, policy: HttpConfigurationRotation.SecurityReplacement) }
                    catch (_: IllegalStateException) { 0u64 }
                }
                let closing = spawn { barrier.dec(); barrier.waitUntilZero(); server.close() }
                try {
                    let result = update.get(5 * Duration.second)
                    @Expect(result == 0u64 || result == 2u64)
                    closing.get(5 * Duration.second)
                    @Expect(server.isClosed())
                    @AssertThrows[IllegalStateException](server.rotateTls(material))
                    pending.abort()
                    rotationWaitConnections(server, 0)
                    serving.get(5 * Duration.second)
                } finally { pending.abort(); server.close() }
            }
        } finally { material.close() }
    }
}
