package wirestack.internal.resolver

import std.env.getVariable
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func observationResolverWait(predicate: () -> Bool): Unit {
    let deadline = MonoTime.now() + 3 * Duration.second
    while (!predicate()) {
        if (MonoTime.now() >= deadline) { throw TimeoutException() }
        sleep(Duration.millisecond)
    }
}

@Test
class SystemResolverResourceObservationTest {
    @TestCase
    func realLocalhostCompletionPreservesOwnerAndFinalSample(): Unit {
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        let initial = resolver.resolverResourceSnapshot()
        let other = SystemResolver(workerCount: 1, queueCapacity: 1)
        try {
            @Expect(initial.ownerId > 0)
            @Expect(initial.ownerId != other.resolverResourceSnapshot().ownerId)
            @Expect(resolver.resolve(api.HostName("localhost")).addresses.isEmpty(), false)
            let idle = resolver.resolverResourceSnapshot()
            @Expect(idle.activeQueries, 0)
            @Expect(idle.runningWork, 0)
            @Expect(idle.cacheEntries, 0)
            resolver.close()
            resolver.close()
            let final = resolver.resolverResourceSnapshot()
            @Expect(final.ownerId, initial.ownerId)
            @Expect(final.activeQueries, 0)
            @Expect(final.sampledAt >= idle.sampledAt)
            @Expect(final.isLive, false)
            sleep(Duration.millisecond)
            @Expect(resolver.resolverResourceSnapshot().sampledAt, final.sampledAt)
        } finally { resolver.close(); other.close() }
    }

    @Configure[skip: getVariable("WIRESTACK_GAI_DELAY_MS") != Some("500")]
    @TestCase
    func abandonedNativeWorkRemainsVisibleUntilWorkerFinishesAndClosedSampleIsHistorical(): Unit {
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        let source = api.CancellationSource()
        let context = api.OperationContext(cancellation: source.token)
        let first = spawn { resolver.resolve(api.HostName("localhost"), context: context) }
        try {
            observationResolverWait({=> resolver.resolverResourceSnapshot().runningWork == 1 })
            let second = spawn { resolver.resolve(api.HostName("localhost"), context: context) }
            observationResolverWait({=> resolver.resolverResourceSnapshot().queuedQueries == 1 })
            let full = resolver.resolverResourceSnapshot()
            @Expect(full.activeQueries, 2)
            @Expect(full.runningWork, 1)
            let error = @AssertThrows[api.ResolveException](resolver.resolve(api.HostName("localhost")))
            match (error.resolveCode) {
                case api.ResolveErrorCode.TemporaryFailure => ()
                case _ => @Fail("expected native bounded queue rejection")
            }
            @Expect(resolver.resolverResourceSnapshot().rejectedQueries, 1)
            source.cancel()
            @ExpectThrows[api.ResolveException](first.get(Duration.second))
            @ExpectThrows[api.ResolveException](second.get(Duration.second))
            let abandoned = resolver.resolverResourceSnapshot()
            @Expect(abandoned.runningWork, 1)
            @Expect(abandoned.activeQueries >= 1)
            observationResolverWait({=> resolver.resolverResourceSnapshot().activeQueries == 0 })
            let final = resolver.resolverResourceSnapshot()
            @Expect(final.runningWork, 0)
            @Expect(final.queuedQueries, 0)
            @Expect(final.rejectedQueries, 1)
            @Expect(final.ownerId, full.ownerId)
            @Expect(final.isLive)
            resolver.close()
            let historical = resolver.resolverResourceSnapshot()
            @Expect(historical.isLive, false)
            @Expect(historical.activeQueries, 0)
            sleep(Duration.millisecond)
            @Expect(resolver.resolverResourceSnapshot().sampledAt, historical.sampledAt)
        } finally { source.cancel(); resolver.close() }
    }

    @Configure[skip: getVariable("WIRESTACK_GAI_DELAY_MS") != Some("500")]
    @TestCase
    func closeDuringBlockedWorkRetainsNonCurrentNonzeroOriginalSample(): Unit {
        let resolver = SystemResolver(workerCount: 1, queueCapacity: 1)
        let source = api.CancellationSource()
        let resolving = spawn { resolver.resolve(api.HostName("localhost"),
            context: api.OperationContext(cancellation: source.token)) }
        try {
            observationResolverWait({=> resolver.resolverResourceSnapshot().runningWork == 1 })
            source.cancel()
            @ExpectThrows[api.ResolveException](resolving.get(Duration.second))
            let started = MonoTime.now()
            resolver.close()
            @Expect(MonoTime.now() - started < 100 * Duration.millisecond)
            let historical = resolver.resolverResourceSnapshot()
            @Expect(historical.isLive, false)
            @Expect(historical.runningWork, 1)
            @Expect(historical.activeQueries, 1)
            sleep(600 * Duration.millisecond)
            let later = resolver.resolverResourceSnapshot()
            @Expect(later.sampledAt, historical.sampledAt)
            @Expect(later.activeQueries, historical.activeQueries)
            @Expect(later.isLive, false)
        } finally { source.cancel(); resolver.close() }
    }
}
