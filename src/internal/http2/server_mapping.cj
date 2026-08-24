package wirestack.internal.http2

import std.collection.ArrayList
import std.sync.Mutex
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

/** Receives WINDOW_UPDATE frames produced by application body consumption. */
public interface Http2ServerControlSink {
    func submit(frames: Array<Http2Frame>): Unit
}

public class Http2ServerRequestHead {
    public let method: HttpMethod
    public let target: String
    public let scheme: ?String
    public let authority: String
    public let headers: HttpHeaders
    public let expectedContentLength: ?Int64

    internal init(
        method: HttpMethod,
        target: String,
        scheme: ?String,
        authority: String,
        headers: HttpHeaders,
        expectedContentLength: ?Int64
    ) {
        this.method = method
        this.target = target
        this.scheme = scheme
        this.authority = authority
        this.headers = headers
        this.expectedContentLength = expectedContentLength
    }
}

/** Protocol-neutral server request owned by one HTTP/2 stream exchange. */
public class Http2ServerRequest <: Resource {
    public let streamId: Http2StreamId
    public let head: Http2ServerRequestHead
    public let body: ResponseBody

    internal init(streamId: Http2StreamId, head: Http2ServerRequestHead, body: ResponseBody) {
        this.streamId = streamId
        this.head = head
        this.body = body
    }

    public func close(): Unit { body.close() }
    public func isClosed(): Bool { body.isClosed() }
}

public class Http2ServerResponse {
    public let response: HttpResponse
    public let trailer: HttpTrailer

    public init(response: HttpResponse, trailer!: HttpTrailer = HttpTrailer()) {
        this.response = response
        this.trailer = trailer
    }
}

public interface Http2ServerHandler {
    func handle(request: Http2ServerRequest, context: OperationContext): Http2ServerResponse
}

/**
 * One peer-initiated server exchange. The connection reader feeds DATA and
 * trailing HEADERS while a lightweight handler task may consume the body.
 */
public class Http2ServerExchange <: Http2StreamResetListener {
    public let streamId: Http2StreamId
    public let request: Http2ServerRequest
    private let registry: Http2StreamRegistry
    private let flow: Http2FlowController
    private let sink: Http2ServerControlSink
    private let bodyChannel: Http2ServerBodyChannel
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let mutex = Mutex()
    private var handlerClaimed = false
    private var peerEnded = false
    private var localEnded = false

    private init(
        streamId: Http2StreamId,
        request: Http2ServerRequest,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        sink: Http2ServerControlSink,
        bodyChannel: Http2ServerBodyChannel,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        peerEnded: Bool
    ) {
        this.streamId = streamId
        this.request = request
        this.registry = registry
        this.flow = flow
        this.sink = sink
        this.bodyChannel = bodyChannel
        this.limits = limits
        this.http2Limits = http2Limits
        this.peerEnded = peerEnded
    }

    public static func open(
        streamId: Http2StreamId,
        fields: Array<HpackHeaderField>,
        endStream: Bool,
        registry: Http2StreamRegistry,
        flow: Http2FlowController,
        sink: Http2ServerControlSink,
        context!: OperationContext = OperationContext.background(),
        limits!: HttpLimits = HttpLimits(),
        http2Limits!: Http2Limits = Http2Limits()
    ): Http2ServerExchange {
        let _ = registry.openPeer(streamId, endStream: endStream)
        var flowOpened = false
        try {
            flow.openStream(streamId)
            flowOpened = true
            let head = decodeHttp2ServerRequestHead(fields, streamId, limits: limits, http2Limits: http2Limits)
            if (endStream) { validateServerRequestEnd(head.expectedContentLength, 0, streamId) }
            let channel = Http2ServerBodyChannel(
                streamId, head.expectedContentLength, flow, sink, context, limits, http2Limits
            )
            if (endStream) { channel.finish(None<HttpTrailer>) }
            let body = ResponseBody(channel, trailerProvider: { => channel.trailer })
            Http2ServerExchange(
                streamId, Http2ServerRequest(streamId, head, body), registry, flow, sink,
                channel, limits, http2Limits, endStream
            )
        } catch (error: Exception) {
            if (flowOpened) { let updates = flow.closeStream(streamId); if (!updates.isEmpty()) { sink.submit(updates) } }
            try { let _ = registry.reset(streamId, Http2ErrorCode.ProtocolError, "HTTP/2 request mapping failed") }
            catch (_: Exception) {}
            throw error
        }
    }

    /** Starts exactly one handler task so the single reader can continue feeding DATA. */
    public func start(
        handler: Http2ServerHandler,
        context!: OperationContext = OperationContext.background()
    ): Future<Http2ServerResponsePlan> {
        synchronized(mutex) {
            if (handlerClaimed) { throw IllegalStateException("HTTP/2 server handler already started") }
            handlerClaimed = true
        }
        spawn {
            try {
                let handled = handler.handle(request, context)
                mapHttp2ServerResponse(
                    streamId, request.head.method, handled, flow,
                    limits: limits, http2Limits: http2Limits
                )
            } finally {
                request.close()
            }
        }
    }

