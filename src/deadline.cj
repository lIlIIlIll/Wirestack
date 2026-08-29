package wirestack

import std.time.MonoTime

/** Monotonic time source used by Deadline and deterministic tests. */
public interface MonotonicClock {
    func now(): MonoTime
}

/** The production clock. It is independent from wall-clock adjustments. */
public class SystemMonotonicClock <: MonotonicClock {
    public init() {}

    public func now(): MonoTime {
        MonoTime.now()
    }
}

/**
 * An absolute monotonic operation deadline.
 *
 * A deadline owns the time source used to create it so derived operations and
 * tests cannot accidentally mix wall time with monotonic time.
 */
public struct Deadline {
    public let expiresAt: MonoTime
    private let clock: MonotonicClock

    public init(expiresAt: MonoTime, clock!: MonotonicClock = SystemMonotonicClock()) {
        this.expiresAt = expiresAt
        this.clock = clock
    }

    /** Creates a deadline relative to one monotonic-clock observation. */
    public static func after(duration: Duration, clock!: MonotonicClock = SystemMonotonicClock()): Deadline {
        requireNonNegativeDuration(duration)
        let now = clock.now()
        Deadline(now + duration, clock: clock)
    }

    /** Returns zero after expiry; it never exposes a negative duration. */
    public func remaining(): Duration {
        let now = clock.now()
        if (now >= expiresAt) {
            return Duration.Zero
        }
        expiresAt - now
    }

    public func isExpired(): Bool {
        clock.now() >= expiresAt
    }

    /**
     * Creates a child budget capped by this deadline. A child may shorten but
     * can never extend its parent.
     */
    public func child(duration: Duration): Deadline {
        requireNonNegativeDuration(duration)
        let now = clock.now()
        if (now >= expiresAt) {
            return Deadline(expiresAt, clock: clock)
        }
        let parentRemaining = expiresAt - now
        if (duration < parentRemaining) {
            return Deadline(now + duration, clock: clock)
        }
        Deadline(expiresAt, clock: clock)
    }
}

private func requireNonNegativeDuration(duration: Duration): Unit {
    if (duration < Duration.Zero) {
        throw IllegalArgumentException("deadline duration must be non-negative")
    }
}
