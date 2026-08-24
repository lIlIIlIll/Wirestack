# Linux HTTP/1 client and server

Wirestack's Linux facade uses typed endpoints and explicit resolvers. It never
consults proxy environment variables, PAC, or WPAD, and the default hostname
resolver fails closed until the SDK exposes a proven bounded async resolver.

## Cleartext client and server

```cj
import std.fs.File
import wirestack.http.*

let loopback = IpAddress(IpAddressFamily.Ipv4, [127u8, 0u8, 0u8, 1u8])
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8080))
    .handler(MyHandler())
    .connectionLimit(256)
    .build()
let serving = spawn { server.serve() }

let host = HostName("service.internal")
let client = HttpClient.builder()
    .resolver(StaticResolver(ResolveResult([loopback], host, ResolverSource.Static)))
    .requestTimeout(5 * Duration.second)
    .build()
let response = client.get("http://service.internal:8080/ready")
try {
    let buffer = Array<Byte>(16 * 1024, repeat: 0)
    let _ = response.body.read(buffer) // Continue until EOF in real code.
} finally {
    response.close()
    client.close()
    let _ = server.shutdown(context: OperationContext(
        deadline: Some(Deadline.after(5 * Duration.second))))
    serving.get(5 * Duration.second)
}
```

`MyHandler` implements `HttpServerHandler` and returns `HttpServerResponse`.
Always consume or close the request body before returning when the connection
should remain reusable.

## TLS HTTP/1 server

Certificate chains are leaf-first DER arrays; private keys are exact,
unencrypted DER PKCS#8 objects.

```cj
let tls = HttpServerTlsConfig(
    [File.readFrom("/etc/wirestack/server-leaf.der")],
    File.readFrom("/etc/wirestack/server-key.pk8")
)
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8443))
    .handler(MyHandler())
    .tls(tls)
    .build()
tls.close() // The built server owns validated provider/key state.
```

The server offers only `http/1.1` ALPN. A client that omits ALPN may use the
standard HTTP/1.1 fallback; an incompatible ALPN fails the handshake.

## HTTPS through an explicit CONNECT proxy

```cj
let proxyHost = HostName("proxy.internal")
let proxyResolver = StaticResolver(ResolveResult(
    [proxyAddress], proxyHost, ResolverSource.Static))
let proxy = HttpProxyConfig(
    HttpProxyEndpoint.hostname("proxy.internal", 3128),
    proxyResolver,
    authorizationProvider: Some(MyProxyAuthorizationProvider())
)
let client = HttpClient.builder()
    .resolver(originResolver)
    .proxy(proxy)
    .requestTimeout(10 * Duration.second)
    .build()
let response = client.get("https://service.internal/private")
```

The authorization hook runs only for the proxy request. Caller-supplied
`Proxy-Authorization` is removed, credentials are sent on CONNECT only, origin
DNS remains independent, and TLS SNI/reference identity remains the origin.

## Mutual TLS

The same custom root and client identity configuration works for direct HTTPS
and HTTPS-over-CONNECT:

```cj
let serverTls = HttpServerTlsConfig(
    [serverLeafDer], serverPrivateKeyPkcs8Der,
    clientAuthentication: HttpServerClientAuthentication.Required,
    clientTrustRootsDer: [clientCaDer]
)
let server = HttpServer.builder()
    .listen(SocketEndpoint(loopback, 8443))
    .handler(MyHandler())
    .tls(serverTls)
    .build()

let clientTls = HttpClientTlsConfig(
    [serverCaDer],
    clientCertificateChainDer: [clientLeafDer],
    clientPrivateKeyPkcs8Der: clientPrivateKeyPkcs8Der
)
let client = HttpClient.builder()
    .resolver(originResolver)
    .tls(clientTls)
    .build()

serverTls.close()
clientTls.close()
```

All DER inputs are bounded and validated before network use. Closing a config
zeroes its retained key copy; the built client/server owns a separate validated
key reference until it is closed.
