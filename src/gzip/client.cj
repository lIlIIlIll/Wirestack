package wirestack.gzip

import wirestack.*
import wirestack.http.HttpClient
import wirestack.http.HttpCancellationHandles

/** Owned raw or decoded response with immutable wire metadata kept separate from the public body view. */
public class GzipResponse <: Resource {
    /** Response view: decoded bodies omit wire Content-Encoding and Content-Length. */
    public let response: HttpResponse
    /** Original immutable wire headers, including encoding, length and representation validators. */
    public let wireHeaders: HttpHeaders
    /** Declared compressed wire length, never asserted as decoded length. */
    public let wireContentLength: ?Int64
    /** True only when this optional wrapper selected gzip decoding. */
    public let isDecoded: Bool
    private let decoder: ?GzipBodyStream
    internal init(response: HttpResponse, wire: HttpResponse, decoder: ?GzipBodyStream) {
        this.response = response; this.wireHeaders = wire.headers
        this.wireContentLength = wire.body.contentLength; this.decoder = decoder
        this.isDecoded = decoder.isSome()
    }
    /** Actual compressed reads; zero for an unchanged raw view. */
    public prop encodedBytesRead: Int64 { get() { match (decoder) { case Some(value) => value.encodedBytesRead; case None => 0 } } }
    /** Actual decoded production, not wire Content-Length; zero for raw views. */
    public prop decodedBytes: Int64 { get() { match (decoder) { case Some(value) => value.decodedBytes; case None => 0 } } }
    /** True only after gzip trailer checks and physical EOF; false for raw views. */
    public prop integrityVerified: Bool { get() { match (decoder) { case Some(value) => value.integrityVerified; case None => false } } }
    /** Accepted gzip headers; zero for raw views. */
    public prop memberCount: Int64 { get() { match (decoder) { case Some(value) => value.memberCount; case None => 0 } } }
    /** Closes the owned response, not its client. */
    public func close(): Unit { response.close() }
    /** Reports whether the owned response is closed. */
    public func isClosed(): Bool { response.isClosed() }
}

/** Explicit optional gzip negotiation and streaming decode; HTTP Core never imports this package. */
public class GzipClient {
    private let client: HttpClient
    private let limits: GzipLimits
    private let passThroughUnsupported: Bool
    /** Wraps a shared client without transferring ownership of it.
     * @param client Existing client with the canonical pools, limits and deadline policy.
     * @param limits Absolute input/output and bounded-work policy.
     * @param passThroughUnsupported Returns unknown/layered encodings raw when true, otherwise rejects them.
     */
    public init(client: HttpClient, limits!: GzipLimits = GzipLimits(), passThroughUnsupported!: Bool = false) {
        this.client = client; this.limits = limits; this.passThroughUnsupported = passThroughUnsupported
    }
    /** Sends through the existing retry/redirect policy; decoding never resubmits a returned response.
     * Caller Accept-Encoding wins. Only this explicitly selected wrapper adds gzip when the header is absent.
     * @param request Original method, URL, body and replay safety.
     * @param context Parent context shared by data admission, network stages and CPU decoding.
     * @param cancellation Typed request/connection/stream cancellation scopes.
     * @return One caller-owned raw or decoded response with separate wire metadata.
     */
    public func send(request: HttpRequest, context!: OperationContext = OperationContext.background(),
        cancellation!: HttpCancellationHandles = HttpCancellationHandles()): GzipResponse {
        let operation = client.contextForRequest(context: context)
        checkGzipContext(operation)
        checkGzipHandles(cancellation)
        // Header rebuilds must accept everything the wrapped client accepts, not the
        // library defaults; otherwise a larger configured limit turns into a local reject.
        let headerLimits = client.configuredLimits()
        let outgoing = requestWithGzipAcceptEncoding(request, headerLimits)
        var lease = None<Resource>
        var opened = None<HttpResponse>
        var decodedStream = None<GzipBodyStream>
        var transferred = false
        try {
            if (request.method != HttpMethod("HEAD")) {
                lease = Some(client.reserveResponseBuffer(request.url, limits.maximumRetainedBytes,
                    context: operation.forStage(OperationTimeoutStage.RequestAdmission)))
            }
            let raw = client.sendControlled(outgoing, cancellation, context: operation)
            opened = Some(raw)
            let bodyless = request.method == HttpMethod("HEAD") || raw.status < 200 ||
                raw.status == 204 || raw.status == 205 || raw.status == 304
            let coding = if (bodyless) { 0 } else { selectedGzipCoding(raw.headers) }
            if (coding == 2 && !passThroughUnsupported) {
                throw GzipException(GzipErrorCode.UnsupportedCoding, "response coding is unsupported or layered")
            }
            if (coding != 1) {
                if (let Some(value) <- lease) { value.close(); lease = None<Resource> }
                transferred = true
                return GzipResponse(raw, raw, None<GzipBodyStream>)
            }
            // A followed redirect may select a different origin or proxy route. Only an owner
            // change moves the reservation: releasing and reacquiring the same owner's lease
            // lets a queued request steal the capacity before this decoder is allocated.
            match (raw.responseTargetUrl) {
                case Some(value) =>
                    if (!client.sameResponseBufferOwner(request.url, value)) {
                        let previous = lease.getOrThrow()
                        previous.close()
                        lease = None<Resource>
                        lease = Some(client.reserveResponseBuffer(value, limits.maximumRetainedBytes,
                            context: operation.forStage(OperationTimeoutStage.RequestAdmission)))
                    }
                case None => ()
            }
            let retained = lease.getOrThrow()
            let effective = match (raw.operationContext) { case Some(value) => value; case None => operation }
            let stream = GzipBodyStream(GzipResponseSource(raw.body), limits, effective, operation,
                { => checkGzipContext(operation); checkGzipHandles(cancellation) }, retained)
            decodedStream = Some(stream)
            lease = None<Resource>
            // Decoded output can outlive the compressed wire body, so the typed cancellation
            // handles must stay linked until this decoded body reaches EOF or terminal cleanup.
            stream.attachCancellation(cancellation.retainCancellation({ => stream.close() }))
            let headers = decodedGzipResponseHeaders(raw.headers, headerLimits)
            let view = HttpResponse(raw.status, raw.reason,
                ResponseBody(stream, trailerProvider: { => if (stream.integrityVerified) { raw.body.trailer } else { None<HttpTrailer> } },
                    completeAtDeclaredLength: false), version: raw.version, headers: headers,
                pushes: raw.pushes, operationContext: Some(effective))
            transferred = true
            GzipResponse(view, raw, Some(stream))
        } finally {
            if (!transferred) {
                try { if (let Some(value) <- decodedStream) { value.close() } }
                finally { if (let Some(value) <- opened) { value.close() } }
            }
            if (let Some(value) <- lease) { value.close() }
        }
    }
}

