package wirestack.internal.transport

import std.collection.*
import std.sync.*

/** Idempotent removal of a cleanup that terminal completion has not claimed. */
public class OperationCleanupRegistration {
    private let owner: OperationCompletion
    private let id: Int64
    private let removed = AtomicBool(false)

    internal init(owner: OperationCompletion, id: Int64) {
        this.owner = owner
        this.id = id
    }

    public func unregister(): Unit {
        if (!removed.swap(true)) { owner.unregister(id) }
    }
}

/**
 * Bounded exactly-once operation completion and terminal resource cleanup.
 *
 * Registered cleanup actions represent cancellation registrations, timers,
 * waiters, buffers, or similar operation-owned resources. The first terminal
 * caller claims and removes every action, runs them outside the registry lock,
 * then invokes its completion callback. Later terminal callbacks never run.
 */
public class OperationCompletion {
    private let maximumCleanups: Int64
    private let mutex = Mutex()
    private var completed = false
    private var nextId: Int64 = 1
    private var cleanups = HashMap<Int64, () -> Unit>()

    public prop isCompleted: Bool { get() { synchronized(mutex) { completed } } }
    public prop activeCleanupCount: Int64 { get() { synchronized(mutex) { cleanups.size } } }

    public init(maxCleanups!: UInt32 = 16u32) {
        if (maxCleanups == 0u32) {
            throw IllegalArgumentException("operation cleanup limit must be positive")
        }
        maximumCleanups = Int64(maxCleanups)
    }

    /**
     * Registers one resource cleanup. A registration after completion is not
     * retained and runs synchronously before this method returns.
     */
    public func registerCleanup(cleanup: () -> Unit): OperationCleanupRegistration {
        var runImmediately = false
        let id = synchronized(mutex) {
            if (completed) {
                runImmediately = true
                0
            } else {
                if (cleanups.size >= maximumCleanups) {
                    throw IllegalStateException("operation cleanup registration limit reached")
                }
                let current = nextId
                nextId += 1
                cleanups[current] = cleanup
                current
            }
        }
        if (runImmediately) { runOperationCleanup(cleanup) }
        OperationCleanupRegistration(this, id)
    }

    /**
     * Completes once. Cleanup failures are isolated so every claimed resource
     * is attempted and the winning completion callback still runs.
     */
    public func tryComplete(onWinner!: () -> Unit = { => }): Bool {
        var claimed = ArrayList<() -> Unit>()
        let won = synchronized(mutex) {
            if (completed) {
                false
            } else {
                completed = true
                for (cleanup in cleanups.values()) { claimed.add(cleanup) }
                cleanups = HashMap<Int64, () -> Unit>()
                true
            }
        }
        if (!won) { return false }

        for (cleanup in claimed) { runOperationCleanup(cleanup) }
        onWinner()
        true
    }

    internal func unregister(id: Int64): Unit {
        if (id == 0) { return }
        synchronized(mutex) { cleanups.remove(id) }
    }
}

private func runOperationCleanup(cleanup: () -> Unit): Unit {
    try { cleanup() } catch (_: Exception) {}
}
