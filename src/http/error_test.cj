package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2
import wirestack.internal.transport as transport

@Test
class HttpErrorTest {
    @TestCase
    func publicGetMapsInvalidUrlWithoutNetworkSideEffects(): Unit {
        let client = HttpClient.builder().build()
        var matched = false
        try {
            let _ = client.get("https://user:secret@example.com/")
        } catch (error: HttpException) {
            matched = sameHttpErrorCode(error.code, HttpErrorCode.InvalidUrl) &&
                error.message == "invalid HTTP URL"
        } finally {
            client.close()
        }
        @Expect(matched)
    }

    @TestCase
    func classifierProvidesStableHttpFailureCodes(): Unit {
        expectHttpError(
            http1.Http1FramingException(
                http1.Http1FramingErrorCode.ConflictingContentLength, "secret framing detail"
            ),
            HttpErrorCode.InvalidFraming
        )
        expectHttpError(
            http1.Http1ChunkException(http1.Http1ChunkErrorCode.BodyTooLarge, "secret body detail"),
            HttpErrorCode.BodyLimitExceeded
        )
        expectHttpError(
            transport.NetworkException(
                transport.NetworkErrorCategory.ResourceExhausted,
                transport.NetworkPhase.PoolAcquire,
                transport.NetworkErrorCode.ResourceExhausted,
                "secret pool detail"
            ),
            HttpErrorCode.PoolExhausted
        )
        expectHttpError(
            HttpRedirectException(HttpRedirectErrorCode.TooManyRedirects, "secret redirect detail"),
            HttpErrorCode.RedirectLimit
        )
        expectHttpError(
            http2.Http2GoAwayException(http2.Http2GoAwayRetryEvidence(
                http2.Http2StreamId(5u32), http2.Http2StreamId(3u32),
                http2.Http2ErrorCode.NoError,
                http2.Http2GoAwayRequestDisposition.DefinitelyNotProcessed
            )),
            HttpErrorCode.ConnectionGoAway
        )
    }
}

private func expectHttpError(error: Exception, expected: HttpErrorCode): Unit {
    let wrapped = wrapHttpError(error)
    match (wrapped) {
        case value: HttpException =>
            @Expect(sameHttpErrorCode(value.code, expected))
            @Expect(!value.message.contains("secret"))
            @Expect(value.cause.isSome())
        case _ => @Expect(false)
    }
}

private func sameHttpErrorCode(left: HttpErrorCode, right: HttpErrorCode): Bool {
    match ((left, right)) {
        case (HttpErrorCode.InvalidUrl, HttpErrorCode.InvalidUrl) => true
        case (HttpErrorCode.InvalidRequest, HttpErrorCode.InvalidRequest) => true
        case (HttpErrorCode.InvalidResponse, HttpErrorCode.InvalidResponse) => true
        case (HttpErrorCode.HeaderLimitExceeded, HttpErrorCode.HeaderLimitExceeded) => true
        case (HttpErrorCode.BodyLimitExceeded, HttpErrorCode.BodyLimitExceeded) => true
        case (HttpErrorCode.InvalidFraming, HttpErrorCode.InvalidFraming) => true
        case (HttpErrorCode.ProtocolViolation, HttpErrorCode.ProtocolViolation) => true
        case (HttpErrorCode.ProxyFailure, HttpErrorCode.ProxyFailure) => true
        case (HttpErrorCode.PoolExhausted, HttpErrorCode.PoolExhausted) => true
        case (HttpErrorCode.RedirectLimit, HttpErrorCode.RedirectLimit) => true
        case (HttpErrorCode.BodyNotReplayable, HttpErrorCode.BodyNotReplayable) => true
        case (HttpErrorCode.StreamReset, HttpErrorCode.StreamReset) => true
        case (HttpErrorCode.ConnectionGoAway, HttpErrorCode.ConnectionGoAway) => true
        case (HttpErrorCode.ServerOverloaded, HttpErrorCode.ServerOverloaded) => true
        case _ => false
    }
}
