# M8-005 Linux HTTP parity qualification

Status: PASS for the executed source and installed-consumer matrix. `task-check.json` records the task commands. `evidence.json` records the final source candidate and report bindings.

Scope: Linux x86_64 glibc with Cangjie STS 1.1.3. The qualified behaviors are bounded `CookieJar`, multipart and `FileHandler`, generic HTTP/1.1 Upgrade ownership, uncompressed HTTP/1.1 and HTTP/2 WebSockets, bounded HTTP/2 push, connector and pool hooks, service hooks, and a public consumer compiled from an extracted installed release archive. Source tests, installed-consumer evidence, and review findings remain separate evidence classes.

Exclusions: WebSocket compression, `ws` or `wss` URL parsing, native `FileHandler` on non-Linux targets, interruption of a blocking filesystem syscall already in the kernel, and browser cookie policies that Wirestack does not implement. No old report, source inspection, or source-tree-only test qualifies the installed deliverable.

## Control-flow paths

| ID | Entry and branch | Observable result |
|---|---|---|
| P001 | Parse, store, replace, expire, evict, remove, or select a cookie | Only valid in-scope live identities appear in deterministic bounded request order |
| P002 | Encode or incrementally parse multipart data | Binary bytes and quoted boundaries round-trip within configured part, metadata, and body limits |
| P003 | Download or upload through Linux `FileHandler` | Root confinement, finite transfer bounds, atomic publication, status mapping, and owned cleanup hold |
| P004 | Complete or reject an HTTP/1.1 generic Upgrade | A matching explicit handshake transfers one exclusive transport. Rejection retains one owned response |
| P005 | Complete an HTTP/1.1 or HTTP/2 WebSocket handshake | A validated uncompressed session transfers, or the caller receives an owned rejection response |
| P006 | Send, receive, cancel, or close WebSocket frames | Masking, framing, UTF-8, message bounds, automatic control replies, and terminal ownership hold |
| P007 | Offer a server push from an HTTP/2 request | The parent request context, authority, same-origin rule, and server admission limits govern the push |
| P008 | Receive, reject, cancel, or close client push offers | Policy runs on the receiver, queues stay bounded, and each pushed body has one owner |
| P009 | Connect and observe pool lease transitions through hooks | Resolver and pool policy remain active. Hook failures cannot change I/O or ownership |
| P010 | Run service hooks around a server handler | Hooks run outside server locks. Failure follows the handler-failure path and closes owned responses |
| P011 | Build, install, and consume the release archive | The public consumer compiles and runs against the extracted install without source-checkout imports |

## Semantics

