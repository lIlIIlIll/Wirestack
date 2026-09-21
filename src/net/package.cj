package wirestack.net

import std.collection.*
import std.convert.Parsable
import std.fs.*
import std.sync.*
import std.time.*
import wirestack as api
import wirestack.internal.resolver as system_resolver
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

private func unixIsUnnamed(kind: UnixEndpointKind): Bool {
    match (kind) {
        case UnixEndpointKind.Unnamed => true
        case _ => false
    }
}

private func unixIsAbstract(kind: UnixEndpointKind): Bool {
    match (kind) {
        case UnixEndpointKind.Abstract => true
        case _ => false
    }
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

/** Typed socket options accepted by stream and datagram sockets. */
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

/** Explicit unsafe option bytes. No C pointer or native descriptor escapes. */
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

    internal init(payload: Array<Byte>, source: ?NetworkEndpoint, truncated: Bool) {
        this.payload = payload.clone()
        this.source = source
        this.truncated = truncated
    }
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
    private let configuredOptions = ArrayList<SocketOption>()

    internal init(delegate: api.DuplexTransport) { this.delegate = delegate }

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

    /** Current stream lifecycle state. */
    public prop state: SocketState {
        get() { if (delegate.info.localEndpoint.isSome()) { SocketState.Open } else { SocketState.Connecting } }
    }
    /** Advisory stream capabilities. */
    public prop capabilities: SocketCapabilities {
        get() { SocketCapabilities(halfClose: delegate.info.supportsHalfClose) }
    }
    /** Local endpoint when known. */
    public prop localEndpoint: ?NetworkEndpoint {
        get() { match (delegate.info.localEndpoint) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> } }
    }
    /** Remote endpoint when known. */
    public prop remoteEndpoint: ?NetworkEndpoint {
        get() { match (delegate.info.remoteEndpoint) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> } }
    }

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
    public func readSome(destination: api.MutableByteSpan, context!: api.OperationContext = api.OperationContext.background()): api.ReadResult {
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
    public func writeSome(source: api.ByteSpan, context!: api.OperationContext = api.OperationContext.background()): Int64 {
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
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit { delegate.abort(reason: reason) }
    /** Reports whether the stream is closed. */
    public func isClosed(): Bool { delegate.info.localEndpoint.isNone() && delegate.info.remoteEndpoint.isNone() }

    /** Applies a bounded typed socket option.
     * @param option Option to apply.
     */
    public func setOption(option: SocketOption): Unit {
        match (option) {
            case SocketOption.ReceiveBuffer(value) =>
                if (value <= 0 || value > 64 * 1024 * 1024) { throw IllegalArgumentException("socket buffer is outside the bounded range") }
            case SocketOption.SendBuffer(value) =>
                if (value <= 0 || value > 64 * 1024 * 1024) { throw IllegalArgumentException("socket buffer is outside the bounded range") }
            case SocketOption.MulticastTtl(value) => if (value == 0u8) { throw IllegalArgumentException("multicast TTL must be non-zero") }
            case _ => ()
        }
        configuredOptions.add(option)
    }
    /** Applies an opaque option payload.
     * @param option Option to apply.
     */
    public func setUnsafeOption(option: UnsafeSocketOption): Unit { let _ = option }

    /** Returns transport diagnostics without exposing native handles. */
    public prop info: api.TransportInfo { get() { delegate.info } }
}

/** TCP listener with a context-bounded synchronous accept. */
public class TcpListener <: Resource {
    private let delegate: stdnet.ContractStreamListener

    private init(delegate: stdnet.ContractStreamListener) { this.delegate = delegate }

    /** Binds a TCP listener.
     *
     * @param backlog Maximum pending connection count.
     * @param endpoint Local endpoint.
     */
    public static func bind(endpoint: api.SocketEndpoint, backlog!: Int64 = 128): TcpListener {
        TcpListener(stdnet.ContractStreamListener.bindTcp(endpoint, backlog))
    }
    /** Local endpoint when known. */
    public prop localEndpoint: ?NetworkEndpoint {
        get() { match (delegate.localEndpoint()) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> } }
    }
    /** Current listener lifecycle state. */
    public prop state: SocketState { get() { if (delegate.isClosed()) { SocketState.Closed } else { SocketState.Listening } } }
    /** Accepts one connection under the shared operation context.
     * @param context Shared operation context.
     */
    public func accept(context!: api.OperationContext = api.OperationContext.background()): TcpStream {
        TcpStream(delegate.accept(context))
    }
    /** Closes the listener idempotently. */
    public func close(): Unit { delegate.stop() }
    /** Reports whether the listener is closed. */
    public func isClosed(): Bool { delegate.isClosed() }
}

/** Unix-domain stream socket. */
public class UnixStream <: StreamSocket & api.DuplexTransport {
    private let delegate: TcpStream

    internal init(delegate: TcpStream) { this.delegate = delegate }

    /** Connects to a pathname or abstract Unix endpoint.
     *
     * @param context Shared operation context.
     * @param endpoint Unix endpoint.
     */
    public static func connect(endpoint: UnixEndpoint, context!: api.OperationContext = api.OperationContext.background()): UnixStream {
        if (unixIsUnnamed(endpoint.kind)) {
            throw api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
                api.NetworkErrorCode.InvalidState, "unnamed Unix endpoint cannot be used as a connect target")
        }
        UnixStream(TcpStream(stdnet.ContractStreamBackend.connectUnix(
            endpoint.nameBytes(), unixIsAbstract(endpoint.kind), context
        )))
    }
    /** Current stream lifecycle state. */
    public prop state: SocketState { get() { delegate.state } }
    /** Advisory stream capabilities. */
    public prop capabilities: SocketCapabilities { get() { delegate.capabilities } }
    /** Local endpoint when known. */
    public prop localEndpoint: ?NetworkEndpoint { get() { Some(NetworkEndpoint.Unix(UnixEndpoint.unnamed())) } }
    /** Remote endpoint when known. */
    public prop remoteEndpoint: ?NetworkEndpoint { get() { Some(NetworkEndpoint.Unix(UnixEndpoint.unnamed())) } }
    /** Reads one partial chunk.
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func read(destination: api.MutableByteSpan, context!: api.OperationContext): ReadResult { delegate.read(destination, context: context) }
    /** Reads one transport chunk.
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readSome(destination: api.MutableByteSpan, context!: api.OperationContext = api.OperationContext.background()): api.ReadResult { delegate.readSome(destination, context: context) }
    /** Writes one partial chunk.
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func write(source: api.ByteSpan, context!: api.OperationContext): Int64 { delegate.write(source, context: context) }
    /** Writes one transport chunk.
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeSome(source: api.ByteSpan, context!: api.OperationContext = api.OperationContext.background()): Int64 { delegate.writeSome(source, context: context) }
    /** Reads until the destination is full.
     * @param context Shared operation context.
     * @param destination Destination byte span.
     */
    public func readExact(destination: api.MutableByteSpan, context!: api.OperationContext): Unit { delegate.readExact(destination, context: context) }
    /** Writes until the source is consumed.
     * @param context Shared operation context.
     * @param source Source byte span.
     */
    public func writeAll(source: api.ByteSpan, context!: api.OperationContext): Unit { delegate.writeAll(source, context: context) }
    /** Requests a directional shutdown.
     * @param direction Direction to shut down.
     */
    public func shutdown(direction: api.ShutdownDirection): Unit { delegate.shutdown(direction) }
    /** Closes the stream idempotently.
     * @param context Shared operation context.
     */
    public func close(context!: api.OperationContext): Unit { delegate.close(context: context) }
    /** Closes the stream with a background context for Resource callers. */
    public func close(): Unit { delegate.close(context: api.OperationContext.background()) }
    /** Aborts the stream idempotently.
     * @param reason Optional abort reason.
     */
    public func abort(reason!: ?api.AbortReason = None<api.AbortReason>): Unit { delegate.abort(reason: reason) }
    /** Reports whether the stream is closed. */
    public func isClosed(): Bool { delegate.isClosed() }
    /** Returns transport diagnostics without exposing native handles. */
    public prop info: api.TransportInfo { get() { delegate.info } }
}