    /** Accepts one DATA frame without blocking the connection reader on application consumption. */
    public func acceptData(frame: Http2Frame): Unit {
        requireServerDataFrame(frame, streamId)
        synchronized(mutex) {
            if (peerEnded) { serverStreamError(streamId, "HTTP/2 request DATA arrived after END_STREAM") }
        }
        let decoded = decodeServerData(frame, streamId)
        bodyChannel.offer(decoded.data, Int64(frame.header.length), frame.header.flags.isEndStream())
        if (frame.header.flags.isEndStream()) { finishPeerSide() }
    }

    /** Accepts the one terminal trailing HEADERS block. */
    public func acceptTrailers(fields: Array<HpackHeaderField>, endStream: Bool): Unit {
        synchronized(mutex) {
            if (peerEnded) { serverStreamError(streamId, "HTTP/2 request trailers arrived after END_STREAM") }
        }
        if (!endStream) { serverStreamError(streamId, "HTTP/2 request trailers must carry END_STREAM") }
        validateServerH2Fields(fields, streamId, http2Limits)
        let trailer = decodeHttp2TrailerFields(fields, streamId, limits: limits)
        bodyChannel.finish(Some(trailer))
        finishPeerSide()
    }

    /** Called only after the local END_STREAM frame has been accepted by the writer path. */
    public func finishLocal(): Unit {
        synchronized(mutex) {
            if (localEnded) { throw IllegalStateException("HTTP/2 server response already ended") }
            localEnded = true
        }
        registry.localEnd(streamId)
        cleanupFlowIfClosed()
    }

    /** Wakes a blocked handler body read after reset cleanup has claimed this stream. */
    public func streamReset(event: Http2StreamResetEvent): Unit {
        if (event.streamId.value == streamId.value) { bodyChannel.reset(event) }
    }

    private func finishPeerSide(): Unit {
        synchronized(mutex) { peerEnded = true }
        registry.peerEnd(streamId)
        cleanupFlowIfClosed()
    }

    private func cleanupFlowIfClosed(): Unit {
        if (registry.stream(streamId).isNone()) {
            let updates = flow.closeStream(streamId)
            if (!updates.isEmpty()) { sink.submit(updates) }
        }
    }
}

private class Http2ServerBodyChannel <: HttpBodyStream {
    private let streamId: Http2StreamId
    private let expectedContentLength: ?Int64
    private let flow: Http2FlowController
    private let sink: Http2ServerControlSink
    private let context: OperationContext
    private let limits: HttpLimits
    private let maxSegments: Int64
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let segments = ArrayList<Http2ServerBodySegment>()
    private var receivedBytes: Int64 = 0
    private var eof = false
    private var applicationClosed = false
    private var retainedTrailer: ?HttpTrailer = None<HttpTrailer>
    private var resetEvent: ?Http2StreamResetEvent = None<Http2StreamResetEvent>

    prop trailer: ?HttpTrailer { get() { synchronized(mutex) { retainedTrailer } } }
    public prop contentLength: ?Int64 { get() { expectedContentLength } }

    init(
        streamId: Http2StreamId,
        expectedContentLength: ?Int64,
        flow: Http2FlowController,
        sink: Http2ServerControlSink,
        context: OperationContext,
        limits: HttpLimits,
        http2Limits: Http2Limits
    ) {
        this.streamId = streamId
        this.expectedContentLength = expectedContentLength
        this.flow = flow
        this.sink = sink
        this.context = context
        this.limits = limits
        maxSegments = Int64(http2Limits.maxPendingWrites)
    }

    func offer(data: Array<Byte>, flowBytes: Int64, endStream: Bool): Unit {
        if (flowBytes < data.size) { serverStreamError(streamId, "HTTP/2 DATA accounting is smaller than content") }
        var immediateCredit: Int64 = 0
        synchronized(mutex) {
            if (eof) { serverStreamError(streamId, "HTTP/2 DATA arrived after request completion") }
            if (data.size > limits.maxBodyBytes - receivedBytes) {
                serverStreamError(streamId, "HTTP/2 request body exceeds the configured limit")
            }
            if (let Some(expected) <- expectedContentLength) {
                if (data.size > expected - min(receivedBytes, expected)) {
                    serverStreamError(streamId, "HTTP/2 request body exceeds Content-Length")
                }
            }
            if (!applicationClosed && !data.isEmpty() && segments.size >= maxSegments) {
                serverStreamError(streamId, "HTTP/2 request body segment queue reached its bound")
            }
            let nextReceivedBytes = receivedBytes + data.size
            if (endStream) {
                validateServerRequestEnd(expectedContentLength, nextReceivedBytes, streamId)
            }
            flow.receiveData(streamId, flowBytes)
            receivedBytes = nextReceivedBytes
            if (applicationClosed || data.isEmpty()) {
                immediateCredit = flowBytes
            } else {
                segments.add(Http2ServerBodySegment(data, flowBytes))
            }
            if (endStream) {
                eof = true
            }
            changed.notifyAll()
        }
        publishCredit(immediateCredit)
    }

