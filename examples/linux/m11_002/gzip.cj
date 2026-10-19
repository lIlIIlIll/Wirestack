package wirestack_m11_002_gzip
import std.fs.File
import std.sync.*
import std.time.MonoTime
import wirestack as api
import wirestack.http.*
import wirestack.gzip.*

func require(value: Bool, message: String): Unit { if (!value) { throw IllegalStateException(message) } }
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func context(): OperationContext { OperationContext(deadline: Some(Deadline.after(10 * Duration.second))) }
func member(): Array<Byte> { [
        31u8, 139u8, 8u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8, 255u8, 203u8, 72u8, 205u8, 201u8, 201u8, 87u8, 72u8, 175u8, 202u8, 44u8, 0u8, 0u8, 25u8, 106u8,
        210u8, 223u8, 10u8, 0u8, 0u8, 0u8
    ] }
// Fixed RFC1952 fixture: one MiB of ASCII a. No runtime compression dependency.
func largeMember(): Array<Byte> { [
        31u8, 139u8, 8u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 3u8, 237u8, 193u8, 49u8, 1u8, 0u8, 0u8, 0u8, 194u8, 160u8, 172u8, 235u8, 95u8, 194u8, 16u8,
        190u8, 64u8, 1u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8,
        0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 0u8, 124u8, 6u8, 114u8, 86u8, 205u8, 215u8, 0u8, 0u8, 16u8, 0u8
    ] }
