package wirestack.net

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

private func abstractName(seed: String): Array<Byte> {
    let suffix = seed.toArray()
    let value = Array<Byte>(suffix.size + 1, repeat: 0u8)
    for (index in 0..suffix.size) {
        value[index + 1] = suffix[index]
    }
    value
}

@Test
class UnixAndRawCapabilityTest {
    @TestCase
    func abstractUnixStreamUsesByteAddressWithoutUtf8Assumption(): Unit {
        let endpoint = UnixEndpoint.abstractName(abstractName("wirestack-m8-003"))
        let listener = UnixListener.bind(endpoint, backlog: 4)
        let accepted = spawn { listener.accept() }
        let client = UnixStream.connect(endpoint)
        let server = accepted.get(3 * Duration.second)
        try {
            client.writeAll(api.ByteSpan([0x61u8, 0x62u8]), context: api.OperationContext.background())
            let received = Array<Byte>(2, repeat: 0u8)
            server.readExact(api.MutableByteSpan(received), context: api.OperationContext.background())
            @Expect(received, [0x61u8, 0x62u8])
        } finally {
            client.close()
            server.close()
            listener.close()
        }
    }

    @TestCase
    func abstractUnixDatagramPreservesMessageBoundary(): Unit {
        let receiver = UnixDatagramSocket.bind(
            UnixEndpoint.abstractName(abstractName("wirestack-m8-003-dgram"))
        )
        let sender = UnixDatagramSocket.bind(
            UnixEndpoint.abstractName(abstractName("wirestack-m8-003-sender"))
        )
        let destination = UnixEndpoint.abstractName(abstractName("wirestack-m8-003-dgram"))
        try {
            let source: Array<Byte> = [7u8, 8u8, 9u8]
            @Expect(sender.sendTo(destination, api.ByteSpan(source)), source.size)
            let result = receiver.receive(8, context: api.OperationContext(
                deadline: Some(api.Deadline.after(3 * Duration.second))
            ))
            @Expect(result.payload, source)
            @Expect(!result.truncated)
        } finally {
            sender.close()
            receiver.close()
        }
    }

    @TestCase
    func unsupportedRawDomainsFailClosed(): Unit {
        let domains = [
            RawSocketDomain.Ipv4,
            RawSocketDomain.Ipv6,
            RawSocketDomain.Packet,
            RawSocketDomain.Netlink
        ]
        for (domain in domains) {
            var rejected = false
            try {
                let _ = RawSocket.open(domain)
            } catch (error: api.NetworkException) {
                match (error.code) {
                    case api.NetworkErrorCode.Unsupported => rejected = true
                    case _ => ()
                }
            }
            @Expect(rejected)
        }
    }
}
