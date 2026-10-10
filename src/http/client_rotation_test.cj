package wirestack.http

import std.collection.ArrayList
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.net.TcpStream

@Test
class HttpClientRotationTest {
    @TestCase
    func nativeH1IdleRotationReleasesSingleConnectionBudgetAndPreservesCookiesHooks(): Unit {
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).build()
        let serving = spawn { server.serve() }
        let firstResolver = RotationResolver(server.localEndpoint.address)
        let client = HttpClient.builder().resolver(firstResolver).cookieJar(CookieJar())
            .connector(fixture).poolHook(fixture).resourceLimits(HttpResourceLimits(
                maximumConnections: 1, maximumConnectionsPerRoute: 1, maximumConnectionsPerOrigin: 1))
            .requestTimeout(5 * Duration.second).build()
        let base = "http://origin.test:${server.localEndpoint.port}"
        try {
            let seed = client.get("${base}/seed")
            @Expect(rotationBody(seed.body), "none"); seed.close()
            @Expect(client.resourceSnapshot().activeConnections, 1)
            for (index in 0..100) {
                let next = RotationResolver(server.localEndpoint.address)
                @Expect(client.rotateResolver(next), UInt64(index + 2))
                let response = client.get("${base}/echo")
                @Expect(response.version, HttpVersion.Http11)
                @Expect(rotationBody(response.body), "session=rotation"); response.close()
                @Expect(next.calls.load(), 1)
                @Expect(client.configurationSnapshot().retainedGenerations, 1)
                @Expect(client.configurationSnapshot().tlsGeneration, 1u64)
            }
            @Expect(firstResolver.calls.load(), 1)
            @Expect(fixture.connections.load(), 101)
            @Expect(fixture.acquisitions.load(), 101)
            @Expect(fixture.releases.load(), 101)
        } finally {
            client.close(); rotationStop(server, serving)
        }
        @Expect(client.configurationSnapshot().retainedGenerations, 0)
        @Expect(client.resourceSnapshot().activeConnections, 0)
    }

    @TestCase
    func nativeGracefulDnsLateResultFinishesOnlyOldAttempt(): Unit {
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).build()
        let serving = spawn { server.serve() }
        let gate = RotationGate()
        let old = RotationResolver(server.localEndpoint.address, gate: Some(gate))
        let next = RotationResolver(server.localEndpoint.address)
        let client = HttpClient.builder().resolver(old).connector(fixture).requestTimeout(5 * Duration.second).build()
        let url = "http://origin.test:${server.localEndpoint.port}/echo"
        let pending = spawn { client.get(url) }
        try {
            gate.waitUntilEntered()
            @Expect(client.rotateResolver(next), 2u64)
            let fresh = client.get(url)
            @Expect(rotationBody(fresh.body), "none"); fresh.close()
            @Expect(next.calls.load(), 1)
            gate.release()
            let previous = pending.get(5 * Duration.second)
            @Expect(rotationBody(previous.body), "none"); previous.close()
            @Expect(old.calls.load(), 1)
            @Expect(next.calls.load(), 1)
            @Expect(client.configurationSnapshot().retainedGenerations, 1)
        } finally {
            gate.release()
            try { pending.get(5 * Duration.second).close() } catch (_: Exception) {}
            client.close(); rotationStop(server, serving)
        }
    }

    @TestCase
    func nativeProxyDnsRotationKeepsDirectDnsAndNoProxyPolicy(): Unit {
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).build()
        let serving = spawn { server.serve() }
        let direct = RotationResolver(server.localEndpoint.address)
        let oldProxy = RotationResolver(server.localEndpoint.address)
        let nextProxy = RotationResolver(server.localEndpoint.address)
        let config = HttpProxyConfig(HttpProxyEndpoint.hostname("proxy.test", server.localEndpoint.port),
            oldProxy, noProxy: NoProxyPolicy(["direct.test"]))
        let client = HttpClient.builder().resolver(direct).proxy(config).connector(fixture)
            .requestTimeout(5 * Duration.second).build()
        try {
            let proxied = client.get("http://origin.test:8081/echo")
            @Expect(rotationBody(proxied.body), "none"); proxied.close()
            let bypassed = client.get("http://direct.test:${server.localEndpoint.port}/echo")
            @Expect(rotationBody(bypassed.body), "none"); bypassed.close()
            @Expect(client.rotateProxyResolver(nextProxy), 2u64)
            let fresh = client.get("http://origin.test:8081/echo")
            @Expect(rotationBody(fresh.body), "none"); fresh.close()
            let bypassAgain = client.get("http://direct.test:${server.localEndpoint.port}/echo")
            @Expect(rotationBody(bypassAgain.body), "none"); bypassAgain.close()
            @Expect(oldProxy.calls.load(), 1)
            @Expect(nextProxy.calls.load(), 1)
            @Expect(direct.calls.load(), 1)
            @Expect(fixture.connections.load(), 3)
            let snapshot = client.configurationSnapshot()
            @Expect(snapshot.directDnsGeneration, 1u64)
            @Expect(snapshot.proxyDnsGeneration, 2u64)
            @Expect(snapshot.tlsGeneration, 1u64)
        } finally { client.close(); rotationStop(server, serving) }
    }

    @TestCase
    func nativeH2TlsRotationDrainsOldBodyRollsBackInvalidAndRejectsRemovedTrust(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).tls(serverTls).build()
        let serving = spawn { server.serve() }
        let trusted = HttpClientTlsConfig([certificate])
        let invalid = HttpClientTlsConfig([[1u8, 2u8, 3u8]])
        let removed = HttpClientTlsConfig([rotationUntrustedCertificateDer()])
        let client = HttpClient.builder().resolver(RotationResolver(server.localEndpoint.address))
            .tls(trusted).connector(fixture).requestTimeout(5 * Duration.second).build()
        let base = "https://example.com:${server.localEndpoint.port}"
        var oldBody = None<HttpResponse>
        var strictBody = None<HttpResponse>
        try {
            let first = client.get("${base}/large")
            oldBody = Some(first)
            @Expect(first.version, HttpVersion.Http2)
            @Expect(client.rotateTls(trusted), 2u64)
            let fresh = client.get("${base}/echo")
            @Expect(fresh.version, HttpVersion.Http2)
            @Expect(rotationBody(fresh.body), "none"); fresh.close()
            @Expect(fixture.connections.load(), 2)
            @Expect(client.configurationSnapshot().retainedTlsContexts, 2)
            @Expect(rotationDrain(first.body), 256 * 1024); first.close()
            @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
            let before = client.configurationSnapshot()
            @ExpectThrows(client.rotateTls(invalid))
            @Expect(client.configurationSnapshot().tlsGeneration, before.tlsGeneration)
            let usable = client.get("${base}/echo")
            @Expect(rotationBody(usable.body), "none"); usable.close()
            @Expect(fixture.connections.load(), 2)
            let held = client.get("${base}/large")
            strictBody = Some(held)
            @Expect(client.rotateTls(trusted), 3u64)
            @Expect(client.rotateTls(removed, policy: HttpConfigurationRotation.SecurityReplacement), 4u64)
            @ExpectThrows(rotationDrain(held.body))
            @ExpectThrows(client.get("${base}/echo"))
            held.close()
            @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
            @Expect(client.resourceSnapshot().activeConnections, 0)
        } finally {
            match (oldBody) { case Some(value) => value.close(); case None => () }
            match (strictBody) { case Some(value) => value.close(); case None => () }
            client.close(); rotationStop(server, serving)
            trusted.close(); invalid.close(); removed.close(); serverTls.close()
        }
        @Expect(client.configurationSnapshot().retainedTlsContexts, 0)
    }

    @TestCase
    func nativeTlsAttemptRetainsSnapshotAndSecurityReplacementRejectsLateFactory(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let serverTls = HttpServerTlsConfig([certificate], publicTlsTestPrivateKeyDer())
        let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationFixture()).tls(serverTls).build()
        let serving = spawn { server.serve() }
        let trusted = HttpClientTlsConfig([certificate])
        let removed = HttpClientTlsConfig([rotationUntrustedCertificateDer()])
        try {
            for (strict in [false, true]) {
                let gate = RotationGate()
                let connector = RotationGatedConnector(gate)
                let client = HttpClient.builder().resolver(RotationResolver(server.localEndpoint.address))
                    .tls(trusted).connector(connector).requestTimeout(5 * Duration.second).build()
                let url = "https://example.com:${server.localEndpoint.port}/echo"
                let pending = spawn {
                    try { Some(client.get(url)) } catch (_: Exception) { None<HttpResponse> }
                }
                try {
                    gate.waitUntilEntered()
                    let policy = if (strict) { HttpConfigurationRotation.SecurityReplacement }
                        else { HttpConfigurationRotation.Graceful }
                    @Expect(client.rotateTls(removed, policy: policy), 2u64)
                    gate.release()
                    let response = pending.get(5 * Duration.second)
                    if (strict) { @Expect(response.isNone()) }
                    else {
                        let completed = response.getOrThrow()
                        @Expect(rotationBody(completed.body), "none"); completed.close()
                    }
                    @ExpectThrows(client.get(url))
                    @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
                    @Expect(client.resourceSnapshot().activeConnections, 0)
                } finally {
                    gate.release()
                    try {
                        match (pending.get(5 * Duration.second)) { case Some(value) => value.close(); case None => () }
                    } catch (_: Exception) {}
                    client.close()
                }
            }
        } finally { rotationStop(server, serving); trusted.close(); removed.close(); serverTls.close() }
    }

    @TestCase
    func nativeRetainedGenerationCeilingRejectsAtomicallyAndReclaimsAfterBodyClose(): Unit {
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).build()
        let serving = spawn { server.serve() }
        let selected = RotationResolver(server.localEndpoint.address)
        let client = HttpClient.builder().resolver(selected).resourceLimits(HttpResourceLimits(
                maximumConnections: 64, maximumConnectionsPerRoute: 64, maximumConnectionsPerOrigin: 64))
            .requestTimeout(5 * Duration.second).build()
        let held = ArrayList<HttpResponse>()
        let url = "http://origin.test:${server.localEndpoint.port}/echo"
        try {
            for (index in 0..64) {
                held.add(client.get(url))
                if (index < 63) { let _ = client.rotateResolver(RotationResolver(server.localEndpoint.address)) }
            }
            @Expect(client.configurationSnapshot().retainedGenerations, 64)
            let generation = client.configurationSnapshot().directDnsGeneration
            @ExpectThrows[IllegalStateException](client.rotateResolver(selected))
            @Expect(client.configurationSnapshot().directDnsGeneration, generation)
            for (response in held) { @Expect(rotationBody(response.body), "none"); response.close() }
            @Expect(client.configurationSnapshot().retainedGenerations, 1)
            @Expect(client.rotateResolver(selected), generation + 1)
            @Expect(client.configurationSnapshot().retainedGenerations, 1)
            let response = client.get(url)
            @Expect(rotationBody(response.body), "none"); response.close()
        } finally {
            for (response in held) { response.close() }
            client.close(); rotationStop(server, serving)
        }
    }
    @TestCase
    func nativeSecurityDnsCancelsLateResolverAndEveryPreviouslyDrainingBody(): Unit {
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).build()
        let serving = spawn { server.serve() }
        let gate = RotationGate()
        let old = RotationResolver(server.localEndpoint.address, gate: Some(gate))
        let next = RotationResolver(server.localEndpoint.address)
        let client = HttpClient.builder().resolver(old).requestTimeout(5 * Duration.second).build()
        let base = "http://origin.test:${server.localEndpoint.port}"
        let pending = spawn {
            try { Some(client.get("${base}/echo")) } catch (_: Exception) { None<HttpResponse> }
        }
        let bodies = ArrayList<HttpResponse>()
        try {
            gate.waitUntilEntered()
            let _ = client.rotateResolver(next, policy: HttpConfigurationRotation.SecurityReplacement)
            gate.release()
            @Expect(pending.get(5 * Duration.second).isNone())
            for (_ in 0..3) {
                bodies.add(client.get("${base}/large"))
                let _ = client.rotateResolver(RotationResolver(server.localEndpoint.address))
            }
            let _ = client.rotateResolver(next, policy: HttpConfigurationRotation.SecurityReplacement)
            for (response in bodies) { @ExpectThrows(rotationDrain(response.body)); response.close() }
            let fresh = client.get("${base}/echo")
            @Expect(rotationBody(fresh.body), "none"); fresh.close()
            @Expect(client.configurationSnapshot().retainedGenerations, 1)
            @Expect(old.calls.load(), 1)
            @Expect(next.calls.load(), 2)
        } finally {
            gate.release()
            for (response in bodies) { response.close() }
            try { match (pending.get(5 * Duration.second)) { case Some(value) => value.close(); case None => () } }
            catch (_: Exception) {}
            client.close(); rotationStop(server, serving)
        }
    }

    @TestCase
    func rapidTlsUpdatesRetainOneContextAndDnsRotationDoesNotReopenClosedMaterial(): Unit {
        let trusted = HttpClientTlsConfig([publicTlsTestCertificateDer()])
        let selected = RotationResolver(rotationLoopback().address)
        let client = HttpClient.builder().resolver(selected).tls(trusted).build()
        try {
            for (index in 0..100) {
                @Expect(client.rotateTls(trusted), UInt64(index + 2))
                let snapshot = client.configurationSnapshot()
                @Expect(snapshot.retainedGenerations, 2)
                @Expect(snapshot.retainedTlsContexts, 1)
                @Expect(snapshot.directDnsGeneration, 1u64)
                @Expect(snapshot.proxyDnsGeneration, 1u64)
            }
            trusted.close()
            @Expect(client.rotateResolver(selected), 2u64)
            @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
            let generation = client.configurationSnapshot().tlsGeneration
            @ExpectThrows[IllegalStateException](client.rotateTls(trusted))
            @Expect(client.configurationSnapshot().tlsGeneration, generation)
        } finally { client.close(); trusted.close() }
        @Expect(client.configurationSnapshot().retainedGenerations, 0)
        @Expect(client.configurationSnapshot().retainedTlsContexts, 0)
    }

    @TestCase
    func nativeTransferredH1SessionRetainsGenerationAcrossRotationAndClientClose(): Unit {
        let server = HttpServer.builder().listen(rotationLoopback()).handler(RotationDuplexFixture()).build()
        let serving = spawn { server.serve() }
        let selected = RotationResolver(server.localEndpoint.address)
        let client = HttpClient.builder().resolver(selected).requestTimeout(5 * Duration.second).build()
        var transferred = None<HttpUpgradedConnection>
        try {
            let request = HttpRequest(HttpMethod("CONNECT"), HttpUrl.parse(
                "http://origin.test:${server.localEndpoint.port}/"))
            let session = match (client.upgrade(request)) {
                case HttpUpgradeResult.Connected(value) => value
                case HttpUpgradeResult.Rejected(response) => response.close(); throw Exception("CONNECT was rejected")
            }
            transferred = Some(session)
            @Expect(session.version, HttpVersion.Http11)
            let _ = client.rotateResolver(selected)
            @Expect(client.configurationSnapshot().retainedGenerations, 2)
            let _ = client.rotateResolver(selected, policy: HttpConfigurationRotation.SecurityReplacement)
            client.close()
            @Expect(client.configurationSnapshot().retainedGenerations, 1)
            let context = OperationContext(deadline: Some(Deadline.after(5 * Duration.second)))
            api.writeAll(session.transport, api.ByteSpan([b'r']), context: context)
            let bytes = Array<Byte>(1, repeat: 0u8)
            api.readExact(session.transport, api.MutableByteSpan(bytes), context: context)
            @Expect(bytes, [b'r'])
            session.close(); session.close()
            @Expect(client.configurationSnapshot().retainedGenerations, 0)
        } finally {
            match (transferred) { case Some(value) => value.close(); case None => () }
            client.close(); rotationStop(server, serving)
        }
    }

    @TestCase
    func nativeMtlsIdentityRemovalCancelsOldH2AndRequiresFreshAuthenticatedHandshake(): Unit {
        let certificate = publicTlsTestCertificateDer()
        let privateKey = publicTlsTestPrivateKeyDer()
        let serverTls = HttpServerTlsConfig([certificate], privateKey,
            clientAuthentication: HttpServerClientAuthentication.Required,
            clientTrustRootsDer: [certificate])
        let identity = HttpClientTlsConfig([certificate],
            clientCertificateChainDer: [certificate], clientPrivateKeyPkcs8Der: privateKey)
        let anonymous = HttpClientTlsConfig([certificate])
        let fixture = RotationFixture()
        let server = HttpServer.builder().listen(rotationLoopback()).handler(fixture).tls(serverTls).build()
        let serving = spawn { server.serve() }
        let client = HttpClient.builder().resolver(RotationResolver(server.localEndpoint.address))
            .tls(identity).connector(fixture).requestTimeout(5 * Duration.second).build()
        let base = "https://example.com:${server.localEndpoint.port}"
        var oldBody = None<HttpResponse>
        try {
            let authenticated = client.get("${base}/large")
            oldBody = Some(authenticated)
            @Expect(authenticated.version, HttpVersion.Http2)
            let sibling = client.get("${base}/echo")
            @Expect(sibling.version, HttpVersion.Http2)
            @Expect(rotationBody(sibling.body), "none"); sibling.close()
            @Expect(fixture.connections.load(), 1)
            @Expect(client.rotateTls(anonymous, policy: HttpConfigurationRotation.SecurityReplacement), 2u64)
            @ExpectThrows(rotationDrain(authenticated.body))
            authenticated.close()
            @ExpectThrows(client.get("${base}/echo"))
            @Expect(fixture.connections.load(), 2)
            @Expect(client.resourceSnapshot().activeConnections, 0)
            @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
            @Expect(client.rotateTls(identity, policy: HttpConfigurationRotation.SecurityReplacement), 3u64)
            let restored = client.get("${base}/echo")
            @Expect(restored.version, HttpVersion.Http2)
            @Expect(rotationBody(restored.body), "none"); restored.close()
            @Expect(fixture.connections.load(), 3)
            @Expect(client.configurationSnapshot().retainedTlsContexts, 1)
        } finally {
            match (oldBody) { case Some(value) => value.close(); case None => () }
            client.close(); rotationStop(server, serving)
            identity.close(); anonymous.close(); serverTls.close()
        }
        @Expect(client.configurationSnapshot().retainedGenerations, 0)
        @Expect(client.configurationSnapshot().retainedTlsContexts, 0)
        @Expect(client.resourceSnapshot().activeConnections, 0)
    }

}

