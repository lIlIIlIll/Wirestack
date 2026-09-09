package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.transport as transport

/** The public cancellation scope owned by one typed HTTP handle. */
public enum HttpCancellationScope <: Equatable<HttpCancellationScope> {
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Request
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Connection
/**
 * Wirestack 公开 API：表示一个可由调用方安全使用的 Wirestack 公开类型。
 */
    | Stream

/**
 * Wirestack 公开 API：比较两个值是否相等。
 * @param other 用于比较的另一个值。
 */
    public operator func ==(other: HttpCancellationScope): Bool {
        match ((this, other)) {
            case (HttpCancellationScope.Request, HttpCancellationScope.Request) => true
            case (HttpCancellationScope.Connection, HttpCancellationScope.Connection) => true
            case (HttpCancellationScope.Stream, HttpCancellationScope.Stream) => true
            case _ => false
        }
    }

/**
 * Wirestack 公开 API：比较两个值是否不同。
 * @param other 用于比较的另一个值。
 */
    public operator func !=(other: HttpCancellationScope): Bool { !(this == other) }
}

/** Cancels one public request from routing/DNS through response-body completion. */
public class HttpRequestCancellationHandle {
    private let state = HttpHandleCancellationState()
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Request } }
/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
 */
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
/**
 * Wirestack 公开 API：请求取消当前操作。
 */
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Cancels the concrete connection selected for every request sharing this handle. */
public class HttpConnectionCancellationHandle {
    private let state = HttpHandleCancellationState()
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Connection } }
/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
 */
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
/**
 * Wirestack 公开 API：请求取消当前操作。
 */
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Cancels one HTTP/2 stream without cancelling sibling streams. */
public class HttpStreamCancellationHandle {
    private let state = HttpHandleCancellationState()
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Stream } }
/**
 * Wirestack 公开 API：报告当前对象是否满足对应条件。
 */
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
/**
 * Wirestack 公开 API：请求取消当前操作。
 */
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Optional typed handles supplied to one controlled client request. */
public class HttpCancellationHandles {
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let request: ?HttpRequestCancellationHandle
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let connection: ?HttpConnectionCancellationHandle
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public let stream: ?HttpStreamCancellationHandle

/**
 * Wirestack 公开 API：构造并校验该公开值。
 * @param connection 调用方提供的输入值。
 * @param request 待处理的 HTTP 请求。
 * @param stream 提供连续数据的输入流。
 */
    public init(
        request!: ?HttpRequestCancellationHandle = None<HttpRequestCancellationHandle>,
        connection!: ?HttpConnectionCancellationHandle = None<HttpConnectionCancellationHandle>,
        stream!: ?HttpStreamCancellationHandle = None<HttpStreamCancellationHandle>
    ) {
        this.request = request
        this.connection = connection
        this.stream = stream
    }
}

private class HttpHandleCancellationState {
    private let cancelled = AtomicBool(false)
    private let source = transport.CancellationSource()

    prop token: transport.CancellationToken { get() { source.token } }
    prop isCancellationRequested: Bool { get() { cancelled.load() } }

    func cancel(): Bool {
        if (!cancelled.compareAndSwap(false, true)) { return false }
        source.cancel()
        true
    }
}

/**
 * Links caller context plus typed handles into one immutable request context.
 * Input registrations are removed on normal body completion, close, error, or
 * as soon as any linked source wins cancellation.
 */
internal class HttpRequestCancellationOperation <: ResponseBodyObserver {
    private let source = transport.CancellationSource()
    private let mutex = Mutex()
    private var registrations = ArrayList<transport.CancellationRegistration>()
    private var released = false
    internal let context: OperationContext
    internal let connectionCancellation: transport.CancellationToken

