package wirestack.internal

import std.collection.ArrayList
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

@Test
class HttpResourceBudgetTest {
    @TestCase
    func routeOriginAndInstanceCapsCoverConnectionsRequestsAndStreams(): Unit {
        let budget = ledgerTestBudget(3, 1, 2, 2, 1, 2, 2, 1, 2, 64u64, 8u64, 8)
        let alphaDirect = HttpResourceOwnerKey("https://alpha.example:443", "direct")
        let alphaProxy = HttpResourceOwnerKey("https://alpha.example:443", "proxy:proxy.example:3128")
        let betaDirect = HttpResourceOwnerKey("https://beta.example:443", "direct")
        let gammaDirect = HttpResourceOwnerKey("https://gamma.example:443", "direct")

        let directConnection = budget.tryAcquireConnection(alphaDirect).getOrThrow()
        @Expect(budget.tryAcquireConnection(alphaDirect).isNone())
        let proxyConnection = budget.tryAcquireConnection(alphaProxy).getOrThrow()
        @Expect(budget.tryAcquireConnection(HttpResourceOwnerKey(
            "https://alpha.example:443", "proxy:other.example:3128"
        )).isNone())
        let betaConnection = budget.tryAcquireConnection(betaDirect).getOrThrow()
        @Expect(budget.tryAcquireConnection(gammaDirect).isNone())

        let directRequest = budget.tryAcquireRequest(alphaDirect).getOrThrow()
        @Expect(budget.tryAcquireRequest(alphaDirect).isNone())
        let proxyRequest = budget.tryAcquireRequest(alphaProxy).getOrThrow()
        @Expect(budget.tryAcquireRequest(betaDirect).isNone())

        let directStream = budget.tryAcquireStream(alphaDirect).getOrThrow()
        @Expect(budget.tryAcquireStream(alphaDirect).isNone())
        let proxyStream = budget.tryAcquireStream(alphaProxy).getOrThrow()
        @Expect(budget.tryAcquireStream(betaDirect).isNone())

        let reserved = budget.snapshot()
        @Expect(reserved.activeConnections, 0)
        @Expect(reserved.reservedConnections, 3)
        @Expect(reserved.activeStreams, 0)
        @Expect(reserved.reservedStreams, 2)
        @Expect(reserved.highWaterConnections, 3)
        @Expect(reserved.highWaterStreams, 2)
        directConnection.activate()
        proxyConnection.activate()
        betaConnection.activate()
        directStream.activate()
        proxyStream.activate()

        let snapshot = budget.snapshot()
        @Expect(snapshot.sampledAt >= reserved.sampledAt)
        @Expect(snapshot.activeConnections, 3)
        @Expect(snapshot.reservedConnections, 0)
        @Expect(snapshot.activeRequests, 2)
        @Expect(snapshot.activeStreams, 2)
        @Expect(snapshot.reservedStreams, 0)
        @Expect(snapshot.highWaterConnections, 3)
        @Expect(snapshot.highWaterRequests, 2)
        @Expect(snapshot.highWaterStreams, 2)
        @Expect(snapshot.owners.size, 3)
        @Expect(snapshot.owners[0].origin, "https://alpha.example:443")
        @Expect(snapshot.owners[0].route, "direct")
        @Expect(snapshot.owners[0].connections, 1)
        @Expect(snapshot.owners[0].requests, 1)
        @Expect(snapshot.owners[0].streams, 1)
        directConnection.close()
        directConnection.close()
        @Expect(budget.snapshot().activeConnections, 2)
        let replacement = budget.tryAcquireConnection(alphaDirect).getOrThrow()
        replacement.close()
        proxyConnection.close()
        betaConnection.close()
        directRequest.close()
        proxyRequest.close()
        directStream.close()
        proxyStream.close()
        @Expect(budget.snapshot().activeConnections, 0)
        @Expect(budget.snapshot().activeRequests, 0)
        @Expect(budget.snapshot().activeStreams, 0)
        @Expect(budget.snapshot().owners.size, 0)
    }

