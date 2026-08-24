package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http2 as http2

@Test
class HttpRetryPolicyTest {
    @TestCase
    func retriesOnlyIdempotentReplayableStructuredFailures(): Unit {
        let policy = HttpRetryPolicy(maximumAttempts: 2)
        let temporary = NetworkException(
            NetworkErrorCategory.Connect,
            NetworkPhase.TcpConnect,
            NetworkErrorCode.ConnectRefused,
            "temporary",
            retryability: Retryability.Temporary
        )
        @Expect(policy.shouldRetry(
            HttpRequest.get("http://example.test/"), temporary, 1, OperationContext.background()
        ))
        @Expect(!policy.shouldRetry(
            HttpRequest.post("http://example.test/", RequestBody.string("x")),
            temporary, 1, OperationContext.background()
        ))
        @Expect(!policy.shouldRetry(
            HttpRequest.get("http://example.test/"), temporary, 2, OperationContext.background()
        ))
        @Expect(!policy.shouldRetry(
            HttpRequest.get("http://example.test/"), temporary, 1,
            OperationContext.background(), responseCommitted: true
        ))
    }

    @TestCase
    func explicitSafetyAllowsPostButDisabledAndOneShotFailClosed(): Unit {
        let policy = HttpRetryPolicy()
        let temporary = NetworkException(
            NetworkErrorCategory.Resolve,
            NetworkPhase.Dns,
            NetworkErrorCode.TemporaryFailure,
            "temporary",
            retryability: Retryability.Temporary
        )
        let safePost = HttpRequest.post("http://example.test/", RequestBody.string("x"))
            .withRetrySafety(HttpRetrySafety.ExplicitlySafe)
        @Expect(policy.shouldRetry(safePost, temporary, 1, OperationContext.background()))
        @Expect(!policy.shouldRetry(
            HttpRequest.get("http://example.test/").withRetrySafety(HttpRetrySafety.Disabled),
            temporary, 1, OperationContext.background()
        ))
        let stream = RequestBody.string("x").open()
        let oneShot = HttpRequest(
            HttpMethod("GET"), HttpUrl.parse("http://example.test/"),
            body: RequestBody.oneShot(stream)
        )
        @Expect(!policy.shouldRetry(oneShot, temporary, 1, OperationContext.background()))
        stream.close()
    }

    @TestCase
    func cancellationDeadlineUnknownAndNeverAreNotRetried(): Unit {
        let policy = HttpRetryPolicy()
        let request = HttpRequest.get("http://example.test/")
        let never = NetworkException(
            NetworkErrorCategory.Read,
            NetworkPhase.HttpHeaders,
            NetworkErrorCode.UnexpectedEof,
            "never",
            retryability: Retryability.Never
        )
        @Expect(!policy.shouldRetry(request, never, 1, OperationContext.background()))
        @Expect(!policy.shouldRetry(request, Exception("generic"), 1, OperationContext.background()))

        let cancelled = CancellationSource()
        cancelled.cancel()
        let temporary = NetworkException(
            NetworkErrorCategory.Resolve,
            NetworkPhase.Dns,
            NetworkErrorCode.TemporaryFailure,
            "temporary",
            retryability: Retryability.Temporary
        )
        @Expect(!policy.shouldRetry(
            request, temporary, 1, OperationContext(cancellation: cancelled.token)
        ))
        @Expect(!policy.shouldRetry(
            request, temporary, 1,
            OperationContext(deadline: Some(Deadline.after(Duration.Zero)))
        ))
    }

    @TestCase
    func goAwayRetriesOnlyDefinitelyUnprocessedSafeReplayableRequests(): Unit {
        let policy = HttpRetryPolicy()
        let definitely = goAwayRetryError(
            5u32, 3u32, http2.Http2GoAwayRequestDisposition.DefinitelyNotProcessed
        )
        let uncertain = goAwayRetryError(
            3u32, 3u32, http2.Http2GoAwayRequestDisposition.MayHaveBeenProcessed
        )
        let get = HttpRequest.get("https://example.test/")
        @Expect(policy.shouldRetry(get, definitely, 1, OperationContext.background()))
        @Expect(!policy.shouldRetry(get, uncertain, 1, OperationContext.background()))
        @Expect(!policy.shouldRetry(
            HttpRequest.post("https://example.test/", RequestBody.string("x")),
            definitely, 1, OperationContext.background()
        ))
        @Expect(!policy.shouldRetry(
            get, definitely, 1, OperationContext.background(), responseCommitted: true
        ))

        let stream = RequestBody.string("x").open()
        let oneShot = HttpRequest(
            HttpMethod("GET"), HttpUrl.parse("https://example.test/"),
            body: RequestBody.oneShot(stream)
        )
        @Expect(!policy.shouldRetry(oneShot, definitely, 1, OperationContext.background()))
        stream.close()
    }
}

private func goAwayRetryError(
    streamId: UInt32,
    lastStreamId: UInt32,
    disposition: http2.Http2GoAwayRequestDisposition
): http2.Http2GoAwayException {
    http2.Http2GoAwayException(http2.Http2GoAwayRetryEvidence(
        http2.Http2StreamId(streamId),
        http2.Http2StreamId(lastStreamId),
        http2.Http2ErrorCode.NoError,
        disposition
    ))
}
