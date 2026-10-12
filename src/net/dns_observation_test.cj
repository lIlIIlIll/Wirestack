package wirestack.net

import std.collection.ArrayList
import std.env.getVariable
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func observationDnsWait(predicate: () -> Bool): Unit {
    let deadline = MonoTime.now() + 2 * Duration.second
    while (!predicate()) {
        if (MonoTime.now() >= deadline) { throw TimeoutException() }
        sleep(Duration.millisecond)
    }
}

@Test
class DnsResourceObservationTest {
    @TestCase
    func snapshotsFollowActualUdpAdmissionQueueRejectionCacheAndClose(): Unit {
        let server = UdpSocket.bind(api.SocketEndpoint(
            api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0))
        let endpoint = match (server.localEndpoint) {
            case Some(api.NetworkEndpoint.Internet(value)) => value
            case _ => throw IllegalStateException("expected Internet endpoint")
        }
        let config = DnsResolverConfig(nameservers: [endpoint], hostsPath: "", attempts: 1,
            queryTimeout: 3 * Duration.second)
        let client = DnsClient(config: config, workerCount: 1, queueCapacity: 1)
        let resolver = Resolver(config: config, dns: Some(client))
        let received = AtomicBool(false)
        let release = AtomicBool(false)
        let serving = spawn {
            let query = server.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(3 * Duration.second))))
            received.store(true)
            observationDnsWait({=> release.load() })
            let response = query.payload.clone()
            response[2] = 0x81u8; response[3] = 0x80u8
            response[6] = 0u8; response[7] = 1u8
            let bytes = ArrayList<Byte>()
            for (byte in response) { bytes.add(byte) }
            for (byte in [0xC0u8, 0x0Cu8, 0u8, 1u8, 0u8, 1u8,
                0u8, 0u8, 0u8, 30u8, 0u8, 4u8, 192u8, 0u8, 2u8, 55u8]) { bytes.add(byte) }
            let _ = server.sendTo(query.source.getOrThrow(), api.ByteSpan(bytes.toArray()))
        }
        let lookup = {=> resolver.resolve(api.HostName("observation.test"),
            options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)) }
        try {
            let first = spawn { lookup() }
            observationDnsWait({=> received.load() })
            let initial = resolver.resolverResourceSnapshot()
            @Expect(initial.ownerId, client.resolverResourceSnapshot().ownerId)
            @Expect(initial.activeQueries, 1)
            @Expect(initial.runningWork, 1)
            @Expect(initial.queuedQueries, 0)
            @Expect(initial.isLive)
            let second = spawn { lookup() }
            observationDnsWait({=> resolver.resolverResourceSnapshot().queuedQueries == 1 })
            let queued = resolver.resolverResourceSnapshot()
            @Expect(queued.activeQueries, 2)
            @Expect(queued.runningWork, 1)
            let rejection = @AssertThrows[api.ResolveException](lookup())
            match (rejection.resolveCode) {
                case api.ResolveErrorCode.TemporaryFailure => ()
                case _ => @Fail("expected bounded queue rejection")
            }
            @Expect(resolver.resolverResourceSnapshot().rejectedQueries, 1)
            release.store(true)
            let answer = first.get(3 * Duration.second)
            @Expect(second.get(3 * Duration.second).expiration, answer.expiration)
            serving.get(Duration.second)
            let idle = resolver.resolverResourceSnapshot()
            @Expect(idle.activeQueries, 0)
            @Expect(idle.queuedQueries, 0)
            @Expect(idle.runningWork, 0)
            @Expect(idle.cacheEntries, 1)
            @Expect(idle.sampledAt >= queued.sampledAt)
            @Expect(lookup().expiration, answer.expiration)
            resolver.close()
            let closed = resolver.resolverResourceSnapshot()
            @Expect(closed.ownerId, initial.ownerId)
            @Expect(closed.cacheEntries, 0)
            @Expect(closed.rejectedQueries, 1)
            @Expect(closed.activeQueries, 0)
            @Expect(closed.queuedQueries, 0)
            @Expect(closed.runningWork, 0)
            @Expect(closed.isLive, false)
            @Expect(closed.sampledAt >= idle.sampledAt)
            sleep(Duration.millisecond)
            resolver.close()
            @ExpectThrows[api.ResolveException](lookup())
            let historical = resolver.resolverResourceSnapshot()
            @Expect(historical.ownerId, closed.ownerId)
            @Expect(historical.sampledAt, closed.sampledAt)
            @Expect(historical.isLive, false)
            @Expect(historical.activeQueries, closed.activeQueries)
            @Expect(historical.queuedQueries, closed.queuedQueries)
            @Expect(historical.runningWork, closed.runningWork)
            @Expect(historical.cacheEntries, closed.cacheEntries)
            @Expect(historical.rejectedQueries, closed.rejectedQueries)
        } finally {
            release.store(true)
            resolver.close()
            server.close()
        }
    }

    @TestCase
    func closeDrainsUdpActiveAndQueuedQueriesBeforeFreezingSnapshot(): Unit {
        let server = UdpSocket.bind(api.SocketEndpoint(
            api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]), 0))
        let endpoint = match (server.localEndpoint) {
            case Some(api.NetworkEndpoint.Internet(value)) => value
            case _ => throw IllegalStateException("expected Internet endpoint")
        }
        let client = DnsClient(config: DnsResolverConfig(nameservers: [endpoint],
            hostsPath: "", attempts: 1, queryTimeout: 3 * Duration.second),
            workerCount: 1, queueCapacity: 1)
        try {
            let first = spawn { client.query("close-observation.test", DnsRecordType.A) }
            let _ = server.receive(512,
                context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
            let second = spawn { client.query("close-observation.test", DnsRecordType.A) }
            observationDnsWait({=> client.resolverResourceSnapshot().queuedQueries == 1 })
            let live = client.resolverResourceSnapshot()
            @Expect(live.activeQueries, 2)
            @Expect(live.runningWork, 1)
            @Expect(live.isLive)
            client.close()
            let closed = client.resolverResourceSnapshot()
            @Expect(closed.isLive, false)
            @Expect(closed.ownerId, live.ownerId)
            @Expect(closed.activeQueries, 0)
            @Expect(closed.queuedQueries, 0)
            @Expect(closed.runningWork, 0)
            @Expect(closed.cacheEntries, 0)
            @Expect(closed.rejectedQueries, 0)
            @ExpectThrows[api.ResolveException](first.get(Duration.second))
            @ExpectThrows[api.ResolveException](second.get(Duration.second))
            sleep(Duration.millisecond)
            client.close()
            @Expect(client.resolverResourceSnapshot().sampledAt, closed.sampledAt)
        } finally { client.close(); server.close() }
    }

    @Configure[skip: getVariable("WIRESTACK_GAI_DELAY_MS") != Some("500")]
    @TestCase
    func nativeFallbackSnapshotsRetainAbandonedWorkAndHistoricalCloseSample(): Unit {
        let config = DnsResolverConfig(nameservers: [], hostsPath: "", attempts: 1,
            queryTimeout: 3 * Duration.second)
        let client = DnsClient(config: config, workerCount: 1, queueCapacity: 1)
        let resolver = Resolver(config: config, dns: Some(client))
        let source = api.CancellationSource()
        let resolving = spawn { client.lookup(api.HostName("localhost"),
            context: api.OperationContext(cancellation: source.token)) }
        try {
            observationDnsWait({=> resolver.resolverResourceSnapshot().runningWork == 1 })
            source.cancel()
            @ExpectThrows[api.ResolveException](resolving.get(Duration.second))
            let abandoned = resolver.resolverResourceSnapshot()
            @Expect(abandoned.activeQueries >= 1)
            @Expect(abandoned.runningWork, 1)
            @Expect(abandoned.isLive)
            observationDnsWait({=> resolver.resolverResourceSnapshot().activeQueries == 0 })
            @Expect(resolver.resolverResourceSnapshot().runningWork, 0)
            client.close()
            let historical = resolver.resolverResourceSnapshot()
            @Expect(historical.isLive, false)
            @Expect(historical.ownerId, abandoned.ownerId)
            @Expect(historical.activeQueries, 0)
            sleep(Duration.millisecond)
            @Expect(resolver.resolverResourceSnapshot().sampledAt, historical.sampledAt)
        } finally { source.cancel(); resolver.close(); client.close() }
    }
}
