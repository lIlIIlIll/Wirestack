# M3-029 public TLS facade test plan

Status: **ACCEPTED FOR IMPLEMENTATION**

This plan covers the Linux x86_64 glibc public `wirestack.tls` facade required
by PRD sections 6.2, 7, 13 and 29. It treats the caller-provided
`DuplexTransport` as consumed when a handshake starts. Tests use only public
`wirestack.tls` declarations unless they are explicitly testing the repository
architecture guard.

## Semantics and ownership

- Client and server builders create immutable, concurrently shareable contexts
  and validate versions, ALPN, trust, identity and provider capability before a
  handshake begins.
- Client handshake keeps SNI and reference identity distinct. The convenience
  overload uses one `HostName` for both.
- Starting a handshake consumes the transport. Success transfers ownership to
  `TlsConnection`; failure, cancellation or Deadline aborts it.
- `TlsConnection` preserves one-reader/one-writer semantics, negotiated facts,
  TLS close evidence, idempotent graceful close and idempotent abort.
- `TlsListener` owns its transport listener and performs one server handshake
  for each accepted transport without adding another timeout owner.
- No public signature exposes `std.net`, an AWS-LC/native handle, an engine,
  pump, provider object, OpenSSL configuration string or legacy TLS socket.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | client builder uses supported default profile and system trust | provider and system-trust capability discovery | reachable | immutable context returned |
| P002 | client builder uses custom roots, explicit versions and ALPN | certificate, version and ALPN validation | reachable | no network side effect |
| P003 | client builder receives invalid version range or ALPN | internal context validation | reachable | stable `TlsContextException` |
| P004 | server builder has identity and supported configuration | key/certificate and provider validation | reachable | immutable context returned |
| P005 | server builder omits identity or required client trust | internal context validation | reachable | fails before accept/handshake |
| P006 | client convenience handshake uses one DNS host for SNI and verification | SAN verification and handshake pump | reachable | transport ownership transfers |
| P007 | client explicit handshake separates SNI and reference identity | SNI routing plus SAN verification | reachable | negotiated facts retained |
| P008 | server handshake succeeds on caller-provided transport | server engine and handshake pump | reachable | connection owns transport |
| P009 | handshake context is pre-cancelled | cancellation fast-fail | reachable | transport aborted, no success publication |
| P010 | handshake Deadline expires while transport is blocked | monotonic Deadline checks | reachable | timeout error and transport abort |
| P011 | trust, identity, protocol or ALPN negotiation fails | provider-neutral TLS error mapping | reachable | transport aborted exactly once |
| P012 | connection read/write succeeds after handshake | one-reader/one-writer gate and TLS pump | reachable | plaintext and negotiated info observable |
| P013 | graceful close completes or observes truncation | close_notify pump and transport close | reachable | terminal evidence retained |
| P014 | abort is called repeatedly or races with close | lifecycle terminal winner | reachable | idempotent terminal cleanup |
| P015 | listener accepts and handshakes one transport | underlying accept and server handshake | reachable | same `OperationContext` propagated |
| P016 | listener close wakes or rejects accept | underlying listener lifecycle | reachable | no background waiter retained |
| P017 | context remains referenced while an active connection exists | Cangjie object lifetime and native provider ownership | reachable | provider cannot be finalized early |
| P018 | API inventory and architecture guard scan public declarations | parser and forbidden-pattern rules | reachable | no native/std.net/legacy leakage |

## Input and state domains

