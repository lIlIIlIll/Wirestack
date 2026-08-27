package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public enum Http1ResponseWriteErrorCode {
    | BodyLengthMismatch
    | BodyTooLarge
    | InvalidResponseState
    | WriteFailed
}

/** Wire commit evidence and connection disposition for one server response. */
public struct Http1ResponseCommitEvidence {
    public let wireBytesWritten: Int64
    public let bodyBytesWritten: Int64
    public let mustClose: Bool
    public let tunnelEstablished: Bool

    public prop responseCommitted: Bool { get() { wireBytesWritten > 0 } }
    public prop bodyCommitted: Bool { get() { bodyBytesWritten > 0 } }

    public init(wireBytesWritten: Int64, bodyBytesWritten: Int64, mustClose: Bool, tunnelEstablished: Bool) {
        this.wireBytesWritten = wireBytesWritten
        this.bodyBytesWritten = bodyBytesWritten
        this.mustClose = mustClose
        this.tunnelEstablished = tunnelEstablished
    }
}

public class Http1ResponseWriteException <: Exception {
    public let code: Http1ResponseWriteErrorCode
    public let evidence: Http1ResponseCommitEvidence
    public let cause: ?Exception

    public init(code: Http1ResponseWriteErrorCode, message: String,
        evidence: Http1ResponseCommitEvidence, cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.evidence = evidence
        this.cause = cause
    }

    protected override func getClassName(): String { "Http1ResponseWriteException" }
}

/** Streams one response and returns whether the owning connection must close or becomes a tunnel. */
public func writeHttp1Response(
    transport: DuplexTransport,
    requestMethod: HttpMethod,
    response: HttpResponse,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    trailer!: HttpTrailer = HttpTrailer()
): Http1ResponseCommitEvidence {
    let status = UInt16(response.status)
    let head = serializeResponseHead(status, response.reason, response.headers, requestMethod, limits: limits)
    validateResponseBody(response.body, head.framing, status, requestMethod)
    let tracker = ResponseWriteTracker(head.framing)
    try {
        writeResponseTracked(transport, head.bytesForWrite(), tracker, context)
        writeResponseBody(transport, response.body, head.framing, tracker, context, limits, trailer)
        tracker.snapshot()
    } catch (error: Http1ResponseWriteException) {
        throw error
    } catch (error: Exception) {
        let evidence = tracker.snapshot()
        throw Http1ResponseWriteException(
            Http1ResponseWriteErrorCode.WriteFailed,
            "HTTP/1 response write failed after ${evidence.wireBytesWritten} wire bytes",
            evidence,
            cause: error
        )
    } finally {
        response.close()
    }
}

private class ResponseWriteTracker {
    var wireBytesWritten: Int64 = 0
    var bodyBytesWritten: Int64 = 0
    private let framing: Http1BodyFraming

    init(framing: Http1BodyFraming) { this.framing = framing }

    func snapshot(): Http1ResponseCommitEvidence {
        match (framing) {
            case Http1BodyFraming.CloseDelimited =>
                Http1ResponseCommitEvidence(wireBytesWritten, bodyBytesWritten, true, false)
            case Http1BodyFraming.Tunnel =>
                Http1ResponseCommitEvidence(wireBytesWritten, bodyBytesWritten, false, true)
            case _ => Http1ResponseCommitEvidence(wireBytesWritten, bodyBytesWritten, false, false)
        }
    }
}

private func validateResponseBody(body: ResponseBody, framing: Http1BodyFraming,
    status: UInt16, requestMethod: HttpMethod): Unit {
    match (framing) {
        case Http1BodyFraming.ContentLength(expected) =>
            if (body.contentLength != Some(expected)) { responseBodyLengthMismatch(emptyResponseEvidence()) }
        case Http1BodyFraming.Empty =>
            // HEAD and 304 may describe a representation without transferring it.
            if (requestMethod != HttpMethod("HEAD") && status != 304 && body.contentLength != Some(0)) {
                responseBodyLengthMismatch(emptyResponseEvidence())
            }
        case Http1BodyFraming.Tunnel =>
            if (body.contentLength != Some(0)) { responseBodyLengthMismatch(emptyResponseEvidence()) }
        case _ => ()
    }
}

