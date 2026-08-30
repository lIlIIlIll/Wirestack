package wirestack.m2_006_probe

import std.time.*
import wirestack as api
import wirestack.internal.resolver.SystemResolver

main(): Int64 {
    var failures = 0
    if (!m2006Run("resolves localhost", m2006Localhost)) { failures++ }
    if (!m2006Run("returns and deduplicates candidates", m2006Candidates)) { failures++ }
    if (!m2006Run("applies family and result bounds", m2006Bounds)) { failures++ }
    if (!m2006Run("maps POSIX resolver failures", m2006Errors)) { failures++ }
    if (!m2006Run("honors cancellation and Deadline", m2006Cancellation)) { failures++ }
    if (!m2006Run("observes a new network generation", m2006NetworkChange)) { failures++ }
    if (!m2006Run("closes idempotently and rejects invalid bounds", m2006Lifecycle)) {
        failures++
    }
    if (failures == 0) { 0 } else { 1 }
}

private func m2006Run(name: String, action: () -> Bool): Bool {
    try {
        if (action()) {
            println("[ PASSED ] CASE: ${name}")
            true
        } else {
            println("[ FAILED ] CASE: ${name}")
            false
        }
    } catch (_: Exception) {
        println("[ FAILED ] CASE: ${name}")
        false
    }
}

private func m2006Localhost(): Bool {
    let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
    try {
        let result = resolver.resolve(api.HostName("localhost"))
        !result.addresses.isEmpty() && result.expiration.isNone() &&
            result.canonicalHost == api.HostName("localhost") &&
            m2006SystemSource(result.source)
    } finally {
        resolver.close()
        resolver.close()
    }
}

private func m2006Candidates(): Bool {
    let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
    try {
        let result = resolver.resolve(api.HostName("all.m2-006.test"))
        result.addresses.size == 2 &&
            m2006Ipv6(result.addresses[0].family) &&
            m2006Ipv4(result.addresses[1].family) &&
            result.diagnostics.duplicatesRemoved == 1 &&
            result.expiration.isNone()
    } finally {
        resolver.close()
    }
}

private func m2006Bounds(): Bool {
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
    try {
        let ipv4 = resolver.resolve(
            api.HostName("all.m2-006.test"),
            options: api.ResolveOptions(
                family: api.ResolveAddressFamily.Ipv4,
                maxResults: 8
            )
        )
        let limited = resolver.resolve(
            api.HostName("all.m2-006.test"),
            options: api.ResolveOptions(maxResults: 1)
        )
        ipv4.addresses.size == 1 && m2006Ipv4(ipv4.addresses[0].family) &&
            limited.addresses.size == 1 && m2006Ipv6(limited.addresses[0].family)
    } finally {
        resolver.close()
    }
}

private func m2006Errors(): Bool {
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 8)
    try {
        for ((name, expected) in [
            ("noname.m2-006.test", api.ResolveErrorCode.NameNotFound),
            ("again.m2-006.test", api.ResolveErrorCode.TemporaryFailure),
            ("family.m2-006.test", api.ResolveErrorCode.UnsupportedFamily),
            ("system.m2-006.test", api.ResolveErrorCode.SystemFailure),
            ("unknown.m2-006.test", api.ResolveErrorCode.SystemFailure)
        ]) {
            let error = m2006Capture({=>
                let _ = resolver.resolve(api.HostName(name))
            })
            if (!m2006Code(error.resolveCode, expected) || error.nativeCode.isNone() ||
                !m2006ResolveDns(error)) {
                return false
            }
        }
        true
    } finally {
        resolver.close()
    }
}

private func m2006Cancellation(): Bool {
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
    try {
        let source = api.CancellationSource()
        let resolving = spawn {
            resolver.resolve(
                api.HostName("delay.m2-006.test"),
                context: api.OperationContext(cancellation: source.token)
            )
        }
        sleep(20 * Duration.millisecond)
        let cancelStarted = MonoTime.now()
        source.cancel()
        let cancelled = m2006Capture({=> let _ = resolving.get(Duration.second) })
        let cancelPrompt = MonoTime.now() - cancelStarted < 100 * Duration.millisecond

        let deadlineStarted = MonoTime.now()
        let timedOut = m2006Capture({=>
            let _ = resolver.resolve(
                api.HostName("delay.m2-006.test"),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(20 * Duration.millisecond))
                )
            )
        })
        let deadlinePrompt = MonoTime.now() - deadlineStarted < 100 * Duration.millisecond
        m2006Code(cancelled.resolveCode, api.ResolveErrorCode.Cancelled) && cancelPrompt &&
            m2006Code(timedOut.resolveCode, api.ResolveErrorCode.Timeout) && deadlinePrompt
    } finally {
        resolver.close()
    }
}

private func m2006NetworkChange(): Bool {
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
    try {
        let first = resolver.resolve(api.HostName("change.m2-006.test"))
        let second = resolver.resolve(api.HostName("change.m2-006.test"))
        first.addresses.size == 2 && second.addresses.size == 2 &&
            first.addresses[1] != second.addresses[1]
    } finally {
        resolver.close()
    }
}

private func m2006Lifecycle(): Bool {
    var invalidWorkers = false
    try {
        let _ = SystemResolver(workerCount: 0)
    } catch (_: IllegalArgumentException) {
        invalidWorkers = true
    }
    var invalidQueue = false
    try {
        let _ = SystemResolver(queueCapacity: 0)
    } catch (_: IllegalArgumentException) {
        invalidQueue = true
    }
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
    resolver.close()
    resolver.close()
    let error = m2006Capture({=>
        let _ = resolver.resolve(api.HostName("localhost"))
    })
    invalidWorkers && invalidQueue &&
        m2006Code(error.resolveCode, api.ResolveErrorCode.SystemFailure) &&
        error.nativeCode.isNone()
}

private func m2006Capture(action: () -> Unit): api.ResolveException {
    try {
        action()
    } catch (error: api.ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func m2006SystemSource(value: api.ResolverSource): Bool {
    match (value) {
        case api.ResolverSource.System => true
        case _ => false
    }
}

private func m2006Ipv4(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv4 => true
        case _ => false
    }
}

private func m2006Ipv6(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv6 => true
        case _ => false
    }
}

private func m2006Code(value: api.ResolveErrorCode, expected: api.ResolveErrorCode): Bool {
    match ((value, expected)) {
        case (api.ResolveErrorCode.NameNotFound, api.ResolveErrorCode.NameNotFound) |
             (api.ResolveErrorCode.TemporaryFailure, api.ResolveErrorCode.TemporaryFailure) |
             (api.ResolveErrorCode.Timeout, api.ResolveErrorCode.Timeout) |
             (api.ResolveErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) |
             (api.ResolveErrorCode.UnsupportedFamily, api.ResolveErrorCode.UnsupportedFamily) |
             (api.ResolveErrorCode.SystemFailure, api.ResolveErrorCode.SystemFailure) => true
        case _ => false
    }
}

private func m2006ResolveDns(error: api.ResolveException): Bool {
    match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Resolve, api.NetworkPhase.Dns) => true
        case _ => false
    }
}
