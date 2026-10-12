package wirestack.internal

import std.collection.ArrayList
import std.sync.*
import wirestack.internal.transport.*
import std.time.*

/** Origin and route identity shared by all protocol-specific pools in one instance. */
public struct HttpResourceOwnerKey <: Equatable<HttpResourceOwnerKey> & Hashable {
    public let origin: String
    public let route: String

    public init(origin: String, route: String) {
        if (origin.isEmpty() || route.isEmpty()) {
            throw IllegalArgumentException("HTTP resource owner requires an origin and route")
        }
        this.origin = origin
        this.route = route
    }

    public operator func ==(other: HttpResourceOwnerKey): Bool {
        origin == other.origin && route == other.route
    }

    public operator func !=(other: HttpResourceOwnerKey): Bool { !(this == other) }

    public func hashCode(): Int64 {
        var hasher = DefaultHasher()
        hasher.write(origin)
        hasher.write(route)
        hasher.finish()
    }
}

internal enum HttpResourceKind {
    | Connection
    | Request
    | Stream
    | Buffer
}
private func sameHttpResourceKind(left: HttpResourceKind, right: HttpResourceKind): Bool {
    match ((left, right)) {
        case (HttpResourceKind.Connection, HttpResourceKind.Connection) => true
        case (HttpResourceKind.Request, HttpResourceKind.Request) => true
        case (HttpResourceKind.Stream, HttpResourceKind.Stream) => true
        case (HttpResourceKind.Buffer, HttpResourceKind.Buffer) => true
        case _ => false
    }
}


private class HttpResourceOwnerCounts {
    let key: HttpResourceOwnerKey
    var connections: Int64 = 0
    var reservedConnections: Int64 = 0
    var requests: Int64 = 0
    var streams: Int64 = 0
    var reservedStreams: Int64 = 0
    var managedBufferBytes: UInt64 = 0u64
    var dataBufferBytes: UInt64 = 0u64
    var receivedBufferBytes: UInt64 = 0u64
    var controlBufferBytes: UInt64 = 0u64
    var cleanupBufferBytes: UInt64 = 0u64
    var waiters: Int64 = 0
    var lastGrantSequence: Int64 = 0

    init(key: HttpResourceOwnerKey) { this.key = key }

    func isEmpty(): Bool {
        connections == 0 && reservedConnections == 0 && requests == 0 &&
            streams == 0 && reservedStreams == 0 && managedBufferBytes == 0u64 &&
            dataBufferBytes == 0u64 && receivedBufferBytes == 0u64 &&
            controlBufferBytes == 0u64 && cleanupBufferBytes == 0u64 && waiters == 0
    }
}
private class HttpResourceWaiter {
    let id: Int64
    let kind: HttpResourceKind
    let owner: HttpResourceOwnerKey
    let amount: UInt64
    let control: Bool

    init(id: Int64, kind: HttpResourceKind, owner: HttpResourceOwnerKey,
        amount: UInt64, control: Bool) {
        this.id = id
        this.kind = kind
        this.owner = owner
        this.amount = amount
        this.control = control
    }
}

/** Per-instance ledger shared by every HTTP pool and HTTP/2 connection. */
public class HttpResourceBudget {
    private let limits: HttpResourceBudgetPolicy
    private let mutex = Mutex()
    private let changed = synchronized(mutex) { mutex.condition() }
    private let owners = ArrayList<HttpResourceOwnerCounts>()
    private let waiters = ArrayList<HttpResourceWaiter>()
    private var nextWaiterId: Int64 = 1
    private var grantSequence: Int64 = 0
    private var activeConnections: Int64 = 0
    private var reservedConnections: Int64 = 0
    private var activeRequests: Int64 = 0
    private var activeStreams: Int64 = 0
    private var reservedStreams: Int64 = 0
    private var managedBufferBytes: UInt64 = 0u64
    private var dataBufferBytes: UInt64 = 0u64
    private var receivedBufferBytes: UInt64 = 0u64
    private var controlBufferBytes: UInt64 = 0u64
    private var cleanupBufferBytes: UInt64 = 0u64
    private var requestAdmissionClosed = false
    private var highWaterConnections: Int64 = 0
    private var highWaterRequests: Int64 = 0
    private var highWaterStreams: Int64 = 0
    private var highWaterManagedBufferBytes: UInt64 = 0u64
    private var highWaterWaiters: Int64 = 0

