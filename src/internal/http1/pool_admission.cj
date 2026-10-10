package wirestack.internal.http1

import std.collection.ArrayList
import wirestack.internal as internal

internal const HTTP_CONNECTION_MAXIMUM_LIFETIME_SECONDS: Int64 = 600

internal class HttpPoolAdmissionWaiter {
    let id: Int64
    let key: HttpConnectionPoolKey
    let owner: internal.HttpResourceOwnerKey

    init(id: Int64, key: HttpConnectionPoolKey) {
        this.id = id
        this.key = key
        this.owner = httpResourceOwnerForPoolKey(key)
    }
}

private class HttpPoolAdmissionOwnerQueue {
    let owner: internal.HttpResourceOwnerKey
    let waiters = ArrayList<HttpPoolAdmissionWaiter>()

    init(owner: internal.HttpResourceOwnerKey) { this.owner = owner }
}

/** Bounded owner-round-robin order shared by the HTTP/1 and HTTP/2 pools. */
internal class HttpPoolAdmissionQueue {
    private let maximumWaiters: Int64
    private var owners = ArrayList<HttpPoolAdmissionOwnerQueue>()
    private var waiterCount: Int64 = 0
    private var nextId: Int64 = 1

    init(maximumWaiters: Int64) { this.maximumWaiters = maximumWaiters }

    func enqueue(key: HttpConnectionPoolKey): ?Int64 {
        if (waiterCount >= maximumWaiters) { return None<Int64> }
        let owner = httpResourceOwnerForPoolKey(key)
        var ownerQueue: ?HttpPoolAdmissionOwnerQueue = None<HttpPoolAdmissionOwnerQueue>
        for (candidate in owners) {
            if (candidate.owner == owner) {
                ownerQueue = Some(candidate)
                break
            }
        }
        let queue = match (ownerQueue) {
            case Some(value) => value
            case None =>
                let value = HttpPoolAdmissionOwnerQueue(owner)
                owners.add(value)
                value
        }
        let id = nextId
        nextId++
        queue.waiters.add(HttpPoolAdmissionWaiter(id, key))
        waiterCount++
        Some(id)
    }

    func firstEligible(
        isEligible: (HttpConnectionPoolKey) -> Bool
    ): ?HttpPoolAdmissionWaiter {
        for (ownerQueue in owners) {
            for (waiter in ownerQueue.waiters) {
                if (isEligible(waiter.key)) { return Some(waiter) }
            }
        }
        None<HttpPoolAdmissionWaiter>
    }

    func firstEligibleKey(
        isEligible: (HttpConnectionPoolKey) -> Bool
    ): ?HttpConnectionPoolKey {
        match (firstEligible(isEligible)) {
            case Some(waiter) => Some(waiter.key)
            case None => None<HttpConnectionPoolKey>
        }
    }

    /** Removes one waiter; a successful grant rotates its owner behind other owners. */
    func remove(id: Int64, granted: Bool): Bool {
        for (ownerIndex in 0..owners.size) {
            let ownerQueue = owners[ownerIndex]
            for (waiterIndex in 0..ownerQueue.waiters.size) {
                if (ownerQueue.waiters[waiterIndex].id == id) {
                    let _ = ownerQueue.waiters.remove(at: waiterIndex)
                    waiterCount--
                    if (ownerQueue.waiters.isEmpty()) {
                        let _ = owners.remove(at: ownerIndex)
                    } else if (granted) {
                        let rotated = owners.remove(at: ownerIndex)
                        owners.add(rotated)
                    }
                    return true
                }
            }
        }
        false
    }

    func size(): Int64 { waiterCount }
}
