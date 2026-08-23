package wirestack.internal.http1

import std.sync.Mutex
import wirestack.internal.http_model.*
import wirestack.internal.transport.*

public enum Http1ClientConnectionState {
    | Ready
    | Exchanging
    | AwaitingBody
    | Closed
    | Failed
}

public class Http1ClientConnectionException <: Exception {
    public let state: Http1ClientConnectionState

    public init(state: Http1ClientConnectionState, message: String) {
        super(message)
        this.state = state
    }

    protected override func getClassName(): String { "Http1ClientConnectionException" }
}

/** One non-pipelined HTTP/1.1 client connection. Body completion alone permits reuse. */
public class Http1ClientConnection <: Resource {
    private let transport: DuplexTransport
    private let limits: HttpLimits
    private let continueTimeout: Duration
    private let mutex = Mutex()
    private var state = Http1ClientConnectionState.Ready

    public init(
        transport: DuplexTransport,
        limits!: HttpLimits = HttpLimits(),
        continueTimeout!: Duration = Duration.second
    ) {
        if (continueTimeout <= Duration.Zero) {
            throw IllegalArgumentException("HTTP/1 continue timeout must be positive")
        }
        this.transport = transport
        this.limits = limits
        this.continueTimeout = continueTimeout
    }

    public func execute(
        request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer()
    ): Http1ResponseReadResult {
        executeTracked(request, context: context, trailer: trailer, onTerminated: { _ => })
    }

    internal func executeTracked(
        request: HttpRequest,
        context!: OperationContext = OperationContext.background(),
        trailer!: HttpTrailer = HttpTrailer(),
        onTerminated!: (Bool) -> Unit = { _ => }
    ): Http1ResponseReadResult {
        synchronized(mutex) {
            match (state) {
                case Http1ClientConnectionState.Ready => state = Http1ClientConnectionState.Exchanging
                case _ => throw Http1ClientConnectionException(
                    state,
                    "HTTP/1 connection cannot start another request before the active response body terminates"
                )
            }
        }
        let observer = Http1ConnectionBodyObserver(this, onTerminated)
        try {
            let expectsContinue = headerContainsToken(request.headers, "expect", "100-continue") &&
                request.body.contentLength != Some(0)
            let result = if (expectsContinue) {
                exchangeHttp1ExpectContinue(
                    transport, request, Http1RequestWriter(request, limits: limits, trailer: trailer),
                    continueTimeout, context: context, limits: limits, observer: observer
                )
            } else {
                let _ = writeHttp1Request(transport, request, context: context, limits: limits, trailer: trailer)
                readHttp1Response(
                    transport, request.method,
                    context: context, limits: limits, observer: observer
                )
            }
            let reusable = result.reusableCandidate &&
                !headerContainsToken(request.headers, "connection", "close")
            observer.configure(reusable)
            let accepted = synchronized(mutex) {
                match (state) {
                    case Http1ClientConnectionState.Exchanging =>
                        state = Http1ClientConnectionState.AwaitingBody
                        true
                    case _ => false
                }
            }
            if (!accepted) {
                result.response.close()
                throw Http1ClientConnectionException(
                    currentState(), "HTTP/1 connection closed during response setup"
                )
            }
            if (result.response.body.contentLength == Some(0)) {
                let _ = result.response.body.read(Array<Byte>(1, repeat: 0))
            }
            result
        } catch (error: Exception) {
            failConnection()
            throw error
        }
    }

    public func currentState(): Http1ClientConnectionState { synchronized(mutex) { state } }

    public func close(): Unit {
        let shouldClose = synchronized(mutex) {
            match (state) {
                case Http1ClientConnectionState.Closed => false
                case _ => state = Http1ClientConnectionState.Closed; true
            }
        }
        if (shouldClose) { transport.close(OperationContext.background()) }
    }

    public func isClosed(): Bool {
        synchronized(mutex) {
            match (state) {
                case Http1ClientConnectionState.Closed | Http1ClientConnectionState.Failed => true
                case _ => false
            }
        }
    }

    internal func bodyTerminated(reusable: Bool, abandoned: Bool): Unit {
        let closeTransport = synchronized(mutex) {
            match (state) {
                case Http1ClientConnectionState.AwaitingBody =>
                    if (reusable) { state = Http1ClientConnectionState.Ready; false }
                    else { state = Http1ClientConnectionState.Closed; true }
                case _ => false
            }
        }
        if (closeTransport) {
            try {
                if (abandoned) { transport.abort(reason: Some(AbortReason.ApplicationAbort)) }
                else { transport.close(OperationContext.background()) }
            } catch (_: Exception) {}
        }
    }

    private func failConnection(): Unit {
        let shouldAbort = synchronized(mutex) {
            match (state) {
                case Http1ClientConnectionState.Closed | Http1ClientConnectionState.Failed => false
                case _ => state = Http1ClientConnectionState.Failed; true
            }
        }
        if (shouldAbort) {
            try { transport.abort(reason: Some(AbortReason.ProtocolFailure)) } catch (_: Exception) {}
        }
    }
}

private class Http1ConnectionBodyObserver <: ResponseBodyObserver {
    private let connection: Http1ClientConnection
    private let onTerminated: (Bool) -> Unit
    private let mutex = Mutex()
    private var configured = false
    private var reusable = false

    init(connection: Http1ClientConnection, onTerminated: (Bool) -> Unit) {
        this.connection = connection
        this.onTerminated = onTerminated
    }

    func configure(reusable: Bool): Unit {
        synchronized(mutex) {
            if (configured) { throw Exception("HTTP/1 body observer configured twice") }
            this.reusable = reusable
            configured = true
        }
    }

    public func completed(): Unit {
        let canReuse = synchronized(mutex) { configured && reusable }
        connection.bodyTerminated(canReuse, false)
        onTerminated(canReuse)
    }

    public func abandoned(): Unit {
        connection.bodyTerminated(false, true)
        onTerminated(false)
    }
}