    public init(limits: HttpResourceBudgetPolicy) { this.limits = limits }

    public func acquireConnection(
        owner: HttpResourceOwnerKey,
        context: OperationContext
    ): HttpResourceLease {
        acquireSlot(HttpResourceKind.Connection, owner, context)
    }

    public func acquireRequest(
        owner: HttpResourceOwnerKey,
        context: OperationContext
    ): HttpResourceLease {
        acquireSlot(HttpResourceKind.Request, owner, context)
    }

    public func acquireStream(
        owner: HttpResourceOwnerKey,
        context: OperationContext
    ): HttpResourceLease {
        acquireSlot(HttpResourceKind.Stream, owner, context)
    }
    protected func stopRequestAdmission(): Unit {
        synchronized(mutex) {
            requestAdmissionClosed = true
            changed.notifyAll()
        }
    }

    private func checkRequestAdmissionOpen(kind: HttpResourceKind): Unit {
        match (kind) {
            case HttpResourceKind.Request =>
                if (requestAdmissionClosed) { throw resourceAdmissionClosed() }
            case _ => ()
        }
    }

    public func tryAcquireConnection(owner: HttpResourceOwnerKey): ?HttpResourceLease {
        tryAcquireSlot(HttpResourceKind.Connection, owner)
    }

    public func tryAcquireRequest(owner: HttpResourceOwnerKey): ?HttpResourceLease {
        tryAcquireSlot(HttpResourceKind.Request, owner)
    }

    public func tryAcquireStream(owner: HttpResourceOwnerKey): ?HttpResourceLease {
        tryAcquireSlot(HttpResourceKind.Stream, owner)
    }

    /** Returns None without allocating a frame when the selected class is full. */
    public func tryAcquireManagedBuffer(
        owner: HttpResourceOwnerKey,
        bytes: UInt64,
        control: Bool,
        cleanup!: Bool = false
    ): ?HttpResourceLease {
        if (bytes == 0u64) { return None<HttpResourceLease> }
        if (cleanup && !control) {
            throw IllegalArgumentException("HTTP cleanup buffers must use the control reserve")
        }
        tryAcquireBuffer(owner, bytes, control, cleanup)
    }

    /** Waits under the caller's original absolute deadline and cancellation token. */
    public func acquireManagedBuffer(
        owner: HttpResourceOwnerKey,
        bytes: UInt64,
        control: Bool,
        context: OperationContext
    ): HttpResourceLease {
        if (bytes == 0u64) { throw IllegalArgumentException("HTTP managed-buffer reservation must be non-zero") }
        acquireBuffer(owner, bytes, control, context)
    }

    /** Accounts received DATA bytes without blocking the connection reader. */
    public func tryReserveReceivedBuffer(owner: HttpResourceOwnerKey, bytes: UInt64): Bool {
        if (bytes == 0u64) { return true }
        synchronized(mutex) {
            if (!canAcquireReceivedBufferLocked(owner, bytes)) { return false }
            let counts = ensureOwnerLocked(owner)
            managedBufferBytes += bytes
            dataBufferBytes += bytes
            receivedBufferBytes += bytes
            counts.managedBufferBytes += bytes
            counts.dataBufferBytes += bytes
            counts.receivedBufferBytes += bytes
            recordHighWaterLocked()
            true
        }
    }
    public func releaseReceivedBuffer(owner: HttpResourceOwnerKey, bytes: UInt64): Unit {
        if (bytes == 0u64) { return }
        synchronized(mutex) {
            let counts = findOwnerLocked(owner)
            if (counts.isNone() || managedBufferBytes < bytes || dataBufferBytes < bytes ||
                receivedBufferBytes < bytes || counts.getOrThrow().managedBufferBytes < bytes ||
                counts.getOrThrow().dataBufferBytes < bytes ||
                counts.getOrThrow().receivedBufferBytes < bytes) {
                throw IllegalStateException("HTTP received-buffer accounting underflow")
            }
            managedBufferBytes -= bytes
            dataBufferBytes -= bytes
            receivedBufferBytes -= bytes
            counts.getOrThrow().managedBufferBytes -= bytes
            counts.getOrThrow().dataBufferBytes -= bytes
            counts.getOrThrow().receivedBufferBytes -= bytes
            removeEmptyOwnerLocked(owner)
            changed.notifyAll()
        }
    }

