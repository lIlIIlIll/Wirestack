package wirestack.http

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
class MultipartTest {
    @TestCase
    func writerStreamsExactBinaryFramingAndReplaysIndependently(): Unit {
        let writer = MultipartWriter("wirestack-boundary")
            .add(MultipartPart("text", "value".toArray(), contentType: "text/plain"))
            .add(MultipartPart("file", [0u8, 255u8, 13u8, 10u8, 1u8],
                filename: Some("bytes.bin")))
        let body = writer.body(maximumBytes: 4096)

        @Expect(body.replayability, BodyReplayability.Replayable)
        let first = readMultipartStream(body.open(), 3)
        let second = readMultipartStream(body.open(), 7)
        @Expect(first, second)
        @Expect(first, joinMultipartBytes([
            "--wirestack-boundary\r\n".toArray(),
            "Content-Disposition: form-data; name=\"text\"\r\n".toArray(),
            "Content-Type: text/plain\r\n\r\n".toArray(),
            "value\r\n".toArray(),
            "--wirestack-boundary\r\n".toArray(),
            "Content-Disposition: form-data; name=\"file\"; filename=\"bytes.bin\"\r\n".toArray(),
            "Content-Type: application/octet-stream\r\n\r\n".toArray(),
            [0u8, 255u8, 13u8, 10u8, 1u8],
            "\r\n--wirestack-boundary--\r\n".toArray()
        ]))
    }

    @TestCase
    func boundarySeparatorsRoundtripThroughContentTypeAndBody(): Unit {
        let writer = MultipartWriter("upload:part/with=separators?")
            .add(MultipartPart("field", "value".toArray()))
        @Expect(writer.contentType(), "multipart/form-data; boundary=\"upload:part/with=separators?\"")
        let reader = MultipartReader(ResponseBody(writer.body().open()),
            boundaryFromMultipartContentType(writer.contentType()))
        try {
            let part = reader.next().getOrThrow()
            @Expect(readMultipartStream(part.body, 3), "value".toArray())
            part.close()
            @Expect(reader.next().isNone())
        } finally { reader.close() }
    }

    @TestCase
    func readerPreservesBinaryWhenEveryDelimiterIsSplitAcrossReads(): Unit {
        let encoded = joinMultipartBytes([
            "--b123\r\n".toArray(),
            "Content-Disposition: form-data; name=\"first\"\r\n\r\n".toArray(),
            [0u8, 1u8, 13u8, 10u8],
            "--b123X".toArray(),
            [255u8],
            "\r\n--b123\r\n".toArray(),
            "Content-Disposition: form-data; name=\"second\"; filename=\"x.bin\"\r\n".toArray(),
            "Content-Type: application/octet-stream\r\n\r\n".toArray(),
            [9u8, 8u8, 7u8],
            "\r\n--b123--\r\n".toArray()
        ])
        let response = ResponseBody(SplitMultipartStream(encoded, 1))
        let reader = MultipartReader(response, "b123", limits: MultipartLimits(
            maximumPartBytes: 1024,
            maximumBodyBytes: 4096,
            readBufferBytes: 4
        ))

        let first = reader.next().getOrThrow()
        @Expect(first.name, "first")
        @Expect(first.filename.isNone())
        @Expect(readMultipartStream(first.body, 2), joinMultipartBytes([
            [0u8, 1u8, 13u8, 10u8],
            "--b123X".toArray(),
            [255u8]
        ]))
        first.close()

        let second = reader.next().getOrThrow()
        @Expect(second.name, "second")
        @Expect(second.filename, Some("x.bin"))
        @Expect(readMultipartStream(second.body, 2), [9u8, 8u8, 7u8])
        second.close()
        @Expect(reader.next().isNone())
        @Expect(reader.isClosed())
    }

