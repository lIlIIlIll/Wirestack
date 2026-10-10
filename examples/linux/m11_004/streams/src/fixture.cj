package wirestack_m11_004_streams

import std.env.*
import std.fs.File
import wirestack.http.*

func runFixture(certPath: String, keyPath: String): Unit {
    let server = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(StreamFixture())
        .tls(HttpServerTlsConfig([File.readFrom(certPath)], File.readFrom(keyPath))).build()
    let serving = spawn { server.serve() }
    try {
        println("STREAM_READY port=${server.localEndpoint.port}"); getStdOut().flush()
        let stop = Array<Byte>(1, repeat: 0u8); let input = getStdIn()
        for (expected in "stop\n".toArray()) { require(input.read(stop) == 1 && stop[0] == expected) }
    } finally {
        let stopped = server.shutdown(context: owner())
        require(stopped.activeAtReturn == 0); serving.get(5 * Duration.second)
    }
    println("STREAM_STOPPED"); getStdOut().flush()
}
