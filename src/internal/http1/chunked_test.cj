package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*

@Test
class Http1ChunkedCodecTest {
    @TestCase
    func decoderStreamsDataExtensionsTrailersAndRemainder(): Unit {
        let decoder = Http1ChunkedDecoder()
        let batch = decoder.feed(
            "4;foo=bar\r\nWiki\r\n5; quoted=\"x\\\"y\"\r\npedia\r\n0\r\nDigest: ok\r\nX-End: yes\r\n\r\nNEXT".toArray()
        )

        @Expect(String.fromUtf8(batch.data), "Wikipedia")
        @Expect(batch.complete)
        @Expect(String.fromUtf8(batch.remaining), "NEXT")
        let trailer = match (batch.trailer) {
            case Some(value) => value
            case None => throw Exception("missing trailer")
        }
        @Expect(trailer.headers.getFirst("digest"), Some("ok"))
        @Expect(trailer.headers.getFirst("x-end"), Some("yes"))
        decoder.finish()
    }

    @TestCase
    func decoderHandlesEveryBoundaryOneByteAtATime(): Unit {
        let decoder = Http1ChunkedDecoder()
        let wire = "3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".toArray()
        let output = ArrayList<Byte>()
        var completed = false
        for (byte in wire) {
            let batch = decoder.feed([byte])
            for (value in batch.data) { output.add(value) }
            if (batch.complete) { completed = true }
        }
        @Expect(String.fromUtf8(output.toArray()), "abcde")
        @Expect(completed)
        decoder.finish()
    }

    @TestCase
    func encoderProducesCanonicalChunksAndBoundedTrailers(): Unit {
        @Expect(
            String.fromUtf8(encodeHttp1Chunk("0123456789".toArray(), extension: Some("foo=bar"))),
            "a;foo=bar\r\n0123456789\r\n"
        )
        let trailer = HttpTrailer(headers: HttpHeaders.builder()
            .add("Digest", "sha-256=value")
            .add("X-End", "yes")
            .build())
        @Expect(
            String.fromUtf8(encodeHttp1FinalChunk(trailer: trailer)),
            "0\r\nDigest: sha-256=value\r\nX-End: yes\r\n\r\n"
        )
    }

