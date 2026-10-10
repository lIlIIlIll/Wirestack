package wirestack.internal.http2

import std.sync.Mutex
import std.time.MonoTime
import wirestack.internal.transport.*
import wirestack.internal as internal

/** One admitted server exchange, never a counter for ordinary completion. */
internal class Http2ServerCancellationMeasurement {
    private let budget: internal.HttpResourceBudget
    private let mutex = Mutex()
    private var requestedAt = None<MonoTime>
    private var reclaimed = false
    private var registration = None<CancellationRegistration>

    init(budget: internal.HttpResourceBudget) { this.budget = budget }

    func requested(): Unit {
        synchronized(mutex) {
            if (!reclaimed && requestedAt.isNone()) { requestedAt = Some(MonoTime.now()) }
        }
    }

    func bind(token: CancellationToken, cancel: () -> Unit): Unit {
        let attached = token.register { => requested(); cancel() }
        let discard = synchronized(mutex) {
            if (reclaimed) { true } else { registration = Some(attached); false }
        }
        if (discard) { attached.unregister() }
    }

    /** Caller has already released channel buffers and request/stream leases. */
    func complete(): Unit {
        let claimed = synchronized(mutex) {
            if (reclaimed) { (None<MonoTime>, None<CancellationRegistration>) }
            else {
                reclaimed = true
                let result = (requestedAt, registration)
                registration = None<CancellationRegistration>
                result
            }
        }
        if (let Some(value) <- claimed[1]) { value.unregister() }
        if (let Some(start) <- claimed[0]) { budget.recordCancellationCompletion(MonoTime.now() - start) }
    }
}
