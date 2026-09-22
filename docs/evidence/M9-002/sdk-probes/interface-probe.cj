import std.net.*

@C
struct MulticastInterface {
    var group: UInt32 = 0
    var address: UInt32 = 0
    var index: Int32 = 0
}

main(): Int64 {
    let socket = UdpSocket(bindAt: IPSocketAddress("127.0.0.1", 0))
    let value = LibC.malloc<MulticastInterface>()
    try {
        socket.bind()
        unsafe {
            value.write(MulticastInterface())
            socket.setSocketOption(0, 32, CPointer<Unit>(value), 12)
        }
        println("IPv4 multicast default interface applied with 12-byte ip_mreqn")
        return 0
    } finally { socket.close(); unsafe { LibC.free(value) } }
}
