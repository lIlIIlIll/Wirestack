package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*
import wirestack.internal.transport.*

@Test
class Http1ServerResponseWriterTest {
    @TestCase
    func writesFixedResponseThroughPartialTransportOperations(): Unit {
        let (server, client) = MemoryTransport.pair(capacity: 2048, maxChunk: 2)
        let response = HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes("data".toArray()).open()),
            headers: HttpHeaders.builder().add("Content-Length", "4").build())
        let evidence = writeHttp1Response(server, HttpMethod("GET"), response)
        let expected = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndata".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(client, MutableByteSpan(received))
        @Expect(received, expected)
        @Expect(evidence.bodyBytesWritten, 4)
        @Expect(!evidence.mustClose)
    }

    @TestCase
    func streamsChunkedResponseAndTrailer(): Unit {
        let (server, client) = MemoryTransport.pair(capacity: 2048, maxChunk: 3)
        let response = HttpResponse(200, "OK",
            ResponseBody(RequestBody.replayableFactory(None<Int64>, {
                => ServerWriterBody("body".toArray(), None<Int64>)
            }).open()),
            headers: HttpHeaders.builder().add("Transfer-Encoding", "chunked").build())
        let trailer = HttpTrailer(headers: HttpHeaders.builder().add("Digest", "done").build())
        let _ = writeHttp1Response(server, HttpMethod("GET"), response, trailer: trailer)
        let expected = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody\r\n0\r\nDigest: done\r\n\r\n".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(client, MutableByteSpan(received))
        @Expect(received, expected)
    }

    @TestCase
    func headResponseNeverTransfersRepresentationBytes(): Unit {
        let (server, client) = MemoryTransport.pair(capacity: 2048)
        let response = HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes("data".toArray()).open()),
            headers: HttpHeaders.builder().add("Content-Length", "4").build())
        let evidence = writeHttp1Response(server, HttpMethod("HEAD"), response)
        let expected = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(client, MutableByteSpan(received))
        @Expect(received, expected)
        @Expect(evidence.bodyBytesWritten, 0)
    }

    @TestCase
    func closeDelimitedResponseRequiresConnectionClose(): Unit {
        let (server, client) = MemoryTransport.pair(capacity: 2048)
        let response = HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes("bye".toArray()).open()))
        let evidence = writeHttp1Response(server, HttpMethod("GET"), response)
        @Expect(evidence.mustClose)
        @Expect(evidence.bodyBytesWritten, 3)
        let expected = "HTTP/1.1 200 OK\r\n\r\nbye".toArray()
        let received = Array<Byte>(expected.size, repeat: 0)
        readExact(client, MutableByteSpan(received))
        @Expect(received, expected)
    }

    @TestCase
    func rejectsKnownLengthMismatchBeforeCommittingHead(): Unit {
        let (server, _) = MemoryTransport.pair(capacity: 2048)
        let response = HttpResponse(200, "OK",
            ResponseBody(RequestBody.bytes("no".toArray()).open()),
            headers: HttpHeaders.builder().add("Content-Length", "3").build())
        var caught: ?Http1ResponseWriteException = None<Http1ResponseWriteException>
        try { let _ = writeHttp1Response(server, HttpMethod("GET"), response) }
        catch (error: Http1ResponseWriteException) { caught = Some(error) }
        let error = caught.getOrThrow()
        @Expect(isServerWriteCode(error.code, Http1ResponseWriteErrorCode.BodyLengthMismatch))
        @Expect(!error.evidence.responseCommitted)
    }
}

private class ServerWriterBody <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let declared: ?Int64
    private var offset: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>, declared: ?Int64) { this.bytes = bytes.clone(); this.declared = declared }
    public prop contentLength: ?Int64 { get() { declared } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw Exception("closed server writer body") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func isServerWriteCode(actual: Http1ResponseWriteErrorCode,
    expected: Http1ResponseWriteErrorCode): Bool {
    match ((actual, expected)) {
        case (Http1ResponseWriteErrorCode.BodyLengthMismatch,
            Http1ResponseWriteErrorCode.BodyLengthMismatch) => true
        case (Http1ResponseWriteErrorCode.BodyTooLarge,
            Http1ResponseWriteErrorCode.BodyTooLarge) => true
        case (Http1ResponseWriteErrorCode.InvalidResponseState,
            Http1ResponseWriteErrorCode.InvalidResponseState) => true
        case (Http1ResponseWriteErrorCode.WriteFailed,
            Http1ResponseWriteErrorCode.WriteFailed) => true
        case _ => false
    }
}
