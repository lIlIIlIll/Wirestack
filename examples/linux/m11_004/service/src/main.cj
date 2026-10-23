package wirestack_m11_004_service

import std.fs.*
import std.console.Console
import std.convert.*
import std.collection.ArrayList
import std.collection.HashMap
import std.sync.*
import wirestack as api
import wirestack.http.*
import wirestack.sse.*

func require(ok: Bool): Unit { if (!ok) { throw IllegalStateException("acceptance") } }
func materialBytes(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        // Validate and snapshot the size once: a file that grows after the check must not
        // enlarge the allocation or the read bound beyond the intended 64 KiB limit.
        let length = file.length
        require(length > 0 && length <= 65536)
        let bytes = Array<Byte>(length, repeat: 0u8)
        var offset: Int64 = 0
        while (offset < bytes.size) {
            let count = file.read(bytes[offset..]); require(count > 0); offset += count
        }
        bytes
    } finally { file.close() }
}
func context(ms!: Int64 = 10000): OperationContext {
    OperationContext(deadline: Some(Deadline.after(ms * Duration.millisecond)))
}
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func waitFor(predicate: () -> Bool): Unit {
    let end = Deadline.after(5 * Duration.second)
    while (!predicate()) { require(!end.isExpired()); sleep(Duration.millisecond) }
}
class Gate {
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    let cancelled = AtomicBool(false)
    func hold(owner: OperationContext): Unit {
        entered.store(true)
        while (!released.load() && !owner.isCancellationRequested() && !owner.isDeadlineExceeded()) {
            sleep(Duration.millisecond)
        }
        cancelled.store(owner.isCancellationRequested())
    }
}
func budgetExpired(operation: OperationContext): Bool {
    operation.isCancellationRequested() || operation.isDeadlineExceeded()
}
class ServiceHandler <: HttpServerHandler {
    let graceful = Gate()
    let security = Gate()
    let draining = Gate()
    let producers = AtomicInt64(0)
    let uploads = AtomicInt64(0)
    let admissions = AtomicInt64(0)
    let budget: Int64
    init(budget: Int64) { this.budget = budget }
    // DOC-BEGIN service-handler
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        admissions.fetchAdd(1)
        let operation = owner.shortenDeadline(budget * Duration.millisecond)
        // The public request body is bound to the handler context, so enforce the same shortened
        // budget by cancelling this request when it expires instead of waiting forever on a stalled body.
        let bodyFinished = AtomicBool(false)
        let bodyWatchdog = spawn {
            while (!bodyFinished.load()) {
                if (operation.isCancellationRequested() || operation.isDeadlineExceeded()) {
                    if (!bodyFinished.load()) { let _ = request.requestCancellation.cancel() }
                    break
                }
                sleep(Duration.millisecond)
            }
        }
        let buffer = Array<Byte>(256, repeat: 0u8)
        var bytes: Int64 = 0
        try {
            while (true) {
                let count = request.body.read(buffer)
                if (count == 0) { break }
                bytes += count
                if (bytes > 4096) {
                    return HttpServerResponse(HttpResponse(413, "Content Too Large", ResponseBody.empty()))
                }
            }
        } finally {
            bodyFinished.store(true)
            try { let _ = bodyWatchdog.get(3 * Duration.second) } catch (_: Exception) {}
            request.body.close()
        }
        // A body EOF can race the watchdog; an expired or cancelled operation must not reach a
        // side-effecting route or report success.
        if (budgetExpired(operation)) {
            return HttpServerResponse(HttpResponse(408, "Request Timeout", ResponseBody.empty()))
        }
        if (request.target == "/upload") {
            uploads.fetchAdd(bytes)
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("${bytes}").open())))
        }
        if (request.target == "/graceful") { graceful.hold(operation) }
        if (request.target == "/security") { security.hold(operation) }
        if (request.target == "/drain") { draining.hold(operation) }
        // A blocking route returns as soon as the shortened operation expires, so the budget is
        // rechecked before any success path; an expired --budget-ms must never report success.
        if (budgetExpired(operation)) { return HttpServerResponse(HttpResponse(408, "Request Timeout", ResponseBody.empty())) }
        if (request.target == "/stream" || request.target == "/hold") {
            let writer = SseWriter(maximumBufferBytes: 128, context: operation)
            producers.fetchAdd(1)
            let held = request.target == "/hold"
            spawn {
                try {
                    writer.write(SseEvent("chunk")); writer.flush()
                    if (held) {
                        while (!writer.isClosed() && !operation.isCancellationRequested() && !operation.isDeadlineExceeded()) {
                            sleep(20 * Duration.millisecond)
                            writer.comment("heartbeat"); writer.flush()
                        }
                    } else { writer.write(SseEvent("complete")); writer.flush() }
                    writer.complete()
                } catch (_: Exception) { writer.close() }
                finally { producers.fetchSub(1) }
            }
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(writer),
                headers: HttpHeaders.builder().add("Content-Type", "text/event-stream").build()))
        }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("download").open())))
    }
    // DOC-END service-handler
}
func budgetRouteExpiry(material: HttpServerTlsConfig, trust: HttpClientTlsConfig): Unit {
    // The shortened request budget must stay enforced after a blocking route returns: a held
    // /graceful, /security or /drain that outlives --budget-ms can never report success.
    let handler = ServiceHandler(250)
    let server = serverFor(handler, material, 0u16, 4, 4)
    let serving = spawn { server.serve() }
    let client = clientFor(server, trust)
    let base = "https://example.test:${server.localEndpoint.port}"
    try {
        for target in ["/graceful", "/security", "/drain"] {
            let response = client.get(base + target, context: context(ms: 5000))
            try { require(response.status == 408) } finally { response.close() }
            waitFor({ => server.resourceSnapshot().activeRequests == 0 })
        }
        require(!handler.graceful.cancelled.load() && !handler.security.cancelled.load() && !handler.draining.cancelled.load())
        println("RESOURCE service_budget_expired routes=3 status=408")
    } finally {
        handler.graceful.released.store(true); handler.security.released.store(true); handler.draining.released.store(true)
        client.close()
        require(server.shutdown(context: context()).activeAtReturn == 0)
        serving.get(3 * Duration.second); server.close()
    }
}
func rejectsUnknownOptions(): Unit {
    // A misspelled resource limit must not silently fall back to the default.
    for (args in [["serve", "--max-request", "1"], ["serve", "--max-requests", "1", "--max-request", "2"],
        ["serve", "--max-requests", "1", "--max-requests", "2"], ["serve", "--max-requests"],
        ["serve", "--unknown-flag", "1"]]) {
        var rejected = false
        try { let _ = parseServeOptions(args) } catch (_: IllegalArgumentException) { rejected = true }
        require(rejected)
    }
    let parsed = parseServeOptions(["serve", "--max-requests", "1", "--budget-ms", "250"])
    require(option(parsed, "--max-requests", "16") == "1" && option(parsed, "--budget-ms", "10000") == "250" &&
        option(parsed, "--max-streams", "16") == "16")
}
func limits(requests: Int64, streams: Int64): HttpResourceLimits {
    HttpResourceLimits(maximumRequests: requests, maximumRequestsPerRoute: requests,
        maximumRequestsPerOrigin: requests, maximumStreams: streams,
        maximumStreamsPerRoute: streams, maximumStreamsPerOrigin: streams,
        maximumWaiters: 4, maximumOwners: 16)
}
func serverFor(handler: ServiceHandler, material: HttpServerTlsConfig, port: UInt16,
    requests: Int64, streams: Int64): HttpServer {
    HttpServer.builder().listen(SocketEndpoint(loopback(), port)).handler(handler).tls(material)
        .connectionLimit(8).http2StreamLimit(UInt32(streams)).resourceLimits(limits(requests, streams)).build()
}
// DOC-BEGIN service-rotation
func rotate(server: HttpServer, certificate: Array<Byte>, key: Array<Byte>, secure: Bool): UInt64 {
    let material = if (secure) {
        HttpServerTlsConfig([certificate], key, clientAuthentication: HttpServerClientAuthentication.Required,
            clientTrustRootsDer: [certificate])
    } else { HttpServerTlsConfig([certificate], key) }
    try {
        server.rotateTls(material, policy: if (secure) { HttpConfigurationRotation.SecurityReplacement }
            else { HttpConfigurationRotation.Graceful })
    } finally { material.close() }
}
// DOC-END service-rotation
func zero(row: HttpResourceSnapshot): Bool {
    row.activeConnections == 0 && row.reservedConnections == 0 && row.activeRequests == 0 &&
        row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 &&
        row.admissionWaiters == 0 && row.owners.size == 0
}
func clean(server: HttpServer, handler: ServiceHandler): Unit {
    waitFor({ => zero(server.resourceSnapshot()) && handler.producers.load() == 0 })
    println("RESOURCE service connections=0 requests=0 streams=0 reserved=0 buffers=0 waiters=0 owners=0")
}
func check(label: String): Unit { println("CHECK service_${label} PASS") }
func clientFor(server: HttpServer, material: HttpClientTlsConfig, cap!: Int64 = 16): HttpClient {
    let resolver = StaticResolver(ResolveResult([server.localEndpoint.address], HostName("example.test"), ResolverSource.Static))
    HttpClient.builder().resolver(resolver).tls(material).resourceLimits(limits(cap, cap)).requestTimeout(10 * Duration.second).build()
}
func drain(response: HttpResponse): String {
    try {
        let bytes = Array<Byte>(512, repeat: 0u8)
        var result = ""
        while (true) {
            let n = response.body.read(bytes)
            if (n == 0) { break }
            require(result.size + n <= 4096)
            result += String.fromUtf8(bytes[..n])
        }
        result
    } finally { response.close() }
}
func failed(client: HttpClient, url: String, operation: OperationContext): ?api.NetworkErrorCode {
    try { let response = client.get(url, context: operation); response.close(); None<api.NetworkErrorCode> }
    catch (error: api.NetworkException) { Some(error.code) }
}
func cancelled(code: ?api.NetworkErrorCode): Bool {
    match (code) { case Some(api.NetworkErrorCode.Cancelled) => true; case _ => false }
}
func selfCheck(cert: Array<Byte>, key: Array<Byte>, untrusted: Array<Byte>): Unit {
    rejectsUnknownOptions()
    let material = HttpServerTlsConfig([cert], key)
    let trust = HttpClientTlsConfig([cert])
    let identity = HttpClientTlsConfig([cert], clientCertificateChainDer: [cert], clientPrivateKeyPkcs8Der: key)
    let badTrust = HttpClientTlsConfig([untrusted])
    let handler = ServiceHandler(10000)
    let server = try { serverFor(handler, material, 0u16, 4, 4) }
        catch (error: Exception) { material.close(); trust.close(); identity.close(); badTrust.close(); throw error }
    let client = try { clientFor(server, trust) }
        catch (error: Exception) { server.close(); material.close(); trust.close(); identity.close(); badTrust.close(); throw error }
    let serving: Future<Unit> = spawn { server.serve() }
    let base = "https://example.test:${server.localEndpoint.port}"
    try {
        let distrust = clientFor(server, badTrust)
        try {
            var rejected = false
            try { let response = distrust.get("${base}/download", context: context()); response.close() }
            catch (error: api.NetworkException) {
                rejected = match (error.phase) { case api.NetworkPhase.TlsHandshake => true; case _ => false }
            }
            require(rejected); check("untrusted_rejected")
        } finally { distrust.close() }
        require(drain(client.get("${base}/download", context: context())) == "download")
        waitFor({ => server.resourceSnapshot().activeRequests == 0 })
        let owners = ArrayList<HttpClient>()
        let sessions = ArrayList<SseSession>()
        try {
            for (_ in 0..4) {
                let admitted = clientFor(server, trust); owners.add(admitted)
                let held = SseSession.eventSource(admitted, HttpUrl.parse("${base}/hold"), context: context())
                sessions.add(held); require(held.receive().isSome())
            }
            let live = server.resourceSnapshot()
            require(live.activeRequests == 4 && live.activeStreams == 4 && live.owners.size > 0)
            println("RESOURCE service_server_live requests=${live.activeRequests} streams=${live.activeStreams} owners=${live.owners.size}")
            let extra = clientFor(server, trust); owners.add(extra)
            var refused = false
            try { let response = extra.sendOnce(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/download")), context: context(ms: 1000)); response.close() }
            catch (error: HttpException) {
                refused = match (error.code) { case HttpErrorCode.StreamReset => true; case HttpErrorCode.ServerOverloaded => true; case HttpErrorCode.InvalidResponse => true; case _ => false }
            }
            catch (error: api.NetworkException) {
                refused = match (error.code) { case api.NetworkErrorCode.ResourceExhausted => true; case _ => false }
            }
            println("RESOURCE service_overload requests=${server.resourceSnapshot().activeRequests} streams=${server.resourceSnapshot().activeStreams}")
            require(refused && server.resourceSnapshot().activeRequests == 4 && server.resourceSnapshot().activeStreams == 4)
            check("server_capacity")
        } finally {
            for (session in sessions) { session.close() }
            for (owner in owners) { owner.close() }
        }
        waitFor({ => server.resourceSnapshot().activeRequests == 0 })
        require(drain(client.send(HttpRequest(HttpMethod("POST"), HttpUrl.parse("${base}/upload"),
            body: RequestBody.string("upload")), context: context())) == "6")
        let stream = SseSession.eventSource(client, HttpUrl.parse("${base}/stream"), context: context())
        try {
            require(stream.receive().getOrThrow().data == "chunk")
            require(stream.receive().getOrThrow().data == "complete")
            require(stream.receive().isNone())
        } finally { stream.close() }
        require(handler.uploads.load() == 6); check("success")
        let pre = CancellationSource(); pre.cancel()
        require(cancelled(failed(client, "${base}/download", context().withCancellation(pre.token)))); check("pre_cancel")
        let active = CancellationSource()
        let session = SseSession.eventSource(client, HttpUrl.parse("${base}/hold"), context: context().withCancellation(active.token))
        try {
            require(session.receive().getOrThrow().data == "chunk")
            let pending = spawn {
                try { let _ = session.receive(); false }
                catch (error: api.NetworkException) { cancelled(Some(error.code)) }
            }
            active.cancel(); require(pending.get(3 * Duration.second))
        } finally { session.close() }
        check("active_cancel")
        let timed = SseSession.eventSource(client, HttpUrl.parse("${base}/hold"), context: context(ms: 250))
        try {
            require(timed.receive().isSome())
            var deadline = false
            try { let _ = timed.receive() }
            catch (error: api.NetworkException) {
                deadline = match (error.code) { case api.NetworkErrorCode.TimedOut => true; case _ => false }
            }
            require(deadline)
        } finally { timed.close() }
        check("deadline")
        budgetRouteExpiry(material, trust); check("budget_route_expiry")
        let capacity = clientFor(server, trust, cap: 1)
        try {
            let held = SseSession.eventSource(capacity, HttpUrl.parse("${base}/hold"), context: context())
            try {
                require(held.receive().isSome())
                let row = capacity.resourceSnapshot()
                require(row.activeRequests == 1 && row.activeStreams == 1)
                println("RESOURCE service_live requests=${row.activeRequests} streams=${row.activeStreams} buffers=${row.managedBufferBytes}")
                let stopWaiters = CancellationSource()
                let waiting = Array<Future<Bool>>(4, { _ => spawn {
                    cancelled(failed(capacity, "${base}/download", context().withCancellation(stopWaiters.token)))
                } })
                waitFor({ => capacity.resourceSnapshot().admissionWaiters == 4 })
                var exhausted = false
                try { let response = capacity.get("${base}/download", context: context(ms: 250)); response.close() }
                catch (error: api.NetworkException) {
                    exhausted = match (error.code) { case api.NetworkErrorCode.ResourceExhausted => true; case _ => false }
                }
                catch (error: HttpException) {
                    exhausted = match (error.code) { case HttpErrorCode.PoolExhausted => true; case _ => false }
                }
                require(exhausted)
                stopWaiters.cancel()
                for (pending in waiting) { require(pending.get(3 * Duration.second)) }
            } finally { held.close() }
        } finally { capacity.close() }
        check("capacity")
        let closed = SseSession.eventSource(client, HttpUrl.parse("${base}/hold"), context: context())
        require(closed.receive().isSome()); closed.close(); require(closed.isClosed()); check("explicit_close")
        let peer = clientFor(server, trust)
        let disconnected = SseSession.eventSource(peer, HttpUrl.parse("${base}/hold"), context: context())
        try { require(disconnected.receive().isSome()); peer.close(); require(peer.isClosed()) }
        finally { disconnected.close(); peer.close() }
        waitFor({ => handler.producers.load() == 0 }); check("peer_disconnect")
        let old = spawn { client.get("${base}/graceful", context: context()) }
        waitFor({ => handler.graceful.entered.load() })
        require(rotate(server, cert, key, false) == 2u64)
        let fresh = clientFor(server, trust)
        try { require(drain(fresh.get("${base}/download", context: context())) == "download") }
        finally { fresh.close() }
        require(server.tlsGeneration() == 2u64)
        handler.graceful.released.store(true)
        require(drain(old.get(3 * Duration.second)) == "download" && !handler.graceful.cancelled.load())
        check("ordinary_rotation")
        let secured = clientFor(server, trust)
        try {
            let obsolete = spawn {
                try { let response = secured.sendOnce(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/security")), context: context()); response.close(); false }
                catch (error: api.NetworkException) {
                    match (error.code) { case api.NetworkErrorCode.Cancelled => true; case api.NetworkErrorCode.ConnectionReset => true; case api.NetworkErrorCode.UnexpectedEof => true; case api.NetworkErrorCode.Closed => true; case _ => false }
                }
                catch (error: HttpException) {
                    match (error.code) { case HttpErrorCode.StreamReset => true; case HttpErrorCode.ConnectionGoAway => true; case HttpErrorCode.InvalidResponse => true; case HttpErrorCode.ProtocolViolation => true; case _ => false }
                }
            }
            waitFor({ => handler.security.entered.load() })
            require(rotate(server, cert, key, true) == 3u64)
            require(obsolete.get(3 * Duration.second)); waitFor({ => handler.security.cancelled.load() })
            check("security_cancel")
        } finally { secured.close() }
        let anonymous = clientFor(server, trust)
        let before = handler.admissions.load()
        try {
            var rejected = false
            try { let response = anonymous.sendOnce(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/download")), context: context()); response.close() }
            catch (error: api.TlsEngineException) {
                rejected = match (error.tlsCode) { case api.TlsEngineErrorCode.PeerAlert => true; case api.TlsEngineErrorCode.ClientCertificateRequired => true; case _ => false }
            }
            catch (error: api.NetworkException) {
                rejected = match (error.code) { case api.NetworkErrorCode.UnexpectedEof => true; case api.NetworkErrorCode.ConnectionReset => true; case api.NetworkErrorCode.BrokenPipe => true; case api.NetworkErrorCode.SystemFailure => match (error.phase) { case api.NetworkPhase.TlsRead => true; case api.NetworkPhase.TlsWrite => true; case api.NetworkPhase.TlsHandshake => true; case api.NetworkPhase.TcpWrite => true; case _ => false }; case _ => false }
            }
            catch (error: HttpException) {
                rejected = match (error.code) { case HttpErrorCode.InvalidResponse => true; case HttpErrorCode.ConnectionGoAway => true; case HttpErrorCode.StreamReset => true; case HttpErrorCode.ProtocolViolation => true; case _ => false }
            }
            require(rejected && handler.admissions.load() == before)
        } finally { anonymous.close() }
        let authenticated = clientFor(server, identity)
        try {
            require(drain(authenticated.get("${base}/download", context: context())) == "download")
            check("security_rotation")
            let held = spawn { authenticated.get("${base}/drain", context: context()) }
            waitFor({ => handler.draining.entered.load() })
            let shutdownDone = AtomicBool(false)
            let shutdown = spawn { let result = server.shutdown(context: context()); shutdownDone.store(true); result }
            waitFor({ => server.isClosed() })
            let late = clientFor(server, identity)
            try {
                var rejected = false
                try { let response = late.sendOnce(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/download")), context: context(ms: 1000)); response.close() }
                catch (error: api.NetworkException) {
                    rejected = match (error.code) { case api.NetworkErrorCode.ConnectRefused => true; case api.NetworkErrorCode.SystemFailure => match (error.phase) { case api.NetworkPhase.TcpConnect => true; case _ => false }; case _ => false }
                }
                require(rejected)
            } finally { late.close() }
            require(!handler.draining.released.load() && !shutdownDone.load())
            let draining = server.resourceSnapshot()
            require(draining.activeRequests == 1 && draining.activeStreams == 1)
            println("RESOURCE service_draining requests=${draining.activeRequests} streams=${draining.activeStreams}")
            handler.draining.released.store(true)
            require(drain(held.get(3 * Duration.second)) == "download")
            authenticated.close(); client.close()
            require(shutdown.get(3 * Duration.second).activeAtReturn == 0)
            serving.get(3 * Duration.second); clean(server, handler); check("graceful_stop")
        } finally { authenticated.close() }
        check("unknown_option")
        check("cleanup"); println("APP_ACCEPTANCE_PASS")
    } finally {
        handler.graceful.released.store(true); handler.security.released.store(true); handler.draining.released.store(true)
        client.close(); server.close(); material.close(); trust.close(); identity.close(); badTrust.close()
    }
}
func command(): String {
    let one = Array<Byte>(1, repeat: 0u8)
    let line = Array<Byte>(512, repeat: 0u8)
    var count: Int64 = 0
    while (Console.stdIn.read(one) != 0) {
        if (one[0] == 10u8) { return String.fromUtf8(line[..count]) }
        require(count < line.size); line[count] = one[0]; count++
    }
    "stop"
}
let OPTION_NAMES = ["--port", "--certificate", "--key", "--max-requests", "--max-streams", "--budget-ms"]
func parseServeOptions(args: Array<String>): HashMap<String, String> {
    // Every argument is consumed exactly once. An unknown, repeated or dangling option fails
    // closed instead of silently falling back to a default resource limit.
    let parsed = HashMap<String, String>()
    var index: Int64 = 1
    while (index < args.size) {
        let flag = args[index]
        if (!OPTION_NAMES.contains(flag)) { throw IllegalArgumentException("unknown service option") }
        if (parsed.contains(flag)) { throw IllegalArgumentException("repeated service option") }
        if (index + 1 >= args.size) { throw IllegalArgumentException("dangling service option") }
        parsed[flag] = args[index + 1]
        index += 2
    }
    parsed
}
func option(args: HashMap<String, String>, name: String, fallback: String): String {
    match (args.get(name)) { case Some(value) => value; case None => fallback }
}
func serve(args: Array<String>): Unit {
    let options = parseServeOptions(args)
    let cert = materialBytes(option(options, "--certificate", ""))
    let key = materialBytes(option(options, "--key", ""))
    let budget = Int64.parse(option(options, "--budget-ms", "10000")); require(budget > 0 && budget <= 600000)
    let material = HttpServerTlsConfig([cert], key)
    let handler = ServiceHandler(budget)
    let server = try { serverFor(handler, material, UInt16.parse(option(options, "--port", "8443")),
        Int64.parse(option(options, "--max-requests", "16")), Int64.parse(option(options, "--max-streams", "16"))) }
        catch (error: Exception) { material.close(); throw error }
    let serving: Future<Unit> = spawn { server.serve() }
    try {
        println("SERVICE_READY port=${server.localEndpoint.port}"); Console.stdOut.flush()
        while (true) {
            let line = command()
            if (line == "stop") { break }
            let words = line.split(" ")
            require(words.size == 3 && (words[0] == "rotate" || words[0] == "secure-rotate"))
            let generation = rotate(server, materialBytes(words[1]), materialBytes(words[2]), words[0] == "secure-rotate")
            println("ROTATED generation=${generation}"); Console.stdOut.flush()
        }
        handler.graceful.released.store(true); handler.draining.released.store(true)
        require(server.shutdown(context: context(ms: budget)).activeAtReturn == 0)
        serving.get(budget * Duration.millisecond); clean(server, handler)
        println("SERVICE_STOPPED"); Console.stdOut.flush()
    } finally { server.close(); material.close() }
}
main(args: Array<String>): Int64 {
    try {
        if (args.size == 0 || args[0] == "--help") {
            println("serve --port N --certificate DER --key PKCS8 --max-requests N --max-streams N --budget-ms N")
            println("stdin: rotate DER PKCS8 | secure-rotate DER PKCS8 | stop")
            println("self-check certificateDER keyPKCS8DER untrustedDER")
            return 0
        }
        if (args[0] == "self-check") {
            require(args.size == 4); selfCheck(materialBytes(args[1]), materialBytes(args[2]), materialBytes(args[3]))
        } else { require(args[0] == "serve"); serve(args) }
        0
    } catch (_: IllegalArgumentException) {
        Console.stdErr.write("ERROR category=usage phase=option code=2\n".toArray()); 2
    }
    catch (_: Exception) { Console.stdErr.write("ERROR category=service phase=operation code=1\n".toArray()); 1 }
}
