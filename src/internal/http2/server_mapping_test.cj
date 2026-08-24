package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.Mutex
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http2ServerMappingTest {
    @TestCase
    func requestHeadMapsPseudoFieldsHostAndContentLength(): Unit {
        let head = decodeHttp2ServerRequestHead([
            HpackHeaderField(":method", "POST"), HpackHeaderField(":scheme", "https"),
            HpackHeaderField(":authority", "example.com"), HpackHeaderField(":path", "/upload?q=1"),
            HpackHeaderField("content-length", "3, 3"), HpackHeaderField("x-test", "yes")
        ], Http2StreamId(1u32))
        @Expect(head.method, HttpMethod("POST"))
        @Expect(head.target, "/upload?q=1")
        @Expect(head.scheme, Some("https"))
        @Expect(head.authority, "example.com")
        @Expect(head.headers.getFirst("host"), Some("example.com"))
        @Expect(head.headers.getFirst("x-test"), Some("yes"))
        @Expect(head.expectedContentLength, Some(3))
    }

    @TestCase
    func connectAndOptionsTargetsAreMappedStrictly(): Unit {
        let connect = decodeHttp2ServerRequestHead([
            HpackHeaderField(":method", "CONNECT"), HpackHeaderField(":authority", "example.com:443")
        ], Http2StreamId(1u32))
        @Expect(connect.target, "example.com:443")
        @Expect(connect.scheme.isNone(), true)

        let options = decodeHttp2ServerRequestHead([
            HpackHeaderField(":method", "OPTIONS"), HpackHeaderField(":scheme", "https"),
            HpackHeaderField(":authority", "example.com"), HpackHeaderField(":path", "*")
        ], Http2StreamId(3u32))
        @Expect(options.target, "*")

        expectServerProtocol({ =>
            let _ = decodeHttp2ServerRequestHead([
                HpackHeaderField(":method", "CONNECT"), HpackHeaderField(":authority", "example.com")
            ], Http2StreamId(5u32))
        })
    }

    @TestCase
    func requestRejectsPseudoOrderCaseConnectionAndAuthorityAmbiguity(): Unit {
        for (fields in [
            [HpackHeaderField("x", "1"), HpackHeaderField(":method", "GET")],
            regularRequestFields(extra: HpackHeaderField("X-Bad", "1")),
            regularRequestFields(extra: HpackHeaderField("connection", "close")),
            regularRequestFields(extra: HpackHeaderField("te", "gzip")),
            regularRequestFields(extra: HpackHeaderField("host", "other.test"))
        ]) {
            expectServerProtocol({ => let _ = decodeHttp2ServerRequestHead(fields, Http2StreamId(1u32)) })
        }
    }

    @TestCase
    func paddedDataReturnsAllFlowCreditAndPublishesTrailers(): Unit {
        let fixture = ServerFixture(http2Limits: Http2Limits(maxPendingWrites: 2u32))
        let exchange = fixture.open(Some(3))
        exchange.acceptData(serverData([2u8, b'a', b'b', b'c', 0u8, 0u8], padded: true))
        let buffer = Array<Byte>(2, repeat: 0)
        @Expect(exchange.request.body.read(buffer), 2)
        @Expect(buffer, [b'a', b'b'])
        @Expect(exchange.request.body.read(buffer), 1)
        @Expect(buffer[0], b'c')
        exchange.acceptTrailers([HpackHeaderField("digest", "done")], true)
        @Expect(exchange.request.body.trailer.getOrThrow().headers.getFirst("digest"), Some("done"))
        @Expect(fixture.sink.totalCredit(), 12)
        @Expect(fixture.registry.activeCount, 1)
        exchange.finishLocal()
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
    }

    @TestCase
    func requestQueueIsBoundedBeforeFlowAccountingMutates(): Unit {
        let fixture = ServerFixture(http2Limits: Http2Limits(maxPendingWrites: 2u32))
        let exchange = fixture.open(None<Int64>)
        exchange.acceptData(serverData([1u8]))
        exchange.acceptData(serverData([2u8]))
        expectServerProtocol({ => exchange.acceptData(serverData([3u8])) })
        @Expect(fixture.flow.snapshot(Http2StreamId(1u32)).bufferedReceiveBytes, 2)
        exchange.request.close()
        @Expect(fixture.flow.snapshot(Http2StreamId(1u32)).bufferedReceiveBytes, 0)
        @Expect(fixture.sink.totalCredit(), 4)
    }

    @TestCase
    func terminalLengthMismatchDoesNotConsumeFlowWindow(): Unit {
        let fixture = ServerFixture()
        let exchange = fixture.open(Some(2))
        expectServerProtocol({ => exchange.acceptData(serverData([1u8], endStream: true)) })
        @Expect(fixture.flow.snapshot(Http2StreamId(1u32)).bufferedReceiveBytes, 0)
        @Expect(fixture.flow.snapshot(Http2StreamId(1u32)).receiveWindow, 65535)
    }

    @TestCase
    func responseHeadersBodyFlowAndTrailersMapInOrder(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let response = HttpResponse(
            200, "OK", ResponseBody(RequestBody.string("abc").open()),
            headers: HttpHeaders.builder().add("X-Test", "yes").add("Set-Cookie", "secret").build()
        )
        let trailer = HttpTrailer(headers: HttpHeaders.builder().add("Digest", "done").build())
        let plan = mapHttp2ServerResponse(id, HttpMethod("GET"), Http2ServerResponse(response, trailer: trailer), flow)
        expectServerField(plan.initialHeaders, 0, ":status", "200")
        expectServerField(plan.initialHeaders, 1, "x-test", "yes")
        expectServerField(plan.initialHeaders, 2, "set-cookie", "secret")
        expectServerField(plan.initialHeaders, 3, "content-length", "3")
        @Expect(isNeverIndexedServer(plan.initialHeaders[2].mode))
        @Expect(!plan.endStreamOnHeaders)

        let body = plan.openBody()
        let data = body.next()
        @Expect(isServerData(data.kind))
        @Expect(data.frame.getOrThrow().payload, "abc".toArray())
        expectIllegalServer({ => let _ = body.next() })
        @Expect(data.beginData())
        let terminal = body.next()
        @Expect(isServerTrailers(terminal.kind))
        expectServerField(terminal.trailerFields, 0, "digest", "done")
        @Expect(body.isClosed())
        @Expect(flow.snapshot(id).sendWindow, 65532)
    }

    @TestCase
    func responseRulesCloseBodiesOnEveryTerminalOrFailurePath(): Unit {
        let flow = Http2FlowController()
        let id = Http2StreamId(1u32)
        flow.openStream(id)
        let headResponse = HttpResponse(200, "OK", ResponseBody(RequestBody.string("ignored").open()))
        let head = mapHttp2ServerResponse(id, HttpMethod("HEAD"), Http2ServerResponse(headResponse), flow)
        @Expect(head.endStreamOnHeaders)
        @Expect(headResponse.isClosed())

        let invalid = HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder().add("connection", "close").build()
        )
        expectServerMessage(Http2MessageErrorCode.ForbiddenConnectionHeader, { =>
            let _ = mapHttp2ServerResponse(id, HttpMethod("GET"), Http2ServerResponse(invalid), flow)
        })
        @Expect(invalid.isClosed())
    }

    @TestCase
    func handlerRunsOnceAndReleasesRequestOwnership(): Unit {
        let fixture = ServerFixture()
        let exchange = Http2ServerExchange.open(
            Http2StreamId(1u32), regularRequestFields(), true,
            fixture.registry, fixture.flow, fixture.sink
        )
        let plan = exchange.start(EmptyServerHandler()).get(Duration.second)
        @Expect(exchange.request.isClosed())
        @Expect(!plan.endStreamOnHeaders)
        expectIllegalServer({ => let _ = exchange.start(EmptyServerHandler()) })
        plan.close()
        exchange.finishLocal()
        @Expect(fixture.registry.activeCount, 0)
        @Expect(fixture.flow.activeStreamCount, 0)
    }
}

