import std.net.*

main(): Int64 {
    let server = TcpServerSocket(bindAt: 0)
    let value = LibC.malloc<Int32>()
    let length = LibC.malloc<UIntNative>()
    try {
        unsafe {
            value.write(1)
            server.setSocketOption(1, 2, CPointer<Unit>(value), 4)
            value.write(-1)
            length.write(4)
            server.getSocketOption(1, 2, CPointer<Unit>(value), length)
            println("before-bind: reuse=${value.read()} length=${length.read()}")
            server.bind()
            value.write(-1)
            length.write(4)
            server.getSocketOption(1, 2, CPointer<Unit>(value), length)
            println("after-bind: reuse=${value.read()} length=${length.read()}")
        }
        return 0
    } finally { server.close(); unsafe { LibC.free(value); LibC.free(length) } }
}
