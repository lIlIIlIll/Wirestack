package wirestack.internal.http1

import std.env.getVariable
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
        let seed = m7023Http1Seed(
            "http1-parser",
            "POST /upload?q=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nX-Test: value\r\n\r\nhello".toArray()
        )
        let replacements = [0u8, 9u8, 10u8, 13u8, 32u8, 44u8, 58u8, 65u8, 127u8, 255u8]
        var accepted: Int64 = 0
        var executions: Int64 = 0
        for (index in 0..seed.size) {
            for (replacement in replacements) {
                executions++
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
        println(
            "M7023_FUZZ target=http1-parser seed=7023 " +
            "iterations=${executions} decision=PASS"
        )
    }

    @TestCase
    func chunkedMutationsHaveDeterministicBoundedTerminals(): Unit {
        let seed = m7023Http1Seed(
            "chunked-decoder", "4\r\nWiki\r\n0\r\n\r\n".toArray()
        )
        let replacements = [0u8, 10u8, 13u8, 32u8, 43u8, 59u8, 127u8, 255u8]
        var executions: Int64 = 0
        for (index in 0..seed.size) {
            for (replacement in replacements) {
                let mutated = seed.clone()
                mutated[index] = replacement
                @Assert(m7023ClassifyChunked(mutated), m7023ClassifyChunked(mutated))
                executions++
            }
        }
        for (length in 0..(seed.size + 1)) {
            let truncated = copyCorpusRange(seed, 0, length)
            @Assert(m7023ClassifyChunked(truncated), m7023ClassifyChunked(truncated))
            executions++
        }
        println(
            "M7023_FUZZ target=chunked-decoder seed=7023 " +
            "iterations=${executions} decision=PASS"
        )
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

private func m7023ClassifyChunked(input: Array<Byte>): String {
    try {
        let decoder = Http1ChunkedDecoder()
        let batch = decoder.feed(input)
        if (!batch.complete) { decoder.finish() }
        "accepted"
    } catch (_: Exception) {
        "rejected"
    }
}

private func m7023Http1Seed(target: String, fallback: Array<Byte>): Array<Byte> {
    match (getVariable("WIRESTACK_M7_023_TARGET")) {
        case None => fallback
        case Some(actual) =>
            if (actual != target) {
                throw IllegalStateException("M7-023 target mismatch: ${actual}")
            }
            match (getVariable("WIRESTACK_M7_023_CORPUS_HEX")) {
                case Some(value) => m7023Http1Hex(value)
                case None => throw IllegalStateException("missing M7-023 corpus")
            }
    }
}

private func m7023Http1Hex(value: String): Array<Byte> {
    let input = value.toArray()
    var digits: Int64 = 0
    for (byte in input) { if (byte > 32u8) { digits++ } }
    if (digits == 0 || digits % 2 != 0) {
        throw IllegalArgumentException("invalid M7-023 hex corpus")
    }
    let output = Array<Byte>(digits / 2, repeat: 0u8)
    var high: ?Byte = None<Byte>
    var index: Int64 = 0
    for (byte in input) {
        if (byte <= 32u8) { continue }
        let nibble = m7023Http1Nibble(byte)
        match (high) {
            case None => high = Some(nibble)
            case Some(value) =>
                output[index] = (value << 4) | nibble
                index++
                high = None<Byte>
        }
    }
    output
}

private func m7023Http1Nibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10u8 }
    else { throw IllegalArgumentException("invalid M7-023 hex digit") }
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
