package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*

/** Fixed regression corpus for parser differentials commonly used in request smuggling. */
@Test
class Http1SmugglingCorpusTest {
    @TestCase
    func clientAndServerFramingRejectTheSameAmbiguousHeaderCorpus(): Unit {
        let ambiguous = [
            "Content-Length: 5\r\nContent-Length: 6",
            "Content-Length: 5, 6",
            "Content-Length: 5,,5",
            "Content-Length: +5",
            "Content-Length: -1",
            "Content-Length: 0x5",
            "Content-Length:",
            "Content-Length: 99999999999999999999",
            "Transfer-Encoding: chunked\r\nContent-Length: 5",
            "Content-Length: 5\r\nTransfer-Encoding: chunked",
            "Transfer-Encoding: gzip",
            "Transfer-Encoding: gzip, chunked",
            "Transfer-Encoding: chunked, chunked",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked"
        ]
        for (fields in ambiguous) {
            @Expect(!requestHeadAccepted(fields))
            @Expect(!responseHeadAccepted(fields))
        }
    }

    @TestCase
    func identicalLengthsAndOneFinalChunkedCodingRemainUnambiguous(): Unit {
        for (fields in [
            "Content-Length: 5",
            "Content-Length: 5\r\nContent-Length: 5",
            "Content-Length: 5, 5",
            "Transfer-Encoding: chunked",
            "Transfer-Encoding: ChUnKeD"
        ]) {
            @Expect(requestHeadAccepted(fields))
            @Expect(responseHeadAccepted(fields))
        }
    }

    @TestCase
    func rejectsWhitespaceTargetAndProxyDifferentialCorpus(): Unit {
        let wires = [
            "GET / HTTP/1.1\nHost: example.com\n\n",
            "GET / HTTP/1.1\r\nHost : example.com\r\n\r\n",
            "GET / HTTP/1.1\r\n Host: example.com\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: example.com\r\n\tX: folded\r\n\r\n",
            "GET  / HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "GET\t/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: example.com\r\nX-Test: a\u{000b}b\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: example.com\r\nX-Test: a\u{007f}b\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n",
            "GET http://example.com/a HTTP/1.1\r\nHost: other.test\r\n\r\n",
            "GET http://example.com/a HTTP/1.1\r\nHost: example.com:81\r\n\r\n",
            "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:80\r\n\r\n",
            "GET /a\\b HTTP/1.1\r\nHost: example.com\r\n\r\n",
            "GET /a#fragment HTTP/1.1\r\nHost: example.com\r\n\r\n"
        ]
        for (wire in wires) { @Expect(!rawRequestAccepted(wire)) }
    }

    @TestCase
    func rejectsMalformedChunkAndTrailerCorpusAtInputOrEof(): Unit {
        for (wire in [
            "z\r\n",
            "+1\r\n",
            "0x1\r\n",
            "8000000000000000\r\n",
            "1;=bad\r\n",
            "1;open=\"x\r\n",
            "1\na\r\n",
            "1\r\naX",
            "2\r\na",
            "0\r\nContent-Length: 1\r\n\r\n",
            "0\r\nTransfer-Encoding: chunked\r\n\r\n",
            "0\r\nDigest: a\r\n folded\r\n\r\n"
        ]) {
            @Expect(chunkRejected(wire))
        }
    }

    @TestCase
    func everyAcceptedSingleByteMutationHasACanonicalReparse(): Unit {
        let seed = "POST /upload?q=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nX-Test: value\r\n\r\nhello".toArray()
        let replacements = [0u8, 9u8, 10u8, 13u8, 32u8, 44u8, 58u8, 65u8, 127u8, 255u8]
        var accepted: Int64 = 0
        for (index in 0..seed.size) {
            for (replacement in replacements) {
                let mutated = seed.clone()
                mutated[index] = replacement
                try {
                    match (Http1RequestHeadParser().feed(mutated)) {
                        case Some(parsed) =>
                            let canonical = serializeRequestHead(
                                parsed.head.method, parsed.head.target, parsed.head.headers
                            )
                            @Expect(Http1RequestHeadParser().feed(canonical.bytes).isSome())
                            accepted++
                        case None => ()
                    }
                } catch (_: Exception) {}
            }
        }
        @Expect(accepted > 100)
    }

    @TestCase
    func validHeadParsesAtEveryTransportSplitBoundary(): Unit {
        let wire = "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 3\r\n\r\nabc".toArray()
        for (split in 0..(wire.size + 1)) {
            let parser = Http1RequestHeadParser()
            let first = parser.feed(copyCorpusRange(wire, 0, split))
            let parsed = match (first) {
                case Some(value) => value
                case None => parser.feed(copyCorpusRange(wire, split, wire.size)).getOrThrow()
            }
            @Expect(parsed.head.target, "/")
            @Expect(corpusContentLength(parsed.head.framing), 3)
        }
    }
}

private func requestHeadAccepted(fields: String): Bool {
    rawRequestAccepted("POST / HTTP/1.1\r\nHost: example.com\r\n${fields}\r\n\r\n")
}

private func responseHeadAccepted(fields: String): Bool {
    try {
        Http1ResponseHeadParser(HttpMethod("POST")).feed(
            "HTTP/1.1 200 OK\r\n${fields}\r\n\r\n".toArray()
        ).isSome()
    } catch (_: Exception) { false }
}

private func rawRequestAccepted(wire: String): Bool {
    try { Http1RequestHeadParser().feed(wire.toArray()).isSome() }
    catch (_: Exception) { false }
}

private func chunkRejected(wire: String): Bool {
    let decoder = Http1ChunkedDecoder()
    try {
        let batch = decoder.feed(wire.toArray())
        if (!batch.complete) { decoder.finish() }
        false
    } catch (_: Exception) { true }
}

private func copyCorpusRange(value: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    let result = Array<Byte>(end - start, repeat: 0)
    for (index in start..end) { result[index - start] = value[index] }
    result
}

private func corpusContentLength(value: Http1BodyFraming): Int64 {
    match (value) { case Http1BodyFraming.ContentLength(length) => length; case _ => -1 }
}