    @TestCase
    func receivedDataHonorsRouteOriginAndAggregateOwnerBudgets(): Unit {
        let budget = HttpResourceBudget(HttpResourceBudgetPolicy(
            1, 1, 1, 1, 1, 1, 1, 1, 1, 65552u64, 17u64, 4,
            maximumManagedBufferBytesPerRoute: 4u64,
            maximumManagedBufferBytesPerOrigin: 6u64,
            maximumOwners: 3
        ))
        let direct = HttpResourceOwnerKey("https://alpha.example:443", "direct")
        let proxy = HttpResourceOwnerKey("https://alpha.example:443", "proxy:edge.example:3128")
        let otherOrigin = HttpResourceOwnerKey("https://beta.example:443", "direct")

        @Expect(budget.tryReserveReceivedBuffer(direct, 4u64))
        @Expect(!budget.tryReserveReceivedBuffer(direct, 1u64))
        @Expect(budget.tryReserveReceivedBuffer(proxy, 2u64))
        @Expect(!budget.tryReserveReceivedBuffer(proxy, 1u64))
        @Expect(budget.tryReserveReceivedBuffer(otherOrigin, 4u64))
        let saturated = budget.snapshot()
        @Expect(saturated.managedBufferBytes, 10u64)
        @Expect(saturated.owners.size, 3)

        budget.releaseReceivedBuffer(direct, 4u64)
        budget.releaseReceivedBuffer(proxy, 2u64)
        budget.releaseReceivedBuffer(otherOrigin, 4u64)
        @Expect(budget.snapshot().managedBufferBytes, 0u64)
        @Expect(budget.snapshot().owners.size, 0)
    }

    @TestCase
    func retainedReceivedBufferCanMoveToTheLateStreamAuthority(): Unit {
        let budget = HttpResourceBudget(HttpResourceBudgetPolicy(
            1, 1, 1, 1, 1, 1, 1, 1, 1, 65552u64, 17u64, 4,
            maximumManagedBufferBytesPerRoute: 4u64,
            maximumManagedBufferBytesPerOrigin: 6u64,
            maximumOwners: 3
        ))
        let listener = HttpResourceOwnerKey("server", "listener")
        let authority = HttpResourceOwnerKey("example.com", "listener")
        @Expect(budget.tryReserveReceivedBuffer(listener, 4u64))
        @Expect(budget.reattributeReceivedBuffer(listener, authority, 4u64))
        let moved = budget.snapshot()
        @Expect(moved.managedBufferBytes, 4u64)
        @Expect(moved.owners.size, 1)
        @Expect(moved.owners[0].origin, "example.com")
        @Expect(moved.owners[0].managedBufferBytes, 4u64)
        @Expect(!budget.reattributeReceivedBuffer(listener, authority, 1u64))
        @Expect(!budget.reattributeReceivedBuffer(
            authority, HttpResourceOwnerKey("other.example", "listener"), 5u64
        ))
        budget.releaseReceivedBuffer(authority, 4u64)
        @Expect(budget.snapshot().managedBufferBytes, 0u64)
        @Expect(budget.snapshot().owners.size, 0)
    }

    @TestCase
    func ownerRowsStayWithinConfiguredBoundAndRecycleAfterRelease(): Unit {
        let budget = HttpResourceBudget(HttpResourceBudgetPolicy(
            1, 1, 1, 2, 2, 2, 1, 1, 1, 65552u64, 17u64, 4,
            maximumOwners: 1
        ))
        let first = HttpResourceOwnerKey("https://first.example:443", "direct")
        let second = HttpResourceOwnerKey("https://second.example:443", "direct")
        let lease = budget.tryAcquireRequest(first).getOrThrow()
        @Expect(budget.snapshot().owners.size, 1)
        @Expect(budget.tryAcquireRequest(second).isNone())

        lease.close()
        @Expect(budget.snapshot().owners.size, 0)
        let replacement = budget.tryAcquireRequest(second).getOrThrow()
        replacement.close()
        @Expect(budget.snapshot().owners.size, 0)
    }

    @TestCase
    func eligibleOtherOwnerPreventsOneBusyOwnerFromStarvingWaiters(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 1, 1, 1, 1, 1, 1, 64u64, 8u64, 3)
        let busyOwner = HttpResourceOwnerKey("https://busy.example:443", "direct")
        let otherOwner = HttpResourceOwnerKey("https://other.example:443", "direct")
        let held = budget.tryAcquireRequest(busyOwner).getOrThrow()
        let order = AtomicInt64(0)
        let other = AtomicInt64(0)
        let busyOne = spawn {
            let lease = budget.acquireRequest(busyOwner, OperationContext.background())
            let _ = order.fetchAdd(1)
            lease.close()
        }
        let busyTwo = spawn {
            let lease = budget.acquireRequest(busyOwner, OperationContext.background())
            let _ = order.fetchAdd(1)
            lease.close()
        }
        let otherWaiter = spawn {
            let lease = budget.acquireRequest(otherOwner, OperationContext.background())
            other.store(order.fetchAdd(1) + 1)
            lease.close()
        }

