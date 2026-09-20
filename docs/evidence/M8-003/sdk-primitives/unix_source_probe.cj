import std.net.*
import std.env.getVariable
import std.env.getStdOut

main(): Int64 {
    let socket = UnixDatagramSocket(bindAt: getVariable("WIRESTACK_UNIX_PROBE_PATH").getOrThrow())
    try {
        socket.bind()
        socket.receiveTimeout = Some(Duration.second * 15)
        println("SOURCE_PROBE_READY")
        getStdOut().flush()
        for (_ in 0..2) {
            let bytes = Array<Byte>(8, repeat: 0)
            let (source, count) = socket.receiveFrom(bytes)
            println("count=${count} source_size=${source.size} source_bytes=${source.getAddressBytes()}")
            getStdOut().flush()
        }
    } finally { socket.close() }
    return 0
}
