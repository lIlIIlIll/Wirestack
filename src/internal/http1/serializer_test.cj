package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

@Test
class Http1SerializerTest {
    @TestCase
    func clientRequestAddsHostAndUsesOriginForm(): Unit {
        let serialized = serializeClientRequestHead(
            HttpMethod("GET"),
            HttpUrl.parse("https://Example.com:8443/path?q=1"),
            HttpHeaders.builder().add("Accept", "text/plain").build()
        )

        @Expect(
            String.fromUtf8(serialized.bytes),
            "GET /path?q=1 HTTP/1.1\r\nAccept: text/plain\r\nHost: example.com:8443\r\n\r\n"
        )
        @Expect(isSerializedEmpty(serialized.framing))
    }

    @TestCase
    func forwardProxyRequestUsesAbsoluteFormAndOriginHost(): Unit {
        let serialized = serializeClientRequestHead(
            HttpMethod("GET"),
            HttpUrl.parse("http://Example.com:8080/path?q=1"),
            HttpHeaders(),
            targetForm: Http1RequestTargetForm.Absolute
        )

        @Expect(
            String.fromUtf8(serialized.bytes),
            "GET http://example.com:8080/path?q=1 HTTP/1.1\r\nHost: example.com:8080\r\n\r\n"
        )
    }

    @TestCase
    func requestPreservesOrderedMultipleFieldsAndLengthFraming(): Unit {
        let headers = HttpHeaders.builder()
            .add("Host", "example.com")
            .add("X-Value", "one")
            .add("X-Value", "two")
            .add("Content-Length", "3")
            .build()
        let serialized = serializeRequestHead(HttpMethod("POST"), "/", headers)

        @Expect(
            String.fromUtf8(serialized.bytes),
            "POST / HTTP/1.1\r\nHost: example.com\r\nX-Value: one\r\nX-Value: two\r\nContent-Length: 3\r\n\r\n"
        )
        @Expect(serializedLength(serialized.framing), 3)
    }

    @TestCase
    func requestRejectsMissingDuplicateOrMismatchedHost(): Unit {
        expectSerializeRequestFailure(HttpHeaders())
        expectSerializeRequestFailure(
            HttpHeaders.builder().add("Host", "a.test").add("Host", "a.test").build()
        )

        var mismatch = false
        try {
            let _ = serializeClientRequestHead(
                HttpMethod("GET"),
                HttpUrl.parse("https://a.test/"),
                HttpHeaders.builder().add("Host", "b.test").build()
            )
        } catch (_: Http1ParseException) {
            mismatch = true
        }
        @Expect(mismatch)
    }

    @TestCase
    func responseSerializesStatusAndUsesSharedFraming(): Unit {
        let serialized = serializeResponseHead(
            200,
            "OK",
            HttpHeaders.builder().add("Content-Length", "2").add("X-Test", "yes").build(),
            HttpMethod("GET")
        )
        @Expect(
            String.fromUtf8(serialized.bytes),
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Test: yes\r\n\r\n"
        )
        @Expect(serializedLength(serialized.framing), 2)
    }

    @TestCase
    func responseRejectsInjectionAndForbiddenBodyFraming(): Unit {
        var reasonRejected = false
        try {
            let _ = serializeResponseHead(200, "OK\r\nInjected", HttpHeaders(), HttpMethod("GET"))
        } catch (_: Http1ParseException) {
            reasonRejected = true
        }
        @Expect(reasonRejected)

        var framingRejected = false
        try {
            let _ = serializeResponseHead(
                204,
                "No Content",
                HttpHeaders.builder().add("Content-Length", "1").build(),
                HttpMethod("GET")
            )
        } catch (_: Http1FramingException) {
            framingRejected = true
        }
        @Expect(framingRejected)
    }

    @TestCase
    func writerHandlesPartialTransportWritesUnderOneContext(): Unit {
        let (writer, reader) = MemoryTransport.pair(capacity: 1024, maxChunk: 2)
        let head = serializeClientRequestHead(
            HttpMethod("GET"),
            HttpUrl.parse("http://example.com/"),
            HttpHeaders()
        )
        writeSerializedHead(writer, head)
        let received = Array<Byte>(head.bytes.size, repeat: 0)
        readExact(reader, MutableByteSpan(received))

        @Expect(received, head.bytes)
    }

    @TestCase
    func serializedBytesAreDefensiveCopies(): Unit {
        let head = serializeClientRequestHead(
            HttpMethod("GET"), HttpUrl.parse("http://example.com/"), HttpHeaders()
        )
        let exposed = head.bytes
        exposed[0] = b'X'
        @Expect(String.fromUtf8(head.bytes).startsWith("GET "))
    }
}

private func expectSerializeRequestFailure(headers: HttpHeaders): Unit {
    var rejected = false
    try {
        let _ = serializeRequestHead(HttpMethod("GET"), "/", headers)
    } catch (_: Http1ParseException) {
        rejected = true
    }
    @Expect(rejected)
}

private func serializedLength(framing: Http1BodyFraming): Int64 {
    match (framing) { case Http1BodyFraming.ContentLength(value) => value; case _ => -1 }
}

private func isSerializedEmpty(framing: Http1BodyFraming): Bool {
    match (framing) { case Http1BodyFraming.Empty => true; case _ => false }
}