    internal init(
        parent: OperationContext,
        request: ?HttpRequestCancellationHandle,
        connection: ?HttpConnectionCancellationHandle,
        stream: ?HttpStreamCancellationHandle
    ) {
        context = parent.withCancellation(source.token)
        connectionCancellation = match (connection) {
            case Some(value) => value.cancellationToken
            case None => transport.CancellationToken.none()
        }
        link(parent.cancellation)
        match (request) { case Some(value) => link(value.cancellationToken); case None => () }
        match (connection) { case Some(value) => link(value.cancellationToken); case None => () }
        match (stream) { case Some(value) => link(value.cancellationToken); case None => () }
    }

    internal func wrap(response: HttpResponse): HttpResponse {
        if (response.body.isFullyConsumed()) { release(); return response }
        let delegate = response.body
        HttpResponse(
            response.status,
            response.reason,
            ResponseBody(
                HttpCancellationBodyStream(delegate),
                observer: this,
                trailerProvider: { => delegate.trailer },
                completeAtDeclaredLength: delegate.completesAtDeclaredLength
            ),
            version: response.version,
            headers: response.headers
        )
    }

    internal func wrapRequestBody(body: ResponseBody): ResponseBody {
        ResponseBody(
            HttpCancellationBodyStream(body, context: Some(context)),
            trailerProvider: { => body.trailer },
            completeAtDeclaredLength: body.completesAtDeclaredLength
        )
    }

    internal func fail(): Unit { release() }
    internal func retain(registration: transport.CancellationRegistration): Unit {
        let discard = synchronized(mutex) {
            if (released) { true } else { registrations.add(registration); false }
        }
        if (discard) { registration.unregister() }
    }
/**
 * Wirestack 公开 API：completed。
 */
    public func completed(): Unit { release() }
/**
 * Wirestack 公开 API：abandoned。
 */
    public func abandoned(): Unit { release() }

    private func link(token: transport.CancellationToken): Unit {
        let registration = token.register { => cancelAndRelease() }
        retain(registration)
    }

    private func cancelAndRelease(): Unit {
        source.cancel()
        release()
    }

    private func release(): Unit {
        let claimed = synchronized(mutex) {
            if (released) {
                ArrayList<transport.CancellationRegistration>()
            } else {
                released = true
                let result = registrations
                registrations = ArrayList<transport.CancellationRegistration>()
                result
            }
        }
        for (registration in claimed) { registration.unregister() }
    }
}

private class HttpCancellationBodyStream <: HttpBodyStream {
    private let delegate: ResponseBody
    private let context: ?OperationContext
    init(delegate: ResponseBody, context!: ?OperationContext = None<OperationContext>) {
        this.delegate = delegate
        this.context = context
    }
/**
 * Wirestack 公开 API：公开成员，用于在网络操作中传递受约束的状态。
 */
    public prop contentLength: ?Int64 { get() { delegate.contentLength } }
/**
 * Wirestack 公开 API：读取下一段数据并返回实际进度。
 * @param destination 调用方提供的输入值。
 */
    public func read(destination: Array<Byte>): Int64 {
        if (!destination.isEmpty()) {
            if (let Some(value) <- context) {
                if (value.isCancellationRequested()) {
                    throw transport.NetworkException(
                        transport.NetworkErrorCategory.Cancelled,
                        transport.NetworkPhase.HttpBody,
                        transport.NetworkErrorCode.Cancelled,
                        "HTTP request body cancelled",
                        retryability: transport.Retryability.Never
                    )
                }
                if (value.isDeadlineExceeded()) {
                    throw transport.NetworkException(
                        transport.NetworkErrorCategory.DeadlineExceeded,
                        transport.NetworkPhase.HttpBody,
                        transport.NetworkErrorCode.TimedOut,
                        "HTTP request body deadline exceeded",
                        retryability: transport.Retryability.Temporary
                    )
                }
            }
        }
        delegate.read(destination)
    }
/**
 * Wirestack 公开 API：关闭资源并唤醒正在等待的操作。
 */
    public func close(): Unit { delegate.close() }
/**
 * Wirestack 公开 API：报告资源是否已经关闭。
 */
    public func isClosed(): Bool { delegate.isClosed() }
}
