package wirestack.http

import std.convert.*
import std.env.getVariable
import std.runtime.*
import std.sync.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private const SSE_PROFILE_BODY_LIMIT_BYTES: Int64 = 64 * 1024
private const SSE_PROFILE_MAX_LEAD_EVENTS: Int64 = 524288

@Test
class Http1SseStreamingProfileTest {
    @TestCase
    func http1StreamsWithoutLifetimeAccumulationAndCancels(): Unit {
        runSseStreamingProfile(HttpVersion.Http11)
    }
}

@Test
class Http2SseStreamingProfileTest {
    @TestCase
    func http2StreamsWithoutLifetimeAccumulationAndPreservesSibling(): Unit {
        runSseStreamingProfile(HttpVersion.Http2)
    }
}

private func runSseStreamingProfile(protocol: HttpVersion): Unit {
    let settings = SseProfileSettings.load()
    let producer = SseProfileProducer(settings)
    let handler = SseProfileHandler(producer)
    let limits = HttpLimits(maxBodyBytes: SSE_PROFILE_BODY_LIMIT_BYTES)
    let certificate = if (protocol == HttpVersion.Http2) {
        Some(publicTlsTestCertificateDer())
    } else {
        None<Array<Byte>>
    }
    let tls = match (certificate) {
        case Some(value) => Some(HttpServerTlsConfig([value], publicTlsTestPrivateKeyDer()))
        case None => None<HttpServerTlsConfig>
    }
    var serverBuilder = HttpServer.builder()
        .listen(sseProfileLoopback(0))
        .handler(handler)
        .limits(limits)
        .http2StreamLimit(8u32)
    if (let Some(value) <- tls) { serverBuilder = serverBuilder.tls(value) }
    let server = serverBuilder.build()
    let serving: Future<Unit> = spawn { server.serve() }
    let host = HostName("example.com")
    let clientTls = match (certificate) {
        case Some(value) => Some(HttpClientTlsConfig([value]))
        case None => None<HttpClientTlsConfig>
    }
    var clientBuilder = HttpClient.builder()
        .resolver(StaticResolver(ResolveResult(
            [server.localEndpoint.address], host, ResolverSource.Static
        )))
        .limits(limits)
    if (let Some(value) <- clientTls) { clientBuilder = clientBuilder.tls(value) }
    let client = clientBuilder.build()
    let cancellation = if (protocol == HttpVersion.Http2) {
        HttpCancellationHandles(stream: Some(HttpStreamCancellationHandle()))
    } else {
        HttpCancellationHandles(request: Some(HttpRequestCancellationHandle()))
    }
    let scheme = if (protocol == HttpVersion.Http2) { "https" } else { "http" }
    let url = "${scheme}://example.com:${server.localEndpoint.port}/events"
    let parser = SseSequenceParser()
    var siblingBefore = false
    var siblingAfter = false
    var siblingBeforeFuture: ?Future<Bool> = None<Future<Bool>>
    var cancelLatencyNs: Int64 = -1
    var maximumLead: Int64 = 0
    var slowLead: Int64 = 0
    let started = MonoTime.now()
    var nextSample = settings.sampleInterval
    try {
        let stream = client.getControlled(url, cancellation)
        @Expect(stream.version, protocol)
        @Expect(stream.headers.getFirst("content-type"), Some("text/event-stream"))
        let buffer = Array<Byte>(settings.clientReadBytes, repeat: 0u8)
        while ((MonoTime.now() - started) < settings.duration ||
            parser.events < settings.minimumEvents) {
            let elapsed = MonoTime.now() - started
            let count = stream.body.read(buffer)
            if (count == 0) { @Fail("SSE stream ended before public cancellation") }
            parser.accept(buffer, count)
            let lead = max(producer.eventsProduced.load() - parser.events, 0)
            maximumLead = max(maximumLead, lead)
            if (elapsed < settings.slowConsumerDuration) {
                slowLead = max(slowLead, lead)
                sleep(settings.slowConsumerDelay)
            }
            if (protocol == HttpVersion.Http2 && siblingBeforeFuture.isNone() &&
                elapsed >= settings.siblingProbeDelay) {
                siblingBeforeFuture = Some(spawn {
                    readSseSibling(client, scheme, server.localEndpoint.port)
                })
            }
            if (elapsed >= nextSample) {
                sseHeapSample(protocol, elapsed, parser.events, producer.eventsProduced.load(), lead)
                nextSample += settings.sampleInterval
            }
        }
        @Expect(parser.sequenceErrors, 0)
        @Expect(parser.events >= settings.minimumEvents)
        @Expect((MonoTime.now() - started) >= settings.duration)
        @Expect(maximumLead <= SSE_PROFILE_MAX_LEAD_EVENTS)
        @Expect(slowLead > 0)
        if (let Some(value) <- siblingBeforeFuture) {
            siblingBefore = value.get(5 * Duration.second)
        }

        let cancelStarted = MonoTime.now()
        @Expect(cancelSseHandle(cancellation, protocol))
        @Expect(!cancelSseHandle(cancellation, protocol))
        @Expect(sseBodyReadCancelled(stream.body))
        cancelLatencyNs = (MonoTime.now() - cancelStarted).toNanoseconds()
        @Expect(cancelLatencyNs <= 50 * Duration.millisecond.toNanoseconds())
        stream.close()
        if (protocol == HttpVersion.Http2) {
            siblingAfter = readSseSibling(client, scheme, server.localEndpoint.port)
            @Expect(siblingBefore)
            @Expect(siblingAfter)
        }
        sseHeapSample(
            protocol, MonoTime.now() - started, parser.events,
            producer.eventsProduced.load(), max(producer.eventsProduced.load() - parser.events, 0)
        )
        println(
            "SSE_RESULT protocol=${sseProtocolName(protocol)} " +
            "requestedSeconds=${settings.duration.toNanoseconds() / Duration.second.toNanoseconds()} " +
            "elapsedMs=${(MonoTime.now() - started).toNanoseconds() / 1000000} " +
            "minimumEvents=${settings.minimumEvents} events=${parser.events} " +
            "sequenceErrors=${parser.sequenceErrors} produced=${producer.eventsProduced.load()} " +
            "maxLeadEvents=${maximumLead} slowLeadEvents=${slowLead} " +
            "slowReadGapNs=${producer.slowWindowMaximumReadGapNs.load()} " +
            "serverReadCalls=${producer.readCalls.load()} cancelLatencyNs=${cancelLatencyNs} " +
            "siblingBefore=${siblingBefore} siblingAfter=${siblingAfter} " +
            "bodyLimitBytes=${SSE_PROFILE_BODY_LIMIT_BYTES} " +
            "applicationPendingBytes=${producer.pendingBytes()}"
        )
    } finally {
        client.close()
        if (!server.isClosed()) {
            let _ = server.shutdown(context: OperationContext(
                deadline: Some(Deadline.after(5 * Duration.second))
            ))
        }
        serving.get(5 * Duration.second)
        match (clientTls) { case Some(value) => value.close(); case None => () }
        match (tls) { case Some(value) => value.close(); case None => () }
    }
    @Expect(producer.isClosed())
}

