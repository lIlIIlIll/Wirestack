package wirestack.internal.transport_stdnet

import wirestack as api

/**
 * Stream adapter contract with immutable ownership of the first native close.
 */
public interface SocketTransport <: api.DuplexTransport {
    /** True only when an abort won the first native close. */
    func wasClosedByAbort(): Bool
}

/** Returns the full cached local endpoint without widening DuplexTransport. */
public func socketLocalNetworkEndpoint(
    transport: SocketTransport
): ?api.NetworkEndpoint {
    match (transport as StdNetTransport) {
        case Some(value) => value.localNetworkEndpoint
        case None =>
            match (transport.info.localEndpoint) {
                case Some(endpoint) => Some(api.NetworkEndpoint.Internet(endpoint))
                case None => None<api.NetworkEndpoint>
            }
    }
}

/** Returns the full cached peer endpoint without widening DuplexTransport. */
public func socketRemoteNetworkEndpoint(
    transport: SocketTransport
): ?api.NetworkEndpoint {
    match (transport as StdNetTransport) {
        case Some(value) => value.remoteNetworkEndpoint
        case None =>
            match (transport.info.remoteEndpoint) {
                case Some(endpoint) => Some(api.NetworkEndpoint.Internet(endpoint))
                case None => None<api.NetworkEndpoint>
            }
    }
}