    public func snapshot(): HttpResourceBudgetSnapshot {
        synchronized(mutex) {
            let sampledAt = MonoTime.now()
            let ownerSnapshots = ArrayList<HttpResourceBudgetOwnerSnapshot>()
            for (counts in owners) {
                if (!counts.isEmpty()) {
                    ownerSnapshots.add(HttpResourceBudgetOwnerSnapshot(
                        counts.key.origin, counts.key.route, counts.connections, counts.requests,
                        counts.streams, counts.managedBufferBytes, counts.waiters,
                        reservedConnections: counts.reservedConnections,
                        reservedStreams: counts.reservedStreams
                    ))
                }
            }
            HttpResourceBudgetSnapshot(
                limits, activeConnections, activeRequests, activeStreams,
                managedBufferBytes, waiters.size, highWaterConnections,
                highWaterRequests, highWaterStreams, highWaterManagedBufferBytes,
                highWaterWaiters, ownerSnapshots.toArray(),
                sampledAt: sampledAt, reservedConnections: reservedConnections,
                reservedStreams: reservedStreams
            )
        }
    }

    /** Releases one lease reference and reclaims its admission on the last close. */

    /** Moves an admitted connection or stream from reserved to active exactly once. */
    internal func activateLease(kind: HttpResourceKind, owner: HttpResourceOwnerKey): Unit {
        synchronized(mutex) {
            let counts = findOwnerLocked(owner)
            if (counts.isNone()) { throw IllegalStateException("HTTP resource owner accounting is missing") }
            let value = counts.getOrThrow()
            match (kind) {
                case HttpResourceKind.Connection =>
                    if (reservedConnections <= 0 || value.reservedConnections <= 0) {
                        throw IllegalStateException("HTTP reserved connection accounting underflow")
                    }
                    reservedConnections--
                    value.reservedConnections--
                    activeConnections++
                    value.connections++
                case HttpResourceKind.Stream =>
                    if (reservedStreams <= 0 || value.reservedStreams <= 0) {
                        throw IllegalStateException("HTTP reserved stream accounting underflow")
                    }
                    reservedStreams--
                    value.reservedStreams--
                    activeStreams++
                    value.streams++
                case _ => ()
            }
            recordHighWaterLocked()
            changed.notifyAll()
        }
    }

