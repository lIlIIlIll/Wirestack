# M0-014 test plan

## Semantics

M0-014 profiles the native Windows x86_64 `std.net` receive path using a 64 KiB
application buffer. GitHub `windows-2025` is a native Windows execution target;
cross-compilation on Linux is not accepted. A result cannot pass unless read
sizes, allocation events, peak private bytes, copied bytes, performance samples,
and bounded cleanup are all present for the exact repository revision.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Windows x86_64 runner and native Cangjie toolchain | OS, runner, compiler target | reachable | Eligible execution environment. |
| P002 | Linux, cross-compile, missing compiler, or stale SHA | strict identity validator | reachable error | Must not PASS. |
| P003 | all five payloads through 64 KiB app buffer | byte and read-trace checks | reachable | Exact bytes and positive progress required. |
| P004 | ETW heap trace and Win32 memory counters available | tool and report checks | reachable | Allocation count and peak private bytes are measured. |
| P005 | copied-byte counter absent or only source-derived | availability classification | reachable error | `SOURCE_BOUND_DERIVATION` is not `MEASURED`. |
| P006 | reads larger than 4 KiB or cap not reproduced | read-size classifier | reachable error | The current fixed 4 KiB hypothesis is tested, not assumed. |
| P007 | timeout, server leak, monitor leak, or child remains | bounded cleanup checks | reachable error | Cleanup failure invalidates the case. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| platform | native Windows x86_64; cross-compile; non-Windows | Only native Windows can pass. |
| payload | 1 KiB; 16 KiB; 64 KiB; 1 MiB; 100 MiB | Every payload is mandatory. |
| metrics | measured; source-derived; skipped; unavailable | Only measured required metrics can pass. |
| report | current SHA; stale SHA; unknown schema; incomplete | Exact schema and SHA required. |
| lifecycle | success; timeout; child/server/monitor leak | All helpers terminate within bounds. |

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Windows capability probe | clean hosted runner | P001,P004 | readiness is explicit | tool paths and versions recorded | platform | P0 |
| S002 | non-native or stale report | candidate PASS | P002 | reject | stable error code | negative | P0 |
| S003 | complete payload matrix | native receiver | P003 | exact transfer | read sizes sum to payload | integration | P0 |
| S004 | missing allocation/copy counter | otherwise valid report | P004,P005 | reject | SKIPPED/derived cannot masquerade as PASS | negative | P0 |
| S005 | fixed 4 KiB hypothesis | payload above 4 KiB | P006 | report observed result | at least one large case proves cap | performance | P0 |
| S006 | timeout or helper leak | active probe | P007 | fail and clean up | no child/server/monitor remains | lifecycle | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P004 | `--environment-only` on `windows-2025` | READY or truthful BLOCKED | runner, CJC/CJPM and ETW tools recorded | native-platform |
| T002 | S002 | P002 | schema, platform and SHA mutations | FAIL | stable codes `UNKNOWN_SCHEMA`, `NON_NATIVE_WINDOWS`, `STALE_REVISION` | fault-injection |
| T003 | S003 | P003 | five-payload result | PASS | exact byte/read matrix | unit,integration |
| T004 | S004 | P004,P005 | SKIPPED, unavailable and source-derived metrics | FAIL | no false PASS | fault-injection |
| T005 | S005 | P006 | remove 4 KiB observation | FAIL | `FOUR_K_CAP` | fault-injection |
| T006 | S006 | P007 | cleanup failure | FAIL | `CLEANUP` | fault-injection,lifecycle |
| T007 | S002,S004 | P002,P005 | atomic validator output | PASS/FAIL | one complete JSON file and no temp residue | unit |

## Excluded gates

This bounded task does not run the one-hour SSE profile, 86,400-second soak, or
any TLS/HTTP platform qualification. An environment report is not M0-014 task
completion and cannot be promoted to copy-profile evidence.