/** Unix-domain stream listener. */
public class UnixListener <: Resource {
    private let delegate: stdnet.ContractStreamListener
    internal init(delegate: stdnet.ContractStreamListener) { this.delegate = delegate }
    /** Binds a Unix-domain listener.
     *
     * @param backlog Maximum pending connection count.
     * @param endpoint Unix endpoint.
     */
    public static func bind(endpoint: UnixEndpoint, backlog!: Int64 = 128): UnixListener {
        if (unixIsUnnamed(endpoint.kind)) {
            throw api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
                api.NetworkErrorCode.InvalidState, "unnamed Unix endpoint cannot be bound")
        }
        UnixListener(stdnet.ContractStreamListener.bindUnix(
            endpoint.nameBytes(), unixIsAbstract(endpoint.kind), backlog
        ))
    }
    /** Accepts one connection under the shared operation context.
     * @param context Shared operation context.
     */
    public func accept(context!: api.OperationContext = api.OperationContext.background()): UnixStream {
        UnixStream(TcpStream(delegate.accept(context)))
    }
    /** Closes the listener idempotently. */
    public func close(): Unit { delegate.stop() }
    /** Reports whether the listener is closed. */
    public func isClosed(): Bool { delegate.isClosed() }
}

/** Datagram socket preserving message atomicity and boundaries. */
public class DatagramSocket <: Resource {
    private let delegate: stdnet.ContractDatagramBackend
    private var peer: ?api.SocketEndpoint = None<api.SocketEndpoint>

    internal init(delegate: stdnet.ContractDatagramBackend) { this.delegate = delegate }

    /** Binds an Internet datagram socket.
     * @param endpoint Optional local endpoint.
     */
    public static func bind(endpoint!: ?api.SocketEndpoint = None<api.SocketEndpoint>): DatagramSocket {
        DatagramSocket(stdnet.ContractDatagramBackend.bind(endpoint))
    }
    /** Local endpoint when known. */
    public prop localEndpoint: ?NetworkEndpoint {
        get() { match (delegate.localEndpoint()) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> } }
    }
    /** Connected peer endpoint when configured. */
    public prop remoteEndpoint: ?NetworkEndpoint {
        get() { match (delegate.remoteEndpoint()) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> } }
    }
    /** Selects the peer used by `send`.
     *
     * @param context Shared operation context.
     * @param endpoint Peer endpoint.
     */
    public func connect(endpoint: api.SocketEndpoint, context!: api.OperationContext = api.OperationContext.background()): Unit {
        delegate.connect(endpoint, context)
        peer = Some(endpoint)
    }
    /** Sends one connected datagram atomically.
     *
     * @param context Shared operation context.
     * @param source Datagram bytes.
     */
    public func send(source: api.ByteSpan, context!: api.OperationContext = api.OperationContext.background()): Int64 {
        delegate.send(peer, source, context)
    }
    /** Sends one datagram to a resolved endpoint.
     *
     * @param context Shared operation context.
     * @param endpoint Destination endpoint.
     * @param source Datagram bytes.
     */
    public func sendTo(endpoint: api.SocketEndpoint, source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()): Int64 {
        delegate.send(Some(endpoint), source, context)
    }
    /** Receives one datagram and reports truncation.
     *
     * @param capacity Maximum payload bytes to copy.
     * @param context Shared operation context.
     */
    public func receive(capacity: Int64, context!: api.OperationContext = api.OperationContext.background()): DatagramReceiveResult {
        let (payload, source, truncated) = delegate.receive(capacity, context)
        let endpoint = match (source) { case Some(value) => Some(NetworkEndpoint.Internet(value)); case None => None<NetworkEndpoint> }
        DatagramReceiveResult(payload, endpoint, truncated)
    }
    /** Closes the datagram socket idempotently. */
    public func close(): Unit { delegate.close() }
    /** Reports whether the datagram socket is closed. */
    public func isClosed(): Bool { delegate.isClosed() }
    /** Applies a bounded typed socket option.
     * @param option Option to apply.
     */
    public func setOption(option: SocketOption): Unit {
        match (option) {
            case SocketOption.ReceiveBuffer(value) =>
                if (value <= 0 || value > 64 * 1024 * 1024) { throw IllegalArgumentException("socket buffer is outside the bounded range") }
            case SocketOption.SendBuffer(value) =>
                if (value <= 0 || value > 64 * 1024 * 1024) { throw IllegalArgumentException("socket buffer is outside the bounded range") }
            case _ => ()
        }
    }
    /** Applies an opaque option payload.
     * @param option Option to apply.
     */
    public func setUnsafeOption(option: UnsafeSocketOption): Unit { let _ = option }
}

/** Unix-domain datagram socket. */
public class UnixDatagramSocket <: Resource {
    private let delegate: stdnet.ContractDatagramBackend
    private init(delegate: stdnet.ContractDatagramBackend) { this.delegate = delegate }
    /** Binds a pathname or abstract Unix datagram endpoint.
     * @param endpoint Unix endpoint.
     */
    public static func bind(endpoint: UnixEndpoint): UnixDatagramSocket {
        if (unixIsUnnamed(endpoint.kind)) {
            throw api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
                api.NetworkErrorCode.InvalidState, "unnamed Unix endpoint cannot be bound")
        }
        UnixDatagramSocket(stdnet.ContractDatagramBackend.bindUnix(
            endpoint.nameBytes(), unixIsAbstract(endpoint.kind)
        ))
    }
    /** Sends one Unix datagram when a native byte-address adapter is available.
     *
     * @param context Shared operation context.
     * @param endpoint Destination Unix endpoint.
     * @param source Datagram bytes.
     */
    public func sendTo(endpoint: UnixEndpoint, source: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()): Int64 {
        if (unixIsUnnamed(endpoint.kind)) {
            throw api.NetworkException(api.NetworkErrorCategory.Address, api.NetworkPhase.UnixSocket,
                api.NetworkErrorCode.InvalidState, "unnamed Unix endpoint cannot be a datagram destination")
        }
        delegate.sendUnix(endpoint.nameBytes(), source, context)
    }
    /** Receives one Unix datagram and reports truncation.
     *
     * @param capacity Maximum payload bytes to copy.
     * @param context Shared operation context.
     */
    public func receive(capacity: Int64, context!: api.OperationContext = api.OperationContext.background()): DatagramReceiveResult {
        let (payload, _, truncated) = delegate.receive(capacity, context)
        DatagramReceiveResult(payload, None<NetworkEndpoint>, truncated)
    }
    /** Closes the datagram socket idempotently. */
    public func close(): Unit { delegate.close() }
    /** Reports whether the datagram socket is closed. */
    public func isClosed(): Bool { delegate.isClosed() }
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

