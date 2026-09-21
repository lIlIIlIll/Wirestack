# M8-005 test plan: HTTP/1.1, HTTP/2 and WebSocket parity

This plan covers the Linux provider-neutral HTTP facade. It keeps ownership in
Wirestack public types, uses the existing bounded H1/H2 state machines, and
does not introduce a second timeout owner or compression implementation.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | CookieJar request/response integration | Explicit Cookie headers win; matching Secure/domain/path cookies are bounded; Set-Cookie updates the caller-owned jar without closing it. |
| P002 | Multipart/FileHandler parity | Multipart metadata is injection-safe, parts are owned, output is replayable and bounded; file serving remains an explicit root/size boundary. |
| P003 | Upgrade and WebSocket parity | Upgrade requires both connection and upgrade tokens; WebSocket frames preserve ownership, masking, fragmentation markers and control-frame limits without compression. |
| P004 | HTTP/2 push and stream bounds | Client push remains disabled by default and the public policy is provider-neutral; existing H2 stream admission and reset limits remain authoritative. |
| P005 | Connector, pool and service hooks | Hooks do not expose sockets/TLS/native handles; server service hooks run around H1 and H2 handler dispatch under the same OperationContext. |
| P006 | Clean public consumer boundary | A consumer can configure parity features through `wirestack.http` only; no `std.net` or internal type appears in the public declarations. |

## Fault-injection matrix

| ID | Injection | Expected result |
|---|---|---|
| S001 | Cookie Set-Cookie contains CR/LF, oversized value, invalid name, or Max-Age deletion | Cookie is rejected or removed without header injection or unbounded state. |
| S002 | Cookie domain/path/secure mismatch and explicit caller Cookie header | Mismatched entries are omitted; explicit request header is preserved. |
| S003 | Multipart boundary, name, filename or content type contains CR/LF/quote/backslash | Construction fails closed; no header injection is emitted. |
| S004 | Multipart output exceeds the configured maximum or part count | Encoding fails with a stable bounded error before returning a body. |
| S005 | WebSocket RSV bits, unknown opcode, truncated length/mask, trailing bytes, or oversized control payload | Decode fails closed; valid masked and unmasked frames round-trip. |
| S006 | HTTP/2 push promise arrives or a stream exceeds configured capacity | Existing client rejects push as protocol error and stream limits remain bounded. |
| S007 | Service hook throws or cancellation races handler dispatch | Handler operation terminates through the existing cancellation/failure path; no duplicate response completion occurs. |
| S008 | Public hook is supplied with an internal/native implementation type | Architecture guard rejects the declaration; public API remains Wirestack-owned. |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,S001,S002 | `HttpParityContractTest.cookieJarAppliesSecureDomainAndPathBounds` plus client builder wiring | PASS |
| T002 | P002,S003,S004 | Multipart ownership, metadata validation and bounded `RequestBody` encoding | PASS |
| T003 | P003,S005 | Masked WebSocket frame encode/decode, control-frame validation and Upgrade token checks | PASS |
| T004 | P004,S006 | Existing HTTP/2 push-denial, stream-limit and reset tests plus `DenyHttp2PushPolicy` | PASS |
| T005 | P005,S007 | Public server/client facade cancellation and lifecycle tests; service-hook wiring compiles through H1/H2 handlers | PASS |
| T006 | P006,S008 | `python3 tools/architecture_guard.py --format json` | PASS |
| T007 | P001..P006,S001..S008 | `cjpm test src/http --no-progress --no-color` on native Linux | PASS (76/76) |

No non-Linux run, one-hour SSE profile, or 86,400-second soak is run by this
task. M8-007 owns the final release-candidate long gate.
