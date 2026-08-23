package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1RequestWriterTest {
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
        case (Http1RequestWriteErrorCode.WriteFailed, Http1RequestWriteErrorCode.WriteFailed) => true
        case _ => false
    }
}