private class SseProfileSettings {
    let duration: Duration
    let minimumEvents: Int64
    let slowConsumerDuration: Duration
    let slowConsumerDelay: Duration
    let siblingProbeDelay: Duration
    let sampleInterval: Duration
    let fastProducerDelay: Duration
    let steadyProducerDelay: Duration
    let eventsPerRead: Int64
    let clientReadBytes: Int64

    init(
        duration: Duration,
        minimumEvents: Int64,
        slowConsumerDuration: Duration,
        slowConsumerDelay: Duration,
        sampleInterval: Duration,
        fastProducerDelay: Duration,
        steadyProducerDelay: Duration,
        eventsPerRead: Int64,
        clientReadBytes: Int64
    ) {
        this.duration = duration
        this.minimumEvents = minimumEvents
        this.slowConsumerDuration = slowConsumerDuration
        this.slowConsumerDelay = slowConsumerDelay
        siblingProbeDelay = min(slowConsumerDuration / 2, duration / 2)
        this.sampleInterval = sampleInterval
        this.fastProducerDelay = fastProducerDelay
        this.steadyProducerDelay = steadyProducerDelay
        this.eventsPerRead = eventsPerRead
        this.clientReadBytes = clientReadBytes
    }

    static func load(): SseProfileSettings {
        let durationSeconds = ssePositiveEnvironment("WIRESTACK_SSE_DURATION_SECONDS", 3)
        let minimumEvents = ssePositiveEnvironment("WIRESTACK_SSE_MIN_EVENTS", 1000)
        let slowSeconds = min(
            ssePositiveEnvironment("WIRESTACK_SSE_SLOW_SECONDS", 1), durationSeconds
        )
        SseProfileSettings(
            Duration.second * durationSeconds,
            minimumEvents,
            Duration.second * slowSeconds,
            Duration.millisecond * ssePositiveEnvironment("WIRESTACK_SSE_SLOW_DELAY_MS", 2),
            Duration.second * ssePositiveEnvironment("WIRESTACK_SSE_SAMPLE_SECONDS", 1),
            Duration.millisecond * ssePositiveEnvironment("WIRESTACK_SSE_FAST_PRODUCER_MS", 1),
            Duration.millisecond * ssePositiveEnvironment("WIRESTACK_SSE_STEADY_PRODUCER_MS", 2),
            ssePositiveEnvironment("WIRESTACK_SSE_EVENTS_PER_READ", 256),
            ssePositiveEnvironment("WIRESTACK_SSE_CLIENT_READ_BYTES", 256)
        )
    }
}

