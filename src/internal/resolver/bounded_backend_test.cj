package wirestack.internal.resolver

import std.collection.ArrayList
import std.env.getVariable
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*

private let M2003_LOCALHOST = HostName("localhost")

@Test
class M2003BoundedResolverBackendTest {
    @TestCase
    func resolvesLocalhostWithBoundedMetricsAndIdempotentClose(): Unit {
        let backend = BoundedSystemResolverBackend(workerCount: 2, queueCapacity: 4)
        try {
            let result = backend.resolve(
                M2003_LOCALHOST,
                None<String>,
                ResolveOptions(maxResults: 8),
                OperationContext.background()
            )
            @Expect(result.addresses.isEmpty(), false)
            @Expect(m2003IsSystemSource(result.source))
            @Expect(result.expiration.isNone())
            let metrics = backend.metrics()
            @Expect(metrics.workerCount, 2)
            @Expect(metrics.queueCapacity, 4)
            @Expect(metrics.activeJobs, 0)
            @Expect(metrics.queuedJobs, 0)
            @Expect(metrics.runningJobs, 0)
            @Expect(metrics.submittedJobs, 1)
            @Expect(metrics.completedJobs, 1)
            @Expect(metrics.rejectedJobs, 0)
        } finally {
            backend.close()
            backend.close()
        }
    }

    @TestCase
    func appliesIpv4FamilyAndRejectsUseAfterClose(): Unit {
        let backend = BoundedSystemResolverBackend(workerCount: 1, queueCapacity: 2)
        let result = backend.resolve(
            M2003_LOCALHOST,
            None<String>,
            ResolveOptions(family: ResolveAddressFamily.Ipv4, maxResults: 8),
            OperationContext.background()
        )
        for (address in result.addresses) {
            @Expect(m2003IsIpv4(address.family))
        }
        backend.close()
        @Expect(m2003ExpectResolveError({=>
            let _ = backend.resolve(
                M2003_LOCALHOST,
                None<String>,
                ResolveOptions(),
                OperationContext.background()
            )
        }, ResolveErrorCode.SystemFailure))
    }

    @TestCase
    func validatesPoolBounds(): Unit {
        @Expect(m2003ExpectIllegalArgument({=> let _ = BoundedSystemResolverBackend(workerCount: 0) }))
        @Expect(m2003ExpectIllegalArgument({=> let _ = BoundedSystemResolverBackend(workerCount: 33) }))
        @Expect(m2003ExpectIllegalArgument({=> let _ = BoundedSystemResolverBackend(queueCapacity: 0) }))
        @Expect(m2003ExpectIllegalArgument({=> let _ = BoundedSystemResolverBackend(queueCapacity: 1025) }))
    }

    @TestCase
    func nativeFamilyValidationFailsClosedAndPollingBackoffIsBounded(): Unit {
        @Expect(m2003IsIpv4(nativeResolverResultFamily(4)))
        @Expect(m2003IsIpv6(nativeResolverResultFamily(6)))
        @Expect(m2003ExpectResolveError(
            {=> let _ = nativeResolverResultFamily(5) },
            ResolveErrorCode.SystemFailure
        ))

        var delay = Duration.millisecond
        let expected = [
            2 * Duration.millisecond,
            4 * Duration.millisecond,
            8 * Duration.millisecond,
            16 * Duration.millisecond,
            16 * Duration.millisecond,
        ]
        for (value in expected) {
            delay = nextResolverWaitDelay(delay)
            @Expect(delay, value)
        }
    }

    @TestCase
    func preCancelledContextDoesNotSubmitNativeWork(): Unit {
        let backend = BoundedSystemResolverBackend(workerCount: 1, queueCapacity: 1)
        let source = CancellationSource()
        source.cancel()
        @Expect(m2003ExpectResolveError({=>
            let _ = backend.resolve(
                M2003_LOCALHOST,
                None<String>,
                ResolveOptions(),
                OperationContext(cancellation: source.token)
            )
        }, ResolveErrorCode.Cancelled))
        @Expect(backend.metrics().submittedJobs, 0)
        backend.close()
    }

    @TestCase
    func delayedNativeWorkDoesNotStarveCangjieHeartbeat(): Unit {
        if (!m2003DelayEnabled()) {
            return
        }
        let backend = BoundedSystemResolverBackend(workerCount: 2, queueCapacity: 16)
        let running = AtomicBool(true)
        let heartbeats = AtomicInt64(0)
        let heartbeat = spawn {
            while (running.load()) {
                heartbeats.fetchAdd(1)
                sleep(5 * Duration.millisecond)
            }
        }
        let futures = ArrayList<Future<ResolveResult>>()
        for (_ in 0..8) {
            futures.add(spawn {
                backend.resolve(
                    M2003_LOCALHOST,
                    None<String>,
                    ResolveOptions(maxResults: 8),
                    OperationContext.background()
                )
            })
        }
        try {
            for (future in futures) {
                @Expect(future.get(5 * Duration.second).addresses.isEmpty(), false)
            }
        } finally {
            running.store(false)
            heartbeat.get(Duration.second)
            backend.close()
        }
        @Expect(heartbeats.load() >= 20)
    }

