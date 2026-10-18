package wirestack_m12_003_resources

import std.collection.ArrayList
import std.convert.Parsable
import std.env.getStdOut
import std.fs.File
import std.sync.*
import std.time.MonoTime
import wirestack as api
import wirestack.http.*
import wirestack.net.*

foreign func resource_fd_limit(): Int64
foreign func resource_fd_exhaust(): Int64
foreign func resource_fd_release(): Unit
foreign func resource_burn(): Int64

func require(ok: Bool, message: String): Unit { if (!ok) { throw IllegalStateException(message) } }
func announce(line: String): Unit { println(line); getStdOut().flush() }
func context(ms!: Int64 = 5000, token!: api.CancellationToken = api.CancellationToken.none()): OperationContext {
    OperationContext(deadline: Some(Deadline.after(ms * Duration.millisecond)), cancellation: token)
}
func until(predicate: () -> Bool): Unit {
    let end = Deadline.after(3 * Duration.second)
    while (!predicate()) { require(!end.isExpired(), "event did not occur"); sleep(Duration.millisecond) }
}
func ip(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func limits(kind: String): HttpResourceLimits {
    let requests: Int64 = if (kind == "requests") { 1 } else { 8 }
    let connections: Int64 = if (kind == "streams") { 2 } else { 1 }
    HttpResourceLimits(maximumConnections: connections, maximumConnectionsPerRoute: connections, maximumConnectionsPerOrigin: connections,
        maximumRequests: requests, maximumRequestsPerRoute: requests, maximumRequestsPerOrigin: requests,
        maximumStreams: 1, maximumStreamsPerRoute: 1, maximumStreamsPerOrigin: 1,
        maximumManagedBufferBytes: 262144u64, reservedControlBufferBytes: 1024u64,
        maximumManagedBufferBytesPerRoute: 131072u64, maximumManagedBufferBytesPerOrigin: 131072u64,
        maximumWaiters: 1, maximumOwners: 1)
}
func snapshot(client: HttpClient, phase: String): Unit {
    let s = client.resourceSnapshot(); let p = client.observationSnapshot().pools
    announce("LEDGER ${phase} connections=${s.activeConnections} reserved_connections=${s.reservedConnections} requests=${s.activeRequests} streams=${s.activeStreams} reserved_streams=${s.reservedStreams} buffers=${s.managedBufferBytes} owners=${s.owners.size} waiters=${s.admissionWaiters} pool_waiters=${p.queuedRequests} rejected=${s.rejectedOperations}")
}
func zero(client: HttpClient): Unit {
    until { => let s = client.resourceSnapshot(); s.activeConnections == 0 && s.reservedConnections == 0 &&
        s.activeRequests == 0 && s.activeStreams == 0 && s.reservedStreams == 0 && s.managedBufferBytes == 0u64 &&
        s.owners.isEmpty() && s.admissionWaiters == 0 && client.observationSnapshot().pools.queuedRequests == 0 }
    snapshot(client, "after")
}
func networkCode(error: Exception): api.NetworkErrorCode {
    match (error) {
        case value: api.NetworkException => value.code
        case value: HttpException => networkCode(value.cause.getOrThrow())
        case _ => throw error
    }
}
func failed(action: () -> Unit, expected: String): Unit {
    var caught = false
    try { action() } catch (error: Exception) {
        let code = networkCode(error)
        let actual = match (code) {
            case api.NetworkErrorCode.ResourceExhausted => "resource_exhausted"
            case api.NetworkErrorCode.Cancelled => "cancelled"
            case api.NetworkErrorCode.TimedOut => "deadline"
            case api.NetworkErrorCode.SystemFailure => "native_failure"
            case _ => "unexpected_code"
        }
        require(actual == expected, "wrong structured result: ${actual}, expected ${expected}")
        caught = true; announce("RESULT ${expected}")
    }
    require(caught, "fault unexpectedly succeeded")
}
class Handler <: HttpServerHandler {
    public func handle(_: HttpServerRequest, _: OperationContext): HttpServerResponse {
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("recovered").open()),
            headers: HttpHeaders.builder().add("Content-Length", "9").build()))
    }
}
func consume(response: HttpResponse): Unit {
    try { let bytes = Array<Byte>(32, repeat: 0u8); var total: Int64 = 0; var n = response.body.read(bytes)
        while (n != 0) { total += n; n = response.body.read(bytes) }
        require(response.status == 200 && total == 9, "recovery response was not complete")
    } finally { response.close() }
}
func buffers(): Unit {
    let client = HttpClient.builder().resourceLimits(limits("buffers")).build()
    let url = HttpUrl.parse("http://example.test/")
    snapshot(client, "before")
    let held = client.reserveResponseBuffer(url, 131072u64, context: context())
    try {
        snapshot(client, "during"); require(client.resourceSnapshot().managedBufferBytes == 131072u64, "buffer quota not occupied")
        let cancel = api.CancellationSource()
        let waiter = spawn { failed({ => let r = client.reserveResponseBuffer(url, 1u64, context: context(token: cancel.token)); r.close() }, "cancelled") }
        try {
            until { => client.resourceSnapshot().admissionWaiters == 1 }
            snapshot(client, "queued")
            failed({ => let r = client.reserveResponseBuffer(url, 1u64, context: context()); r.close() }, "resource_exhausted")
        } finally { let started = MonoTime.now(); cancel.cancel(); waiter.get(3 * Duration.second)
            announce("CANCELLATION elapsed_ns=${(MonoTime.now()-started).toNanoseconds()}") }
        failed({ => let r = client.reserveResponseBuffer(HttpUrl.parse("http://other.test/"), 1u64, context: context()); r.close() }, "resource_exhausted")
        let started = MonoTime.now()
        failed({ => let r = client.reserveResponseBuffer(url, 1u64, context: context(ms: 100)); r.close() }, "deadline")
        announce("DEADLINE elapsed_ns=${(MonoTime.now()-started).toNanoseconds()} budget_ns=100000000")
    } finally { held.close() }
    let recovered = client.reserveResponseBuffer(url, 131072u64, context: context())
    require(client.resourceSnapshot().managedBufferBytes == 131072u64, "post-release admission failed")
    recovered.close(); client.close(); zero(client)
    announce("CHECK buffers_waiters_owners PASS")
}
func exchanges(kind: String, certificate: String, key: String): Unit {
    let serverTls = HttpServerTlsConfig([File.readFrom(certificate)], File.readFrom(key))
    let builder = HttpServer.builder().listen(SocketEndpoint(ip(), 0u16)).handler(Handler())
    if (kind == "streams") { builder.tls(serverTls) }
    let server = builder.build(); let serving = spawn { server.serve() }
    let clientBuilder = HttpClient.builder().resourceLimits(limits(kind))
    let clientTls = HttpClientTlsConfig([File.readFrom(certificate)])
    if (kind == "streams") { clientBuilder.tls(clientTls) }
    let client = clientBuilder.build()
    let url = "${if (kind == "streams") { "https" } else { "http" }}://127.0.0.1:${server.localEndpoint.port}/"
    try {
        snapshot(client, "before")
        let held = client.get(url, context: context())
        try {
            if (kind == "streams") { require(held.version == HttpVersion.Http2, "H2 was not negotiated"); require(client.resourceSnapshot().activeStreams == 1, "stream not active") }
            require(client.resourceSnapshot().activeRequests == 1, "request not retained")
            snapshot(client, "during")
            let cancel = api.CancellationSource()
            let waiter = spawn { failed({ => consume(client.get(url, context: context(token: cancel.token))) }, "cancelled") }
            try {
                until { => let s = client.observationSnapshot(); s.resources.admissionWaiters > 0 || s.pools.queuedRequests > 0 }
                snapshot(client, "queued")
            } finally { let started = MonoTime.now(); cancel.cancel(); waiter.get(3 * Duration.second)
                announce("CANCELLATION elapsed_ns=${(MonoTime.now()-started).toNanoseconds()}") }
            let started = MonoTime.now()
            failed({ => consume(client.get(url, context: context(ms: 100))) }, "deadline")
            announce("DEADLINE elapsed_ns=${(MonoTime.now()-started).toNanoseconds()} budget_ns=100000000")
        } finally { held.close() }
        consume(client.get(url, context: context())); announce("RECOVERY complete=true")
    } finally {
        client.close(); zero(client)
        let _ = server.shutdown(context: context()); serving.get(5 * Duration.second)
        server.close(); serverTls.close(); clientTls.close()
    }
    announce("CHECK ${kind} PASS")
}
func resolver(port: UInt16): Unit {
    let dns = DnsClient(config: DnsResolverConfig(nameservers: [SocketEndpoint(ip(), port)], hostsPath: "", attempts: 1,
        cacheCapacity: 0, queryTimeout: 5 * Duration.second), workerCount: 1, queueCapacity: 1)
    try { resolverChecks(dns) } finally { dns.close() }
}
func resolverChecks(dns: DnsClient): Unit {
    let cancel = api.CancellationSource()
    let first = spawn { dnsFailure(dns, "hold.example.test", context(token: cancel.token), "cancelled") }
    var queued = None<Future<Unit>>
    try {
        until { => dns.resolverResourceSnapshot().activeQueries == 1 }
        queued = Some(spawn { dnsFailure(dns, "queued.example.test", context(ms: 150), "deadline") })
        until { => dns.resolverResourceSnapshot().queuedQueries == 1 }
        let s = dns.resolverResourceSnapshot()
        announce("DNS during active=${s.activeQueries} queued=${s.queuedQueries} running=${s.runningWork}")
        dnsFailure(dns, "overflow.example.test", context(), "refused")
        queued.getOrThrow().get(3 * Duration.second)
    } finally { cancel.cancel(); first.get(3 * Duration.second) }
    let result = dns.query("recover.example.test", DnsRecordType.A, context: context())
    require(result.answerCount == 1, "DNS recovery not answered")
    until { => let s = dns.resolverResourceSnapshot(); s.activeQueries == 0 && s.queuedQueries == 0 && s.runningWork == 0 }
    let s = dns.resolverResourceSnapshot(); require(s.rejectedQueries == 1, "DNS overflow rejection not accounted")
    announce("DNS after active=${s.activeQueries} queued=${s.queuedQueries} running=${s.runningWork} rejected=${s.rejectedQueries}")
    announce("CHECK resolver PASS")
}
func dnsFailure(dns: DnsClient, name: String, ctx: OperationContext, expected: String): Unit {
    var caught = false
    try { let _ = dns.query(name, DnsRecordType.A, context: ctx) } catch (error: api.ResolveException) {
        let actual = match (error.resolveCode) {
            case api.ResolveErrorCode.Cancelled => "cancelled"
            case api.ResolveErrorCode.Timeout => "deadline"
            case api.ResolveErrorCode.TemporaryFailure => "refused"
            case _ => "wrong"
        }
        require(actual == expected, "wrong DNS classification: ${actual}, expected ${expected}"); caught = true
    }
    require(caught, "DNS exhaustion succeeded")
}
func lowFd(): Unit {
    require(unsafe { resource_fd_limit() } == 64, "effective lowFD limit was not 64")
    announce("LIMIT nofile=64")
    let held = unsafe { resource_fd_exhaust() }; require(held > 0, "EMFILE was not reached")
    announce("FAULT emfile=true held=${held}"); sleep(100 * Duration.millisecond)
    try { failed({ => let s = TcpListener.bind(SocketEndpoint(ip(), 0u16), context: context()); s.close() }, "native_failure") }
    finally { unsafe { resource_fd_release() } }
    let recovered = TcpListener.bind(SocketEndpoint(ip(), 0u16), context: context())
    recovered.close(); announce("CHECK low_fd PASS")
}
main(args: Array<String>): Int64 {
    try {
        require(args.size >= 1, "scenario required")
        announce("MARK before"); sleep(100 * Duration.millisecond)
        match (args[0]) {
            case "buffers" => buffers()
            case "requests" | "pool" | "streams" => exchanges(args[0], args[1], args[2])
            case "resolver" => resolver(UInt16.parse(args[1]))
            case "low_fd" => lowFd()
            case "cpu" => require(unsafe { resource_burn() } > 0, "CPU burn failed"); buffers(); announce("CHECK low_cpu PASS")
            case "memory" => buffers(); announce("CHECK low_memory PASS")
            case "memory_pressure" =>
                try {
                    let allocations = ArrayList<Array<Byte>>()
                    for (_ in 0..128) { allocations.add(Array<Byte>(4 * 1024 * 1024, repeat: 7u8)); announce("ALLOC bytes=${allocations.size * 4 * 1024 * 1024}") }
                    announce("CHECK memory_pressure_survived PASS")
                } catch (_: OutOfMemoryError) {
                    announce("RUNTIME_ERROR code=out_of_memory")
                    return 23
                }
            case _ => throw IllegalArgumentException("unknown scenario")
        }
        announce("MARK after"); sleep(100 * Duration.millisecond); return 0
    } catch (error: Exception) { eprintln(error.toString()); return 1 }
}
