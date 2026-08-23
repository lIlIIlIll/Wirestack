package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpMessageTest {
    @TestCase
    func requestFactoriesProduceImmutableProtocolNeutralModels(): Unit {
        let request = HttpRequest.post(
            "https://Example.com/upload",
            RequestBody.string("payload")
        ).withHeaders(HttpHeaders.builder().add("Content-Type", "text/plain").build())

        @Expect(request.method, HttpMethod("POST"))
        @Expect(request.url.toString(), "https://example.com/upload")
        @Expect(request.headers.getFirst("content-type"), Some("text/plain"))
        @Expect(request.body.contentLength, Some(7))
    }

    @TestCase
    func responseEofCompletesObserverExactlyOnce(): Unit {
        let observer = RecordingBodyObserver()
        let body = ResponseBody(RequestBody.bytes("ok".toArray()).open(), observer: observer)
        let response = HttpResponse(200, "OK", body)
        let destination = Array<Byte>(8, repeat: 0)

        @Expect(response.body.read(destination), 2)
        @Expect(response.body.read(destination), 0)
        @Expect(response.body.read(destination), 0)
        @Expect(response.body.isFullyConsumed())
        @Expect(observer.completions, 1)
        @Expect(observer.abandons, 0)
        response.close()
        response.close()
        @Expect(observer.completions, 1)
        @Expect(observer.abandons, 0)
    }

    @TestCase
    func earlyCloseAbandonsObserverExactlyOnce(): Unit {
        let observer = RecordingBodyObserver()
        let response = HttpResponse(
            200,
            "OK",
            ResponseBody(RequestBody.bytes("remaining".toArray()).open(), observer: observer)
        )

        response.close()
        response.close()
        @Expect(observer.completions, 0)
        @Expect(observer.abandons, 1)
        expectMessageBodyFailure(HttpBodyErrorCode.Closed, {
            => let _ = response.body.read(Array<Byte>(1, repeat: 0))
        })
    }

    @TestCase
    func readFailureClosesAndAbandonsTheBody(): Unit {
        let observer = RecordingBodyObserver()
        let source = FailingBodyStream()
        let body = ResponseBody(source, observer: observer)

        var failed = false
        try {
            let _ = body.read(Array<Byte>(1, repeat: 0))
        } catch (_: Exception) {
            failed = true
        }
        @Expect(failed)
        @Expect(body.isClosed())
        @Expect(source.isClosed())
        @Expect(observer.abandons, 1)
    }

    @TestCase
    func emptyDestinationDoesNotMistakeNoProgressForEof(): Unit {
        let observer = RecordingBodyObserver()
        let body = ResponseBody(RequestBody.bytes("x".toArray()).open(), observer: observer)
        @Expect(body.read(Array<Byte>()), 0)
        @Expect(!body.isFullyConsumed())
        @Expect(observer.completions, 0)
        body.close()
        @Expect(observer.abandons, 1)
    }

    @TestCase
    func responseRejectsInvalidStatusAndReason(): Unit {
        for (status in [99, 1000]) {
            var rejected = false
            try {
                let _ = HttpResponse(status, "bad", ResponseBody.empty())
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
        var reasonRejected = false
        try {
            let _ = HttpResponse(200, "OK\r\nInjected", ResponseBody.empty())
        } catch (_: IllegalArgumentException) {
            reasonRejected = true
        }
        @Expect(reasonRejected)
    }
}

private class RecordingBodyObserver <: ResponseBodyObserver {
    var completions: Int64 = 0
    var abandons: Int64 = 0
    public func completed(): Unit { completions++ }
    public func abandoned(): Unit { abandons++ }
}

private class FailingBodyStream <: HttpBodyStream {
    private var closed = false
    public prop contentLength: ?Int64 { get() { None<Int64> } }
    public func read(_: Array<Byte>): Int64 { throw Exception("scripted read failure") }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func expectMessageBodyFailure(code: HttpBodyErrorCode, action: () -> Unit): Unit {
    var matched = false
    try {
        action()
    } catch (error: HttpBodyException) {
        match ((error.code, code)) {
            case (HttpBodyErrorCode.Closed, HttpBodyErrorCode.Closed) => matched = true
            case _ => ()
        }
    }
    @Expect(matched)
}
