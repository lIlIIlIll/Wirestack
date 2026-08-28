# M7-027 test plan

## Semantics

M7-027 documents the supported Linux migration path and ships examples that a
consumer can compile and run without importing `wirestack.internal.*`. The
examples must use the current public API, one absolute `Deadline`, typed
cancellation handles, structured error fields, explicit proxy configuration,
and provider-neutral TLS configuration. They must not depend on OpenSSL build
flags, runtime/std source changes, external network access, or long-running
profiles.

The acceptance gate copies the checked-in example sources into a temporary CJPM
consumer, points that consumer at the current Wirestack package, builds it, and
runs it on native Linux x86_64 glibc. A marker counts only after the example has
checked its observable result. Missing, duplicate, or reordered marker names
fail the gate.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Migration guide maps mutable timeout to one `OperationContext` with an absolute `Deadline` | Documentation contract scan | Reachable | The guide must not introduce a second timeout owner. |
| P002 | Caller cancels request, connection, or HTTP/2 stream through the matching typed handle | Public handle scope and idempotence assertions | Reachable | All three scopes remain distinct. |
| P003 | HTTPS client trusts one explicit custom root and receives a local response | TLS verification, hostname and ALPN checks | Reachable | No external network or system CA is required. |
| P004 | HTTP/1.1 server accepts a cleartext request and shuts down within the same deadline | Native loopback I/O and bounded shutdown | Reachable | Response body is consumed and closed. |
| P005 | TLS server and client negotiate HTTP/2 and the public request reports `Http2` | Native loopback TLS and ALPN dispatch | Reachable | No internal HTTP/2 type is imported. |
| P006 | Caller-provided `DuplexTransport` is upgraded by public client/server TLS contexts | TLS engine pump over a bounded example transport | Reachable | The transport implementation belongs to the example, not Wirestack internals. |
| P007 | Explicit CONNECT proxy route retains origin SNI/reference identity and never consults proxy environment variables | Public proxy model assertions and clean build | Reachable | The runnable configuration example does not require a live external proxy. |
| P008 | Server requires a client certificate and client presents an identity trusted by the server | Native mTLS handshake | Reachable | The fixture certificate and key are test-only. |
| P009 | Finite SSE body is delivered as `text/event-stream` through the public streaming body interface | Body read and exact payload assertion | Reachable | This is not the one-hour streaming profile. |
| P010 | Replayable request and retry policy remain bounded; unknown or unsafe failures fail closed | Public policy assertions and guide scan | Reachable | No exception-message parsing. |
| P011 | HTTP and network failures are handled by stable type, code, phase, and retryability | Public structured-field assertions | Reachable | HTTP 4xx/5xx remain responses. |
| P012 | Legacy OpenSSL/global-provider settings are removed from the migration path | Forbidden-token scan of maintained guide and examples | Reachable | Diagnostic provider strings are allowed only as read-only runtime info. |
| P013 | Example source imports an internal package or depends on runtime/std/stdx source modifications | Import and path guard | Reachable error path | Gate must fail before compiling. |
| P014 | A required example marker is missing, duplicated, or printed before its assertion | Exact marker validation | Reachable error path | `SKIPPED` cannot satisfy a marker. |
| P015 | Clean consumer build or execution exits non-zero, times out, or emits unbounded output | Subprocess result and timeout checks | Reachable error path | Failure output is tail-bounded. |
| P016 | Gate runs on a non-Linux, non-x86_64, or musl host | Platform preflight | Platform-dependent | Result is BLOCKED/FAIL, never PASS. |
| P017 | Report write is interrupted | Same-directory temporary file plus `fsync` and replace | Reachable error path | Existing report remains intact. |
| P018 | Source or evidence digest changes after acceptance | P1-012 evidence verifier | Reachable error path | Prior PASS becomes STALE. |

## Input and state domains

| Domain | Partitions and boundaries | Required behavior |
|---|---|---|
| Platform | Linux x86_64 glibc; Linux musl; other OS/CPU | Only Linux x86_64 glibc may pass. |
| Deadline | absent; positive absolute deadline; already expired | Examples use a positive absolute deadline; expired contexts fail by stable code. |
| Cancellation | not cancelled; request; connection; stream; repeated cancel | Scope is observable and `cancel()` has exactly one winner. |
| Trust | custom root; system trust; no matching root | Local examples use custom roots; verification failure is structured. |
| HTTP protocol | HTTP/1.1; HTTP/2 after ALPN | Both public versions are observed in native loopback runs. |
| Body | empty; finite fixed length; finite streaming/SSE; non-replayable | Reads are bounded; retry rules respect replayability. |
| Proxy | explicit hostname endpoint; explicit IP endpoint; no-proxy match | Configuration is explicit and origin identity stays separate. |
| Evidence | current; missing; malformed; source drift | Only current, schema-valid PASS evidence is accepted. |

## State and side effects

- Each server, client, response, TLS config, key, transport, and spawned task is
  closed or joined on both success and failure paths.
- Clean consumers are created under a temporary directory and are removed after
  the run. The repository receives only the atomic JSON report.
- Examples use loopback or bounded in-memory transports. They do not resolve or
  contact public hosts.
