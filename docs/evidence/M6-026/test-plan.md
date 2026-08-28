# M6-026 test plan

## Semantics

One public `HttpClient` may execute multiple HTTP/2 requests concurrently on
one pooled TLS connection. Each request owns a distinct stream and response
body. Newly opened client streams must publish their first HEADERS in increasing
stream-ID order even though pool admission and request execution are separate.
Interleaved response HEADERS and DATA frames must reach only their matching body.
Reading or closing one completed body must not remove, reset, fail, or corrupt
its sibling. A stream failure stays at stream scope unless RFC connection-error
rules require otherwise. Every terminal path releases the pool lease, flow
state, cancellation registrations, reset listener, reader listener, and body
segments exactly once.

The regression uses a real native Linux TLS loopback and only public
`wirestack.http` client and server APIs. It first warms one H2 connection. For
each measured batch, a server-side barrier waits for two `/barrier` requests
before either handler returns a two-byte body. The client then reads and closes
both bodies concurrently. Acceptance requires 1,000 consecutive batches and
2,000 exact `ok` bodies under the existing five-second request Deadline. A
serial client, a retry that hides the first failure, a larger Deadline, or a
new timeout owner does not satisfy the task.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Warm request negotiates H2 and leaves one reusable pooled connection | TLS ALPN and public response version | Reachable | The measured batches must not rely on first-connection setup races. |
| P002 | Two callers enter one origin pool concurrently | pool capacity and bounded admission | Reachable | Both calls must be admitted without serializing the public API. |
| P003 | The pool assigns distinct odd client stream IDs on the same H2 connection | stream registry and peer limit | Reachable | Duplicate or inactive stream IDs are protocol failures. |
| P004 | Two request HEADERS blocks are encoded and queued | ordered initial-HEADERS coordinator, encoder mutex and bounded writer queue | Reachable | A higher admitted stream cannot publish before a lower stream; cancellation of an unpublished lower stream advances the bounded order without emitting idle-stream RST. |
| P005 | Server barrier observes both streams before returning either response | mutex/condition wakeup | Reachable | Proves the requests overlap at the public facade. |
| P006 | Two response HEADERS blocks and DATA frames interleave on one writer | bounded write scheduler | Reachable | Interleaving must remain valid HTTP/2 framing. |
| P007 | One reader loop parses frames and dispatches by stream ID | frame parser and connection state machine | Reachable | No frame may be delivered to the sibling exchange. |
| P008 | Each exchange publishes one status/version/body tuple | response sequence validation | Reachable | Duplicate final headers or DATA-before-headers fail closed. |
| P009 | Each body consumes exactly two bytes and then EOF | content length, body channel and flow credit | Reachable | Both bodies must equal `ok`. |
| P010 | First body reaches EOF and releases its stream before sibling completion | lifecycle and pool release | Reachable | Sibling must still complete on the same connection. |
| P011 | Second body reaches EOF first | scheduler-dependent ordering | Reachable | The opposite completion order must also be safe. |
| P012 | Stream-scoped malformed input or reset occurs | typed stream error | Reachable error path | Only that stream terminates and sibling remains usable. |
| P013 | Connection-scoped protocol failure occurs | reader completion fanout | Reachable error path | Preserve the first code, scope, reason, and both caller failures. |
| P014 | Request Deadline or cancellation wins | canonical OperationContext | Reachable error path | No new timeout owner and no hidden retry. |
| P015 | Response body close races with final DATA/END_STREAM | body and exchange mutexes | Reachable | Observer, flow close, and pool release remain exactly once. |
| P016 | Client/server shutdown follows all measured batches | connection drain and resource cleanup | Reachable | The process must exit within the outer hard bound. |

## Input and state domains

