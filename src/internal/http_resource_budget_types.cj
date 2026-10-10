package wirestack.internal
import std.time.*

/** Internal cross-module policy values used to keep the ledger below the HTTP facade. */
public struct HttpResourceBudgetPolicy {
    public let maximumConnections: Int64
    public let maximumConnectionsPerRoute: Int64
    public let maximumConnectionsPerOrigin: Int64
    public let maximumRequests: Int64
    public let maximumRequestsPerRoute: Int64
    public let maximumRequestsPerOrigin: Int64
    public let maximumStreams: Int64
    public let maximumStreamsPerRoute: Int64
    public let maximumStreamsPerOrigin: Int64
    public let maximumManagedBufferBytes: UInt64
    public let reservedControlBufferBytes: UInt64
    public let maximumManagedBufferBytesPerRoute: UInt64
    public let maximumManagedBufferBytesPerOrigin: UInt64
    public let maximumOwners: Int64
    public let maximumWaiters: Int64

    public init(maximumConnections: Int64, maximumConnectionsPerRoute: Int64,
        maximumConnectionsPerOrigin: Int64, maximumRequests: Int64,
        maximumRequestsPerRoute: Int64, maximumRequestsPerOrigin: Int64,
        maximumStreams: Int64, maximumStreamsPerRoute: Int64,
        maximumStreamsPerOrigin: Int64, maximumManagedBufferBytes: UInt64,
        reservedControlBufferBytes: UInt64, maximumWaiters: Int64,
        maximumManagedBufferBytesPerRoute!: UInt64 = 33554432u64,
        maximumManagedBufferBytesPerOrigin!: UInt64 = 67108864u64,
        maximumOwners!: Int64 = 8192) {
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
        this.maximumWaiters = maximumWaiters
        this.maximumManagedBufferBytesPerRoute = maximumManagedBufferBytesPerRoute
        this.maximumManagedBufferBytesPerOrigin = maximumManagedBufferBytesPerOrigin
        this.maximumOwners = maximumOwners
    }
}

public struct HttpResourceBudgetOwnerSnapshot {
    public let origin: String
    public let route: String
    public let connections: Int64
    public let reservedConnections: Int64
    public let requests: Int64
    public let streams: Int64
    public let reservedStreams: Int64
    public let managedBufferBytes: UInt64
    public let waiters: Int64

    public init(origin: String, route: String, connections: Int64, requests: Int64,
        streams: Int64, managedBufferBytes: UInt64, waiters: Int64,
        reservedConnections!: Int64 = 0, reservedStreams!: Int64 = 0) {
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

public struct HttpResourceBudgetSnapshot {
    public let limits: HttpResourceBudgetPolicy
    public let activeConnections: Int64
    public let reservedConnections: Int64
    public let activeRequests: Int64
    public let activeStreams: Int64
    public let reservedStreams: Int64
    public let managedBufferBytes: UInt64
    public let sampledAt: MonoTime
    public let admissionWaiters: Int64
    public let highWaterConnections: Int64
    public let highWaterRequests: Int64
    public let highWaterStreams: Int64
    public let highWaterManagedBufferBytes: UInt64
    public let highWaterAdmissionWaiters: Int64
    public let owners: Array<HttpResourceBudgetOwnerSnapshot>
    /** Saturating lifetime rejection count sampled with all ledger counters. */
    public let rejectedOperations: Int64
    /** Saturating number of measured cancellations after owned cleanup. */
    public let completedCancellations: Int64
    /** Last measured cleanup duration; absent before the first completion. */
    public let lastCancellationCompletionLatency: ?Duration
 
    public init(limits: HttpResourceBudgetPolicy, activeConnections: Int64,
        activeRequests: Int64, activeStreams: Int64, managedBufferBytes: UInt64,
        admissionWaiters: Int64, highWaterConnections: Int64, highWaterRequests: Int64,
        highWaterStreams: Int64, highWaterManagedBufferBytes: UInt64,
        highWaterAdmissionWaiters: Int64, owners: Array<HttpResourceBudgetOwnerSnapshot>,
        sampledAt!: MonoTime = MonoTime.now(), reservedConnections!: Int64 = 0,
        reservedStreams!: Int64 = 0, rejectedOperations!: Int64 = 0,
        completedCancellations!: Int64 = 0,
        lastCancellationCompletionLatency!: ?Duration = None<Duration>) {
        this.limits = limits
        this.activeConnections = activeConnections
        this.reservedConnections = reservedConnections
        this.activeRequests = activeRequests
        this.activeStreams = activeStreams
        this.reservedStreams = reservedStreams
        this.managedBufferBytes = managedBufferBytes
        this.sampledAt = sampledAt
        this.admissionWaiters = admissionWaiters
        this.highWaterConnections = highWaterConnections
        this.highWaterRequests = highWaterRequests
        this.highWaterStreams = highWaterStreams
        this.highWaterManagedBufferBytes = highWaterManagedBufferBytes
        this.highWaterAdmissionWaiters = highWaterAdmissionWaiters
        this.owners = owners
        this.rejectedOperations = rejectedOperations
        this.completedCancellations = completedCancellations
        this.lastCancellationCompletionLatency = lastCancellationCompletionLatency
    }
}
