package wirestack.internal.http2

import wirestack.internal.transport.*
import wirestack as api

internal func http2ServerStreamEventContext(context: OperationContext, streamId: Http2StreamId): OperationContext {
    if (context.eventSink.isNone()) { return context }
    let requestId = match (context.requestId) { case Some(value) => value; case None => api.nextNetworkCorrelationId() }
    let attemptId = match (context.attemptId) { case Some(value) => value; case None => api.nextNetworkCorrelationId() }
    context.withEventCorrelation(requestId: Some(requestId), attemptId: Some(attemptId),
        connectionId: context.connectionId, streamId: Some(Int64(streamId.value)))
}

/** Attributes events to a stage without adding that stage's timeout owner.
 * The returned context keeps the parent absolute deadline, cancellation and policy.
 */
internal func http2StageObservationContext(context: OperationContext,
    stage: OperationTimeoutStage): OperationContext {
    if (context.eventSink.isNone()) { return context }
    OperationContext(deadline: context.deadline, cancellation: context.cancellation,
        trace: context.trace, eventSink: context.eventSink, timeoutPolicy: context.timeoutPolicy,
        requestId: context.requestId, attemptId: context.attemptId,
        connectionId: context.connectionId, streamId: context.streamId,
        stage: Some(stage), deadlineStage: context.deadlineStage)
}

internal func http2StreamEventContext(context: OperationContext, streamId: Http2StreamId): OperationContext {
    if (context.eventSink.isNone()) { return context }
    context.withEventCorrelation(requestId: context.requestId, attemptId: context.attemptId,
        connectionId: context.connectionId, streamId: Some(Int64(streamId.value)))
}

internal func http2Observe(context: OperationContext, kind: NetworkEventKind,
    outcome: NetworkEventOutcome, error!: ?Exception = None<Exception>): Unit {
    if (context.eventSink.isNone()) { return }
    let code = match (error) {
        case Some(value) => match (value) {
            case network: NetworkException => Some(network.code)
            case _ => Some(NetworkErrorCode.InvalidState)
        }
        case None => None<NetworkErrorCode>
    }
    emitNetworkEvent(context, NetworkEvent(kind, outcome, errorCode: code))
}

internal func http2ObservedStage<T>(context: OperationContext, action: () -> T): T {
    if (context.eventSink.isNone()) { return action() }
    http2Observe(context, NetworkEventKind.StageStarted, NetworkEventOutcome.Started)
    try {
        let result = action()
        http2Observe(context, NetworkEventKind.StageCompleted, NetworkEventOutcome.Succeeded)
        result
    } catch (error: Exception) {
        http2Observe(context, NetworkEventKind.StageCompleted, NetworkEventOutcome.Failed, error: Some(error))
        throw error
    }
}
