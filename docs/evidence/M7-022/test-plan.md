# M7-022 test plan

## Semantics

M7-022 qualifies the installed Linux release artifact with one uninterrupted
mixed-workload process. A formal result requires at least 86,400 seconds of
native Linux x86_64 glibc execution. Short runs are preflight evidence only and
cannot produce `PASS`.

The consumer uses the extracted M7-021 artifact as its only Wirestack
dependency. It keeps HTTP/1.1 and HTTP/2 servers alive while alternating idle
periods with new connections, pooled HTTP/1.1 requests, multiplexed HTTP/2
requests, numbered SSE traffic, request cancellation, connection cancellation,
and HTTP/2 stream cancellation. The process reports semantic counters and
heavy-GC heap samples. The runner independently samples its process tree for
RSS, file descriptors, sockets, timerfds, threads, and process count.

The gate classifies post-warmup median windows. Every required metric must have
enough samples, stay within its explicit growth limit, and finish with zero
application-owned waiters, buffers, or background tasks. Early exit, timeout,
source drift, artifact drift, malformed output, `SKIPPED`, or a short duration
fails closed.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Native platform is Linux x86_64 glibc | `platform` and libc preflight | Platform-dependent | Other platforms cannot produce PASS. |
| P002 | M7-021 report and artifact digest match the current qualified artifact | SHA-256 and qualification report validation | Reachable | The soak never silently rebuilds or substitutes an artifact. |
| P003 | Archive extraction stays below the temporary install root | M7-021 safe extractor | Reachable error path | Links and parent traversal fail before build. |
| P004 | Installed consumer imports only public `wirestack.http` APIs | source guard and clean CJPM dependency | Reachable | Repository source is not a consumer dependency. |
| P005 | Requested duration is at least 86,400 seconds | argument and result classification | Reachable | Smaller values are preflight-only and return INCOMPLETE. |
| P006 | One consumer process runs continuously for the requested duration | monotonic child and parent wall clocks | Reachable | Stitched or resumed partial runs cannot qualify. |
| P007 | Workload alternates active cycles with explicit idle intervals | semantic marker counters | Reachable | Both counters must be positive. |
| P008 | New clients create fresh connections and close them after use | connect and close counters | Reachable | Connection churn is part of the mixed load. |
| P009 | Persistent HTTP/1.1 client reuses its bounded pool | response version and request counters | Reachable | Every response body is fully consumed and closed. |
| P010 | Persistent HTTP/2 client completes concurrent sibling requests | response version and multiplex counters | Reachable | At least two siblings run in each multiplex batch. |
| P011 | H1 and H2 numbered SSE streams advance without lifetime accumulation | sequence parser and bounded producer lead | Reachable | The consumer stores no complete stream history. |
| P012 | H1 request cancellation terminates the controlled body | typed category/code and latency | Reachable | The handle is idempotent. |
| P013 | H2 stream cancellation sends a stream reset and a sibling still completes | typed stream handle and sibling response | Reachable | The connection stays usable. |
| P014 | Connection cancellation closes shared connection work and later reconnect succeeds | typed connection handle and recovery request | Reachable | Reset and reconnect counters must match. |
| P015 | Child emits exactly one final result and ordered resource samples | strict marker parser | Reachable | Duplicate, missing, reordered, or unknown fields fail. |
| P016 | Heavy GC samples record heap, active waiters, buffers, and background tasks | Cangjie runtime and application counters | Reachable | Final application counters must be zero. |
| P017 | Parent samples RSS, FD, socket, timerfd, process, and thread counts | Linux `/proc` process-tree sampler | Platform-dependent | Missing process samples fail closed. |
| P018 | Post-warmup first and last median windows stay within every bound | trend classifier | Reachable | Any FAIL or INCONCLUSIVE result blocks PASS. |
| P019 | Child exits early, times out, crashes, or leaves descendants alive | process-group ownership and terminal checks | Reachable error path | The runner terminates the complete process group. |
| P020 | Output exceeds the report limit | bounded tail capture plus full raw log | Reachable error path | Machine reports stay bounded. |
| P021 | Atomic report replacement succeeds or an injected replace fails | fsync plus same-directory replace | Reachable error path | An existing report survives failed replacement. |
| P022 | A long command is selected by task/full/fast rather than long mode | task-contract validator | Reachable error path | Long work never enters implicit gates. |
| P023 | Task or command timeout cannot cover 24 hours plus bounded teardown | repository timeout validation | Reachable error path | Long-task limit must exceed 86,400 seconds. |
| P024 | Source or report digest changes after acceptance | P1-012 evidence verifier | Reachable error path | Old PASS becomes STALE. |

## Input and state domains