    func finish(trailer: ?HttpTrailer): Unit {
        synchronized(mutex) {
            if (eof) { serverStreamError(streamId, "HTTP/2 request already completed") }
            validateServerRequestEnd(expectedContentLength, receivedBytes, streamId)
            retainedTrailer = trailer
            eof = true
            changed.notifyAll()
        }
    }

    func reset(event: Http2StreamResetEvent): Unit {
        synchronized(mutex) {
            if (resetEvent.isSome()) { return }
            resetEvent = Some(event)
            segments.clear()
            eof = true
            changed.notifyAll()
        }
    }

    public func read(destination: Array<Byte>): Int64 {
        if (destination.isEmpty()) { return 0 }
        let registration = context.cancellation.register { => wake() }
        var updates = Array<Http2Frame>()
        try {
            let result = synchronized(mutex) {
                while (segments.isEmpty() && !eof && !applicationClosed && resetEvent.isNone()) {
                    checkServerBodyContext(context)
                    match (context.deadline) {
                        case Some(deadline) => changed.wait(timeout: deadline.remaining())
                        case None => changed.wait()
                    }
                }
                checkServerBodyContext(context)
                if (let Some(event) <- resetEvent) {
                    throw Http2ProtocolException(
                        event.code, Http2ErrorScope.Stream(event.streamId), event.reason
                    )
                }
                if (applicationClosed) {
                    throw Http2MessageException(
                        Http2MessageErrorCode.InvalidMessageSequence, "HTTP/2 request body is closed"
                    )
                }
                if (segments.isEmpty()) { return 0 }
                let segment = segments[0]
                let count = min(destination.size, segment.remainingData)
                for (index in 0..count) { destination[index] = segment.data[segment.offset + index] }
                segment.offset += count
                let credit = if (segment.remainingData == 0) { segment.remainingFlowBytes } else { count }
                segment.remainingFlowBytes -= credit
                if (segment.remainingData == 0) { let _ = segments.remove(at: 0) }
                if (credit > 0) { updates = flow.consumeReceived(streamId, credit) }
                count
            }
            if (!updates.isEmpty()) { sink.submit(updates) }
            result
        } finally {
            registration.unregister()
        }
    }

    public func close(): Unit {
        var updates = Array<Http2Frame>()
        synchronized(mutex) {
            if (applicationClosed) { return }
            applicationClosed = true
            var credit: Int64 = 0
            for (segment in segments) { credit += segment.remainingFlowBytes }
            segments.clear()
            if (credit > 0) { updates = flow.consumeReceived(streamId, credit) }
            changed.notifyAll()
        }
        if (!updates.isEmpty()) { sink.submit(updates) }
    }

    public func isClosed(): Bool { synchronized(mutex) { applicationClosed } }

    private func publishCredit(bytes: Int64): Unit {
        if (bytes > 0) { sink.submit(flow.consumeReceived(streamId, bytes)) }
    }

    private func wake(): Unit { synchronized(mutex) { changed.notifyAll() } }
}

private class Http2ServerBodySegment {
    let data: Array<Byte>
    var offset: Int64 = 0
    var remainingFlowBytes: Int64
    prop remainingData: Int64 { get() { data.size - offset } }

    init(data: Array<Byte>, flowBytes: Int64) {
        this.data = data.clone()
        remainingFlowBytes = flowBytes
    }
}

private struct Http2DecodedServerData {
    let data: Array<Byte>
    init(data: Array<Byte>) { this.data = data }
}

public enum Http2ServerBodyEventKind {
    | Data
    | EndData
    | Trailers
}

/** One reserved DATA frame or one terminal response-body event. */
public class Http2ServerBodyEvent {
    public let kind: Http2ServerBodyEventKind
    public let frame: ?Http2Frame
    private let permit: ?Http2SendPermit
    private let owner: ?Http2ServerResponseBody
    private let ownedTrailerFields: Array<HpackFieldEncoding>

    public prop trailerFields: Array<HpackFieldEncoding> { get() { ownedTrailerFields.clone() } }

    internal init(
        kind: Http2ServerBodyEventKind,
        frame!: ?Http2Frame = None<Http2Frame>,
        permit!: ?Http2SendPermit = None<Http2SendPermit>,
        owner!: ?Http2ServerResponseBody = None<Http2ServerResponseBody>,
        trailerFields!: Array<HpackFieldEncoding> = Array<HpackFieldEncoding>()
    ) {
        this.kind = kind
        this.frame = frame
        this.permit = permit
        this.owner = owner
        ownedTrailerFields = trailerFields.clone()
    }

    /** Consumes reserved flow credit immediately before the DATA write path. */
    public func beginData(context!: OperationContext = OperationContext.background()): Bool {
        match (permit) {
            case Some(value) =>
                try { value.beginSend(context: context) }
                finally { if (let Some(body) <- owner) { body.completePermit(value) } }
            case None => throw IllegalStateException("HTTP/2 terminal body event has no DATA permit")
        }
    }

