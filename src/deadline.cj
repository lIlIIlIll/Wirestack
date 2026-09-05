package wirestack

import std.time.MonoTime

/** Monotonic time source used by Deadline and deterministic tests. */
public interface MonotonicClock {
/**
 * Wirestack 公开 API：now。
 */
    func now(): MonoTime
}

/** The production clock. It is independent from wall-clock adjustments. */
public class SystemMonotonicClock <: MonotonicClock {
/**
 * Wirestack 公开 API：init。
 */
    public init() {}

/**
 * Wirestack 公开 API：now。
 */
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
/**
 * Wirestack 公开 API：expiresAt。
 */
    public let expiresAt: MonoTime
    private let clock: MonotonicClock

/**
 * Wirestack 公开 API：init。
 * @param clock 参数 clock。
 * @param expiresAt 参数 expiresAt。
 */
    public init(expiresAt: MonoTime, clock!: MonotonicClock = SystemMonotonicClock()) {
        this.expiresAt = expiresAt
        this.clock = clock
    }

/**
 * Creates a deadline relative to one monotonic-clock observation.
 * @param clock 参数 clock。
 * @param duration 参数 duration。
 */
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

/**
 * Wirestack 公开 API：isExpired。
 */
    public func isExpired(): Bool {
        clock.now() >= expiresAt
    }

    /**
     * Creates a child budget capped by this deadline. A child may shorten but
     * can never extend its parent.
 * @param duration 参数 duration。
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