- Repeated cancellation and close calls stay idempotent. No example changes
  process-global TLS state, proxy environment variables, or SDK files.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Migration guide | Current public API baseline | P001,P010,P011,P012 | All eight migration topics map old behavior to current API and removal steps | Required headings/tokens present; forbidden legacy recommendation absent | normal | P0 |
| S002 | HTTPS and custom CA example | Loopback TLS server stopped | P003,P005 | Client verifies local certificate, receives body, and reports HTTP/2 | Status, body and `HttpVersion.Http2` asserted before markers | integration,platform | P0 |
| S003 | Cleartext server example | Loopback port 0 | P004 | Public server handles one HTTP/1.1 request and terminates | Version, body and shutdown active count asserted | integration,platform | P0 |
| S004 | Existing transport TLS example | Bounded in-memory pair open | P006 | Public contexts complete both handshakes and exchange bytes | ALPN, provider metadata, exact payload and cleanup asserted | integration | P0 |
| S005 | CONNECT configuration example | Explicit proxy and origin resolvers | P007 | HTTPS request configuration routes through proxy while keeping origin identity | Proxy route, endpoint, target host and TLS config asserted | normal | P0 |
| S006 | mTLS example | Client/server identities loaded | P008 | Required client authentication completes and application bytes cross TLS | Both handshakes and exact payload asserted | security,integration | P0 |
| S007 | SSE example | Public HTTP/1.1 server running | P009 | Client reads exact finite SSE records through streaming response body | Content type and event bytes asserted | streaming,integration | P0 |
| S008 | Scoped cancellation example | Three fresh handles | P002 | Each handle reports its scope and repeated cancellation is idempotent | Scope, first true and second false asserted | lifecycle | P0 |
| S009 | Retry and errors guide/example | Replayable and non-replayable requests | P010,P011 | Retry remains bounded and code handles typed failures | Attempt limit and stable error coordinates asserted | policy,error | P1 |
| S010 | Internal import injection | Example tree modified in fixture | P013 | Gate rejects source before build | Stable failure code names the offending path | negative,security | P0 |
| S011 | Missing or duplicate marker | Synthetic runner output | P014 | Gate rejects output | Missing/duplicate set asserted without parsing exception text | negative | P0 |
| S012 | Build timeout/non-zero | Synthetic subprocess result | P015 | Gate fails with bounded diagnostics | Exit/timeout state and output bound asserted | negative | P1 |
| S013 | Unsupported platform | Synthetic platform identity | P016 | Gate refuses qualification | Decision is not PASS | platform,negative | P0 |
| S014 | Interrupted report replacement | Existing report plus injected replace failure | P017 | Old report remains valid | Original bytes unchanged and temporary file removed | fault-injection | P1 |
| S015 | Source drift after PASS | Mutated copied source | P018 | Evidence verification reports STALE/FAIL | Digest mismatch asserted | evidence,negative | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P010,P011,P012 | Maintained migration guide | Contract scan PASS | Eight topics and legacy-removal instructions present; no forbidden recommendation | minimal,static |
| T002 | S002 | P003,P005 | Native clean consumer HTTPS loopback | HTTPS and HTTP/2 markers | Status 200, expected body, custom CA verification and `Http2` | integration |
| T003 | S003 | P004 | Native clean consumer cleartext loopback | HTTP/1.1 marker | Expected body/version and zero active connections at shutdown | integration |
| T004 | S004 | P006 | Bounded caller-owned transport pair | Existing-transport TLS marker | Both handshakes, ALPN, provider ID and exact bytes | integration |
| T005 | S005 | P007 | Explicit proxy configuration | CONNECT configuration marker | Route is proxy; origin host differs from proxy identity | minimal |
| T006 | S006 | P008 | Required client certificate | mTLS marker | Server trusts presented client identity and payload matches | security,integration |
| T007 | S007 | P009 | Two finite SSE events | SSE marker | `text/event-stream`, exact event sequence and EOF | streaming |
| T008 | S008,S009 | P002,P010,P011 | Typed handles, retry and structured failure models | Cancellation/policy markers | Scope, idempotence, bounded attempts and stable codes | lifecycle,error |
| T009 | S010,S011 | P013,P014 | Inject internal import and malformed marker output | Deterministic rejection | Stable error category and exact offending item | fault-injection |
| T010 | S012,S013 | P015,P016 | Non-zero/timeout and synthetic unsupported host | Deterministic FAIL/BLOCKED | Bounded output; no PASS | fault-injection,platform |
| T011 | S014 | P017 | Inject atomic replacement failure | Existing report preserved | Byte-for-byte old report and no partial final JSON | fault-injection |
| T012 | S015 | P018 | Seal evidence then mutate copied source | STALE/FAIL | Changed source digest is reported | evidence |

## Coverage and gap review

No coverage or mutation claim is made for this documentation task. Existing
protocol and long-duration coverage remain owned by their tasks. T002 through
T008 exercise the checked-in example sources through public packages. T009
through T012 test the gate itself. The one-hour SSE profile, 24-hour soak, real
external proxy interoperability, and non-Linux execution are outside M7-027 and
must not be reported as run.