    public func cancelData(): Bool {
        match (permit) {
            case Some(value) =>
                let result = value.cancel()
                if (let Some(body) <- owner) { body.completePermit(value) }
                result
            case None => false
        }
    }
}

public class Http2ServerResponsePlan <: Resource {
    private let ownedInitialHeaders: Array<HpackFieldEncoding>
    private let response: HttpResponse
    private let trailer: HttpTrailer
    private let flow: Http2FlowController
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let expectedContentLength: ?Int64
    private var opened = false
    public let streamId: Http2StreamId
    public let endStreamOnHeaders: Bool

    public prop initialHeaders: Array<HpackFieldEncoding> { get() { ownedInitialHeaders.clone() } }

    internal init(
        streamId: Http2StreamId,
        initialHeaders: Array<HpackFieldEncoding>,
        response: HttpResponse,
        trailer: HttpTrailer,
        flow: Http2FlowController,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        expectedContentLength: ?Int64,
        endStreamOnHeaders: Bool
    ) {
        this.streamId = streamId
        ownedInitialHeaders = initialHeaders.clone()
        this.response = response
        this.trailer = trailer
        this.flow = flow
        this.limits = limits
        this.http2Limits = http2Limits
        this.expectedContentLength = expectedContentLength
        this.endStreamOnHeaders = endStreamOnHeaders
        if (endStreamOnHeaders) { response.close() }
    }

    public func openBody(): Http2ServerResponseBody {
        if (endStreamOnHeaders) { throw IllegalStateException("HTTP/2 response ended on initial HEADERS") }
        if (opened) { throw IllegalStateException("HTTP/2 response body already opened") }
        opened = true
        Http2ServerResponseBody(
            streamId, response, trailer, flow, limits, http2Limits, expectedContentLength
        )
    }

    public func close(): Unit { response.close() }
    public func isClosed(): Bool { response.isClosed() }
}

/** One-frame-prefetch response source; memory remains bounded while flow credit stalls. */
public class Http2ServerResponseBody <: Resource {
    private let streamId: Http2StreamId
    private let response: HttpResponse
    private let trailer: HttpTrailer
    private let flow: Http2FlowController
    private let limits: HttpLimits
    private let http2Limits: Http2Limits
    private let expectedContentLength: ?Int64
    private var staging = Array<Byte>()
    private var stagingOffset: Int64 = 0
    private var consumed: Int64 = 0
    private var eof = false
    private var terminalClaimed = false
    private var closed = false
    private var outstanding: ?Http2SendPermit = None<Http2SendPermit>

    internal init(
        streamId: Http2StreamId,
        response: HttpResponse,
        trailer: HttpTrailer,
        flow: Http2FlowController,
        limits: HttpLimits,
        http2Limits: Http2Limits,
        expectedContentLength: ?Int64
    ) {
        this.streamId = streamId
        this.response = response
        this.trailer = trailer
        this.flow = flow
        this.limits = limits
        this.http2Limits = http2Limits
        this.expectedContentLength = expectedContentLength
    }

    public func next(
        context!: OperationContext = OperationContext.background()
    ): Http2ServerBodyEvent {
        requireServerResponseBodyOpen()
        if (terminalClaimed) { throw IllegalStateException("HTTP/2 response body already produced END_STREAM") }
        if (outstanding.isSome()) { throw IllegalStateException("HTTP/2 response DATA permit is still outstanding") }
        if (stagingOffset == staging.size && !eof) { fillStaging() }
        if (stagingOffset < staging.size) {
            let requested = staging.size - stagingOffset
            let permit = flow.reserveSend(streamId, requested, context: context)
            let count = permit.amount
            let payload = Array<Byte>(count, repeat: 0)
            for (index in 0..count) { payload[index] = staging[stagingOffset + index] }
            stagingOffset += count
            if (stagingOffset == staging.size) { staging = Array<Byte>(); stagingOffset = 0 }
            outstanding = Some(permit)
            let frame = Http2Frame(
                Http2FrameHeader(UInt32(count), Http2FrameType.Data, Http2Flags(), streamId, limits: http2Limits),
                payload
            )
            return Http2ServerBodyEvent(
                Http2ServerBodyEventKind.Data, frame: Some(frame), permit: Some(permit), owner: Some(this)
            )
        }
        terminalClaimed = true
        close()
        let trailers = encodeHttp2TrailerFields(trailer, limits: http2Limits)
        if (trailers.isEmpty()) { Http2ServerBodyEvent(Http2ServerBodyEventKind.EndData) }
        else { Http2ServerBodyEvent(Http2ServerBodyEventKind.Trailers, trailerFields: trailers) }
    }

    public func close(): Unit {
        if (!closed) {
            if (let Some(permit) <- outstanding) { let _ = permit.cancel() }
            outstanding = None<Http2SendPermit>
            closed = true
            response.close()
        }
    }

