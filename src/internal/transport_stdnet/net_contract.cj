package wirestack.internal.transport_stdnet

import wirestack as api

/**
 * Stream adapter contract with immutable ownership of the first native close.
 */
public interface SocketTransport <: api.DuplexTransport {
    /** True only when an abort won the first native close. */
    func wasClosedByAbort(): Bool
}
