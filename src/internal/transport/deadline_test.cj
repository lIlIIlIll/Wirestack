package wirestack.internal.transport

import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

private class FakeMonotonicClock <: MonotonicClock {
    private var current: MonoTime

    init(start: MonoTime) {
        current = start
    }

    public func now(): MonoTime {
        current
    }

    func advance(duration: Duration): Unit {
        current = current + duration
    }
}

@Test
class DeadlineTest {
    @TestCase
    func remainingUsesTheInjectedMonotonicClock(): Unit {
        let clock = FakeMonotonicClock(MonoTime.now())
        let deadline = Deadline.after(Duration.second, clock: clock)
        @Expect(deadline.remaining(), Duration.second)
        @Expect(!deadline.isExpired())

        clock.advance(250 * Duration.millisecond)
        @Expect(deadline.remaining(), 750 * Duration.millisecond)
        @Expect(!deadline.isExpired())

        clock.advance(750 * Duration.millisecond)
        @Expect(deadline.remaining(), Duration.Zero)
        @Expect(deadline.isExpired())
    }

    @TestCase
    func remainingClampsAtZeroAfterExpiry(): Unit {
        let clock = FakeMonotonicClock(MonoTime.now())
        let deadline = Deadline.after(10 * Duration.millisecond, clock: clock)
        clock.advance(20 * Duration.millisecond)

        @Expect(deadline.remaining(), Duration.Zero)
        @Expect(deadline.isExpired())
    }

    @TestCase
    func childCanShortenButNeverExtendParent(): Unit {
        let clock = FakeMonotonicClock(MonoTime.now())
        let parent = Deadline.after(Duration.second, clock: clock)
        let shorter = parent.child(100 * Duration.millisecond)
        let longer = parent.child(2 * Duration.second)

        @Expect(shorter.expiresAt < parent.expiresAt)
        @Expect(longer.expiresAt, parent.expiresAt)

        clock.advance(50 * Duration.millisecond)
        let delayedChild = parent.child(Duration.second)
        @Expect(delayedChild.expiresAt, parent.expiresAt)
    }

    @TestCase
    func rejectsNegativeDurationsWithoutReadingTheClock(): Unit {
        let clock = FakeMonotonicClock(MonoTime.now())
        var afterRejected = false
        try {
            let _ = Deadline.after(Duration.Zero - Duration.nanosecond, clock: clock)
        } catch (_: IllegalArgumentException) {
            afterRejected = true
        }

        let parent = Deadline.after(Duration.second, clock: clock)
        var childRejected = false
        try {
            let _ = parent.child(Duration.Zero - Duration.nanosecond)
        } catch (_: IllegalArgumentException) {
            childRejected = true
        }

        @Expect(afterRejected)
        @Expect(childRejected)
    }
}
