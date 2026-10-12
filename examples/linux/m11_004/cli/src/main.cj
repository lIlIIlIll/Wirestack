package wirestack_m11_004_cli

import std.fs.*
import std.convert.*
import std.console.Console
import std.io.*
import std.sync.*
import std.time.*
import wirestack.http.*

class DownloadFailure <: Exception {
    let code: Int64
    init(code: Int64) { super("download failed"); this.code = code }
}
func require(value: Bool): Unit { if (!value) { throw DownloadFailure(90) } }
func operation(ms!: Int64 = 5000, token!: CancellationToken = CancellationToken.none()): OperationContext {
    OperationContext(deadline: Some(Deadline.after(ms * Duration.millisecond)), cancellation: token)
}
func checkOperation(context: OperationContext): Unit {
    if (context.isCancellationRequested()) { throw NetworkException(NetworkErrorCategory.Cancelled, NetworkPhase.HttpBody, NetworkErrorCode.Cancelled, "cancelled") }
    if (context.isDeadlineExceeded()) { throw NetworkException(NetworkErrorCategory.DeadlineExceeded, NetworkPhase.HttpBody, NetworkErrorCode.TimedOut, "deadline") }
}
// DOC-BEGIN cli-download
func download(client: HttpClient, url: String, output: String, context: OperationContext,
    maximum!: Int64 = 1048576, progress!: () -> Unit = { => }): Int64 {
    checkOperation(context)
    if (exists(output) || exists(output + ".partial")) { throw DownloadFailure(4) }
    let response = client.get(url, context: context)
    let partial = output + ".partial"
    var owned = false
    var published = false
    try {
        if (response.status != 200) { throw DownloadFailure(5) }
        let file = try { File.create(partial) } catch (_: IOException) { throw DownloadFailure(4) }
        owned = true
        var total = 0
        try {
            let buffer = Array<Byte>(4096, repeat: 0u8)
            while (true) {
                checkOperation(context)
                let count = response.body.read(buffer)
                if (count == 0) { break }
                if (count > maximum - total) { throw DownloadFailure(3) }
                try { file.write(buffer[..count]) } catch (_: IOException) { throw DownloadFailure(4) }
                total += count
                progress()
            }
            checkOperation(context)
        } finally { file.close() }
        try { rename(partial, to: output) } catch (_: IOException) { throw DownloadFailure(4) }
        published = true
        total
    } finally {
        try { response.close() } finally { if (owned && !published) { removeIfExists(partial) } }
    }
}
// DOC-END cli-download

