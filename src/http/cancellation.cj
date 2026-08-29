package wirestack.http

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.transport as transport

/** The public cancellation scope owned by one typed HTTP handle. */
public enum HttpCancellationScope <: Equatable<HttpCancellationScope> {
    | Request
    | Connection
    | Stream

    public operator func ==(other: HttpCancellationScope): Bool {
        match ((this, other)) {
            case (HttpCancellationScope.Request, HttpCancellationScope.Request) => true
            case (HttpCancellationScope.Connection, HttpCancellationScope.Connection) => true
            case (HttpCancellationScope.Stream, HttpCancellationScope.Stream) => true
            case _ => false
        }
    }

    public operator func !=(other: HttpCancellationScope): Bool { !(this == other) }
}

/** Cancels one public request from routing/DNS through response-body completion. */
public class HttpRequestCancellationHandle {
    private let state = HttpHandleCancellationState()
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Request } }
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Cancels the concrete connection selected for every request sharing this handle. */
public class HttpConnectionCancellationHandle {
    private let state = HttpHandleCancellationState()
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Connection } }
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Cancels one HTTP/2 stream without cancelling sibling streams. */
public class HttpStreamCancellationHandle {
    private let state = HttpHandleCancellationState()
    public prop scope: HttpCancellationScope { get() { HttpCancellationScope.Stream } }
    public prop isCancellationRequested: Bool { get() { state.isCancellationRequested } }
    public func cancel(): Bool { state.cancel() }
    internal prop cancellationToken: transport.CancellationToken { get() { state.token } }
}

/** Optional typed handles supplied to one controlled client request. */
public class HttpCancellationHandles {
    public let request: ?HttpRequestCancellationHandle
    public let connection: ?HttpConnectionCancellationHandle
    public let stream: ?HttpStreamCancellationHandle

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
    public func completed(): Unit { release() }
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
    public prop contentLength: ?Int64 { get() { delegate.contentLength } }
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
    public func close(): Unit { delegate.close() }
    public func isClosed(): Bool { delegate.isClosed() }
}
