package wirestack_m12_003_network

import std.env.{getVariable, getStdOut}
import std.convert.Parsable
import std.time.MonoTime
import std.sync.AtomicInt64
import wirestack as api
import wirestack.net.*
import wirestack.http.*

func require(ok: Bool, message: String): Unit { if (!ok) { throw Exception(message) } }
func announce(text: String): Unit { println(text); getStdOut().flush() }
func v4(): api.IpAddress { api.IpAddress(api.IpAddressFamily.Ipv4, [192u8,0u8,2u8,2u8]) }
func v6(): api.IpAddress { api.IpAddress(api.IpAddressFamily.Ipv6,
    [0x20u8,1u8,0x0du8,0xb8u8,0u8,0u8,0u8,0u8,0u8,0u8,0u8,0u8,0u8,0u8,0u8,2u8]) }
func owner(ms: Int64): api.OperationContext { api.OperationContext(deadline: Some(api.Deadline.after(ms * Duration.millisecond))) }
func elapsed(start: MonoTime): Int64 { (MonoTime.now() - start).toNanoseconds() / 1000000 }
func errorCode(error: Exception): String {
    match (error) {
        case e: api.NetworkException => match (e.code) {
            case api.NetworkErrorCode.TimedOut => "deadline"
            case api.NetworkErrorCode.Cancelled => "cancelled"
            case api.NetworkErrorCode.ConnectionReset => "reset"
            case api.NetworkErrorCode.SystemFailure => "system_failure"
            case _ => "network"
        }
        case _ => "other"
    }
}
func readOk(response: HttpResponse): Bool {
    let buffer = Array<Byte>(2, repeat: 0)
    var offset = 0i64
    while (offset < 2) {
        let part = Array<Byte>(2 - offset, repeat: 0)
        let count = response.body.read(part)
        if (count == 0) { return false }
        for (i in 0..count) { buffer[offset + i] = part[i] }
        offset += count
    }
    let tail = Array<Byte>(1, repeat: 0)
    buffer == "ok".toArray() && response.body.read(tail) == 0
}
class CountingConnector <: HttpConnector {
    let attempts = AtomicInt64(0)
    let cancellation: api.CancellationSource
    let cancelSecond: Bool
    let origin = MonoTime.now()
    let cancelledAtMs = AtomicInt64(-1)
    init(cancellation: api.CancellationSource, cancelSecond: Bool) {
        this.cancellation = cancellation; this.cancelSecond = cancelSecond
    }
    public func connect(endpoint: api.SocketEndpoint, context: OperationContext): api.DuplexTransport {
        let n = attempts.fetchAdd(1) + 1
        announce("ATTEMPT ${n}")
        if (cancelSecond && n == 2) { cancelledAtMs.store(elapsed(origin)); cancellation.cancel() }
        TcpStream.connect(endpoint, context: context)
    }
}
func runHttp(mode: String, port: UInt16): Unit {
    let cancellation = api.CancellationSource()
    let connector = CountingConnector(cancellation, mode == "multicandidate_cancel")
    let addresses = if (mode == "ipv6_blackhole") { [v6(),v4()] } else { [v4(),v6()] }
    let resolver = api.StaticResolver(api.ResolveResult(addresses, api.HostName("network.example.test"), api.ResolverSource.Static))
    let client = HttpClientBuilder().resolver(resolver).connector(connector)
        .retryPolicy(HttpRetryPolicy(maximumAttempts: 1)).build()
    let url = "http://network.example.test:${port}/"
    let start = MonoTime.now()
    var outcome = "success"
    try {
        try {
            let response = client.get(url, context: api.OperationContext(
                deadline: Some(api.Deadline.after(1500 * Duration.millisecond)), cancellation: cancellation.token))
            require(response.status == 200, "HTTP response status changed")
            require(readOk(response), "HTTP response payload changed")
            response.close()
        } catch (e: Exception) { outcome = errorCode(e) }
        let cancellationOvershoot = if (mode == "multicandidate_cancel") { elapsed(connector.origin) - connector.cancelledAtMs.load() } else { 0 }
        let duration = elapsed(start)
        if (mode == "multicandidate_cancel") {
            require(connector.attempts.load() >= 2 && outcome == "cancelled", "multi-candidate cancellation lost")
            require(elapsed(connector.origin) - connector.cancelledAtMs.load() <= 250, "candidate cancellation overshot")
        } else if (mode == "http_rst" || mode == "http_no_write") {
            require(outcome != "success", "faulted HTTP request succeeded")
            require((mode == "http_rst" && (outcome == "reset" || outcome == "system_failure")) || (mode == "http_no_write" && outcome == "deadline" && duration <= 1750), "HTTP fault identity/deadline changed")
            require(client.resourceSnapshot().activeConnections == 0, "failed connection returned to pool")
            announce("FAULT_COMPLETE")
            // The fixture answers the next accepted physical connection, not the failed one.
            let recovered = client.get(url, context: owner(3000))
            require(recovered.status == 200 && readOk(recovered), "new request did not recover")
            recovered.close()
            require(connector.attempts.load() == 2, "recovery reused unhealthy connection")
        } else { require(outcome == "success" && connector.attempts.load() >= 2, "IPv4 fallback failed") }
        announce("RESULT {\"outcome\":\"${outcome}\",\"duration_ms\":${duration},\"cancel_overshoot_ms\":${cancellationOvershoot},\"attempts\":${connector.attempts.load()},\"recovery\":true}")
    } finally { client.close() }
    let s = client.resourceSnapshot()
    require(s.activeConnections == 0 && s.reservedConnections == 0 && s.activeRequests == 0 && s.activeStreams == 0 && s.managedBufferBytes == 0 && s.owners.size == 0 && s.admissionWaiters == 0,
        "HTTP counters did not reclaim")
    announce("CLEANUP {\"connections\":${s.activeConnections},\"requests\":${s.activeRequests},\"streams\":${s.activeStreams},\"buffers\":${s.managedBufferBytes},\"owners\":${s.owners.size},\"waiters\":${s.admissionWaiters}}")
}
func runDns(mode: String, port: UInt16): Unit {
    let config = DnsResolverConfig(nameservers: [api.SocketEndpoint(v4(), port)], hostsPath: "",
        queryTimeout: 5 * Duration.second, attempts: 1, cacheCapacity: 4)
    let dns = DnsClient(config: config)
    let start = MonoTime.now()
    var outcome = "success"
    try {
        try { let _ = dns.query("fault.example.test", DnsRecordType.A, context: owner(300)) }
        catch (e: api.ResolveException) {
            outcome = match (e.resolveCode) { case api.ResolveErrorCode.Timeout => "deadline"; case _ => "other" }
        }
        let duration = elapsed(start)
        require(outcome == "deadline" && duration <= 550, "DNS absolute deadline overshot")
        announce("FAULT_COMPLETE")
        let answer = dns.query("recovery.example.test", DnsRecordType.A, context: owner(3000))
        require(answer.answerCount == 1 && answer.records[0].data() == [192u8,0u8,2u8,2u8], "late DNS answer poisoned recovery")
        announce("RESULT {\"outcome\":\"${outcome}\",\"duration_ms\":${duration},\"recovery\":true}")
    } finally { dns.close() }
    require(dns.isClosed(), "DNS owner remained open")
    announce("CLEANUP {\"dns_closed\":true}")
}
func runTcp(mode: String, port: UInt16): Unit {
    let stream = TcpStream.connect(api.SocketEndpoint(v4(), port), options: [SocketOption.SendBuffer(4096)], context: owner(3000))
    let bytes = Array<Byte>(65536, repeat: 97)
    var outcome = "success"
    var transferred = 0i64
    let start = MonoTime.now()
    try {
        if (mode == "peer_no_read") {
            let context = owner(500)
            try { while (transferred < 64 * 1024 * 1024) { transferred += stream.writeSome(api.ByteSpan(bytes), context: context) } }
            catch (e: Exception) { outcome = errorCode(e) }
            require(outcome == "deadline" && transferred > 0 && transferred < 64 * 1024 * 1024, "write backpressure was not bounded")
        } else {
            let _ = stream.writeSome(api.ByteSpan([1u8]), context: owner(3000))
            try {
                match (stream.readSome(api.MutableByteSpan(bytes, length: 1), context: owner(500))) {
                    case api.ReadResult.Data(n) => transferred = n
                    case _ => outcome = "eof"
                }
            } catch (e: Exception) { outcome = errorCode(e) }
            if (mode == "echo" || mode == "delay_loss") { require(transferred == 1 && bytes[0] == 1, "echo bytes changed") }
            else if (mode == "rst") { require(outcome == "reset" || outcome == "system_failure", "RST collapsed into timeout/EOF") }
            else { require(outcome == "deadline", "silent peer did not respect deadline") }
        }
        require(elapsed(start) <= 800, "transport deadline overshot")
        announce("RESULT {\"outcome\":\"${outcome}\",\"duration_ms\":${elapsed(start)},\"transferred\":${transferred}}")
    } finally { stream.close() }
    require(stream.isClosed(), "native TCP owner remained open")
    announce("CLEANUP {\"stream_closed\":true}")
}
func runNetem(port: UInt16): Unit {
    let context = owner(3000)
    let start = MonoTime.now()
    var stream = None<TcpStream>
    var transferred = 0i64
    var outcome = "success"
    try {
        try {
            let native = TcpStream.connect(api.SocketEndpoint(v4(), port), context: context)
            stream = Some(native)
            let bytes = Array<Byte>(1, repeat: 0)
            let expected = UInt8.parse(getVariable("WIRESTACK_NETWORK_BYTE").getOrThrow())
            for (_ in 0..16) {
                require(native.writeSome(api.ByteSpan([expected]), context: context) == 1, "netem write changed")
                match (native.readSome(api.MutableByteSpan(bytes), context: context)) {
                    case api.ReadResult.Data(n) => require(n == 1 && bytes[0] == expected, "netem bytes changed"); transferred += n
                    case _ => throw Exception("netem stream unexpectedly ended")
                }
            }
        } catch (e: api.NetworkException) { outcome = errorCode(e); require(outcome == "deadline", "netem failure lost deadline identity") }
        require(elapsed(start) <= 3250, "netem deadline overshot")
        require(outcome == "success" && transferred == 16, "original response did not recover through TCP retransmission")
        announce("RESULT {\"outcome\":\"${outcome}\",\"duration_ms\":${elapsed(start)},\"transferred\":${transferred}}")
    } finally { if (let Some(native) <- stream) { native.close(); require(native.isClosed(), "netem socket cleanup") } }
    announce("CLEANUP {\"operation_complete\":true}")
}
func runSystemBoundary(): Unit {
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
    try {
    let deadlines = AtomicInt64(0)
    let start = MonoTime.now()
    let first: Future<Unit> = spawn {
        try { let _ = resolver.resolve(api.HostName("localhost"), context: owner(300)) }
        catch (e: api.ResolveException) {
            require(errorCode(e) == "deadline", "system resolver did not time out")
            let _ = deadlines.fetchAdd(1)
        }
    }
    let admission = owner(2000)
    while (resolver.resolverResourceSnapshot().runningWork != 1) {
        require(!admission.isDeadlineExceeded(), "native resolver work did not enter")
        sleep(Duration.millisecond)
    }
    let callers = Array<Future<Unit>>(8, { _ => spawn {
        try { let _ = resolver.resolve(api.HostName("localhost"), context: owner(300)) }
        catch (_: api.ResolveException) { () }
    } })
    first.get(2 * Duration.second)
    let duration = elapsed(start)
    require(duration <= 550, "system resolver caller deadline overshot")
    let abandoned = resolver.resolverResourceSnapshot()
    require(deadlines.load() == 1 && abandoned.runningWork == 1 && abandoned.queuedQueries <= 1,
        "synchronous SDK boundary or bounded admission changed")
    for (caller in callers) { caller.get(2 * Duration.second) }
    let reclaim = owner(3000)
    while (resolver.resolverResourceSnapshot().activeQueries != 0 || resolver.resolverResourceSnapshot().runningWork != 0) {
        require(!reclaim.isDeadlineExceeded(), "abandoned native resolver work was not reclaimed")
        sleep(Duration.millisecond)
    }
    let finalSample = resolver.resolverResourceSnapshot()
    require(finalSample.rejectedQueries > 0 && finalSample.queuedQueries == 0, "resolver admission was not bounded")
    resolver.close()
    announce("RESULT {\"outcome\":\"deadline\",\"duration_ms\":${duration},\"abandoned_running_work\":${abandoned.runningWork},\"rejected_queries\":${finalSample.rejectedQueries},\"recovery\":true}")
    announce("CLEANUP {\"active_queries\":${finalSample.activeQueries},\"running_work\":${finalSample.runningWork},\"queued_queries\":${finalSample.queuedQueries},\"resolver_closed\":${resolver.isClosed()}}")
    } finally { resolver.close() }
}
func warmup(): Unit {
    let context = owner(2000)
    let listener = TcpListener.bind(api.SocketEndpoint(v4(), 0), context: context)
    var client = None<TcpStream>
    var peer = None<TcpStream>
    try {
        let left = TcpStream.connect(listener.localEndpoint, context: context)
        client = Some(left)
        let right = listener.accept(context: context)
        peer = Some(right)
        require(left.writeSome(api.ByteSpan([1u8]), context: context) == 1, "warmup write")
        let buffer = Array<Byte>(1, repeat: 0)
        match (right.readSome(api.MutableByteSpan(buffer), context: context)) {
            case api.ReadResult.Data(n) => require(n == 1 && buffer[0] == 1, "warmup bytes")
            case _ => throw Exception("warmup EOF")
        }
    } finally {
        if (let Some(value) <- client) { value.close() }
        if (let Some(value) <- peer) { value.close() }
        listener.close()
    }
}
main(): Int64 {
    let mode = getVariable("WIRESTACK_NETWORK_MODE").getOrThrow()
    let port = UInt16.parse(getVariable("WIRESTACK_NETWORK_PORT").getOrThrow())
    warmup()
    announce("BASELINE")
    require(readln() == "continue", "fault barrier was not acknowledged")
    if (mode == "system_resolver_boundary") { runSystemBoundary() }
    else if (mode.startsWith("dns_")) { runDns(mode, port) }
    else if (mode.startsWith("http_") || mode == "ipv6_blackhole" || mode == "multicandidate_cancel") { runHttp(mode, port) }
    else if (mode == "delay_loss") { runNetem(port) }
    else { runTcp(mode, port) }
    announce("RECLAIMED")
    require(readln() == "finish", "reclamation barrier was not acknowledged")
    0
}
