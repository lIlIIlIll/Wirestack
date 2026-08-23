package wirestack.internal.http1

import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public enum Http1RequestWriteErrorCode {
    | BodyLengthMismatch
    | BodyTooLarge
    | InvalidRequestFraming
    | InvalidRequestState
    | WriteFailed
}

/** Immutable evidence used by retry policy after success or partial failure. */
public struct Http1RequestCommitEvidence {
    public let wireBytesWritten: Int64
    public let bodyBytesWritten: Int64

    public prop requestCommitted: Bool { get() { wireBytesWritten > 0 } }
    public prop bodyCommitted: Bool { get() { bodyBytesWritten > 0 } }

    public init(wireBytesWritten: Int64, bodyBytesWritten: Int64) {
        this.wireBytesWritten = wireBytesWritten
        this.bodyBytesWritten = bodyBytesWritten
    }
}

public class Http1RequestWriteException <: Exception {
    public let code: Http1RequestWriteErrorCode
    public let evidence: Http1RequestCommitEvidence
    public let cause: ?Exception

    public init(
        code: Http1RequestWriteErrorCode,
        message: String,
        evidence: Http1RequestCommitEvidence,
        cause!: ?Exception = None<Exception>
    ) {
        super(message)
        this.code = code
        this.evidence = evidence
        this.cause = cause
    }

    protected override func getClassName(): String { "Http1RequestWriteException" }
}

/** Writes one complete request without buffering its body and returns retry/redirect commit evidence. */
public func writeHttp1Request(
    transport: DuplexTransport,
    request: HttpRequest,
    context!: OperationContext = OperationContext.background(),
    limits!: HttpLimits = HttpLimits(),
    trailer!: HttpTrailer = HttpTrailer()
): Http1RequestCommitEvidence {
    let writer = Http1RequestWriter(request, limits: limits, trailer: trailer)
    writer.writeHead(transport, context: context)
    writer.writeBody(transport, context: context)
    writer.evidence
}

/** Stateful two-stage writer used by Expect: 100-continue without opening the body early. */
public class Http1RequestWriter {
    private let request: HttpRequest
    private let limits: HttpLimits
    private let trailer: HttpTrailer
    private let head: Http1SerializedHead
    private let tracker = RequestWriteTracker()
    private var headWritten = false
    private var bodyWritten = false

    public prop evidence: Http1RequestCommitEvidence { get() { tracker.snapshot() } }

    public init(request: HttpRequest, limits!: HttpLimits = HttpLimits(), trailer!: HttpTrailer = HttpTrailer()) {
        let serialized = serializeClientRequestHead(request.method, request.url, request.headers, limits: limits)
        validateBodyFraming(request.body, serialized.framing)
        this.request = request
        this.limits = limits
        this.trailer = trailer
        head = serialized
    }

    public func writeHead(
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): Http1RequestCommitEvidence {
        if (headWritten) { invalidWriterState("HTTP/1 request head has already been written", tracker.snapshot()) }
        try {
            writeTracked(transport, head.bytes, tracker, context)
            headWritten = true
            tracker.snapshot()
        } catch (error: Http1RequestWriteException) {
            throw error
        } catch (error: Exception) {
            writeFailure(error, tracker.snapshot())
        }
    }

    public func writeBody(
        transport: DuplexTransport,
        context!: OperationContext = OperationContext.background()
    ): Http1RequestCommitEvidence {
        if (!headWritten || bodyWritten) {
            invalidWriterState("HTTP/1 request body requires one completed head and one write", tracker.snapshot())
        }
        try {
            writeRequestBody(transport, request.body, head.framing, tracker, context, limits, trailer)
            bodyWritten = true
            tracker.snapshot()
        } catch (error: Http1RequestWriteException) {
            throw error
        } catch (error: Exception) {
            writeFailure(error, tracker.snapshot())
        }
    }
}

private class RequestWriteTracker {
    var wireBytesWritten: Int64 = 0
    var bodyBytesWritten: Int64 = 0

    func snapshot(): Http1RequestCommitEvidence {
        Http1RequestCommitEvidence(wireBytesWritten, bodyBytesWritten)
    }
}

private func validateBodyFraming(body: RequestBody, framing: Http1BodyFraming): Unit {
    match (framing) {
        case Http1BodyFraming.Empty =>
            if (body.contentLength != Some(0)) { bodyLengthMismatch(Http1RequestCommitEvidence(0, 0)) }
        case Http1BodyFraming.ContentLength(expected) =>
            if (body.contentLength != Some(expected)) { bodyLengthMismatch(Http1RequestCommitEvidence(0, 0)) }
        case Http1BodyFraming.Chunked => ()
        case Http1BodyFraming.CloseDelimited | Http1BodyFraming.Tunnel =>
            throw Http1RequestWriteException(
                Http1RequestWriteErrorCode.InvalidRequestFraming,
                "HTTP/1 requests cannot use close-delimited or tunnel body framing",
                Http1RequestCommitEvidence(0, 0)
            )
    }
}

