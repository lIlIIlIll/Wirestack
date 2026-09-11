import std.net.*

main(): Int64 {
    let receiver = UdpSocket(bindAt: IPSocketAddress(IPv4Address(127, 0, 0, 1), 0))
    try {
        receiver.bind()
        receiver.receiveTimeout = Some(10 * Duration.second)
        println("UDP_ZERO_RECEIVE_READY")
        receiver.sendTo(IPSocketAddress(IPv4Address(127, 0, 0, 1), 41599), [1u8])
        let (sender, count) = receiver.receiveFrom(Array<Byte>(1, repeat: 0))
        println("ZERO_RECEIVED count=${count}; sender=${sender}; closed=${receiver.isClosed()}")
        if (count == 0) { 0 } else { 1 }
    } catch (error: Exception) {
        println("ZERO_RECEIVE_FAILURE=${error}; closed=${receiver.isClosed()}")
        1
    } finally {
        receiver.close()
    }
}