    public func isClosed(): Bool { closed }

    private func fillStaging(): Unit {
        let maximum = min(Int64(http2Limits.maxFrameSize), 16384)
        let buffer = Array<Byte>(maximum, repeat: 0)
        let count = response.body.read(buffer)
        if (count < 0 || count > buffer.size) { serverLocalBodyError("HTTP/2 response body returned invalid progress") }
        if (count == 0) {
            if (let Some(expected) <- expectedContentLength) {
                if (consumed != expected) { serverLocalBodyError("HTTP/2 response body ended before Content-Length") }
            }
            eof = true
            return
        }
        if (count > limits.maxBodyBytes - consumed) {
            serverLocalBodyError("HTTP/2 response body exceeds the configured limit")
        }
        consumed += count
        if (let Some(expected) <- expectedContentLength) {
            if (consumed > expected) { serverLocalBodyError("HTTP/2 response body exceeds Content-Length") }
        }
        staging = Array<Byte>(count, repeat: 0)
        for (index in 0..count) { staging[index] = buffer[index] }
        stagingOffset = 0
    }

    private func requireServerResponseBodyOpen(): Unit {
        if (closed) { throw IllegalStateException("HTTP/2 response body is closed") }
    }

    internal func completePermit(permit: Http2SendPermit): Unit {
        if (let Some(current) <- outstanding) {
            if (current.id == permit.id) { outstanding = None<Http2SendPermit> }
        }
    }

    private func serverLocalBodyError(message: String): Nothing {
        try { close() } catch (_: Exception) {}
        throw Http2MessageException(Http2MessageErrorCode.BodyLengthMismatch, message)
    }
}

/** Strictly maps one handler-owned response; ownership is closed on every failure. */
public func mapHttp2ServerResponse(
    streamId: Http2StreamId,
    requestMethod: HttpMethod,
    handled: Http2ServerResponse,
    flow: Http2FlowController,
    limits!: HttpLimits = HttpLimits(),
    http2Limits!: Http2Limits = Http2Limits()
): Http2ServerResponsePlan {
    let response = handled.response
    try {
        let status = response.status
        if (status < 200 || status > 599) {
            serverLocalHeaderError("HTTP/2 handler response must be one final status")
        }
        let successfulConnect = requestMethod == HttpMethod("CONNECT") && status >= 200 && status < 300
        let bodyless = requestMethod == HttpMethod("HEAD") || status == 204 || status == 205 || status == 304
        let fields = ArrayList<HpackFieldEncoding>()
        fields.add(serverEncoding(":status", "${status}"))
        let declared = encodeServerResponseHeaders(response.headers, fields)
        validateServerResponseBody(
            requestMethod, response.body, handled.trailer, status, bodyless, successfulConnect, declared
        )
        if (declared.isNone() && !bodyless && !successfulConnect) {
            if (let Some(length) <- response.body.contentLength) {
                if (length > 0) { fields.add(serverEncoding("content-length", "${length}")) }
            }
        }
        let encoded = fields.toArray()
        validateServerEncodedFields(encoded, http2Limits)
        if (!handled.trailer.headers.entries.isEmpty()) {
            let _ = encodeHttp2TrailerFields(handled.trailer, limits: http2Limits)
        }
        let expectedLength = match (declared) {
            case Some(value) => Some(value)
            case None => response.body.contentLength
        }
        Http2ServerResponsePlan(
            streamId, encoded, response, handled.trailer, flow, limits, http2Limits,
            expectedLength, bodyless
        )
    } catch (error: Exception) {
        try { response.close() } catch (_: Exception) {}
        throw error
    }
}

private func encodeServerResponseHeaders(
    headers: HttpHeaders,
    output: ArrayList<HpackFieldEncoding>
): ?Int64 {
    var contentLength: ?Int64 = None<Int64>
    for (entry in headers.entries) {
        let name = entry.name.toAsciiLower()
        if (serverForbiddenConnectionField(name) || name == "te") {
            throw Http2MessageException(
                Http2MessageErrorCode.ForbiddenConnectionHeader,
                "HTTP/2 response contains a forbidden connection field"
            )
        }
        if (name == "content-length") {
            let value = serverParseLocalDecimal(entry.value)
            if (let Some(existing) <- contentLength) {
                if (existing != value) { serverLocalContentLengthError() }
            } else { contentLength = Some(value) }
            continue
        }
        output.add(serverEncoding(name, entry.value, sensitive: serverSensitiveField(name)))
    }
    if (let Some(value) <- contentLength) { output.add(serverEncoding("content-length", "${value}")) }
    contentLength
}