| Domain | Partitions and boundaries | Required behavior |
|---|---|---|
| Platform | Linux x86_64 glibc; musl; other OS/CPU | Only the current Linux profile may qualify. |
| Duration | 0; short positive; 86,399; 86,400; above 86,400 | Only 86,400 or greater can PASS. |
| Artifact | exact digest; missing; changed; unsafe archive | Only the exact M7-021 artifact may run. |
| Process terminal | success; nonzero; timeout; signal; descendant leak | Only clean success with no surviving descendant may PASS. |
| Workload counters | zero; positive; inconsistent totals; overflow boundary | Every required workload must run and totals must reconcile. |
| Cancellation | H1 request; H2 stream; shared connection; repeated cancel | Typed terminal, idempotence, recovery, and sibling isolation are required. |
| Samples | missing; too few; sufficient; malformed; reordered | Missing or malformed samples are INCONCLUSIVE/FAIL. |
| Trend | falling; flat; bounded jitter; exact limit; over limit; monotonic growth | Equality passes; growth over a limit fails. |
| Report write | new target; replace target; injected replace failure | Writes are atomic and retain the old target on failure. |
| Gate routing | fast; task; full; long | The formal command appears only in long mode. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Exact installed artifact, short duration | Clean temporary consumer | P001-P004,P007-P018 | All mixed workloads execute, result is INCOMPLETE because duration is short | public imports, counters, samples, trends, clean exit | normal,platform | P0 |
| S002 | Exact installed artifact, 86,400 seconds | Clean host and no prior partial run | P001-P018 | One uninterrupted process completes and all resource trends pass | child and parent duration, every workload, every resource class | normal,platform | P0 |
| S003 | H1 request cancellation | Active numbered SSE body | P011,P012,P016 | Body returns typed Cancelled within budget and cleanup reaches zero | category, code, latency, idempotence, final counters | concurrency,regression | P0 |
| S004 | H2 stream cancellation with sibling | Multiplexed connection | P010,P011,P013,P016 | Cancelled stream resets while sibling and later request succeed | sibling before/after, typed cancel, zero pending body bytes | concurrency,regression | P0 |
| S005 | Connection cancellation and reconnect | Shared active connection | P008,P014,P016 | Connection work terminates and a fresh connection succeeds | cancellation count, reset count, reconnect count | concurrency,error | P0 |
| S006 | Persistent H1 and H2 active/idle phases | Warm pools and servers | P007-P011 | Pool and multiplex traffic continue through every phase | versions, response bodies, request totals, idle total | lifecycle | P0 |
| S007 | Flat or falling resource samples | Warmup complete | P016-P018 | Classifier returns PASS for every resource class | sample counts, median windows, growth and limit | boundary | P0 |
| S008 | One metric equals its limit | Synthetic samples | P018 | Boundary passes | exact growth comparison | boundary | P1 |
| S009 | One metric exceeds its limit or grows monotonically | Synthetic samples | P018 | Gate returns FAIL | failing metric and stable code | error | P0 |
| S010 | Short, missing, malformed, duplicate, reordered, or SKIPPED output | Child terminal available | P005,P015,P019,P020 | Gate cannot report PASS | stable parser code and bounded diagnostic | error | P0 |
| S011 | Missing or mismatched artifact/report | Preflight | P002,P003 | Gate stops before consumer build | stable artifact error and no child run | error,security | P0 |
| S012 | Unsupported OS, CPU, or libc | Preflight | P001 | Gate returns BLOCKED/FAIL, never PASS | platform code and no child run | platform,error | P0 |
| S013 | Child timeout, signal, nonzero exit, or descendant leak | Running process group | P019 | Gate terminates owned processes and reports FAIL | exit/signal/timeout fields and no orphan | error,lifecycle | P0 |
| S014 | Atomic replace succeeds and injected replacement fails | Existing report | P021 | Valid JSON replaces atomically; injected failure preserves old bytes | target bytes and no temporary residue | error,regression | P0 |
| S015 | Long command is routed into fast/task/full | Repository contract validation | P022,P023 | Contract is INVALID before execution | stable long-gate and timeout error codes | error,regression | P0 |
| S016 | Accepted source or report changes | Sealed PASS evidence | P024 | Evidence verifier returns STALE | changed path and nonzero exit | regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S003,S004,S005,S006 | P001-P018 | 10 to 30 second installed-artifact preflight | INCOMPLETE with every workload and resource sampler operational | public dependency, exact markers, positive counters, clean terminal | integration |
| T002 | S002,S003,S004,S005,S006,S007 | P001-P018 | formal 86,400 second native run | PASS | uninterrupted durations, all workloads, all trends, zero final counters | long,platform |
| T003 | S008,S009 | P018 | synthetic equality and over-limit windows | PASS then FAIL | exact median growth and stable metric decision | unit,boundary |
| T004 | S010 | P005,P015,P019,P020 | short duration and malformed marker variants | INCOMPLETE/FAIL, never PASS | duration, duplicate, order, unknown field, SKIPPED, bounded output | unit,error |
| T005 | S011 | P002,P003 | missing, digest-changed, and traversal artifact | FAIL before build | stable artifact code and no subprocess | unit,security |
| T006 | S012 | P001 | other OS/CPU and musl | BLOCKED/FAIL | no PASS and no child start | unit,platform |
| T007 | S013 | P019 | injected nonzero, timeout, signal, and live descendant | FAIL with full process-group cleanup | terminal fields and orphan check | unit,lifecycle |
| T008 | S014 | P021 | existing JSON plus successful and failing replace | atomic replacement or preserved old content | fsync/replace outcome and no temp files | unit,regression |
| T009 | S015 | P022,P023 | long command in wrong gate and 86,400-only timeout | INVALID | stable `LONG_GATE_LEAK` or `TIMEOUT` classification | unit,regression |
| T010 | S016 | P024 | mutate one sealed source/report | STALE | changed digest cannot reuse PASS | integration,regression |
| T011 | S001,S010 | P004,P015,P020 | internal import and oversized output injection | FAIL with bounded report | import guard and tail length | unit,security |
| T012 | S001,S002 | P002,P005,P006 | raw child and parent timing reconciliation | short is INCOMPLETE, formal duration may PASS | monotonic duration agreement and no partial-run stitching | unit,long |

## Coverage and reverse review

- The formal run is intentionally separate from `scripts/check`, `check-fast`,
  `check-task`, and `check-full`.
- The short preflight proves workload reachability and report plumbing. It does
  not prove the 24-hour resource trend.
- M0-011 retains Transport-only peer-reset and cleanup history. M7-022 adds the
  installed-artifact protocol mix and does not relabel the old report.
- Linux musl remains outside the current platform profile under ADR-0004.
- No coverage percentage is claimed. The gate records semantic and resource
  evidence instead.
