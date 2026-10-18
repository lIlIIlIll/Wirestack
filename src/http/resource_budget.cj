package wirestack.http
import std.collection.ArrayList
import std.time.*
import wirestack.internal as internal

/** Per-instance limits shared by every HTTP route and protocol pool. */
public class HttpResourceLimits {
    /** Maximum active physical HTTP connections in this instance. */
    public let maximumConnections: Int64
    /** Maximum active connections for one route and origin owner. */
    public let maximumConnectionsPerRoute: Int64
    /** Maximum active connections across all routes for one origin. */
    public let maximumConnectionsPerOrigin: Int64
    /** Maximum active requests in this instance. */
    public let maximumRequests: Int64
    /** Maximum active requests for one route and origin owner. */
    public let maximumRequestsPerRoute: Int64
    /** Maximum active requests across all routes for one origin. */
    public let maximumRequestsPerOrigin: Int64
    /** Maximum active HTTP/2 streams in this instance. */
    public let maximumStreams: Int64
    /** Maximum active streams for one route and origin owner. */
    public let maximumStreamsPerRoute: Int64
    /** Maximum active streams across all routes for one origin. */
    public let maximumStreamsPerOrigin: Int64
    /** Maximum aggregate bytes held by resource-accounted HTTP/2 buffers. */
    public let maximumManagedBufferBytes: UInt64
    /** Bytes reserved for HTTP/2 general control and cleanup frames. */
    public let reservedControlBufferBytes: UInt64
    /** Maximum DATA bytes attributed to one route/origin owner. */
    public let maximumManagedBufferBytesPerRoute: UInt64
    /** Maximum DATA bytes across all routes for one origin. */
    public let maximumManagedBufferBytesPerOrigin: UInt64
    /** Maximum simultaneous waiters on this instance resource ledger. */
    public let maximumWaiters: Int64
    /** Maximum distinct origin/route owner records retained by the ledger. */
    public let maximumOwners: Int64

