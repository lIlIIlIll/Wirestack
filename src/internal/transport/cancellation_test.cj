package wirestack.internal.transport

import std.collection.*
import std.sync.AtomicInt64
import std.unittest.*
import std.unittest.testmacro.*

@Test
class CancellationTest {
    @TestCase
    func cancelIsOneWayAndCallbacksRunExactlyOnce(): Unit {
        let source = CancellationSource()
        let first = AtomicInt64(0)
        let second = AtomicInt64(0)
        let _ = source.token.register { => first.fetchAdd(1); () }
        let _ = source.token.register { => second.fetchAdd(1); () }

        @Expect(!source.token.isCancellationRequested)
        source.cancel()
        source.cancel()

        @Expect(source.token.isCancellationRequested)
        @Expect(first.load(), 1)
        @Expect(second.load(), 1)
    }

    @TestCase
    func unregisterIsIdempotentAndPreventsPendingCallback(): Unit {
        let source = CancellationSource()
        let calls = AtomicInt64(0)
        let registration = source.token.register { => calls.fetchAdd(1); () }

        registration.unregister()
        registration.unregister()
        source.cancel()

        @Expect(calls.load(), 0)
    }

    @TestCase
    func alreadyCancelledRegistrationRunsSynchronouslyOnce(): Unit {
        let source = CancellationSource()
        source.cancel()
        let calls = AtomicInt64(0)

        let registration = source.token.register { => calls.fetchAdd(1); () }
        @Expect(calls.load(), 1)
        registration.unregister()
        source.cancel()
        @Expect(calls.load(), 1)
    }

    @TestCase
    func noneTokenRemainsUsableAndNotCancelled(): Unit {
        let token = CancellationToken.none()
        let calls = AtomicInt64(0)
        let registration = token.register { => calls.fetchAdd(1); () }
        let second = token.register { => calls.fetchAdd(1); () }

        @Expect(!token.isCancellationRequested)
        registration.unregister()
        second.unregister()
        @Expect(calls.load(), 0)
    }

    @TestCase
    func oneFailingCallbackDoesNotBlockOtherWaiters(): Unit {
        let source = CancellationSource()
        let calls = AtomicInt64(0)
        let _ = source.token.register { => throw Exception("callback failed") }
        let _ = source.token.register { => calls.fetchAdd(1); () }

        source.cancel()
        @Expect(calls.load(), 1)
    }

    @TestCase
    func concurrentCancelClaimsEveryCallbackExactlyOnce(): Unit {
        for (_ in 0..100) {
            let source = CancellationSource()
            let calls = AtomicInt64(0)
            for (_ in 0..64) {
                let _ = source.token.register { => calls.fetchAdd(1); () }
            }

            let cancellers = ArrayList<Future<Unit>>()
            for (_ in 0..16) {
                cancellers.add(spawn { source.cancel() })
            }
            for (canceller in cancellers) { canceller.get(Duration.second) }

            @Expect(source.token.isCancellationRequested)
            @Expect(calls.load(), 64)
        }
    }

    @TestCase
    func registrationRacingCancellationStillRunsExactlyOnce(): Unit {
        for (_ in 0..100) {
            let source = CancellationSource()
            let calls = AtomicInt64(0)
            let tasks = ArrayList<Future<Unit>>()
            for (_ in 0..64) {
                tasks.add(spawn {
                    let _ = source.token.register { => calls.fetchAdd(1); () }
                })
            }
            for (_ in 0..16) {
                tasks.add(spawn { source.cancel() })
            }
            for (task in tasks) { task.get(Duration.second) }
            source.cancel()

            @Expect(source.token.isCancellationRequested)
            @Expect(calls.load(), 64)
        }
    }

    @TestCase
    func unregisterRacingCancellationIsAtMostOnce(): Unit {
        for (_ in 0..100) {
            let source = CancellationSource()
            let calls = AtomicInt64(0)
            let registration = source.token.register { => calls.fetchAdd(1); () }

            let unregistering = spawn { registration.unregister() }
            let cancelling = spawn { source.cancel() }
            unregistering.get(Duration.second)
            cancelling.get(Duration.second)
            registration.unregister()
            source.cancel()

            @Expect(calls.load() >= 0 && calls.load() <= 1)
        }
    }

    @TestCase
    func callbackMayReenterCancellationAndRegistrationWithoutDeadlock(): Unit {
        let source = CancellationSource()
        let outerCalls = AtomicInt64(0)
        let nestedCalls = AtomicInt64(0)
        let _ = source.token.register { =>
            outerCalls.fetchAdd(1)
            source.cancel()
            let nested = source.token.register { => nestedCalls.fetchAdd(1); () }
            nested.unregister()
        }

        let cancelling = spawn { source.cancel() }
        cancelling.get(Duration.second)
        source.cancel()

        @Expect(outerCalls.load(), 1)
        @Expect(nestedCalls.load(), 1)
    }
}
