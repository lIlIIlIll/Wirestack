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
| P002 | One absolute `OperationContext` crosses potentially blocking operations | pre-cancelled connect fails before socket creation; no relative timeout is exposed |
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
| S010 | Privileged raw capability and native close wakeup | NOT_RUN; M8-002/M8-003 |
| S011 | Close/abort state, cancellation-closes-delegate and repeated terminal operations | PASS; lifecycle regression distinguishes pre-cancel from in-flight abort |
| S012 | Cookie injection, persistence failure, path precedence and unsafe parity metadata | NOT_RUN; M8-005 |
| S013 | Mutated DNS headers and malformed length/count/flags | NOT_RUN; M8-004 |
| S014 | Git writes a loader warning on stderr or evidence has a malformed revision | PASS; 26 repository-tooling tests including provenance regressions |
| S015 | Unix pathname contains NUL but abstract name legitimately contains it | PASS; shared endpoint/error regressions |

## Test-plan matrix

| ID | Scenarios | Command or evidence | Result |
|---|---|---|---|
| T001 | P001,P004 | `python3 tools/architecture_guard.py --format json` and public API inventory | PASS |
| T002 | P001,P002,P003,P004,P005,P006,P007 | `cjpm check` and `cjpm build` | PASS |
| T003 | P002,P003,P004,P005,P006,S005,S006,S011 | `cjpm test src/net --no-progress --no-color` | PASS; 14/14, no native datagram I/O claim |
| T004 | S001,S002,S003,S004,S014 | Repository-tooling, architecture guard and API/backlog regression tests | PASS |
| T005 | P006,S005 | Datagram result upper-bound and receive-buffer reuse regressions | PASS |
| T006 | S007,S008,S009,S010,S012,S013 | M8-002, M8-003, M8-004, M8-005 and M8-006 task gates | NOT_RUN; owned by later tasks |
| T007 | P007,S015 | Shared endpoint/error regressions through canonical `scripts/check` | PASS; 4 selected error cases and all 83 transport cases in the canonical gate |

The `NOT_RUN` rows are intentionally visible and cannot be used as release
evidence. No one-hour SSE profile or 86,400-second soak is run by this task.