    /** Releases one lease reference and reclaims its admission on the last close. */
    internal func releaseLease(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey,
        amount: UInt64,
        activated: Bool,
        control: Bool,
        cleanup: Bool
    ): Unit {
        synchronized(mutex) {
            let result = findOwnerLocked(owner)
            if (result.isNone()) { throw IllegalStateException("HTTP resource owner accounting is missing") }
            let counts = result.getOrThrow()
            match (kind) {
                case HttpResourceKind.Connection =>
                    if (activated) {
                        if (activeConnections <= 0 || counts.connections <= 0) {
                            throw IllegalStateException("HTTP connection accounting underflow")
                        }
                        activeConnections--
                        counts.connections--
                    } else {
                        if (reservedConnections <= 0 || counts.reservedConnections <= 0) {
                            throw IllegalStateException("HTTP reserved connection accounting underflow")
                        }
                        reservedConnections--
                        counts.reservedConnections--
                    }
                case HttpResourceKind.Request =>
                    if (activeRequests <= 0 || counts.requests <= 0) {
                        throw IllegalStateException("HTTP request accounting underflow")
                    }
                    activeRequests--
                    counts.requests--
                case HttpResourceKind.Stream =>
                    if (activated) {
                        if (activeStreams <= 0 || counts.streams <= 0) {
                            throw IllegalStateException("HTTP stream accounting underflow")
                        }
                        activeStreams--
                        counts.streams--
                    } else {
                        if (reservedStreams <= 0 || counts.reservedStreams <= 0) {
                            throw IllegalStateException("HTTP reserved stream accounting underflow")
                        }
                        reservedStreams--
                        counts.reservedStreams--
                    }
                case HttpResourceKind.Buffer =>
                    if (managedBufferBytes < amount || counts.managedBufferBytes < amount) {
                        throw IllegalStateException("HTTP managed-buffer accounting underflow")
                    }
                    if (control) {
                        if (controlBufferBytes < amount || counts.controlBufferBytes < amount ||
                            (cleanup && (cleanupBufferBytes < amount || counts.cleanupBufferBytes < amount))) {
                            throw IllegalStateException("HTTP control-buffer accounting underflow")
                        }
                    } else if (dataBufferBytes < amount || counts.dataBufferBytes < amount) {
                        throw IllegalStateException("HTTP DATA-buffer accounting underflow")
                    }
                    managedBufferBytes -= amount
                    counts.managedBufferBytes -= amount
                    if (control) {
                        controlBufferBytes -= amount
                        counts.controlBufferBytes -= amount
                        if (cleanup) {
                            cleanupBufferBytes -= amount
                            counts.cleanupBufferBytes -= amount
                        }
                    } else {
                        dataBufferBytes -= amount
                        counts.dataBufferBytes -= amount
                    }
            }
            removeEmptyOwnerLocked(owner)
            changed.notifyAll()
        }
    }

    private func acquireSlot(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey,
        context: OperationContext
    ): HttpResourceLease {
        acquire(kind, owner, 0u64, false, context)
    }
    private func acquireBuffer(
        owner: HttpResourceOwnerKey,
        bytes: UInt64,
        control: Bool,
        context: OperationContext
    ): HttpResourceLease {
        acquire(HttpResourceKind.Buffer, owner, bytes, control, context)
    }

    private func acquire(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey,
        amount: UInt64,
        control: Bool,
        context: OperationContext
    ): HttpResourceLease {
        let registration = context.cancellation.register { => wakeWaiters() }
        try {
            synchronized(mutex) {
                checkContext(context)
                if (findOwnerLocked(owner).isNone() && owners.size >= limits.maximumOwners) {
                    throw resourceOwnersExhausted()
                }
                if (nextWaiterLocked(kind).isNone() && canAcquireLocked(kind, owner, amount, control)) {
                    return grantLocked(kind, owner, amount, control, false)
                }
                if (waiters.size >= limits.maximumWaiters) { throw resourceWaitersExhausted() }
                let waiter = HttpResourceWaiter(nextWaiterId, kind, owner, amount, control)
                nextWaiterId++
                waiters.add(waiter)
                ensureOwnerLocked(owner).waiters++
                highWaterWaiters = max(highWaterWaiters, waiters.size)
                changed.notifyAll()
                try {
                    while (true) {
                        checkContext(context)
                        checkRequestAdmissionOpen(kind)
                        if (isNextWaiterLocked(waiter)) {
                            removeWaiterLocked(waiter)
                            let lease = grantLocked(kind, owner, amount, control, false)
                            changed.notifyAll()
                            return lease
                        }
                        waitForChangeLocked(context)
                    }
                    throw IllegalStateException("unreachable HTTP resource admission state")
                } finally {
                    removeWaiterLocked(waiter)
                    changed.notifyAll()
                }
            }
        } finally {
            registration.unregister()
        }
    }

