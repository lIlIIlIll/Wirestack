package wirestack.internal.http1

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** Machine-readable benchmark harness; threshold decisions live in tools/benchmarks. */
@Test
@Tag[Performance]
class Http1KeepAliveBenchmarkTest {
    @TestCase
    func benchmarkKeepAliveSmall(): Unit {
        let iterations: Int64 = 2000
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        let serving = spawn {
            serveHttp1Connection(
                serverTransport, BenchmarkEmptyHandler(), maximumRequests: iterations
            )
        }
        let connection = Http1ClientConnection(clientTransport)
        let request = HttpRequest.get("http://benchmark.test/small")
        let started = MonoTime.now()
        var checksum: Int64 = 0
        for (_ in 0..iterations) {
            let response = connection.execute(request).response
            checksum += response.status
            response.close()
        }
        let duration = (MonoTime.now() - started).toNanoseconds()
        connection.close()
        let served = serving.get()
        @Expect(served.requestsServed, iterations)
        @Expect(checksum, iterations * 200)
        @Expect(duration > 0)
        println(
            "HTTP1_BENCH scenario=keep_alive_small iterations=${iterations} " +
            "durationNs=${duration} bytes=0 checksum=${checksum}"
        )
    }

}

@Test
@Tag[Performance]
class Http1Stream16MiBBenchmarkTest {
    @TestCase
    func benchmarkStream16MiB(): Unit { benchmarkStream(16 * 1024 * 1024, "stream_16mib") }
}

@Test
@Tag[Performance]
class Http1Stream64MiBBenchmarkTest {
    @TestCase
    func benchmarkStream64MiB(): Unit { benchmarkStream(64 * 1024 * 1024, "stream_64mib") }
}

private func benchmarkStream(size: Int64, name: String): Unit {
    let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
    let serving = spawn {
        serveHttp1Connection(
            serverTransport, BenchmarkStreamingHandler(size), maximumRequests: 1
        )
    }
    let connection = Http1ClientConnection(clientTransport)
    let started = MonoTime.now()
    let response = connection.execute(HttpRequest.get("http://benchmark.test/stream")).response
    let buffer = Array<Byte>(64 * 1024, repeat: 0)
    var received: Int64 = 0
    var checksum: Int64 = 0
    while (received < size) {
        let count = response.body.read(buffer)
        if (count == 0) { break }
        received += count
        checksum += Int64(buffer[0]) + Int64(buffer[count - 1])
    }
    let duration = (MonoTime.now() - started).toNanoseconds()
    response.close()
    connection.close()
    let served = serving.get()
    @Expect(served.requestsServed, 1)
    @Expect(received, size)
    @Expect(duration > 0)
    println(
        "HTTP1_BENCH scenario=${name} iterations=1 durationNs=${duration} " +
        "bytes=${received} checksum=${checksum}"
    )
}

private class BenchmarkEmptyHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        Http1ServerResponse(HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("Content-Length", "0").build()
        ))
    }
}

private class BenchmarkStreamingHandler <: Http1ServerHandler {
    private let size: Int64
    init(size: Int64) { this.size = size }
    public func handle(request: Http1ServerRequest, context: OperationContext): Http1ServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0))
        Http1ServerResponse(HttpResponse(
            200, "OK", ResponseBody(BenchmarkPatternStream(size)),
            headers: HttpHeaders.builder().add("Content-Length", "${size}").build()
        ))
    }
}

private class BenchmarkPatternStream <: HttpBodyStream {
    private let size: Int64
    private var offset: Int64 = 0
    private var closed = false
    init(size: Int64) { this.size = size }
    public prop contentLength: ?Int64 { get() { Some(size) } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw IllegalStateException("benchmark stream is closed") }
        if (destination.isEmpty() || offset == size) { return 0 }
        let count = min(destination.size, size - offset)
        for (index in 0..count) { destination[index] = UInt8(UInt64((offset + index) & 255)) }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}
