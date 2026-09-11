import std.net.*

main(): Int64 {
    let loopback = IPSocketAddress(IPv4Address(127, 0, 0, 1), 0)
    let listener = TcpServerSocket(bindAt: loopback)
    listener.bind()
    let client = TcpSocket(listener.localAddress)
    try {
        client.connect(timeout: Some(Duration.second))
        let accepted = listener.accept(timeout: Some(Duration.second))
        try {
            client.write([0x42u8])
            accepted.readTimeout = Some(Duration.second)
            let buffer = Array<Byte>(1, repeat: 0)
            if (accepted.read(buffer) != 1 || buffer[0] != 0x42u8) {
                throw Exception("TCP primitive payload mismatch")
            }
            println("TCP_LOOPBACK_PASS")
        } finally {
            accepted.close()
        }
    } finally {
        client.close()
        listener.close()
    }

    let sender = UdpSocket(bindAt: loopback)
    let receiver = UdpSocket(bindAt: loopback)
    var emptyDelivered = false
    try {
        sender.bind()
        receiver.bind()
        receiver.receiveTimeout = Some(200 * Duration.millisecond)
        try {
            sender.sendTo(receiver.localAddress, Array<Byte>())
            let (_, count) = receiver.receiveFrom(Array<Byte>(1, repeat: 0))
            emptyDelivered = count == 0
            println("EMPTY_DATAGRAM_COUNT=${count}")
        } catch (error: Exception) {
            println("EMPTY_DATAGRAM_FAILURE=${error}; senderClosed=${sender.isClosed()}")
        }
        sender.sendTo(receiver.localAddress, [1u8, 2u8, 3u8, 4u8, 5u8])
        let buffer = Array<Byte>(3, repeat: 0)
        let (_, count) = receiver.receiveFrom(buffer)
        if (count != 3 || buffer != [1u8, 2u8, 3u8]) {
            throw Exception("UDP truncation primitive mismatch")
        }
        sender.connect(receiver.localAddress)
        try {
            sender.send(Array<Byte>())
            let (_, emptyCount) = receiver.receiveFrom(buffer)
            println("CONNECTED_EMPTY_COUNT=${emptyCount}")
        } catch (error: Exception) {
            println("CONNECTED_EMPTY_FAILURE=${error}; senderClosed=${sender.isClosed()}")
        }
        sender.send([9u8, 10u8])
        let (_, exactCount) = receiver.receiveFrom(buffer)
        if (exactCount != 2 || buffer[0] != 9u8 || buffer[1] != 10u8) {
            throw Exception("connected UDP primitive mismatch")
        }
        println("UDP_TRUNCATION_AND_CONNECTED_SEND_PASS")
    } finally {
        sender.close()
        receiver.close()
    }
    if (emptyDelivered) { 0 } else { 1 }
}