private class RotationFixture <: HttpServerHandler & HttpConnector & HttpConnectionPoolHook {
    let connections = AtomicInt64(0)
    let acquisitions = AtomicInt64(0)
    let releases = AtomicInt64(0)
    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let _ = connections.fetchAdd(1)
        TcpStream.connect(endpoint, context: context)
    }
    public func acquired(_: NetworkEvent, _: OperationContext): Unit { let _ = acquisitions.fetchAdd(1) }
    public func released(_: NetworkEvent, _: OperationContext): Unit { let _ = releases.fetchAdd(1) }
    public func handle(request: HttpServerRequest, _: OperationContext): HttpServerResponse {
        let large = request.target == "/large"
        let text = match (request.headers.getFirst("cookie")) { case Some(value) => value; case None => "none" }
        let bytes = if (large) { Array<Byte>(256 * 1024, repeat: b'x') } else { text.toArray() }
        let headers = HttpHeaders.builder().add("Content-Length", bytes.size.toString())
        if (request.target == "/seed") { headers.add("Set-Cookie", "session=rotation; Path=/; HttpOnly") }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(bytes).open()), headers: headers.build()))
    }
}

private class RotationResolver <: Resolver {
    let calls = AtomicInt64(0)
    private let address: IpAddress
    private let gate: ?RotationGate
    init(address: IpAddress, gate!: ?RotationGate = None<RotationGate>) { this.address = address; this.gate = gate }
    public func resolve(host: HostName, _: ?String, _: ResolveOptions, context: OperationContext): ResolveResult {
        let _ = calls.fetchAdd(1)
        match (gate) { case Some(value) => value.enter(); case None => () }
        if (context.isCancellationRequested()) {
            throw ResolveException(ResolveErrorCode.Cancelled, "rotation resolver cancelled")
        }
        ResolveResult([address], host, ResolverSource.Static)
    }
}