private func selectedGzipCoding(headers: HttpHeaders): Int64 {
    let values = headers.getAll("content-encoding")
    if (values.isEmpty()) { return 0 }
    if (values.size != 1) { return 2 }
    let value = values[0].trimAscii().toAsciiLower()
    if (value == "identity") { 0 } else if (value == "gzip") { 1 } else { 2 }
}
private func checkGzipHandles(handles: HttpCancellationHandles): Unit {
    let cancelled = match (handles.request) { case Some(value) => value.isCancellationRequested; case None => false } ||
        match (handles.connection) { case Some(value) => value.isCancellationRequested; case None => false } ||
        match (handles.stream) { case Some(value) => value.isCancellationRequested; case None => false }
    if (cancelled) {
        throw NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody,
            NetworkErrorCode.Cancelled, "gzip request cancelled", retryability: Retryability.Never)
    }
}

/** Adds the explicit gzip offer using the wrapped client's header limits; caller values win. */
internal func requestWithGzipAcceptEncoding(request: HttpRequest, limits: HttpLimits): HttpRequest {
    if (request.headers.contains("accept-encoding")) { return request }
    let builder = HttpHeaders.builder(limits: limits)
    for (entry in request.headers.entries) { builder.add(entry.name, entry.value) }
    request.withHeaders(builder.add("Accept-Encoding", "gzip").build())
}

/** Builds the decoded response view under the wrapped client's header limits. */
internal func decodedGzipResponseHeaders(original: HttpHeaders, limits: HttpLimits): HttpHeaders {
    let builder = HttpHeaders.builder(limits: limits)
    for (entry in original.entries) {
        let name = entry.name.toAsciiLower()
        if (name != "content-encoding" && name != "content-length" && name != "transfer-encoding" &&
            name != "content-md5" && name != "content-digest" && name != "digest" && name != "etag") {
            builder.add(entry.name, entry.value)
        }
    }
    builder.build()
}

private class GzipResponseSource <: HttpBodyStream {
    private let body: ResponseBody
    init(body: ResponseBody) { this.body = body }
    /** Original framed wire length; it never describes decoded output. */
    public prop contentLength: ?Int64 { get() { body.contentLength } }
    /** Pulls framed wire bytes through the response's existing owner.
     * @param destination Caller-owned compressed-input buffer.
     */
    public func read(destination: Array<Byte>): Int64 { body.read(destination) }
    /** Releases the owned wire body once; the shared client remains open. */
    public func close(): Unit { body.close() }
    /** Reports the wire body's existing close state. */
    public func isClosed(): Bool { body.isClosed() }
}
