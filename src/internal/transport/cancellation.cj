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
        if (id == 0) {
            return
        }
        if (!unregistered.swap(true)) {
            state.unregister(id)
        }
    }
}

/** Read-only cancellation capability passed to operations. */
public class CancellationToken {
    private static let NONE_STATE = CancellationState()
    private static let NONE_REGISTRATION = CancellationRegistration(NONE_STATE, 0)
    private static let NONE = CancellationToken(NONE_STATE, permanentlyActive: true)
    private let state: CancellationState
    protected let permanentlyActive: Bool

    internal init(state: CancellationState, permanentlyActive!: Bool = false) {
        this.state = state
        this.permanentlyActive = permanentlyActive
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
        if (permanentlyActive) {
            // A never-cancelled token cannot invoke the callback. Reusing one
            // zero-id registration keeps hot background I/O allocation-free.
            NONE_REGISTRATION
        } else {
            state.register(callback)
        }
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
