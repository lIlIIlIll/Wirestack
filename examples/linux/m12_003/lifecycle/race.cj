package wirestack_m12_003_race

import std.fs.File
import std.sync.*
import std.time.MonoTime
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
    private var entries: Int64 = 0
    private var released = false
    private var cancelled = false

    func hold(operation: OperationContext): Unit {
        let registration = operation.cancellation.register { =>
            synchronized(mutex) { cancelled = true; changed.notifyAll() }
        }
        try {
            synchronized(mutex) {
                entered = true; entries++; changed.notifyAll()
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
    func waitEntries(count: Int64): Unit {
        let limit = Deadline.after(5 * Duration.second)
        synchronized(mutex) {
            while (entries < count) {
                require(!limit.isExpired(), "storm admission barrier expired")
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


func isCancelled(error: Exception): Bool {
    match (error) {
        case value: NetworkException => match (value.code) { case NetworkErrorCode.Cancelled => true; case _ => false }
        case value: HttpException => match (value.cause) { case Some(cause) => isCancelled(cause); case None => false }
        case _ => false
    }
}
func allZero(row: HttpResourceSnapshot): Bool {
    row.activeConnections == 0 && row.reservedConnections == 0 && row.activeRequests == 0 &&
    row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 &&
    row.admissionWaiters == 0 && row.owners.isEmpty()
}
func raceTerminal(error: Exception): String {
    if (isCancelled(error)) { return "Cancelled" }
    match (error) {
        case failure: HttpException => match (failure.code) {
            case HttpErrorCode.ConnectionGoAway => "ConnectionGoAway"
            case HttpErrorCode.StreamReset => "StreamReset"
            case _ => throw error
        }
        case _ => throw error
    }
}
main(args: Array<String>): Int64 {
    require(args.size == 3, "usage: race mode certificate.der key.pk8")
    let mode = args[0]
    let cert = File.readFrom(args[1])
    let serverTls = HttpServerTlsConfig([cert], File.readFrom(args[2]))
    let clientTls = HttpClientTlsConfig([cert])
    let handler = RotationHandler()
    let server = HttpServer.builder().listen(SocketEndpoint(
        IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16))
        .handler(handler).tls(serverTls).http2StreamLimit(32u32).build()
    let serving = spawn { server.serve() }
    let resolver = StaticResolver(ResolveResult([server.localEndpoint.address], HostName("example.test"), ResolverSource.Static))
    let client = HttpClient.builder().resolver(resolver).tls(clientTls)
        .retryPolicy(HttpRetryPolicy(maximumAttempts: 1)).requestTimeout(10 * Duration.second).build()
    let base = "https://example.test:${server.localEndpoint.port}"
    var completions: Int64 = 0
    var oldGeneration: UInt64 = 0u64
    var newGeneration: UInt64 = 0u64
    var latency: Int64 = 0
    var perOperation = ""
    var oldTerminal = "not_applicable"
    var newTerminal = "not_applicable"
    try {
        expectReady(client, base)
        if (mode == "cancel_storm") {
            let sources = Array<CancellationSource>(16, { _ => CancellationSource() })
            let finished = AtomicInt64(0)
            let started = Array<MonoTime>(16, repeat: MonoTime.now())
            let elapsed = Array<Int64>(16, repeat: 0)
            let pending = Array<Future<Bool>>(16, { index => spawn {
                try {
                    let response = client.get("${base}/graceful", context: context().withCancellation(sources[index].token))
                    response.close(); false
                } catch (error: Exception) { isCancelled(error) }
                finally { elapsed[index] = (MonoTime.now() - started[index]).toNanoseconds(); finished.fetchAdd(1) }
            } })
            try {
                handler.graceful.waitEntries(16)
                let start = MonoTime.now()
                let cancellations = Array<Future<Unit>>(16, { index => spawn { started[index] = MonoTime.now(); sources[index].cancel(); sources[index].cancel() } })
                for (task in cancellations) { task.get(5 * Duration.second) }
                for (task in pending) { require(task.get(5 * Duration.second), "storm terminal not typed Cancelled") }
                latency = (MonoTime.now() - start).toNanoseconds()
                completions = finished.load()
                require(completions == 16, "storm completion count differs")
                for (index in 0..16) {
                    require(elapsed[index] > 0, "missing operation cancellation latency")
                    perOperation += "${if (index > 0) { "," } else { "" }}${elapsed[index]}"
                }
                expectReady(client, base)
            } finally {
                for (source in sources) { source.cancel() }
                handler.graceful.release()
                for (task in pending) { task.get(5 * Duration.second) }
            }
        } else {
            let finished = AtomicInt64(0)
            let admitted = spawn { try { client.get("${base}/graceful") } finally { finished.fetchAdd(1) } }
            handler.graceful.waitEntered()
            oldGeneration = client.configurationSnapshot().tlsGeneration
            newGeneration = client.rotateTls(clientTls)
            require(newGeneration > oldGeneration, "new client generation not published")
            require(server.rotateTls(serverTls) == 2u64, "server new generation not published")
            expectReady(client, base)
            let newAdmitted = spawn { try { client.get("${base}/security") } finally { finished.fetchAdd(1) } }
            handler.security.waitEntered()
            require(client.configurationSnapshot().retainedGenerations >= 2, "old/new generations were not concurrently retained")
            let startGate = ExchangeGate()
            let shutdown = spawn { startGate.hold(context()); server.shutdown(context: context()) }
            let rotation = spawn {
                startGate.hold(context())
                try { client.rotateResolver(resolver); client.close() }
                finally { handler.graceful.release(); handler.security.release() }
            }
            startGate.waitEntries(2)
            let start = MonoTime.now(); startGate.release()
            try {
                rotation.get(5 * Duration.second)
                try {
                    let response = admitted.get(5 * Duration.second)
                    try { require(response.status == 204, "old generation completion differs"); oldTerminal = "Completed204" }
                    finally { response.close() }
                } catch (error: Exception) { oldTerminal = raceTerminal(error) }
                try {
                    let response = newAdmitted.get(5 * Duration.second)
                    try { require(response.status == 204, "new generation completion differs"); newTerminal = "Completed204" }
                    finally { response.close() }
                } catch (error: Exception) { newTerminal = raceTerminal(error) }
                require(shutdown.get(5 * Duration.second).activeAtReturn == 0, "race shutdown retained connections")
                completions = finished.load()
                perOperation = "${(MonoTime.now() - start).toNanoseconds()},${(MonoTime.now() - start).toNanoseconds()}"
                require(completions == 2, "race completion ledger differs")
                latency = (MonoTime.now() - start).toNanoseconds()
            } finally { handler.graceful.release(); handler.security.release(); client.close() }
        }
    } finally {
        handler.graceful.release(); handler.security.release(); client.close()
        try {
            require(server.shutdown(context: context()).activeAtReturn == 0, "shutdown retained connections")
            serving.get(5 * Duration.second)
        } finally { server.close(); serverTls.close(); clientTls.close() }
    }
    require(allZero(client.resourceSnapshot()) && allZero(server.resourceSnapshot()), "terminal ledger not zero")
    require(client.configurationSnapshot().retainedGenerations == 0, "terminal generations retained")
    println("{\"profile_id\":\"${mode}\",\"completion_count\":${completions},\"operation_ns\":${latency}," +
        "\"old_terminal\":\"${oldTerminal}\",\"new_terminal\":\"${newTerminal}\",\"cancel_operation_ns\":[${perOperation}],\"old_generation\":${oldGeneration},\"new_generation\":${newGeneration},\"terminal_owners\":0,\"terminal_buffers\":0,\"terminal_generations\":0,\"recovery\":true}")
    0
}
