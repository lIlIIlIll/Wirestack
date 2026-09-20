import std.net.*

func require(value: Bool, message: String): Unit {
    if (!value) { throw Exception(message) }
}

main(): Int64 {
    let streamName: Array<Byte> = [0, 119, 115, 51, 45, 115, 255, 0, 49]
    let streamAddress = UnixSocketAddress(streamName)
    println("stream_address_size=${streamAddress.size} bytes=${streamAddress.getAddressBytes()}")
    let server = UnixServerSocket(bindAt: streamAddress)
    let client = UnixSocket(streamAddress)
    try {
        server.bind()
        let pending = spawn { => server.accept() }
        client.connect(timeout: Some(Duration.second * 3))
        let peer = pending.get()
        try {
            println("client_local=${client.localAddress.getAddressBytes()}")
            println("peer_remote=${peer.remoteAddress.getAddressBytes()}")
            client.write([1, 2, 3])
            let data = Array<Byte>(3, repeat: 0)
            require(peer.read(data) == 3 && data == [1, 2, 3], "stream bytes changed")
            client.close()
            require(peer.read(data) == 0, "stream EOF missing")
            println("stream=PASS")
        } finally { peer.close() }
    } finally { client.close(); server.close() }
    let firstAddress = UnixSocketAddress([0, 119, 115, 51, 45, 100, 255, 0, 49])
    let secondAddress = UnixSocketAddress([0, 119, 115, 51, 45, 100, 255, 0, 50])
    let first = UnixDatagramSocket(bindAt: firstAddress)
    let second = UnixDatagramSocket(bindAt: secondAddress)
    try {
        first.bind(); second.bind()
        second.receiveTimeout = Some(Duration.second * 3)
        var emptySent = false
        try {
            first.sendTo(secondAddress, Array<Byte>())
            emptySent = true
            println("empty_send=ACCEPTED")
        } catch (error: Exception) { println("empty_send=REJECTED ${error}") }
        let data = Array<Byte>(8, repeat: 0)
        if (emptySent) {
            let (_, count) = second.receiveFrom(data)
            require(count == 0, "empty datagram lost")
        }
        first.sendTo(secondAddress, [4, 5, 6])
        let (source, count) = second.receiveFrom(data)
        require(count == 3 && data[0] == 4 && data[1] == 5 && data[2] == 6, "datagram bytes changed")
        require(source == firstAddress, "datagram source changed")
        println("datagram_source_size=${source.size} bytes=${source.getAddressBytes()}")
        println("datagram=PASS")
    } finally { first.close(); second.close() }
    return 0
}