/** Capability-scoped raw socket. Linux packet/netlink/seqpacket/ancillary are explicit exclusions in M8. */
public class RawSocket <: Resource {
    /** Address domain selected when this socket was opened. */
    public let domain: RawSocketDomain
    /** Protocol selected when this socket was opened. */
    public let protocolValue: RawSocketProtocol
    private var closed = false

    private init(domain: RawSocketDomain, protocolValue: RawSocketProtocol) {
        this.domain = domain
        this.protocolValue = protocolValue
    }

    /** Opens a raw socket when a capability adapter is installed.
     * @param domain Address domain to open.
     * @param protocolValue Raw protocol number.
     */
    public static func open(domain: RawSocketDomain, protocolValue!: RawSocketProtocol = RawSocketProtocol.icmp()): RawSocket {
        let _ = domain
        let _ = protocolValue
        // The M8 profile deliberately has no privileged native raw adapter.
        // Fail closed at construction instead of returning a handle whose first
        // operation would only fail later.
        throw api.NetworkException(api.NetworkErrorCategory.Unsupported, api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Unsupported,
            "raw socket capability adapter is not installed in the M8 Linux profile")
    }

    /** Reports the advisory raw-socket capability set. */
    public prop capabilities: SocketCapabilities { get() { SocketCapabilities(raw: true) } }
    /** Sends one raw packet or reports that the capability adapter is unavailable.
     * @param address Opaque destination address.
     * @param payload Packet payload bytes.
     * @param context Shared operation context.
     */
    public func sendTo(address: RawAddress, payload: api.ByteSpan,
        context!: api.OperationContext = api.OperationContext.background()): Int64 {
        let _ = address
        let _ = payload
        let _ = context
        if (closed) { throw api.NetworkException(api.NetworkErrorCategory.Closed, api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Closed, "raw socket is closed") }
        throw api.NetworkException(api.NetworkErrorCategory.Unsupported, api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Unsupported, "raw packet I/O requires the dedicated Linux capability adapter")
    }
    /** Receives one raw packet or reports that the capability adapter is unavailable.
     * @param capacity Maximum payload bytes to copy.
     * @param context Shared operation context.
     */
    public func receive(capacity: Int64, context!: api.OperationContext = api.OperationContext.background()): DatagramReceiveResult {
        let _ = capacity
        let _ = context
        if (closed) { throw api.NetworkException(api.NetworkErrorCategory.Closed, api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Closed, "raw socket is closed") }
        throw api.NetworkException(api.NetworkErrorCategory.Unsupported, api.NetworkPhase.RawSocket,
            api.NetworkErrorCode.Unsupported, "raw packet I/O requires the dedicated Linux capability adapter")
    }
    /** Closes the raw socket idempotently. */
    public func close(): Unit { closed = true }
    /** Reports whether the raw socket is closed. */
    public func isClosed(): Bool { closed }
}

/** Nameserver configuration parsed from the Linux stub resolver files. */
public struct DnsResolverConfig {
    /** Configured nameserver endpoints. */
    public let nameservers: Array<api.SocketEndpoint>
    /** Search-domain suffixes applied by the resolver policy. */
    public let searchDomains: Array<api.HostName>
    /** Minimum dot count before search-domain expansion. */
    public let ndots: Int64
    /** Bounded hosts-file path; an empty value disables hosts-file lookup. */
    public let hostsPath: String

    /** Creates bounded resolver configuration.
     * @param nameservers Nameserver endpoints.
     * @param searchDomains Search-domain suffixes.
     * @param ndots Minimum dot count for absolute lookup preference.
     * @param hostsPath Optional bounded hosts-file path.
     */
    public init(
        nameservers!: Array<api.SocketEndpoint> = Array<api.SocketEndpoint>(),
        searchDomains!: Array<api.HostName> = Array<api.HostName>(),
        ndots!: Int64 = 1,
        hostsPath!: String = "/etc/hosts"
    ) {
        if (nameservers.size > 8 || searchDomains.size > 16 || ndots < 0 || ndots > 15 ||
            hostsPath.size > 4096 || hostsPath.contains("\0") ||
            (!hostsPath.isEmpty() && !Path(hostsPath).isAbsolute())) {
            throw IllegalArgumentException("DNS resolver configuration exceeds bounds")
        }
        this.nameservers = nameservers.clone()
        this.searchDomains = searchDomains.clone()
        this.ndots = ndots
        this.hostsPath = hostsPath
    }

    /** Reads only nameserver, search/domain and ndots from resolv.conf.
     * @param path Resolver configuration file path.
     */
    public static func fromSystem(path!: String = "/etc/resolv.conf"): DnsResolverConfig {
        if (!exists(path)) { return DnsResolverConfig() }
        let lines = String.fromUtf8(File.readFrom(path)).split("\n")
        let servers = ArrayList<api.SocketEndpoint>()
        let search = ArrayList<api.HostName>()
        var ndots: Int64 = 1
        for (line in lines) {
            let fields = dnsFields(line)
            if (fields.isEmpty()) { continue }
            match (fields[0]) {
                case "nameserver" => if (fields.size >= 2) {
                    match (parseIpLiteral(fields[1])) {
                        case Some(address) => servers.add(api.SocketEndpoint(address, 53))
                        case None => ()
                    }
                }
                case "search" | "domain" =>
                    for (field in fields[1..fields.size]) {
                        try { search.add(api.HostName(field)) } catch (_: Exception) { () }
                    }
                case "options" =>
                    for (field in fields[1..fields.size]) {
                        if (field.startsWith("ndots:")) {
                            match (Int64.tryParse(field[6..field.size])) {
                                case Some(value) => ndots = if (value > 15) { 15 } else { value }
                                case None => ()
                            }
                        }
                    }
                case _ => ()
            }
        }
        DnsResolverConfig(nameservers: servers.toArray(), searchDomains: search.toArray(), ndots: ndots)
    }
}

private const DNS_CLASS_IN: UInt16 = 1u16
private const DNS_MAX_MESSAGE: Int64 = 65535
private const DNS_QUERY_ATTEMPTS: Int64 = 2
private let DNS_CACHE_TTL = 30 * Duration.second
private let DNS_NEGATIVE_CACHE_TTL = 5 * Duration.second

