package wirestack.http

import std.sync.*
import wirestack as api
import wirestack.internal.http1 as http1

/** Non-sensitive configuration generations and retained route/context counts. */
public struct HttpClientConfigurationSnapshot {
    /** TLS policy generation, initially one. */
    public let tlsGeneration: UInt64
    /** Direct resolver generation, initially one. */
    public let directDnsGeneration: UInt64
    /** Proxy resolver generation, initially one. */
    public let proxyDnsGeneration: UInt64
    /** Current and draining route objects, bounded by 64. */
    public let retainedGenerations: Int64
    /** Distinct retained TLS context owners, bounded by 64. */
    public let retainedTlsContexts: Int64

    internal init(tlsGeneration: UInt64, directDnsGeneration: UInt64,
        proxyDnsGeneration: UInt64, retainedGenerations: Int64, retainedTlsContexts: Int64) {
        this.tlsGeneration = tlsGeneration
        this.directDnsGeneration = directDnsGeneration
        this.proxyDnsGeneration = proxyDnsGeneration
        this.retainedGenerations = retainedGenerations
        this.retainedTlsContexts = retainedTlsContexts
    }
}

// Each immutable route owns a separate pool. Pool identity strings cannot cause
// reuse across snapshots, even when two TLS policies have identical labels.
internal class ClientRotationSlot {
    let client: Resource
    let kind: Int64
    let cancellation = HttpRequestCancellationHandle()
    let tlsOwner: ?ClientTlsOwner
    private let stop: (Bool) -> Unit
    private let empty: () -> Bool
    private let mutex = Mutex()
    private var users: Int64 = 0
    private var retired = false
    private var disposed = false
    private var disposing = false
    private var pendingStops: Int64 = 0
    private var activeStops: Int64 = 0

    init(client: Resource, kind: Int64, stop: (Bool) -> Unit, empty: () -> Bool,
        tlsOwner!: ?ClientTlsOwner = None<ClientTlsOwner>) {
        this.client = client
        this.kind = kind
        this.stop = stop
        this.empty = empty
        this.tlsOwner = tlsOwner
    }

    func hold(): ClientRotationLease {
        synchronized(mutex) {
            if (retired) { throw IllegalStateException("HTTP configuration generation is retired") }
            users++
        }
        ClientRotationLease(this)
    }

    func release(): Unit {
        synchronized(mutex) { users-- }
        let _ = collect()
    }

    func isRetired(): Bool { synchronized(mutex) { retired } }
    func markRetired(): Unit { synchronized(mutex) { retired = true; pendingStops++ } }


    func retire(policy: HttpConfigurationRotation): Unit {
        synchronized(mutex) {
            retired = true
            if (pendingStops > 0) { pendingStops-- }
            activeStops++
        }
        let strict = match (policy) {
            case HttpConfigurationRotation.Graceful => false
            case HttpConfigurationRotation.SecurityReplacement => true
        }
        try {
            if (strict) { let _ = cancellation.cancel() }
            stop(strict)
        } finally {
            synchronized(mutex) { activeStops-- }
            let _ = collect()
        }
    }

    func collect(): Bool {
        let close = synchronized(mutex) {
            if (!disposed && !disposing && pendingStops == 0 && activeStops == 0 && retired && users == 0 && empty()) {
                disposing = true
                true
            } else { false }
        }
        if (close) {
            try { client.close() } finally { synchronized(mutex) { disposed = true } }
        }
        synchronized(mutex) { disposed }
    }
}

internal class ClientRotationLease <: Resource {
    private let slot: ClientRotationSlot
    private let closed = AtomicBool(false)
    init(slot: ClientRotationSlot) { this.slot = slot }
    /** Releases this generation reference once. */
    public func close(): Unit {
        if (closed.compareAndSwap(false, true)) { slot.release() }
    }
    /** Reports whether the generation reference was released. */
    public func isClosed(): Bool { closed.load() }
}

// Resolver replacement shares the immutable TLS context without rebuilding keys
// from a caller-owned HttpClientTlsConfig that the caller may already have closed.
internal class ClientTlsOwner {
    let id: UInt64
    let delegate: Resource
    private let mutex = Mutex()
    private var references: Int64 = 0
    init(id: UInt64, delegate: Resource) { this.id = id; this.delegate = delegate }
    func retain(): Unit { synchronized(mutex) { references++ } }
    func release(): Unit {
        let close = synchronized(mutex) { references--; references == 0 }
        if (close) { delegate.close() }
    }
}