private class RotationGatedConnector <: HttpConnector {
    private let gate: RotationGate
    private let first = AtomicBool(true)
    init(gate: RotationGate) { this.gate = gate }
    public func connect(endpoint: SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let stream = TcpStream.connect(endpoint, context: context)
        try {
            if (first.compareAndSwap(true, false)) { gate.enter() }
            stream
        } catch (error: Exception) { stream.close(); throw error }
    }
}

private class RotationGate {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    func enter(): Unit {
        synchronized(mutex) {
            entered = true; changed.notifyAll()
            let deadline = Deadline.after(5 * Duration.second)
            while (!released) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("rotation gate timed out") }
                changed.wait(timeout: remaining)
            }
        }
    }
    func waitUntilEntered(): Unit {
        synchronized(mutex) {
            let deadline = Deadline.after(5 * Duration.second)
            while (!entered) {
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw Exception("rotation attempt did not enter gate") }
                changed.wait(timeout: remaining)
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
}

private func rotationLoopback(): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)
}
private func rotationStop(server: HttpServer, serving: Future<Unit>): Unit {
    let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
    serving.get(5 * Duration.second)
}
private func rotationBody(body: ResponseBody): String {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(32, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        if (bytes.size + count > 1024) { throw Exception("rotation fixture body is too large") }
        for (index in 0..count) { bytes.add(buffer[index]) }
    }
    String.fromUtf8(bytes.toArray())
}
private func rotationDrain(body: ResponseBody): Int64 {
    let buffer = Array<Byte>(4096, repeat: 0u8)
    var count: Int64 = 0
    while (true) {
        let next = body.read(buffer)
        if (next == 0) { return count }
        count += next
    }
    throw Exception("unreachable rotation drain")
}

