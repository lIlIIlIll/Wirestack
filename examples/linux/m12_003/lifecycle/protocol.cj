package wirestack_m12_003_protocol

import std.fs.File
import std.time.MonoTime
import wirestack as api
import wirestack.http.*

func require(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}
func zero(row: HttpResourceSnapshot): Bool {
    row.activeConnections == 0 && row.reservedConnections == 0 && row.activeRequests == 0 &&
    row.activeStreams == 0 && row.reservedStreams == 0 && row.managedBufferBytes == 0u64 &&
    row.admissionWaiters == 0 && row.owners.isEmpty()
}
func consume(response: api.HttpResponse, expected: Int64, byte: Byte): Unit {
    let buffer = Array<Byte>(4096, repeat: 0u8)
    var count: Int64 = 0
    try {
        require(response.version == api.HttpVersion.Http2, "H2 negotiation missing")
        while (true) {
            let n = response.body.read(buffer)
            if (n == 0) { break }
            for (i in 0..n) { require(buffer[i] == byte, "body byte semantics differ") }
            count += n
        }
        require(count == expected, "body length differs")
    } finally { response.close() }
}
main(args: Array<String>): Int64 {
    require(args.size == 3, "usage: protocol mode certificate.der port")
    let mode = args[0]
    let tls = HttpClientTlsConfig([File.readFrom(args[1])])
    let resolver = api.StaticResolver(api.ResolveResult([
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])],
        api.HostName("example.test"), api.ResolverSource.Static))
    let client = HttpClient.builder().tls(tls).resolver(resolver)
        .retryPolicy(HttpRetryPolicy(maximumAttempts: 1)).requestTimeout(10 * Duration.second).build()
    let base = "https://example.test:${args[2]}"
    var elapsed: Int64 = 0
    var high: UInt64 = 0u64
    var terminal = "none"
    var sibling = None<api.HttpResponse>
    try {
        if (mode == "h2_slowconsumer") {
            let started = MonoTime.now()
            let response = client.get("${base}/slow")
            try {
                // The peer answers probe only after exhausting the slow DATA window.
                consume(client.get("${base}/probe"), 0, 80u8)
                let row = client.resourceSnapshot()
                high = row.managedBufferBytes
                require(high > 0u64 && high <= row.limits.maximumManagedBufferBytes,
                    "slow consumer storage not bounded")
                consume(response, 1048576, 83u8)
                elapsed = (MonoTime.now() - started).toNanoseconds()
            } finally { response.close() }
        } else {
            if (mode == "h2_streamscope") { sibling = Some(client.get("${base}/sibling")) }
            let started = MonoTime.now()
            try {
                let response = client.get("${base}/${if (mode == "h2_goaway") { "goaway" } else { "reset" }}")
                response.close()
                throw IllegalStateException("fault request unexpectedly succeeded")
            } catch (error: HttpException) {
                match (error.code) {
                    case HttpErrorCode.ConnectionGoAway =>
                        require(mode == "h2_goaway", "connection fault escaped stream scope")
                        terminal = "ConnectionGoAway"
                    case HttpErrorCode.StreamReset =>
                        require(mode == "h2_streamscope", "GOAWAY collapsed into stream reset")
                        terminal = "StreamReset"
                    case _ => throw error
                }
            }
            elapsed = (MonoTime.now() - started).toNanoseconds()
            if (let Some(response) <- sibling) { consume(response, 1, 72u8) }
            consume(client.get("${base}/healthy"), 1, 72u8)
        }
    } finally { if (let Some(response) <- sibling) { response.close() }; client.close(); tls.close() }
    require(zero(client.resourceSnapshot()), "terminal resource ledger not zero")
    println("{\"profile_id\":\"${mode}\",\"terminal_error\":\"${terminal}\",\"operation_ns\":${elapsed}," +
        "\"managed_buffer_bytes_at_fault\":${high},\"terminal_owners\":0,\"terminal_buffers\":0," +
        "\"terminal_requests\":0,\"terminal_streams\":0,\"completion_count\":1,\"recovery\":true}")
    0
}