    /**
     * Creates validated aggregate ceilings for one HTTP client or server instance.
     * @param maximumConnections Maximum physical connections for the instance.
     * @param maximumConnectionsPerRoute Maximum connections for one route and origin.
     * @param maximumConnectionsPerOrigin Maximum connections across routes for one origin.
     * @param maximumRequests Maximum active requests for the instance.
     * @param maximumRequestsPerRoute Maximum active requests for one route and origin.
     * @param maximumRequestsPerOrigin Maximum active requests across routes for one origin.
     * @param maximumStreams Maximum active HTTP/2 streams for the instance.
     * @param maximumStreamsPerRoute Maximum active streams for one route and origin.
     * @param maximumStreamsPerOrigin Maximum active streams across routes for one origin.
     * @param maximumManagedBufferBytes Aggregate managed HTTP/2 buffer byte ceiling.
     * @param reservedControlBufferBytes Capacity protected from DATA for control and cleanup frames.
     * @param maximumWaiters Maximum waiters on aggregate resource admission.
     * @param maximumManagedBufferBytesPerRoute DATA-buffer bytes for one route and origin.
     * @param maximumManagedBufferBytesPerOrigin DATA-buffer bytes across routes for one origin.
     * @param maximumOwners Maximum concurrent origin/route owner records.
     */
    public init(
        maximumConnections!: Int64 = 128,
        maximumConnectionsPerRoute!: Int64 = 16,
        maximumConnectionsPerOrigin!: Int64 = 32,
        maximumRequests!: Int64 = 4096,
        maximumRequestsPerRoute!: Int64 = 1024,
        maximumRequestsPerOrigin!: Int64 = 2048,
        maximumStreams!: Int64 = 4096,
        maximumStreamsPerRoute!: Int64 = 1024,
        maximumStreamsPerOrigin!: Int64 = 2048,
        maximumManagedBufferBytes!: UInt64 = 134217728u64,
        reservedControlBufferBytes!: UInt64 = 1048576u64,
        maximumWaiters!: Int64 = 256,
        maximumManagedBufferBytesPerRoute!: UInt64 = 33554432u64,
        maximumManagedBufferBytesPerOrigin!: UInt64 = 67108864u64,
        maximumOwners!: Int64 = 8192
    ) {
        if (maximumConnections <= 0 || maximumConnections > 65536 ||
            maximumConnectionsPerRoute <= 0 || maximumConnectionsPerRoute > maximumConnections ||
            maximumConnectionsPerOrigin < maximumConnectionsPerRoute ||
            maximumConnectionsPerOrigin > maximumConnections ||
            maximumRequests <= 0 || maximumRequests > 1000000 ||
            maximumRequestsPerRoute <= 0 || maximumRequestsPerRoute > maximumRequests ||
            maximumRequestsPerOrigin < maximumRequestsPerRoute ||
            maximumRequestsPerOrigin > maximumRequests ||
            maximumStreams <= 0 || maximumStreams > 1000000 ||
            maximumStreamsPerRoute <= 0 || maximumStreamsPerRoute > maximumStreams ||
            maximumStreamsPerOrigin < maximumStreamsPerRoute ||
            maximumStreamsPerOrigin > maximumStreams ||
            maximumManagedBufferBytes == 0u64 || maximumManagedBufferBytes > 1073741824u64 ||
            reservedControlBufferBytes == 0u64 ||
            reservedControlBufferBytes >= maximumManagedBufferBytes ||
            maximumManagedBufferBytesPerRoute == 0u64 ||
            maximumManagedBufferBytesPerRoute > maximumManagedBufferBytes ||
            maximumManagedBufferBytesPerOrigin < maximumManagedBufferBytesPerRoute ||
            maximumManagedBufferBytesPerOrigin > maximumManagedBufferBytes ||
            maximumWaiters <= 0 || maximumWaiters > 65536 ||
            maximumOwners <= 0 || maximumOwners > 65536) {
            throw IllegalArgumentException("HTTP aggregate resource limits are invalid")
        }
        let receiveWindowBudget = UInt64(maximumConnections) * 65535u64
        let cleanupFrameReserve = UInt64(maximumConnections) * 17u64
        if (reservedControlBufferBytes < cleanupFrameReserve) {
            throw IllegalArgumentException("HTTP control reserve cannot guarantee cleanup frames")
        }
        if (maximumManagedBufferBytes - reservedControlBufferBytes <= receiveWindowBudget) {
            throw IllegalArgumentException(
                "HTTP managed-buffer budget must cover receive windows and DATA capacity"
            )
        }
        this.maximumConnections = maximumConnections
        this.maximumConnectionsPerRoute = maximumConnectionsPerRoute
        this.maximumConnectionsPerOrigin = maximumConnectionsPerOrigin
        this.maximumRequests = maximumRequests
        this.maximumRequestsPerRoute = maximumRequestsPerRoute
        this.maximumRequestsPerOrigin = maximumRequestsPerOrigin
        this.maximumStreams = maximumStreams
        this.maximumStreamsPerRoute = maximumStreamsPerRoute
        this.maximumStreamsPerOrigin = maximumStreamsPerOrigin
        this.maximumManagedBufferBytes = maximumManagedBufferBytes
        this.reservedControlBufferBytes = reservedControlBufferBytes
        this.maximumManagedBufferBytesPerRoute = maximumManagedBufferBytesPerRoute
        this.maximumManagedBufferBytesPerOrigin = maximumManagedBufferBytesPerOrigin
        this.maximumWaiters = maximumWaiters
        this.maximumOwners = maximumOwners
    }
    internal func withMaximumConnections(value: Int64): HttpResourceLimits {
        let effective = min(value, maximumConnections)
        HttpResourceLimits(
            maximumConnections: effective,
            maximumConnectionsPerRoute: min(maximumConnectionsPerRoute, effective),
            maximumConnectionsPerOrigin: min(maximumConnectionsPerOrigin, effective),
            maximumRequests: maximumRequests,
            maximumRequestsPerRoute: maximumRequestsPerRoute,
            maximumRequestsPerOrigin: maximumRequestsPerOrigin,
            maximumStreams: maximumStreams,
            maximumStreamsPerRoute: maximumStreamsPerRoute,
            maximumStreamsPerOrigin: maximumStreamsPerOrigin,
            maximumManagedBufferBytes: maximumManagedBufferBytes,
            reservedControlBufferBytes: reservedControlBufferBytes,
            maximumWaiters: maximumWaiters,
            maximumManagedBufferBytesPerRoute: maximumManagedBufferBytesPerRoute,
            maximumManagedBufferBytesPerOrigin: maximumManagedBufferBytesPerOrigin,
            maximumOwners: maximumOwners
        )
    }