private class EmptyServerHandler <: Http2ServerHandler {
    public func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse {
        let _ = request
        let _ = context
        Http2ServerResponse(HttpResponse(200, "OK", ResponseBody.empty()))
    }
}

private class RecordingServerSink <: Http2ServerControlSink {
    private let mutex = Mutex()
    private let recorded = ArrayList<Http2Frame>()
    public func submit(frames: Array<Http2Frame>): Unit {
        synchronized(mutex) { for (frame in frames) { recorded.add(frame) } }
    }
    func totalCredit(): Int64 {
        synchronized(mutex) {
            var total: Int64 = 0
            for (frame in recorded) { total += Int64(decodeHttp2WindowUpdate(frame)) }
            total
        }
    }
}

private class ServerFixture {
    let registry: Http2StreamRegistry
    let flow: Http2FlowController
    let sink = RecordingServerSink()
    let http2Limits: Http2Limits
    init(http2Limits!: Http2Limits = Http2Limits()) {
        this.http2Limits = http2Limits
        registry = Http2StreamRegistry(Http2ConnectionRole.Server, limits: http2Limits)
        flow = Http2FlowController(limits: http2Limits)
    }
    func open(contentLength: ?Int64): Http2ServerExchange {
        let fields = ArrayList<HpackHeaderField>()
        for (field in regularRequestFields()) { fields.add(field) }
        if (let Some(value) <- contentLength) { fields.add(HpackHeaderField("content-length", "${value}")) }
        Http2ServerExchange.open(
            Http2StreamId(1u32), fields.toArray(), false, registry, flow, sink,
            http2Limits: http2Limits
        )
    }
}