/** DNS record types understood by the bounded wire parser. */
public enum DnsRecordType {
    /** IPv4 address record. */
    | A
    /** IPv6 address record. */
    | AAAA
    /** Canonical-name record. */
    | CNAME
    /** Service record. */
    | SRV
    /** Text record. */
    | TXT
    /** Mail-exchange record. */
    | MX
    /** Reverse-pointer record. */
    | PTR
    /** Record type not decoded by the public model. */
    | Unknown(Int64)
}

/** One validated DNS question section entry. */
public struct DnsQuestion {
    /** Canonical wire name. */
    public let name: String
    /** Question type. */
    public let recordType: DnsRecordType
    /** DNS class, normally IN (1). */
    public let recordClass: UInt16

    internal init(name: String, recordType: DnsRecordType, recordClass: UInt16) {
        this.name = name
        this.recordType = recordType
        this.recordClass = recordClass
    }
}

/** One bounded DNS resource record with validated RDATA. */
public struct DnsRecord {
    /** Owner name. */
    public let name: String
    /** Resource-record type. */
    public let recordType: DnsRecordType
    /** DNS class, normally IN (1). */
    public let recordClass: UInt16
    /** Record time-to-live in seconds. */
    public let ttl: UInt32
    /** Opaque but length-validated RDATA bytes. */
    private let ownedData: Array<Byte>
    /** Decoded target for CNAME, PTR, MX and SRV records when present. */
    public let targetName: ?String

    internal init(
        name: String,
        recordType: DnsRecordType,
        recordClass: UInt16,
        ttl: UInt32,
        data: Array<Byte>,
        targetName!: ?String = None<String>
    ) {
        this.name = name
        this.recordType = recordType
        this.recordClass = recordClass
        this.ttl = ttl
        this.ownedData = data.clone()
        this.targetName = targetName
    }

    /** Returns a defensive copy of RDATA. */
    public func data(): Array<Byte> { ownedData.clone() }
}

/** Bounded DNS wire parser summary. */
public struct DnsMessageSummary {
    /** Transaction identifier copied from the response header. */
    public let transactionId: UInt16
    /** Number of answer records in the response header. */
    public let answerCount: Int64
    /** Whether the response advertises truncation. */
    public let truncated: Bool
    /** DNS response code from the low four header flag bits. */
    public let responseCode: Int64
    /** Number of question entries. */
    public let questionCount: Int64
    /** Number of authority records. */
    public let authorityCount: Int64
    /** Number of additional records. */
    public let additionalCount: Int64
    /** Validated question entries. */
    public let questions: Array<DnsQuestion>
    /** Validated answer, authority and additional records. */
    public let records: Array<DnsRecord>

    /** Creates a validated DNS header summary.
     * @param transactionId Transaction identifier.
     * @param answerCount Answer record count.
     * @param truncated Truncation flag.
     * @param responseCode Validated DNS response code.
     * @param questionCount Number of question entries.
     * @param authorityCount Number of authority records.
     * @param additionalCount Number of additional records.
     * @param questions Validated question entries.
     * @param records Validated answer, authority and additional records.
     */
    public init(
        transactionId: UInt16,
        answerCount: Int64,
        truncated: Bool,
        responseCode!: Int64 = 0,
        questionCount!: Int64 = 0,
        authorityCount!: Int64 = 0,
        additionalCount!: Int64 = 0,
        questions!: Array<DnsQuestion> = Array<DnsQuestion>(),
        records!: Array<DnsRecord> = Array<DnsRecord>()
    ) {
        if (answerCount < 0 || questionCount < 0 || authorityCount < 0 || additionalCount < 0 ||
            responseCode < 0 || responseCode > 15) {
            throw IllegalArgumentException("DNS section counts must be non-negative")
        }
        this.transactionId = transactionId
        this.answerCount = answerCount
        this.truncated = truncated
        this.responseCode = responseCode
        this.questionCount = questionCount
        this.authorityCount = authorityCount
        this.additionalCount = additionalCount
        this.questions = questions.clone()
        this.records = records.clone()
    }
}

/** Parser limits for hostile DNS responses. */
public struct DnsParserLimits {
    /** Maximum accepted DNS message size in bytes. */
    public let maximumMessageBytes: Int64
    /** Maximum decoded domain-name length in bytes. */
    public let maximumNameBytes: Int64
    /** Maximum compression-pointer indirections. */
    public let maximumIndirections: Int64
    /** Creates bounded DNS parser limits.
     * @param maximumMessageBytes Maximum wire message length.
     * @param maximumNameBytes Maximum decoded name length.
     * @param maximumIndirections Maximum compression-pointer hops.
     */
    public init(
        maximumMessageBytes!: Int64 = 65535,
        maximumNameBytes!: Int64 = 253,
        maximumIndirections!: Int64 = 32
    ) {
        if (maximumMessageBytes <= 0 || maximumMessageBytes > 65535 || maximumNameBytes <= 0 ||
            maximumNameBytes > 253 || maximumIndirections <= 0 || maximumIndirections > 128) {
            throw IllegalArgumentException("DNS parser limits are outside the bounded range")
        }
        this.maximumMessageBytes = maximumMessageBytes
        this.maximumNameBytes = maximumNameBytes
        this.maximumIndirections = maximumIndirections
    }
}

/** Parses bounded DNS wire messages, names and selected resource records. */
public class DnsMessageParser {
    /** Limits applied to every parse operation. */
    public let limits: DnsParserLimits
    /** Creates a parser with bounded limits.
     * @param limits Parser limits.
     */
    public init(limits!: DnsParserLimits = DnsParserLimits()) { this.limits = limits }

    /** Parses and validates DNS sections, compression pointers and RDATA.
     * @param message DNS wire message bytes.
     */
    public func parse(message: Array<Byte>): DnsMessageSummary {
        if (message.size < 12 || message.size > limits.maximumMessageBytes) {
            throw dnsMalformed("DNS message length is invalid")
        }
        let flags = (UInt16(message[2]) << 8) | UInt16(message[3])
        let questionsCount = (Int64(message[4]) << 8) | Int64(message[5])
        let answers = (Int64(message[6]) << 8) | Int64(message[7])
        let authority = (Int64(message[8]) << 8) | Int64(message[9])
        let additional = (Int64(message[10]) << 8) | Int64(message[11])
        if ((flags & 0x8000u16) == 0u16) {
            throw dnsMalformed("DNS response flag is missing")
        }
        let totalSections = questionsCount + answers + authority + additional
        if (totalSections > 4096) {
            throw dnsMalformed("DNS section count exceeds the bounded limit")
        }
        var offset: Int64 = 12
        let questions = ArrayList<DnsQuestion>()
        for (_ in 0..questionsCount) {
            let (name, next) = parseDnsName(message, offset)
            offset = next
            if (offset + 4 > message.size) { throw dnsMalformed("DNS question is truncated") }
            let typeCode = (Int64(message[offset]) << 8) | Int64(message[offset + 1])
            let classCode = (UInt16(message[offset + 2]) << 8) | UInt16(message[offset + 3])
            offset += 4
            questions.add(DnsQuestion(name, dnsRecordType(typeCode), classCode))
        }
        let records = ArrayList<DnsRecord>()
        let recordCount = answers + authority + additional
        for (_ in 0..recordCount) {
            let (record, next) = parseDnsRecord(message, offset)
            offset = next
            records.add(record)
        }
        DnsMessageSummary(
            (UInt16(message[0]) << 8) | UInt16(message[1]),
            answers,
            (flags & 0x0200u16) != 0u16,
            responseCode: Int64(flags & 0x000Fu16),
            questionCount: questionsCount,
            authorityCount: authority,
            additionalCount: additional,
            questions: questions.toArray(),
            records: records.toArray()
        )
    }