    private func tryAcquireSlot(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey
    ): ?HttpResourceLease {
        synchronized(mutex) {
            if (!canAcquireLocked(kind, owner, 0u64, false) || nextWaiterLocked(kind).isSome()) {
                return None<HttpResourceLease>
            }
            Some<HttpResourceLease>(grantLocked(kind, owner, 0u64, false, false))
        }
    }

    private func tryAcquireBuffer(
        owner: HttpResourceOwnerKey,
        bytes: UInt64,
        control: Bool,
        cleanup: Bool
    ): ?HttpResourceLease {
        synchronized(mutex) {
            if (!canAcquireBufferLocked(owner, bytes, control, cleanup) ||
                (!cleanup && nextWaiterLocked(HttpResourceKind.Buffer).isSome())) {
                return None<HttpResourceLease>
            }
            Some<HttpResourceLease>(grantLocked(HttpResourceKind.Buffer, owner, bytes, control, cleanup))
        }
    }

    private func canAcquireLocked(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey,
        amount: UInt64,
        control: Bool
    ): Bool {
        checkRequestAdmissionOpen(kind)
        if (findOwnerLocked(owner).isNone() && owners.size >= limits.maximumOwners) { return false }
        match (kind) {
            case HttpResourceKind.Connection =>
                activeConnections + reservedConnections < limits.maximumConnections &&
                    ownerCountLocked(owner, kind) < limits.maximumConnectionsPerRoute &&
                    originCountLocked(owner.origin, kind) < limits.maximumConnectionsPerOrigin
            case HttpResourceKind.Request =>
                activeRequests < limits.maximumRequests &&
                    ownerCountLocked(owner, kind) < limits.maximumRequestsPerRoute &&
                    originCountLocked(owner.origin, kind) < limits.maximumRequestsPerOrigin
            case HttpResourceKind.Stream =>
                activeStreams + reservedStreams < limits.maximumStreams &&
                    ownerCountLocked(owner, kind) < limits.maximumStreamsPerRoute &&
                    originCountLocked(owner.origin, kind) < limits.maximumStreamsPerOrigin
            case HttpResourceKind.Buffer => canAcquireBufferLocked(owner, amount, control, false)
        }
    }

    private func canAcquireBufferLocked(
        owner: HttpResourceOwnerKey,
        amount: UInt64,
        control: Bool,
        cleanup: Bool
    ): Bool {
        if (findOwnerLocked(owner).isNone() && owners.size >= limits.maximumOwners) { return false }
        if (control) {
            let cleanupReserve = min(
                UInt64(limits.maximumConnections) * 17u64,
                limits.reservedControlBufferBytes
            )
            if (cleanup) {
                amount <= cleanupReserve - min(cleanupBufferBytes, cleanupReserve) &&
                    amount <= limits.maximumManagedBufferBytes -
                        min(managedBufferBytes, limits.maximumManagedBufferBytes)
            } else {
                let ordinaryBudget = limits.reservedControlBufferBytes - cleanupReserve
                let ordinaryUsed = controlBufferBytes - cleanupBufferBytes
                amount <= ordinaryBudget - min(ordinaryUsed, ordinaryBudget) &&
                    amount <= limits.maximumManagedBufferBytes -
                        min(managedBufferBytes, limits.maximumManagedBufferBytes)
            }
        } else {
            let controlReserve = min(limits.reservedControlBufferBytes, limits.maximumManagedBufferBytes)
            let receiveReserve = min(
                UInt64(limits.maximumConnections) * 65535u64,
                limits.maximumManagedBufferBytes - controlReserve
            )
            let dataBudget = limits.maximumManagedBufferBytes - controlReserve - receiveReserve
            let outboundUsed = dataBufferBytes - receivedBufferBytes
            let routeUsed = ownerDataBufferBytesLocked(owner)
            let originUsed = originDataBufferBytesLocked(owner.origin)
            amount <= dataBudget - min(outboundUsed, dataBudget) &&
                amount <= limits.maximumManagedBufferBytesPerRoute -
                    min(routeUsed, limits.maximumManagedBufferBytesPerRoute) &&
                amount <= limits.maximumManagedBufferBytesPerOrigin -
                    min(originUsed, limits.maximumManagedBufferBytesPerOrigin) &&
                amount <= limits.maximumManagedBufferBytes -
                    min(managedBufferBytes, limits.maximumManagedBufferBytes)
        }
    }