private func validateServerResponseBody(
    requestMethod: HttpMethod,
    body: ResponseBody,
    trailer: HttpTrailer,
    status: Int64,
    bodyless: Bool,
    successfulConnect: Bool,
    declared: ?Int64
): Unit {
    if ((status == 204 || successfulConnect) && declared.isSome()) {
        serverLocalHeaderError("HTTP/2 response status forbids Content-Length")
    }
    if (status == 205) {
        if (let Some(value) <- declared) { if (value != 0) { serverLocalContentLengthError() } }
    }
    if (bodyless) {
        if (requestMethod != HttpMethod("HEAD") && status != 304 && body.contentLength != Some(0)) {
            throw Http2MessageException(Http2MessageErrorCode.BodyLengthMismatch, "HTTP/2 bodyless response has content")
        }
        if (!trailer.headers.entries.isEmpty()) { serverLocalHeaderError("HTTP/2 bodyless response cannot have trailers") }
        return
    }
    if (let Some(value) <- declared) {
        if (let Some(actual) <- body.contentLength) {
            if (actual != value) { serverLocalContentLengthError() }
        }
    }
}

private func validateServerEncodedFields(fields: Array<HpackFieldEncoding>, limits: Http2Limits): Unit {
    if (UInt64(fields.size) > UInt64(limits.maxHeaderFields)) { serverLocalHeaderError("HTTP/2 response field count exceeds limit") }
    var bytes = 0u64
    for (field in fields) {
        let size = field.field.tableSize
        if (size > UInt64(limits.maxHeaderListBytes) - min(bytes, UInt64(limits.maxHeaderListBytes))) {
            serverLocalHeaderError("HTTP/2 response field list exceeds limit")
        }
        bytes += size
    }
}

public func decodeHttp2ServerRequestHead(
    fields: Array<HpackHeaderField>,
    streamId: Http2StreamId,
    limits!: HttpLimits = HttpLimits(),
    http2Limits!: Http2Limits = Http2Limits()
): Http2ServerRequestHead {
    validateServerH2Fields(fields, streamId, http2Limits)
    var method: ?HttpMethod = None<HttpMethod>
    var scheme: ?String = None<String>
    var authority: ?String = None<String>
    var path: ?String = None<String>
    var sawRegular = false
    let regular = ArrayList<HttpHeader>()
    var host: ?String = None<String>
    var contentLength: ?Int64 = None<Int64>
    for (field in fields) {
        serverValidateInboundName(field.name, streamId)
        if (field.name.startsWith(":")) {
            if (sawRegular) { serverStreamError(streamId, "HTTP/2 request pseudo-header follows a regular field") }
            match (field.name) {
                case ":method" =>
                    if (method.isSome()) { serverStreamError(streamId, "HTTP/2 request repeats :method") }
                    method = Some(serverParseMethod(field.value, streamId))
                case ":scheme" =>
                    if (scheme.isSome()) { serverStreamError(streamId, "HTTP/2 request repeats :scheme") }
                    if (field.value != "http" && field.value != "https") {
                        serverStreamError(streamId, "HTTP/2 request :scheme is unsupported")
                    }
                    scheme = Some(field.value)
                case ":authority" =>
                    if (authority.isSome()) { serverStreamError(streamId, "HTTP/2 request repeats :authority") }
                    authority = Some(field.value)
                case ":path" =>
                    if (path.isSome()) { serverStreamError(streamId, "HTTP/2 request repeats :path") }
                    path = Some(field.value)
                case _ => serverStreamError(streamId, "HTTP/2 request contains an unsupported pseudo-header")
            }
        } else {
            sawRegular = true
            if (serverForbiddenConnectionField(field.name)) {
                serverStreamError(streamId, "HTTP/2 request contains a connection-specific field")
            }
            if (field.name == "te" && field.value.toAsciiLower().trimAscii() != "trailers") {
                serverStreamError(streamId, "HTTP/2 request TE field may contain only trailers")
            }
            if (field.name == "host") {
                if (host.isSome()) { serverStreamError(streamId, "HTTP/2 request repeats Host") }
                host = Some(field.value)
                continue
            }
            if (field.name == "content-length") {
                let values = serverSplitComma(field.value, streamId)
                for (value in values) {
                    let parsed = serverParseInboundDecimal(value, streamId)
                    if (let Some(existing) <- contentLength) {
                        if (existing != parsed) { serverStreamError(streamId, "HTTP/2 Content-Length values conflict") }
                    } else { contentLength = Some(parsed) }
                }
                continue
            }
            if (field.name == "trailer") { serverValidateTrailerDeclaration(field.value, streamId) }
            try { regular.add(HttpHeader(field.name, field.value)) }
            catch (_: IllegalArgumentException) { serverStreamError(streamId, "HTTP/2 request field is invalid") }
        }
    }
    let resolvedMethod = match (method) {
        case Some(value) => value
        case None => serverStreamError(streamId, "HTTP/2 request requires :method")
    }
    let resolvedAuthority = match (authority) {
        case Some(value) => value
        case None => match (host) {
            case Some(value) => value
            case None => serverStreamError(streamId, "HTTP/2 request requires :authority or Host")
        }
    }
    let connect = resolvedMethod == HttpMethod("CONNECT")
    let target: String
    let retainedScheme: ?String
    if (connect) {
        if (scheme.isSome() || path.isSome()) {
            serverStreamError(streamId, "HTTP/2 CONNECT request forbids :scheme and :path")
        }
        serverValidateConnectAuthority(resolvedAuthority, streamId)
        target = resolvedAuthority
        retainedScheme = None<String>
    } else {
        let resolvedScheme = match (scheme) {
            case Some(value) => value
            case None => serverStreamError(streamId, "HTTP/2 request requires :scheme")
        }
        let resolvedPath = match (path) {
            case Some(value) => value
            case None => serverStreamError(streamId, "HTTP/2 request requires :path")
        }
        serverValidateRequestTarget(resolvedMethod, resolvedScheme, resolvedAuthority, resolvedPath, streamId)
        target = resolvedPath
        retainedScheme = Some(resolvedScheme)
    }
    if (let Some(value) <- host) {
        serverValidateMatchingAuthority(value, resolvedAuthority, if (connect) { "http" } else { scheme.getOrThrow() }, streamId)
    }
    try { regular.add(HttpHeader("host", resolvedAuthority)) }
    catch (_: IllegalArgumentException) { serverStreamError(streamId, "HTTP/2 request authority is not a valid Host value") }
    if (let Some(value) <- contentLength) {
        if (value > limits.maxBodyBytes) { serverStreamError(streamId, "HTTP/2 request Content-Length exceeds body limit") }
        regular.add(HttpHeader("content-length", "${value}"))
    }
    let headers = try { HttpHeaders(entries: regular.toArray(), limits: limits) }
    catch (_: IllegalArgumentException) { serverStreamError(streamId, "HTTP/2 request headers exceed configured limits") }
    Http2ServerRequestHead(resolvedMethod, target, retainedScheme, resolvedAuthority, headers, contentLength)
}

