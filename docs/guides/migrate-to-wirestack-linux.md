# Migrate a Linux client or server to Wirestack

Use this guide to replace a timeout-based OpenSSL or legacy global-provider
integration with Wirestack 0.1 on Linux x86_64 glibc. The checked-in examples
run against loopback and a bounded in-memory transport, so validation does not
contact a public host.

## Prerequisites

- Linux x86_64 with glibc.
- Cangjie Compiler `1.1.0-alpha.20260817040003` and CJPM `1.1.3`.
- A Wirestack checkout with its pinned native provider cache available.
- DER certificate chains in leaf-first order and unencrypted DER PKCS#8 keys
  for server or client identities.

The Linux profile uses the build-time AWS-LC provider. It does not support
musl with the pinned SDK, and it does not select a TLS provider at runtime.

## Map old APIs to Wirestack

| Previous behavior | Wirestack API | Migration rule |
|---|---|---|
| Mutable socket timeout | `OperationContext` plus `Deadline.after` | Create one absolute budget and pass the same context through DNS, connect, TLS, headers, and body I/O. |
| Closing a socket to cancel unrelated work | `HttpRequestCancellationHandle`, `HttpConnectionCancellationHandle`, or `HttpStreamCancellationHandle` | Choose the narrowest scope before starting the request. |
| Global TLS provider | `TlsClientContext`, `TlsServerContext`, `HttpClientTlsConfig`, or `HttpServerTlsConfig` | Build immutable configuration and pass it to the client/server that owns it. |
| CA path hidden in OpenSSL settings | `TrustPolicy.customRoots` or `HttpClientTlsConfig` | Supply bounded DER roots explicitly. Custom roots do not disable hostname checks. |
| Callback returning a certificate boolean | `TrustPolicy` and `ReferenceIdentity` | Keep trust-chain validation and DNS/IP identity verification typed and separate. |
| OpenSSL cipher string | `TlsSecurityProfile` and TLS version bounds | Select a documented profile. The ordinary API has no cipher-string input. |
| Socket exception message matching | `NetworkException`, `HttpException`, and stable fields | Branch on type, code, phase, category, and retryability. |
| Unbounded automatic retry | `HttpRetryPolicy` plus `HttpRequest.retrySafety` | Retry only replayable requests and keep a fixed attempt limit. |

The complete runnable sources are under
[`examples/linux/m7_027`](../../examples/linux/m7_027). The acceptance command
copies those exact files into a temporary CJPM project, compiles them as an
external consumer, and runs their assertions.

## Replace relative timeouts with a Deadline

Create the deadline once at the operation boundary. `OperationContext` is
immutable, and child operations may shorten the deadline but cannot extend it.
The examples use this form for client calls and server shutdown:

```cj
let context = OperationContext(
    deadline: Some(Deadline.after(5 * Duration.second))
)
let response = client.get(url, context: context)
```

Do not set a new per-phase timeout after DNS, connect, or TLS completes. A
request-level convenience timeout on `HttpClientBuilder.requestTimeout` only
caps a request that has no earlier caller deadline.

## Choose a cancellation scope

Create a typed handle before calling `getControlled` or `sendControlled`:

- `HttpRequestCancellationHandle` covers routing through response-body EOF.
- `HttpConnectionCancellationHandle` aborts the selected connection. On HTTP/2,
  it affects every stream on that connection.
- `HttpStreamCancellationHandle` resets one HTTP/2 stream. On HTTP/1.1, the
  current request owns the connection, so independent stream cancellation is
  unavailable.

`cancel()` is idempotent. Exactly one caller observes `true`. Server handlers
receive corresponding handles through `HttpServerRequest`, and their
`OperationContext` observes the same cancellation without another timeout
owner. See `runHttp1SseCancellationAndProxyExamples` in
[`http_examples.cj`](../../examples/linux/m7_027/http_examples.cj).

## Configure a custom CA

For the HTTP facade, pass leaf-first DER roots to `HttpClientTlsConfig`, then
install that config with `HttpClient.builder().tls`. For an existing transport,
build a `TlsClientContext` with `TrustPolicy.customRoots`.

Custom roots change trust anchors only. Wirestack still verifies the
`ReferenceIdentity`, keeps SNI separate when requested, and does not fall back
to a Common Name. The loopback HTTPS example proves custom-root verification
for `example.com` before it prints `CUSTOM_CA=PASS`.

## Configure mutual TLS

The server must set `ClientAuthentication.Required`, provide a client
`TrustPolicy`, and own its `LocalIdentity`. The client must provide its own
`LocalIdentity`. Closing each `PrivateKeyRef` after the connection finishes
releases its key material.