    @TestCase
    func closingPartDiscardsOnlyThatPartAndReleasesNextPart(): Unit {
        let encoded = MultipartWriter("discard-boundary")
            .add(MultipartPart("discard", Array<Byte>(257, { index => UInt8(index % 251) })))
            .add(MultipartPart("keep", "kept".toArray()))
            .body(maximumBytes: 4096)
        let reader = MultipartReader(ResponseBody(encoded.open()), "discard-boundary",
            limits: MultipartLimits(maximumPartBytes: 1024, maximumBodyBytes: 4096,
                readBufferBytes: 8))

        let discarded = reader.next().getOrThrow()
        let prefix = Array<Byte>(3, repeat: 0u8)
        @Expect(discarded.body.read(prefix), 3)
        let activeError = @AssertThrows[MultipartException](reader.next())
        @Expect(activeError.code, MultipartErrorCode.ActivePart)
        discarded.close()

        let kept = reader.next().getOrThrow()
        @Expect(readMultipartStream(kept.body, 1), "kept".toArray())
        kept.close()
        @Expect(reader.next().isNone())
    }

    @TestCase
    func malformedAndConfiguredLimitsCloseOwnedSource(): Unit {
        let malformedResponse = ResponseBody(SplitMultipartStream(
            "--bad\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\npayload".toArray(), 2
        ))
        let malformed = MultipartReader(malformedResponse, "bad", limits: MultipartLimits(
            maximumPartBytes: 64,
            maximumBodyBytes: 256,
            readBufferBytes: 4
        ))
        let part = malformed.next().getOrThrow()
        @AssertThrows[MultipartException](readMultipartStream(part.body, 3))
        @Expect(malformedResponse.isClosed())

        let oversizedResponse = ResponseBody(SplitMultipartStream(Array<Byte>(65, repeat: 1u8), 4))
        let error = @AssertThrows[MultipartException](MultipartReader(
            oversizedResponse,
            "b",
            limits: MultipartLimits(maximumPartBytes: 32, maximumBodyBytes: 64,
                readBufferBytes: 4)
        ))
        @Expect(error.code, MultipartErrorCode.BodyBytesLimitExceeded)
        @Expect(oversizedResponse.isClosed())
    }

    @TestCase
    func partCountLimitRejectsBeforeParsingUnboundedAdditionalMetadata(): Unit {
        let body = MultipartWriter("count-boundary")
            .add(MultipartPart("one", "1".toArray()))
            .add(MultipartPart("two", "2".toArray()))
            .body(maximumBytes: 4096)
        let reader = MultipartReader(ResponseBody(body.open()), "count-boundary",
            limits: MultipartLimits(maximumParts: 1, maximumPartBytes: 64,
                maximumBodyBytes: 4096, readBufferBytes: 4))
        let first = reader.next().getOrThrow()
        @Expect(readMultipartStream(first.body, 1), "1".toArray())
        first.close()
        let error = @AssertThrows[MultipartException](reader.next())
        @Expect(error.code, MultipartErrorCode.PartLimitExceeded)
        @Expect(reader.isClosed())
    }
}

private class SplitMultipartStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let maximumRead: Int64
    private var offset: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>, maximumRead: Int64) {
        this.bytes = bytes.clone()
        this.maximumRead = maximumRead
    }

    public prop contentLength: ?Int64 { get() { Some(bytes.size) } }

    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw HttpBodyException(HttpBodyErrorCode.Closed, "test stream is closed") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, min(maximumRead, bytes.size - offset))
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }

    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func joinMultipartBytes(parts: Array<Array<Byte>>): Array<Byte> {
    let output = ArrayList<Byte>()
    for (part in parts) {
        for (byte in part) { output.add(byte) }
    }
    output.toArray()
}

private func readMultipartStream(stream: HttpBodyStream, chunkSize: Int64): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(chunkSize, repeat: 0u8)
    try {
        while (true) {
            let count = stream.read(buffer)
            if (count == 0) { break }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        output.toArray()
    } finally {
        stream.close()
    }
}
