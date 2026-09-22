import std.net.*

func probe(socket: UdpSocket, label: String): Unit {
    let value = LibC.malloc<Int32>()
    let length = LibC.malloc<UIntNative>()
    try {
        unsafe {
            value.write(1)
            socket.setSocketOption(1, 6, CPointer<Unit>(value), 4)
            value.write(-1)
            length.write(4)
            socket.getSocketOption(1, 6, CPointer<Unit>(value), length)
            println("${label}: broadcast=${value.read()} length=${length.read()}")
            if (value.read() != 1 || length.read() != 4) {
                throw Exception("raw option readback mismatch")
            }
        }
    } finally {
        unsafe { LibC.free(value); LibC.free(length) }
    }
}

main(): Int64 {
    let socket = UdpSocket(bindAt: 0)
    try {
        probe(socket, "before-bind")
        socket.bind()
        probe(socket, "after-bind")
        return 0
    } finally { socket.close() }
}