class ProxyAuth <: HttpProxyAuthorizationProvider {
    let value: String
    init(value: String) { this.value = value }
    public func authorization(proxy: HttpProxyEndpoint, target: HttpUrl, context: OperationContext): ?String { Some(value) }
}
func proxyEndpoint(url: HttpUrl): HttpProxyEndpoint {
    if (!url.host.contains(":")) {
        let parts = url.host.split(".")
        var numeric = parts.size == 4
        for (byte in url.host.toArray()) { if ((byte < b'0' || byte > b'9') && byte != b'.') { numeric = false } }
        if (!numeric) { return HttpProxyEndpoint.hostname(url.host, url.port) }
        let octets = Array<Byte>(4, repeat: 0u8)
        for (i in 0..4) { octets[i] = UInt8.parse(parts[i]) }
        return HttpProxyEndpoint.address(IpAddress(IpAddressFamily.Ipv4, octets), url.port)
    }
    let halves = url.host.split("::")
    let result = Array<Byte>(16, repeat: 0u8)
    var left = 0; var right = 16
    for (side in 0..halves.size) {
        if (halves[side].isEmpty()) { continue }
        let groups = halves[side].split(":")
        var width = groups.size * 2
        if (groups[groups.size - 1].contains(".")) { width += 2 }
        var offset = if (side == 0) { left } else { right - width }
        for (group in groups) {
            if (group.contains(".")) {
                for (part in group.split(".")) { result[offset] = UInt8.parse(part); offset++ }
            } else {
                var value = 0u16
                for (byte in group.toAsciiLower().toArray()) {
                    let digit = if (byte <= b'9') { byte - b'0' } else { byte - b'a' + 10u8 }
                    value = (value << 4) | UInt16(digit)
                }
                result[offset] = UInt8(value >> 8); result[offset + 1] = UInt8(value & 255u16); offset += 2
            }
        }
        if (side == 0) { left = offset } else { right -= width }
    }
    HttpProxyEndpoint.address(IpAddress(IpAddressFamily.Ipv6, result), url.port)
}
func proxyConfig(endpoint: String, resolver: Resolver, auth: String): HttpProxyConfig {
    let url = HttpUrl.parse("http://" + endpoint)
    if (!url.explicitPort || url.requestTarget != "/") { throw DownloadFailure(2) }
    HttpProxyConfig(proxyEndpoint(url), resolver,
        authorizationProvider: if (auth.isEmpty()) { None<HttpProxyAuthorizationProvider> } else { Some(ProxyAuth(auth)) })
}
func usage(): Unit {
    println("download --url HTTPS_URL --output FILE --trust DER [--proxy HOST:PORT] [--proxy-authorization VALUE] [--budget-ms 1..60000] [--max-bytes 1..1048576] [--pre-cancel] [--cancel-after-bytes N]")
    println("self-check CERT_DER KEY_PKCS8_DER UNTRUSTED_DER [PROXY_PORT]")
    println("fixture CERT_DER KEY_PKCS8_DER")
}
func runDownload(args: Array<String>): Int64 {
    var url = ""; var output = ""; var trust = ""; var proxy = ""; var auth = ""
    var budget = 5000; var maximum = 1048576; var after = 0; var pre = false
    var i = 1
    while (i < args.size) {
        let flag = args[i]; i++
        if (flag == "--pre-cancel") { pre = true; continue }
        if (i >= args.size) { throw DownloadFailure(2) }
        let value = args[i]; i++
        match (flag) {
            case "--url" => url = value
            case "--output" => output = value
            case "--trust" => trust = value
            case "--proxy" => proxy = value
            case "--proxy-authorization" => auth = value
            case "--budget-ms" => budget = Int64.parse(value)
            case "--max-bytes" => maximum = Int64.parse(value)
            case "--cancel-after-bytes" => after = Int64.parse(value)
            case _ => throw DownloadFailure(2)
        }
    }
    if (url.isEmpty() || output.isEmpty() || trust.isEmpty() || budget < 1 || budget > 60000 || maximum < 1 || maximum > 1048576 || after < 0 || after > maximum) { throw DownloadFailure(2) }
    require(HttpUrl.parse(url).scheme == "https")
    let source = CancellationSource()
    let context = operation(ms: budget, token: source.token)
    if (pre) { source.cancel() }
    let tls = HttpClientTlsConfig([boundedFile(trust)])
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 4)
    var client = None<HttpClient>
    try {
        let builder = HttpClient.builder().resolver(resolver).tls(tls).requestTimeout(budget * Duration.millisecond)
        if (!proxy.isEmpty()) { builder.proxy(proxyConfig(proxy, resolver, auth)) }
        let ready = builder.build(); client = Some(ready)
        let cancellationThreshold = after; let outputPath = output
        let bytes = download(ready, url, output, context, maximum: maximum, progress: { =>
            if (cancellationThreshold > 0 && FileInfo(outputPath + ".partial").size >= cancellationThreshold) { source.cancel() }
        })
        println("DOWNLOAD_PASS bytes=${bytes}")
        0
    } finally { if (let Some(value) <- client) { value.close() }; resolver.close(); tls.close() }
}
func boundedFile(path: String): Array<Byte> {
    let file = File(path, OpenMode.Read)
    try {
        let info = file.info
        require(info.isRegular() && info.size > 0 && info.size <= 65536)
        let content = Array<Byte>(info.size, repeat: 0u8)
        let chunk = Array<Byte>(8192, repeat: 0u8)
        var total: Int64 = 0
        while (true) {
            let count = file.read(chunk)
            if (count == 0) { break }
            require(count > 0 && count <= chunk.size && count <= info.size - total)
            for (index in 0 .. count) { content[total + index] = chunk[index] }
            total += count
        }
        require(total == info.size)
        content
    } finally {
        file.close()
    }
}
func phaseName(value: NetworkPhase): String {
    match (value) {
        case NetworkPhase.Dns => "dns"
        case NetworkPhase.AddressSelection => "address_selection"
        case NetworkPhase.TcpConnect => "tcp_connect"
        case NetworkPhase.TcpRead => "tcp_read"
        case NetworkPhase.TcpWrite => "tcp_write"
        case NetworkPhase.TransportClose => "transport_close"
        case NetworkPhase.ProxyConnect => "proxy_connect"
        case NetworkPhase.TlsHandshake => "tls_handshake"
        case NetworkPhase.TlsRead => "tls_read"
        case NetworkPhase.TlsWrite => "tls_write"
        case NetworkPhase.HttpHeaders => "http_headers"
        case NetworkPhase.HttpBody => "http_body"
        case NetworkPhase.PoolAcquire => "pool_acquire"
        case NetworkPhase.ServerAccept => "server_accept"
        case _ => "other"
    }
}
func httpCausePhase(error: HttpException): String {
    if (let Some(cause) <- error.cause) {
        match (cause) { case network: NetworkException => return phaseName(network.phase); case _ => () }
    }
    "not_available"
}
main(args: Array<String>): Int64 {
    try {
        if (args.isEmpty() || args[0] == "--help" || args[0] == "help") { usage(); return 0 }
        match (args[0]) {
            case "download" => runDownload(args)
            case "self-check" => selfCheck(args[1..])
            case "fixture" => fixture(args[1..])
            case _ => throw DownloadFailure(2)
        }
    } catch (error: DownloadFailure) { Console.stdErr.write("ERROR category=application code=${error.code}\n".toArray()); if (error.code == 2) { 2 } else { 1 } }
      catch (error: NetworkException) { let code = match (error.code) { case NetworkErrorCode.Cancelled => 1; case NetworkErrorCode.TimedOut => 2; case NetworkErrorCode.ResourceExhausted => 3; case NetworkErrorCode.UnexpectedEof => 4; case _ => 99 }; Console.stdErr.write("ERROR category=network phase=${phaseName(error.phase)} code=${code}\n".toArray()); 1 }
      catch (error: HttpException) { let code = match (error.code) { case HttpErrorCode.PoolExhausted => 3; case HttpErrorCode.StreamReset => 4; case _ => 99 }; Console.stdErr.write("ERROR category=http phase=${httpCausePhase(error)} code=${code}\n".toArray()); 1 }
      catch (_: IllegalArgumentException) { Console.stdErr.write("ERROR category=usage code=2\n".toArray()); 2 }
      catch (_: Exception) { Console.stdErr.write("ERROR category=application code=99\n".toArray()); 1 }
}