internal class ClientAlpnTlsLease <: http1.HttpAlpnTlsHandshaker {
    let owner: ClientTlsOwner
    private let delegate: http1.HttpAlpnTlsHandshaker
    private let closed = AtomicBool(false)
    init(owner: ClientTlsOwner, delegate: http1.HttpAlpnTlsHandshaker) {
        this.owner = owner; this.delegate = delegate; owner.retain()
    }
    func copyOwner(): ClientAlpnTlsLease { ClientAlpnTlsLease(owner, delegate) }
    /** Immutable TLS context identity used by its route. */
    public prop tlsContextIdentity: String { get() { delegate.tlsContextIdentity } }
    /** Immutable trust-policy identity. */
    public prop trustContextIdentity: String { get() { delegate.trustContextIdentity } }
    /** Authenticated client-identity label. */
    public prop clientIdentity: String { get() { delegate.clientIdentity } }
    /** Build-selected provider identity. */
    public prop providerIdentity: String { get() { delegate.providerIdentity } }
    /** Negotiation policy retained by the snapshot. */
    public prop alpnPolicy: String { get() { delegate.alpnPolicy } }
    /** Negotiates using the retained immutable context.
     * @param host Peer certificate name.
     * @param stream Connected transport.
     * @param context Original deadline and cancellation. */
    public func handshakeNegotiated(host: HostName, stream: api.DuplexTransport,
        context: OperationContext): http1.HttpNegotiatedTlsTransport {
        delegate.handshakeNegotiated(host, stream, context)
    }
    /** Releases this TLS context reference once. */
    public func close(): Unit {
        if (closed.compareAndSwap(false, true)) { owner.release() }
    }
    /** Reports whether this TLS reference was released. */
    public func isClosed(): Bool { closed.load() }
}

internal class ClientProxyTlsLease <: http1.Http1TlsHandshaker {
    let owner: ClientTlsOwner
    private let delegate: http1.Http1TlsHandshaker
    private let closed = AtomicBool(false)
    init(owner: ClientTlsOwner, delegate: http1.Http1TlsHandshaker) {
        this.owner = owner; this.delegate = delegate; owner.retain()
    }
    func copyOwner(): ClientProxyTlsLease { ClientProxyTlsLease(owner, delegate) }
    /** Immutable TLS context identity used by its proxy route. */
    public prop tlsContextIdentity: String { get() { delegate.tlsContextIdentity } }
    /** Immutable trust-policy identity. */
    public prop trustContextIdentity: String { get() { delegate.trustContextIdentity } }
    /** Authenticated client-identity label. */
    public prop clientIdentity: String { get() { delegate.clientIdentity } }
    /** Build-selected provider identity. */
    public prop providerIdentity: String { get() { delegate.providerIdentity } }
    /** Negotiation policy retained by the snapshot. */
    public prop alpnPolicy: String { get() { delegate.alpnPolicy } }
    /** Authenticates the tunnel peer using the retained context.
     * @param host Peer certificate name.
     * @param stream Connected tunnel transport.
     * @param context Original deadline and cancellation. */
    public func handshake(host: HostName, stream: api.DuplexTransport,
        context: OperationContext): api.DuplexTransport { delegate.handshake(host, stream, context) }
    /** Releases this TLS context reference once. */
    public func close(): Unit {
        if (closed.compareAndSwap(false, true)) { owner.release() }
    }
    /** Reports whether this TLS reference was released. */
    public func isClosed(): Bool { closed.load() }
}

// Ownership-transferred duplex sessions are independent of rotation cancellation.
// Their generation remains retained until actual transport/stream cleanup.
internal class ClientRotationTransport <: api.DuplexTransport {
    private let delegate: api.DuplexTransport
    private let lease: ClientRotationLease
    private let closed = AtomicBool(false)
    init(delegate: api.DuplexTransport, lease: ClientRotationLease) {
        this.delegate = delegate; this.lease = lease
    }
    /** Underlying transport metadata. */
    public prop info: api.TransportInfo { get() { delegate.info } }
    /** Reads without extending the caller operation budget.
     * @param destination Caller-owned writable span.
     * @param context Current read deadline and cancellation. */
    public func readSome(destination: api.MutableByteSpan, context!: OperationContext): api.ReadResult {
        delegate.readSome(destination, context: context)
    }
    /** Writes without extending the caller operation budget.
     * @param source Caller-owned readable span.
     * @param context Current write deadline and cancellation. */
    public func writeSome(source: api.ByteSpan, context!: OperationContext): Int64 {
        delegate.writeSome(source, context: context)
    }
    /** Half-closes the requested direction.
     * @param direction Transport direction to stop. */
    public func shutdown(direction: api.ShutdownDirection): Unit { delegate.shutdown(direction) }
    /** Closes the transport and releases its generation once.
     * @param context Bounded close operation. */
    public func close(context: OperationContext): Unit {
        if (closed.compareAndSwap(false, true)) {
            try { delegate.close(context) } finally { lease.close() }
        }
    }
    /** Closes the transport and releases its generation once. */
    public func close(): Unit { close(OperationContext.background()) }
    /** Aborts the transport and releases its generation once.
     * @param reason Structured abort cause. */
    public func abort(reason!: ?api.AbortReason): Unit {
        if (closed.compareAndSwap(false, true)) {
            try { delegate.abort(reason: reason) } finally { lease.close() }
        }
    }
    /** Reports whether this transport owner was closed. */
    public func isClosed(): Bool { closed.load() }
}

internal func emptyClientPool(value: http1.Http1ConnectionPoolSnapshot): Bool {
    value.connections == 0 && value.reservations == 0 && value.waiters == 0
}
