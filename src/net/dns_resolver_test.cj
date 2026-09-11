package wirestack.net

import std.collection.ArrayList
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func dnsResolverTestLoopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func dnsResolverTestEndpoint(socket: UdpSocket): api.SocketEndpoint {
    match (socket.localEndpoint) {
        case Some(api.NetworkEndpoint.Internet(endpoint)) => endpoint
        case _ => throw IllegalStateException("expected an Internet UDP endpoint")
    }
}

private func dnsResolverTestNxdomain(query: Array<Byte>): Array<Byte> {
    if (query.size < 12) { throw IllegalArgumentException("DNS fixture query is too short") }
    let response = query.clone()
    response[2] = 0x81u8
    response[3] = 0x83u8
    for (index in 6..12) { response[index] = 0u8 }
    response
}

private func dnsResolverTestReceiveTimedOut(error: api.NetworkException): Bool {
    match ((error.category, error.phase, error.code)) {
        case (
            api.NetworkErrorCategory.Read,
            api.NetworkPhase.DatagramReceive,
            api.NetworkErrorCode.TimedOut
        ) => true
        case _ => false
    }
}


private func dnsResolverTestIpv4(last: Byte): api.IpAddress {
    api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, last])
}

private func dnsResolverTestTempPath(): String {
    let file = File.createTemp("/tmp")
    let path = file.info.path.toString()
    file.close()
    path
}

private func dnsResolverTestDefaults(config: DnsResolverConfig): Bool {
    config.nameservers.isEmpty() && config.searchDomains.isEmpty() && config.ndots == 1
}

private func dnsResolverTestHostsSource(source: api.ResolverSource): Bool {
    match (source) {
        case api.ResolverSource.HostsFile => true
        case _ => false
    }
}

private func dnsResolverTestFamilyIs(
    actual: api.IpAddressFamily,
    expected: api.IpAddressFamily
): Bool {
    match ((actual, expected)) {
        case (api.IpAddressFamily.Ipv4, api.IpAddressFamily.Ipv4) |
             (api.IpAddressFamily.Ipv6, api.IpAddressFamily.Ipv6) => true
        case _ => false
    }
}

private func dnsResolverTestResolveError(operation: () -> Unit): api.ResolveException {
    try {
        operation()
    } catch (error: api.ResolveException) {
        return error
    }
    throw Exception("expected ResolveException")
}

private func dnsResolverTestResolveErrorIs(
    error: api.ResolveException,
    expected: api.ResolveErrorCode
): Bool {
    let resolveCode = match ((error.resolveCode, expected)) {
        case (api.ResolveErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) |
             (api.ResolveErrorCode.Timeout, api.ResolveErrorCode.Timeout) => true
        case _ => false
    }
    let networkCode = match ((error.code, expected)) {
        case (api.NetworkErrorCode.Cancelled, api.ResolveErrorCode.Cancelled) |
             (api.NetworkErrorCode.TimedOut, api.ResolveErrorCode.Timeout) => true
        case _ => false
    }
    let coordinates = match ((error.category, error.phase)) {
        case (api.NetworkErrorCategory.Resolve, api.NetworkPhase.Dns) => true
        case _ => false
    }
    resolveCode && networkCode && coordinates
}

private func dnsResolverTestConnectTimeout(error: api.NetworkException): Bool {
    match ((error.category, error.phase, error.code)) {
        case (
            api.NetworkErrorCategory.Connect,
            api.NetworkPhase.TcpConnect,
            api.NetworkErrorCode.TimedOut
        ) => true
        case _ => false
    }
}

private class DnsResolverTestClock <: api.MonotonicClock {
    private let mutex = Mutex()
    private var current: MonoTime

    init(current: MonoTime) { this.current = current }

    public func now(): MonoTime { synchronized(mutex) { current } }

    func advance(duration: Duration): Unit {
        synchronized(mutex) { current = current + duration }
    }
}

private class DnsResolverDeadlineSink <: api.NetworkEventSink {
    private let clock: DnsResolverTestClock
    private let advanced = AtomicBool(false)
    private let dnsCompleted = AtomicInt64(0)
    private let connectStarted = AtomicInt64(0)

    init(clock: DnsResolverTestClock) { this.clock = clock }

