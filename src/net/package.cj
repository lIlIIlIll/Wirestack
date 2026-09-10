package wirestack.net

import wirestack as api
import wirestack.internal.transport_stdnet as stdnet

/** The endpoint kinds understood by the network package. */
public enum NetworkEndpointKind {
/** Internet endpoint. */
    | Internet
/** Unix-domain endpoint. */
    | Unix
}

/** An Internet or Unix endpoint. Endpoint construction never performs DNS. */
public enum NetworkEndpoint {
/** Internet socket endpoint. */
    | Internet(api.SocketEndpoint)
/** Unix-domain socket endpoint. */
    | Unix(UnixEndpoint)
}

/** Unix endpoint address forms. Abstract names retain arbitrary bytes. */
public enum UnixEndpointKind {
/** Filesystem pathname form. */
    | Pathname
/** Linux abstract byte-name form. */
    | Abstract
/** Unnamed socket form. */
    | Unnamed
}


/** Immutable Unix endpoint value. */
public struct UnixEndpoint {
    private let value: Array<Byte>
/** Endpoint address form. */
    public let kind: UnixEndpointKind

    private init(kind: UnixEndpointKind, value: Array<Byte>) {
        if (value.size > 107) {
            throw IllegalArgumentException("Unix endpoint name must not exceed 107 bytes")
        }
        match (kind) {
            case UnixEndpointKind.Pathname | UnixEndpointKind.Abstract =>
                if (value.isEmpty()) { throw IllegalArgumentException("named Unix endpoint must not be empty") }
            case UnixEndpointKind.Unnamed => ()
        }
        this.kind = kind
        this.value = value.clone()
    }

    /** Creates a filesystem pathname endpoint.
     * @param path Filesystem pathname.
     */
    public static func pathname(path: String): UnixEndpoint {
        UnixEndpoint(UnixEndpointKind.Pathname, path.toArray())
    }

    /** Creates a Linux abstract endpoint without UTF-8 conversion.
     * @param name Arbitrary abstract-name bytes.
     */
    public static func abstractName(name: Array<Byte>): UnixEndpoint {
        UnixEndpoint(UnixEndpointKind.Abstract, name)
    }

    /** Creates an unnamed endpoint used for automatically allocated clients. */
    public static func unnamed(): UnixEndpoint {
        UnixEndpoint(UnixEndpointKind.Unnamed, Array<Byte>())
    }

    /** Returns a defensive copy of the pathname or abstract name bytes. */
    public func nameBytes(): Array<Byte> { value.clone() }
}

/** Socket lifecycle states observable through Wirestack-owned types. */
public enum SocketState {
/** Socket object has been created. */
    | Created
/** Connect is in progress. */
    | Connecting
/** Listener is accepting connections. */
    | Listening
/** Socket is open. */
    | Open
/** Close has started. */
    | Closing
/** Socket is closed. */
    | Closed
}

/** Advisory capabilities. The operation remains authoritative. */
public struct SocketCapabilities {
/** Whether the descriptor is non-blocking. */
    public let nonBlocking: Bool
/** Whether the descriptor is close-on-exec. */
    public let closeOnExec: Bool
/** Whether directional half-close is available. */
    public let halfClose: Bool
/** Whether broadcast is available. */
    public let broadcast: Bool
/** Whether multicast is available. */
    public let multicast: Bool
/** Whether raw socket operations are available. */
    public let raw: Bool
/** Whether ancillary data is available. */
    public let ancillaryData: Bool

    /** Creates an advisory capability value.
     *
     * @param ancillaryData Ancillary-data capability.
     * @param broadcast Broadcast capability.
     * @param closeOnExec Close-on-exec capability.
     * @param halfClose Half-close capability.
     * @param multicast Multicast capability.
     * @param nonBlocking Non-blocking capability.
     * @param raw Raw-socket capability.
     */
    public init(
        nonBlocking!: Bool = true,
        closeOnExec!: Bool = true,
        halfClose!: Bool = false,
        broadcast!: Bool = true,
        multicast!: Bool = true,
        raw!: Bool = false,
        ancillaryData!: Bool = false
    ) {
        this.nonBlocking = nonBlocking
        this.closeOnExec = closeOnExec
        this.halfClose = halfClose
        this.broadcast = broadcast
        this.multicast = multicast
        this.raw = raw
        this.ancillaryData = ancillaryData
    }
}