    private func parseDnsName(message: Array<Byte>, start: Int64): (String, Int64) {
        if (start < 12 || start >= message.size) { throw dnsMalformed("DNS name offset is outside the message") }
        var cursor = start
        var next = start
        var jumped = false
        var hops: Int64 = 0
        var decodedBytes: Int64 = 0
        let labels = ArrayList<String>()
        let seen = ArrayList<Int64>()
        while (true) {
            if (cursor >= message.size) { throw dnsMalformed("DNS name is truncated") }
            let length = UInt16(message[cursor])
            if ((length & 0xC0u16) == 0xC0u16) {
                if (cursor + 1 >= message.size) { throw dnsMalformed("DNS compression pointer is truncated") }
                let pointer = Int64(((length & 0x3Fu16) << 8) | UInt16(message[cursor + 1]))
                if (pointer < 12 || pointer >= message.size) { throw dnsMalformed("DNS compression pointer is outside the message") }
                if (hops >= limits.maximumIndirections) { throw dnsMalformed("DNS compression indirection limit exceeded") }
                for (value in seen) { if (value == pointer) { throw dnsMalformed("DNS compression loop detected") } }
                seen.add(pointer)
                hops += 1
                if (!jumped) { next = cursor + 2; jumped = true }
                cursor = pointer
                continue
            }
            if ((length & 0xC0u16) != 0u16) { throw dnsMalformed("DNS label uses a reserved length encoding") }
            if (length == 0u16) {
                if (!jumped) { next = cursor + 1 }
                break
            }
            if (length > 63u16 || cursor + 1 + Int64(length) > message.size) {
                throw dnsMalformed("DNS label exceeds the message bounds")
            }
            decodedBytes += Int64(length) + 1
            if (decodedBytes > limits.maximumNameBytes) { throw dnsMalformed("DNS name exceeds the bounded length") }
            let labelBytes = Array<Byte>(Int64(length), repeat: 0u8)
            for (index in 0..Int64(length)) {
                let value = message[cursor + 1 + index]
                if (value < 0x21u8 || value > 0x7Eu8) { throw dnsMalformed("DNS name contains a non-ASCII label byte") }
                labelBytes[index] = value
            }
            labels.add(String.fromUtf8(labelBytes))
            cursor += 1 + Int64(length)
        }
        var name = ""
        for (index in 0..labels.size) {
            if (index > 0) { name += "." }
            name += labels[index]
        }
        (name, next)
    }

    private func parseDnsRecord(message: Array<Byte>, start: Int64): (DnsRecord, Int64) {
        let (name, afterName) = parseDnsName(message, start)
        if (afterName + 10 > message.size) { throw dnsMalformed("DNS resource record header is truncated") }
        let typeCode = (Int64(message[afterName]) << 8) | Int64(message[afterName + 1])
        let classCode = (UInt16(message[afterName + 2]) << 8) | UInt16(message[afterName + 3])
        let ttl = (UInt32(message[afterName + 4]) << 24) |
            (UInt32(message[afterName + 5]) << 16) |
            (UInt32(message[afterName + 6]) << 8) |
            UInt32(message[afterName + 7])
        let dataLength = (Int64(message[afterName + 8]) << 8) | Int64(message[afterName + 9])
        let dataStart = afterName + 10
        let dataEnd = dataStart + dataLength
        if (dataEnd > message.size) { throw dnsMalformed("DNS resource record data is truncated") }
        let recordType = dnsRecordType(typeCode)
        var target: ?String = None<String>
        match (recordType) {
            case DnsRecordType.A => if (dataLength != 4) { throw dnsMalformed("A record has an invalid length") }
            case DnsRecordType.AAAA => if (dataLength != 16) { throw dnsMalformed("AAAA record has an invalid length") }
            case DnsRecordType.CNAME | DnsRecordType.PTR =>
                let (decoded, consumed) = parseDnsName(message, dataStart)
                if (consumed > dataEnd) { throw dnsMalformed("compressed target escapes RDATA") }
                target = Some(decoded)
            case DnsRecordType.MX =>
                if (dataLength < 3) { throw dnsMalformed("MX record is too short") }
                let (decoded, consumed) = parseDnsName(message, dataStart + 2)
                if (consumed > dataEnd) { throw dnsMalformed("MX target escapes RDATA") }
                target = Some(decoded)
            case DnsRecordType.SRV =>
                if (dataLength < 7) { throw dnsMalformed("SRV record is too short") }
                let (decoded, consumed) = parseDnsName(message, dataStart + 6)
                if (consumed > dataEnd) { throw dnsMalformed("SRV target escapes RDATA") }
                target = Some(decoded)
            case DnsRecordType.TXT =>
                var cursor = dataStart
                while (cursor < dataEnd) {
                    let chunk = Int64(message[cursor])
                    cursor += 1
                    if (cursor + chunk > dataEnd) { throw dnsMalformed("TXT chunk exceeds RDATA") }
                    cursor += chunk
                }
            case _ => ()
        }
        let data = Array<Byte>(dataLength, repeat: 0u8)
        for (index in 0..dataLength) { data[index] = message[dataStart + index] }
        (DnsRecord(name, recordType, classCode, ttl, data, targetName: target), dataEnd)
    }
}

private func dnsRecordType(code: Int64): DnsRecordType {
    match (code) {
        case 1 => DnsRecordType.A
        case 28 => DnsRecordType.AAAA
        case 5 => DnsRecordType.CNAME
        case 33 => DnsRecordType.SRV
        case 16 => DnsRecordType.TXT
        case 15 => DnsRecordType.MX
        case 12 => DnsRecordType.PTR
        case _ => DnsRecordType.Unknown(code)
    }
}

private func dnsMalformed(message: String): api.ResolveException {
    api.ResolveException(api.ResolveErrorCode.SystemFailure, message)
}

private func checkDnsContext(context: api.OperationContext): Unit {
    if (context.isCancellationRequested()) {
        throw api.ResolveException(api.ResolveErrorCode.Cancelled, "DNS operation cancelled")
    }
    if (context.isDeadlineExceeded()) {
        throw api.ResolveException(api.ResolveErrorCode.Timeout, "DNS operation deadline exceeded")
    }
}

private func dnsSourceMatches(source: ?NetworkEndpoint, expected: api.SocketEndpoint): Bool {
    match (source) {
        case Some(NetworkEndpoint.Internet(value)) => value == expected
        case _ => false
    }
}

private func dnsTypeCode(recordType: DnsRecordType): Int64 {
    match (recordType) {
        case DnsRecordType.A => 1
        case DnsRecordType.AAAA => 28
        case DnsRecordType.CNAME => 5
        case DnsRecordType.SRV => 33
        case DnsRecordType.TXT => 16
        case DnsRecordType.MX => 15
        case DnsRecordType.PTR => 12
        case DnsRecordType.Unknown(value) => value
    }
}