private func decodeServerData(frame: Http2Frame, streamId: Http2StreamId): Http2DecodedServerData {
    let payload = frame.payload
    if (!frame.header.flags.isPadded()) { return Http2DecodedServerData(payload) }
    if (payload.isEmpty()) { serverStreamError(streamId, "HTTP/2 padded DATA has no pad length") }
    let padding = Int64(payload[0])
    if (padding >= payload.size) { serverStreamError(streamId, "HTTP/2 DATA padding consumes its complete payload") }
    let count = payload.size - padding - 1
    let data = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { data[index] = payload[index + 1] }
    Http2DecodedServerData(data)
}

private func requireServerDataFrame(frame: Http2Frame, streamId: Http2StreamId): Unit {
    match (frame.header.frameType) {
        case Http2FrameType.Data => ()
        case _ => throw IllegalArgumentException("expected HTTP/2 DATA frame")
    }
    if (frame.header.streamId.value != streamId.value) {
        throw IllegalArgumentException("HTTP/2 DATA belongs to another stream")
    }
}

private func validateServerH2Fields(
    fields: Array<HpackHeaderField>, streamId: Http2StreamId, limits: Http2Limits
): Unit {
    if (UInt64(fields.size) > UInt64(limits.maxHeaderFields)) {
        serverStreamError(streamId, "HTTP/2 request field count exceeds configured limit")
    }
    var bytes = 0u64
    for (field in fields) {
        let size = field.tableSize
        if (size > UInt64(limits.maxHeaderListBytes) - min(bytes, UInt64(limits.maxHeaderListBytes))) {
            serverStreamError(streamId, "HTTP/2 request field list exceeds configured limit")
        }
        bytes += size
    }
}

private func serverValidateInboundName(name: String, streamId: Http2StreamId): Unit {
    let bytes = name.toArray()
    if (bytes.isEmpty()) { serverStreamError(streamId, "HTTP/2 field name is empty") }
    for (byte in bytes) {
        if (byte >= b'A' && byte <= b'Z') { serverStreamError(streamId, "HTTP/2 field name contains uppercase") }
    }
}

private func serverParseMethod(value: String, streamId: Http2StreamId): HttpMethod {
    try { HttpMethod(value) }
    catch (_: IllegalArgumentException) { serverStreamError(streamId, "HTTP/2 :method is invalid") }
}

private func serverValidateRequestTarget(
    method: HttpMethod, scheme: String, authority: String, path: String, streamId: Http2StreamId
): Unit {
    if (path == "*") {
        if (method != HttpMethod("OPTIONS")) { serverStreamError(streamId, "HTTP/2 asterisk path requires OPTIONS") }
        serverValidateMatchingAuthority(authority, authority, scheme, streamId)
        return
    }
    if (path.isEmpty() || !path.startsWith("/") || path.contains("#")) {
        serverStreamError(streamId, "HTTP/2 :path is not valid origin-form")
    }
    try { let _ = HttpUrl.parse("${scheme}://${authority}${path}") }
    catch (_: Exception) { serverStreamError(streamId, "HTTP/2 request pseudo-fields do not form a valid URL") }
}