private func writeRequestBody(
    transport: DuplexTransport,
    body: RequestBody,
    framing: Http1BodyFraming,
    tracker: RequestWriteTracker,
    context: OperationContext,
    limits: HttpLimits,
    trailer: HttpTrailer
): Unit {
    let stream = body.open()
    try {
        match (framing) {
            case Http1BodyFraming.Empty =>
                ensureBodyEof(stream, tracker.snapshot())
            case Http1BodyFraming.ContentLength(expected) =>
                writeFixedBody(transport, stream, expected, tracker, context)
            case Http1BodyFraming.Chunked =>
                writeChunkedBody(transport, stream, tracker, context, limits, trailer)
            case _ => ()
        }
    } finally {
        stream.close()
    }
}

private func writeFixedBody(
    transport: DuplexTransport,
    stream: HttpBodyStream,
    expected: Int64,
    tracker: RequestWriteTracker,
    context: OperationContext
): Unit {
    let buffer = Array<Byte>(16384, repeat: 0)
    var remaining = expected
    while (remaining > 0) {
        let destination = if (remaining < buffer.size) { Array<Byte>(remaining, repeat: 0) } else { buffer }
        let count = stream.read(destination)
        if (count <= 0 || count > remaining) { bodyLengthMismatch(tracker.snapshot()) }
        writeTracked(
            transport, destination, tracker, context,
            length: count, bodyStart: 0, bodyLength: count
        )
        remaining -= count
    }
    ensureBodyEof(stream, tracker.snapshot())
}

private func writeChunkedBody(
    transport: DuplexTransport,
    stream: HttpBodyStream,
    tracker: RequestWriteTracker,
    context: OperationContext,
    limits: HttpLimits,
    trailer: HttpTrailer
): Unit {
    let buffer = Array<Byte>(16384, repeat: 0)
    var total: Int64 = 0
    while (true) {
        let count = stream.read(buffer)
        if (count == 0) { break }
        if (count < 0 || count > buffer.size || count > limits.maxBodyBytes - total) {
            throw Http1RequestWriteException(
                Http1RequestWriteErrorCode.BodyTooLarge,
                "HTTP/1 chunked request body exceeds its configured bound",
                tracker.snapshot()
            )
        }
        let data = copyPrefix(buffer, count)
        let encoded = encodeHttp1Chunk(data, limits: limits)
        writeTracked(
            transport, encoded, tracker, context,
            bodyStart: encoded.size - count - 2, bodyLength: count
        )
        total += count
    }
    writeTracked(transport, encodeHttp1FinalChunk(trailer: trailer, limits: limits), tracker, context)
}

private func ensureBodyEof(stream: HttpBodyStream, evidence: Http1RequestCommitEvidence): Unit {
    let probe = Array<Byte>(1, repeat: 0)
    if (stream.read(probe) != 0) { bodyLengthMismatch(evidence) }
}

private func writeTracked(
    transport: DuplexTransport,
    bytes: Array<Byte>,
    tracker: RequestWriteTracker,
    context: OperationContext,
    length!: Int64 = bytes.size,
    bodyStart!: Int64 = -1,
    bodyLength!: Int64 = 0
): Unit {
    var remaining = ByteSpan(bytes, length: length)
    while (!remaining.isEmpty()) {
        let written = transport.writeSome(remaining, context: context)
        if (written <= 0 || written > remaining.length) {
            throw Exception("transport returned an invalid HTTP/1 write count")
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

private func copyPrefix(bytes: Array<Byte>, count: Int64): Array<Byte> {
    let result = Array<Byte>(count, repeat: 0)
    for (index in 0..count) { result[index] = bytes[index] }
    result
}

private func bodyLengthMismatch(evidence: Http1RequestCommitEvidence): Nothing {
    throw Http1RequestWriteException(
        Http1RequestWriteErrorCode.BodyLengthMismatch,
        "HTTP request body bytes differ from the declared Content-Length",
        evidence
    )
}

private func invalidWriterState(message: String, evidence: Http1RequestCommitEvidence): Nothing {
    throw Http1RequestWriteException(Http1RequestWriteErrorCode.InvalidRequestState, message, evidence)
}

private func writeFailure(error: Exception, evidence: Http1RequestCommitEvidence): Nothing {
    throw Http1RequestWriteException(
        Http1RequestWriteErrorCode.WriteFailed,
        "HTTP/1 request write failed after ${evidence.wireBytesWritten} wire bytes",
        evidence,
        cause: error
    )
}
