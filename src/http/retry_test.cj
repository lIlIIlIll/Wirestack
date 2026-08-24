package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

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
}
