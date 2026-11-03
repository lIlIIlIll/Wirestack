# M2-004 test plan

## Semantics

M2-004 supplies the Windows `SystemResolver` through the existing bounded
native worker-pool ABI. Current requalification requires native Cangjie
execution on the GitHub `windows-2025` runner using the official Windows x64
STS 1.2.0 archive pinned in `docs/references/m2-004-sts-sdk.json`. The runner
records the pinned archive checksum, matches installed SDK files to archive
members, and requires both `cjc` and `cjpm` to report 1.2.0.

The report binds the exact revision and every path in the M2-004 task
manifest's `source_paths` with typed UTF-8/LF digests. Linux builds,
cross-compilation, native-C-only probes, skipped cases, stale reports, and
reports from earlier SDK channels or versions are not current Windows evidence.

The Windows adapter returns every IPv4/IPv6 candidate up to the caller's
explicit bound, does not invent DNS TTL data, maps Winsock failures to stable
Wirestack error categories, and keeps blocking name-service work off Cangjie
scheduler carrier threads. Cancellation and Deadline expiry return promptly;
unfinished native calls remain quarantined within the process-wide bounded
worker allocation until completion.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | native Windows x86_64 runner with the pinned official STS 1.2.0 archive | SDK archive hash, archive/install file equality, `cjc`/`cjpm` version and target | reachable | Only this path can produce current platform PASS. |
| P002 | Linux, cross-compile, missing tool, unknown schema, stale SHA, or stale source inventory | fail-closed report validator | reachable error | Must not PASS or DEGRADED-as-PASS. |
| P003 | valid host, family and maximum-results bound | native resolver plus public contract assertions | reachable | Retain all returned candidates up to the bound. |
| P004 | Winsock success and documented resolver failures | stable result/native-code mapping | reachable | No exception-message parsing. |
| P005 | caller cancellation or Deadline while native lookup remains active | terminal-category and elapsed-time assertions | reachable | Caller returns promptly; the fixture's native sleep outlives the caller. |
| P006 | invalid pool bounds, repeated close, or resolve after close | fixed ABI status mapping and lifecycle checks | reachable error | Selected tests assert invalid bounds, idempotent close and use-after-close result. |
| P007 | delayed job cancellation/Deadline followed by resolver close | caller and pool ownership transitions | reachable | Selected Windows receipt does not assert eventual reaper completion or native resource counters. |
| P008 | build on Linux or Windows | strict build-time platform selector | reachable | No runtime guessing or fallback. |
| P009 | exact revision with changed, missing, or extra manifest source input | typed source inventory comparison | reachable error | Current source paths and normalized text digests must match. |
| P010 | archive checksum/version/channel/target mismatch | pinned SDK identity verifier | reachable error | No nightly, prerelease, PATH-selected, or unpinned SDK is accepted. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| platform | native Windows x86_64; Linux x86_64; cross-compiled Windows; unsupported | Only native Windows with the pinned STS SDK satisfies M2-004. |
| SDK identity | exact STS 1.2.0 archive/name/hash/size; altered bytes; wrong channel/version/target | Installed `cjc` and `cjpm` must come from the extracted archive and report 1.2.0. |
| host | localhost; deterministic fixture names; invalid/unknown; delayed | Host input remains bounded to 253 bytes. |
| family | any; IPv4; IPv6; unknown integer | Unknown family is rejected. |
| results | 1; multiple; maximum 1024; oversized | Storage and output remain bounded. |
| terminal | success; name-not-found; no-data; temporary; unsupported-family; system | Stable Wirestack result plus optional native code. |
| lifecycle | open; close; repeated close; caller release during delayed queued/running/complete work | Selected Windows cases cover delayed cancellation/Deadline and double close/use-after-close; they do not assert final reaper counters. |
| report | exact SHA/source inventory; stale SHA; unknown schema; skipped case; timeout; missing log | Only exact complete PASS is accepted. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Windows hosted runner and official Windows x64 STS 1.2.0 archive | clean checkout | P001,P009,P010 | select and build Windows resolver | native OS/target, exact revision, pinned archive digest and matching installed bytes recorded | platform | P0 |
| S002 | valid localhost and deterministic multi-address fixture | open pool | P003,P004,P007 | resolve through the public contract | all candidates/families, System source, no TTL | integration | P0 |
| S003 | family and result bounds | open pool | P003,P006 | respect caller bounds | IPv4/IPv6 filter and max-results enforced | boundary | P0 |
| S004 | deterministic Winsock failures and unknown native error | open pool | P004 | map without text parsing | category, DNS phase, stable code and native code | fault-injection | P0 |
| S005 | delayed native lookup with cancellation and Deadline | worker occupied | P005,P007 | caller returns within 50 ms target | Cancelled and Timeout categories, separate <50 ms checks, then close; no claim of eventual native cleanup counters | concurrency | P0 |
| S006 | invalid worker/queue bounds, repeated close and resolve after close | bounded pool | P006,P007 | reject invalid bounds and post-close use | stable SystemFailure with no native code; close is idempotent | lifecycle | P0 |
| S007 | stale, skipped, timed-out, wrong-platform or malformed report | candidate evidence | P002 | reject candidate | explicit bounded failure code | negative | P0 |
| S008 | Linux regression after platform-neutral refactor | Linux glibc checkout | P008 | preserve existing Linux behavior | focused and repository checks pass locally | regression | P0 |
| S009 | current source files match manifest inventory | candidate report | P009 | bind every current source input | exact path set and typed text digest for each input | evidence-integrity | P0 |
| S010 | archive bytes or tool version differ from official STS pin | candidate runner | P010 | reject before current qualification | official URL, archive SHA, installed-file match, `cjc`/`cjpm` version and native target must agree | negative | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S009,S010 | P001,P009,P010 | hosted runner with committed STS pin | PASS | exact revision/source inventory, archive SHA and installed SDK bytes; `cjc` and `cjpm` both report STS 1.2.0 | native-platform |
| T002 | S002,S003 | P003,P004,P007 | Windows Cangjie resolver suite | PASS | candidates, family, bounds, no fake TTL | integration |
| T003 | S004 | P004 | injected Winsock status matrix | PASS | stable error/native-code mapping | fault-injection |
| T004 | S005 | P005,P007 | delayed lookup, cancel and Deadline | PASS | named case asserts distinct terminal category and each return latency below 50 ms; close is invoked while delayed work may remain | concurrency |
| T005 | S006 | P006,P007 | invalid bounds, close twice, use-after-close | PASS | invalid constructors throw; post-close resolution is SystemFailure with no native code | lifecycle,fault-injection |
| T006 | S007,S009,S010 | P002,P009,P010 | schema/revision/source/SDK/log mutations | FAIL | unknown schema, stale SHA, changed source digest, pinned archive digest drift, typed log digest drift, skipped case and timeout are rejected | unit,fault-injection |
| T007 | S008 | P008 | Linux focused tests and `scripts/check` | PASS | no Linux regression | regression |
| T008 | S007 | P002 | atomic report replacement | PASS | complete JSON replaces the previous document without temporary-file residue | unit |
| T009 | S009 | P009 | mutate or remove one manifest input after capture | FAIL | current source inventory differs and report is rejected | negative |
| T010 | S010 | P010 | wrong archive checksum/version/channel/target or installed byte | FAIL | pinned SDK identity rejects before acceptance | negative |


## Current evidence boundary

The previous schema-v1 Windows report was produced with an alpha SDK and remains
historical. The old M2-004 generic evidence index is also retained as historical
bytes; neither is rewritten or used as current STS evidence. The current report,
validation and six logs are produced only by the pinned native Windows workflow
at `docs/evidence/M2-004/current-desktop/windows-x86_64/`. No new native capture
has run yet. Coverage and mutation artifacts are not provided, so no coverage or
mutation adequacy claim is made.
## Excluded gates

M2-004 does not run the one-hour SSE profile, the 86,400-second soak, TLS or
HTTP protocol qualification, non-Windows platform gates, or mobile-device
tests. A native-C-only result is supporting evidence, not task completion.