        @Expect(waitForBudgetWaiters(budget, 3, Duration.second))
        held.close()
        busyOne.get(Duration.second)
        busyTwo.get(Duration.second)
        otherWaiter.get(Duration.second)

        // Concurrent arrival order is unspecified; avoid busy-owner starvation.
        @Expect(other.load() > 0)
        @Expect(other.load() <= 2)
        @Expect(budget.snapshot().admissionWaiters, 0)
        @Expect(budget.snapshot().activeRequests, 0)
    }

    @TestCase
    func cancelledAdmissionRemovesItsWaiterAndWaiterCapIsHard(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 4, 2, 4, 4, 2, 4, 64u64, 8u64, 1)
        let holder = HttpResourceOwnerKey("https://holder.example:443", "direct")
        let waiter = HttpResourceOwnerKey("https://waiter.example:443", "direct")
        let overflow = HttpResourceOwnerKey("https://overflow.example:443", "direct")
        let heldConnection = budget.tryAcquireConnection(holder).getOrThrow()
        let cancellation = CancellationSource()
        let wasCancelled = AtomicBool(false)
        let waiting = spawn {
            try {
                let _ = budget.acquireConnection(
                    waiter, OperationContext(cancellation: cancellation.token)
                )
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Cancelled => wasCancelled.store(true)
                    case _ => ()
                }
            }
        }

        @Expect(waitForBudgetWaiters(budget, 1, Duration.second))
        expectResourceWaiterExhaustion({ =>
            let _ = budget.acquireConnection(overflow, OperationContext.background())
        })
        @Expect(budget.snapshot().admissionWaiters, 1)
        cancellation.cancel()
        waiting.get(Duration.second)
        @Expect(wasCancelled.load())
        @Expect(budget.snapshot().admissionWaiters, 0)

        heldConnection.close()
        let admittedAfterRelease = budget.tryAcquireConnection(waiter).getOrThrow()
        admittedAfterRelease.close()
        @Expect(budget.snapshot().activeConnections, 0)
        @Expect(budget.snapshot().admissionWaiters, 0)
        @Expect(budget.snapshot().owners.size, 0)
    }
    @TestCase
    func deadlineAdmissionRemovesWaiterWithoutGrantingResource(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 1, 1, 1, 1, 1, 1, 64u64, 8u64, 2)
        let holder = HttpResourceOwnerKey("https://holder.example:443", "direct")
        let waiter = HttpResourceOwnerKey("https://waiter.example:443", "direct")
        let heldRequest = budget.tryAcquireRequest(holder).getOrThrow()
        let timedOut = AtomicBool(false)
        let waiting = spawn {
            try {
                let _ = budget.acquireRequest(waiter, OperationContext(
                    deadline: Some(Deadline.after(50 * Duration.millisecond))
                ))
            } catch (error: NetworkException) {
                match (error.category) {
                    case NetworkErrorCategory.DeadlineExceeded =>
                        match (error.code) {
                            case NetworkErrorCode.TimedOut => timedOut.store(true)
                            case _ => ()
                        }
                    case _ => ()
                }
            }
        }

        @Expect(waitForBudgetWaiters(budget, 1, Duration.second))
        waiting.get(2 * Duration.second)
        @Expect(timedOut.load())
        @Expect(budget.snapshot().admissionWaiters, 0)
        @Expect(budget.snapshot().activeRequests, 1)
        @Expect(budget.snapshot().owners.size, 1)
        heldRequest.close()
        @Expect(budget.snapshot().activeRequests, 0)
        @Expect(budget.snapshot().owners.size, 0)
    }
    @TestCase
    func grantRacingCancellationCompletesAndReleasesExactlyOnce(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 1, 1, 1, 1, 1, 1, 64u64, 8u64, 1)
        let owner = HttpResourceOwnerKey("https://race.example:443", "direct")
        for (_ in 0..32) {
            let holder = budget.tryAcquireRequest(owner).getOrThrow()
            let cancellation = CancellationSource()
            let granted = AtomicBool(false)
            let cancelled = AtomicBool(false)
            let unexpected = AtomicBool(false)
            let waiter = spawn {
                try {
                    let lease = budget.acquireRequest(
                        owner,
                        OperationContext(cancellation: cancellation.token)
                    )
                    granted.store(true)
                    lease.close()
                } catch (e: NetworkException) {
                    match (e.code) {
                        case NetworkErrorCode.Cancelled => cancelled.store(true)
                        case _ => unexpected.store(true)
                    }
                }
            }
            @Expect(waitForBudgetWaiters(budget, 1, Duration.second))
            let release = spawn { holder.close() }
            let cancel = spawn { let _ = cancellation.cancel() }
            release.get(Duration.second)
            cancel.get(Duration.second)
            waiter.get(Duration.second)

            @Expect(granted.load() || cancelled.load())
            @Expect(!(granted.load() && cancelled.load()))
            @Expect(!unexpected.load())
            let snapshot = budget.snapshot()
            @Expect(snapshot.activeRequests, 0)
            @Expect(snapshot.admissionWaiters, 0)
            @Expect(snapshot.owners.size, 0)
        }
    }
    @TestCase
    func concurrentRequestStormNeverExceedsAggregateOrOwnerCaps(): Unit {
        let budget = ledgerTestBudget(2, 1, 2, 32, 16, 16, 8, 4, 8, 262144u64, 4096u64, 8)
        let alpha = HttpResourceOwnerKey("https://alpha.example:443", "direct")
        let beta = HttpResourceOwnerKey("https://beta.example:443", "proxy:edge.example:3128")
        let leases = ArrayList<HttpResourceLease>()
        let rejected = ArrayList<Bool>()
        let resultsMutex = Mutex()
        let workers = ArrayList<Future<Unit>>()
        for (worker in 0..16) {
            workers.add(spawn {
                let owner = if (worker % 2 == 0) { alpha } else { beta }
                for (_ in 0..32) {
                    let lease = budget.tryAcquireRequest(owner)
                    synchronized(resultsMutex) {
                        match (lease) {
                            case Some(value) => leases.add(value)
                            case None => rejected.add(true)
                        }
                    }
                }
            })
        }
        for (worker in workers) { worker.get(Duration.second) }

        let saturated = budget.snapshot()
        @Expect(leases.size, 32)
        @Expect(rejected.size, 480)
        @Expect(saturated.activeRequests, 32)
        @Expect(saturated.highWaterRequests, 32)
        @Expect(saturated.owners.size, 2)
        for (owner in saturated.owners) { @Expect(owner.requests, 16) }

        for (lease in leases) { lease.close() }
        let released = budget.snapshot()
        @Expect(released.activeRequests, 0)
        @Expect(released.owners.size, 0)
    }
    @TestCase
    func closeAdmissionWakesRequestWaitersAndPreservesHeldLease(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 1, 1, 1, 1, 1, 1, 64u64, 8u64, 1)
        let owner = HttpResourceOwnerKey("https://close.example:443", "direct")
        let held = budget.tryAcquireRequest(owner).getOrThrow()
        let closed = AtomicBool(false)
        let unexpected = AtomicBool(false)
        let waiter = spawn {
            try {
                let lease = budget.acquireRequest(owner, OperationContext.background())
                lease.close()
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => closed.store(true)
                    case _ => unexpected.store(true)
                }
            }
        }

        @Expect(waitForBudgetWaiters(budget, 1, Duration.second))
        budget.closeAdmission()
        waiter.get(Duration.second)

        @Expect(closed.load())
        @Expect(!unexpected.load())
        @Expect(budget.snapshot().activeRequests, 1)
        @Expect(budget.snapshot().admissionWaiters, 0)
        held.close()
        @Expect(budget.snapshot().activeRequests, 0)
        @Expect(budget.snapshot().owners.size, 0)

        let rejectedAfterClose = AtomicBool(false)
        try {
            match (budget.tryAcquireRequest(owner)) {
                case Some(lease) => lease.close()
                case None => ()
            }
        } catch (error: NetworkException) {
            match (error.code) {
                case NetworkErrorCode.Closed => rejectedAfterClose.store(true)
                case _ => unexpected.store(true)
            }
        }
        @Expect(rejectedAfterClose.load())
        @Expect(!unexpected.load())
    }
    @TestCase
    func closeAdmissionWakesConnectionStreamAndBufferWaiters(): Unit {
        let budget = ledgerTestBudget(1, 1, 1, 1, 1, 1, 1, 1, 1, 64u64, 8u64, 4)
        let owner = HttpResourceOwnerKey("https://close.example:443", "direct")
        let heldConnection = budget.tryAcquireConnection(owner).getOrThrow()
        let heldStream = budget.tryAcquireStream(owner).getOrThrow()
        let heldBuffer = budget.tryAcquireManagedBuffer(owner, 8u64, true, cleanup: true).getOrThrow()
        let closedConnections = AtomicBool(false)
        let closedStreams = AtomicBool(false)
        let closedBuffers = AtomicBool(false)
        let unexpected = AtomicBool(false)
        let connectionWaiter = spawn {
            try {
                let lease = budget.acquireConnection(owner, OperationContext.background())
                lease.close()
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => closedConnections.store(true)
                    case _ => unexpected.store(true)
                }
            }
        }
        let streamWaiter = spawn {
            try {
                let lease = budget.acquireStream(owner, OperationContext.background())
                lease.close()
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => closedStreams.store(true)
                    case _ => unexpected.store(true)
                }
            }
        }
        let bufferWaiter = spawn {
            try {
                let lease = budget.acquireManagedBuffer(
                    owner, 8u64, true, OperationContext.background()
                )
                lease.close()
            } catch (error: NetworkException) {
                match (error.code) {
                    case NetworkErrorCode.Closed => closedBuffers.store(true)
                    case _ => unexpected.store(true)
                }
            }
        }
        @Expect(waitForBudgetWaiters(budget, 3, Duration.second))
        budget.closeAdmission()
        connectionWaiter.get(Duration.second)
        streamWaiter.get(Duration.second)
        bufferWaiter.get(Duration.second)
        @Expect(closedConnections.load())
        @Expect(closedStreams.load())
        @Expect(closedBuffers.load())
        @Expect(!unexpected.load())
        let retained = budget.snapshot()
        @Expect(retained.admissionWaiters, 0)
        @Expect(retained.reservedConnections, 1)
        @Expect(retained.reservedStreams, 1)
        @Expect(retained.managedBufferBytes, 8u64)
        heldConnection.close()
        heldStream.close()
        heldBuffer.close()
        @Expect(budget.snapshot().owners.size, 0)
    }
    @TestCase
    func retainedLeaseClosesExactlyOnceAcrossConcurrentOwners(): Unit {
        let budget = ledgerTestBudget(4, 2, 4, 4, 2, 4, 4, 2, 4, 64u64, 8u64, 4)
        let owner = HttpResourceOwnerKey("https://lease.example:443", "direct")
        let lease = budget.tryAcquireStream(owner).getOrThrow()
        let retained = lease.retain()
        let firstCloser = spawn {
            lease.close()
            lease.close()
        }
        let secondCloser = spawn {
            retained.close()
            retained.close()
        }

        firstCloser.get(Duration.second)
        secondCloser.get(Duration.second)
        @Expect(lease.isClosed())
        @Expect(retained.isClosed())
        @Expect(budget.snapshot().activeStreams, 0)
        @Expect(budget.snapshot().owners.size, 0)
    }
}

