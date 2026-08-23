package wirestack.internal.connector

import std.collection.ArrayList
import wirestack.internal.common.*

public struct ConnectCandidate {
    public let endpoint: SocketEndpoint
    public let ordinal: Int64
    public let familyOrdinal: Int64

    public init(endpoint: SocketEndpoint, ordinal: Int64, familyOrdinal: Int64) {
        this.endpoint = endpoint
        this.ordinal = ordinal
        this.familyOrdinal = familyOrdinal
    }
}

/** Immutable RFC 8305-style stable interleaving plan. */
public struct AttemptPlan {
    private let ownedCandidates: Array<ConnectCandidate>
    public let attemptDelay: Duration

    public init(candidates: Array<ConnectCandidate>, attemptDelay: Duration) {
        if (candidates.isEmpty()) {
            throw IllegalArgumentException("attempt plan requires at least one candidate")
        }
        if (attemptDelay < Duration.Zero) {
            throw IllegalArgumentException("attemptDelay must be non-negative")
        }
        ownedCandidates = candidates.clone()
        this.attemptDelay = attemptDelay
    }

    public prop candidates: Array<ConnectCandidate> {
        get() { ownedCandidates.clone() }
    }
}

/**
 * Alternates address families while preserving order within each family.
 * Exact duplicates are removed without discarding distinct IPv6 zones.
 */
public func buildAttemptPlan(
    addresses: Array<IpAddress>,
    port: UInt16,
    attemptDelay!: Duration = 250 * Duration.millisecond
): AttemptPlan {
    if (addresses.isEmpty()) {
        throw IllegalArgumentException("cannot build an attempt plan without addresses")
    }
    let unique = deduplicate(addresses)
    let ipv4 = ArrayList<IpAddress>()
    let ipv6 = ArrayList<IpAddress>()
    for (address in unique) {
        match (address.family) {
            case IpAddressFamily.Ipv4 => ipv4.add(address)
            case IpAddressFamily.Ipv6 => ipv6.add(address)
        }
    }

    let preferIpv6 = unique[0].family == IpAddressFamily.Ipv6
    var v4Index: Int64 = 0
    var v6Index: Int64 = 0
    var ordinal: Int64 = 0
    let result = ArrayList<ConnectCandidate>()
    var chooseIpv6 = preferIpv6
    while (v4Index < ipv4.size || v6Index < ipv6.size) {
        if (chooseIpv6 && v6Index < ipv6.size) {
            result.add(ConnectCandidate(SocketEndpoint(ipv6[v6Index], port), ordinal, v6Index))
            v6Index++
            ordinal++
        } else if (!chooseIpv6 && v4Index < ipv4.size) {
            result.add(ConnectCandidate(SocketEndpoint(ipv4[v4Index], port), ordinal, v4Index))
            v4Index++
            ordinal++
        } else if (v6Index < ipv6.size) {
            result.add(ConnectCandidate(SocketEndpoint(ipv6[v6Index], port), ordinal, v6Index))
            v6Index++
            ordinal++
        } else {
            result.add(ConnectCandidate(SocketEndpoint(ipv4[v4Index], port), ordinal, v4Index))
            v4Index++
            ordinal++
        }
        chooseIpv6 = !chooseIpv6
    }
    AttemptPlan(result.toArray(), attemptDelay)
}

private func deduplicate(addresses: Array<IpAddress>): Array<IpAddress> {
    let result = ArrayList<IpAddress>()
    for (candidate in addresses) {
        var duplicate = false
        for (existing in result) {
            if (candidate == existing) {
                duplicate = true
                break
            }
        }
        if (!duplicate) {
            result.add(candidate)
        }
    }
    result.toArray()
}
