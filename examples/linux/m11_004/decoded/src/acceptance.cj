package wirestack_m11_004_decoded
import std.fs.*
import std.sync.*
import std.time.*
import wirestack.http.*

class Gate {
    let entered = AtomicBool(false)
    let release = AtomicBool(false)
    func waitEntered(): Unit {
        let end = Deadline.after(3000 * Duration.millisecond)
        while (!entered.load()) { require(!end.isExpired()); sleep(Duration.millisecond) }
    }
}
class HeldBody <: HttpBodyStream {
    let gate: Gate
    let owner: OperationContext
    let closed = AtomicBool(false)
    init(gate: Gate, owner: OperationContext) { this.gate = gate; this.owner = owner }
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(destination: Array<Byte>): Int64 {
        gate.entered.store(true)
        while (!gate.release.load() && !closed.load() && !owner.isCancellationRequested() && !owner.isDeadlineExceeded()) { sleep(Duration.millisecond) }
        if (!gate.release.load()) { throw NetworkException(NetworkErrorCategory.Read, NetworkPhase.HttpBody, NetworkErrorCode.ConnectionReset, "fixture stopped") }
        0
    }
    public func close(): Unit { closed.store(true) }
    public func isClosed(): Bool { closed.load() }
}
class DownloadHandler <: HttpServerHandler {
    let active = Gate(); let deadline = Gate(); let peer = Gate()
    let count = AtomicInt64(0)
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        require(count.fetchAdd(1) < 40)
        let body = match (request.target) {
            case "/active" => ResponseBody(HeldBody(active, owner))
            case "/deadline" => ResponseBody(HeldBody(deadline, owner))
            case "/peer" => ResponseBody(HeldBody(peer, owner))
            case "/gzip" => ResponseBody(RequestBody.bytes(gzipBytes()).open())
            case _ => ResponseBody(RequestBody.string("download-payload").open())
        }
        let headers = HttpHeaders.builder()
        if (request.target == "/gzip") { headers.add("Content-Encoding", "gzip") }
        HttpServerResponse(HttpResponse(200, "OK", body, headers: headers.build()))
    }
    func release(): Unit { active.release.store(true); deadline.release.store(true); peer.release.store(true) }
}
func gzipBytes(): Array<Byte> { [31u8, 139u8, 8u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8, 255u8, 75u8, 201u8, 47u8, 207u8, 203u8, 201u8, 79u8, 76u8, 209u8, 45u8, 72u8, 172u8, 4u8, 209u8, 0u8, 61u8, 253u8, 39u8, 0u8, 16u8, 0u8, 0u8, 0u8] }
func mark(name: String): Unit { println("CHECK decoded_" + name + " PASS") }
func clean(client: HttpClient): Unit {
    let end = Deadline.after(3000 * Duration.millisecond)
    while (true) {
        let row = client.resourceSnapshot()
        if (row.activeRequests == 0 && row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 && row.admissionWaiters == 0) { return }
        require(!end.isExpired()); sleep(Duration.millisecond)
    }
}
func stopped(action: () -> Unit, cancellation: Bool): Bool {
    try { action(); false } catch (error: NetworkException) {
        match (error.code) { case NetworkErrorCode.Cancelled => cancellation; case NetworkErrorCode.TimedOut => !cancellation; case _ => false }
    }
}
func absent(path: String): Unit { require(!exists(path) && !exists(path + ".partial")) }
func selfCheck(args: Array<String>): Int64 {
    require(args.size >= 3 && args.size <= 3)
    let cert = boundedFile(args[0]); let key = boundedFile(args[1]); let untrusted = boundedFile(args[2])
    require(cert != untrusted)
    let material = HttpServerTlsConfig([cert], key)
    let trust = HttpClientTlsConfig([cert])
    let handler = DownloadHandler()
    let server = HttpServer.builder().listen(SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).tls(material).handler(handler).build()
    let serving = spawn { server.serve() }
    let resolver = StaticResolver(ResolveResult([server.localEndpoint.address], HostName("example.test"), ResolverSource.Static))
    let client = HttpClient.builder().resolver(resolver).tls(trust).resourceLimits(HttpResourceLimits(maximumWaiters: 1)).requestTimeout(5000 * Duration.millisecond).build()
    let base = "https://example.test:${server.localEndpoint.port}"
    let output = "decoded-self-check-output"
    try {
        absent(output)
        require(download(client, base + "/ok", output, operation()) == 16)
        require(File.readFrom(output) == "download-payload".toArray()); remove(output); clean(client); mark("success")
        let source = CancellationSource(); source.cancel()
        require(stopped({ => download(client, base + "/ok", output, operation(token: source.token)); () }, true)); absent(output); mark("pre_cancel")
        let activeSource = CancellationSource()
        let worker = spawn { stopped({ => download(client, base + "/active", output, operation(token: activeSource.token)); () }, true) }
        handler.active.waitEntered(); activeSource.cancel()
        require(worker.get(3000 * Duration.millisecond)); absent(output); clean(client); mark("active_cancel")
        let timer = spawn { stopped({ => download(client, base + "/deadline", output, operation(ms: 500)); () }, false) }
        handler.deadline.waitEntered(); require(timer.get(3000 * Duration.millisecond)); absent(output); clean(client); mark("deadline")
        let lease = client.reserveResponseBuffer(HttpUrl.parse(base + "/ok"), 25165824u64, context: operation())
        let waitingSource = CancellationSource()
        let waiting = spawn { stopped({ => let value = client.reserveResponseBuffer(HttpUrl.parse(base + "/ok"), 16777216u64, context: operation(token: waitingSource.token)); value.close() }, true) }
        try {
            let end = Deadline.after(2000 * Duration.millisecond)
            while (client.resourceSnapshot().admissionWaiters != 1) { require(!end.isExpired()); sleep(Duration.millisecond) }
            let exhausted = try { let value = client.reserveResponseBuffer(HttpUrl.parse(base + "/ok"), 16777216u64, context: operation()); value.close(); false }
            catch (error: NetworkException) { match (error.code) { case NetworkErrorCode.ResourceExhausted => true; case _ => false } }
            require(exhausted)
        } finally { waitingSource.cancel(); require(waiting.get(3000 * Duration.millisecond)); lease.close() }
        clean(client); mark("capacity")
        let outputFailure = try { download(client, base + "/ok", output, operation(), progress: { => File.writeTo(output, "owned-existing".toArray()) }); false } catch (error: DownloadFailure) { error.code == 4 }
        require(outputFailure && !exists(output + ".partial")); require(File.readFrom(output) == "owned-existing".toArray()); remove(output); clean(client); mark("output_failure")
        let response = client.get(base + "/ok", context: operation()); response.close(); require(response.isClosed())
        let closed = try { response.body.read(Array<Byte>(1, repeat: 0u8)); false } catch (error: HttpBodyException) { match (error.code) { case HttpBodyErrorCode.Closed => true; case _ => false } }
        require(closed); clean(client); mark("explicit_close")
        require(download(client, base + "/gzip", output, operation(), decoded: true) == 16)
        require(File.readFrom(output) == "download-payload".toArray()); remove(output); clean(client); mark("decoded_gzip")
        
        let disconnected = spawn {
            try { download(client, base + "/peer", output, operation()); false }
            catch (error: NetworkException) { match (error.code) { case NetworkErrorCode.UnexpectedEof => println("PEER_TERMINAL network=unexpected_eof"); true; case NetworkErrorCode.ConnectionReset => println("PEER_TERMINAL network=reset"); true; case NetworkErrorCode.Closed => println("PEER_TERMINAL network=closed"); true; case _ => false } }
            catch (error: HttpException) { match (error.code) { case HttpErrorCode.StreamReset => println("PEER_TERMINAL http=stream_reset"); true; case HttpErrorCode.ConnectionGoAway => println("PEER_TERMINAL http=go_away"); true; case HttpErrorCode.ProtocolViolation => println("PEER_TERMINAL http=protocol_violation"); true; case _ => false } }
        }
        handler.peer.waitEntered(); server.close(); require(disconnected.get(3000 * Duration.millisecond)); absent(output); clean(client); mark("peer_disconnect")
    } finally {
        handler.release(); client.close(); server.close(); serving.get(3000 * Duration.millisecond); material.close(); trust.close()
    }
    let row = client.resourceSnapshot()
    require(row.activeRequests == 0 && row.activeConnections == 0 && row.reservedConnections == 0 && row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 && row.admissionWaiters == 0)
    println("RESOURCE decoded_cleanup connections=${row.activeConnections} requests=${row.activeRequests} streams=${row.activeStreams} buffers=${row.managedBufferBytes} admission_waiters=${row.admissionWaiters}")
    mark("cleanup"); println("APP_ACCEPTANCE_PASS"); 0
}
func fixture(args: Array<String>): Int64 {
    require(args.size == 2)
    let material = HttpServerTlsConfig([boundedFile(args[0])], boundedFile(args[1]))
    let handler = DownloadHandler()
    let server = HttpServer.builder().listen(SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).tls(material).handler(handler).build()
    let serving = spawn { server.serve() }
    try { println("FIXTURE_READY port=${server.localEndpoint.port}"); sleep(15 * Duration.second) }
    finally { handler.release(); server.close(); serving.get(3000 * Duration.millisecond); material.close() }
    0
}