    public func emit(event: api.NetworkEvent): Unit {
        match (event.kind) {
            case api.NetworkEventKind.DnsCompleted =>
                let _ = dnsCompleted.fetchAdd(1)
            case api.NetworkEventKind.ConnectAttemptStarted =>
                let _ = connectStarted.fetchAdd(1)
                if (!advanced.swap(true)) { clock.advance(Duration.second) }
            case _ => ()
        }
    }

    prop dnsCompletions: Int64 { get() { dnsCompleted.load() } }
    prop connectStarts: Int64 { get() { connectStarted.load() } }
}

@Test
class DnsResolverPolicyTest {
    @TestCase
    func fromSystemParsesTabsCommentsLastSearchAndClampedNdots(): Unit {
        let path = dnsResolverTestTempPath()
        try {
            File.writeTo(path, (
                "# trusted resolver fixture\n" +
                "nameserver\t192.0.2.53 # primary\n" +
                "nameserver 010.0.0.1 ; leading zero is not a literal\n" +
                "nameserver 300.1.1.1\n" +
                "nameserver 2001:db8::53 ; secondary\n" +
                "nameserver 2001:db8:::53\n" +
                "search old.test duplicate.test\n" +
                "domain\tfinal.test ignored.test # the last directive wins\n" +
                "options rotate ndots:99 ndots:-1\n"
            ).toArray())

            let config = DnsResolverConfig.fromSystem(path: path)
            let servers = config.nameservers
            @Assert(servers.size, 2)
            @Expect(servers[0].address.toOctets(), [192u8, 0u8, 2u8, 53u8])
            @Expect(servers[0].port, 53u16)
            @Expect(dnsResolverTestFamilyIs(
                servers[1].address.family,
                api.IpAddressFamily.Ipv6
            ))
            @Expect(servers[1].port, 53u16)
            @Expect(config.searchDomains, [api.HostName("final.test")])
            @Expect(config.ndots, 15)
        } finally {
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func directConfigRejectsUnsupportedNameserverZonesBeforeQueries(): Unit {
        let octets = Array<Byte>(16, repeat: 0u8)
        octets[0] = 0xFEu8
        octets[1] = 0x80u8
        octets[15] = 1u8
        for (zone in ["eth0", "4294967296"]) {
            let endpoint = api.SocketEndpoint(
                api.IpAddress(api.IpAddressFamily.Ipv6, octets, zone: Some(zone)),
                53u16
            )
            @AssertThrows[IllegalArgumentException](DnsResolverConfig(nameservers: [endpoint]))
        }
    }

    @TestCase
    func systemNameserversRetainOnlySupportedNumericZones(): Unit {
        let path = dnsResolverTestTempPath()
        try {
            File.writeTo(path, (
                "nameserver fe80::1%eth0\n" +
                "nameserver fe80::2%4294967296\n" +
                "nameserver fe80::3%7\n" +
                "nameserver 192.0.2.53\n"
            ).toArray())
            let servers = DnsResolverConfig.fromSystem(path: path).nameservers
            @Assert(servers.size, 2)
            @Expect(servers[0].address.zone, Some("7"))
            @Expect(servers[1].address.toOctets(), [192u8, 0u8, 2u8, 53u8])
            File.writeTo(path, "nameserver fe80::1%eth0\n".toArray())
            @Expect(DnsResolverConfig.fromSystem(path: path).nameservers.isEmpty())
        } finally {
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func configOwnsInputArraysAndReturnsDefensiveCopies(): Unit {
        let first = dnsResolverTestLoopback(5301u16)
        let second = dnsResolverTestLoopback(5302u16)
        let nameservers = [first, second]
        let searches = [api.HostName("first.test"), api.HostName("second.test")]
        let config = DnsResolverConfig(
            nameservers: nameservers,
            searchDomains: searches,
            hostsPath: ""
        )

        nameservers[0] = dnsResolverTestLoopback(5399u16)
        searches[0] = api.HostName("mutated.test")
        @Expect(config.nameservers[0], first)
        @Expect(config.searchDomains[0], api.HostName("first.test"))

        let returnedServers = config.nameservers
        let returnedSearches = config.searchDomains
        returnedServers[0] = dnsResolverTestLoopback(5398u16)
        returnedSearches[0] = api.HostName("returned.test")
        @Expect(config.nameservers[0], first)
        @Expect(config.nameservers[1], second)
        @Expect(config.searchDomains[0], api.HostName("first.test"))
        @Expect(config.searchDomains[1], api.HostName("second.test"))
    }

    @TestCase
    func systemFilesFailClosedWhenMissingOversizedOrNonregular(): Unit {
        let missing = dnsResolverTestTempPath()
        let oversized = dnsResolverTestTempPath()
        let directory = dnsResolverTestTempPath()
        try {
            let _ = removeIfExists(missing)
            File.writeTo(oversized, Array<Byte>(1024 * 1024 + 1, repeat: 0u8))
            let _ = removeIfExists(directory)
            Directory.create(directory)

            @Expect(dnsResolverTestDefaults(DnsResolverConfig.fromSystem(path: missing)))
            @Expect(dnsResolverTestDefaults(DnsResolverConfig.fromSystem(path: oversized)))
            @Expect(dnsResolverTestDefaults(DnsResolverConfig.fromSystem(path: directory)))
        } finally {
            let _ = removeIfExists(missing)
            let _ = removeIfExists(oversized)
            let _ = removeIfExists(directory, recursive: true)
        }
    }

    @TestCase
    func hostsAliasesFilterFamiliesAndRemainSnapshotted(): Unit {
        let path = dnsResolverTestTempPath()
        try {
            File.writeTo(path, (
                "127.0.0.2 primary-v4 alias-v4 mixed # v4 aliases\n" +
                "::1 primary-v6 alias-v6 mixed ; v6 aliases\n" +
                "010.0.0.7 rejected-alias\n"
            ).toArray())
            let config = DnsResolverConfig(hostsPath: path)
            let resolver = Resolver(config: config)
            try {
                File.writeTo(path, "127.0.0.9 alias-v4 mixed\n".toArray())

                let ipv4 = resolver.resolve(
                    api.HostName("alias-v4"),
                    options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
                )
                @Expect(ipv4.addresses, [dnsResolverTestIpv4(2u8)])
                @Expect(ipv4.canonicalHost, api.HostName("alias-v4"))
                @Expect(dnsResolverTestHostsSource(ipv4.source))
                @Expect(ipv4.expiration.isNone())

                let ipv6 = resolver.resolve(
                    api.HostName("alias-v6"),
                    options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv6)
                )
                @Assert(ipv6.addresses.size, 1)
                @Expect(dnsResolverTestFamilyIs(
                    ipv6.addresses[0].family,
                    api.IpAddressFamily.Ipv6
                ))

                let mixedV4 = resolver.resolve(
                    api.HostName("mixed"),
                    options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
                )
                let mixedV6 = resolver.resolve(
                    api.HostName("mixed"),
                    options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv6)
                )
                @Expect(mixedV4.addresses, [dnsResolverTestIpv4(2u8)])
                @Assert(mixedV6.addresses.size, 1)
                @Expect(dnsResolverTestFamilyIs(
                    mixedV6.addresses[0].family,
                    api.IpAddressFamily.Ipv6
                ))

                let reloaded = Resolver(config: config)
                try {
                    @Expect(
                        reloaded.resolve(api.HostName("alias-v4")).addresses,
                        [dnsResolverTestIpv4(9u8)]
                    )
                } finally {
                    reloaded.close()
                }
            } finally {
                resolver.close()
            }
        } finally {
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func trailingRootSkipsSearchWhileNdotsSelectsSearchOrAbsoluteFirst(): Unit {
        let server = UdpSocket.bind(dnsResolverTestLoopback(0u16))
        let endpoint = dnsResolverTestEndpoint(server)
        let searchFirst = Resolver(config: DnsResolverConfig(nameservers: [endpoint],
            searchDomains: [api.HostName("search.test")], ndots: 2, hostsPath: "", attempts: 1))
        let absoluteFirst = Resolver(config: DnsResolverConfig(nameservers: [endpoint],
            searchDomains: [api.HostName("search.test")], ndots: 1, hostsPath: "", attempts: 1))
        let serving: Future<Array<String>> = spawn {
            let names = ArrayList<String>()
            for (_ in 0..3) {
                let received = server.receive(512, context: api.OperationContext(
                    deadline: Some(api.Deadline.after(2 * Duration.second))))
                names.add(DnsMessageParser().parse(received.payload).questions[0].name)
                let header = received.payload.clone()
                header[2] = 0x81u8
                header[3] = 0x80u8
                header[7] = 1u8
                let response = ArrayList<Byte>()
                for (byte in header) { response.add(byte) }
                for (byte in [0xC0u8, 0x0Cu8, 0u8, 1u8, 0u8, 1u8,
                    0u8, 0u8, 0u8, 0u8, 0u8, 4u8, 127u8, 0u8, 0u8, 42u8]) {
                    response.add(byte)
                }
                let _ = server.sendTo(received.source.getOrThrow(), api.ByteSpan(response.toArray()),
                    context: api.OperationContext(deadline: Some(api.Deadline.after(Duration.second))))
            }
            names.toArray()
        }
        let options = api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
        try {
            let expanded = searchFirst.resolve("service", options: options)
            @Expect(expanded.canonicalHost, api.HostName("service.search.test"))
            let rooted = searchFirst.resolve("service.", options: options)
            @Expect(rooted.canonicalHost, api.HostName("service"))
            let absolute = absoluteFirst.resolve("db.prod", options: options)
            @Expect(absolute.canonicalHost, api.HostName("db.prod"))
            @Expect(expanded.addresses, [dnsResolverTestIpv4(42u8)])
            @Expect(serving.get(Duration.second), ["service.search.test", "service", "db.prod"])
        } finally {
            searchFirst.close()
            absoluteFirst.close()
            server.close()
            try { let _ = serving.get(Duration.second) } catch (_: Exception) {}
        }
    }

    @TestCase
    func exactHostsEntryWinsBeforeSearchSuffixDns(): Unit {
        let path = dnsResolverTestTempPath()
        let dnsServer = UdpSocket.bind(dnsResolverTestLoopback(0u16))
        File.writeTo(path, "127.0.0.21 precedence.test\n".toArray())
        let resolver = Resolver(config: DnsResolverConfig(
            nameservers: [dnsResolverTestEndpoint(dnsServer)],
            searchDomains: [api.HostName("search.test")],
            ndots: 2,
            hostsPath: path,
            queryTimeout: Duration.second,
            attempts: 1
        ))
        let serving: Future<Int64> = spawn {
            try {
                let received = dnsServer.receive(
                    512,
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(200 * Duration.millisecond))
                    )
                )
                let _ = dnsServer.sendTo(
                    received.source.getOrThrow(),
                    api.ByteSpan(dnsResolverTestNxdomain(received.payload)),
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.second))
                    )
                )
                1
            } catch (error: api.NetworkException) {
                if (dnsResolverTestReceiveTimedOut(error)) { 0 } else { throw error }
            }
        }
        try {
            let result = resolver.resolve(
                "precedence.test",
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4)
            )
            @Expect(result.addresses, [dnsResolverTestIpv4(21u8)])
            @Expect(result.canonicalHost, api.HostName("precedence.test"))
            @Expect(dnsResolverTestHostsSource(result.source))
            @Expect(serving.get(Duration.second), 0)
        } finally {
            resolver.close()
            dnsServer.close()
            try { let _ = serving.get(Duration.second) } catch (_: Exception) {}
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func cancelledExpiredAndClosedCallsRetainPublicResolveClassifications(): Unit {
        let path = dnsResolverTestTempPath()
        try {
            File.writeTo(path, "127.0.0.20 lifecycle.test\n".toArray())
            let resolver = Resolver(config: DnsResolverConfig(hostsPath: path))
            try {
                let cancellation = api.CancellationSource()
                cancellation.cancel()

                let cancelled = dnsResolverTestResolveError({ =>
                    let _ = resolver.resolve(
                        api.HostName("lifecycle.test"),
                        context: api.OperationContext(cancellation: cancellation.token)
                    )
                })
                @Expect(dnsResolverTestResolveErrorIs(
                    cancelled,
                    api.ResolveErrorCode.Cancelled
                ))

                let expired = dnsResolverTestResolveError({ =>
                    let _ = resolver.resolve(
                        api.HostName("lifecycle.test"),
                        context: api.OperationContext(
                            deadline: Some(api.Deadline.after(Duration.Zero))
                        )
                    )
                })
                @Expect(dnsResolverTestResolveErrorIs(expired, api.ResolveErrorCode.Timeout))

                resolver.close()
                @Expect(resolver.isClosed())
                let closed = dnsResolverTestResolveError({ =>
                    let _ = resolver.resolve(api.HostName("lifecycle.test"))
                })
                @Expect(dnsResolverTestResolveErrorIs(closed, api.ResolveErrorCode.Cancelled))
            } finally {
                resolver.close()
            }
        } finally {
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func connectUsesHostsMappingForANativeListenerExchange(): Unit {
        let path = dnsResolverTestTempPath()
        let listener = TcpListener.bind(dnsResolverTestLoopback(0u16), backlog: 2)
        File.writeTo(path, "127.0.0.1 native-connect.test\n".toArray())
        let resolver = Resolver(config: DnsResolverConfig(
            hostsPath: path,
            queryTimeout: 500 * Duration.millisecond
        ))
        let clock = DnsResolverTestClock(MonoTime.now())
        let sink = DnsResolverDeadlineSink(clock)
        let request = [0x10u8, 0x20u8, 0x30u8]
        let response = [0xA0u8, 0xB0u8]
        let serving: Future<Bool> = spawn {
            let peer = listener.accept(context: api.OperationContext(
                deadline: Some(api.Deadline.after(2 * Duration.second))
            ))
            try {
                let received = Array<Byte>(request.size, repeat: 0u8)
                peer.readExact(
                    api.MutableByteSpan(received),
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.second))
                    )
                )
                peer.writeAll(
                    api.ByteSpan(response),
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.second))
                    )
                )
                received == request
            } finally {
                peer.close()
            }
        }
        var connected: ?api.DuplexTransport = None<api.DuplexTransport>
        try {
            let transport = resolver.connect(
                api.HostName("native-connect.test"),
                listener.localEndpoint.port,
                attemptDelay: Duration.Zero,
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(2 * Duration.second, clock: clock)),
                    eventSink: Some(sink)
                )
            )
            connected = Some(transport)
            match (transport.info.remoteEndpoint) {
                case Some(endpoint) =>
                    @Expect(endpoint, listener.localEndpoint)
                case _ => @Fail("connected transport did not expose its Internet peer")
            }
            api.writeAll(
                transport,
                api.ByteSpan(request),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(Duration.second))
                )
            )
            let received = Array<Byte>(response.size, repeat: 0u8)
            api.readExact(
                transport,
                api.MutableByteSpan(received),
                context: api.OperationContext(
                    deadline: Some(api.Deadline.after(Duration.second))
                )
            )
            @Expect(received, response)
            @Expect(serving.get(Duration.second))
        } finally {
            match (connected) {
                case Some(transport) => transport.close(api.OperationContext.background())
                case None => ()
            }
            listener.close()
            try { let _ = serving.get(Duration.second) } catch (_: Exception) {}
            resolver.close()
            let _ = removeIfExists(path)
        }
    }

    @TestCase
    func resolverConnectCarriesOneAbsoluteDeadlineIntoNativeTcpAdmission(): Unit {
        let path = dnsResolverTestTempPath()
        let listener = TcpListener.bind(dnsResolverTestLoopback(0u16), backlog: 1)
        File.writeTo(path, "127.0.0.1 deadline-connect.test\n".toArray())
        let resolver = Resolver(config: DnsResolverConfig(
            hostsPath: path,
            queryTimeout: 5 * Duration.second
        ))
        let clock = DnsResolverTestClock(MonoTime.now())
        let sink = DnsResolverDeadlineSink(clock)
        try {
            let error = try {
                let transport = resolver.connect(
                    api.HostName("deadline-connect.test"),
                    listener.localEndpoint.port,
                    attemptDelay: Duration.Zero,
                    context: api.OperationContext(
                        deadline: Some(api.Deadline.after(Duration.second, clock: clock)),
                        eventSink: Some(sink)
                    )
                )
                transport.close(api.OperationContext.background())
                @Fail("expired total deadline unexpectedly published a connected transport")
            } catch (value: api.NetworkException) {
                value
            }
            @Expect(dnsResolverTestConnectTimeout(error))
            @Expect(sink.dnsCompletions, 1)
            @Expect(sink.connectStarts, 1)
        } finally {
            resolver.close()
            listener.close()
            let _ = removeIfExists(path)
        }
    }
}
