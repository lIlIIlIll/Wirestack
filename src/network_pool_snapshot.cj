package wirestack

import std.time.MonoTime

/** Read-only physical pool and stream counters, sampled at actual pool owners. */
public struct NetworkConnectionPoolSnapshot {
    /** Physical connections with an admitted exchange or transferred session. */
    public let leasedConnections: Int64
    /** Live physical connections immediately reusable without an active exchange. */
    public let idleConnections: Int64
    /** Reserved physical connection creations not yet published. */
    public let connectingConnections: Int64
    /** Requests actually waiting for this pool's connection or stream capacity. */
    public let queuedRequests: Int64
    /** Protocol streams actually opened and not yet released. */
    public let activeStreams: Int64
    /** Stream claims reserved before protocol opening. */
    public let reservedStreams: Int64
    /** Physical connections that stopped accepting new exchanges. */
    public let drainingConnections: Int64
    /** Monotonic sample instant; combined pools are not atomically sampled. */
    public let sampledAt: MonoTime
    /** Creates pool-local counters.
     * @param leasedConnections Physical connections with admitted work.
     * @param idleConnections Reusable physical connections with no active exchange.
     * @param connectingConnections Actual connection creation reservations.
     * @param queuedRequests Actual connection or stream capacity waiters.
     * @param activeStreams Actually opened protocol streams.
     * @param reservedStreams Pending protocol stream claims.
     * @param drainingConnections Physical connections declining new exchanges.
     * @param sampledAt Owner-local monotonic sample instant.
     */
    public init(leasedConnections!: Int64 = 0, idleConnections!: Int64 = 0,
        connectingConnections!: Int64 = 0, queuedRequests!: Int64 = 0,
        activeStreams!: Int64 = 0, reservedStreams!: Int64 = 0,
        drainingConnections!: Int64 = 0, sampledAt!: MonoTime = MonoTime.now()) {
        if (leasedConnections < 0 || idleConnections < 0 || connectingConnections < 0 ||
            queuedRequests < 0 || activeStreams < 0 || reservedStreams < 0 || drainingConnections < 0) {
            throw IllegalArgumentException("pool observation counters must be non-negative")
        }
        this.leasedConnections = leasedConnections; this.idleConnections = idleConnections
        this.connectingConnections = connectingConnections; this.queuedRequests = queuedRequests
        this.activeStreams = activeStreams; this.reservedStreams = reservedStreams
        this.drainingConnections = drainingConnections; this.sampledAt = sampledAt
    }
    /** Combines two separately sampled owner counters without claiming atomicity.
     * @param other Another bounded pool-local sample.
     */
    public func combinedWith(other: NetworkConnectionPoolSnapshot): NetworkConnectionPoolSnapshot {
        NetworkConnectionPoolSnapshot(leasedConnections: leasedConnections + other.leasedConnections,
            idleConnections: idleConnections + other.idleConnections,
            connectingConnections: connectingConnections + other.connectingConnections,
            queuedRequests: queuedRequests + other.queuedRequests,
            activeStreams: activeStreams + other.activeStreams, reservedStreams: reservedStreams + other.reservedStreams,
            drainingConnections: drainingConnections + other.drainingConnections)
    }
}