private func regularRequestFields(extra!: ?HpackHeaderField = None<HpackHeaderField>): Array<HpackHeaderField> {
    let fields = ArrayList<HpackHeaderField>()
    fields.add(HpackHeaderField(":method", "POST"))
    fields.add(HpackHeaderField(":scheme", "https"))
    fields.add(HpackHeaderField(":authority", "example.com"))
    fields.add(HpackHeaderField(":path", "/"))
    if (let Some(value) <- extra) { fields.add(value) }
    fields.toArray()
}

private func serverData(
    payload: Array<Byte>, padded!: Bool = false, endStream!: Bool = false
): Http2Frame {
    let raw = (if (padded) { 0x08u8 } else { 0u8 }) | (if (endStream) { 0x01u8 } else { 0u8 })
    Http2Frame(
        Http2FrameHeader(
            UInt32(payload.size), Http2FrameType.Data,
            Http2Flags(raw: raw), Http2StreamId(1u32)
        ), payload
    )
}

private func expectServerField(
    fields: Array<HpackFieldEncoding>, index: Int64, name: String, value: String
): Unit {
    @Expect(fields[index].field.name, name)
    @Expect(fields[index].field.value, value)
}

private func expectServerProtocol(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == 1u32 && isServerStreamScope(error.scope)
    }
    @Expect(matched)
}

private func expectServerMessage(code: Http2MessageErrorCode, action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2MessageException) { matched = sameServerCode(error.code, code) }
    @Expect(matched)
}

private func expectIllegalServer(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (_: IllegalStateException) { matched = true }
    @Expect(matched)
}

private func sameServerCode(left: Http2MessageErrorCode, right: Http2MessageErrorCode): Bool {
    match ((left, right)) {
        case (Http2MessageErrorCode.ForbiddenConnectionHeader, Http2MessageErrorCode.ForbiddenConnectionHeader) => true
        case _ => false
    }
}

private func isServerStreamScope(value: Http2ErrorScope): Bool {
    match (value) { case Http2ErrorScope.Stream(_) => true; case _ => false }
}

private func isNeverIndexedServer(value: HpackIndexingMode): Bool {
    match (value) { case HpackIndexingMode.NeverIndexed => true; case _ => false }
}

private func isServerData(value: Http2ServerBodyEventKind): Bool {
    match (value) { case Http2ServerBodyEventKind.Data => true; case _ => false }
}

private func isServerTrailers(value: Http2ServerBodyEventKind): Bool {
    match (value) { case Http2ServerBodyEventKind.Trailers => true; case _ => false }
}