    @TestCase
    func rejectsInvalidSizeExtensionAndTerminators(): Unit {
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkSize, "z\r\n")
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkSize, "8000000000000000\r\n")
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkExtension, "1;=bad\r\n")
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkExtension, "1;foo=\"open\r\n")
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkTerminator, "1\r\naX")
        expectChunkFailure(Http1ChunkErrorCode.InvalidChunkTerminator, "1\na\r\n")
    }

    @TestCase
    func enforcesBodyChunkLineAndTrailerBounds(): Unit {
        expectChunkFailure(
            Http1ChunkErrorCode.BodyTooLarge,
            "3\r\n",
            limits: HttpLimits(maxBodyBytes: 2)
        )
        expectChunkFailure(
            Http1ChunkErrorCode.ChunkLineTooLong,
            "1;extension=long\r\n",
            limits: HttpLimits(maxChunkLineBytes: 4)
        )
        expectChunkFailure(
            Http1ChunkErrorCode.TrailerTooLarge,
            "0\r\nA: 1\r\nB: 2\r\n\r\n",
            limits: HttpLimits(maxTrailerCount: 1)
        )

        var encodeBodyRejected = false
        try {
            let _ = encodeHttp1Chunk("abc".toArray(), limits: HttpLimits(maxBodyBytes: 2))
        } catch (error: Http1ChunkException) {
            encodeBodyRejected = sameChunkCode(error.code, Http1ChunkErrorCode.BodyTooLarge)
        }
        @Expect(encodeBodyRejected)

        var encodeLineRejected = false
        try {
            let _ = encodeHttp1Chunk(
                "a".toArray(), extension: Some("extension=long"), limits: HttpLimits(maxChunkLineBytes: 4)
            )
        } catch (error: Http1ChunkException) {
            encodeLineRejected = sameChunkCode(error.code, Http1ChunkErrorCode.ChunkLineTooLong)
        }
        @Expect(encodeLineRejected)
    }

    @TestCase
    func streamingResponseKeepsEachChunkBoundedWithoutALifetimeCeiling(): Unit {
        let decoder = Http1ChunkedDecoder(
            HttpLimits(maxBodyBytes: 2), streamingResponse: true
        )
        let first = decoder.feed("2\r\nab\r\n".toArray())
        @Expect(first.data, "ab".toArray())
        @Expect(!first.complete)
        let second = decoder.feed("2\r\ncd\r\n0\r\n\r\n".toArray())
        @Expect(second.data, "cd".toArray())
        @Expect(second.complete)
    }

    @TestCase
    func rejectsForbiddenOrFoldedTrailers(): Unit {
        expectChunkFailure(Http1ChunkErrorCode.InvalidTrailer, "0\r\nContent-Length: 1\r\n\r\n")
        expectChunkFailure(Http1ChunkErrorCode.InvalidTrailer, "0\r\nDigest: a\r\n folded\r\n\r\n")
    }

    @TestCase
    func eofAndPostCompletionUseFailClosedStates(): Unit {
        let incomplete = Http1ChunkedDecoder()
        let _ = incomplete.feed("2\r\na".toArray())
        var eofRejected = false
        try {
            incomplete.finish()
        } catch (error: Http1ChunkException) {
            eofRejected = sameChunkCode(error.code, Http1ChunkErrorCode.UnexpectedEof)
        }
        @Expect(eofRejected)

        let complete = Http1ChunkedDecoder()
        let _ = complete.feed("0\r\n\r\n".toArray())
        var reuseRejected = false
        try {
            let _ = complete.feed(Array<Byte>())
        } catch (error: Http1ChunkException) {
            reuseRejected = sameChunkCode(error.code, Http1ChunkErrorCode.DecoderAlreadyCompleted)
        }
        @Expect(reuseRejected)
    }

    @TestCase
    func decodeBatchesOwnDataAndRemainingBytes(): Unit {
        let batch = Http1ChunkedDecoder().feed("1\r\na\r\n0\r\n\r\nrest".toArray())
        let data = batch.data
        let remaining = batch.remaining
        data[0] = b'x'
        remaining[0] = b'X'
        @Expect(String.fromUtf8(batch.data), "a")
        @Expect(String.fromUtf8(batch.remaining), "rest")
    }
}

private func expectChunkFailure(
    code: Http1ChunkErrorCode,
    wire: String,
    limits!: HttpLimits = HttpLimits()
): Unit {
    var matched = false
    try {
        let _ = Http1ChunkedDecoder(limits: limits).feed(wire.toArray())
    } catch (error: Http1ChunkException) {
        matched = sameChunkCode(error.code, code)
    }
    @Expect(matched)
}

private func sameChunkCode(left: Http1ChunkErrorCode, right: Http1ChunkErrorCode): Bool {
    match ((left, right)) {
        case (Http1ChunkErrorCode.InvalidChunkSize, Http1ChunkErrorCode.InvalidChunkSize) => true
        case (Http1ChunkErrorCode.ChunkLineTooLong, Http1ChunkErrorCode.ChunkLineTooLong) => true
        case (Http1ChunkErrorCode.InvalidChunkExtension, Http1ChunkErrorCode.InvalidChunkExtension) => true
        case (Http1ChunkErrorCode.InvalidChunkTerminator, Http1ChunkErrorCode.InvalidChunkTerminator) => true
        case (Http1ChunkErrorCode.BodyTooLarge, Http1ChunkErrorCode.BodyTooLarge) => true
        case (Http1ChunkErrorCode.InvalidTrailer, Http1ChunkErrorCode.InvalidTrailer) => true
        case (Http1ChunkErrorCode.TrailerTooLarge, Http1ChunkErrorCode.TrailerTooLarge) => true
        case (Http1ChunkErrorCode.UnexpectedEof, Http1ChunkErrorCode.UnexpectedEof) => true
        case (Http1ChunkErrorCode.DecoderAlreadyCompleted, Http1ChunkErrorCode.DecoderAlreadyCompleted) => true
        case _ => false
    }
}
