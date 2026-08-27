package wirestack.http

import std.env.getVariable
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class M2005SystemResolverTest {
    @TestCase
    func resolvesLocalhostThroughThePublicContract(): Unit {
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(HostName("localhost"))
            @Expect(result.addresses.isEmpty(), false)
            @Expect(m2005IsSystemSource(result.source))
            @Expect(result.expiration.isNone())
            @Expect(result.canonicalHost, HostName("localhost"))
        } finally {
            resolver.close()
            resolver.close()
        }
    }

    @TestCase
    func fixtureReturnsAllCandidatesAndDoesNotInventTtl(): Unit {
        if (!m2005FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(HostName("all.m2-005.test"))
            @Expect(result.addresses.size, 2)
            @Expect(result.addresses[0].family, IpAddressFamily.Ipv6)
            @Expect(result.addresses[1].family, IpAddressFamily.Ipv4)
            @Expect(result.diagnostics.duplicatesRemoved, 1)
            @Expect(result.expiration.isNone())
            @Expect(result.canonicalHost, HostName("all.m2-005.test"))
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureAppliesFamilyAndResultBounds(): Unit {
        if (!m2005FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        try {
            let ipv4 = resolver.resolve(
                HostName("all.m2-005.test"),
                options: ResolveOptions(family: ResolveAddressFamily.Ipv4, maxResults: 8)
            )
            @Expect(ipv4.addresses.size, 1)
            @Expect(ipv4.addresses[0].family, IpAddressFamily.Ipv4)
            let limited = resolver.resolve(
                HostName("all.m2-005.test"),
                options: ResolveOptions(maxResults: 1)
            )
            @Expect(limited.addresses.size, 1)
            @Expect(limited.addresses[0].family, IpAddressFamily.Ipv6)
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureMapsStableErrorsAndRetainsNativeEvidence(): Unit {
        if (!m2005FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 4)
        try {
            for ((name, code, nativeExpected) in [
                ("noname.m2-005.test", ResolveErrorCode.NameNotFound, true),
                ("nodata.m2-005.test", ResolveErrorCode.NoData, false),
                ("again.m2-005.test", ResolveErrorCode.TemporaryFailure, true),
                ("family.m2-005.test", ResolveErrorCode.UnsupportedFamily, true),
                ("system.m2-005.test", ResolveErrorCode.SystemFailure, true)
            ]) {
                let error = m2005ResolveError({=>
                    let _ = resolver.resolve(HostName(name))
                })
                @Expect(m2005IsCode(error.resolveCode, code))
                @Expect(error.nativeCode.isSome(), nativeExpected)
                @Expect(m2005IsResolveDns(error))
            }
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureCancellationAndDeadlineReturnBeforeNativeCleanup(): Unit {
        if (!m2005FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        let source = CancellationSource()
        let resolving = spawn {
            resolver.resolve(
                HostName("delay.m2-005.test"),
                context: OperationContext(cancellation: source.token)
            )
        }
        sleep(20 * Duration.millisecond)
        let cancelStarted = MonoTime.now()
        source.cancel()
        let cancelled = m2005ResolveError({=> let _ = resolving.get(Duration.second) })
        @Expect(m2005IsCode(cancelled.resolveCode, ResolveErrorCode.Cancelled))
        @Expect(MonoTime.now() - cancelStarted < 50 * Duration.millisecond)

        let deadlineStarted = MonoTime.now()
        let timedOut = m2005ResolveError({=>
            let _ = resolver.resolve(
                HostName("delay.m2-005.test"),
                context: OperationContext(
                    deadline: Some(Deadline.after(20 * Duration.millisecond))
                )
            )
        })
        @Expect(m2005IsCode(timedOut.resolveCode, ResolveErrorCode.Timeout))
        @Expect(MonoTime.now() - deadlineStarted < 50 * Duration.millisecond)
        resolver.close()
    }

    @TestCase
    func validatesBoundsAndRejectsUseAfterClose(): Unit {
        @Expect(m2005IllegalArgument({=> let _ = SystemResolver(workerCount: 0) }))
        @Expect(m2005IllegalArgument({=> let _ = SystemResolver(queueCapacity: 0) }))
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        resolver.close()
        resolver.close()
        let error = m2005ResolveError({=>
            let _ = resolver.resolve(HostName("localhost"))
        })
        @Expect(m2005IsCode(error.resolveCode, ResolveErrorCode.SystemFailure))
        @Expect(error.nativeCode.isNone())
    }
}

private func m2005FixtureEnabled(): Bool {
    match (getVariable("WIRESTACK_M2_005_FIXTURE")) {
        case Some(value) => value == "1"
        case None => false
    }
}

private func m2005ResolveError(action: () -> Unit): ResolveException {
    try {
        action()
    } catch (error: ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func m2005IllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func m2005IsSystemSource(value: ResolverSource): Bool {
    match (value) {
        case ResolverSource.System => true
        case _ => false
    }
}

private func m2005IsCode(value: ResolveErrorCode, expected: ResolveErrorCode): Bool {
    match ((value, expected)) {
        case (ResolveErrorCode.NameNotFound, ResolveErrorCode.NameNotFound) => true
        case (ResolveErrorCode.NoData, ResolveErrorCode.NoData) => true
        case (ResolveErrorCode.TemporaryFailure, ResolveErrorCode.TemporaryFailure) => true
        case (ResolveErrorCode.Timeout, ResolveErrorCode.Timeout) => true
        case (ResolveErrorCode.Cancelled, ResolveErrorCode.Cancelled) => true
        case (ResolveErrorCode.InvalidName, ResolveErrorCode.InvalidName) => true
        case (ResolveErrorCode.UnsupportedFamily, ResolveErrorCode.UnsupportedFamily) => true
        case (ResolveErrorCode.SystemFailure, ResolveErrorCode.SystemFailure) => true
        case _ => false
    }
}

private func m2005IsResolveDns(error: ResolveException): Bool {
    match ((error.category, error.phase)) {
        case (NetworkErrorCategory.Resolve, NetworkPhase.Dns) => true
        case _ => false
    }
}
