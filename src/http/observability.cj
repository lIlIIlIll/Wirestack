package wirestack.http

import std.collection.ArrayList
import wirestack as api
import wirestack.internal.http1 as http1
import wirestack.internal.http2 as http2

/** Separately sampled client counters. No cross-module atomicity is promised.
 * Resolver rows and resource owner rows are bounded diagnostic data, not metric labels.
 */
public struct HttpClientObservationSnapshot {
    /** Aggregate resource ledger sample. */
    public let resources: HttpResourceSnapshot
    /** Current and retained route pools, sampled outside the client lock. */
    public let pools: api.NetworkConnectionPoolSnapshot
    /** Bounded configuration retention counters. */
    public let configuration: HttpClientConfigurationSnapshot
    /** Distinct supported resolver owners, deduplicated by ownerId. */
    public let resolvers: Array<api.ResolverResourceSnapshot>
    /** Route resolver references whose counters are unavailable, never invented zero rows. */
    public let unavailableResolvers: Int64
    /** Caller-selected bounded observation queue sample, when supplied. */
    public let observations: ?api.NetworkEventBufferSnapshot
    internal init(resources: HttpResourceSnapshot, pools: api.NetworkConnectionPoolSnapshot,
        configuration: HttpClientConfigurationSnapshot, resolvers: Array<api.ResolverResourceSnapshot>,
        unavailableResolvers: Int64, observations: ?api.NetworkEventBufferSnapshot) {
        this.resources = resources; this.pools = pools; this.configuration = configuration
        this.resolvers = resolvers; this.unavailableResolvers = unavailableResolvers; this.observations = observations
    }
}

/** Server-local samples. Ledger, TLS generation and adapter samples are not atomic together. */
public struct HttpServerObservationSnapshot {
    /** Real aggregate connection, stream, request and buffer counters. */
    public let resources: HttpResourceSnapshot
    /** Last published TLS generation, zero for cleartext. */
    public let tlsGeneration: UInt64
    /** Current and referenced old TLS generations, bounded by 64. */
    public let retainedTlsGenerations: Int64
    /** Accepted connections that actually began drainage. */
    public let drainingConnections: Int64
    /** Caller-selected observation queue sample. */
    public let observations: ?api.NetworkEventBufferSnapshot
    internal init(resources: HttpResourceSnapshot, tlsGeneration: UInt64, retainedTlsGenerations: Int64,
        drainingConnections: Int64, observations: ?api.NetworkEventBufferSnapshot) {
        this.resources = resources; this.tlsGeneration = tlsGeneration
        this.retainedTlsGenerations = retainedTlsGenerations; this.drainingConnections = drainingConnections
        this.observations = observations
    }
}

internal func observedRequestContext(context: OperationContext, hook: Bool): OperationContext {
    if ((!hook && context.eventSink.isNone()) || context.requestId.isSome()) { return context }
    context.withEventCorrelation(requestId: Some(api.nextNetworkCorrelationId()), attemptId: context.attemptId,
        connectionId: context.connectionId, streamId: context.streamId)
}
internal func observedAttemptContext(context: OperationContext): OperationContext {
    if (context.eventSink.isNone()) { return context }
    context.withEventCorrelation(requestId: context.requestId, attemptId: Some(api.nextNetworkCorrelationId()),
        connectionId: context.connectionId, streamId: context.streamId)
}
internal func emitHttpObservation(context: OperationContext, kind: NetworkEventKind, outcome: NetworkEventOutcome): Unit {
    if (context.eventSink.isSome()) { api.emitNetworkEvent(context, NetworkEvent(kind, outcome)) }
}
internal func emitHttpFailure(context: OperationContext, kind: NetworkEventKind, error: Exception): Unit {
    if (context.eventSink.isNone()) { return }
    match (httpObservationFailureCause(error)) {
        case Some(value) =>
            api.emitNetworkEvent(context, NetworkEvent(kind, NetworkEventOutcome.Failed,
                phase: Some(value[0]), errorCode: Some(value[1])))
        case None => emitHttpObservation(context, kind, NetworkEventOutcome.Failed)
    }
}
/** Walks the typed cause chain so terminal request events keep a stable phase and code.
 * Free-form messages are never inspected; only declared exception types are mapped.
 */
private func httpObservationFailureCause(error: Exception): ?(NetworkPhase, NetworkErrorCode) {
    var current = error
    for (_ in 0..16) {
        match (current) {
            case value: NetworkException => return Some((value.phase, value.code))
            case value: HttpException => match (value.cause) {
                case Some(cause) => current = cause
                case None => return None<(NetworkPhase, NetworkErrorCode)>
            }
            case value: http1.Http1RequestWriteException => match (value.cause) {
                case Some(cause) => current = cause
                case None => return Some((NetworkPhase.TcpWrite, NetworkErrorCode.InvalidState))
            }
            case value: http2.Http2ProtocolException => return Some((
                match (value.scope) {
                    case http2.Http2ErrorScope.Stream(_) => NetworkPhase.HttpBody
                    case http2.Http2ErrorScope.Connection => NetworkPhase.HttpHeaders
                },
                match (value.code) {
                    case http2.Http2ErrorCode.Cancel => NetworkErrorCode.Cancelled
                    case _ => NetworkErrorCode.InvalidState
                }))
            case _: http2.Http2GoAwayException => return Some((NetworkPhase.HttpHeaders, NetworkErrorCode.InvalidState))
            case _ => return None<(NetworkPhase, NetworkErrorCode)>
        }
    }
    None<(NetworkPhase, NetworkErrorCode)>
}
internal func sampleHttpPool(value: Resource): api.NetworkConnectionPoolSnapshot {
    match (value) {
        case client: http1.Http1CleartextClient => client.observationSnapshot()
        case client: http1.Http1ForwardProxyClient => client.observationSnapshot()
        case client: http1.HttpAutomaticHttpsClient => client.observationSnapshot()
        case client: http1.Http1HttpsProxyClient => client.observationSnapshot()
        case _ => throw IllegalStateException("unknown HTTP route pool")
    }
}
/** A closed route may still own a transferred duplex session until its transport closes. */
internal func httpPoolRetainsEntries(value: api.NetworkConnectionPoolSnapshot): Bool {
    value.leasedConnections > 0 || value.idleConnections > 0 || value.connectingConnections > 0 ||
        value.queuedRequests > 0 || value.activeStreams > 0 || value.reservedStreams > 0 ||
        value.drainingConnections > 0
}
internal func sampleHttpResolvers(values: Array<Resolver>): (Array<api.ResolverResourceSnapshot>, Int64) {
    let rows = ArrayList<api.ResolverResourceSnapshot>()
    var unavailable: Int64 = 0
    for (value in values) {
        match (value) {
            case owner: api.ResolverResourceOwner =>
                // A closed owner still publishes its immutable final sample. That row is
                // real data, so only owners without counters are unavailable.
                let row = owner.resolverResourceSnapshot()
                var found = false
                for (existing in rows) { if (existing.ownerId == row.ownerId) { found = true; break } }
                if (!found) { rows.add(row) }
            case _ => unavailable++
        }
    }
    (rows.toArray(), unavailable)
}
internal func sampleHttpObservations(value: ?api.NetworkEventStatistics): ?api.NetworkEventBufferSnapshot {
    match (value) { case Some(statistics) => Some(statistics.snapshot()); case None => None<api.NetworkEventBufferSnapshot> }
}
