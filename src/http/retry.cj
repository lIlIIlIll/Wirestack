package wirestack.http

import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2
import wirestack.internal.transport as transport

/** Bounded automatic retry policy. Unknown and generic exceptions always fail closed. */
public class HttpRetryPolicy {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let maximumAttempts: Int64

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param maximumAttempts 调用方提供的输入值。
 */
    public init(maximumAttempts!: Int64 = 2) {
        if (maximumAttempts <= 0 || maximumAttempts > 10) {
            throw IllegalArgumentException("HTTP retry attempt limit is invalid")
        }
        this.maximumAttempts = maximumAttempts
    }

/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 * @param attemptsStarted 调用方提供的输入值。
 * @param context 控制本次操作的截止时间、取消和追踪范围。
 * @param error 调用方提供的输入值。
 * @param request 待处理的 HTTP 请求。
 * @param responseCommitted 调用方提供的输入值。
 */
    public func shouldRetry(request: HttpRequest, error: Exception,
        attemptsStarted: Int64, context: OperationContext,
        responseCommitted!: Bool = false): Bool {
        if (responseCommitted || attemptsStarted >= maximumAttempts || context.isCancellationRequested() ||
            context.isDeadlineExceeded() || request.body.replayability != BodyReplayability.Replayable) {
            return false
        }
        match (request.retrySafety) {
            case HttpRetrySafety.Disabled => return false
            case HttpRetrySafety.ExplicitlySafe => ()
            case HttpRetrySafety.Default => if (!isIdempotentMethod(request.method)) { return false }
        }
        match (error) {
            case value: transport.NetworkException => retryable(value.retryability)
            case value: http1.Http1RequestWriteException => retryWriteFailure(value)
            case value: http2.Http2GoAwayException => value.evidence.definitelyNotProcessed
            case _ => false
        }
    }
}

private func isIdempotentMethod(method: HttpMethod): Bool {
    match (method.value) {
        case "GET" | "HEAD" | "PUT" | "DELETE" | "OPTIONS" | "TRACE" => true
        case _ => false
    }
}

private func retryWriteFailure(error: http1.Http1RequestWriteException): Bool {
    match (error.cause) {
        case Some(value: transport.NetworkException) => match (value.retryability) {
            case transport.Retryability.SafeBeforeWrite => !error.evidence.requestCommitted
            case transport.Retryability.SafeIfReplayable | transport.Retryability.Temporary => true
            case transport.Retryability.Never | transport.Retryability.Unknown => false
        }
        case _ => false
    }
}

private func retryable(value: transport.Retryability): Bool {
    match (value) {
        case transport.Retryability.SafeBeforeWrite |
            transport.Retryability.SafeIfReplayable |
            transport.Retryability.Temporary => true
        case transport.Retryability.Never | transport.Retryability.Unknown => false
    }
}