    private func canAcquireReceivedBufferLocked(
        owner: HttpResourceOwnerKey,
        amount: UInt64
    ): Bool {
        if (findOwnerLocked(owner).isNone() && owners.size >= limits.maximumOwners) { return false }
        let controlReserve = min(limits.reservedControlBufferBytes, limits.maximumManagedBufferBytes)
        let receiveReserve = min(
            UInt64(limits.maximumConnections) * 65535u64,
            limits.maximumManagedBufferBytes - controlReserve
        )
        amount <= receiveReserve - min(receivedBufferBytes, receiveReserve) &&
            amount <= limits.maximumManagedBufferBytesPerRoute -
                min(ownerDataBufferBytesLocked(owner), limits.maximumManagedBufferBytesPerRoute) &&
            amount <= limits.maximumManagedBufferBytesPerOrigin -
                min(originDataBufferBytesLocked(owner.origin), limits.maximumManagedBufferBytesPerOrigin) &&
            amount <= limits.maximumManagedBufferBytes -
                min(managedBufferBytes, limits.maximumManagedBufferBytes)
    }

    private func ownerDataBufferBytesLocked(owner: HttpResourceOwnerKey): UInt64 {
        match (findOwnerLocked(owner)) {
            case Some(value) => value.dataBufferBytes
            case None => 0u64
        }
    }

    private func originDataBufferBytesLocked(origin: String): UInt64 {
        var total = 0u64
        for (value in owners) {
            if (value.key.origin == origin) { total += value.dataBufferBytes }
        }
        total
    }

    private func grantLocked(
        kind: HttpResourceKind,
        owner: HttpResourceOwnerKey,
        amount: UInt64,
        control: Bool,
        cleanup: Bool
    ): HttpResourceLease {
        let counts = ensureOwnerLocked(owner)
        grantSequence++
        counts.lastGrantSequence = grantSequence
        match (kind) {
            case HttpResourceKind.Connection =>
                reservedConnections++
                counts.reservedConnections++
            case HttpResourceKind.Request =>
                activeRequests++
                counts.requests++
            case HttpResourceKind.Stream =>
                reservedStreams++
                counts.reservedStreams++
            case HttpResourceKind.Buffer =>
                managedBufferBytes += amount
                counts.managedBufferBytes += amount
                if (control) {
                    controlBufferBytes += amount
                    counts.controlBufferBytes += amount
                    if (cleanup) {
                        cleanupBufferBytes += amount
                        counts.cleanupBufferBytes += amount
                    }
                } else {
                    dataBufferBytes += amount
                    counts.dataBufferBytes += amount
                }
        }
        recordHighWaterLocked()
        HttpResourceLease(HttpResourceLeaseState(this, kind, owner, amount, control, cleanup))
    }

    private func isNextWaiterLocked(waiter: HttpResourceWaiter): Bool {
        match (nextWaiterLocked(waiter.kind)) {
            case Some(next) => next.id == waiter.id
            case None => false
        }
    }

    /** Least-recently-granted eligible owner wins; one busy origin cannot starve others. */
    private func nextWaiterLocked(kind: HttpResourceKind): ?HttpResourceWaiter {
        var selected: ?HttpResourceWaiter = None<HttpResourceWaiter>
        var leastRecent: Int64 = 0
        for (waiter in waiters) {
            if (!sameHttpResourceKind(waiter.kind, kind)) { continue }
            if (!canAcquireLocked(waiter.kind, waiter.owner, waiter.amount, waiter.control)) { continue }
            let counts = findOwnerLocked(waiter.owner).getOrThrow()
            match (selected) {
                case None =>
                    selected = Some(waiter)
                    leastRecent = counts.lastGrantSequence
                case Some(current) =>
                    if (counts.lastGrantSequence < leastRecent ||
                        (counts.lastGrantSequence == leastRecent && waiter.id < current.id)) {
                        selected = Some(waiter)
                        leastRecent = counts.lastGrantSequence
                    }
                }
        }
        selected
    }

