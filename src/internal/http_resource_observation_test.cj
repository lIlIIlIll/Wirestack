package wirestack.internal

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func observationLedgerWait(predicate: () -> Bool): Unit {
    let deadline = MonoTime.now() + Duration.second
    while (!predicate()) {
        if (MonoTime.now() >= deadline) { throw TimeoutException() }
        sleep(Duration.millisecond)
    }
}

@Test
class HttpResourceObservationTest {
    @TestCase
    func actualWaiterRejectionsRecoverWithoutCountingProbesOrCancellationRequests(): Unit {
        let budget = HttpResourceBudget(HttpResourceBudgetPolicy(
            1, 1, 1, 1, 1, 1, 1, 1, 1, 65552u64, 17u64, 1))
        let owner = HttpResourceOwnerKey("https://example.test:443", "direct")
        let lease = budget.acquireRequest(owner, api.OperationContext.background())
        let source = api.CancellationSource()
        let waiting = spawn {
            budget.acquireRequest(owner, api.OperationContext(cancellation: source.token))
        }
        try {
            observationLedgerWait({=> budget.snapshot().admissionWaiters == 1 })
            @Expect(budget.tryAcquireRequest(owner).isNone())
            @Expect(budget.snapshot().rejectedOperations, 0)
            let error = @AssertThrows[api.NetworkException](
                budget.acquireRequest(owner, api.OperationContext.background()))
            match (error.code) {
                case api.NetworkErrorCode.ResourceExhausted => ()
                case _ => @Fail("expected exhausted waiter limit")
            }
            @Expect(budget.snapshot().rejectedOperations, 1)
            @Expect(budget.snapshot().completedCancellations, 0)
            @Expect(budget.snapshot().lastCancellationCompletionLatency.isNone())
            let started = MonoTime.now()
            source.cancel()
            @ExpectThrows[api.NetworkException](waiting.get(Duration.second))
            @Expect(budget.snapshot().completedCancellations, 0)
            budget.recordCancellationCompletion(MonoTime.now() - started)
            @Expect(budget.snapshot().completedCancellations, 1)
            @Expect(budget.snapshot().lastCancellationCompletionLatency.isSome())
            @ExpectThrows[IllegalArgumentException](budget.recordCancellationCompletion(-1 * Duration.nanosecond))
            @Expect(budget.snapshot().completedCancellations, 1)
            lease.close(); lease.close()
            let replacement = budget.acquireRequest(owner, api.OperationContext.background())
            replacement.close()
            let final = budget.snapshot()
            @Expect(final.activeRequests, 0)
            @Expect(final.admissionWaiters, 0)
            @Expect(final.owners.isEmpty())
            @Expect(final.rejectedOperations, 1)
        } finally { source.cancel(); lease.close() }
    }

    @TestCase
    func ownerLimitRejectsExactlyOnceAndReclaimsOwnerOnLastLeaseRelease(): Unit {
        let budget = HttpResourceBudget(HttpResourceBudgetPolicy(
            2, 1, 2, 2, 1, 2, 2, 1, 2, 131104u64, 34u64, 1, maximumOwners: 1))
        let alpha = HttpResourceOwnerKey("https://alpha.example.test:443", "direct")
        let beta = HttpResourceOwnerKey("https://beta.example.test:443", "direct")
        let lease = budget.acquireRequest(alpha, api.OperationContext.background())
        try {
            @ExpectThrows[api.NetworkException](budget.acquireRequest(beta, api.OperationContext.background()))
            @Expect(budget.snapshot().rejectedOperations, 1)
            lease.close()
            let admitted = budget.acquireRequest(beta, api.OperationContext.background())
            admitted.close()
            @Expect(budget.snapshot().owners.isEmpty())
            @Expect(budget.snapshot().rejectedOperations, 1)
        } finally { lease.close() }
    }
}
