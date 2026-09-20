import std.net.*

func attempt(sender: UdpSocket, receiver: UdpSocket, name: String, payload: Array<Byte>): Bool {
    try {
        sender.sendTo(receiver.localAddress, payload)
        let (_, count) = receiver.receiveFrom(Array<Byte>(1, repeat: 0))
        println("${name}: received=${count}")
        count == 0
    } catch (error: Exception) {
        println("${name}: ${error}; senderClosed=${sender.isClosed()}")
        false
    }
}

main(): Int64 {
    let endpoint = IPSocketAddress(IPv4Address(127, 0, 0, 1), 0)
    let sender = UdpSocket(bindAt: endpoint)
    let receiver = UdpSocket(bindAt: endpoint)
    try {
        sender.bind()
        receiver.bind()
        receiver.receiveTimeout = Some(200 * Duration.millisecond)
        let backing = Array<Byte>(1, repeat: 0)
        let allocated = attempt(sender, receiver, "allocated-empty", Array<Byte>(0, repeat: 0))
        let startSlice = attempt(sender, receiver, "backed-start-slice", backing.slice(0, 0))
        let endSlice = attempt(sender, receiver, "backed-end-slice", backing.slice(1, 0))
        if (allocated || startSlice || endSlice) { 0 } else { 1 }
    } finally {
        sender.close()
        receiver.close()
    }
}