| Domain | Minimal values | Boundary or error values | Required relationship |
|---|---|---|---|
| Concurrent callers | exactly 2 | 1 as warm-up; cancellation of one sibling | Measured batches always contain two overlapping calls. |
| Response body | `ok`, two bytes | empty body; body closed before EOF | Both measured bodies have `Content-Length: 2`. |
| Batch count | 1 diagnostic batch | 1,000 acceptance batches | No stitched or retried batch counts as success. |
| Stream ordering | first completes first | second completes first; interleaved frames | Result must not depend on task scheduling order. |
| Connection state | warmed/open | draining, reset, reader failure | New work is rejected after a real connection terminal. |
| Operation budget | existing 5 seconds | cancellation before completion; expiry | Child work may shorten but never extend the budget. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | warm request | new client/server | P001,P008,P009 | H2 connection becomes reusable | status 200, version H2, body `ok`, clean close | normal | P0 |
| S002 | two barrier-coordinated GETs | warmed H2 connection | P002..P011 | both bodies complete independently | two distinct successful futures, 2 bodies, 4 bytes, no retry or timeout | regression,concurrency | P0 |
| S003 | 1,000 batches | same warmed client | P002..P011,P016 | repeated reuse stays valid and process exits | 2,000 exact bodies, 0 failures, 0 timeouts, terminal cleanup | regression,lifecycle | P0 |
| S004 | first body closes before sibling EOF | two active streams | P010,P015 | sibling remains readable | sibling status/version/body unchanged, no connection abort | concurrency,lifecycle | P0 |
| S005 | reversed completion order | two active streams | P011,P015 | result is order-independent | same semantic assertions as S004 | concurrency | P1 |
| S006 | stream reset | two active streams | P012,P015 | only selected stream fails | stable stream error, sibling succeeds, connection accepts next request | error | P1 |
| S007 | connection protocol terminal | two active streams | P013,P016 | both callers receive one retained terminal and cleanup completes | first code/scope/reason retained, no hang or leaked task | error,diagnostic | P0 |
| S008 | cancellation or Deadline | one or two active streams | P014..P016 | canonical context wins promptly | stable cancel/deadline classification and bounded exit | error,lifecycle | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S004,S005 | P001..P011,P015 | one warm request plus one two-stream barrier batch | public facade multiplexes and consumes both bodies | H2 versions, status 200, exact `ok`, both futures joined, server overlap count 2 | minimal |
| T002 | S002,S003 | P002..P011,P016 | 1,000 barrier batches on one client | zero intermittent connection failure and bounded process exit | batches 1,000, responses 2,000, bytes 4,000, failures 0, timeouts 0, final active handlers 0 | regression |
| T003 | S006,S008 | P004,P012,P014,P015 | cancel one admitted stream before initial HEADERS, plus an existing open-stream reset | unpublished cancellation stays local and reset stays stream scoped | no idle-stream RST, next claimed stream publishes; typed open-stream failure leaves sibling and connection usable | boundary |
| T004 | S007 | P003,P004,P013,P016 | retained M7-022 failure plus two instrumented pre-fix reproductions | first connection terminal is preserved | `ProtocolError`, connection scope, `peer stream ids must increase monotonically`, both tasks joined, process exits | diagnostic |
| T005 | S008 | P014..P016 | public cancellation and five-second Deadline | terminal work is prompt and exactly once | stable category/code, no Deadline extension, zero residual handlers | boundary |

## Feedback and gap review

M7-022 supplied the release-artifact failure: its formal installed-artifact run
failed with public `HttpErrorCode.ProtocolViolation` while both concurrent body
tasks were active. Two bounded pre-fix reproductions then failed at batches 616
and 472. Instrumenting only the reader terminal branches retained the first
server terminal as connection-scoped `ProtocolError` with reason
`HTTP/2 peer stream ids must increase monotonically`; the client-side socket
failure was secondary. The diagnostic print was removed before the product
change. The existing M6-025 profile supplies TLS full-duplex and process-
termination evidence, but it did not enforce repeated simultaneous small-body
requests.

The final reverse review must confirm
that every reachable P0 path maps to a semantic assertion, that no test merely
executes code, and that the acceptance runner does not count `SKIPPED`, retry,
serialization, or a short batch count as PASS.