private func writeResponseBody(transport: DuplexTransport, body: ResponseBody,
    framing: Http1BodyFraming, tracker: ResponseWriteTracker, context: OperationContext,
    limits: HttpLimits, trailer: HttpTrailer): Unit {
    match (framing) {
        case Http1BodyFraming.Empty | Http1BodyFraming.Tunnel => ()
        case Http1BodyFraming.ContentLength(expected) =>
            writeFixedResponseBody(transport, body, expected, tracker, context)
        case Http1BodyFraming.Chunked =>
            writeChunkedResponseBody(transport, body, tracker, context, limits, trailer)
        case Http1BodyFraming.CloseDelimited =>
            writeCloseDelimitedResponseBody(transport, body, tracker, context, limits)
    }
}

private func writeFixedResponseBody(transport: DuplexTransport, body: ResponseBody,
    expected: Int64, tracker: ResponseWriteTracker, context: OperationContext): Unit {
    let buffer = Array<Byte>(16384, repeat: 0)
    var remaining = expected
    while (remaining > 0) {
        let destination = if (remaining < buffer.size) { Array<Byte>(remaining, repeat: 0) } else { buffer }
        let count = body.read(destination)
        if (count <= 0 || count > remaining) { responseBodyLengthMismatch(tracker.snapshot()) }
        writeResponseTracked(transport, destination, tracker, context, length: count,
            bodyStart: 0, bodyLength: count)
        remaining -= count
    }
    if (body.read(Array<Byte>(1, repeat: 0)) != 0) { responseBodyLengthMismatch(tracker.snapshot()) }
}

private func writeChunkedResponseBody(transport: DuplexTransport, body: ResponseBody,
    tracker: ResponseWriteTracker, context: OperationContext, limits: HttpLimits,
    trailer: HttpTrailer): Unit {
    let buffer = Array<Byte>(16384, repeat: 0)
    var total: Int64 = 0
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        if (count < 0 || count > buffer.size || count > limits.maxBodyBytes - total) {
            throw Http1ResponseWriteException(Http1ResponseWriteErrorCode.BodyTooLarge,
                "HTTP/1 chunked response body exceeds its configured bound", tracker.snapshot())
        }
        let data = responsePrefix(buffer, count)
        let encoded = encodeHttp1Chunk(data, limits: limits)
        writeResponseTracked(transport, encoded, tracker, context,
            bodyStart: encoded.size - count - 2, bodyLength: count)
        total += count
    }
    writeResponseTracked(transport, encodeHttp1FinalChunk(trailer: trailer, limits: limits), tracker, context)
}

private func writeCloseDelimitedResponseBody(transport: DuplexTransport, body: ResponseBody,
    tracker: ResponseWriteTracker, context: OperationContext, limits: HttpLimits): Unit {
    let buffer = Array<Byte>(16384, repeat: 0)
    var total: Int64 = 0
    while (true) {
        let count = body.read(buffer)
        if (count == 0) { break }
        if (count < 0 || count > buffer.size || count > limits.maxBodyBytes - total) {
            throw Http1ResponseWriteException(Http1ResponseWriteErrorCode.BodyTooLarge,
                "HTTP/1 close-delimited response body exceeds its configured bound", tracker.snapshot())
        }
        writeResponseTracked(transport, buffer, tracker, context, length: count,
            bodyStart: 0, bodyLength: count)
        total += count
    }
}

private func writeResponseTracked(transport: DuplexTransport, bytes: Array<Byte>,
    tracker: ResponseWriteTracker, context: OperationContext, length!: Int64 = bytes.size,
    bodyStart!: Int64 = -1, bodyLength!: Int64 = 0): Unit {
    var remaining = ByteSpan(bytes, length: length)
    while (!remaining.isEmpty()) {
        let written = transport.writeSome(remaining, context: context)
        if (written <= 0 || written > remaining.length) {
            throw Exception("transport returned an invalid HTTP/1 response write count")
        }
        let writeStart = length - remaining.length
        if (bodyStart >= 0 && bodyLength > 0) {
            let overlapStart = max(writeStart, bodyStart)
            let overlapEnd = min(writeStart + written, bodyStart + bodyLength)
            if (overlapEnd > overlapStart) { tracker.bodyBytesWritten += overlapEnd - overlapStart }
        }
        tracker.wireBytesWritten += written
        remaining = remaining.advance(written)
    }
}

private func responsePrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let result = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { result[index] = bytes[index] }
    result
}

private func emptyResponseEvidence(): Http1ResponseCommitEvidence {
    Http1ResponseCommitEvidence(0, 0, false, false)
}

private func responseBodyLengthMismatch(evidence: Http1ResponseCommitEvidence): Nothing {
    throw Http1ResponseWriteException(Http1ResponseWriteErrorCode.BodyLengthMismatch,
        "HTTP response body bytes differ from its declared framing", evidence)
}