private func ledgerTestBudget(
    maximumConnections: Int64,
    maximumConnectionsPerRoute: Int64,
    maximumConnectionsPerOrigin: Int64,
    maximumRequests: Int64,
    maximumRequestsPerRoute: Int64,
    maximumRequestsPerOrigin: Int64,
    maximumStreams: Int64,
    maximumStreamsPerRoute: Int64,
    maximumStreamsPerOrigin: Int64,
    maximumManagedBufferBytes: UInt64,
    reservedControlBufferBytes: UInt64,
    maximumWaiters: Int64
): HttpResourceBudget {
    HttpResourceBudget(HttpResourceBudgetPolicy(
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
        maximumWaiters
    ))
}

private func waitForBudgetWaiters(
    budget: HttpResourceBudget,
    expected: Int64,
    timeout: Duration
): Bool {
    let expiresAt = MonoTime.now() + timeout
    while (true) {
        if (budget.snapshot().admissionWaiters >= expected) { return true }
        if (expiresAt - MonoTime.now() <= Duration.Zero) { return false }
    }
    false
}

private func expectResourceWaiterExhaustion(action: () -> Unit): Unit {
    var exhausted = false
    try { action() } catch (error: NetworkException) {
        match (error.code) {
            case NetworkErrorCode.ResourceExhausted => exhausted = true
            case _ => ()
        }
    }
    @Expect(exhausted)
}