private class SseProfileHandler <: HttpServerHandler {
    private let producer: SseProfileProducer
    init(producer: SseProfileProducer) { this.producer = producer }
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        let _ = context
        let _ = request.body.read(Array<Byte>(1, repeat: 0u8))
        if (request.target == "/sibling") {
            return HttpServerResponse(HttpResponse(
                200, "OK", ResponseBody(RequestBody.string("ok").open()),
                headers: HttpHeaders.builder().add("Content-Length", "2").build()
            ))
        }
        @Expect(request.target, "/events")
        let headers = if (request.version == HttpVersion.Http11) {
            HttpHeaders.builder()
                .add("Content-Type", "text/event-stream")
                .add("Cache-Control", "no-cache")
                .add("Transfer-Encoding", "chunked")
                .build()
        } else {
            HttpHeaders.builder()
                .add("Content-Type", "text/event-stream")
                .add("Cache-Control", "no-cache")
                .build()
        }
        HttpServerResponse(HttpResponse(
            200, "OK", ResponseBody(producer), headers: headers
        ))
    }
}

private class SseProfileProducer <: HttpBodyStream {
    let eventsProduced = AtomicInt64(0)
    let readCalls = AtomicInt64(0)
    let slowWindowMaximumReadGapNs = AtomicInt64(0)
    private let settings: SseProfileSettings
    private let started = MonoTime.now()
    private let mutex = Mutex()
    private var sequence: Int64 = 1
    private var pending = Array<Byte>()
    private var pendingOffset: Int64 = 0
    private var lastReadAt: ?MonoTime = None<MonoTime>
    private var closed = false

    init(settings: SseProfileSettings) { this.settings = settings }
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(destination: Array<Byte>): Int64 {
        if (destination.isEmpty()) { return 0 }
        let now = MonoTime.now()
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("SSE producer is closed") }
            if ((now - started) < settings.slowConsumerDuration) {
                if (let Some(previous) <- lastReadAt) {
                    sseAtomicMaximum(slowWindowMaximumReadGapNs, (now - previous).toNanoseconds())
                }
            }
            lastReadAt = Some(now)
        }
        let delay = if ((now - started) < settings.slowConsumerDuration) {
            settings.fastProducerDelay
        } else {
            settings.steadyProducerDelay
        }
        sleep(delay)
        var written: Int64 = 0
        var completed: Int64 = 0
        synchronized(mutex) {
            if (closed) { throw IllegalStateException("SSE producer is closed") }
            while (written < destination.size && completed < settings.eventsPerRead) {
                if (pendingOffset == pending.size) {
                    pending = "id:${sequence}\ndata:x\n\n".toArray()
                    pendingOffset = 0
                }
                let count = min(destination.size - written, pending.size - pendingOffset)
                for (index in 0..count) {
                    destination[written + index] = pending[pendingOffset + index]
                }
                written += count
                pendingOffset += count
                if (pendingOffset == pending.size) {
                    pending = Array<Byte>()
                    pendingOffset = 0
                    sequence += 1
                    completed += 1
                    eventsProduced.fetchAdd(1)
                }
            }
        }
        readCalls.fetchAdd(1)
        written
    }
    public func close(): Unit { synchronized(mutex) { closed = true; pending = Array<Byte>() } }
    public func isClosed(): Bool { synchronized(mutex) { closed } }
    func pendingBytes(): Int64 { synchronized(mutex) { pending.size - pendingOffset } }
}