private class RotationDuplexFixture <: HttpServerHandler & HttpDuplexHandler {
    public func handle(_: HttpServerRequest, _: OperationContext): HttpServerResponse {
        HttpServerResponse(HttpResponse(200, "Connection Established", ResponseBody.empty()),
            duplexHandler: Some<HttpDuplexHandler>(this))
    }
    public func serve(stream: api.DuplexTransport, context: OperationContext): Unit {
        let bytes = Array<Byte>(16, repeat: 0u8)
        while (true) {
            match (stream.readSome(api.MutableByteSpan(bytes), context: context)) {
                case api.ReadResult.Data(count) =>
                    api.writeAll(stream, api.ByteSpan(bytes, length: count), context: context)
                case api.ReadResult.EndOfStream => return
            }
        }
    }
}

// Existing independent alt.example.com certificate from tls_identity_fixture_test.cj.
private func rotationUntrustedCertificateDer(): Array<Byte> {
    [
        48u8, 130u8, 3u8, 49u8, 48u8, 130u8, 2u8, 25u8, 160u8, 3u8, 2u8, 1u8, 2u8, 2u8, 20u8, 14u8,
        25u8, 155u8, 116u8, 90u8, 211u8, 220u8, 129u8, 238u8, 177u8, 110u8, 175u8, 55u8, 26u8, 162u8, 203u8, 103u8,
        57u8, 13u8, 13u8, 48u8, 13u8, 6u8, 9u8, 42u8, 134u8, 72u8, 134u8, 247u8, 13u8, 1u8, 1u8, 11u8,
        5u8, 0u8, 48u8, 26u8, 49u8, 24u8, 48u8, 22u8, 6u8, 3u8, 85u8, 4u8, 3u8, 12u8, 15u8, 97u8,
        108u8, 116u8, 46u8, 101u8, 120u8, 97u8, 109u8, 112u8, 108u8, 101u8, 46u8, 99u8, 111u8, 109u8, 48u8, 30u8,
        23u8, 13u8, 50u8, 54u8, 48u8, 56u8, 50u8, 51u8, 50u8, 49u8, 48u8, 57u8, 51u8, 56u8, 90u8, 23u8,
        13u8, 51u8, 54u8, 48u8, 56u8, 50u8, 48u8, 50u8, 49u8, 48u8, 57u8, 51u8, 56u8, 90u8, 48u8, 26u8,
        49u8, 24u8, 48u8, 22u8, 6u8, 3u8, 85u8, 4u8, 3u8, 12u8, 15u8, 97u8, 108u8, 116u8, 46u8, 101u8,
        120u8, 97u8, 109u8, 112u8, 108u8, 101u8, 46u8, 99u8, 111u8, 109u8, 48u8, 130u8, 1u8, 34u8, 48u8, 13u8,
        6u8, 9u8, 42u8, 134u8, 72u8, 134u8, 247u8, 13u8, 1u8, 1u8, 1u8, 5u8, 0u8, 3u8, 130u8, 1u8,
        15u8, 0u8, 48u8, 130u8, 1u8, 10u8, 2u8, 130u8, 1u8, 1u8, 0u8, 230u8, 177u8, 64u8, 250u8, 2u8,
        135u8, 75u8, 238u8, 215u8, 164u8, 134u8, 206u8, 116u8, 7u8, 197u8, 227u8, 140u8, 16u8, 96u8, 102u8, 54u8,
        79u8, 87u8, 190u8, 78u8, 17u8, 226u8, 113u8, 0u8, 60u8, 210u8, 235u8, 156u8, 1u8, 129u8, 38u8, 204u8,
        109u8, 46u8, 123u8, 175u8, 240u8, 57u8, 219u8, 12u8, 204u8, 40u8, 165u8, 23u8, 42u8, 192u8, 238u8, 92u8,
        78u8, 215u8, 73u8, 96u8, 179u8, 10u8, 252u8, 60u8, 234u8, 243u8, 183u8, 45u8, 252u8, 56u8, 59u8, 37u8,
        119u8, 184u8, 135u8, 130u8, 238u8, 96u8, 26u8, 240u8, 62u8, 209u8, 107u8, 128u8, 158u8, 210u8, 19u8, 255u8,
        52u8, 47u8, 211u8, 217u8, 178u8, 114u8, 108u8, 22u8, 85u8, 78u8, 102u8, 57u8, 160u8, 34u8, 85u8, 88u8,
        88u8, 200u8, 135u8, 109u8, 162u8, 155u8, 79u8, 133u8, 177u8, 227u8, 232u8, 62u8, 150u8, 66u8, 184u8, 194u8,
        35u8, 211u8, 207u8, 42u8, 136u8, 52u8, 17u8, 85u8, 26u8, 151u8, 221u8, 142u8, 204u8, 137u8, 243u8, 34u8,
        105u8, 72u8, 11u8, 5u8, 39u8, 60u8, 174u8, 98u8, 63u8, 4u8, 250u8, 47u8, 196u8, 28u8, 111u8, 252u8,
        71u8, 246u8, 219u8, 209u8, 172u8, 121u8, 37u8, 135u8, 159u8, 184u8, 136u8, 100u8, 135u8, 163u8, 48u8, 143u8,
        23u8, 153u8, 49u8, 176u8, 163u8, 3u8, 114u8, 118u8, 204u8, 161u8, 139u8, 96u8, 96u8, 0u8, 41u8, 132u8,
        79u8, 211u8, 10u8, 214u8, 243u8, 121u8, 144u8, 114u8, 15u8, 66u8, 209u8, 78u8, 89u8, 138u8, 244u8, 253u8,
        76u8, 199u8, 4u8, 45u8, 90u8, 66u8, 224u8, 195u8, 11u8, 117u8, 161u8, 102u8, 64u8, 24u8, 211u8, 79u8,
        59u8, 247u8, 83u8, 121u8, 134u8, 193u8, 57u8, 85u8, 7u8, 252u8, 1u8, 121u8, 196u8, 217u8, 180u8, 59u8,
        95u8, 72u8, 17u8, 124u8, 100u8, 183u8, 186u8, 208u8, 180u8, 111u8, 196u8, 25u8, 109u8, 234u8, 6u8, 168u8,
        86u8, 83u8, 239u8, 169u8, 178u8, 234u8, 45u8, 47u8, 224u8, 45u8, 171u8, 2u8, 3u8, 1u8, 0u8, 1u8,
        163u8, 111u8, 48u8, 109u8, 48u8, 29u8, 6u8, 3u8, 85u8, 29u8, 14u8, 4u8, 22u8, 4u8, 20u8, 29u8,
        91u8, 227u8, 114u8, 82u8, 131u8, 202u8, 119u8, 213u8, 4u8, 111u8, 199u8, 78u8, 200u8, 86u8, 121u8, 0u8,
        102u8, 172u8, 215u8, 48u8, 31u8, 6u8, 3u8, 85u8, 29u8, 35u8, 4u8, 24u8, 48u8, 22u8, 128u8, 20u8,
        29u8, 91u8, 227u8, 114u8, 82u8, 131u8, 202u8, 119u8, 213u8, 4u8, 111u8, 199u8, 78u8, 200u8, 86u8, 121u8,
        0u8, 102u8, 172u8, 215u8, 48u8, 15u8, 6u8, 3u8, 85u8, 29u8, 19u8, 1u8, 1u8, 255u8, 4u8, 5u8,
        48u8, 3u8, 1u8, 1u8, 255u8, 48u8, 26u8, 6u8, 3u8, 85u8, 29u8, 17u8, 4u8, 19u8, 48u8, 17u8,
        130u8, 15u8, 97u8, 108u8, 116u8, 46u8, 101u8, 120u8, 97u8, 109u8, 112u8, 108u8, 101u8, 46u8, 99u8, 111u8,
        109u8, 48u8, 13u8, 6u8, 9u8, 42u8, 134u8, 72u8, 134u8, 247u8, 13u8, 1u8, 1u8, 11u8, 5u8, 0u8,
        3u8, 130u8, 1u8, 1u8, 0u8, 184u8, 196u8, 190u8, 78u8, 228u8, 197u8, 166u8, 52u8, 144u8, 221u8, 250u8,
        226u8, 110u8, 87u8, 30u8, 61u8, 111u8, 71u8, 107u8, 239u8, 232u8, 182u8, 167u8, 147u8, 75u8, 243u8, 101u8,
        181u8, 220u8, 115u8, 173u8, 3u8, 113u8, 135u8, 89u8, 107u8, 54u8, 237u8, 226u8, 165u8, 125u8, 40u8, 155u8,
        216u8, 183u8, 98u8, 174u8, 93u8, 209u8, 102u8, 182u8, 73u8, 112u8, 86u8, 11u8, 220u8, 52u8, 160u8, 39u8,
        150u8, 235u8, 130u8, 173u8, 195u8, 246u8, 186u8, 243u8, 50u8, 251u8, 78u8, 93u8, 192u8, 101u8, 201u8, 192u8,
        250u8, 27u8, 195u8, 251u8, 80u8, 127u8, 212u8, 188u8, 87u8, 114u8, 224u8, 6u8, 80u8, 246u8, 211u8, 5u8,
        70u8, 66u8, 201u8, 249u8, 231u8, 0u8, 244u8, 216u8, 193u8, 210u8, 164u8, 81u8, 67u8, 216u8, 92u8, 207u8,
        22u8, 102u8, 196u8, 46u8, 181u8, 22u8, 129u8, 147u8, 239u8, 238u8, 230u8, 208u8, 204u8, 54u8, 229u8, 197u8,
        189u8, 162u8, 177u8, 99u8, 253u8, 0u8, 131u8, 145u8, 127u8, 47u8, 149u8, 155u8, 195u8, 226u8, 233u8, 165u8,
        188u8, 93u8, 202u8, 76u8, 210u8, 69u8, 25u8, 17u8, 245u8, 75u8, 249u8, 65u8, 167u8, 27u8, 201u8, 6u8,
        50u8, 73u8, 51u8, 200u8, 123u8, 22u8, 155u8, 160u8, 177u8, 71u8, 87u8, 208u8, 38u8, 145u8, 9u8, 67u8,
        181u8, 154u8, 248u8, 106u8, 126u8, 122u8, 144u8, 26u8, 155u8, 222u8, 199u8, 75u8, 55u8, 47u8, 75u8, 54u8,
        141u8, 138u8, 46u8, 219u8, 226u8, 170u8, 168u8, 210u8, 93u8, 244u8, 247u8, 124u8, 149u8, 81u8, 21u8, 199u8,
        148u8, 215u8, 236u8, 254u8, 155u8, 115u8, 120u8, 136u8, 176u8, 243u8, 216u8, 240u8, 147u8, 104u8, 252u8, 126u8,
        217u8, 123u8, 128u8, 183u8, 236u8, 176u8, 48u8, 82u8, 62u8, 246u8, 67u8, 139u8, 225u8, 72u8, 90u8, 248u8,
        34u8, 211u8, 1u8, 40u8, 64u8, 253u8, 25u8, 211u8, 33u8, 54u8, 44u8, 71u8, 116u8, 0u8, 153u8, 217u8,
        43u8, 186u8, 192u8, 158u8, 68u8
    ]
}

