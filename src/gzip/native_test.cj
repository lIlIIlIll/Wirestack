package wirestack.gzip

import std.collection.ArrayList
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.*
import wirestack.http.{HttpClient, HttpServer, HttpServerHandler, HttpServerRequest, HttpServerResponse,
    HttpResourceLimits, HttpClientTlsConfig, HttpServerTlsConfig, HttpCancellationHandles, HttpStreamCancellationHandle}

@Test
class GzipNativeTest {
    @TestCase
    func rawClientDoesNotNegotiateOrDecodeAndWrapperRetainsWireMetadata(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            try {
                let raw = fixture.client.send(fixture.request("/gzip"))
                try {
                    @Expect(fixture.handler.acceptEncoding, None<String>)
                    @Expect(raw.headers.getFirst("content-encoding"), Some("gzip"))
                    @Expect(gzipNativeRead(raw.body), gzipNativeSmallMember())
                } finally { raw.close() }
                let decoded = GzipClient(fixture.client).send(fixture.request("/gzip"))
                try {
                    @Expect(fixture.handler.acceptEncoding, Some("gzip"))
                    @Expect(decoded.isDecoded)
                    @Expect(decoded.wireHeaders.getFirst("content-encoding"), Some("gzip"))
                    @Expect(decoded.wireHeaders.getFirst("content-length"), Some("30"))
                    @Expect(decoded.wireContentLength, Some(30))
                    @Expect(decoded.response.headers.getFirst("content-encoding"), None<String>)
                    @Expect(decoded.response.headers.getFirst("content-length"), None<String>)
                    @Expect(decoded.response.body.contentLength, None<Int64>)
                    @Expect(String.fromUtf8(gzipNativeRead(decoded.response.body)), "hello gzip")
                    @Expect(decoded.encodedBytesRead, 30)
                    @Expect(decoded.decodedBytes, 10)
                    @Expect(decoded.memberCount, 1)
                    @Expect(decoded.integrityVerified)
                } finally { decoded.close(); decoded.close() }
                let caller = GzipClient(fixture.client).send(fixture.request("/gzip", headers:
                    HttpHeaders.builder().add("Accept-Encoding", "identity, gzip;q=0.5").build()))
                try {
                    @Expect(fixture.handler.acceptEncoding, Some("identity, gzip;q=0.5"))
                    @Expect(String.fromUtf8(gzipNativeRead(caller.response.body)), "hello gzip")
                } finally { caller.close() }
                gzipNativeExpectReleased(fixture.client)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func unsupportedCodingFailsClosedUnlessExplicitRawPassThrough(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            try {
                for (target in ["/unknown", "/multi", "/repeated-coding"]) {
                    let error = @AssertThrows[GzipException](GzipClient(fixture.client).send(fixture.request(target)))
                    @Expect(error.code, GzipErrorCode.UnsupportedCoding)
                    gzipNativeExpectReleased(fixture.client)
                    let raw = GzipClient(fixture.client, passThroughUnsupported: true).send(fixture.request(target))
                    try {
                        @Expect(!raw.isDecoded)
                        let expected = if (target == "/unknown") { "br" }
                            else if (target == "/multi") { "gzip, identity" } else { "gzip" }
                        @Expect(raw.response.headers.getFirst("content-encoding"), Some(expected))
                        @Expect(raw.wireHeaders.getFirst("content-encoding"), Some(expected))
                        @Expect(raw.response.headers.getFirst("content-length"), Some("30"))
                        @Expect(raw.wireContentLength, Some(30))
                        if (target == "/repeated-coding") {
                            @Expect(raw.response.headers.getAll("content-encoding").size, 2)
                            @Expect(raw.wireHeaders.getAll("content-encoding").size, 2)
                        }
                        @Expect(raw.response.body.contentLength, Some(30))
                        @Expect(gzipNativeRead(raw.response.body), gzipNativeSmallMember())
                        @Expect(!raw.integrityVerified)
                    } finally { raw.close() }
                }
                for (target in ["/plain", "/identity"]) {
                    let raw = GzipClient(fixture.client).send(fixture.request(target))
                    try {
                        @Expect(!raw.isDecoded)
                        @Expect(String.fromUtf8(gzipNativeRead(raw.response.body)), "ok")
                    } finally { raw.close() }
                }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func headAndBodylessStatusesSkipInvalidCoding(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            try {
                let head = GzipClient(fixture.client).send(fixture.request("/head", method: "HEAD"))
                try {
                    @Expect(!head.isDecoded)
                    @Expect(head.wireHeaders.getFirst("content-encoding"), Some("invalid, gzip"))
                    @Expect(head.response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
                } finally { head.close() }
                for (status in [204, 205, 304]) {
                    let response = GzipClient(fixture.client).send(fixture.request("/status-${status}"))
                    try {
                        @Expect(response.response.status, status)
                        @Expect(!response.isDecoded)
                        @Expect(response.response.body.read(Array<Byte>(1, repeat: 0u8)), 0)
                    } finally { response.close() }
                }
                gzipNativeExpectReleased(fixture.client)
            } finally { fixture.close() }
        }
    }

    @TestCase
    func concatenationRequiresExplicitMemberLimitAndExactOutputLimitValidatesEof(): Unit {
        let fixture = GzipNativeFixture()
        try {
            let rejected = GzipClient(fixture.client).send(fixture.request("/members"))
            try {
                let error = @AssertThrows[GzipException](gzipNativeRead(rejected.response.body))
                @Expect(error.code, GzipErrorCode.MemberLimit)
                @Expect(!rejected.integrityVerified)
            } finally { rejected.close() }
            let accepted = GzipClient(fixture.client, limits: GzipLimits(maximumMembers: 2,
                maximumEncodedBytes: 60, maximumDecodedBytes: 20, maximumReadBytes: 3)).send(fixture.request("/members"))
            try {
                @Expect(String.fromUtf8(gzipNativeRead(accepted.response.body, bufferBytes: 2)), "hello gziphello gzip")
                @Expect(accepted.memberCount, 2)
                @Expect(accepted.encodedBytesRead, 60)
                @Expect(accepted.decodedBytes, 20)
                @Expect(accepted.integrityVerified)
            } finally { accepted.close() }
            gzipNativeExpectReleased(fixture.client)
        } finally { fixture.close() }
    }

    @TestCase
    func crcTruncationAndHighRatioOutputFailureReleaseRealReservations(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            try {
                for ((target, code) in [("/crc", GzipErrorCode.ChecksumMismatch),
                    ("/truncated", GzipErrorCode.UnexpectedEof), ("/large", GzipErrorCode.OutputLimit)]) {
                    let response = GzipClient(fixture.client, limits: GzipLimits(maximumDecodedBytes: 128,
                        maximumReadBytes: 4)).send(fixture.request(target))
                    try {
                        @Expect(fixture.client.resourceSnapshot().managedBufferBytes > 0u64)
                        @Expect(response.response.body.read(Array<Byte>(1, repeat: 0u8)), 1)
                        let error = @AssertThrows[GzipException](gzipNativeRead(response.response.body))
                        @Expect(error.code, code)
                        @Expect(!response.integrityVerified)
                        @Expect(response.response.body.isClosed())
                        gzipNativeExpectReleased(fixture.client)
                    } finally { response.close() }
                    let subsequent = fixture.client.send(fixture.request("/plain"))
                    try { @Expect(String.fromUtf8(gzipNativeRead(subsequent.body)), "ok") }
                    finally { subsequent.close() }
                }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func pendingNativeReadWakesOnParentCancellationAndLocalClose(): Unit {
        for (tls in [false, true]) {
            for (localClose in [false, true]) {
                let fixture = GzipNativeFixture(tls: tls)
                let source = CancellationSource()
                let readSignal = GzipNativeReadSignal()
                let response = GzipClient(fixture.client).send(fixture.request("/stall"), context:
                    OperationContext(deadline: Some(Deadline.after(3 * Duration.second)), cancellation: source.token,
                        eventSink: Some(readSignal)))
                try {
                    fixture.handler.stall.waitUntilBlocked()
                    let reading = spawn {
                        try { let _ = response.response.body.read(Array<Byte>(1, repeat: 0u8)); false }
                        catch (error: NetworkException) {
                            match (error.code) {
                                case NetworkErrorCode.Cancelled =>
                                    if (localClose) { @Fail("local close surfaced NetworkErrorCode.Cancelled, TLS=${tls}") }; true
                                case NetworkErrorCode.Closed =>
                                    if (!localClose) { @Fail("parent cancellation surfaced NetworkErrorCode.Closed, TLS=${tls}") }; true
                                case _ => throw error
                            }
                        } catch (error: GzipException) {
                            if (!localClose || error.code != GzipErrorCode.Closed) { throw error }; true
                        }
                        catch (error: HttpBodyException) {
                            match (error.code) {
                                case HttpBodyErrorCode.Closed =>
                                    if (!localClose) { @Fail("parent cancellation surfaced HttpBodyErrorCode.Closed, TLS=${tls}") }; true
                                case _ => throw error
                            }
                        }
                    }
                    readSignal.waitUntilReadStarted()
                    @Expect(fixture.client.resourceSnapshot().managedBufferBytes > 0u64)
                    if (localClose) { response.close() } else { source.cancel() }
                    @Expect(reading.get(Duration.second))
                    gzipNativeExpectReleased(fixture.client)
                } finally { response.close(); fixture.close() }
            }
        }
    }
    @TestCase
    func parentAbsoluteDeadlineInterruptsNativeBodyRead(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            let deadline = Deadline.after(200 * Duration.millisecond)
            let response = GzipClient(fixture.client).send(fixture.request("/stall"),
                context: OperationContext(deadline: Some(deadline)))
            try {
                @Expect(response.response.operationContext.getOrThrow().deadline.getOrThrow().expiresAt, deadline.expiresAt)
                let error = @AssertThrows[NetworkException](response.response.body.read(Array<Byte>(1, repeat: 0u8)))
                match (error.code) { case NetworkErrorCode.TimedOut => (); case _ => @Fail("native body read must time out") }
                @Expect(!response.integrityVerified)
                gzipNativeExpectReleased(fixture.client)
            } finally { response.close(); fixture.close() }
        }
    }

    @TestCase
    func http2TypedStreamCancellationReclaimsDecoderWithoutClosingSibling(): Unit {
        let fixture = GzipNativeFixture(tls: true)
        let handle = HttpStreamCancellationHandle()
        let readSignal = GzipNativeReadSignal()
        let response = GzipClient(fixture.client).send(fixture.request("/stall"),
            cancellation: HttpCancellationHandles(stream: Some(handle)),
            context: OperationContext(deadline: Some(Deadline.after(3 * Duration.second)), eventSink: Some(readSignal)))
        let sibling = fixture.client.send(fixture.request("/sibling"))
        try {
            let reading = spawn {
                try { let _ = response.response.body.read(Array<Byte>(1, repeat: 0u8)); false }
                catch (error: NetworkException) {
                    match (error.code) { case NetworkErrorCode.Cancelled => true; case _ => false }
                }
            }
            readSignal.waitUntilReadStarted()
            @Expect(handle.cancel())
            @Expect(!handle.cancel())
            @Expect(reading.get(Duration.second))
            @Expect(String.fromUtf8(gzipNativeRead(sibling.body)), "sibling remains readable")
            gzipNativeExpectReleased(fixture.client)
            @Expect(fixture.client.resourceSnapshot().activeConnections, 1)
        } finally { response.close(); sibling.close(); fixture.close() }
    }


    @TestCase
    func http2GzipCloseAndMalformedMemberLeaveActiveSiblingAlive(): Unit {
        for (target in ["/stall", "/crc", "/truncated", "/large"]) {
            let fixture = GzipNativeFixture(tls: true)
            try {
                let decoded = GzipClient(fixture.client, limits: GzipLimits(maximumDecodedBytes: 128,
                    maximumReadBytes: 4)).send(fixture.request(target))
                let sibling = fixture.client.send(fixture.request("/sibling"))
                try {
                    @Expect(decoded.response.version, HttpVersion.Http2)
                    @Expect(sibling.version, HttpVersion.Http2)
                    @Expect(fixture.client.resourceSnapshot().activeConnections, 1)
                    @Expect(fixture.client.resourceSnapshot().activeStreams, 2)
                    if (target == "/stall") { decoded.close() }
                    else { let _ = @AssertThrows[GzipException](gzipNativeRead(decoded.response.body)) }
                    gzipNativeAwait({ => fixture.client.resourceSnapshot().activeStreams == 1 })
                    @Expect(fixture.client.resourceSnapshot().activeConnections, 1)
                    @Expect(String.fromUtf8(gzipNativeRead(sibling.body)), "sibling remains readable")
                    gzipNativeExpectReleased(fixture.client)
                    @Expect(fixture.client.resourceSnapshot().activeConnections, 1)
                } finally { decoded.close(); sibling.close() }
            } finally { fixture.close() }
        }
    }

    @TestCase
    func http1UnreadWideBodyAbandonsConnectionWithoutDrainingUnboundedInput(): Unit {
        let fixture = GzipNativeFixture()
        let response = GzipClient(fixture.client).send(fixture.request("/wide"))
        try {
            @Expect(response.response.body.read(Array<Byte>(1, repeat: 0u8)), 1)
            @Expect(response.encodedBytesRead < gzipNativeWideMember().size)
            @Expect(fixture.client.resourceSnapshot().activeRequests, 1)
            response.close(); response.close()
            gzipNativeExpectReleased(fixture.client)
            gzipNativeAwait({ => fixture.client.resourceSnapshot().activeConnections == 0 })
            let next = fixture.client.send(fixture.request("/plain"))
            try { @Expect(String.fromUtf8(gzipNativeRead(next.body)), "ok") } finally { next.close() }
        } finally { response.close(); fixture.close() }
    }

    @TestCase
    func configuredRequestTimeoutSurvivesBufferedCpuDecoding(): Unit {
        let fixture = GzipNativeFixture(requestTimeout: Duration.second)
        let clock = GzipNativeClock()
        let parent = Deadline.after(10 * Duration.second, clock: clock)
        let response = GzipClient(fixture.client, limits: GzipLimits(maximumReadBytes: 65536)).send(
            fixture.request("/large"), context: OperationContext(deadline: Some(parent)))
        try {
            @Expect(response.response.operationContext.getOrThrow().deadline.getOrThrow().expiresAt < parent.expiresAt)
            @Expect(response.response.body.read(Array<Byte>(1, repeat: 0u8)), 1)
            @Expect(response.encodedBytesRead, gzipNativeLargeMember().size)
            clock.arm()
            let error = @AssertThrows[NetworkException](gzipNativeRead(response.response.body, bufferBytes: 65536))
            match (error.code) { case NetworkErrorCode.TimedOut => (); case _ => @Fail("buffered decoding must time out") }
            @Expect(response.decodedBytes < 1048576)
            @Expect(!response.integrityVerified)
            gzipNativeExpectReleased(fixture.client)
        } finally { response.close(); fixture.close() }
    }

    @TestCase
    func dataAdmissionUsesSameRequestTimeoutAndParentCancellationBeforeSend(): Unit {
        let resourceLimits = HttpResourceLimits(maximumConnections: 8, maximumConnectionsPerRoute: 8,
            maximumConnectionsPerOrigin: 8, maximumManagedBufferBytes: 8u64 * 1024u64 * 1024u64,
            maximumManagedBufferBytesPerRoute: 8u64 * 1024u64 * 1024u64,
            maximumManagedBufferBytesPerOrigin: 8u64 * 1024u64 * 1024u64)
        for (cancel in [false, true]) {
            let fixture = GzipNativeFixture(resourceLimits: resourceLimits, requestTimeout: 200 * Duration.millisecond)
            let capacity = resourceLimits.maximumManagedBufferBytes - resourceLimits.reservedControlBufferBytes -
                UInt64(resourceLimits.maximumConnections) * 65535u64
            let lease = fixture.client.reserveResponseBuffer(fixture.url("/gzip"), capacity)
            let source = CancellationSource()
            try {
                let sending = spawn {
                    try {
                        let response = GzipClient(fixture.client).send(fixture.request("/gzip"), context:
                            OperationContext(deadline: Some(Deadline.after(2 * Duration.second)), cancellation: source.token))
                        response.close(); false
                    } catch (error: NetworkException) {
                        match (error.code) {
                            case NetworkErrorCode.Cancelled => cancel
                            case NetworkErrorCode.TimedOut => !cancel
                            case _ => false
                        }
                    }
                }
                gzipNativeAwait({ => fixture.client.resourceSnapshot().admissionWaiters == 1 })
                if (cancel) { source.cancel() }
                @Expect(sending.get(Duration.second))
                @Expect(fixture.handler.gzipRequests.load(), 0)
                @Expect(fixture.client.resourceSnapshot().admissionWaiters, 0)
                @Expect(fixture.client.resourceSnapshot().managedBufferBytes, capacity)
                lease.close()
                gzipNativeExpectReleased(fixture.client)
            } finally { lease.close(); fixture.close() }
        }
    }

    @TestCase
    func nativeLargeBodyDecodesIncrementallyWithBoundedReadsAndReservation(): Unit {
        for (tls in [false, true]) {
            let fixture = GzipNativeFixture(tls: tls)
            let response = GzipClient(fixture.client, limits: GzipLimits(maximumReadBytes: 1024)).send(fixture.request("/large"))
            try {
                let buffer = Array<Byte>(8192, repeat: 0u8)
                var count: Int64 = 0
                var reads: Int64 = 0
                var invalidBytes: Int64 = 0
                let reserved = fixture.client.resourceSnapshot().managedBufferBytes
                @Expect(reserved > 0u64)
                while (true) {
                    let n = response.response.body.read(buffer)
                    if (n == 0) { break }
                    @Expect(n <= 1024)
                    for (i in 0..n) { if (buffer[i] != b'a') { invalidBytes++ } }
                    count += n; reads++
                    @Expect(fixture.client.resourceSnapshot().managedBufferBytes <= reserved)
                }
                @Expect(count, 1048576)
                @Expect(reads, 1024)
                @Expect(invalidBytes, 0)
                @Expect(response.integrityVerified)
                gzipNativeExpectReleased(fixture.client)
            } finally { response.close(); fixture.close() }
        }
    }
}

private func gzipNativeRead(body: ResponseBody, bufferBytes!: Int64 = 17): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(bufferBytes, repeat: 0u8)
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { return output.toArray() }
        for (index in 0..count) { output.add(buffer[index]) }
    }
    output.toArray()
}

private func gzipNativeAwait(ready: () -> Bool): Unit {
    let end = MonoTime.now() + 2 * Duration.second
    while (!ready()) {
        if (MonoTime.now() >= end) { @Fail("native gzip resource state did not settle") }
        sleep(Duration.millisecond)
    }
}

private func gzipNativeExpectReleased(client: HttpClient): Unit {
    gzipNativeAwait({ => let state = client.resourceSnapshot();
        state.activeRequests == 0 && state.activeStreams == 0 && state.managedBufferBytes == 0u64 })
    let state = client.resourceSnapshot()
    @Expect(state.reservedConnections, 0)
    @Expect(state.reservedStreams, 0)
    @Expect(state.admissionWaiters, 0)
}

private class GzipNativeClock <: MonotonicClock {
    private let base = MonoTime.now()
    private let ticks = AtomicInt64(0)
    private let armed = AtomicBool(false)
    func arm(): Unit { armed.store(true) }
    public func now(): MonoTime {
        if (armed.load()) { return base + ticks.fetchAdd(1) * 100 * Duration.millisecond }
        base
    }
}

private class GzipNativeFixture <: Resource {
    let handler = GzipNativeHandler()
    let client: HttpClient
    private let server: HttpServer
    private let serving: Future<Unit>
    private let secure: Bool
    private var serverTls: ?HttpServerTlsConfig = None<HttpServerTlsConfig>
    private var clientTls: ?HttpClientTlsConfig = None<HttpClientTlsConfig>
    init(tls!: Bool = false, resourceLimits!: HttpResourceLimits = HttpResourceLimits(),
        requestTimeout!: Duration = 5 * Duration.second) {
        secure = tls
        let builder = HttpServer.builder().listen(SocketEndpoint(
            IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0u16)).handler(handler)
        if (tls) {
            let config = HttpServerTlsConfig([gzipNativeCertificate()], gzipNativePrivateKey())
            serverTls = Some(config); builder.tls(config).http2StreamLimit(8u32)
        }
        server = builder.build()
        let owner = server
        serving = spawn { owner.serve() }
        let cb = HttpClient.builder().resolver(StaticResolver(ResolveResult([server.localEndpoint.address],
            HostName("example.com"), ResolverSource.Static))).resourceLimits(resourceLimits).requestTimeout(requestTimeout)
        if (tls) {
            let config = HttpClientTlsConfig([gzipNativeCertificate()])
            clientTls = Some(config); cb.tls(config)
        }
        client = cb.build()
        // A GET response, not a delay, proves listener readiness before any close/shutdown.
        let ready = client.send(request("/fixture-ready"), context:
            OperationContext(deadline: Some(Deadline.after(2 * Duration.second))))
        try { let _ = gzipNativeRead(ready.body) } finally { ready.close() }
    }
    func url(target: String): HttpUrl {
        let scheme = if (secure) { "https" } else { "http" }
        HttpUrl.parse("${scheme}://example.com:${server.localEndpoint.port}${target}")
    }
    func request(target: String, method!: String = "GET", headers!: HttpHeaders = HttpHeaders()): HttpRequest {
        HttpRequest(HttpMethod(method), url(target), headers: headers)
    }
    public func close(): Unit {
        handler.stall.close(); client.close()
        if (let Some(value) <- clientTls) { value.close() }
        if (!server.isClosed()) { let _ = server.shutdown(context:
            OperationContext(deadline: Some(Deadline.after(2 * Duration.second)))) }
        serving.get(3 * Duration.second)
        if (let Some(value) <- serverTls) { value.close() }
    }
    public func isClosed(): Bool { client.isClosed() }
}

private class GzipNativeHandler <: HttpServerHandler {
    let stall = GzipNativeStalledBody()
    let gzipRequests = AtomicInt64(0)
    private let mutex = Mutex()
    private var encoding: ?String = None<String>
    prop acceptEncoding: ?String { get() { synchronized(mutex) { encoding } } }
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.drain(1024)
        synchronized(mutex) { encoding = request.headers.getFirst("accept-encoding") }
        let target = request.target
        if (target == "/gzip") { gzipRequests.fetchAdd(1) }
        if (target == "/stall") {
            return HttpServerResponse(HttpResponse(200, "OK", ResponseBody(stall), headers:
                HttpHeaders.builder().add("Content-Encoding", "gzip").add("Content-Length", "30").build()))
        }
        if (target == "/head" || target.startsWith("/status-")) {
            let status: Int64 = if (target == "/status-204") { 204 }
                else if (target == "/status-205") { 205 }
                else if (target == "/status-304") { 304 } else { 200 }
            let headers = HttpHeaders.builder().add("Content-Encoding", "invalid, gzip")
            if (status != 204) { headers.add("Content-Length", "0") }
            return HttpServerResponse(HttpResponse(status, "fixture", ResponseBody.empty(), headers: headers.build()))
        }
        if (target == "/fixture-ready" || target == "/plain" || target == "/identity" || target == "/sibling") {
            let bytes = if (target == "/sibling") { "sibling remains readable".toArray() } else { "ok".toArray() }
            let headers = HttpHeaders.builder().add("Content-Length", bytes.size.toString())
            if (target == "/identity") { headers.add("Content-Encoding", "identity") }
            return reply(bytes, headers.build())
        }
        var bytes = if (target == "/large") { gzipNativeLargeMember() }
            else if (target == "/wide") { gzipNativeWideMember() } else { gzipNativeSmallMember() }
        if (target == "/crc") { bytes[bytes.size - 8] ^= 1u8 }
        if (target == "/truncated") { bytes = bytes[0..bytes.size - 3] }
        if (target == "/members") {
            let member = bytes
            bytes = Array<Byte>(member.size * 2, {i => member[i % member.size]})
        }
        let coding = if (target == "/unknown") { "br" } else if (target == "/multi") { "gzip, identity" } else { "gzip" }
        let headers = HttpHeaders.builder().add("Content-Encoding", coding).add("Content-Length", bytes.size.toString())
        if (target == "/repeated-coding") { headers.add("Content-Encoding", "gzip") }
        reply(bytes, headers.build())
    }
    private func reply(bytes: Array<Byte>, headers: HttpHeaders): HttpServerResponse {
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(bytes).open()), headers: headers))
    }
}

