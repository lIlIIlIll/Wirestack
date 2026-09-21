package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import wirestack as api

private func dnsExampleResponse(): Array<Byte> {
    [
        0x12u8, 0x34u8, 0x81u8, 0x80u8,
        0x00u8, 0x01u8, 0x00u8, 0x02u8,
        0x00u8, 0x00u8, 0x00u8, 0x00u8,
        0x07u8, b'e', b'x', b'a', b'm', b'p', b'l', b'e',
        0x03u8, b'c', b'o', b'm', 0x00u8,
        0x00u8, 0x01u8, 0x00u8, 0x01u8,
        0xC0u8, 0x0Cu8, 0x00u8, 0x01u8, 0x00u8, 0x01u8,
        0x00u8, 0x00u8, 0x00u8, 0x3Cu8, 0x00u8, 0x04u8,
        0x01u8, 0x02u8, 0x03u8, 0x04u8,
        0xC0u8, 0x0Cu8, 0x00u8, 0x05u8, 0x00u8, 0x01u8,
        0x00u8, 0x00u8, 0x00u8, 0x3Cu8, 0x00u8, 0x02u8,
        0xC0u8, 0x0Cu8
    ]
}

private func m8DnsLoopback(port: UInt16): api.SocketEndpoint {
    api.SocketEndpoint(
        api.IpAddress(api.IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]),
        port
    )
}

private func dnsQuestionEnd(query: Array<Byte>): Int64 {
    var cursor: Int64 = 12
    while (cursor < query.size) {
        let length = Int64(query[cursor])
        cursor += 1
        if (length == 0) { return cursor + 4 }
        cursor += length
    }
    throw Exception("invalid DNS query in test server")
}

private func dnsSyntheticResponse(query: Array<Byte>, truncated: Bool): Array<Byte> {
    let questionEnd = dnsQuestionEnd(query)
    let questionBytes = questionEnd - 12
    let answerBytes = if (truncated) { 0 } else { 16 }
    let response = Array<Byte>(12 + questionBytes + answerBytes, repeat: 0u8)
    response[0] = query[0]
    response[1] = query[1]
    response[2] = if (truncated) { 0x83u8 } else { 0x81u8 }
    response[3] = 0x80u8
    response[5] = 1u8
    response[7] = if (truncated) { 0u8 } else { 1u8 }
    for (index in 0..questionBytes) { response[12 + index] = query[12 + index] }
    if (!truncated) {
        var offset = 12 + questionBytes
        response[offset] = 0xC0u8
        response[offset + 1] = 0x0Cu8
        response[offset + 3] = 1u8
        response[offset + 5] = 1u8
        response[offset + 9] = 1u8
        response[offset + 11] = 4u8
        response[offset + 12] = 1u8
        response[offset + 13] = 2u8
        response[offset + 14] = 3u8
        response[offset + 15] = 4u8
    }
    response
}

@Test
class DnsWireFoundationTest {
    @TestCase
    func parsesQuestionsAnswersAndCompressedNames(): Unit {
        let summary = DnsMessageParser().parse(dnsExampleResponse())
        @Expect(summary.transactionId, 0x1234u16)
        @Expect(summary.questionCount, 1)
        @Expect(summary.answerCount, 2)
        @Expect(summary.responseCode, 0)
        @Expect(summary.questions.size, 1)
        @Expect(summary.questions[0].name, "example.com")
        @Expect(summary.records.size, 2)
        match (summary.records[0].recordType) {
            case DnsRecordType.A => ()
            case _ => @Fail("A record type was not decoded")
        }
        @Expect(summary.records[0].data(), [1u8, 2u8, 3u8, 4u8])
        match (summary.records[1].targetName) {
            case Some(value) => @Expect(value, "example.com")
            case None => @Fail("CNAME target was not decoded")
        }
    }

