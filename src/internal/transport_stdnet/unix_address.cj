package wirestack.internal.transport_stdnet

import std.net as native
import wirestack as api

/** Encodes a named Linux Unix endpoint using the public SDK address API. */
internal func toStdUnixEndpoint(endpoint: api.UnixEndpoint, local!: Bool = false): native.UnixSocketAddress {
    let name = endpoint.nameBytes()
    let localEndpoint = if (local) { Some(api.NetworkEndpoint.Unix(endpoint)) } else { None<api.NetworkEndpoint> }
    let remoteEndpoint = if (local) { None<api.NetworkEndpoint> } else { Some(api.NetworkEndpoint.Unix(endpoint)) }
    match (endpoint.kind) {
        case api.UnixEndpointKind.Unnamed =>
            throw api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
                api.NetworkErrorCode.InvalidState, "unnamed Unix endpoint cannot be bound or used as a destination",
                retryability: api.Retryability.Never, localEndpoint: localEndpoint, remoteEndpoint: remoteEndpoint)
        case api.UnixEndpointKind.Pathname => native.UnixSocketAddress(name)
        case api.UnixEndpointKind.Abstract =>
            // The SDK both stringifies the name and passes sizeof(sockaddr_un)
            // instead of its actual length. Short names would silently gain
            // significant trailing NUL bytes. Reject rather than rename them.
            if (name.size != 107 || !String.checkUtf8Encoding(name)) {
                throw api.NetworkException(api.NetworkErrorCategory.Unsupported, api.NetworkPhase.UnixSocket,
                    api.NetworkErrorCode.Unsupported, "std.net requires exactly 107 UTF-8 bytes to preserve an abstract Unix name",
                    retryability: api.Retryability.Never, localEndpoint: localEndpoint, remoteEndpoint: remoteEndpoint)
            }
            native.UnixSocketAddress(Array<Byte>(name.size + 1, { index =>
                if (index == 0) { 0 } else { name[index - 1] }
            }))
    }
}

/** Decodes the documented Linux sockaddr_un bytes without stringifying abstract names. */
internal func fromStdUnixEndpoint(address: native.SocketAddress): api.UnixEndpoint {
    match (address) {
        case unix: native.UnixSocketAddress =>
            let bytes = unix.getAddressBytes()
            let size = unix.size
            // Linux sockaddr_un starts with a two-byte sa_family_t. Its
            // reported length, not its zero-filled capacity, owns the name.
            if (size < 2 || size > bytes.size || size > 110) {
                throw unsupportedUnixAddress()
            }
            if (size == 2) { return api.UnixEndpoint.unnamed() }
            if (bytes[2] == 0) {
                if (size == 3) { throw unsupportedUnixAddress() }
                return api.UnixEndpoint.abstractName(Array<Byte>(size - 3, { index => bytes[index + 3] }))
            }
            let end = if (bytes[size - 1] == 0) { size - 1 } else { size }
            if (end <= 2 || end - 2 > 107) { throw unsupportedUnixAddress() }
            let name = Array<Byte>(end - 2, { index => bytes[index + 2] })
            if (!String.checkUtf8Encoding(name)) { throw unsupportedUnixAddress() }
            for (byte in name) {
                if (byte == 0) { throw unsupportedUnixAddress() }
            }
            api.UnixEndpoint.pathname(String.fromUtf8(name))
        case _ => throw unsupportedUnixAddress()
    }
}

private func unsupportedUnixAddress(): api.NetworkException {
    api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
        api.NetworkErrorCode.Unsupported, "native Unix address cannot be represented by the endpoint contract",
        retryability: api.Retryability.Never)
}