    /** Defaults for one client shared by cleartext, proxy, HTTP/1.1, and HTTP/2 pools. */
    public static func clientDefault(): HttpResourceLimits {
        HttpResourceLimits()
    }
 
    /** Defaults for one server; owner quotas stay below the instance DATA ceiling. */
    public static func serverDefault(): HttpResourceLimits {
        HttpResourceLimits(
            maximumConnections: 1024,
            maximumConnectionsPerRoute: 1024,
            maximumConnectionsPerOrigin: 1024,
            maximumManagedBufferBytesPerRoute: 16777216u64,
            maximumManagedBufferBytesPerOrigin: 33554432u64
        )
    }
    internal func toBudgetPolicy(): internal.HttpResourceBudgetPolicy {
        internal.HttpResourceBudgetPolicy(
            maximumConnections,
            maximumConnectionsPerRoute,
            maximumConnectionsPerOrigin,
            maximumRequests,
            maximumRequestsPerRoute,
            maximumRequestsPerOrigin,
            maximumStreams,
            maximumStreamsPerRoute,
            maximumStreamsPerOrigin,
            maximumManagedBufferBytes,
            reservedControlBufferBytes,
            maximumWaiters,
            maximumManagedBufferBytesPerRoute: maximumManagedBufferBytesPerRoute,
            maximumManagedBufferBytesPerOrigin: maximumManagedBufferBytesPerOrigin,
            maximumOwners: maximumOwners
        )
    }
}

/** Current resource counts for one origin and route. */
public struct HttpResourceOwnerSnapshot {
    /** Canonical HTTP origin represented by this owner. */
    public let origin: String
    /** Direct or proxy route identity represented by this owner. */
    public let route: String
    /** Active connections retained for this owner. */
    public let connections: Int64
    /** Connection slots admitted while connect/adoption is incomplete. */
    public let reservedConnections: Int64
    /** Active requests retained for this owner. */
    public let requests: Int64
    /** Active HTTP/2 streams retained for this owner. */
    public let streams: Int64
    /** Stream slots admitted but not yet opened. */
    public let reservedStreams: Int64
    /** Managed HTTP/2 buffer bytes currently attributed to this owner. */
    public let managedBufferBytes: UInt64
    /** Resource-admission waiters currently attributed to this owner. */
    public let waiters: Int64

    /**
     * Creates a point-in-time count for one resource owner.
     * @param origin Canonical HTTP origin.
     * @param route Direct or proxy route identity.
     * @param connections Active connection count.
     * @param requests Active request count.
     * @param streams Active HTTP/2 stream count.
     * @param managedBufferBytes Currently reserved managed-buffer bytes.
     * @param waiters Current resource-admission waiter count.
     * @param reservedConnections Connection slots admitted before activation.
     * @param reservedStreams HTTP/2 stream slots admitted before activation.
     */
    public init(
        origin: String,
        route: String,
        connections: Int64,
        requests: Int64,
        streams: Int64,
        managedBufferBytes: UInt64,
        waiters: Int64,
        reservedConnections!: Int64 = 0,
        reservedStreams!: Int64 = 0
    ) {
        this.origin = origin
        this.route = route
        this.connections = connections
        this.reservedConnections = reservedConnections
        this.requests = requests
        this.streams = streams
        this.reservedStreams = reservedStreams
        this.managedBufferBytes = managedBufferBytes
        this.waiters = waiters
    }
}

