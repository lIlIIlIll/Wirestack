package wirestack_m11_002_raw
import std.sync.*
import wirestack.http.*

func require(value: Bool, message: String): Unit { if (!value) { throw IllegalStateException(message) } }
func loopback(): IpAddress { IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8]) }
func member(): Array<Byte> { [
        31u8, 139u8, 8u8, 0u8, 0u8, 0u8, 0u8, 0u8, 2u8, 255u8, 203u8, 72u8, 205u8, 201u8, 201u8, 87u8, 72u8, 175u8, 202u8, 44u8, 0u8, 0u8, 25u8, 106u8,
        210u8, 223u8, 10u8, 0u8, 0u8, 0u8
    ] }
class RawHandler <: HttpServerHandler {
    let negotiated = AtomicBool(false)
    public func handle(request: HttpServerRequest, owner: OperationContext): HttpServerResponse {
        negotiated.store(request.headers.contains("accept-encoding"))
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.bytes(member()).open()),
            headers: HttpHeaders.builder().add("Content-Encoding", "gzip").add("Content-Length", "30").build()))
    }
}
main(): Int64 {
    let handler = RawHandler()
    let server = HttpServer.builder().listen(SocketEndpoint(loopback(), 0u16)).handler(handler).build()
    let serving = spawn { server.serve() }
    let client = HttpClient.builder().requestTimeout(10 * Duration.second).build()
    try {
        let response = client.get("http://127.0.0.1:${server.localEndpoint.port}/raw")
        try {
            require(response.headers.getFirst("Content-Encoding") == Some("gzip"), "raw encoding metadata changed")
            require(response.body.contentLength == Some(member().size), "wire length changed")
            let expected = member(); let buffer = Array<Byte>(1, repeat: 0u8); var offset: Int64 = 0
            while (response.body.read(buffer) != 0) {
                require(offset < expected.size && buffer[0] == expected[offset], "default client decoded or changed raw bytes")
                offset++
            }
            require(offset == expected.size && !handler.negotiated.load(), "raw byte count or implicit negotiation differs")
            println("RAW encoded_bytes=${offset} implicit_negotiation=false")
            println("CHECK default_raw_no_negotiation PASS")
        } finally { response.close() }
    } finally {
        client.close(); let _ = server.shutdown(context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
        serving.get(5 * Duration.second); server.close()
    }
    println("M11_002_INSTALLED_RAW_PASS"); 0
}
