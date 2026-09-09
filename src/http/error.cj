package wirestack.http

import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2
import wirestack.internal.transport as transport

/** Stable HTTP failures. HTTP 4xx/5xx responses are not errors in this model. */
public enum HttpErrorCode {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidUrl
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidRequest
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidResponse
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | HeaderLimitExceeded
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | BodyLimitExceeded
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | InvalidFraming
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ProtocolViolation
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ProxyFailure
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | PoolExhausted
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | RedirectLimit
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | BodyNotReplayable
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | StreamReset
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ConnectionGoAway
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | ServerOverloaded
}

/**
 * Wirestack 公开 API：表示一次可由调用方捕获的操作失败。
 */
public class HttpException <: Exception {
/**
 * Wirestack 公开 API：返回当前对象保存的受约束值。
 */
    public let code: HttpErrorCode
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let cause: ?Exception

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param cause 导致当前错误的底层异常。
 * @param code 稳定的错误或状态分类。
 * @param message 面向调用方的诊断文本。
 */
    public init(code: HttpErrorCode, message: String,
        cause!: ?Exception = None<Exception>) {
        super(message)
        this.code = code
        this.cause = cause
    }

/**
 * Wirestack 公开 API：返回运行时类型名称。
 */
    protected override func getClassName(): String { "HttpException" }
}

internal func classifyHttpError(error: Exception): ?HttpErrorCode {
    match (error) {
        case value: HttpException => Some(value.code)
        case value: HttpRedirectException => Some(match (value.code) {
            case HttpRedirectErrorCode.TooManyRedirects => HttpErrorCode.RedirectLimit
            case HttpRedirectErrorCode.BodyNotReplayable => HttpErrorCode.BodyNotReplayable
            case _ => HttpErrorCode.InvalidResponse
        })
        case _: http1.Http1ProxyConnectException => Some(HttpErrorCode.ProxyFailure)
        case _: http2.Http2GoAwayException => Some(HttpErrorCode.ConnectionGoAway)
        case value: http2.Http2ProtocolException => Some(match (value.scope) {
            case http2.Http2ErrorScope.Stream(_) => HttpErrorCode.StreamReset
            case http2.Http2ErrorScope.Connection => HttpErrorCode.ProtocolViolation
        })
        case value: http1.Http1ParseException => Some(match (value.code) {
            case http1.Http1ParseErrorCode.HeaderTooLarge => HttpErrorCode.HeaderLimitExceeded
            case http1.Http1ParseErrorCode.LineTooLong => HttpErrorCode.HeaderLimitExceeded
            case _ => HttpErrorCode.InvalidResponse
        })
        case _: http1.Http1FramingException => Some(HttpErrorCode.InvalidFraming)
        case value: http1.Http1ChunkException => Some(match (value.code) {
            case http1.Http1ChunkErrorCode.BodyTooLarge => HttpErrorCode.BodyLimitExceeded
            case http1.Http1ChunkErrorCode.TrailerTooLarge => HttpErrorCode.HeaderLimitExceeded
            case _ => HttpErrorCode.InvalidFraming
        })
        case value: http1.Http1RequestWriteException => match (value.code) {
            case http1.Http1RequestWriteErrorCode.BodyTooLarge => Some(HttpErrorCode.BodyLimitExceeded)
            case http1.Http1RequestWriteErrorCode.BodyLengthMismatch => Some(HttpErrorCode.InvalidFraming)
            case http1.Http1RequestWriteErrorCode.InvalidRequestFraming => Some(HttpErrorCode.InvalidFraming)
            case http1.Http1RequestWriteErrorCode.InvalidRequestState => Some(HttpErrorCode.InvalidRequest)
            case http1.Http1RequestWriteErrorCode.WriteFailed => None<HttpErrorCode>
        }
        case value: transport.NetworkException =>
            if (isPoolExhaustion(value)) {
                Some(HttpErrorCode.PoolExhausted)
            } else {
                None<HttpErrorCode>
            }
        case _ => None<HttpErrorCode>
    }
}

internal func wrapHttpError(error: Exception): Exception {
    match (classifyHttpError(error)) {
        case Some(code) => match (error) {
            case value: HttpException => value
            case _ => HttpException(code, httpErrorMessage(code), cause: error)
        }
        case None => error
    }
}

private func isPoolExhaustion(error: transport.NetworkException): Bool {
    match ((error.phase, error.code)) {
        case (transport.NetworkPhase.PoolAcquire, transport.NetworkErrorCode.ResourceExhausted) => true
        case _ => false
    }
}

private func httpErrorMessage(code: HttpErrorCode): String {
    match (code) {
        case HttpErrorCode.InvalidUrl => "invalid HTTP URL"
        case HttpErrorCode.InvalidRequest => "invalid HTTP request"
        case HttpErrorCode.InvalidResponse => "invalid HTTP response"
        case HttpErrorCode.HeaderLimitExceeded => "HTTP header limit exceeded"
        case HttpErrorCode.BodyLimitExceeded => "HTTP body limit exceeded"
        case HttpErrorCode.InvalidFraming => "invalid HTTP framing"
        case HttpErrorCode.ProtocolViolation => "HTTP protocol violation"
        case HttpErrorCode.ProxyFailure => "HTTP proxy failure"
        case HttpErrorCode.PoolExhausted => "HTTP connection pool exhausted"
        case HttpErrorCode.RedirectLimit => "HTTP redirect limit exceeded"
        case HttpErrorCode.BodyNotReplayable => "HTTP body is not replayable"
        case HttpErrorCode.StreamReset => "HTTP stream reset"
        case HttpErrorCode.ConnectionGoAway => "HTTP connection is going away"
        case HttpErrorCode.ServerOverloaded => "HTTP server overloaded"
    }
}