[`transport_tls_example.cj`](../../examples/linux/m7_027/transport_tls_example.cj)
performs both public handshakes over a caller-owned bounded transport, verifies
ALPN and peer-certificate evidence, and exchanges application bytes. It prints
`MTLS=PASS` only after the server accepts the required client certificate.

For the HTTP facade, use `HttpServerTlsConfig` with
`HttpServerClientAuthentication.Required` and `clientTrustRootsDer`, then use
`HttpClientTlsConfig` with `clientCertificateChainDer` and
`clientPrivateKeyPkcs8Der`.

## Stream request and response bodies

Implement `HttpBodyStream` when bytes are produced incrementally. Return
`None<Int64>` from `contentLength` when the total is unknown, keep each read
bounded by the supplied destination, and make `close()` idempotent. Wrap the
stream in `RequestBody.streaming` for requests or `ResponseBody` for server
responses.

For HTTP/1.1 responses with unknown length, set `Transfer-Encoding: chunked`.
Do not add that header to HTTP/2. The SSE example makes this protocol-specific
choice, checks `Content-Type: text/event-stream`, reads two complete events, and
then observes EOF. It is a short functional example, not the one-hour SSE
profile.

## Configure bounded retries

Set `HttpRetryPolicy(maximumAttempts: 2)` or another value from 1 through 10.
Wirestack retries only when all of these conditions hold:

- no response was committed;
- the request body is replayable;
- the method or explicit `HttpRetrySafety` permits retry;
- the structured error says retry is safe;
- the shared context is neither cancelled nor expired.

Unknown exceptions, non-replayable bodies, HTTP 4xx/5xx responses, and failures
after the attempt limit do not retry. An HTTP status is a response, not a
transport exception.

## Handle structured errors

Catch the narrow public type first. Use `HttpException.code` for protocol and
policy failures. Use `NetworkException.category`, `phase`, `code`, and
`retryability` for DNS, connect, TLS, read, write, cancellation, and deadline
failures. Inspect `cause` only to preserve diagnostic context.

Do not branch on `Exception.message`. Messages are for operators and may change;
the typed fields are the control-flow contract. The cancellation example checks
`NetworkErrorCategory.Cancelled` and `NetworkErrorCode.Cancelled` before it
prints its pass marker.

## Configure HTTPS through CONNECT

Wirestack reads no proxy environment variables, PAC file, or WPAD state. Build
an `HttpProxyConfig` from an explicit endpoint and resolver, pass it through
`HttpClientBuilder.proxy`, and install `HttpClientTlsConfig` for the origin.
Proxy authorization comes only from `HttpProxyAuthorizationProvider` and is
sent on the proxy request.

The proxy endpoint and origin stay separate. CONNECT targets the origin
authority, and the TLS handshake after CONNECT uses the origin for SNI and
reference-identity verification. The runnable example validates that separation
without requiring an external proxy. Production integration should point the
same configuration at the deployment's authenticated CONNECT proxy.

## Run HTTP/1.1 and HTTP/2 servers

`HttpServer` serves cleartext HTTP/1.1 when no TLS config is present. With
`HttpServerTlsConfig`, it advertises `h2` and `http/1.1` and dispatches from the
negotiated ALPN value. `http2StreamLimit` sets the per-connection concurrent
stream bound. Handler code stays protocol-neutral and reads the selected
version from `HttpServerRequest.version`.

Always stop admission with `shutdown(context:)`, wait for the `serve` task, and
close owned TLS configs. The examples assert zero active connections at
shutdown before reporting either server marker.

## Remove OpenSSL build configuration

Remove application link flags `-lssl` and `-lcrypto`, OpenSSL include paths,
runtime library search paths, copied OpenSSL DLL/shared objects, cipher-string
configuration, and global-provider initialization. Remove CI steps that install
system OpenSSL only for Wirestack.

Keep Wirestack's native provider build inputs intact. `TlsRuntime.info()` is a
read-only way to record the provider version, build fingerprint, target, and
`externalOpenSslDependency` value. It does not change provider selection.

## Verify the migration examples

Run the task gate from the repository root. It prepares only Wirestack's native
dependencies, then builds and runs a temporary consumer:

```terminal
scripts/check-m7-027-linux-examples
```

The command succeeds with this exact line:

```text
M7-027 PASS: Linux migration examples accepted
```

If the gate reports `UNSUPPORTED_PLATFORM` or `UNSUPPORTED_LIBC`, use a native
Linux x86_64 glibc host. A cross-compile does not qualify this task.

