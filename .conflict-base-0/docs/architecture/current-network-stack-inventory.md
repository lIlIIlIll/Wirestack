# Current Cangjie TLS/HTTP/std.net Inventory

**Task:** M0-001  
**Issue:** #1  
**Status:** Complete for source and supplied-SDK inventory; runtime semantics remain subject to M0 gates  
**Inspection date:** 2026-08-22

## 1. Inputs and source pins

| Input | Pin | Purpose |
|---|---|---|
| Supplied Cangjie SDK | SHA-256 `bc2ed8a34b9b6846a5445d3eba0ac66b146730a005d3df56d45a2b119416f40d` | Actual compiler, CJPM, module and runtime inspection |
| `cangjielanguage/cangjie_stdx` | `9581a10b9b81b259155c26701afe1478d4892f32` | Existing `stdx.net.tls` / `stdx.net.http`, build and distribution inspection |
| `cangjielanguage/cangjie_runtime` | `335fc487d782a566e3240004522ba55b38989369` | Existing `std.net` source and runtime-facing semantics |

The source pins are inspection snapshots. The supplied SDK archive does not carry
source provenance that cryptographically proves those commits were used to build
its binaries. Conclusions below distinguish observed SDK artifacts from source
structure.

## 2. Executive conclusions

1. The supplied SDK provides a usable Linux x86_64 Cangjie 1.1.0-alpha toolchain,
   CJPM 1.1.3, and core `std.net` modules/runtime. It does not include `stdx` TLS/HTTP.
2. Existing `stdx.net.tls` is not merely implemented with OpenSSL; OpenSSL is part
   of its compile, link, distribution, and runtime-resolution contract.
3. Existing TLS public abstractions directly expose `std.net.StreamingSocket` and
   use a mutable process-global `TlsKit` registration point.
4. Existing `TlsSocket` delegates mutable read/write timeouts to the underlying
   socket, accepts a separate handshake timeout, and inherits the ambiguous
   `read() == 0` close/EOF model.
5. Existing `stdx.net.http` imports `std.net.*` and TLS common directly. Its public
   connector returns `StreamingSocket`, and timeout ownership is split into read
   and write durations rather than one end-to-end absolute deadline.
6. Current `std.net.TcpSocket` is still valuable as the runtime-integrated TCP
   substrate, but its string-address constructor, mutable relative timeouts,
   whole-array I/O, and conflated zero-read result cannot define Wirestack's core
   semantics.
7. Wirestack should reuse `std.net` only behind `wirestack.internal.transport_stdnet`;
   old TLS/HTTP types and the OpenSSL bridge remain migration/reference material,
   not implementation dependencies.

## 3. Current dependency graph

```text
stdx.net.http
  ├── std.net.*
  ├── stdx.net.tls.common
  ├── stdx.encoding.url
  ├── stdx.log
  └── HTTP/1.1 + HTTP/2 implementation in one product package

stdx.net.tls
  ├── std.net.StreamingSocket / SocketAddress
  ├── stdx.net.tls.common
  ├── stdx.crypto.keys / x509 / common
  ├── stdx.net.tlsFFI
  └── cangjie-dynamicLoader-opensslFFI
       └── system or application-provided OpenSSL 3.x symbols/libraries

std.net
  ├── TcpSocket / TcpServerSocket / StreamingSocket
  ├── CJThread/runtime socket wait and wakeup path
  └── OS socket implementation
```

This graph violates the Wirestack target boundary because HTTP and the TLS public
surface both depend directly on `std.net`, while TLS also exposes a provider- and
OpenSSL-shaped native bridge.

## 4. Existing package and public-surface inventory

### 4.1 `stdx.net.tls.common`

Representative public surface:

- `TlsKit`
- `TlsConnection`
- `TlsConfig`
- `TlsSession`
- `TlsException`
- `setGlobalTlsKit`
- `getGlobalTlsKit`

`TlsKit` accepts and returns abstractions built around `std.net.StreamingSocket`.
The package owns a mutable process-global optional `TlsKit`. Importing the default
TLS package installs `DefaultTlsKit` through static initialization.

Disposition:

- **Delete from the new design:** global provider registration and lookup.
- **Do not carry into public API:** `StreamingSocket` parameters/returns.
- **Migration reference only:** naming and behavior documentation.

### 4.2 `stdx.net.tls`

Representative implementation/public files:

```text
alpn.cj
certificate.cj
cipher_suite.cj
context.cj
default_tls_kit.cj
handshake.cj
native.cj
session.cj
tls_client_config.cj
tls_server_config.cj
tls_socket.cj
tls_socket_state.cj
native/*.c
```

Observed behavior:

- `TlsSocket` owns a `StreamingSocket` and exposes its local/remote address.
- `readTimeout` and `writeTimeout` mutate the underlying socket properties.
- `handshake(timeout)` introduces another relative timeout owner.
- `read(Array<Byte>)` uses zero both for a self-closed stream and for peer EOF in
  the inherited socket contract.