/** Typed socket-option values. M8-001 does not expose an option application operation. */
public enum SocketOption {
/** Enables address reuse. */
    | ReuseAddress(Bool)
/** Enables port reuse. */
    | ReusePort(Bool)
/** Enables TCP no-delay. */
    | NoDelay(Bool)
/** Enables keep-alive probes. */
    | KeepAlive(Bool)
/** Enables datagram broadcast. */
    | Broadcast(Bool)
/** Requests a receive buffer size. */
    | ReceiveBuffer(Int64)
/** Requests a send buffer size. */
    | SendBuffer(Int64)
/** Sets the multicast TTL. */
    | MulticastTtl(UInt8)
}

/** A bounded opaque option value for a future capability adapter. Constructing it does not apply it. */
public struct UnsafeSocketOption {
/** Native option level number. */
    public let level: Int32
/** Native option number. */
    public let option: Int32
    private let bytes: Array<Byte>

    /** Creates a bounded opaque option payload.
     *
     * @param level Native option level number.
     * @param option Native option number.
     * @param value Option payload bytes.
     */
    public init(level: Int32, option: Int32, value: api.ByteSpan) {
        if (level < 0 || option < 0 || value.length > 4096) {
            throw IllegalArgumentException("unsafe socket option is outside the bounded range")
        }
        let copy = Array<Byte>(value.length, repeat: 0)
        for (index in 0..value.length) { copy[index] = value.bytes[value.offset + index] }
        this.level = level
        this.option = option
        this.bytes = copy
    }

    /** Returns a defensive copy of the option payload. */
    public func value(): Array<Byte> { bytes.clone() }
}

/** A datagram result that preserves message boundaries and reports truncation. */
public struct DatagramReceiveResult {
/** Received datagram bytes. */
    public let payload: Array<Byte>
/** Source endpoint when one is available. */
    public let source: ?NetworkEndpoint
/** Whether the incoming datagram exceeded the receive capacity. */
    public let truncated: Bool

    /** Creates an owned result, including valid zero-length datagrams.
     *
     * @param payload Received bytes, bounded to 65,507 bytes.
     * @param source Source endpoint, or none when unavailable.
     * @param truncated Whether the datagram exceeded the receive capacity.
     */
    public init(payload: Array<Byte>, source: ?NetworkEndpoint, truncated: Bool) {
        if (payload.size > 65507) {
            throw IllegalArgumentException("datagram payload exceeds the IPv4 payload bound")
        }
        this.payload = payload.clone()
        this.source = source
        this.truncated = truncated
    }
}

/**
 * Synchronous datagram operations shared by Internet and Unix adapters.
 *
 * One send and one receive may proceed concurrently; overlapping operations
 * in the same direction fail rather than creating an unbounded queue.
 * Each operation completes at most once under the supplied absolute context.
 * Local close, abort, cancellation and deadline retain distinct error causes.
 * Native bind factories and adapter qualification belong to M8-002/M8-003.
 */
public interface DatagramSocket <: Resource {
    /** Current lifecycle state. */
    prop state: SocketState
    /** Advisory capabilities; an operation remains authoritative. */
    prop capabilities: SocketCapabilities
    /** Local endpoint when known. */
    prop localEndpoint: ?NetworkEndpoint
    /** Selected peer endpoint when connected. */
    prop remoteEndpoint: ?NetworkEndpoint

    /** Selects a resolved peer without DNS or a new timeout owner.
     *
     * @param endpoint Peer of the adapter's supported endpoint kind.
     * @param context Shared absolute deadline and cancellation token.
     */
    func connect(endpoint: NetworkEndpoint, context!: api.OperationContext): Unit

    /** Sends one complete datagram to the selected peer.
     *
     * Success returns exactly `source.length`, including zero for an empty
     * datagram. Missing peers and payloads above 65,507 bytes fail before I/O;
     * a partial send is an error, never successful stream-like progress.
     *
     * @param source Datagram payload retained only for this operation.
     * @param context Shared absolute deadline and cancellation token.
     */
    func send(source: api.ByteSpan, context!: api.OperationContext): Int64

    /** Sends one complete datagram without changing the selected peer.
     *
     * The same payload bound and atomic-send rules apply as for `send`.
     * Endpoint kinds unsupported by the adapter fail explicitly.
     *
     * @param endpoint Resolved destination endpoint.
     * @param source Datagram payload retained only for this operation.
     * @param context Shared absolute deadline and cancellation token.
     */
    func sendTo(endpoint: NetworkEndpoint, source: api.ByteSpan,
        context!: api.OperationContext): Int64

