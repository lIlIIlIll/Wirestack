package wirestack_m10_004_rotation

import std.fs.File
import std.sync.*
import wirestack.http.*

func require(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func context(): OperationContext {
    OperationContext(deadline: Some(Deadline.after(10 * Duration.second)))
}

class ExchangeGate {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var entered = false
    private var released = false
    private var cancelled = false

    func hold(operation: OperationContext): Unit {
        let registration = operation.cancellation.register { =>
            synchronized(mutex) { cancelled = true; changed.notifyAll() }
        }
        try {
            synchronized(mutex) {
                entered = true; changed.notifyAll()
                while (!released && !operation.isCancellationRequested()) {
                    if (operation.isDeadlineExceeded()) { throw Exception("held exchange deadline expired") }
                    changed.wait(timeout: Duration.second)
                }
                cancelled = operation.isCancellationRequested(); changed.notifyAll()
            }
        } finally { registration.unregister() }
    }
    func waitEntered(): Unit {
        let limit = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (!entered) {
                if (limit.isExpired()) { throw Exception("exchange was not admitted") }
                changed.wait(timeout: limit.remaining())
            }
        }
    }
    func release(): Unit { synchronized(mutex) { released = true; changed.notifyAll() } }
    func wasCancelled(): Bool { synchronized(mutex) { cancelled } }
}

class RotationHandler <: HttpServerHandler {
    let graceful = ExchangeGate()
    let security = ExchangeGate()
    public func handle(request: HttpServerRequest, operation: OperationContext): HttpServerResponse {
        if (request.target == "/graceful") { graceful.hold(operation) }
        if (request.target == "/security") { security.hold(operation) }
        HttpServerResponse(HttpResponse(204, "No Content", ResponseBody.empty()))
    }
}

func expectReady(client: HttpClient, base: String): Unit {
    let response = client.get("${base}/ready")
    try {
        require(response.status == 204, "unexpected readiness status")
        require(response.version == HttpVersion.Http2, "rotation consumer did not negotiate HTTP/2")
        require(response.body.read(Array<Byte>(1, repeat: 0u8)) == 0, "readiness body was not empty")
    } finally { response.close() }
}
func requestFails(client: HttpClient, url: String): Bool {
    try { let response = client.get(url); response.close(); false }
    catch (_: Exception) { true }
}

main(args: Array<String>): Int64 {
    if (args.size != 3) { throw IllegalArgumentException("usage: configuration_rotation <certificate.der> <key.pk8> <untrusted.der>") }
    let certificate = File.readFrom(args[0])
    let key = File.readFrom(args[1])
    let untrusted = File.readFrom(args[2])
    let serverMaterial = HttpServerTlsConfig([certificate], key)
    let stricterServer = HttpServerTlsConfig([certificate], key,
        clientAuthentication: HttpServerClientAuthentication.Required,
        clientTrustRootsDer: [certificate])
    let clientMaterial = HttpClientTlsConfig([certificate])
    let mtls = HttpClientTlsConfig([certificate], clientCertificateChainDer: [certificate],
        clientPrivateKeyPkcs8Der: key)
    let removedTrust = HttpClientTlsConfig([untrusted], clientCertificateChainDer: [certificate],
        clientPrivateKeyPkcs8Der: key)
    let handler = RotationHandler()
    let server = HttpServer.builder().listen(SocketEndpoint(
        IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16))
        .handler(handler).tls(serverMaterial).build()
    let serving: Future<Unit> = spawn { server.serve() }
    let resolver = StaticResolver(ResolveResult([server.localEndpoint.address],
        HostName("example.test"), ResolverSource.Static))
    let client = HttpClient.builder().resolver(resolver).tls(clientMaterial)
        .requestTimeout(10 * Duration.second).build()
    let base = "https://example.test:${server.localEndpoint.port}"
    try {
        let admitted = spawn {
            try { client.get("${base}/graceful") }
            catch (error: HttpException) {
                if (let Some(cause) <- error.cause) { println("graceful-failure-cause=${cause}") }
                throw error
            }
        }
        handler.graceful.waitEntered()
        require(client.rotateTls(clientMaterial) == 2u64, "client graceful generation not published")
        require(server.rotateTls(serverMaterial) == 2u64, "server graceful generation not published")
        expectReady(client, base)
        handler.graceful.release()
        let old = admitted.get(5 * Duration.second)
        try { require(old.status == 204, "graceful exchange was interrupted") }
        finally { old.close() }
        require(!handler.graceful.wasCancelled(), "graceful operation was cancelled")
        println("graceful=continued,new-admission=replaced")

        let obsolete = spawn { requestFails(client, "${base}/security") }
        handler.security.waitEntered()
        require(server.rotateTls(stricterServer, policy: HttpConfigurationRotation.SecurityReplacement) == 3u64,
            "server security generation not published")
        require(obsolete.get(5 * Duration.second), "security replacement allowed obsolete exchange")
        require(handler.security.wasCancelled(), "security operation token was not cancelled")
        require(requestFails(client, "${base}/ready"), "old anonymous HTTP/2 authentication was reused")
        require(client.rotateTls(mtls, policy: HttpConfigurationRotation.SecurityReplacement) == 3u64,
            "client identity replacement not published")
        expectReady(client, base)
        require(client.rotateTls(removedTrust, policy: HttpConfigurationRotation.SecurityReplacement) == 4u64,
            "trust replacement not published")
        require(requestFails(client, "${base}/ready"), "removed trust reused an authenticated HTTP/2 connection")
        require(client.rotateTls(mtls, policy: HttpConfigurationRotation.SecurityReplacement) == 5u64,
            "trust recovery not published")
        expectReady(client, base)
        require(client.rotateResolver(resolver) == 2u64, "DNS generation not published")
        expectReady(client, base)
        require(client.configurationSnapshot().retainedGenerations <= 4, "unreferenced routes retained")
        println("security=cancelled,old-h2=rejected,mtls=recovered,dns=replaced")
    } finally {
        handler.graceful.release(); handler.security.release()
        client.close()
        let shutdown = server.shutdown(context: context())
        require(shutdown.activeAtReturn == 0, "server retained active connections")
        serving.get(5 * Duration.second)
        server.close()
        serverMaterial.close(); stricterServer.close(); clientMaterial.close(); mtls.close(); removedTrust.close()
        for (index in 0..key.size) { key[index] = 0u8 }
    }
    require(client.configurationSnapshot().retainedGenerations == 0, "client retained generations after close")
    require(client.resourceSnapshot().activeConnections == 0, "client retained connections after close")
    require(server.resourceSnapshot().activeConnections == 0, "server retained connections after close")
    println("M10_004_INSTALLED_ROTATION_PASS")
    0
}
