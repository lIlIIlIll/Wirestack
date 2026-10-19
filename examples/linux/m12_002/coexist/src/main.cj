package wirestack_m12_002_coexist

import std.fs.*
import std.sync.*
import wirestack.http.*
import wirestack.tls.TlsRuntime
import independent_math.checkedNativeWork

foreign func fixture_independent_tls(port: UInt16): Int32

func require(ok: Bool): Unit { if (!ok) { throw IllegalStateException("coexistence assertion") } }
func bytes(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        require(file.length > 0 && file.length < 65536)
        let result = Array<Byte>(file.length, repeat: 0u8)
        var offset: Int64 = 0
        while (offset < result.size) { let n = file.read(result[offset..]); require(n > 0); offset += n }
        result
    } finally { file.close() }
}
class Handler <: HttpServerHandler {
    public func handle(request: HttpServerRequest, context: OperationContext): HttpServerResponse {
        request.body.close()
        HttpServerResponse(HttpResponse(200, "OK", ResponseBody(RequestBody.string("coexist-native-work").open())))
    }
}
main(args: Array<String>): Int64 {
    require(args.size == 2)
    let info = TlsRuntime.info()
    require(info.tlsProvider == "aws-lc" && info.tlsProviderVersion == "5.5.0" && !info.externalOpenSslDependency)
    println("IDENTITY wirestack ${info.tlsProvider} ${info.tlsProviderVersion} ${info.buildFingerprint}")
    require(checkedNativeWork() == 985)
    println("CHECK independent_cangjie_native PASS")
    let certificate = bytes(args[0])
    let material = HttpServerTlsConfig([certificate], bytes(args[1]))
    let trust = HttpClientTlsConfig([certificate])
    let ip = IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
    let server = HttpServer.builder().listen(SocketEndpoint(ip, 0u16)).handler(Handler()).tls(material).build()
    let serving = spawn { server.serve() }
    let resolver = StaticResolver(ResolveResult([ip], HostName("example.test"), ResolverSource.Static))
    let client = HttpClient.builder().resolver(resolver).tls(trust).build()
    try {
        let owner = OperationContext(deadline: Some(Deadline.after(10 * Duration.second)))
        let response = client.get("https://example.test:${server.localEndpoint.port}/", context: owner)
        try {
            require(response.status == 200)
            let buffer = Array<Byte>(256, repeat: 0u8)
            var body = ""
            while (true) { let n = response.body.read(buffer); if (n == 0) { break }; body += String.fromUtf8(buffer[..n]) }
            require(body == "coexist-native-work")
        } finally { response.close() }
        println("CHECK wirestack_verified_tls PASS")
        let external = unsafe { fixture_independent_tls(server.localEndpoint.port) }
        require(external == 0)
        println("CHECK independent_verified_tls PASS")
        let repeated = HttpClient.builder().resolver(resolver).tls(trust).build()
        try {
            let fresh = repeated.get("https://example.test:${server.localEndpoint.port}/", context: OperationContext(deadline: Some(Deadline.after(10 * Duration.second))))
            try {
                require(fresh.status == 200)
                let buffer = Array<Byte>(256, repeat: 0u8)
                var body = ""
                while (true) { let n = fresh.body.read(buffer); if (n == 0) { break }; body += String.fromUtf8(buffer[..n]) }
                require(body == "coexist-native-work")
            } finally { fresh.close() }
        } finally { repeated.close() }
        println("CHECK wirestack_after_independent_cleanup PASS")
        require(checkedNativeWork() == 985 && TlsRuntime.info().buildFingerprint == info.buildFingerprint)
        println("CHECK same_process_identity_preserved PASS")
    } finally {
        client.close(); server.close(); serving.get(); material.close(); trust.close()
    }
    0
}