    /** Consumes exactly one datagram into an owned bounded result.
     *
     * Excess bytes are discarded and `truncated` is true. An empty payload is
     * a datagram, not stream EOF. Invalid capacity fails before receiving.
     *
     * @param capacity Maximum retained payload size, from 1 through 65,507.
     * @param context Shared absolute deadline and cancellation token.
     */
    func receive(capacity: Int64,
        context!: api.OperationContext): DatagramReceiveResult

    /** Closes idempotently and wakes pending operations.
     * @param context Shared context for any completion wait.
     */
    func close(context!: api.OperationContext): Unit

    /** Aborts idempotently without waiting and wakes pending operations.
     * @param reason Optional local abort reason.
     */
    func abort(reason!: ?api.AbortReason): Unit
}

/** A synchronous stream socket contract. */
public interface StreamSocket <: Resource {
    /** Current lifecycle state. */
    prop state: SocketState
    /** Advisory socket capabilities. */
    prop capabilities: SocketCapabilities
    /** Local endpoint when known. */
    prop localEndpoint: ?NetworkEndpoint
    /** Remote endpoint when known. */
    prop remoteEndpoint: ?NetworkEndpoint
    /** Reads at most the destination capacity and may return partial data.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    func read(destination: api.MutableByteSpan, context!: api.OperationContext): ReadResult
    /** Writes at most one bounded chunk and may return partial progress.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    func write(source: api.ByteSpan, context!: api.OperationContext): Int64
    /** Fills the destination or raises a terminal error.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    func readExact(destination: api.MutableByteSpan, context!: api.OperationContext): Unit
    /** Writes the complete source or raises a terminal error.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    func writeAll(source: api.ByteSpan, context!: api.OperationContext): Unit
    /** Requests a directional shutdown.
     * @param direction Direction to shut down.
     */
    func shutdown(direction: api.ShutdownDirection): Unit
    /** Closes the socket idempotently.
     * @param context Shared operation context.
     */
    func close(context!: api.OperationContext): Unit
    /** Aborts the socket idempotently.
     * @param reason Optional abort reason.
     */
    func abort(reason!: ?api.AbortReason): Unit
}

/** Partial-progress result for stream reads. */
public enum ReadResult {
/** A data read with its byte count. */
    | Data(Int64)
/** Peer reached EOF. */
    | EndOfStream
}

/** TCP stream backed by the provider-neutral Transport SPI. */
public class TcpStream <: StreamSocket & api.DuplexTransport {
    private let delegate: api.DuplexTransport
    private let connectionInfo: api.TransportInfo
    private let localEndpointValue: ?NetworkEndpoint
    private let remoteEndpointValue: ?NetworkEndpoint
    private let capabilityValue: SocketCapabilities

    internal init(delegate: api.DuplexTransport) {
        let info = delegate.info
        this.delegate = delegate
        this.connectionInfo = info
        this.localEndpointValue = match (info.localEndpoint) {
            case Some(value) => Some(NetworkEndpoint.Internet(value))
            case None => None<NetworkEndpoint>
        }
        this.remoteEndpointValue = match (info.remoteEndpoint) {
            case Some(value) => Some(NetworkEndpoint.Internet(value))
            case None => None<NetworkEndpoint>
        }
        this.capabilityValue = SocketCapabilities(
            nonBlocking: false,
            closeOnExec: false,
            halfClose: info.supportsHalfClose,
            broadcast: false,
            multicast: false,
            raw: false,
            ancillaryData: false
        )
    }

    /** Connects to an already-resolved endpoint without invoking DNS.
     * @param context Shared operation context.
     * @param endpoint Remote Internet endpoint.
     */
    public static func connect(
        endpoint: api.SocketEndpoint,
        context!: api.OperationContext = api.OperationContext.background()
    ): TcpStream {
        TcpStream(stdnet.ContractStreamBackend.connectTcp(endpoint, context))
    }

    /** Current stream lifecycle state. A returned stream is already connected. */
    public prop state: SocketState {
        get() {
            if (delegate.isClosed()) {
                SocketState.Closed
            } else {
                SocketState.Open
            }
        }
    }
    /** Advisory stream capabilities. Unrepresented descriptor, datagram and raw features remain false. */
    public prop capabilities: SocketCapabilities { get() { capabilityValue } }
    /** Immutable local endpoint captured when the connection completed. */
    public prop localEndpoint: ?NetworkEndpoint { get() { localEndpointValue } }
    /** Immutable remote endpoint captured when the connection completed. */
    public prop remoteEndpoint: ?NetworkEndpoint { get() { remoteEndpointValue } }