| Domain | Partitions and boundaries | Required treatment |
|---|---|---|
| TLS versions | 1.2 only, 1.3 only, 1.2 through 1.3, reversed range | valid ranges build; reversed range fails |
| ALPN | empty, one value, `h2,http/1.1`, duplicate/invalid/oversized | bounded validation before handshake |
| Trust | system, custom roots, system plus custom roots, pins, malformed/empty roots | fail closed without disabling identity verification |
| Identity | valid PKCS#8 pair, missing server identity, mismatched key, closed key | reject before network side effects where constructible |
| Reference identity | exact DNS, wildcard boundary, IP, mismatching DNS, zoned IP | SAN-only verification; SNI remains separate |
| Operation state | background, pre-cancelled, live cancellation, future Deadline, expired Deadline | one absolute context propagated unchanged |
| Transport state | open, peer EOF, reset, blocked read/write, already closed | stable terminal category and at-most-once abort/close |
| Connection state | open, closing, closed, aborted; first and repeated terminal call | idempotence and retained evidence |
| Listener state | open, active accept, closed, repeated close | wakeup and no accepted transport leak |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | default client builder | provider available | P001 | immutable system-trust context builds | context builds; capability/provider types are not public | normal | P0 |
| S002 | custom roots plus `h2,http/1.1` | valid DER root | P002 | configuration validates before I/O | ALPN copy is immutable; no transport touched | normal,boundary | P0 |
| S003 | reversed versions and invalid ALPN | builder open | P003 | stable context error | exact error type/code; no network side effect | error | P0 |
| S004 | server identity and optional/required mTLS | valid certificate/key | P004,P005 | valid context builds; missing trust/identity fails | stable code; key/provider types remain opaque | normal,error | P0 |
| S005 | real TLS 1.3 client/server over consumer transports | two connected caller transports | P006,P008,P012,P017 | handshake, plaintext exchange and negotiated info succeed | version, ALPN, cipher, peer chain, provider metadata, bytes | integration | P0 |
| S006 | explicit SNI differs from verified DNS identity | certificate and route permit combination | P007 | SNI and reference identity are independently retained | requested SNI and verified identity assertions | integration | P0 |
| S007 | pre-cancelled client handshake | open instrumented transport | P009 | no connection returned; transport aborted once | cancellation category/code/phase and abort count | error,lifecycle | P0 |
| S008 | blocked handshake with expired Deadline | open fault transport | P010 | timeout terminates and aborts transport | Deadline category/code/phase; bounded completion; abort once | error,lifecycle | P0 |
| S009 | hostname mismatch or untrusted root | open real transport | P011 | stable TLS error and no usable connection | TLS code; transport terminal; no message parsing | security,error | P0 |
| S010 | bidirectional plaintext after handshake | open TLS pair | P012 | one read and one write can progress | exact bytes and transport info backend | normal,concurrency | P0 |
| S011 | graceful close_notify | open TLS pair | P013 | both sides reach a clean terminal | `CloseNotify`, closed state, repeated close no-op | lifecycle | P0 |
| S012 | peer transport EOF without close_notify | open TLS pair | P013 | truncation remains distinguishable | `PeerClosedWithoutCloseNotify` and stable error | security,lifecycle | P0 |
| S013 | repeated abort and close/abort ordering | open or terminal connection | P014 | first terminal wins and cleanup is idempotent | terminal state/evidence and one underlying abort/close | concurrency,lifecycle | P0 |
| S014 | TLS listener accept then close | open caller listener | P015,P016,P017 | accepted transport is secured; close is idempotent | data exchange, accept wake/terminal, no leak | integration,lifecycle | P0 |
| S015 | public API ownership and architecture scan | completed source tree | P018 | forbidden internal, native, `std.net` and legacy types are absent | current pre-1.0 inventory and guards PASS | architecture | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S003 | P001,P002,P003 | public client builder partitions | valid contexts build and invalid policies fail | immutable ALPN copy plus typed exception assertions | minimal |
| T002 | S004 | P004,P005 | public server builder and mTLS partitions | valid server builds; missing identity/trust rejected | typed code and no transport side effect | minimal |
| T003 | S005,S010 | P006,P008,P012,P017 | native loopback consumer transport pair | TLS 1.3 handshake and duplex plaintext succeed | negotiated/version/provider/peer-chain and exact-byte assertions | integration |
| T004 | S006 | P007 | separate SNI and DNS reference identity | handshake succeeds with independent inputs | requested SNI and verified identity assertions | integration |
| T005 | S007 | P009 | pre-cancelled context and counting transport | handshake fails and aborts exactly once | category/code/phase plus terminal counters | error |
| T006 | S008 | P010 | expired Deadline and blocking transport | bounded timeout failure | monotonic elapsed bound, typed error and one abort | error |
| T007 | S009 | P011 | wrong root and hostname mismatch | fail-closed handshake | stable TLS code and no returned connection | security |
| T008 | S011 | P013 | graceful close_notify pair | clean terminal and repeated close no-op | closure evidence and closed state | lifecycle |
| T009 | S012 | P013 | peer EOF without close_notify | truncation retained | typed unexpected EOF and truncation evidence | security,lifecycle |
| T010 | S013 | P014 | repeated/racing close and abort | at-most-once cleanup | state, evidence and counters | concurrency |
| T011 | S014 | P015,P016,P017 | public listener over consumer listener | secured accept and idempotent close | exchange, wakeup and terminal assertions | integration |
| T012 | S015 | P018 | current API inventory, architecture guard and clean consumer | public ownership is explicit and forbidden surface absent | zero internal aliases, guard result and executable PASS markers | architecture |

## Evidence boundary

No coverage, mutation or long-duration claim is made by this plan. M3-029 must
produce native Linux glibc public-package tests, a clean-consumer report, the
current pre-1.0 public-ownership inventory and the architecture-guard result.
Historical M7-026 compatibility is not an M3-029 acceptance gate after M7-032.
The 24-hour soak, one-hour SSE profile and all non-Linux platforms remain
outside this task.