private func appendDnsU16(output: ArrayList<Byte>, value: Int64): Unit {
    output.add(UInt8(UInt64((value >> 8) & 0xFF)))
    output.add(UInt8(UInt64(value & 0xFF)))
}

private func buildDnsQuery(host: api.HostName, typeCode: Int64, transactionId: UInt16): Array<Byte> {
    let output = ArrayList<Byte>()
    appendDnsU16(output, Int64(transactionId))
    appendDnsU16(output, 0x0100)
    appendDnsU16(output, 1)
    appendDnsU16(output, 0)
    appendDnsU16(output, 0)
    appendDnsU16(output, 0)
    for (label in host.ascii.split(".")) {
        let bytes = label.toArray()
        if (bytes.isEmpty() || bytes.size > 63) { throw dnsMalformed("DNS label is outside the query bounds") }
        output.add(UInt8(UInt64(bytes.size)))
        for (value in bytes) { output.add(value) }
    }
    output.add(0u8)
    appendDnsU16(output, typeCode)
    appendDnsU16(output, Int64(DNS_CLASS_IN))
    output.toArray()
}

private func validateDnsResponse(
    summary: DnsMessageSummary,
    host: api.HostName,
    typeCode: Int64,
    transactionId: UInt16
): Unit {
    if (summary.transactionId != transactionId || summary.questionCount != 1 || summary.questions.size != 1) {
        throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS response identity is invalid")
    }
    let question = summary.questions[0]
    if (question.name != host.ascii || question.recordClass != DNS_CLASS_IN ||
        dnsTypeCode(question.recordType) != typeCode) {
        throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS response question does not match the query")
    }
    match (summary.responseCode) {
        case 0 => ()
        case 3 => throw api.ResolveException(api.ResolveErrorCode.NameNotFound, "DNS response reports NXDOMAIN")
        case 2 | 5 => throw api.ResolveException(api.ResolveErrorCode.TemporaryFailure, "DNS response reports a temporary resolver failure")
        case _ => throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS response reports an unsupported error code")
    }
}

private func addressesFromSummary(
    summary: DnsMessageSummary,
    host: api.HostName,
    typeCode: Int64
): api.ResolveResult {
    let startedAt = MonoTime.now()
    let addresses = ArrayList<api.IpAddress>()
    var current = host.ascii
    var hops: Int64 = 0
    var minimumTtl: ?UInt32 = None<UInt32>
    while (hops < 8) {
        var followed = false
        for (record in summary.records) {
            if (record.recordClass != DNS_CLASS_IN || record.name != current) { continue }
            if (dnsTypeCode(record.recordType) == typeCode) {
                let data = record.data()
                if (typeCode == 1 && data.size == 4) {
                    addresses.add(api.IpAddress(api.IpAddressFamily.Ipv4, data))
                } else if (typeCode == 28 && data.size == 16) {
                    addresses.add(api.IpAddress(api.IpAddressFamily.Ipv6, data))
                }
                match (minimumTtl) {
                    case Some(value) => if (record.ttl < value) { minimumTtl = Some(record.ttl) }
                    case None => minimumTtl = Some(record.ttl)
                }
            } else if (match (record.recordType) { case DnsRecordType.CNAME => true; case _ => false }) {
                match (record.targetName) {
                    case Some(value) =>
                        current = value
                        followed = true
                    case None => ()
                }
                if (followed) { break }
            }
        }
        if (!followed) { break }
        hops += 1
    }
    if (hops >= 8) { throw api.ResolveException(api.ResolveErrorCode.SystemFailure, "DNS CNAME chain exceeds the bounded limit") }
    let completedAt = MonoTime.now()
    let expiration = match (minimumTtl) {
        case Some(value) => Some(completedAt + Duration.second * Int64(value))
        case None => None<MonoTime>
    }
    api.ResolveResult(
        addresses.toArray(), host, api.ResolverSource.System,
        expiration: expiration,
        startedAt: startedAt,
        completedAt: completedAt
    )
}

private func queryDnsTcp(
    nameserver: api.SocketEndpoint,
    query: Array<Byte>,
    context: api.OperationContext
): Array<Byte> {
    let stream = TcpStream.connect(nameserver, context: context)
    try {
        let frame = Array<Byte>(query.size + 2, repeat: 0u8)
        frame[0] = UInt8(UInt64((query.size >> 8) & 0xFF))
        frame[1] = UInt8(UInt64(query.size & 0xFF))
        for (index in 0..query.size) { frame[index + 2] = query[index] }
        stream.writeAll(api.ByteSpan(frame), context: context)
        let lengthBytes = Array<Byte>(2, repeat: 0u8)
        stream.readExact(api.MutableByteSpan(lengthBytes), context: context)
        let length = (Int64(lengthBytes[0]) << 8) | Int64(lengthBytes[1])
        if (length <= 0 || length > DNS_MAX_MESSAGE) { throw dnsMalformed("DNS TCP response length is outside the bounds") }
        let response = Array<Byte>(length, repeat: 0u8)
        stream.readExact(api.MutableByteSpan(response), context: context)
        response
    } finally {
        stream.close()
    }
}

private class DnsCacheEntry {
    /** Cached positive or negative resolution result. */
    public let result: ?api.ResolveResult
    /** Monotonic expiration time for this cache entry. */
    public let expiresAt: MonoTime
    /**
     * Creates one bounded cache entry.
     * @param result Positive result or an explicit negative-cache marker.
     * @param expiresAt Monotonic time at which the entry becomes unusable.
     */
    public init(result: ?api.ResolveResult, expiresAt: MonoTime) {
        this.result = result
        this.expiresAt = expiresAt
    }
}

/** DNS wire client with bounded UDP/TCP fallback and negative caching. */
public class DnsClient <: Resource {
    private let delegate: system_resolver.SystemResolver
    private let mutex = Mutex()
    private let cache = HashMap<String, DnsCacheEntry>()
    private let nextTransaction = AtomicInt64(1)
    /** Resolver configuration captured by this client. */
    public let config: DnsResolverConfig

    /** Creates a bounded DNS client.
     * @param config Resolver configuration.
     * @param queueCapacity Maximum queued lookup requests.
     * @param workerCount Maximum resolver workers.
     */
    public init(
        config!: DnsResolverConfig = DnsResolverConfig(),
        workerCount!: Int64 = 4,
        queueCapacity!: Int64 = 64
    ) {
        this.config = config
        delegate = system_resolver.SystemResolver(workerCount: workerCount, queueCapacity: queueCapacity)
    }

