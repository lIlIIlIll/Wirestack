package wirestack.internal.transport

import std.collection.*
import std.sync.*

/** A removable cancellation callback registration. */
public class CancellationRegistration {
    private let state: CancellationState
    private let id: Int64
    private let unregistered = AtomicBool(false)

    internal init(state: CancellationState, id: Int64) {
        this.state = state
        this.id = id
    }

    /** Idempotently prevents a callback that cancellation has not claimed. */
    public func unregister(): Unit {
        if (!unregistered.swap(true)) {
            state.unregister(id)
        }
    }
}

/** Read-only cancellation capability passed to operations. */
public class CancellationToken {
    private static let NONE = CancellationToken(CancellationState())
    private let state: CancellationState

    internal init(state: CancellationState) {
        this.state = state
    }

    /** A token that cannot be cancelled by a caller. */
    public static func none(): CancellationToken {
        NONE
    }

    public prop isCancellationRequested: Bool {
        get() {
            state.isCancellationRequested
        }
    }

    /**
     * Registers an interruption callback. If already cancelled, the callback
     * runs synchronously before this method returns.
     */
    public func register(callback: () -> Unit): CancellationRegistration {
        state.register(callback)
    }
}

/** Owns the one-way transition that cancels a token. */
public class CancellationSource {
    private let state = CancellationState()
    public let token: CancellationToken

    public init() {
        token = CancellationToken(state)
    }

    /** Runs every callback at most once. Repeated cancellation is a no-op. */
    public func cancel(): Unit {
        state.cancel()
    }
}

internal class CancellationState {
    private let cancelled = AtomicBool(false)
    private let mutex = Mutex()
    private var nextId: Int64 = 1
    private var callbacks = HashMap<Int64, () -> Unit>()

    internal prop isCancellationRequested: Bool {
        get() {
            cancelled.load()
        }
    }

    internal func register(callback: () -> Unit): CancellationRegistration {
        var invokeImmediately = false
        let id = synchronized(mutex) {
            if (cancelled.load()) {
                invokeImmediately = true
                0
            } else {
                let current = nextId
                nextId++
                callbacks[current] = callback
                current
            }
        }

        if (invokeImmediately) {
            callback()
        }
        CancellationRegistration(this, id)
    }

    internal func unregister(id: Int64): Unit {
        if (id == 0) {
            return
        }
        synchronized(mutex) {
            callbacks.remove(id)
        }
    }

    internal func cancel(): Unit {
        if (cancelled.swap(true)) {
            return
        }

        let claimed = synchronized(mutex) {
            let result = ArrayList<() -> Unit>()
            for (callback in callbacks.values()) {
                result.add(callback)
            }
            callbacks = HashMap<Int64, () -> Unit>()
            result
        }

        // User/internal callbacks never run while the registration lock is held.
        for (callback in claimed) {
            try {
                callback()
            } catch (_: Exception) {
                // Cancellation must still wake every registered operation.
            }
        }
    }
}