private class SseSequenceParser {
    var events: Int64 = 0
    var sequenceErrors: Int64 = 0
    private var expected: Int64 = 1
    private var phase: Int64 = 0
    private var prefixIndex: Int64 = 0
    private var suffixIndex: Int64 = 0
    private var value: Int64 = 0
    private var digits: Int64 = 0
    private let prefix = "id:".toArray()
    private let suffix = "data:x\n\n".toArray()

    func accept(bytes: Array<Byte>, count: Int64): Unit {
        for (index in 0..count) { acceptByte(bytes[index]) }
    }

    private func acceptByte(byte: Byte): Unit {
        if (phase == 0) {
            if (byte != prefix[prefixIndex]) { malformed() }
            prefixIndex += 1
            if (prefixIndex == prefix.size) { phase = 1; prefixIndex = 0 }
            return
        }
        if (phase == 1) {
            if (byte >= b'0' && byte <= b'9') {
                if (value > (Int64.Max - Int64(byte - b'0')) / 10) { malformed() }
                value = value * 10 + Int64(byte - b'0')
                digits += 1
                return
            }
            if (byte != b'\n' || digits == 0) { malformed() }
            if (value != expected) { sequenceErrors += 1; malformed() }
            phase = 2
            return
        }
        if (byte != suffix[suffixIndex]) { malformed() }
        suffixIndex += 1
        if (suffixIndex == suffix.size) {
            events += 1
            expected += 1
            value = 0
            digits = 0
            suffixIndex = 0
            phase = 0
        }
    }

    private func malformed(): Nothing {
        sequenceErrors += 1
        throw Exception("malformed or out-of-sequence SSE event")
    }
}

private func ssePositiveEnvironment(name: String, fallback: Int64): Int64 {
    match (getVariable(name)) {
        case Some(value) =>
            let parsed = Int64.parse(value)
            if (parsed <= 0) { throw IllegalArgumentException("${name} must be positive") }
            parsed
        case None => fallback
    }
}

private func cancelSseHandle(handles: HttpCancellationHandles, protocol: HttpVersion): Bool {
    if (protocol == HttpVersion.Http2) {
        handles.stream.getOrThrow().cancel()
    } else {
        handles.request.getOrThrow().cancel()
    }
}

private func sseBodyReadCancelled(body: ResponseBody): Bool {
    try {
        let _ = body.read(Array<Byte>(1, repeat: 0u8))
        false
    } catch (error: NetworkException) {
        match (error.category) {
            case NetworkErrorCategory.Cancelled => true
            case _ => false
        }
    }
}

private func readSseSibling(client: HttpClient, scheme: String, port: UInt16): Bool {
    let response = client.get("${scheme}://example.com:${port}/sibling")
    try {
        let buffer = Array<Byte>(2, repeat: 0u8)
        response.body.read(buffer) == 2 && String.fromUtf8(buffer) == "ok"
    } finally {
        response.close()
    }
}

private func sseHeapSample(
    protocol: HttpVersion,
    elapsed: Duration,
    events: Int64,
    produced: Int64,
    lead: Int64
): Unit {
    gc(heavy: true)
    println(
        "SSE_SAMPLE protocol=${sseProtocolName(protocol)} " +
        "elapsedMs=${elapsed.toNanoseconds() / 1000000} events=${events} " +
        "produced=${produced} leadEvents=${lead} usedHeapBytes=${getUsedHeapSize()}"
    )
}

private func sseAtomicMaximum(value: AtomicInt64, candidate: Int64): Unit {
    var current = value.load()
    while (candidate > current) {
        if (value.compareAndSwap(current, candidate)) { return }
        current = value.load()
    }
}

private func sseProtocolName(protocol: HttpVersion): String {
    if (protocol == HttpVersion.Http2) { "h2" } else { "h1" }
}

private func sseProfileLoopback(port: UInt16): SocketEndpoint {
    SocketEndpoint(IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), port)
}
