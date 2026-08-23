package wirestack.internal.transport

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

        @Expect(!token.isCancellationRequested)
        registration.unregister()
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
}
