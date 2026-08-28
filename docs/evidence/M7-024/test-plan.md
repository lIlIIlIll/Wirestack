# M7-024 Linux performance release gate test plan

- Task: `M7-024`
- Profile: native Linux x86_64 glibc
- Inputs: retained raw reports from M1-027, M1-025, M2-016, M6-025,
  M5-030, M6-020 and M6-023
- Output: one machine-readable aggregate release decision
- Excluded: Linux musl, non-Linux platforms, SDK builds and runtime/std changes

M7-024 does not replace the component benchmarks. It pins their raw reports,
validates the experimental controls and metrics again, and turns them into one
fail-closed Linux release gate. Reading a component's top-level `PASS` value is
not sufficient.

## Semantics and side effects

The gate loads one repository-owned manifest, resolves every report below the
repository root, verifies each SHA-256 digest, parses finite JSON values, and
checks the frozen environment, rounds, sample counts, workload matrix and
thresholds. It writes one bounded JSON report. It does not execute a benchmark,
modify a source report, build an SDK component, or access another repository.

## Control-flow path matrix

| Path ID | Conditions and values | Expected terminal | Reachability |
|---|---|---|---|
| P001 | Manifest schema, gate id, profile and exactly eight domains are valid | Continue to artifact validation | reachable |
| P002 | Manifest is missing, malformed, has an unknown domain or a path escapes the repository | Write FAIL report and exit nonzero before trusting artifacts | reachable |
| P003 | Every raw report exists, matches its digest and contains finite JSON | Continue to domain checks | reachable |
| P004 | A report is missing, changed, malformed or contains a non-finite number | Write FAIL with the affected artifact and exit nonzero | reachable |
| P005 | Platform, compiler, target, libc, optimization, order and percentile controls match the frozen profile | Continue to metric checks | reachable |
| P006 | A required environment or experiment-control field is absent or mismatched | Mark the affected domain FAIL | reachable |
| P007 | Required rounds, samples, payloads, profiles, stream counts and durations meet their minima | Continue to thresholds | reachable |
| P008 | A workload is missing, duplicated or under-sampled | Mark the affected domain FAIL | reachable |
| P009 | Every extracted metric meets its PRD or component acceptance threshold | Mark the domain PASS | reachable |
| P010 | A metric misses its threshold or the source report decision is not PASS | Mark the domain FAIL with actual and required values | reachable |
| P011 | All eight domains PASS and every pinned artifact passes shared validation | Write aggregate PASS and exit zero | reachable |
| P012 | Any domain or shared validation fails | Write aggregate FAIL and exit nonzero | reachable |

## Input domains and state

- Paths: valid repository-relative file, absolute path, `..` escape, missing
  path and directory instead of a file.
- Digests: exact lowercase SHA-256, malformed digest and valid but stale digest.
- Values: expected scalar, missing key, wrong type, boundary equality, one unit
  below or above a threshold, `NaN` and infinity.
- Collections: exact workload inventory, missing item, duplicate item and
  unexpected item.
- State: first run, repeated run, PASS output replaced by FAIL output, and
  source reports unchanged after either terminal.

## Semantic scenario matrix

| Scenario ID | Input and pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|
| S001 | Valid raw TCP and cancellation reports | P001,P003,P005,P007,P009 | Five payloads retain 11 paired rounds, throughput ratio at least 0.95, P95 ratio at most 1.10, zero staging copies and cancellation P99 at most 50 ms | Assert exact payload set, samples, ratios, copies, cancellation terminals and PASS | normal | P0 |
| S002 | Valid DNS-to-connected report | P003,P005,P007,P009 | Six native profiles retain 11 rounds and 88 samples; cancellation P99 stays within 50 ms | Assert profile inventory, sample counts, impairment observations, cancellation value and PASS | normal,platform | P0 |
| S003 | Current M6-025 TLS requalification report | P003,P005,P007,P009 | Bulk and handshake ratios, resumed rounds, body growth and idle memory meet PRD limits | Assert 11 measured rounds, ratios, resumed flags, memory bounds and PASS | normal | P0 |
| S004 | Valid HTTP/1 report | P003,P005,P007,P009 | Seven alternating rounds meet 0.90 throughput ratio and bounded streaming-memory limits | Assert round counts, ratio, two streamed body sizes, RSS thresholds and PASS | normal | P0 |
| S005 | Valid HTTP/2 report | P003,P005,P007,P009 | Forward/reverse 1, 10 and 100 stream profiles keep one H2 connection, bounded queues and at most 0.25 H2/H1 connection ratio | Assert 20 rounds per pass, exact concurrency set, request counts, queue bounds, flow permits and PASS | normal | P0 |
| S006 | Valid SSE and memory reports | P003,P005,P007,P009 | H1 and H2 each run at least one hour and one million events with bounded application flow, cancellation under 50 ms and steady RSS/FD/socket/thread trends | Assert protocol inventory, duration, events, sequence, cancellation, samples, trend limits and PASS | normal,resource | P0 |
| S007 | Digest, schema, environment, workload or threshold mutation | P002,P004,P006,P008,P010,P012 | Gate fails closed and identifies the exact failed check | Assert nonzero exit, aggregate FAIL, domain FAIL and actual/expected values | error,regression | P0 |
| S008 | Same valid inputs run twice | P001,P003,P011 | Decisions and extracted baseline metrics are stable; source artifacts remain byte-identical | Assert two PASS decisions, equal normalized domains and unchanged input digests | repeated-call | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S002,S003,S004,S005,S006 | P001,P003,P005,P007,P009,P011 | Checked-in manifest and reports | Aggregate PASS with eight PASS domains | Assert exact domain set, artifact digests, controls, extracted metrics and zero failures | minimal |
| T002 | S007 | P002,P012 | Manifest with an unknown or missing domain | Aggregate FAIL | Assert exact-domain error and no false PASS | boundary |
| T003 | S007 | P002,P004,P012 | Escaping path, stale digest, missing file and malformed JSON | Aggregate FAIL before metric trust | Assert affected artifact and reason are retained | boundary,error |
| T004 | S007 | P004,P010,P012 | `NaN`, infinity, wrong scalar type and missing metric | Aggregate FAIL | Assert finite-number/type/key checks fail closed | boundary,error |
| T005 | S007 | P006,P008,P012 | Wrong platform/toolchain, reduced rounds or missing workload | Affected domain FAIL | Assert actual and required controls are present in output | regression |
| T006 | S007 | P010,P012 | Each comparison operator at equality and just beyond its limit | Equality passes and threshold miss fails | Assert `ge`, `le` and `eq` boundary semantics | boundary |
| T007 | S008 | P001,P003,P011 | Two runs with identical inputs | Both PASS with stable normalized domain results | Assert input digests unchanged and volatile timestamps are the only permitted report difference | repeated-call |
| T008 | S001,S002,S003,S004,S005,S006 | P003,P005,P007,P009 | Native glibc release evidence inspection | Platform-specific PASS only | Assert Linux/x86_64/glibc and pinned compiler/CJPM; make no musl or global claim | platform |

## Evidence and gaps

The raw reports retain the benchmark subprocess output and samples. M7-024
validates and references them by digest instead of copying or rerunning the
one-hour SSE profile. CPU affinity and governor were not frozen in the original
component reports, so this gate does not invent cross-host comparability. It
freezes the current host/toolchain evidence and its existing PRD thresholds.
