package wirestack_m12_002_trust

import std.fs.*
import std.time.*
import wirestack.http.*
import wirestack.tls.TlsEngineException
import wirestack.tls.TlsEngineErrorCode

// The default builder selects system trust. Explicit DER selects only that CA.
main(args: Array<String>): Int64 {
    if (args.size < 2 || args.size > 3) { println("ERROR usage"); return 2 }
    let resolver = SystemResolver(workerCount: 1, queueCapacity: 4)
    var material = None<HttpClientTlsConfig>
    var client = None<HttpClient>
    try {
        let builder = HttpClient.builder().resolver(resolver).requestTimeout(5 * Duration.second)
        if (args[0] == "explicit") {
            if (args.size != 3) { println("ERROR usage"); return 2 }
            if (!exists(args[2])) { println("ERROR ca_file_missing"); return 1 }
            let info = FileInfo(args[2])
            if (!info.isRegular() || info.size < 1 || info.size > 65536) { println("ERROR ca_file_invalid"); return 1 }
            let tls = HttpClientTlsConfig([File.readFrom(args[2])])
            material = Some(tls)
            builder.tls(tls)
        } else if (args[0] != "system") { println("ERROR usage"); return 2 }
        let ready = builder.build()
        client = Some(ready)
        let response = ready.get(args[1], context: OperationContext(deadline: Some(Deadline.after(5 * Duration.second))))
        try {
            let buffer = Array<Byte>(32, repeat: 0u8)
            let count = response.body.read(buffer)
            if (response.status != 200 || count != 8 || String.fromUtf8(buffer[..count]) != "download") {
                println("ERROR response_mismatch"); return 1
            }
            if (response.body.read(buffer) != 0) { println("ERROR body_not_bounded"); return 1 }
            println("TRUST_DOWNLOAD_PASS bytes=8")
            0
        } finally { response.close() }
    } catch (error: TlsEngineException) {
        match (error.tlsCode) {
            case TlsEngineErrorCode.CertificateUntrusted => println("ERROR certificate_untrusted phase=tls_handshake")
            case _ => println("ERROR tls_failure phase=tls_handshake")
        }
        1
    } catch (error: HttpException) {
        println("ERROR http_failure")
        1
    } catch (_: IllegalArgumentException) {
        println("ERROR invalid_trust_configuration")
        1
    } catch (_: Exception) {
        println("ERROR trust_unavailable")
        1
    } finally {
        if (let Some(value) <- client) { value.close() }
        if (let Some(value) <- material) { value.close() }
        resolver.close()
    }
}
