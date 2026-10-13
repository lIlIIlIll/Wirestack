package wirestack

import std.time.MonoTime

/** Read-only real work counters for one resolver owner; scope is owner-local. */
public struct ResolverResourceSnapshot {
    /** Process-local owner identity, never a metric label. */
    public let ownerId: Int64
    /** Admitted queries whose work has not yet completed. */
    public let activeQueries: Int64
    /** Admitted work waiting for a resolver worker or query slot. */
    public let queuedQueries: Int64
    /** Resolver work actually executing, including abandoned native work. */
    public let runningWork: Int64
    /** Current bounded DNS cache entry count. */
    public let cacheEntries: Int64
    /** Cumulative rejected queries, saturated at Int64 maximum. */
    public let rejectedQueries: Int64
    /** Monotonic instant of this owner-local sample. */
    public let sampledAt: MonoTime
    /** True for live counters; false for an immutable last sample of a closed owner. */
    public let isLive: Bool
    /** Creates a resolver-local resource sample.
     * @param ownerId Positive process-local resolver owner identifier.
     * @param activeQueries Admitted queries not yet completed.
     * @param queuedQueries Queries waiting for work admission.
     * @param runningWork Actual running resolver work.
     * @param cacheEntries Current retained DNS cache entries.
     * @param rejectedQueries Lifetime rejection count.
     * @param sampledAt Owner-local monotonic sample instant.
     * @param isLive False only for a closed owner's last actual sample; sampledAt stays unchanged.
     */
    public init(ownerId: Int64, activeQueries: Int64, queuedQueries: Int64, runningWork: Int64,
        cacheEntries: Int64, rejectedQueries: Int64, sampledAt!: MonoTime = MonoTime.now(), isLive!: Bool = true) {
        if (ownerId <= 0 || activeQueries < 0 || queuedQueries < 0 || runningWork < 0 ||
            cacheEntries < 0 || rejectedQueries < 0) {
            throw IllegalArgumentException("resolver resource counters must be non-negative")
        }
        this.ownerId = ownerId; this.activeQueries = activeQueries; this.queuedQueries = queuedQueries
        this.runningWork = runningWork; this.cacheEntries = cacheEntries
        this.rejectedQueries = rejectedQueries; this.sampledAt = sampledAt
        this.isLive = isLive
    }
}

/** Optional real-resource seam. A resolver without this interface is unknown,
 * not zero; callers must not fabricate counters for user-supplied resolvers.
 */
public interface ResolverResourceOwner {
    /** Returns an owner-local read-only sample without starting DNS work. */
    func resolverResourceSnapshot(): ResolverResourceSnapshot
}
