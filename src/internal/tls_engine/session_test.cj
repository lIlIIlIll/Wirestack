package wirestack.internal.tls_engine

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.transport.*

private class FakeSessionClock <: MonotonicClock {
    private var current: MonoTime

    init(start: MonoTime) { current = start }
    public func now(): MonoTime { current }
    func advance(duration: Duration): Unit { current = current + duration }
}

@Test
class TlsSessionStoreTest {
    @TestCase
    func boundedLruExpiryAndSingleUseAreDeterministic(): Unit {
        let clock = FakeSessionClock(MonoTime.now())
        let store = TlsSessionStore(
            maximumEntries: 2,
            maximumEncodedBytes: 8,
            maximumOneSessionBytes: 4,
            clock: clock
        )
        let first = testSessionKey("first")
        let second = testSessionKey("second")
        let third = testSessionKey("third")
        store.put(first, [1, 2, 3, 4], 10u64, false)
        store.put(second, [5, 6, 7, 8], 10u64, true)
        store.put(third, [9, 10, 11, 12], 1u64, false)
        @Expect(store.snapshot().entries, 2)
        @Expect(store.snapshot().encodedBytes, 8)
        @Expect(store.take(first).isNone())
        @Expect(store.take(second).isSome())
        @Expect(store.take(second).isNone())
        @Expect(store.snapshot().entries, 1)
        clock.advance(Duration.second)
        @Expect(store.take(third).isNone())
        @Expect(store.snapshot().entries, 0)
        store.close()
    }

    @TestCase
    func everySecurityPartitionDimensionPreventsReuse(): Unit {
        let store = TlsSessionStore(
            maximumEntries: 4,
            maximumEncodedBytes: 64,
            maximumOneSessionBytes: 64
        )
        let base = testSessionKey("server")
        store.put(base, [1, 2, 3], 10u64, false)
        let variants = [
            TlsSessionKey("other", "h2", "trust", "client", "provider", "12-13"),
            TlsSessionKey("server", "http/1.1", "trust", "client", "provider", "12-13"),
            TlsSessionKey("server", "h2", "other-trust", "client", "provider", "12-13"),
            TlsSessionKey("server", "h2", "trust", "other-client", "provider", "12-13"),
            TlsSessionKey("server", "h2", "trust", "client", "other-provider", "12-13"),
            TlsSessionKey("server", "h2", "trust", "client", "provider", "13-13")
        ]
        for (variant in variants) {
            @Expect(store.take(variant).isNone())
            @Expect(store.snapshot().entries, 1)
        }
        @Expect(store.take(base).isSome())
        store.close()
    }
}

private func testSessionKey(server: String): TlsSessionKey {
    TlsSessionKey(server, "h2", "trust", "client", "provider", "12-13")
}
