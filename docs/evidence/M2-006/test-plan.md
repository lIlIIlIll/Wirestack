# M2-006 test plan

## Semantics

M2-006 supplies the Apple `SystemResolver` through the provider-neutral
resolver contract and the existing bounded native worker-pool ABI. Completion
requires native Cangjie execution at an exact repository revision on the
desktop macOS arm64 target and separate iOS Simulator arm64 qualification. The
desktop workflow uses the official STS 1.2.0 macOS arm64 archive pinned in
`docs/references/m2-006-sts-sdk.json`. Its report binds the archive bytes,
selected SDK tools, source inventory, and native test results. The current
workflow does not run iOS; mobile/iOS remains unverified. Linux execution,
cross-compilation, native-C-only probes, skipped cases, and stale reports are
not Apple platform evidence.

The Apple adapter returns every IPv4 and IPv6 candidate up to the caller's
explicit bound, does not invent DNS TTL data, maps POSIX resolver failures to
stable Wirestack errors, and keeps blocking name-service work off Cangjie
scheduler carrier threads. Cancellation and Deadline expiry return promptly;
unfinished native calls remain quarantined within a process-wide bounded
worker allocation until completion. A later resolution always performs a new
native lookup so that network changes are observable without a process restart.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | clean exact-revision checkout on native macOS arm64 with the pinned STS 1.2.0 SDK and Xcode tools | platform, archive byte-count/digest, installed toolchain and revision identity | reachable | Only the desktop STS run can satisfy the macOS half of M2-006. |
| P002 | native iOS Simulator arm64 with an official, separately pinned STS SDK | simulator, SDK and revision identity | unverified | The desktop workflow does not run iOS; no mobile evidence is accepted from nightly SDKs. |
| P003 | Linux, cross-compile-only, missing tool, wrong platform, unknown schema, or stale SHA | fail-closed report validator | reachable error | Must not PASS or treat DEGRADED/SKIPPED as PASS. |
| P004 | valid host, family and maximum-results bound | native resolver plus public contract assertions | reachable | Retain all returned candidates up to the bound. |
| P005 | POSIX success and documented `getaddrinfo` failures | stable result and native-code mapping | reachable | No exception-message parsing. |
| P006 | caller cancellation or Deadline while native lookup remains active | latency and terminal-category assertions | reachable | Caller returns promptly; native capacity remains bounded. |
| P007 | queue full, pool closed, repeated close, or invalid bounds | fixed ABI status mapping and lifecycle checks | reachable error | Admission and cleanup are bounded and idempotent. |
| P008 | job pending, completes, caller releases, or pool is destroyed | exactly-once ownership checks | reachable | No use-after-free or leaked caller reference. |
| P009 | resolver is called before and after a simulated network change | fresh native lookup and result comparison | reachable | No hidden resolver cache or process-restart requirement. |
| P010 | build on Linux, macOS, or iOS Simulator | strict build-time platform selector | reachable | No runtime platform guessing or automatic fallback. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| platform | native macOS arm64 with pinned STS 1.2.0; native iOS Simulator arm64 with its separately qualified STS SDK; Linux x86_64; cross-compiled Apple; unsupported | Only matching native Apple execution satisfies its platform claim; mobile remains unverified. |
| host | localhost; deterministic multi-address fixture; invalid/unknown; delayed; changing | Host input remains bounded to 253 bytes. |
| family | any; IPv4; IPv6; unknown integer | Unknown family is rejected. |
| results | 1; multiple; maximum 1024; oversized | Storage and output remain bounded. |
| terminal | success; name-not-found; no-data; temporary; unsupported-family; system; unknown native code | Stable Wirestack result plus optional native code. |
| lifecycle | open; overloaded; close; repeated close; caller release during queued/running/complete | Every resource has one bounded owner path. |
| network generation | first lookup; changed generation; repeated unchanged generation | Every public resolve call reaches the native adapter. |
| report | exact SHA; stale SHA; unknown schema; skipped test; timeout; wrong platform | Only exact complete PASS is accepted. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | GitHub-hosted macOS capability | clean exact-revision checkout and verified STS 1.2.0 archive | P001,P010 | build and run the desktop resolver | OS, architecture, exact archive size and digest, SDK-root CJC/CJPM, source inventory and revision recorded | platform | P0 |
| S002 | GitHub-hosted iOS Simulator capability | separate native iOS STS prerequisite | P002,P010 | qualify the iOS resolver on a separate native workflow | simulator runtime, SDK, architecture and revision recorded; this proof is not present | platform | P0 |
| S003 | localhost and deterministic multi-address fixture | open pool | P004,P005,P008 | resolve through the public contract | all candidates/families, System source, no TTL, deduplication | integration | P0 |
| S004 | family and result bounds | open pool | P004,P007 | respect caller bounds | IPv4/IPv6 filter and max-results enforced | boundary | P0 |
| S005 | deterministic POSIX failures and unknown native error | open pool | P005 | map without text parsing | category, DNS phase, stable code and native code | fault-injection | P0 |
| S006 | delayed native lookup with cancellation and Deadline | worker occupied | P006,P008 | caller returns within the latency target | Cancelled/Timeout exactly once and no carrier starvation | concurrency | P0 |
| S007 | capacity exhaustion, invalid arguments and repeated close | bounded pool | P007,P008 | fail closed and clean up | stable status, no unbounded admission, idempotent close | lifecycle | P0 |
| S008 | two lookups around a deterministic network-generation change | open pool | P009 | second lookup observes changed addresses | no cache, no restart, distinct bounded result | integration | P0 |
| S009 | stale, skipped, timed-out, wrong-platform or malformed report | candidate evidence | P003 | reject candidate | explicit bounded failure code | negative | P0 |
| S010 | Linux regression after platform-neutral selector changes | Linux glibc checkout | P010 | preserve the existing Linux resolver | focused and repository checks pass locally | regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P010 | build and run on `macos-15` with pinned STS 1.2.0 | PASS required; current capture pending | native macOS identity, exact archive size and checksum, SDK-root tool identity, exact source SHA, and eight cases with zero failures/errors/skips/timeouts | native-platform |
| T002 | S002 | P002,P010 | build and execute on a native iOS Simulator using a separately qualified STS SDK | BLOCKED, mobile/iOS unverified | native simulator identity, exact SDK pin, process exit and assertions are still required for full M2-006 | native-platform |
| T003 | S003,S004 | P004,P005,P008 | Apple Cangjie resolver suite | PASS | candidates, family, bounds, deduplication and no fake TTL | integration |
| T004 | S005 | P005 | injected POSIX status matrix | PASS | stable error and native-code mapping | fault-injection |
| T005 | S006 | P006,P008 | delayed lookup, cancellation and Deadline | PASS | terminal category and latency bound | concurrency |
| T006 | S007 | P007,P008 | invalid bounds, overload, close and release races | PASS | fixed capacity and cleanup | lifecycle,fault-injection |
| T007 | S008 | P009 | deterministic generation change between lookups | PASS | fresh native query returns changed result | integration |
| T008 | S009 | P003 | schema/SHA/platform/skip/timeout mutations | FAIL | invalid evidence never reports PASS | unit,fault-injection |
| T009 | S010 | P010 | Linux focused tests and repository checks | PASS | no Linux regression | regression |
| T010 | S009 | P003 | retained report and command logs with refreshed typed digests but a changed resolver-test output | FAIL | the log must match its command receipt, and skipped/case-inventory failures remain derived from retained output | unit,fault-injection |

## Excluded gates

M2-006 does not run the one-hour SSE profile, the 86,400-second soak, TLS or
HTTP protocol qualification, physical iPhone/iPad tests, Android, HarmonyOS,
Windows, or performance gates. iOS Simulator execution remains required for
full M2-006 completion, but it is outside this desktop STS qualification and
is explicitly unverified.