/** Point-in-time aggregate resource counters for one client or server instance. */
public struct HttpResourceSnapshot {
    /** Effective per-instance resource ceilings. */
    public let limits: HttpResourceLimits
    /** Current active physical connection count. */
    public let activeConnections: Int64
    /** Connection slots reserved while connect/adoption is incomplete. */
    public let reservedConnections: Int64
    /** Current active request count. */
    public let activeRequests: Int64
    /** Current active HTTP/2 stream count. */
    public let activeStreams: Int64
    /** Stream slots reserved before a protocol stream is opened. */
    public let reservedStreams: Int64
    /** Current bytes admitted to resource-accounted HTTP/2 buffers. */
    public let managedBufferBytes: UInt64
    /** Monotonic instant of the ledger's single-lock snapshot. */
    public let sampledAt: MonoTime
    /** Lifetime ResourceExhausted ledger rejections, sampled under the ledger lock and saturated. */
    public let rejectedOperations: Int64
    /** Measured cancellations whose owned cleanup completed, sampled under the ledger lock. */
    public let completedCancellations: Int64
    /** Most recent measured cleanup latency; absent until a cancellation completes. */
    public let lastCancellationCompletionLatency: ?Duration
    /** Current count of waiters on aggregate resource admission. */
    public let admissionWaiters: Int64
    /** Lifetime maximum of active plus reserved physical connections. */
    public let highWaterConnections: Int64
    /** Highest active request count since instance creation. */
    public let highWaterRequests: Int64
    /** Lifetime maximum of active plus reserved HTTP/2 streams. */
    public let highWaterStreams: Int64
    /** Highest admitted managed-buffer byte count since instance creation. */
    public let highWaterManagedBufferBytes: UInt64
    /** Highest resource-admission waiter count since instance creation. */
    public let highWaterAdmissionWaiters: Int64
    /** Current owner rows with resource or waiter activity; ordering is not stable. */
    public let owners: Array<HttpResourceOwnerSnapshot>

