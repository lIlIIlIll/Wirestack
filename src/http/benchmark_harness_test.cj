package wirestack.http

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/** Machine-readable public HTTP/1 loopback benchmark; threshold decisions live in tools/benchmarks. */
@Test
@Tag[Performance]
class Http1PublicKeepAliveBenchmarkTest {
    @TestCase
    func benchmarkKeepAliveSmall(): Unit {
        let warmup: Int64 = 200
        let iterations: Int64 = 2000
        let totalRequests = warmup + iterations
        let endpoint = SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0
        )
        let server = HttpServer.builder()
            .listen(endpoint)
            .handler(BenchmarkPublicEmptyHandler())
            .connectionLimit(1)
            .requestsPerConnectionLimit(totalRequests)
            .build()
        let serving = spawn { server.serve() }
        let host = HostName("127.0.0.1")
        let client = HttpClient.builder()
            .resolver(StaticResolver(ResolveResult(
                [server.localEndpoint.address], host, ResolverSource.Static
            )))
            .requestTimeout(5 * Duration.second)
            .build()
        var checksum: Int64 = 0
        try {
            let url = "http://127.0.0.1:${server.localEndpoint.port}/small"
            for (_ in 0..warmup) {
                let response = client.get(url)
                response.close()
            }
            let started = MonoTime.now()
            for (_ in 0..iterations) {
                let response = client.get(url)
                checksum += response.status
                response.close()
            }
            let duration = (MonoTime.now() - started).toNanoseconds()
            @Expect(checksum, iterations * 200)
            @Expect(duration > 0)
            println(
                "HTTP1_BENCH scenario=keep_alive_small iterations=${iterations} " +
                "durationNs=${duration} bytes=0 checksum=${checksum}"
            )
        } finally {
            client.close()
            let result = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
            @Expect(result.activeAtReturn, 0)
            serving.get(5 * Duration.second)
        }
    }
}

private class BenchmarkPublicEmptyHandler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        HttpServerResponse(HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}