    @TestCase
    func cancellationCompletesPromptlyWhileNativeJobCleansUp(): Unit {
        if (!m2003DelayEnabled()) {
            return
        }
        let backend = BoundedSystemResolverBackend(workerCount: 1, queueCapacity: 2)
        let source = CancellationSource()
        let resolving = spawn {
            backend.resolve(
                M2003_LOCALHOST,
                None<String>,
                ResolveOptions(maxResults: 8),
                OperationContext(cancellation: source.token)
            )
        }
        sleep(20 * Duration.millisecond)
        let started = MonoTime.now()
        source.cancel()
        @Expect(m2003ExpectResolveError({=> let _ = resolving.get(Duration.second) }, ResolveErrorCode.Cancelled))
        let latency = MonoTime.now() - started
        @Expect(latency < 50 * Duration.millisecond)
        let closeStarted = MonoTime.now()
        backend.close()
        @Expect(MonoTime.now() - closeStarted < 50 * Duration.millisecond)
    }

    @TestCase
    func deadlineCompletesPromptlyWhileNativeJobCleansUp(): Unit {
        if (!m2003DelayEnabled()) {
            return
        }
        let backend = BoundedSystemResolverBackend(workerCount: 1, queueCapacity: 1)
        let started = MonoTime.now()
        @Expect(m2003ExpectResolveError({=>
            let _ = backend.resolve(
                M2003_LOCALHOST,
                None<String>,
                ResolveOptions(maxResults: 8),
                OperationContext(deadline: Some(Deadline.after(20 * Duration.millisecond)))
            )
        }, ResolveErrorCode.Timeout))
        let latency = MonoTime.now() - started
        @Expect(latency < 50 * Duration.millisecond)
        backend.close()
    }

    @TestCase
    func queueAdmissionIsStrictlyBounded(): Unit {
        if (!m2003DelayEnabled()) {
            return
        }
        let backend = BoundedSystemResolverBackend(workerCount: 1, queueCapacity: 1)
        let first = spawn { m2003Resolve(backend) }
        m2003WaitForMetrics(backend, {metrics => metrics.runningJobs == 1})
        let second = spawn { m2003Resolve(backend) }
        m2003WaitForMetrics(backend, {metrics => metrics.queuedJobs == 1})
        @Expect(m2003ExpectResolveError({=> let _ = m2003Resolve(backend) }, ResolveErrorCode.TemporaryFailure))
        @Expect(first.get(2 * Duration.second).addresses.isEmpty(), false)
        @Expect(second.get(2 * Duration.second).addresses.isEmpty(), false)
        let metrics = backend.metrics()
        @Expect(metrics.peakActiveJobs <= 2)
        @Expect(metrics.peakQueuedJobs <= 1)
        @Expect(metrics.rejectedJobs, 1)
        backend.close()
    }
}

private func m2003Resolve(backend: BoundedSystemResolverBackend): ResolveResult {
    backend.resolve(
        M2003_LOCALHOST,
        None<String>,
        ResolveOptions(maxResults: 8),
        OperationContext.background()
    )
}

private func m2003ExpectResolveError(action: () -> Unit, expected: ResolveErrorCode): Bool {
    try {
        action()
        false
    } catch (error: ResolveException) {
        m2003IsError(error.resolveCode, expected)
    }
}

private func m2003ExpectIllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func m2003DelayEnabled(): Bool {
    match (getVariable("WIRESTACK_GAI_DELAY_MS")) {
        case Some(value) => value != "0"
        case None => false
    }
}

private func m2003IsSystemSource(value: ResolverSource): Bool {
    match (value) {
        case ResolverSource.System => true
        case _ => false
    }
}

private func m2003IsIpv4(value: IpAddressFamily): Bool {
    match (value) {
        case IpAddressFamily.Ipv4 => true
        case _ => false
    }
}

private func m2003IsIpv6(value: IpAddressFamily): Bool {
    match (value) {
        case IpAddressFamily.Ipv6 => true
        case _ => false
    }
}

private func m2003IsError(value: ResolveErrorCode, expected: ResolveErrorCode): Bool {
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

private func m2003WaitForMetrics(
    backend: BoundedSystemResolverBackend,
    predicate: (ResolverPoolMetrics) -> Bool
): Unit {
    let expiresAt = MonoTime.now() + Duration.second
    while (MonoTime.now() < expiresAt) {
        if (predicate(backend.metrics())) {
            return
        }
        sleep(Duration.millisecond)
    }
    throw TimeoutException()
}
