package wirestack.internal.transport

import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class OperationCompletionTest {
    @TestCase
    func completionCleansEveryResourceBeforeTheWinnerCallback(): Unit {
        let completion = OperationCompletion()
        let cancellation = AtomicInt64(0)
        let timer = AtomicInt64(0)
        let waiter = AtomicInt64(0)
        let callbackCalls = AtomicInt64(0)
        let activeSeenByCallback = AtomicInt64(-1)
        let _ = completion.registerCleanup { => cancellation.fetchAdd(1); () }
        let _ = completion.registerCleanup { => timer.fetchAdd(1); () }
        let _ = completion.registerCleanup { => waiter.fetchAdd(1); () }

        @Expect(completion.activeCleanupCount, 3)
        @Expect(completion.tryComplete { =>
            activeSeenByCallback.store(completion.activeCleanupCount)
            callbackCalls.fetchAdd(1)
            ()
        })

        @Expect(completion.isCompleted)
        @Expect(completion.activeCleanupCount, 0)
        @Expect(activeSeenByCallback.load(), 0)
        @Expect(cancellation.load(), 1)
        @Expect(timer.load(), 1)
        @Expect(waiter.load(), 1)
        @Expect(callbackCalls.load(), 1)
        @Expect(!completion.tryComplete { => callbackCalls.fetchAdd(1); () })
        @Expect(callbackCalls.load(), 1)
    }

    @TestCase
    func unregisterAndLateRegistrationHaveExplicitTerminalSemantics(): Unit {
        let completion = OperationCompletion()
        let removedCalls = AtomicInt64(0)
        let removed = completion.registerCleanup { => removedCalls.fetchAdd(1); () }
        removed.unregister()
        removed.unregister()

        @Expect(completion.activeCleanupCount, 0)
        @Expect(completion.tryComplete())
        @Expect(removedCalls.load(), 0)

        let lateCalls = AtomicInt64(0)
        let late = completion.registerCleanup { => lateCalls.fetchAdd(1); () }
        @Expect(lateCalls.load(), 1)
        @Expect(completion.activeCleanupCount, 0)
        late.unregister()
        @Expect(lateCalls.load(), 1)
    }

    @TestCase
    func cleanupCapacityIsPositiveAndHardBounded(): Unit {
        var invalidLimitRejected = false
        try {
            let _ = OperationCompletion(maxCleanups: 0u32)
        } catch (_: IllegalArgumentException) {
            invalidLimitRejected = true
        }
        @Expect(invalidLimitRejected)

        let completion = OperationCompletion(maxCleanups: 2u32)
        let _ = completion.registerCleanup { => }
        let _ = completion.registerCleanup { => }
        @Expect(completion.activeCleanupCount, 2)
        var capacityRejected = false
        try {
            let _ = completion.registerCleanup { => }
        } catch (_: IllegalStateException) {
            capacityRejected = true
        }
        @Expect(capacityRejected)
        @Expect(completion.activeCleanupCount, 2)
        @Expect(completion.tryComplete())
        @Expect(completion.activeCleanupCount, 0)
    }

    @TestCase
    func cleanupFailuresAndReentrancyCannotBlockTerminalProgress(): Unit {
        let completion = OperationCompletion(maxCleanups: 4u32)
        let cleanupCalls = AtomicInt64(0)
        let nestedCalls = AtomicInt64(0)
        let winnerCalls = AtomicInt64(0)
        let reentrantWinners = AtomicInt64(0)
        let _ = completion.registerCleanup { => throw Exception("cleanup failed") }
        let _ = completion.registerCleanup { =>
            cleanupCalls.fetchAdd(1)
            if (completion.tryComplete()) { reentrantWinners.fetchAdd(1); () }
            let late = completion.registerCleanup { => nestedCalls.fetchAdd(1); () }
            late.unregister()
        }

        @Expect(completion.tryComplete { =>
            winnerCalls.fetchAdd(1)
            if (completion.tryComplete()) { reentrantWinners.fetchAdd(1); () }
            ()
        })
        @Expect(cleanupCalls.load(), 1)
        @Expect(nestedCalls.load(), 1)
        @Expect(winnerCalls.load(), 1)
        @Expect(reentrantWinners.load(), 0)
        @Expect(completion.activeCleanupCount, 0)
    }

    @TestCase
    func winnerExceptionDoesNotReopenTheCompletion(): Unit {
        let completion = OperationCompletion()
        var threw = false
        try {
            let _ = completion.tryComplete { => throw Exception("winner failed") }
        } catch (_: Exception) {
            threw = true
        }
        @Expect(threw)
        @Expect(completion.isCompleted)
        @Expect(!completion.tryComplete())
    }

    @TestCase
    func cleanupCountPropertyHoldsAcrossEveryConfiguredOccupancy(): Unit {
        for (count in 0..17) {
            let completion = OperationCompletion(maxCleanups: 16u32)
            let calls = AtomicInt64(0)
            for (_ in 0..count) {
                let _ = completion.registerCleanup { => calls.fetchAdd(1); () }
            }
            @Expect(completion.activeCleanupCount, Int64(count))
            @Expect(completion.tryComplete())
            @Expect(calls.load(), Int64(count))
            @Expect(completion.activeCleanupCount, 0)
        }
    }

    @TestCase
    func concurrentTerminalCallersHaveOneWinner(): Unit {
        for (_ in 0..100) {
            let completion = OperationCompletion()
            let winningReturns = AtomicInt64(0)
            let winningCallbacks = AtomicInt64(0)
            let cleanupCalls = AtomicInt64(0)
            let _ = completion.registerCleanup { => cleanupCalls.fetchAdd(1); () }
            let tasks = ArrayList<Future<Unit>>()
            for (_ in 0..16) {
                tasks.add(spawn {
                    if (completion.tryComplete { => winningCallbacks.fetchAdd(1); () }) {
                        winningReturns.fetchAdd(1)
                        ()
                    }
                })
            }
            for (task in tasks) { task.get(Duration.second) }

            @Expect(winningReturns.load(), 1)
            @Expect(winningCallbacks.load(), 1)
            @Expect(cleanupCalls.load(), 1)
            @Expect(completion.activeCleanupCount, 0)
        }
    }

    @TestCase
    func registrationRacingCompletionIsAlwaysCleanedOnce(): Unit {
        for (_ in 0..100) {
            let completion = OperationCompletion(maxCleanups: 64u32)
            let cleanupCalls = AtomicInt64(0)
            let tasks = ArrayList<Future<Unit>>()
            for (_ in 0..64) {
                tasks.add(spawn {
                    let _ = completion.registerCleanup { => cleanupCalls.fetchAdd(1); () }
                })
            }
            tasks.add(spawn { let _ = completion.tryComplete() })
            for (task in tasks) { task.get(Duration.second) }
            let _ = completion.tryComplete()

            @Expect(cleanupCalls.load(), 64)
            @Expect(completion.activeCleanupCount, 0)
        }
    }

    @TestCase
    func unregisterRacingCompletionRunsCleanupAtMostOnce(): Unit {
        for (_ in 0..100) {
            let completion = OperationCompletion()
            let cleanupCalls = AtomicInt64(0)
            let registration = completion.registerCleanup { => cleanupCalls.fetchAdd(1); () }
            let unregistering = spawn { registration.unregister() }
            let completing = spawn { let _ = completion.tryComplete() }
            unregistering.get(Duration.second)
            completing.get(Duration.second)
            registration.unregister()
            let _ = completion.tryComplete()

            @Expect(cleanupCalls.load() >= 0 && cleanupCalls.load() <= 1)
            @Expect(completion.activeCleanupCount, 0)
        }
    }
}