private class GzipNativeStalledBody <: HttpBodyStream {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var sent = false
    private var blocked = false
    private var closed = false
    public prop contentLength: ?Int64 { get() { Some(30) } }
    func waitUntilBlocked(): Unit {
        let deadline = Deadline.after(2 * Duration.second)
        synchronized(mutex) {
            while (!blocked && !closed) {
                changed.wait(timeout: deadline.remaining())
                if (deadline.isExpired()) { @Fail("native gzip server did not enter its body wait") }
            }
        }
    }
    public func read(destination: Array<Byte>): Int64 {
        synchronized(mutex) {
            if (closed || destination.isEmpty()) { return 0 }
            if (!sent) {
                sent = true
                let prefix = gzipNativeSmallMember()[0..10]
                let n = min(destination.size, prefix.size)
                for (i in 0..n) { destination[i] = prefix[i] }
                return n
            }
            blocked = true; changed.notifyAll()
            while (!closed) { changed.wait(timeout: Duration.second) }
            0
        }
    }
    public func close(): Unit { synchronized(mutex) { closed = true; changed.notifyAll() } }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
}

private class GzipNativeReadSignal <: NetworkEventSink {
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private var starts: Int64 = 0
    public func emit(event: NetworkEvent): Unit {
        match (event.kind) {
            case NetworkEventKind.StageStarted =>
                match (event.stage) {
                    case Some(OperationTimeoutStage.BodyReadIdle) =>
                        synchronized(mutex) { starts++; changed.notifyAll() }
                    case _ => ()
                }
            case _ => ()
        }
    }
    func waitUntilReadStarted(): Unit {
        let deadline = Deadline.after(2 * Duration.second)
        synchronized(mutex) {
            // The first read gets the ten-byte gzip header; the second waits for absent payload.
            while (starts < 2) {
                changed.wait(timeout: deadline.remaining())
                if (deadline.isExpired()) { @Fail("native gzip client did not start its body read") }
            }
        }
    }
}