    private func waitForChangeLocked(context: OperationContext): Unit {
        match (context.deadline) {
            case Some(deadline) =>
                let remaining = deadline.remaining()
                if (remaining <= Duration.Zero) { throw resourceDeadlineExceeded() }
                changed.wait(timeout: remaining)
            case None => changed.wait()
        }
    }

    private func checkContext(context: OperationContext): Unit {
        if (context.isCancellationRequested()) { throw resourceAdmissionCancelled() }
        if (context.isDeadlineExceeded()) { throw resourceDeadlineExceeded() }
    }

    private func wakeWaiters(): Unit { synchronized(mutex) { changed.notifyAll() } }

    private func removeWaiterLocked(waiter: HttpResourceWaiter): Unit {
        for (index in 0..waiters.size) {
            if (waiters[index].id == waiter.id) {
                let _ = waiters.remove(at: index)
                let counts = findOwnerLocked(waiter.owner)
                if (let Some(value) <- counts) { value.waiters-- }
                removeEmptyOwnerLocked(waiter.owner)
                return
            }
        }
    }
 
    private func ensureOwnerLocked(owner: HttpResourceOwnerKey): HttpResourceOwnerCounts {
        match (findOwnerLocked(owner)) {
            case Some(value) => value
            case None =>
                if (owners.size >= limits.maximumOwners) { throw resourceOwnersExhausted() }
                let value = HttpResourceOwnerCounts(owner)
                value.lastGrantSequence = grantSequence
                owners.add(value)
                value
        }
    }

    private func findOwnerLocked(owner: HttpResourceOwnerKey): ?HttpResourceOwnerCounts {
        for (value in owners) { if (value.key == owner) { return Some(value) } }
        None<HttpResourceOwnerCounts>
    }

    private func ownerCountLocked(owner: HttpResourceOwnerKey, kind: HttpResourceKind): Int64 {
        let value = match (findOwnerLocked(owner)) {
            case Some(counts) => counts
            case None => return 0
        }
        match (kind) {
            case HttpResourceKind.Connection => value.connections + value.reservedConnections
            case HttpResourceKind.Request => value.requests
            case HttpResourceKind.Stream => value.streams + value.reservedStreams
            case HttpResourceKind.Buffer => 0
        }
    }

    private func originCountLocked(origin: String, kind: HttpResourceKind): Int64 {
        var total: Int64 = 0
        for (value in owners) {
            if (value.key.origin != origin) { continue }
            match (kind) {
                case HttpResourceKind.Connection => total += value.connections + value.reservedConnections
                case HttpResourceKind.Request => total += value.requests
                case HttpResourceKind.Stream => total += value.streams + value.reservedStreams
                case HttpResourceKind.Buffer => ()
            }
        }
        total
    }

    private func removeEmptyOwnerLocked(owner: HttpResourceOwnerKey): Unit {
        for (index in 0..owners.size) {
            if (owners[index].key == owner && owners[index].isEmpty()) {
                let _ = owners.remove(at: index)
                return
            }
        }
    }

    private func recordHighWaterLocked(): Unit {
        highWaterConnections = max(highWaterConnections, activeConnections + reservedConnections)
        highWaterRequests = max(highWaterRequests, activeRequests)
        highWaterStreams = max(highWaterStreams, activeStreams + reservedStreams)
        highWaterManagedBufferBytes = max(highWaterManagedBufferBytes, managedBufferBytes)
    }
}

