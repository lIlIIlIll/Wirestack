package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1RequestWriterTest {
    @TestCase
    func twoStageWriterDoesNotOpenBodyBeforeExplicitCommit(): Unit {
        let (client, server) = MemoryTransport.pair(capacity: 4096)
        let stream = CountingOpenBodyStream("body".toArray())
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "4").add("Expect", "100-continue").build(),
            body: RequestBody.oneShot(stream)
        )
        let writer = Http1RequestWriter(request)
        let headEvidence = writer.writeHead(client)
        @Expect(headEvidence.requestCommitted)
        @Expect(!headEvidence.bodyCommitted)
        @Expect(stream.readCalls, 0)

        let head = readRequestWriterHead(server)
        @Expect(head.head.target, "/upload")
        let finalEvidence = writer.writeBody(client)
        @Expect(finalEvidence.bodyBytesWritten, 4)
        @Expect(stream.readCalls > 0)
        expectRequestWriterFailure(Http1RequestWriteErrorCode.InvalidRequestState, { => let _ = writer.writeBody(client) })
        client.close()
        server.close()
    }
    @TestCase
    func writesFixedBodyThroughPartialTransportOperations(): Unit {
        let (writer, reader) = MemoryTransport.pair(capacity: 1024, maxChunk: 2)
        let request = HttpRequest(
            HttpMethod("POST"),
            HttpUrl.parse("http://example.com/upload"),
            headers: HttpHeaders.builder().add("Content-Length", "4").build(),
            body: RequestBody.bytes("data".toArray())
        )

        let evidence = writeHttp1Request(writer, request)
        let expected = "POST /upload HTTP/1.1\r\nContent-Length: 4\r\nHost: example.com\r\n\r\ndata".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(reader, MutableByteSpan(received))

        @Expect(received, expected)
        @Expect(evidence.wireBytesWritten, expected.size)
        @Expect(evidence.bodyBytesWritten, 4)
        @Expect(evidence.requestCommitted)
        @Expect(evidence.bodyCommitted)
    }

    @TestCase
    func streamsUnknownLengthBodyAsCanonicalChunks(): Unit {
        let (writer, reader) = MemoryTransport.pair(capacity: 1024, maxChunk: 3)
        let request = HttpRequest(
            HttpMethod("POST"),
            HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder().add("Transfer-Encoding", "chunked").build(),
            body: RequestBody.replayableFactory(None<Int64>, {
                => WriterTestBodyStream("chunk".toArray(), None<Int64>)
            })
        )

        let evidence = writeHttp1Request(writer, request)
        let expected = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nHost: example.com\r\n\r\n5\r\nchunk\r\n0\r\n\r\n".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(reader, MutableByteSpan(received))

        @Expect(received, expected)
        @Expect(evidence.bodyBytesWritten, 5)
    }

    @TestCase
    func rejectsDeclaredMismatchBeforeWritingAnything(): Unit {
        let (writer, _) = MemoryTransport.pair(capacity: 1024)
        let request = HttpRequest(
            HttpMethod("POST"),
            HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder().add("Content-Length", "3").build(),
            body: RequestBody.bytes("no".toArray())
        )

        let error = captureWriteFailure(writer, request)
        @Expect(isWriteCode(error.code, Http1RequestWriteErrorCode.BodyLengthMismatch))
        @Expect(!error.evidence.requestCommitted)
    }

    @TestCase
    func prematureBodyEofRetainsPartialCommitEvidence(): Unit {
        let (writer, _) = MemoryTransport.pair(capacity: 1024, maxChunk: 2)
        let request = HttpRequest(
            HttpMethod("POST"),
            HttpUrl.parse("http://example.com/"),
            headers: HttpHeaders.builder().add("Content-Length", "3").build(),
            body: RequestBody.replayableFactory(Some(3), {
                => WriterTestBodyStream("no".toArray(), Some(3))
            })
        )

        let error = captureWriteFailure(writer, request)
        @Expect(isWriteCode(error.code, Http1RequestWriteErrorCode.BodyLengthMismatch))
        @Expect(error.evidence.requestCommitted)
        @Expect(error.evidence.bodyBytesWritten, 2)
    }

    @TestCase
    func emptyFramingProbesSourceInsteadOfDroppingUnexpectedBytes(): Unit {
        let (writer, _) = MemoryTransport.pair(capacity: 1024)
        let request = HttpRequest(
            HttpMethod("GET"),
            HttpUrl.parse("http://example.com/"),
            body: RequestBody.replayableFactory(Some(0), {
                => WriterTestBodyStream("x".toArray(), Some(0))
            })
        )

        let error = captureWriteFailure(writer, request)
        @Expect(isWriteCode(error.code, Http1RequestWriteErrorCode.BodyLengthMismatch))
        @Expect(error.evidence.requestCommitted)
    }
}

private class WriterTestBodyStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let declared: ?Int64
    private var offset: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>, declared: ?Int64) {
        this.bytes = bytes.clone()
        this.declared = declared
    }

    public prop contentLength: ?Int64 { get() { declared } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw Exception("closed writer test body") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private class CountingOpenBodyStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private var offset: Int64 = 0
    private var closed = false
    var readCalls: Int64 = 0

    init(bytes: Array<Byte>) { this.bytes = bytes.clone() }
    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }
    public func read(destination: Array<Byte>): Int64 {
        readCalls++
        if (closed) { throw Exception("closed counting body") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func readRequestWriterHead(transport: DuplexTransport): Http1ParsedRequestHead {
    let parser = Http1RequestHeadParser()
    while (true) {
        let buffer = Array<Byte>(64, repeat: 0)
        match (transport.readSome(MutableByteSpan(buffer), context: OperationContext.background())) {
            case ReadResult.Data(count) =>
                let input = Array<Byte>(count, repeat: 0)
                for (index in 0..count) { input[index] = buffer[index] }
                if (let Some(parsed) <- parser.feed(input)) { return parsed }
            case ReadResult.EndOfStream => throw Exception("request writer closed before head")
        }
    }
    throw Exception("unreachable request writer head loop")
}

private func expectRequestWriterFailure(code: Http1RequestWriteErrorCode, action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http1RequestWriteException) { matched = isWriteCode(error.code, code) }
    @Expect(matched)
}

private func captureWriteFailure(
    transport: DuplexTransport,
    request: HttpRequest
): Http1RequestWriteException {
    try {
        let _ = writeHttp1Request(transport, request)
    } catch (error: Http1RequestWriteException) {
        return error
    }
    throw Exception("expected HTTP/1 request write failure")
}

private func isWriteCode(left: Http1RequestWriteErrorCode, right: Http1RequestWriteErrorCode): Bool {
    match ((left, right)) {
        case (Http1RequestWriteErrorCode.BodyLengthMismatch, Http1RequestWriteErrorCode.BodyLengthMismatch) => true
        case (Http1RequestWriteErrorCode.BodyTooLarge, Http1RequestWriteErrorCode.BodyTooLarge) => true
        case (Http1RequestWriteErrorCode.InvalidRequestFraming, Http1RequestWriteErrorCode.InvalidRequestFraming) => true
        case (Http1RequestWriteErrorCode.InvalidRequestState, Http1RequestWriteErrorCode.InvalidRequestState) => true
        case (Http1RequestWriteErrorCode.WriteFailed, Http1RequestWriteErrorCode.WriteFailed) => true
        case _ => false
    }
}