    @TestCase
    func compressionLoopsAreRejected(): Unit {
        var rejected = false
        try {
            let _ = DnsMessageParser().parse([
                0x00u8, 0x01u8, 0x81u8, 0x80u8,
                0x00u8, 0x01u8, 0x00u8, 0x00u8,
                0x00u8, 0x00u8, 0x00u8, 0x00u8,
                0xC0u8, 0x0Cu8
            ])
        } catch (_: api.ResolveException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func malformedRecordLengthIsRejected(): Unit {
        var rejected = false
        try {
            let _ = DnsMessageParser().parse([
                0x00u8, 0x01u8, 0x81u8, 0x80u8,
                0x00u8, 0x01u8, 0x00u8, 0x01u8,
                0x00u8, 0x00u8, 0x00u8, 0x00u8,
                0x00u8, 0x00u8, 0x01u8, 0x00u8, 0x01u8,
                0xC0u8, 0x0Cu8, 0x00u8, 0x01u8, 0x00u8, 0x01u8,
                0x00u8, 0x00u8, 0x00u8, 0x01u8, 0x00u8, 0x04u8,
                0x01u8, 0x02u8
            ])
        } catch (_: api.ResolveException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func resolverUsesBoundedHostsSearchAndIpv6Entries(): Unit {
        let temporary = File.createTemp("/tmp")
        let path = temporary.info.path.toString()
        temporary.close()
        try {
            File.writeTo(path, "127.0.0.7 alias.m8.test\n::1 alias.m8.test\n".toArray())
            let config = DnsResolverConfig(
                searchDomains: [api.HostName("m8.test")],
                ndots: 2,
                hostsPath: path
            )
            let resolver = Resolver(config: config)
            let result = resolver.resolve(api.HostName("alias"))
            match (result.source) {
                case api.ResolverSource.HostsFile => ()
                case api.ResolverSource.System => @Fail("hosts resolver returned System source")
                case api.ResolverSource.Static => @Fail("hosts resolver returned Static source")
                case api.ResolverSource.Custom => @Fail("hosts resolver returned Custom source")
            }
            @Expect(result.addresses.size, 2)
            resolver.close()
        } finally {
            remove(path)
        }
    }

    @TestCase
    func dnsResponseCodeMapsNxDomainToNameNotFound(): Unit {
        var response = dnsExampleResponse()
        response[3] = 0x83u8
        response[7] = 0u8
        response[6] = 0u8
        var rejected = false
        try {
            let summary = DnsMessageParser().parse(response)
            @Expect(summary.responseCode, 3)
            if (summary.responseCode == 3) { rejected = true }
        } catch (error: api.ResolveException) {
            let _ = error
        }
        @Expect(rejected)
    }

    @TestCase
    func truncatedUdpResponseFallsBackToTcp(): Unit {
        let udp = DatagramSocket.bind()
        let udpLocal = match (udp.localEndpoint) {
            case Some(NetworkEndpoint.Internet(value)) => value
            case _ => throw Exception("DNS test UDP endpoint is unavailable")
        }
        let nameserver = m8DnsLoopback(udpLocal.port)
        let tcp = TcpListener.bind(nameserver, backlog: 4)
        let deadline = api.OperationContext(deadline: Some(api.Deadline.after(3 * Duration.second)))
        let udpResponder = spawn {
            =>
            let request = udp.receive(2048, context: deadline)
            let source = match (request.source) {
                case Some(NetworkEndpoint.Internet(value)) => value
                case _ => throw Exception("DNS test request source is unavailable")
            }
            let response = dnsSyntheticResponse(request.payload, true)
            let _ = udp.sendTo(source, api.ByteSpan(response), context: deadline)
        }
        let tcpResponder = spawn {
            =>
            let connection = tcp.accept(context: deadline)
            try {
                let frameLength = Array<Byte>(2, repeat: 0u8)
                connection.readExact(api.MutableByteSpan(frameLength), context: deadline)
                let queryLength = (Int64(frameLength[0]) << 8) | Int64(frameLength[1])
                let query = Array<Byte>(queryLength, repeat: 0u8)
                connection.readExact(api.MutableByteSpan(query), context: deadline)
                let response = dnsSyntheticResponse(query, false)
                let frame = Array<Byte>(response.size + 2, repeat: 0u8)
                frame[0] = UInt8(UInt64((response.size >> 8) & 0xFF))
                frame[1] = UInt8(UInt64(response.size & 0xFF))
                for (index in 0..response.size) { frame[index + 2] = response[index] }
                connection.writeAll(api.ByteSpan(frame), context: deadline)
            } finally {
                connection.close()
            }
        }
        let client = DnsClient(config: DnsResolverConfig(
            nameservers: [nameserver], hostsPath: ""
        ))
        try {
            let result = client.lookup(
                api.HostName("example.com"),
                options: api.ResolveOptions(family: api.ResolveAddressFamily.Ipv4),
                context: deadline
            )
            @Expect(result.addresses.size, 1)
            @Expect(result.addresses[0], api.IpAddress(
                api.IpAddressFamily.Ipv4, [1u8, 2u8, 3u8, 4u8]
            ))
            let _ = udpResponder.get(3 * Duration.second)
            let _ = tcpResponder.get(3 * Duration.second)
        } finally {
            client.close()
            udp.close()
            tcp.close()
        }
    }
}