private func serverValidateConnectAuthority(authority: String, streamId: Http2StreamId): Unit {
    let parsed = try { HttpUrl.parse("http://${authority}/") }
    catch (_: Exception) { serverStreamError(streamId, "HTTP/2 CONNECT authority is invalid") }
    if (!parsed.explicitPort) { serverStreamError(streamId, "HTTP/2 CONNECT authority requires an explicit port") }
}

private func serverValidateMatchingAuthority(
    candidate: String, authority: String, scheme: String, streamId: Http2StreamId
): Unit {
    let left = try { HttpUrl.parse("${scheme}://${candidate}/") }
    catch (_: Exception) { serverStreamError(streamId, "HTTP/2 Host authority is invalid") }
    let right = try { HttpUrl.parse("${scheme}://${authority}/") }
    catch (_: Exception) { serverStreamError(streamId, "HTTP/2 :authority is invalid") }
    if (left.host.toAsciiLower() != right.host.toAsciiLower() || left.port != right.port) {
        serverStreamError(streamId, "HTTP/2 Host and :authority differ")
    }
}

private func validateServerRequestEnd(expected: ?Int64, received: Int64, streamId: Http2StreamId): Unit {
    if (let Some(value) <- expected) {
        if (value != received) { serverStreamError(streamId, "HTTP/2 request body does not match Content-Length") }
    }
}

private func checkServerBodyContext(context: OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw NetworkException(
            NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled,
            "HTTP/2 request body wait cancelled", retryability: Retryability.Never
        )
    }
    if (context.isDeadlineExceeded()) {
        throw NetworkException(
            NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut,
            "HTTP/2 request body deadline exceeded", retryability: Retryability.Temporary
        )
    }
}

private func serverSplitComma(value: String, streamId: Http2StreamId): Array<String> {
    let bytes = value.toArray()
    let output = ArrayList<String>()
    var start: Int64 = 0
    while (start <= bytes.size) {
        var end = start
        while (end < bytes.size && bytes[end] != b',') { end += 1 }
        var left = start
        var right = end
        while (left < right && (bytes[left] == b' ' || bytes[left] == 9u8)) { left += 1 }
        while (right > left && (bytes[right - 1] == b' ' || bytes[right - 1] == 9u8)) { right -= 1 }
        if (left == right) { serverStreamError(streamId, "HTTP/2 comma-separated field contains an empty value") }
        let slice = Array<Byte>(right - left, repeat: 0)
        for (index in 0..slice.size) { slice[index] = bytes[left + index] }
        output.add(String.fromUtf8(slice))
        if (end == bytes.size) { break }
        start = end + 1
    }
    output.toArray()
}

private func serverParseInboundDecimal(value: String, streamId: Http2StreamId): Int64 {
    try { serverParseLocalDecimal(value) }
    catch (_: Http2MessageException) { serverStreamError(streamId, "HTTP/2 Content-Length is invalid") }
}

private func serverParseLocalDecimal(value: String): Int64 {
    let bytes = value.toArray()
    if (bytes.isEmpty() || bytes.size > 19) { serverLocalContentLengthError() }
    var result: Int64 = 0
    for (byte in bytes) {
        if (byte < b'0' || byte > b'9') { serverLocalContentLengthError() }
        let digit = Int64(byte - b'0')
        if (result > (Int64.Max - digit) / 10) { serverLocalContentLengthError() }
        result = result * 10 + digit
    }
    result
}

private func serverValidateTrailerDeclaration(value: String, streamId: Http2StreamId): Unit {
    for (name in serverSplitComma(value, streamId)) {
        let lowered = name.toAsciiLower()
        try { let _ = HttpHeader(lowered, "") }
        catch (_: IllegalArgumentException) { serverStreamError(streamId, "HTTP/2 Trailer declaration is invalid") }
        if (serverForbiddenConnectionField(lowered) || lowered == "content-length" || lowered == "host" ||
            lowered == "trailer" || lowered == "te") {
            serverStreamError(streamId, "HTTP/2 Trailer declaration contains a forbidden name")
        }
    }
}

private func serverEncoding(name: String, value: String, sensitive!: Bool = false): HpackFieldEncoding {
    HpackFieldEncoding(HpackHeaderField(name, value, sensitive: sensitive))
}

private func serverSensitiveField(name: String): Bool {
    name == "authorization" || name == "proxy-authorization" || name == "cookie" || name == "set-cookie"
}

private func serverForbiddenConnectionField(name: String): Bool {
    name == "connection" || name == "proxy-connection" || name == "keep-alive" ||
        name == "transfer-encoding" || name == "upgrade"
}

private func serverLocalHeaderError(message: String): Nothing {
    throw Http2MessageException(Http2MessageErrorCode.InvalidHeader, message)
}

private func serverLocalContentLengthError(): Nothing {
    throw Http2MessageException(Http2MessageErrorCode.InvalidContentLength, "HTTP/2 Content-Length is invalid")
}

private func serverStreamError(streamId: Http2StreamId, message: String): Nothing {
    throw Http2ProtocolException(Http2ErrorCode.ProtocolError, Http2ErrorScope.Stream(streamId), message)
}