    /**
     * Creates a point-in-time aggregate snapshot.
     * @param limits Effective configured resource ceilings.
     * @param activeConnections Currently active physical connections.
     * @param activeRequests Current active request count.
     * @param activeStreams Current active HTTP/2 streams.
     * @param managedBufferBytes Currently admitted managed HTTP/2 bytes.
     * @param admissionWaiters Current resource-admission waiter count.
     * @param highWaterConnections Lifetime maximum active plus reserved connections.
     * @param highWaterRequests Lifetime maximum active request count.
     * @param highWaterStreams Lifetime maximum active plus reserved stream count.
     * @param highWaterManagedBufferBytes Lifetime maximum managed-buffer bytes.
     * @param highWaterAdmissionWaiters Lifetime maximum admission waiter count.
     * @param owners Current origin/route owner rows with activity.
     * @param sampledAt Monotonic sample instant captured with the ledger counters.
     * @param reservedConnections Current admitted connections not yet activated.
     * @param reservedStreams Current admitted streams not yet activated.
     * @param rejectedOperations Saturating lifetime rejections sampled under the ledger lock.
     * @param completedCancellations Saturating completed-cleanup count sampled under the ledger lock.
     * @param lastCancellationCompletionLatency Last measured cleanup latency, or none before any measurement.
     */
    public init(
        limits: HttpResourceLimits,
        activeConnections: Int64,
        activeRequests: Int64,
        activeStreams: Int64,
        managedBufferBytes: UInt64,
        admissionWaiters: Int64,
        highWaterConnections: Int64,
        highWaterRequests: Int64,
        highWaterStreams: Int64,
        highWaterManagedBufferBytes: UInt64,
        highWaterAdmissionWaiters: Int64,
        owners: Array<HttpResourceOwnerSnapshot>,
        sampledAt!: MonoTime = MonoTime.now(),
        reservedConnections!: Int64 = 0,
        reservedStreams!: Int64 = 0,
        rejectedOperations!: Int64 = 0,
        completedCancellations!: Int64 = 0,
        lastCancellationCompletionLatency!: ?Duration = None<Duration>
    ) {
        this.limits = limits
        this.activeConnections = activeConnections
        this.reservedConnections = reservedConnections
        this.activeRequests = activeRequests
        this.activeStreams = activeStreams
        this.reservedStreams = reservedStreams
        this.managedBufferBytes = managedBufferBytes
        this.sampledAt = sampledAt
        this.rejectedOperations = rejectedOperations
        this.completedCancellations = completedCancellations
        this.lastCancellationCompletionLatency = lastCancellationCompletionLatency
        this.admissionWaiters = admissionWaiters
        this.highWaterConnections = highWaterConnections
        this.highWaterRequests = highWaterRequests
        this.highWaterStreams = highWaterStreams
        this.highWaterManagedBufferBytes = highWaterManagedBufferBytes
        this.highWaterAdmissionWaiters = highWaterAdmissionWaiters
        this.owners = owners
    }
}
internal func resourceSnapshotFromLedger(ledger: internal.HttpResourceBudgetSnapshot): HttpResourceSnapshot {
    let policy = ledger.limits
    let limits = HttpResourceLimits(
        maximumConnections: policy.maximumConnections,
        maximumConnectionsPerRoute: policy.maximumConnectionsPerRoute,
        maximumConnectionsPerOrigin: policy.maximumConnectionsPerOrigin,
        maximumRequests: policy.maximumRequests,
        maximumRequestsPerRoute: policy.maximumRequestsPerRoute,
        maximumRequestsPerOrigin: policy.maximumRequestsPerOrigin,
        maximumStreams: policy.maximumStreams,
        maximumStreamsPerRoute: policy.maximumStreamsPerRoute,
        maximumStreamsPerOrigin: policy.maximumStreamsPerOrigin,
        maximumManagedBufferBytes: policy.maximumManagedBufferBytes,
        reservedControlBufferBytes: policy.reservedControlBufferBytes,
        maximumWaiters: policy.maximumWaiters,
        maximumManagedBufferBytesPerRoute: policy.maximumManagedBufferBytesPerRoute,
        maximumManagedBufferBytesPerOrigin: policy.maximumManagedBufferBytesPerOrigin,
        maximumOwners: policy.maximumOwners
    )
    let owners = ArrayList<HttpResourceOwnerSnapshot>()
    for (owner in ledger.owners) {
        owners.add(HttpResourceOwnerSnapshot(
            owner.origin, owner.route, owner.connections, owner.requests,
            owner.streams, owner.managedBufferBytes, owner.waiters,
            reservedConnections: owner.reservedConnections,
            reservedStreams: owner.reservedStreams
        ))
    }
    HttpResourceSnapshot(
        limits, ledger.activeConnections, ledger.activeRequests, ledger.activeStreams,
        ledger.managedBufferBytes, ledger.admissionWaiters,
        ledger.highWaterConnections, ledger.highWaterRequests, ledger.highWaterStreams,
        ledger.highWaterManagedBufferBytes, ledger.highWaterAdmissionWaiters, owners.toArray(),
        sampledAt: ledger.sampledAt, reservedConnections: ledger.reservedConnections,
        reservedStreams: ledger.reservedStreams, rejectedOperations: ledger.rejectedOperations,
        completedCancellations: ledger.completedCancellations,
        lastCancellationCompletionLatency: ledger.lastCancellationCompletionLatency
    )
}