    /** Reads one partial chunk.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func read(destination: api.MutableByteSpan, context!: api.OperationContext): ReadResult {
        match (delegate.readSome(destination, context: context)) {
            case api.ReadResult.Data(count) => ReadResult.Data(count)
            case api.ReadResult.EndOfStream => ReadResult.EndOfStream
        }
    }
    /** Reads one transport chunk and returns the provider-neutral result.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readSome(
        destination: api.MutableByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ReadResult {
        delegate.readSome(destination, context: context)
    }
    /** Writes one partial chunk.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func write(source: api.ByteSpan, context!: api.OperationContext): Int64 {
        delegate.writeSome(source, context: context)
    }
    /** Writes one transport chunk.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeSome(
        source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()
    ): Int64 {
        delegate.writeSome(source, context: context)
    }
    /** Reads until the destination is full.
     *
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readExact(destination: api.MutableByteSpan, context!: api.OperationContext): Unit {
        api.readExact(delegate, destination, context: context)
    }
    /** Writes until the source is consumed.
     *
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeAll(source: api.ByteSpan, context!: api.OperationContext): Unit {
        api.writeAll(delegate, source, context: context)
    }
    /** Requests a directional shutdown.
     * @param direction Direction to shut down.
     */
    public func shutdown(direction: api.ShutdownDirection): Unit { delegate.shutdown(direction) }
    /** Closes the stream idempotently.
     * @param context Shared operation context.
     */
    public func close(context!: api.OperationContext): Unit { delegate.close(context) }
    /** Closes the stream with a background context for Resource callers. */
    public func close(): Unit { delegate.close(api.OperationContext.background()) }
    /** Aborts the stream idempotently.
     * @param reason Optional abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit {
        delegate.abort(reason: reason)
    }
    /** Reports the transport's explicit terminal lifecycle state. */
    public func isClosed(): Bool { delegate.isClosed() }

    /** Returns the immutable connection diagnostics captured after connect. */
    public prop info: api.TransportInfo { get() { connectionInfo } }
}

/** Raw protocol/domain configuration, independent from destination addressing. */
public enum RawSocketDomain {
/** IPv4 raw socket domain. */
    | Ipv4
/** IPv6 raw socket domain. */
    | Ipv6
/** Linux packet domain; not implemented in the M8 profile. */
    | Packet
/** Linux netlink domain; not implemented in the M8 profile. */
    | Netlink
}

/** A numeric raw protocol value. */
public struct RawSocketProtocol {
    /** Numeric protocol identifier. */
    public let number: Int32
    /** Creates a bounded numeric raw protocol value.
     * @param number Protocol identifier in the supported numeric range.
     */
    public init(number: Int32) {
        if (number < 0 || number > 255) { throw IllegalArgumentException("raw protocol must be between 0 and 255") }
        this.number = number
    }
    /** Returns the IPv4 ICMP protocol number. */
    public static func icmp(): RawSocketProtocol { RawSocketProtocol(1) }
    /** Returns the IPv6 ICMP protocol number. */
    public static func icmpv6(): RawSocketProtocol { RawSocketProtocol(58) }
}

/** Opaque raw address bytes. C pointers and native descriptors never escape. */
public struct RawAddress {
    private let value: Array<Byte>
    /** Creates a bounded raw destination address.
     * @param bytes Address bytes owned by this value.
     */
    public init(bytes: Array<Byte>) {
        if (bytes.isEmpty() || bytes.size > 256) { throw IllegalArgumentException("raw address is outside the bounded range") }
        value = bytes.clone()
    }
    /** Returns a defensive copy of the address bytes. */
    public func bytes(): Array<Byte> { value.clone() }
}

/**
 * Explicit raw-socket capability boundary.
 *
 * M8-001 installs no privileged raw adapter, so construction always fails
 * with a structured Unsupported error. It does not return a placeholder
 * object with operations that can never succeed.
 */
public class RawSocket {
    private init() {}

    /** Attempts to open a raw socket through an installed capability adapter.
     * @param domain Address domain to open.
     * @param protocolValue Raw protocol number.
     */
    public static func open(
        domain: RawSocketDomain,
        protocolValue!: RawSocketProtocol = RawSocketProtocol.icmp()
    ): RawSocket {
        let _ = domain
        let _ = protocolValue
        throw api.NetworkException(
            api.NetworkErrorCategory.Unsupported,
            api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Unsupported,
            "raw socket capability adapter is not installed in the M8 Linux profile",
            retryability: api.Retryability.Never
        )
    }
}

