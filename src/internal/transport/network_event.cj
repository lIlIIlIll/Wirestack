package wirestack.internal.transport

import wirestack as api

public type NetworkEventKind = api.NetworkEventKind
public type NetworkEventOutcome = api.NetworkEventOutcome
public type NetworkEvent = api.NetworkEvent
public type NetworkEventSink = api.NetworkEventSink

public func emitNetworkEvent(context: OperationContext, event: NetworkEvent): Unit {
    api.emitNetworkEvent(context, event)
}
