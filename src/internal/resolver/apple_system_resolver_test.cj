package wirestack.internal.resolver

import std.env.getVariable
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class M2006AppleSystemResolverTest {
    @TestCase
    func resolvesLocalhostThroughTheProviderNeutralContract(): Unit {
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(api.HostName("localhost"))
            @Expect(result.addresses.isEmpty(), false)
            @Expect(m2006IsSystemSource(result.source))
            @Expect(result.expiration.isNone())
            @Expect(result.canonicalHost, api.HostName("localhost"))
        } finally {
            resolver.close()
            resolver.close()
        }
    }

    @TestCase
    func fixtureReturnsAllCandidatesWithoutInventingTtl(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(api.HostName("all.m2-006.test"))
            @Expect(result.addresses.size, 2)
            @Expect(m2006IsIpv6(result.addresses[0].family))
            @Expect(result.addresses[0].zone, Some("11"))
            @Expect(m2006IsIpv4(result.addresses[1].family))
            @Expect(result.diagnostics.duplicatesRemoved, 1)
            @Expect(result.expiration.isNone())
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureAppliesFamilyAndResultBounds(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        try {
            let ipv4 = resolver.resolve(
                api.HostName("all.m2-006.test"),
                options: api.ResolveOptions(
                    family: api.ResolveAddressFamily.Ipv4,
                    maxResults: 8
                )
            )
            @Expect(ipv4.addresses.size, 1)
            @Expect(m2006IsIpv4(ipv4.addresses[0].family))
            let limited = resolver.resolve(
                api.HostName("all.m2-006.test"),
                options: api.ResolveOptions(maxResults: 1)
            )
            @Expect(limited.addresses.size, 1)
            @Expect(m2006IsIpv6(limited.addresses[0].family))
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureMapsPosixFailuresAndUnknownCodes(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 8)
        try {
            for ((name, code) in [
                ("noname.m2-006.test", api.ResolveErrorCode.NameNotFound),
                ("again.m2-006.test", api.ResolveErrorCode.TemporaryFailure),
                ("family.m2-006.test", api.ResolveErrorCode.UnsupportedFamily),
                ("system.m2-006.test", api.ResolveErrorCode.SystemFailure),
                ("unknown.m2-006.test", api.ResolveErrorCode.SystemFailure)
            ]) {
                let error = m2006ResolveError({=>
                    let _ = resolver.resolve(api.HostName(name))
                })
                @Expect(m2006IsCode(error.resolveCode, code))
                @Expect(error.nativeCode.isSome())
                @Expect(m2006IsResolveDns(error))
            }
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureCancellationAndDeadlineReturnBeforeNativeCleanup(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
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
        let cancelled = m2006ResolveError({=> let _ = resolving.get(Duration.second) })
        @Expect(m2006IsCode(cancelled.resolveCode, api.ResolveErrorCode.Cancelled))
        @Expect(MonoTime.now() - cancelStarted < 100 * Duration.millisecond)

        let deadlineStarted = MonoTime.now()
        let timedOut = m2006ResolveError({=>
            let _ = resolver.resolve(
                api.HostName("delay.m2-006.test"),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(20 * Duration.millisecond))
                )
            )
        })
        @Expect(m2006IsCode(timedOut.resolveCode, api.ResolveErrorCode.Timeout))
        @Expect(MonoTime.now() - deadlineStarted < 100 * Duration.millisecond)
        resolver.close()
    }

    @TestCase
    func newResolutionObservesNetworkGenerationChange(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        try {
            let first = resolver.resolve(api.HostName("change.m2-006.test"))
            let second = resolver.resolve(api.HostName("change.m2-006.test"))
            @Expect(first.addresses.size, 2)
            @Expect(second.addresses.size, 2)
            @Expect(first.addresses[1] != second.addresses[1])
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func validatesBoundsAndRejectsUseAfterClose(): Unit {
        @Expect(m2006IllegalArgument({=> let _ = SystemResolver(workerCount: 0) }))
        @Expect(m2006IllegalArgument({=> let _ = SystemResolver(queueCapacity: 0) }))
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        resolver.close()
        resolver.close()
        let error = m2006ResolveError({=>
            let _ = resolver.resolve(api.HostName("localhost"))
        })
        @Expect(m2006IsCode(error.resolveCode, api.ResolveErrorCode.SystemFailure))
        @Expect(error.nativeCode.isNone())
    }

    @TestCase
    func fixtureBoundsAdmissionAndReleasesQueuedWorkAfterClose(): Unit {
        if (!m2006FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        let first = spawn {
            resolver.resolve(api.HostName("delay.m2-006.test"))
        }
        m2006WaitForMetrics(resolver, {metrics => metrics.runningJobs == 1})
        let second = spawn {
            resolver.resolve(api.HostName("delay.m2-006.test"))
        }
        m2006WaitForMetrics(resolver, {metrics => metrics.queuedJobs == 1})
        let overloaded = m2006ResolveError({=>
            let _ = resolver.resolve(api.HostName("delay.m2-006.test"))
        })
        @Expect(m2006IsCode(overloaded.resolveCode, api.ResolveErrorCode.TemporaryFailure))
        let closeStarted = MonoTime.now()
        resolver.close()
        resolver.close()
        @Expect(MonoTime.now() - closeStarted < 100 * Duration.millisecond)
        @Expect(first.get(2 * Duration.second).addresses.isEmpty(), false)
        @Expect(second.get(2 * Duration.second).addresses.isEmpty(), false)
    }
}

private func m2006WaitForMetrics(
    resolver: SystemResolver,
    predicate: (ResolverPoolMetrics) -> Bool
): Unit {
    let expiresAt = MonoTime.now() + Duration.second
    while (MonoTime.now() < expiresAt) {
        if (predicate(resolver.metrics())) {
            return
        }
        sleep(Duration.millisecond)
    }
    throw TimeoutException()
}

private func m2006FixtureEnabled(): Bool {
    match (getVariable("WIRESTACK_RESOLVER_TEST_FIXTURE")) {
        case Some(value) => value == "1"
        case None => false
    }
}

private func m2006ResolveError(action: () -> Unit): api.ResolveException {
    try {
        action()
    } catch (error: api.ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func m2006IllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func m2006IsSystemSource(value: api.ResolverSource): Bool {
    match (value) {
        case api.ResolverSource.System => true
        case _ => false
    }
}

private func m2006IsIpv4(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv4 => true
        case _ => false
    }
}

private func m2006IsIpv6(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv6 => true
        case _ => false
    }
}

private func m2006IsCode(value: api.ResolveErrorCode, expected: api.ResolveErrorCode): Bool {
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

private func m2006IsResolveDns(error: api.ResolveException): Bool {
    match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Resolve, api.NetworkPhase.Dns) => true
        case _ => false
    }
}
