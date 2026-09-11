import std.net.*
import std.env.getVariable

main(): Int64 {
    let path = getVariable("WIRESTACK_UNIX_PROBE_PATH").getOrThrow()
    let server = UnixServerSocket(bindAt: UnixSocketAddress(path))
    try { server.bind(); println("pathname_bind=PASS") } finally { server.close() }
    let datagram = UnixDatagramSocket(bindAt: UnixSocketAddress(path + ".udp"))
    try { datagram.bind(); println("pathname_datagram_bind=PASS") } finally { datagram.close() }
    return 0
}