| ID | Paths | Input or state | Required assertion |
|---|---|---|---|
| S001 | P001 | Host-only, parent-domain, foreign-domain, exact rejected suffix, and sibling DNS names | Host-only cookies stay on the origin host. Accepted Domain cookies reach only matching suffix boundaries. Foreign and rejected domains fail |
| S002 | P001 | Default path, exact path, slash boundary, `Secure`, `HttpOnly`, `Expires`, and `Max-Age` | Directory matching and transport scope are exact. `Max-Age` wins. Nonpositive lifetime deletes. `HttpOnly` does not invent a browser policy |
| S003 | P001 | Invalid name/value octets, CRLF injection, full jar, replacement, and a short header budget | Invalid input leaves no identity. Capacity evicts the oldest identity. Replacement is stable. `headerFor` returns a bounded `String` in path-length then age order |
| S004 | P001,P009,P010 | Client receives `Set-Cookie`, then sends a jar-selected or explicit `Cookie` header | The jar persists the valid cookie across pool reuse. An explicit request header takes precedence. Hook exceptions do not suppress the exchange |
| S005 | P002 | Replayable binary parts, permitted separator characters in a boundary, and split delimiters | Independent body opens match byte-for-byte. `contentType()` quotes the boundary. One-byte reads preserve payload bytes |
| S006 | P002 | Active part, early part close, malformed final boundary, part-count overflow, header overflow, part overflow, and body overflow | `next()` rejects a second active part without closing the current one. Closing one part releases the next. Terminal parser and limit failures retain a stable `MultipartErrorCode` and close owned input |
| S007 | P003 | Safe download, traversal, symlink, nonregular file, wrong method, and oversized file | Only the configured relative regular file returns `200`. Unsafe input maps to the documented status. Transfer never exceeds `maximumBytes` |
| S008 | P003 | One accepted binary upload, two file parts, rejected filename, traversal, oversized body, and existing destination | Only one complete accepted file appears with mode `0600`. Rejected staging is removed. No-replace publication preserves an existing file |
| S009 | P003 | Cancellation or deadline before a bounded filesystem step and a syscall already executing | Context stop raises `FileHandlerException`. Checks occur between calls. No interruption of an in-kernel blocking filesystem syscall is claimed |
| S010 | P004 | Bodyless request with matching `Connection: Upgrade` and an offered protocol list. Response selects one matching protocol and includes prefetched bytes | The caller receives status, immutable headers, version, and one transport that starts with every prefetched byte and leaves the pool only on close |
| S011 | P004 | Missing or mismatched upgrade evidence, an implicit `101`, or a non-`101` response with a body | Invalid handshake fails closed with no transfer. Ordinary rejection returns the complete owned `HttpResponse` |
| S012 | P005 | `http` handshake, `https` handshake negotiated to HTTP/2, selected offered subprotocol, and sibling HTTP/2 request | HTTP/1.1 uses Upgrade. HTTP/2 uses extended CONNECT. The selected protocol is retained and the sibling stream remains usable |
| S013 | P005 | Managed handshake field supplied by caller, bad accept key, unoffered protocol, or extension response | The handshake is rejected or fails closed. No redirect or retry replays it. WebSocket extensions are not negotiated |
| S014 | P006 | Fragmented text across one-byte reads, binary frame, Ping, Pong, and valid close | Payload bytes are owned. UTF-8 can span continuations. Ping receives an equal Pong. Close completes both owners within the shorter deadline |
| S015 | P006 | Wrong masking direction, noncanonical length, oversized frame or message, bad continuation, invalid UTF-8, and invalid control payload | A local pre-I/O validation failure preserves untouched state. A wire protocol failure returns the stable code and RFC close status, then fails closed |
| S016 | P006 | Pre-cancelled send and cancellation or deadline after frame I/O begins | Pre-cancel performs no I/O and the session stays usable. An in-progress I/O stop cannot leave a partially usable session |
| S017 | P007 | `request.push(request,response)` on HTTP/2 with the parent authority including an explicit port | The promised URL retains the parent host and port and uses the parent request's stored deadline and cancellation without a context argument |
| S018 | P007 | Concurrent, pending, and per-request push limits. HTTP/1.1 parent. Draining HTTP/2 connection | Admission never exceeds any limit. Excess or unavailable push fails without leaking the promised response body |
| S019 | P008 | Push disabled, invalid method or origin, policy rejection, policy exception, and configured same-origin acceptance | Disabled clients advertise no push. Protocol validation precedes policy. Rejected promises reset. Accepted offers alone reach the caller |
| S020 | P008 | Full pending queue, one active receiver, cancelled receive, parent response close, and transferred pushed response | The queue stays bounded. A second receiver fails. Cancellation wakes the receiver. Close resets unclaimed offers. Transferred response ownership is unique |
| S021 | P009 | Custom `HttpConnector`, pool reuse, acquire and release callbacks, and throwing observers | The connector returns the client-owned transport. The pool reuses it. Callbacks describe actual lease transitions outside locks. Observer failure does not alter the request |
| S022 | P010 | `before` failure, handler success, `after` failure, and a later request | `before` does not own the body. `after` runs before commitment. Failure closes the response and follows normal `500` handling. Later service remains usable |
| S023 | P011 | Installed public imports and construction of immutable headers, cookie, multipart, hook, Upgrade, WebSocket, and push APIs | The consumer compiles only against the extracted archive and observes the documented public types and return values |
| S024 | P011 | Native loopback execution and report generation | The consumer exercises public HTTP behavior. The report has `source_task` `M8-005`, top-level `PASS` or `FAIL`, durable raw-log paths, and typed `tools.evidence_digest` digests |
| S025 | P007,P008 | A pushed body exceeds the initial HTTP/2 flow window | The parent response completes before the client drains the 131,072-byte push. Sibling requests and an open WebSocket remain usable |
| S026 | P007,P008 | Parent completion, retained push lifetimes, cancellation, and repeated lifetime close | Cancellation still reaches retained workers. The last completed lifetime detaches request registrations exactly once |
| S027 | P007 | Parent reset during an admission wait, cross-origin promise, blocked user read, and blocked header-only close | Admission revalidates the parent and origin. Rejection closes the response. Reset does not block the reader or release a still-running worker's slot |
| S028 | P008 | Reset during offer transfer and header-only pushed response completion | A terminal offer is skipped. A transferred response remains uniquely owned until its successful completion or close |
| S029 | P007,P008 | Reset during a partially written header block, an unstarted admitted block, more than eight CONTINUATION frames, and HPACK admission failure | Admitted blocks remain contiguous and complete. Compression-state failures close the affected connection instead of permitting inconsistent reuse |
| S030 | P004 | Ordinary GET without an explicit protocol, CONNECT paired with an extended protocol, and valid Upgrade offer lists | Mismatched public calls fail before connector I/O. A selected offered HTTP/1.1 protocol transfers buffered bytes |
| S031 | P008 | A followed HTTP/2 redirect has an unclaimed large push | Following closes the old response and abandons its push before client teardown |
| S032 | P005,P007,P008 | A duplex handler returns, or a parent ends without any accepted push | Handler return terminates both stream directions. An empty push source returns None after parent END_STREAM without requiring a body read |
| S033 | P001 | Deterministic Set-Cookie byte substitutions and deletions across attributes, quoting, expiry, DNS boundaries, and control bytes | Rejected candidates leave no identity. Accepted headers remain bounded and injection-free. Host-only, path, unrelated-host, and Secure transport boundaries hold |
| S034 | P002 | Binary multipart seeds, every proper truncation and deletion, byte replacements, delimiter padding, changed boundaries, and four source split schedules | Accepted metadata and payload bytes or typed terminal errors agree across splits. Source and payload read budgets remain finite |
| S035 | P006 | Masked WebSocket seed mutations, all eight bit flips at selected positions, deletions, truncations, extended lengths, and four read split schedules | Accepted frame traces, typed terminal codes, automatic wire replies, and exclusive graceful or abort ownership agree across splits. Frame, message, input, output, and read-call limits bound execution |
| S036 | P002 | Invalid Content-Disposition or Content-Type metadata after the reader has adopted its source | The original typed parser failure closes the owned response body. The retained red mutation run fails this ownership assertion before correction |

