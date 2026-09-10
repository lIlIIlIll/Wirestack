# M8-001 test plan: Linux network foundation contract

This plan is scoped to the Linux x86_64 glibc contract freeze. It proves the
public package shape, dependency boundary, bounded values and fail-closed
capability decisions. Native privileged raw I/O, complete DNS wire transport,
full HTTP parity, TLS context replacement and the final release soak belong to
M8-002 through M8-007 and are not represented as PASS here.

## Semantics

| ID | Contract or failure scenario | Expected result |
|---|---|---|
| P001 | Shared `wirestack` endpoint values and `wirestack.net` socket contracts | declarations compile without public `std.net` or internal aliases |
| P002 | One absolute `OperationContext` crosses potentially blocking operations | stopped connect/close is rejected before side effects; a started close bounds caller wait without abandoning cleanup |
| P003 | Stream lifecycle is bounded and idempotent | abort, close, failure and directional half-close remain distinct; repeated terminal calls preserve state |
| P004 | Unix and raw capability boundary is explicit | pathname/abstract/unnamed forms are distinct; AF_PACKET/AF_NETLINK are Unsupported |
| P005 | DNS policy is not hidden in endpoint construction | endpoint construction takes resolved values and is DNS-free; wire parsing belongs to M8-004 |
| P006 | Datagram operations preserve packet semantics under one context | public connect/send/sendTo/receive/lifecycle contract; bounded owned results; native adapters belong to M8-002/M8-003 |
| P007 | Shared structured errors retain Unix endpoints | exact pathname/abstract bytes, native code and cause survive error propagation; pathname rejects NUL |

The following fault injections are required by the M8 series. M8-001 executes
the contract and repository-control subset; the remaining protocol/native
cases are carried forward to their owning task and remain NOT_RUN here:

| ID | Injection | M8-001 disposition |
|---|---|---|
| S001 | Path escape, unknown task schema, missing task, dependency cycle | PASS; fresh repository-tooling unit tests |
| S002 | Long-running command accidentally selected by fast/full gate | PASS; manifest validator and existing fault tests |
| S003 | SKIPPED or compile-only result promoted to PASS | PASS; report/status validator |
| S004 | Non-atomic report replacement | PASS; existing atomic-report fault test |
| S005 | Oversized Unix/raw/option/datagram values | PASS; public Cangjie contract tests |
| S006 | Pre-cancelled operation and unsupported raw domain | PASS; public Cangjie contract tests |
| S007 | Context/connection provider mismatch or TLS replacement | NOT_RUN; M8-006 |
| S008 | DNS compression loop, malformed RR, UDP-to-TCP fallback | NOT_RUN; M8-004 |
| S009 | HTTP/2 stream isolation, WebSocket frame bounds and push limits | NOT_RUN; M8-005 |
| S010 | Native UDP/Unix/raw close wakeup and privileged raw capability | NOT_RUN; M8-002/M8-003 |
| S011 | Close/abort state, cancellation and wrong-direction I/O after half-close | PASS; 35/35 network cases, including deterministic final-direction shutdown wakeup |
| S012 | Cookie injection, persistence failure, path precedence and unsafe parity metadata | NOT_RUN; M8-005 |
| S013 | Mutated DNS headers and malformed length/count/flags | NOT_RUN; M8-004 |
| S014 | Warning-contaminated, fictitious or source-mismatched revision passed to sealing | PASS; 37/37 tooling cases and real CLI rejection without seal output |
| S015 | Unix pathname contains NUL but abstract name legitimately contains it | PASS; shared endpoint/error regressions |
| S016 | Published task totals disagree with declared unique task IDs | PASS; corrupted total rejected, unchanged graph passes 4/4; expected counts are derived |
| S017 | Exact read reaches EOF before filling the destination | PASS; captured endpoints and write direction survive; native peer receives post-EOF data |
| S018 | Partial I/O conflict omits available endpoint diagnostics | PASS; all six public I/O paths retain captured endpoints without closing |
| S019 | Delegate close throws an unclassified exception | PASS; stable close error classification, endpoints and original cause; Failed retained |
| S020 | Descriptor exhaustion during native socket construction | PASS; a warmed external consumer under `RLIMIT_NOFILE=0` returns a structured connect error with the peer and original cause |
| S021 | Pre-cancelled admitted I/O observes a concurrent graceful close | PASS; read and write preserve the graceful owner; cancellation-owned closure also survives close and Closed-error observers |
| S022 | Unclassified read, write, shutdown or abort exception | PASS; all eight entry points retain phase, endpoint and cause diagnostics; abort remains Aborted |
| S023 | Real cancellation closes a native TCP transport | PASS; blocked read reports Cancelled and the stream remains Aborted after close |
| S024 | Close receives a pre-cancelled or expired context | PASS; both real TCP streams retain Open, return structured errors and transmit data afterward |
| S025 | Cancellation/deadline while delegate close blocks, followed by success, failure or concurrent abort | PASS; bounded caller wait preserves cleanup ownership and the eventual terminal cause |
| S026 | Direct verification receives a fictitious or unrelated candidate revision | PASS; both are rejected; real-Git tests also reject non-commit objects and preserve legitimate STALE results |
| S027 | Caller-supplied deadline clock throws while admitting close | PASS; structured SystemFailure retains cause/endpoints and leaves the stream open |
| S028 | Repeated close after a terminal state receives a stopped or throwing-clock context | PASS; no-op before context callbacks, with all terminal results preserved |
| S029 | Abort races a graceful native close that already owns the resource | PASS; native ownership is retained through gated wrapper completion; no upgrade or interruption is claimed |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,P004 | `python3 tools/architecture_guard.py --format json` and public API inventory | PASS |
| T002 | P001,P002,P003,P004,P005,P006,P007 | `cjpm check` and `cjpm build` | PASS |
| T003 | P002,P003,P004,P005,P006,S005,S006,S011,S017,S018,S019,S021,S022,S023,S024,S025,S027,S028,S029 | `cjpm test src/net --no-progress --no-color` | PASS; 35/35, including native cancellation, bounded close and native ownership; no native datagram I/O claim |
| T004 | S001,S002,S003,S004,S014,S016 | Repository-tooling, architecture guard and API/backlog regression tests | PASS; count invariant rejects stale metadata without fixed numeric expectations |
| T005 | P006,S005 | Datagram result upper-bound and receive-buffer reuse regressions | PASS |
| T006 | S007,S008,S009,S010,S012,S013 | M8-002, M8-003, M8-004, M8-005 and M8-006 task gates | NOT_RUN; owned by later tasks |
| T007 | P007,S015 | Shared endpoint/error regressions through canonical `scripts/check` | PASS; 4 selected error cases and all 83 transport cases in the canonical gate |
| T008 | S020 | Warmed external consumer, per-process descriptor exhaustion and `review-seventh.json` | PASS; raw SocketException before repair, structured connect failure afterward |
| T009 | P002,S024 | Real TCP stopped-close consumer and receiver | PASS; baseline exit 42 becomes exit 0, with both peers receiving byte 42 after rejected close |
| T010 | P002,P003,S025,S027 | Deterministic close-admission/completion gates and a failing caller clock | PASS; 35/35 network cases |
| T011 | S026 | Focused repository-tooling suite and direct forged-index reproduction | PASS; 37/37 after three baseline failures; fictitious/unrelated revisions rejected directly |
| T012 | P002,P003,S028,S029 | Gated real-native ownership and terminal-close probe; public and native regression suites | PASS; two native probe cases fail before repair and pass afterward; permanent network 35/35 and native adapter 34 passed with 17 existing exclusions |

The `NOT_RUN` rows are intentionally visible and cannot be used as release
evidence. No one-hour SSE profile or 86,400-second soak is run by this task.