internal class HttpResourceLeaseState {
    private let budget: HttpResourceBudget
    private let kind: HttpResourceKind
    private let owner: HttpResourceOwnerKey
    private let amount: UInt64
    private let control: Bool
    private let cleanup: Bool
    private let mutex = Mutex()
    private var references: Int64 = 1
    private var released = false
    private var activated = true

    init(budget: HttpResourceBudget, kind: HttpResourceKind,
        owner: HttpResourceOwnerKey, amount: UInt64, control: Bool, cleanup: Bool) {
        this.budget = budget
        this.kind = kind
        this.owner = owner
        this.amount = amount
        this.control = control
        this.cleanup = cleanup
        match (kind) {
            case HttpResourceKind.Connection => activated = false
            case HttpResourceKind.Stream => activated = false
            case _ => activated = true
        }
    }

    func activate(): Unit {
        synchronized(mutex) {
            if (released) { throw IllegalStateException("HTTP resource lease is already released") }
            if (!activated) {
                budget.activateLease(kind, owner)
                activated = true
            }
        }
    }

    func addReference(): Unit {
        synchronized(mutex) {
            if (released) { throw IllegalStateException("HTTP resource lease is already released") }
            references++
        }
    }

    func releaseReference(): Unit {
        let outcome = synchronized(mutex) {
            if (released) { (false, activated) }
            else {
                references--
                if (references == 0) { released = true; (true, activated) }
                else { (false, activated) }
            }
        }
        if (outcome[0]) {
            budget.releaseLease(kind, owner, amount, outcome[1], control, cleanup)
        }
    }
}

/** Idempotent reference to one admitted connection, request, stream, or byte span. */
public class HttpResourceLease <: Resource {
    private let state: HttpResourceLeaseState
    private let closed = AtomicBool(false)

    init(state: HttpResourceLeaseState) { this.state = state }

    /** Promotes a reserved connection or stream slot after its resource exists. */
    public func activate(): Unit {
        if (closed.load()) { throw IllegalStateException("HTTP resource lease is already closed") }
        state.activate()
    }

    /** Clones one reference to the admitted unit or byte span. */
    public func retain(): HttpResourceLease {
        if (closed.load()) { throw IllegalStateException("HTTP resource lease is already closed") }
        state.addReference()
        HttpResourceLease(state)
    }

    public func close(): Unit {
        if (!closed.compareAndSwap(false, true)) { return }
        state.releaseReference()
    }

    public func isClosed(): Bool { closed.load() }
}
private func resourceOwnersExhausted(): NetworkException {
    NetworkException(
        NetworkErrorCategory.ResourceExhausted,
        NetworkPhase.PoolAcquire,
        NetworkErrorCode.ResourceExhausted,
        "HTTP aggregate resource owner limit exceeded",
        retryability: Retryability.Temporary
    )
}

private func resourceWaitersExhausted(): NetworkException {
    NetworkException(
        NetworkErrorCategory.ResourceExhausted,
        NetworkPhase.PoolAcquire,
        NetworkErrorCode.ResourceExhausted,
        "HTTP aggregate resource waiter limit exceeded",
        retryability: Retryability.Temporary
    )
}

private func resourceAdmissionClosed(): NetworkException {
    NetworkException(
        NetworkErrorCategory.Closed,
        NetworkPhase.PoolAcquire,
        NetworkErrorCode.Closed,
        "HTTP client request admission is closed",
        retryability: Retryability.Never
    )
}

private func resourceAdmissionCancelled(): NetworkException {
    NetworkException(
        NetworkErrorCategory.Cancelled,
        NetworkPhase.PoolAcquire,
        NetworkErrorCode.Cancelled,
        "HTTP aggregate resource admission cancelled",
        retryability: Retryability.Never
    )
}

private func resourceDeadlineExceeded(): NetworkException {
    NetworkException(
        NetworkErrorCategory.DeadlineExceeded,
        NetworkPhase.PoolAcquire,
        NetworkErrorCode.TimedOut,
        "HTTP aggregate resource admission deadline exceeded",
        retryability: Retryability.Temporary
    )
}