## Test-plan matrix

| ID | Paths | Scenarios | Execution/evidence | Status |
|---|---|---|---|---|
| T001 | P001 | S001,S002,S003 | [`HttpCookieJarTest`](../../../src/http/cookie_test.cj): metadata, domain/path/transport boundaries, injection rejection, expiry, deterministic capacity, snapshots, and concurrent bounded access | PASS |
| T002 | P001,P009,P010 | S004,S021,S022 | [`HttpClientExtensionsTest.nativeCookiesAndServiceHooksSurviveThrowingPoolObservers`](../../../src/http/client_extensions_test.cj): native cookie persistence, explicit-header precedence, connector reuse, pool transitions, and service-hook failures | PASS |
| T003 | P002 | S005,S006 | [`MultipartTest`](../../../src/http/multipart_test.cj): quoted separator boundary, exact replayable bytes, split delimiters, single-active-part ownership, malformed cleanup, and part-count bound | PASS |
| T004 | P003 | S007,S008 | [`FileHandlerTest`](../../../src/http/file_handler_test.cj): confined download, symlink rejection, body lifetime, atomic binary upload, traversal, duplicate-part, size, and no-replace cases | PASS |
| T005 | P004 | S010,S011 | [`Http1ResponseReaderTest`](../../../src/internal/http1/response_reader_test.cj) and [`Http1ServerConnectionTest`](../../../src/internal/http1/server_connection_test.cj): explicit matching transfer, mismatched rejection, buffered bytes, and exactly-once rejected handoff cleanup | PASS |
| T006 | P006 | S014,S015,S016 | [`WebSocketConnectionTest`](../../../src/http/websocket_test.cj): one-byte fragmentation, automatic Pong, pre-cancel health, message bounds, masking, canonical lengths, UTF-8, graceful close, payload ownership, and control bounds | PASS |
| T007 | P005,P006 | S012,S013,S014,S016 | [`WebSocketHandshakeTest`](../../../src/http/websocket_handshake_test.cj): native public H1 and H2 handshake, echo, push, sibling request, and close ownership | PASS |
| T008 | P007,P008 | S017,S018,S019,S020 | [`Http2ClientMappingTest`](../../../src/internal/http2/client_mapping_test.cj), [`Http2SettingsTest`](../../../src/internal/http2/settings_test.cj), and [`Http2ClientConnectionTest`](../../../src/internal/http2/client_connection_test.cj): promise validation, push advertisement, peer settings, and bounded caller-driven delivery | PASS |
| T009 | P001,P009,P010,P011 | S004,S021,S022,S023 | Installed consumer mode `cookies-hooks`, marker `COOKIES_HOOKS_PASS` | PASS |
| T010 | P002,P003,P011 | S005,S007,S008,S009,S023 | Installed mode `files-multipart`: exact binary upload/download, quoted boundary, distinct pre-cancel and expired-deadline errors, then successful reuse. Marker `FILES_MULTIPART_PASS` | PASS |
| T011 | P004,P011 | S010,S011,S023 | Installed consumer mode `upgrade-http1`, marker `UPGRADE_HTTP1_PASS` | PASS |
| T012 | P005,P006,P011 | S012,S014,S023 | Installed consumer mode `websocket-http1`, marker `WEBSOCKET_HTTP1_PASS` | PASS |
| T013 | P005,P006,P007,P008,P011 | S012,S014,S017,S019,S020,S023,S025 | Installed mode `websocket-http2-push`: parent completion before a 131,072-byte push, sibling request, and an open WebSocket. Marker `WEBSOCKET_HTTP2_PUSH_PASS` | PASS |
| T014 | P001,P002,P003,P004,P005,P006,P007,P008,P009,P010 | S001,S002,S003,S004,S005,S006,S007,S008,S010,S011,S012,S013,S014,S015,S016,S017,S018,S019,S020,S021,S022 | [`http-tests.json`](http-tests.json) records 106 passed and 3 skipped. [`protocol-tests.json`](protocol-tests.json) records 290 passed and 3 skipped. Both have zero failures | PASS |
| T015 | P011 | S023,S024 | [`native-http.cj`](../../../examples/linux/m8_005/native_http.cj) runs against the extracted release through `tools/m8_005_native_http.py`. [`native-http.json`](native-http.json) retains the five executed modes and typed raw-log digests | PASS |
| T016 | P007,P008 | S025,S026,S027 | [`Http2ServerPushLifecycleTest`](../../../src/internal/http2/server_push_lifecycle_test.cj): parent progress, cancellation, cross-origin rejection, post-wait parent reset, retained blocked-worker slots, and nonblocking reset cleanup | PASS |
| T017 | P007,P008 | S026,S031 | [`HttpFacadeTest`](../../../src/http/facade_test.cj): retained cancellation lifetimes and followed-redirect cleanup of an unclaimed large push | PASS |
| T018 | P008 | S028 | [`client_push_ownership_test.cj`](../../../src/internal/http2/client_push_ownership_test.cj): reset during transfer and header-only pushed-body ownership | PASS |
| T019 | P007,P008 | S029 | [`Http2WriteSchedulerTest`](../../../src/internal/http2/write_scheduler_test.cj): irrevocable admitted batches, partial-write reset, contiguity beyond the control burst, and terminal admission failure. `Http2ClientConnectionTest.encodedHeaderFailureClosesTheConnection` verifies peer termination | PASS |
| T020 | P004 | S030 | `HttpClientExtensionsTest.mismatchedUpgradePairingsNeverOpenConnections` and `Http1ServerConnectionTest.selectedUpgradeOfferTransfersBufferedSessionBytes` | PASS |
| T021 | P005,P007,P008 | S032 | `Http2ServerPushLifecycleTest.duplexHandlerReturnAbortsBothStreamDirections` and `crossOriginPushIsRejectedAndItsResponseIsClosedBeforeAnyOffer`. The latter reproduced the parent-completion timeout before correction | PASS |
| T022 | P001 | S033 | `HttpCookieJarTest.boundedSetCookieMutationsPreserveScopeAndHeaderSafety` executes deterministic syntax and security mutations with independent accepted and rejected controls | PASS |
| T023 | P002 | S034 | `MultipartTest.boundedDeterministicWireMutationsAreChunkIndependent` and `deterministicMutationHarnessEnforcesSmallLimitsAndOwnedClosure` compare binary data, metadata, typed failures, and cleanup across finite source splits | PASS |
| T024 | P006 | S035 | `WebSocketConnectionTest.boundedDeterministicWireMutationsAreSplitInvariantAndFailClosed` combines independent protocol anchors with generated mutations and bounded terminal-state comparisons | PASS |
| T025 | P002 | S036 | [`red HTTP run`](commands/parser-review-red/http-contract-tests.json) fails the adopted-source ownership assertion. [`green HTTP run`](commands/parser-review-green/http-contract-tests.json) passes all 106 cases after terminal typed-error cleanup | PASS |

## Execution and evidence rules

Validate the matrix structure with:

```text
python3 tools/repository/repository_tooling.py --root . validate-plan docs/evidence/M8-005/test-plan.md --json
```

Run the installed public consumer with:

```text
python3 tools/m8_005_native_http.py --report docs/evidence/M8-005/native-http.json
```

The installed-consumer tool must build a release archive, extract it outside the checkout import path, and compile [`native_http.cj`](../../../examples/linux/m8_005/native_http.cj) against that install. `native-http.json` must keep the exact argv, exit status, toolchain identity, source identity, raw stdout and stderr paths, and typed digests under `tools.evidence_digest`. All report and raw-log paths must remain under `docs/evidence/M8-005`.

A row changes to `PASS` only after its stated observable contract runs successfully on the final candidate and its raw evidence is retained. A source finding can support review but cannot replace execution. Evidence from an older source candidate, including a source-equivalent-looking report, does not qualify this candidate.

No coverage percentage, performance percentile, WebSocket compression result, non-Linux `FileHandler`, browser cookie conformance, blocking-syscall interruption, release signature, or final soak is claimed by this plan.