class Handler <: HttpServerHandler {
    let negotiated = AtomicInt64(0)
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        if (request.target == "/ready") { return HttpServerResponse(HttpResponse(200, "OK", ResponseBody.empty())) }
        if (request.headers.getFirst("Accept-Encoding") == Some("gzip")) { negotiated.fetchAdd(1) }
        let wire = member()
        if (request.target == "/crc") { wire[wire.size - 8] ^= 1u8 }
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(wire).open()),
            headers: HttpHeaders.builder().add("Content-Encoding", "gzip").add("Content-Length", "30").add("ETag", "wire-only").build()))
    }
}
func clean(client: HttpClient): Unit {
    let end = Deadline.after(3 * Duration.second)
    while (true) {
        let state = client.observationSnapshot()
        if (state.resources.activeRequests == 0 && state.resources.activeStreams == 0 &&
            state.resources.reservedStreams == 0 && state.resources.managedBufferBytes == 0u64 &&
            state.resources.admissionWaiters == 0 && state.pools.queuedRequests == 0) {
            println("RESOURCE buffers=0 requests=0 streams=0 reserved_streams=0 admission_waiters=0 pool_waiters=0"); return
        }
        require(!end.isExpired(), "gzip owner leaked client resources"); sleep(Duration.millisecond)
    }
}
func native(client: HttpClient, base: String, version: HttpVersion, label: String): Unit {
    let ready = client.get("${base}/ready", context: context()); ready.close()
    let response = GzipClient(client).send(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}/gzip")), context: context())
    try {
        require(response.isDecoded && response.response.version == version, "native protocol/selection differs")
        require(response.wireHeaders.getFirst("Content-Encoding") == Some("gzip") && response.wireContentLength == Some(30), "wire metadata lost")
        require(!response.response.headers.contains("Content-Encoding") && !response.response.headers.contains("Content-Length") &&
            !response.response.headers.contains("ETag") && response.response.body.contentLength.isNone(), "wire metadata leaked into decoded representation")
        require(client.resourceSnapshot().managedBufferBytes >= GzipLimits().maximumRetainedBytes, "decoder lacks actual DATA reservation")
        let expected = "hello gzip".toArray(); let byte = Array<Byte>(1, repeat: 0u8); var offset: Int64 = 0
        while (response.response.body.read(byte) != 0) {
            require(offset < expected.size && byte[0] == expected[offset], "incremental decoded output differs"); offset++
        }
        require(offset == expected.size && response.integrityVerified && response.decodedBytes == 10 && response.encodedBytesRead == 30 && response.memberCount == 1, "validated EOF/counters differ")
        println("DECODE protocol=${label} encoded_bytes=${response.encodedBytesRead} decoded_bytes=${response.decodedBytes} members=${response.memberCount} verified=${response.integrityVerified}")
    } finally { response.close() }
    clean(client)
    for (path in ["/gzip", "/crc"]) {
        let limits = if (path == "/gzip") { GzipLimits(maximumDecodedBytes: 5) } else { GzipLimits() }
        let failed = GzipClient(client, limits: limits).send(HttpRequest(HttpMethod("GET"), HttpUrl.parse("${base}${path}")), context: context())
        var rejected = false
        try { let buffer = Array<Byte>(16, repeat: 0u8); while (failed.response.body.read(buffer) != 0) {} }
        catch (error: GzipException) {
            rejected = if (path == "/gzip") { error.code == GzipErrorCode.OutputLimit } else { error.code == GzipErrorCode.ChecksumMismatch }
        } finally { failed.close() }
        require(rejected && !failed.integrityVerified, "limit/CRC failure was accepted or mislabeled"); clean(client)
    }
    println("CHECK native_gzip_${label} PASS")
}
func benchmark(): Unit {
    let raw = Array<Byte>(1024 * 1024, repeat: b'a'); let wire = largeMember()
    let output = Array<Byte>(16384, repeat: 0u8)
    for (decoded in [false, true]) {
        let started = MonoTime.now(); var bytes: Int64 = 0; var checksum: Int64 = 0; var maxWork: Int64 = 0
        for (_ in 0..8) {
            let source = RequestBody.bytes(if (decoded) { wire } else { raw }).open()
            let codec = if (decoded) { Some(GzipBodyStream(source, context: context())) } else { None<GzipBodyStream> }
            let body: api.HttpBodyStream = match (codec) { case Some(value) => value; case None => source }
            try {
                while (true) {
                    let count = body.read(output); if (count == 0) { break }
                    bytes += count; for (index in 0..count) { checksum += Int64(output[index]) }
                }
                if (let Some(value) <- codec) {
                    require(value.integrityVerified && value.encodedBytesRead == wire.size && value.decodedBytes == raw.size, "benchmark decoder did not validate exact output")
                    maxWork = max(maxWork, value.maximumWorkBetweenChecks)
                }
            } finally { body.close() }
        }
        let nanos = (MonoTime.now() - started).toNanoseconds()
        require(bytes == 8 * raw.size && checksum == bytes * 97 && nanos > 0 && maxWork <= 512, "baseline output or counted work bound failed")
        let mode = if (decoded) { "gzip" } else { "raw" }
        let retained = if (decoded) { GzipLimits().maximumRetainedBytes } else { 0u64 }
        println("BENCH mode=${mode} bytes=${bytes} checksum=${checksum} elapsed_ns=${nanos} max_work_between_checks=${maxWork} retained_bound=${retained}")
    }
    println("CHECK bounded_decode_baseline PASS")
}
main(args: Array<String>): Int64 {
    require(args.size == 2, "usage: gzip certificate.der key.pk8")
    let cert = File.readFrom(args[0]); let key = File.readFrom(args[1])
    let serverTls = HttpServerTlsConfig([cert], key); let clientTls = HttpClientTlsConfig([cert]); let handler = Handler()
    let server1 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).build()
    let server2 = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).tls(serverTls).build()
    let serve1 = spawn { server1.serve() }; let serve2 = spawn { server2.serve() }
    let h1 = HttpClient.builder().requestTimeout(10 * Duration.second).build()
    let resolver = StaticResolver(ResolveResult([loopback()], HostName("example.test"), ResolverSource.Static))
    let h2 = HttpClient.builder().resolver(resolver).tls(clientTls).requestTimeout(10 * Duration.second).build()
    try {
        native(h1, "http://127.0.0.1:${server1.localEndpoint.port}", HttpVersion.Http11, "h1")
        native(h2, "https://example.test:${server2.localEndpoint.port}", HttpVersion.Http2, "h2")
        require(handler.negotiated.load() == 6, "explicit gzip was not negotiated for all six requests")
        benchmark()
    } finally {
        h1.close(); h2.close(); let _ = server1.shutdown(context: context()); let _ = server2.shutdown(context: context())
        serve1.get(5 * Duration.second); serve2.get(5 * Duration.second)
        server1.close(); server2.close(); serverTls.close(); clientTls.close()
    }
    println("CHECK native_shutdown PASS"); println("M11_002_INSTALLED_GZIP_PASS"); 0
}