- Concurrent close can surface either `SocketException` or `TlsException` based
  on timing.
- Native calls use OpenSSL-oriented `Ctx`/`Ssl` handles and `CJ_TLS_DYN_*` bridge
  functions; native error text is converted directly into `TlsException` messages.

Disposition:

- **Delete:** global/default-kit bootstrap, message-text control semantics, and
  legacy timeout ownership.
- **Isolate as provider work only:** reusable ideas around external byte-stream
  driving, ALPN/SNI/session handling, after provider selection and revalidation.
- **Do not copy:** current `TlsSocket` state machine or public API.
- **Reference:** existing interop scenarios, certificate/session concepts, and
  legacy migration mapping.

### 4.3 `stdx.net.http`

Representative surface and implementation areas:

- `ClientBuilder`, `Client`
- `ServerBuilder`, `Server`
- request/response/header/body models
- connection pooling
- proxy environment handling
- cookies and redirect logic
- HTTP/1.1 codec/framing
- HTTP/2 frames, HPACK, flow control, stream scheduling

Observed coupling and resource issues:

- The package imports `std.net.*` and `stdx.net.tls.common.*` directly.
- The public connector is a function from `SocketAddress` to `StreamingSocket`.
- Client configuration has independent read and write timeout values.
- HTTP/2 defaults include `UInt32(2^31 - 1)` maximum concurrent streams and
  `UInt32.Max` maximum header-list size, which do not meet Wirestack's rule that
  all queues, tables, windows, and parser limits have explicit safe bounds.
- TLS configuration is supplied through the old `TlsConfig` hierarchy.

Disposition:

- **Do not reuse as the new product package:** direct network/TLS coupling and
  timeout/resource semantics are incompatible with the PRD.
- **Reference after security review:** protocol vectors, parser edge cases,
  HPACK/framing logic, proxy/redirect behavior, and compatibility tests.
- **Reimplement behind new boundaries:** client/server orchestration, pooling,
  HTTP/1.1, HTTP/2, retry, redirect, proxy and streaming body semantics.

### 4.4 `std.net`

Relevant public capabilities:

- `TcpSocket(SocketAddress)` and `TcpServerSocket`
- runtime-integrated connect/read/write/accept waits
- local/remote address access
- native close and socket options
- one-reader/one-writer baseline concurrency model

Observed incompatible semantics:

- `TcpSocket(String, port)` invokes `resolveHelper`, coupling DNS to socket
  construction and the default address-selection path.
- `readTimeout` and `writeTimeout` are mutable relative durations.
- `connect(timeout)` has its own relative timeout.
- `read(Array<Byte>)` documents zero for either peer close or local socket close.
- `write(Array<Byte>): Unit` has no public partial-write result.
- I/O accepts whole arrays rather than offset/length or span views.
- public error information is not sufficient by itself for Wirestack's stable
  category/phase/retryability model.

Disposition:

- **Reuse behind adapter:** runtime-integrated TCP connect/read/write/listen/accept,
  close, endpoint access, and stable typed socket options.
- **Never call from Core:** all access goes through Transport SPI.
- **Reject:** string-address constructor, socket timeout as total request budget,
  message parsing as control flow, and raw private runtime handles.
- **Gate before acceptance:** close wakeup, cancellation latency, EOF evidence,
  full-duplex races, copying, leaks, and mobile network changes.

## 5. Native and OpenSSL dependency inventory

The existing stdx manifest links:

```text
stdx.net.tls:
  cangjie-dynamicLoader-opensslFFI
  stdx.net.tlsFFI
  stdx.crypto.keysFFI
  stdx.crypto.x509FFI

stdx.net.http:
  cangjie-dynamicLoader-opensslFFI
```

The TLS native CMake target compiles a substantial C bridge (`tls_bio.c`,
`tls-impl.c`, sessions, ciphers, hostname, provider and key/certificate code),
includes OpenSSL headers, combines OpenSSL-loader objects into static archives,
and links the shared TLS FFI target to the dynamic OpenSSL loader.

The current stdx distribution documentation further states:

- dynamic libraries resolve OpenSSL at runtime using `dlopen/dlsym` or
  `LoadLibrary/GetProcAddress`;
- default static libraries may fall back to runtime OpenSSL discovery;
- the external-static variant requires applications to provide `libssl.a` and
  `libcrypto.a` explicitly;
- OpenSSL 3.x and consistent compile/link/runtime versions are required.

Wirestack decision:

- no dependency on `stdx.net.tlsFFI` or the dynamic OpenSSL loader;
- no runtime provider guessing or automatic fallback;
- provider selection is build-time and recorded in a manifest;
- default artifacts must report no system OpenSSL dependency.

## 6. Build and distribution inventory

Current stdx build paths include:

- root CMake/build.py flow, requiring an OpenSSL library location;
- CJPM static-package build;
- target-specific configuration for Linux, macOS, Windows and OHOS;
- CMake toolchain files for Android and iOS as well as desktop targets;
- separate dynamic, default-static and external-static output modes.

The documented downloadable binary matrix currently lists Linux aarch64/x64,
macOS aarch64/x64, OHOS aarch64/x64 and Windows x64. Android and iOS are not in
that quick-download matrix. The supplied SDK itself contains only Linux x86_64
and Windows x86_64 `std.net` artifacts.

Wirestack implication:

- the repository must not infer six-platform readiness from source toolchain
  files or cross-compilation alone;
- target manifests, native dependencies and actual runner/device evidence must
  be recorded separately per platform;
- M0 and release gates remain blocked where native execution is unavailable.

## 7. Existing tests and evidence baseline

### Available today

- Existing stdx source and API documentation provide behavior and build examples.
- Existing TLS/HTTP implementation contains protocol and state-machine material
  that can inform new test cases.
- The supplied SDK can compile and link Wirestack packages against `std.net` on
  Linux x86_64.
- The SDK contains Windows x86_64 `std.net` binary artifacts for later native
  validation.

### Not supplied or not accepted as evidence

- The SDK archive contains no stdx TLS/HTTP source tests or test corpus.
- No Windows native execution was performed in the inspection container.
- No macOS, Android, iOS or HarmonyOS/OHOS runtime artifact or device was supplied.
- Existing legacy tests, even when available, cannot prove Wirestack's absolute
  Deadline, structured EOF, cancellation, bounded-resource or provider-isolation
  semantics.

### Required new evidence

M0-004 and later tasks must establish deterministic and native test evidence for:

- close waking blocked read/write/connect/accept;
- exactly-once completion and cancellation races;
- peer FIN/RST versus local close/abort;
- partial I/O and absolute Deadline accounting;
- allocation/copy/thread/RSS measurements;
- DNS carrier-thread behavior;
- platform network changes;
- TLS/HTTP conformance, fuzz, interop and security corpora.

## 8. Platform difference matrix

| Platform | Supplied SDK artifact | Existing source/build indication | M0-001 evidence level |
|---|---:|---|---|
| Linux x86_64 | Yes; executed | std.net + stdx build paths | Toolchain and build probe verified |
| Windows x86_64 | Yes; not executed | std.net + stdx target/link settings | Artifact inventory only |
| macOS | No | stdx target and download entries | Source/documentation only |
| Android | No | CMake toolchain files | Source infrastructure only |
| iOS | No | CMake toolchain files | Source infrastructure only |
| HarmonyOS/OHOS | No in supplied SDK | stdx target and download entries | Source/documentation only |

No platform above is considered to have passed a Wirestack network gate as part
of M0-001.

## 9. Path disposition map

| Current path or concept | Decision | Rationale |
|---|---|---|
| `std.net` TCP client/server runtime path | Reuse through adapter | Preserves CJThread/runtime integration |
| `TcpSocket(String, port)` | Reject | Hides DNS and address selection |
| mutable socket read/write timeout | Reject as operation budget | Cannot represent one absolute end-to-end deadline |
| `read() == 0` current semantics | Isolate and gate | Conflates peer EOF and local close |
| whole-array read/write API | Adapt temporarily; seek upstream span/partial I/O if gates fail | Correctness possible with bounded staging, performance uncertain |
| `stdx.net.tls.common.TlsKit` global | Delete | Mutable process-global provider and public `std.net` leakage |
| `stdx.net.tls.TlsSocket` | Migration reference only | Wrong ownership, timeout and EOF contract |
| `stdx.net.tls/native` OpenSSL bridge | Do not depend on | Violates default artifact and provider boundary goals |
| old TLS certificate/session/ALPN concepts | Reference and revalidate | Useful requirements, not reusable API contracts |
| `stdx.net.http` orchestration/package | Reimplement | Direct std.net/TLS coupling and split timeout ownership |
| old HTTP parser/HPACK/test vectors | Candidate reference after audit | May reduce research cost but must pass new security/resource rules |
| old public API docs/examples | Migration source | Needed for mapping guides, not compatibility implementation |

## 10. Consequences for subsequent tasks

M0-002 may now freeze a real CJPM package layout using the supplied SDK.
M0-004 may start in parallel because its only dependency, M0-001, is complete.

The following remain explicitly unresolved until their gates run:

- whether close reliably wakes every blocked operation on every target;
- whether local close can be distinguished from peer EOF without upstream work;
- whether per-operation cancellation requires a new runtime/std.net API;
- whether current array I/O and Windows data paths meet copy/throughput targets;
- whether resolver calls block scheduler carrier threads;
- the exact minimum OS/API versions and mobile listener support level;
- the TLS provider choice.

No `UP-*` task is unlocked by this inventory alone.
