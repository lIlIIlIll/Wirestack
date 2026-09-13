package wirestack.http

import wirestack as api

/** DNS-free connection hook. The client owns returned transports, not the supplied factory. */
public type HttpConnector = api.TransportFactory

/**
 * Non-blocking pool observations using the existing secret-safe network event contract.
 * Callbacks run outside pool locks. Their exceptions cannot alter connection ownership or I/O.
 * Connection identifiers are local to a pool; trace metadata identifies the operation.
 */
public interface HttpConnectionPoolHook {
    /**
     * Observes acquisition success, reuse, or failure; failed acquisitions have no connection identifier.
     * @param event Actual pool acquisition event.
     * @param context Original operation cancellation, absolute deadline, trace, and event sink.
     */
    func acquired(event: NetworkEvent, context: OperationContext): Unit

    /**
     * Observes an actual lease release or discard, never an inferred response-header completion.
     * @param event Actual pool release event and reuse outcome.
     * @param context Original operation cancellation, absolute deadline, trace, and event sink.
     */
    func released(event: NetworkEvent, context: OperationContext): Unit
}

/** Synchronous service interception. Exceptions use the server's normal handler-failure path. */
public interface HttpServiceHook {
    /**
     * Runs before the handler without a server or connection state lock.
     * @param request Incoming request; this hook does not acquire its body ownership.
     * @param context Shared request cancellation, absolute deadline, trace, and event sink.
     */
    func before(request: HttpServerRequest, context: OperationContext): Unit

    /**
     * Runs after a handler returns and before response commitment. A failure closes that response.
     * @param response Handler-owned response awaiting commitment.
     * @param context Shared request cancellation, absolute deadline, trace, and event sink.
     */
    func after(response: HttpServerResponse, context: OperationContext): Unit
}

internal func withHttpPoolHook(
    context: OperationContext,
    hook: ?HttpConnectionPoolHook
): OperationContext {
    match (hook) {
        case Some(value) => context.withEventSink(Some<NetworkEventSink>(HttpPoolHookSink(context, value)))
        case None => context
    }
}

private class HttpPoolHookSink <: NetworkEventSink {
    private let context: OperationContext
    private let hook: HttpConnectionPoolHook

    init(context: OperationContext, hook: HttpConnectionPoolHook) {
        this.context = context
        this.hook = hook
    }

    /**
     * Forwards the event to the original sink, then dispatches acquisition or release observations.
     * The event boundary suppresses exceptions from either callback so they cannot alter pool I/O or ownership.
     * @param event Actual network event emitted by the pool.
     */
    public func emit(event: NetworkEvent): Unit {
        // Forward through the existing isolation boundary, so a failing original sink cannot
        // suppress a pool observation. The outer dispatch isolates hook exceptions as well.
        api.emitNetworkEvent(context, event)
        match (event.kind) {
            case NetworkEventKind.HttpConnectionAcquired => hook.acquired(event, context)
            case NetworkEventKind.HttpConnectionReleased => hook.released(event, context)
            case _ => ()
        }
    }
}

internal class ServiceHookHandler <: HttpServerHandler {
    private let delegate: HttpServerHandler
    private let hook: HttpServiceHook

    init(delegate: HttpServerHandler, hook: HttpServiceHook) {
        this.delegate = delegate
        this.hook = hook
    }

    /**
     * Runs the before hook, delegate, and after hook in order.
     * A before or delegate exception follows normal handler failure. An after exception closes the produced
     * response, suppresses any close exception, and rethrows the callback exception.
     * @param request Incoming request retained under the server's existing ownership.
     * @param context Request cancellation, absolute deadline, trace, and event sink.
     */
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        hook.before(request, context)
        let response = delegate.handle(request, context)
        try {
            hook.after(response, context)
            response
        } catch (error: Exception) {
            try { response.response.close() } catch (_: Exception) {}
            throw error
        }
    }
}
