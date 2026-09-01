package wirestack.internal.resolver

import std.env.getVariable
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class M2004WindowsSystemResolverTest {
    @TestCase
    func resolvesLocalhostThroughTheProviderNeutralContract(): Unit {
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(api.HostName("localhost"))
            @Expect(result.addresses.isEmpty(), false)
            @Expect(m2004IsSystemSource(result.source))
            @Expect(result.expiration.isNone())
            @Expect(result.canonicalHost, api.HostName("localhost"))
        } finally {
            resolver.close()
            resolver.close()
        }
    }

    @TestCase
    func fixtureReturnsAllCandidatesWithoutInventingTtl(): Unit {
        if (!m2004FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 2, queueCapacity: 4)
        try {
            let result = resolver.resolve(api.HostName("all.m2-004.test"))
            @Expect(result.addresses.size, 2)
            @Expect(m2004IsIpv6(result.addresses[0].family))
            @Expect(result.addresses[0].zone, Some("7"))
            @Expect(m2004IsIpv4(result.addresses[1].family))
            @Expect(result.diagnostics.duplicatesRemoved, 0)
            @Expect(result.expiration.isNone())
            @Expect(result.canonicalHost, api.HostName("all.m2-004.test"))
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureAppliesFamilyAndResultBounds(): Unit {
        if (!m2004FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        try {
            let ipv4 = resolver.resolve(
                api.HostName("all.m2-004.test"),
                options: api.ResolveOptions(
                    family: api.ResolveAddressFamily.Ipv4,
                    maxResults: 8
                )
            )
            @Expect(ipv4.addresses.size, 1)
            @Expect(m2004IsIpv4(ipv4.addresses[0].family))
            let limited = resolver.resolve(
                api.HostName("all.m2-004.test"),
                options: api.ResolveOptions(maxResults: 2)
            )
            @Expect(limited.addresses.size, 2)
            @Expect(m2004IsIpv6(limited.addresses[0].family))
            @Expect(m2004IsIpv4(limited.addresses[1].family))
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureMapsWinsockFailuresAndUnknownCodes(): Unit {
        if (!m2004FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 8)
        try {
            for ((name, code) in [
                ("noname.m2-004.test", api.ResolveErrorCode.NameNotFound),
                ("nodata.m2-004.test", api.ResolveErrorCode.NoData),
                ("again.m2-004.test", api.ResolveErrorCode.TemporaryFailure),
                ("family.m2-004.test", api.ResolveErrorCode.UnsupportedFamily),
                ("system.m2-004.test", api.ResolveErrorCode.SystemFailure),
                ("unknown.m2-004.test", api.ResolveErrorCode.SystemFailure)
            ]) {
                let error = m2004ResolveError({=>
                    let _ = resolver.resolve(api.HostName(name))
                })
                @Expect(m2004IsCode(error.resolveCode, code))
                @Expect(error.nativeCode.isSome())
                @Expect(m2004IsResolveDns(error))
            }
        } finally {
            resolver.close()
        }
    }

    @TestCase
    func fixtureCancellationAndDeadlineReturnBeforeNativeCleanup(): Unit {
        if (!m2004FixtureEnabled()) { return }
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 2)
        let source = api.CancellationSource()
        let resolving = spawn {
            resolver.resolve(
                api.HostName("delay.m2-004.test"),
                context: api.OperationContext(cancellation: source.token)
            )
        }
        sleep(20 * Duration.millisecond)
        let cancelStarted = MonoTime.now()
        source.cancel()
        let cancelled = m2004ResolveError({=> let _ = resolving.get(Duration.second) })
        @Expect(m2004IsCode(cancelled.resolveCode, api.ResolveErrorCode.Cancelled))
        @Expect(MonoTime.now() - cancelStarted < 50 * Duration.millisecond)

        let deadlineStarted = MonoTime.now()
        let timedOut = m2004ResolveError({=>
            let _ = resolver.resolve(
                api.HostName("delay.m2-004.test"),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(20 * Duration.millisecond))
                )
            )
        })
        @Expect(m2004IsCode(timedOut.resolveCode, api.ResolveErrorCode.Timeout))
        @Expect(MonoTime.now() - deadlineStarted < 50 * Duration.millisecond)
        resolver.close()
    }

    @TestCase
    func validatesBoundsAndRejectsUseAfterClose(): Unit {
        @Expect(m2004IllegalArgument({=> let _ = SystemResolver(workerCount: 0) }))
        @Expect(m2004IllegalArgument({=> let _ = SystemResolver(queueCapacity: 0) }))
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        resolver.close()
        resolver.close()
        let error = m2004ResolveError({=>
            let _ = resolver.resolve(api.HostName("localhost"))
        })
        @Expect(m2004IsCode(error.resolveCode, api.ResolveErrorCode.SystemFailure))
        @Expect(error.nativeCode.isNone())
    }
}

private func m2004FixtureEnabled(): Bool {
    match (getVariable("WIRESTACK_RESOLVER_TEST_FIXTURE")) {
        case Some(value) => value == "1"
        case None => false
    }
}

private func m2004ResolveError(action: () -> Unit): api.ResolveException {
    try {
        action()
    } catch (error: api.ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func m2004IllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func m2004IsSystemSource(value: api.ResolverSource): Bool {
    match (value) {
        case api.ResolverSource.System => true
        case _ => false
    }
}

private func m2004IsIpv4(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv4 => true
        case _ => false
    }
}

private func m2004IsIpv6(value: api.IpAddressFamily): Bool {
    match (value) {
        case api.IpAddressFamily.Ipv6 => true
        case _ => false
    }
}

private func m2004IsCode(value: api.ResolveErrorCode, expected: api.ResolveErrorCode): Bool {
    match ((value, expected)) {
        case (api.ResolveErrorCode.NameNotFound, api.ResolveErrorCode.NameNotFound) |
             (api.ResolveErrorCode.NoData, api.ResolveErrorCode.NoData) |
             (api.ResolveErrorCode.TemporaryFailure, api.ResolveErrorCode.TemporaryFailure) |
             (api.ResolveErrorCode.Timeout, api.ResolveErrorCode.Timeout) |
             (api.ResolveErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) |
             (api.ResolveErrorCode.InvalidName, api.ResolveErrorCode.InvalidName) |
             (api.ResolveErrorCode.UnsupportedFamily, api.ResolveErrorCode.UnsupportedFamily) |
             (api.ResolveErrorCode.SystemFailure, api.ResolveErrorCode.SystemFailure) => true
        case _ => false
    }
}

private func m2004IsResolveDns(error: api.ResolveException): Bool {
    match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Resolve, api.NetworkPhase.Dns) => true
        case _ => false
    }
}
