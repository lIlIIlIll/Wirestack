# M2-004 test plan

## Semantics

M2-004 supplies the Windows `SystemResolver` through the existing bounded
native worker-pool ABI. Completion requires native Cangjie execution on the
GitHub `windows-2025` runner at the exact repository revision. Linux builds,
cross-compilation, native-C-only probes, skipped cases, and stale reports are
not Windows platform evidence.

The Windows adapter returns every IPv4/IPv6 candidate up to the caller's
explicit bound, does not invent DNS TTL data, maps Winsock failures to stable
Wirestack error categories, and keeps blocking name-service work off Cangjie
scheduler carrier threads. Cancellation and Deadline expiry return promptly;
unfinished native calls remain quarantined within the process-wide bounded
worker allocation until completion.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | native Windows x86_64 runner with Cangjie/CJPM and native toolchain | platform and toolchain identity | reachable | Only this path can produce platform PASS. |
| P002 | Linux, cross-compile, missing tool, unknown schema, or stale SHA | fail-closed report validator | reachable error | Must not PASS or DEGRADED-as-PASS. |
| P003 | valid host, family and maximum-results bound | native resolver plus public contract assertions | reachable | Retain all returned candidates up to the bound. |
| P004 | Winsock success and documented resolver failures | stable result/native-code mapping | reachable | No exception-message parsing. |
| P005 | caller cancellation or Deadline while native lookup remains active | latency and terminal-category assertions | reachable | Caller returns promptly; native capacity remains bounded. |
| P006 | queue full, pool closed, repeated close, or invalid bounds | fixed ABI status mapping and lifecycle checks | reachable error | Admission and cleanup are bounded and idempotent. |
| P007 | job pending, completes, caller releases, or pool is destroyed | exactly-once ownership checks | reachable | No use-after-free or leaked caller reference. |
| P008 | build on Linux or Windows | strict build-time platform selector | reachable | No runtime guessing or fallback. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| platform | native Windows x86_64; Linux x86_64; cross-compiled Windows; unsupported | Only native Windows satisfies M2-004. |
| host | localhost; deterministic fixture names; invalid/unknown; delayed | Host input remains bounded to 253 bytes. |
| family | any; IPv4; IPv6; unknown integer | Unknown family is rejected. |
| results | 1; multiple; maximum 1024; oversized | Storage and output remain bounded. |
| terminal | success; name-not-found; no-data; temporary; unsupported-family; system | Stable Wirestack result plus optional native code. |
| lifecycle | open; overloaded; close; repeated close; caller release during queued/running/complete | Every resource has one bounded owner path. |
| report | exact SHA; stale SHA; unknown schema; skipped test; timeout | Only exact complete PASS is accepted. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Windows hosted runner capability | clean checkout | P001,P008 | select and build Windows resolver | OS, CJC, CJPM, compiler and revision recorded | platform | P0 |
| S002 | valid localhost and deterministic multi-address fixture | open pool | P003,P004,P007 | resolve through the public contract | all candidates/families, System source, no TTL | integration | P0 |
| S003 | family and result bounds | open pool | P003,P006 | respect caller bounds | IPv4/IPv6 filter and max-results enforced | boundary | P0 |
| S004 | deterministic Winsock failures and unknown native error | open pool | P004 | map without text parsing | category, DNS phase, stable code and native code | fault-injection | P0 |
| S005 | delayed native lookup with cancellation and Deadline | worker occupied | P005,P007 | caller returns within 50 ms target | Cancelled/Timeout exactly once and no carrier starvation | concurrency | P0 |
| S006 | capacity exhaustion, invalid arguments and repeated close | bounded pool | P006,P007 | fail closed and clean up | stable status, no unbounded admission, idempotent close | lifecycle | P0 |
| S007 | stale, skipped, timed-out, wrong-platform or malformed report | candidate evidence | P002 | reject candidate | explicit bounded failure code | negative | P0 |
| S008 | Linux regression after platform-neutral refactor | Linux glibc checkout | P008 | preserve existing Linux behavior | focused and repository checks pass locally | regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P008 | build and toolchain probe on `windows-2025` | PASS | native Windows identity and exact SHA | native-platform |
| T002 | S002,S003 | P003,P004,P007 | Windows Cangjie resolver suite | PASS | candidates, family, bounds, no fake TTL | integration |
| T003 | S004 | P004 | injected Winsock status matrix | PASS | stable error/native-code mapping | fault-injection |
| T004 | S005 | P005,P007 | delayed lookup, cancel and Deadline | PASS | terminal category and latency bound | concurrency |
| T005 | S006 | P006,P007 | invalid bounds, overload, close/release races | PASS | fixed capacity and cleanup | lifecycle,fault-injection |
| T006 | S007 | P002 | schema/SHA/platform/skip/timeout mutations | FAIL | invalid evidence never reports PASS | unit,fault-injection |
| T007 | S008 | P008 | Linux focused tests and `scripts/check` | PASS | no Linux regression | regression |
| T008 | S007 | P002 | atomic report replacement under injected write failure | PASS | no partial JSON or temp residue | unit,fault-injection |

## Excluded gates

M2-004 does not run the one-hour SSE profile, the 86,400-second soak, TLS or
HTTP protocol qualification, non-Windows platform gates, or mobile-device
tests. A native-C-only result is supporting evidence, not task completion.