    /** Resolves A/AAAA candidates through DNS wire transport when nameservers
     * are configured, otherwise uses the bounded system adapter.
     * @param context Shared operation context.
     * @param host Host name to resolve.
     * @param options Resolution policy options.
     */
    public func lookup(
        host: api.HostName,
        options!: api.ResolveOptions = api.ResolveOptions(),
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ResolveResult {
        if (config.nameservers.isEmpty()) {
            return delegate.resolve(host, options: options, context: context)
        }
        checkDnsContext(context)
        let startedAt = MonoTime.now()
        let families = match (options.family) {
            case api.ResolveAddressFamily.Ipv4 => [1]
            case api.ResolveAddressFamily.Ipv6 => [28]
            case _ => [1, 28]
        }
        let addresses = ArrayList<api.IpAddress>()
        var shortestTtl: ?UInt32 = None<UInt32>
        var source = api.ResolverSource.System
        var lastResolveError: ?api.ResolveException = None<api.ResolveException>
        for (typeCode in families) {
            try {
                let result = query(host, typeCode, context)
                source = result.source
                for (address in result.addresses) {
                    if (addresses.size < options.maxResults) { addresses.add(address) }
                }
                match (result.expiration) {
                    case Some(expiration) =>
                        let now = MonoTime.now()
                        let seconds = Int64((expiration - now).toNanoseconds() / Duration.second.toNanoseconds())
                        let ttl = if (seconds < 0) { 0u32 } else { UInt32(seconds) }
                        match (shortestTtl) {
                            case Some(value) => if (ttl < value) { shortestTtl = Some(ttl) }
                            case None => shortestTtl = Some(ttl)
                        }
                    case None => ()
                }
            } catch (error: api.ResolveException) {
                lastResolveError = Some(error)
                match (error.resolveCode) {
                    case api.ResolveErrorCode.NameNotFound | api.ResolveErrorCode.NoData => ()
                    case _ => throw error
                }
            }
        }
        if (addresses.isEmpty()) {
            match (lastResolveError) {
                case Some(error) => throw error
                case None => throw api.ResolveException(api.ResolveErrorCode.NoData, "DNS response contained no address records")
            }
        }
        let completedAt = MonoTime.now()
        let expiration = match (shortestTtl) {
            case Some(value) => Some(completedAt + Duration.second * Int64(value))
            case None => None<MonoTime>
        }
        api.ResolveResult(
            addresses.toArray(), host, source,
            expiration: expiration,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
    /** Closes the resolver client idempotently. */
    public func close(): Unit { delegate.close() }
    /** Reports whether the resolver client is closed. */
    public func isClosed(): Bool { delegate.isClosed() }

    private func query(
        host: api.HostName,
        typeCode: Int64,
        context: api.OperationContext
    ): api.ResolveResult {
        let key = "${host.ascii}|${typeCode}"
        match (cached(key)) {
            case Some(entry) =>
                match (entry.result) {
                    case Some(value) => return value
                    case None => throw api.ResolveException(api.ResolveErrorCode.NameNotFound, "DNS negative cache hit")
                }
            case None => ()
        }
        let transactionId = UInt16(UInt64(nextTransaction.fetchAdd(1) & 0xFFFF))
        let queryBytes = buildDnsQuery(host, typeCode, transactionId)
        var lastError: ?Exception = None<Exception>
        for (_ in 0..DNS_QUERY_ATTEMPTS) {
            for (nameserver in config.nameservers) {
                checkDnsContext(context)
                try {
                    let socket = DatagramSocket.bind()
                    try {
                        let _ = socket.sendTo(nameserver, api.ByteSpan(queryBytes), context: context)
                        let received = socket.receive(65507, context: context)
                        if (!dnsSourceMatches(received.source, nameserver)) {
                            throw api.ResolveException(api.ResolveErrorCode.SystemFailure,
                                "DNS response source does not match the queried nameserver")
                        }
                        var responseBytes = received.payload
                        var summary = DnsMessageParser().parse(responseBytes)
                        if (summary.truncated) {
                            responseBytes = queryDnsTcp(nameserver, queryBytes, context)
                            summary = DnsMessageParser().parse(responseBytes)
                        }
                        validateDnsResponse(summary, host, typeCode, transactionId)
                        let result = addressesFromSummary(summary, host, typeCode)
                        if (result.addresses.isEmpty()) {
                            putNegativeCache(key, DNS_NEGATIVE_CACHE_TTL)
                            throw api.ResolveException(api.ResolveErrorCode.NoData,
                                "DNS response contained no address records")
                        }
                        putCache(key, result, DNS_CACHE_TTL)
                        return result
                    } finally {
                        socket.close()
                    }
                } catch (error: api.ResolveException) {
                    lastError = Some(error)
                    match (error.resolveCode) {
                        case api.ResolveErrorCode.NoData | api.ResolveErrorCode.NameNotFound =>
                            putNegativeCache(key, DNS_NEGATIVE_CACHE_TTL)
                        case _ => ()
                    }
                } catch (error: api.NetworkException) {
                    lastError = Some(error)
                }
            }
        }
        match (lastError) {
            case Some(error) => throw error
            case None => throw api.ResolveException(api.ResolveErrorCode.TemporaryFailure, "DNS query failed")
        }
    }

    private func cached(key: String): ?DnsCacheEntry {
        synchronized(mutex) {
            match (cache.get(key)) {
                case Some(entry) =>
                    if (MonoTime.now() < entry.expiresAt) { Some(entry) }
                    else { let _ = cache.remove(key); None<DnsCacheEntry> }
                case None => None<DnsCacheEntry>
            }
        }
    }

    private func putCache(key: String, result: api.ResolveResult, ttl: Duration): Unit {
        synchronized(mutex) { cache[key] = DnsCacheEntry(Some(result), MonoTime.now() + ttl) }
    }

    private func putNegativeCache(key: String, ttl: Duration): Unit {
        synchronized(mutex) { cache[key] = DnsCacheEntry(None<api.ResolveResult>, MonoTime.now() + ttl) }
    }
}

/** Resolver policy wrapper around the bounded resolver contract. */
public class Resolver <: Resource {
    private let dns: DnsClient
    /** Resolver configuration used for policy decisions. */
    public let config: DnsResolverConfig

    /** Creates a resolver policy wrapper.
     * @param config Resolver configuration.
     * @param dns Optional DNS client to reuse.
     */
    public init(config!: DnsResolverConfig = DnsResolverConfig(), dns!: ?DnsClient = None<DnsClient>) {
        this.config = config
        this.dns = match (dns) { case Some(value) => value; case None => DnsClient(config: config) }
    }

    /** Applies the configured bounded policy and delegates DNS queries.
     * @param context Shared operation context.
     * @param host Host name to resolve.
     * @param options Resolution policy options.
     */
    public func resolve(
        host: api.HostName,
        options!: api.ResolveOptions = api.ResolveOptions(),
        context!: api.OperationContext = api.OperationContext.background()
    ): api.ResolveResult {
        checkDnsContext(context)
        let candidates = resolverCandidates(host, config)
        var lastError: ?api.ResolveException = None<api.ResolveException>
        for (candidate in candidates) {
            checkDnsContext(context)
            match (hostsLookup(config.hostsPath, candidate, options, context)) {
                case Some(value) =>
                    println("HOSTDBG resolver returning hosts value")
                    return value
                case None => ()
            }
            try {
                return dns.lookup(candidate, options: options, context: context)
            } catch (error: api.ResolveException) {
                lastError = Some(error)
                match (error.resolveCode) {
                    case api.ResolveErrorCode.NameNotFound | api.ResolveErrorCode.NoData => ()
                    case _ => throw error
                }
            }
        }
        match (lastError) {
            case Some(error) => throw error
            case None => throw api.ResolveException(api.ResolveErrorCode.NameNotFound,
                "resolver exhausted bounded search candidates")
        }
    }
    /** Closes the resolver and its DNS client idempotently. */
    public func close(): Unit { dns.close() }
    /** Reports whether the resolver is closed. */
    public func isClosed(): Bool { dns.isClosed() }
}

private const DNS_MAX_HOSTS_BYTES: Int64 = 1024 * 1024
private const DNS_MAX_HOSTS_LINES: Int64 = 4096

private func dnsMatchesFamily(address: api.IpAddress, requested: api.ResolveAddressFamily): Bool {
    match (requested) {
        case api.ResolveAddressFamily.Any => true
        case api.ResolveAddressFamily.Ipv4 => address.family == api.IpAddressFamily.Ipv4
        case api.ResolveAddressFamily.Ipv6 => address.family == api.IpAddressFamily.Ipv6
    }
}

private func resolverCandidates(host: api.HostName, config: DnsResolverConfig): Array<api.HostName> {
    let candidates = ArrayList<api.HostName>()
    var dots: Int64 = 0
    for (value in host.ascii.toArray()) { if (value == b'.') { dots += 1 } }
    let absoluteFirst = dots >= config.ndots
    if (absoluteFirst) { candidates.add(host) }
    for (suffix in config.searchDomains) {
        if (candidates.size >= 16) { break }
        try {
            let candidate = api.HostName("${host.ascii}.${suffix.ascii}")
            var duplicate = false
            for (existing in candidates) { if (existing == candidate) { duplicate = true; break } }
            if (!duplicate) { candidates.add(candidate) }
        } catch (_: Exception) { () }
    }
    if (!absoluteFirst && candidates.size < 16) {
        var duplicate = false
        for (existing in candidates) { if (existing == host) { duplicate = true; break } }
        if (!duplicate) { candidates.add(host) }
    }
    candidates.toArray()
}

private func hostsLookup(
    path: String,
    host: api.HostName,
    options: api.ResolveOptions,
    context: api.OperationContext
): ?api.ResolveResult {
    if (path.isEmpty() || !exists(path)) { return None<api.ResolveResult> }
    checkDnsContext(context)
    try {
        let info = FileInfo(path)
        if (!info.isRegular() || !info.canRead() || info.size < 0 || info.size > DNS_MAX_HOSTS_BYTES) {
            return None<api.ResolveResult>
        }
        let startedAt = MonoTime.now()
        let addresses = ArrayList<api.IpAddress>()
        var linesRead: Int64 = 0
        for (line in String.fromUtf8(File.readFrom(path)).split("\n")) {
            linesRead += 1
            if (linesRead > DNS_MAX_HOSTS_LINES) { break }
            let withoutComment = if (line.contains("#")) { line.split("#")[0] } else { line }
            let fields = dnsFields(withoutComment)
            if (fields.size < 2) { continue }
            match (parseIpLiteral(fields[0])) {
                case Some(address) =>
                    if (!dnsMatchesFamily(address, options.family)) { continue }
                    for (nameIndex in 1..fields.size) {
                        try {
                            if (api.HostName(fields[nameIndex]) == host) {
                                if (addresses.size < options.maxResults) { addresses.add(address) }
                                break
                            }
                        } catch (_: Exception) { () }
                    }
                case None => ()
            }
            if (addresses.size >= options.maxResults) { break }
        }
        if (addresses.isEmpty()) { None<api.ResolveResult> }
        else {
            let completedAt = MonoTime.now()
            Some(api.ResolveResult(
                addresses.toArray(), host, api.ResolverSource.HostsFile,
                startedAt: startedAt, completedAt: completedAt
            ))
        }
    } catch (_: Exception) {
        None<api.ResolveResult>
    }
}

private func parseIpLiteral(value: String): ?api.IpAddress {
    let parts = value.split(".")
    if (parts.size == 4) {
        let bytes = ArrayList<Byte>()
        for (part in parts) {
            match (Int64.tryParse(part)) {
                case Some(number) =>
                    if (number < 0 || number > 255) { return None<api.IpAddress> }
                    bytes.add(UInt8(UInt64(number)))
                case None => return None<api.IpAddress>
            }
        }
        if (bytes.size == 4) { return Some(api.IpAddress(api.IpAddressFamily.Ipv4, bytes.toArray())) }
    }
    if (value.contains(":")) {
        let groups = value.split(":")
        var emptyIndex: Int64 = -1
        var nonEmpty: Int64 = 0
        for (index in 0..groups.size) {
            if (groups[index].isEmpty()) {
                if (emptyIndex >= 0) {
                    // More than one empty group is only valid when it is the
                    // two-character IPv6 compression marker (::).
                    if (index != emptyIndex + 1) { return None<api.IpAddress> }
                } else {
                    emptyIndex = index
                }
            } else {
                nonEmpty += 1
            }
        }
        let compressed = emptyIndex >= 0
        if ((!compressed && groups.size != 8) || (compressed && nonEmpty >= 8)) {
            return None<api.IpAddress>
        }
        let expanded = ArrayList<Int64>()
        for (index in 0..groups.size) {
            if (compressed && index == emptyIndex) {
                let zeros = 8 - nonEmpty
                for (_ in 0..zeros) { expanded.add(0) }
                if (index + 1 < groups.size && groups[index + 1].isEmpty()) { /* skip second marker half */ }
                continue
            }
            if (compressed && index == emptyIndex + 1 && groups[index].isEmpty()) { continue }
            let group = groups[index]
            if (group.isEmpty() || group.size > 4) { return None<api.IpAddress> }
            var number: Int64 = 0
            for (digit in group.toArray()) {
                let nibble = if (digit >= b'0' && digit <= b'9') {
                    Int64(digit - b'0')
                } else if (digit >= b'a' && digit <= b'f') {
                    Int64(digit - b'a') + 10
                } else if (digit >= b'A' && digit <= b'F') {
                    Int64(digit - b'A') + 10
                } else {
                    -1
                }
                if (nibble < 0) { return None<api.IpAddress> }
                number = number * 16 + nibble
            }
            expanded.add(number)
        }
        if (expanded.size == 8) {
            let bytes = Array<Byte>(16, repeat: 0u8)
            for (index in 0..8) {
                bytes[index * 2] = UInt8(UInt64((expanded[index] >> 8) & 0xFF))
                bytes[index * 2 + 1] = UInt8(UInt64(expanded[index] & 0xFF))
            }
            return Some(api.IpAddress(api.IpAddressFamily.Ipv6, bytes))
        }
    }
    None<api.IpAddress>
}

private func dnsFields(line: String): Array<String> {
    let fields = ArrayList<String>()
    for (field in line.split(" ")) {
        if (!field.isEmpty()) { fields.add(field) }
    }
    fields.toArray()
}
