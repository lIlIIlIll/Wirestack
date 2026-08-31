# M3-031 test plan

## Semantics

M3-031 is a dependency-adoption gate. It proves that the current
provider-neutral TLS Core satisfies the desktop-applicable projection of the
inherited prerequisites and that pinned AWS-LC 5.5.0 passes every required
capability on native Windows x86_64 and macOS arm64 at one exact repository
revision. It does not implement system trust or system key adapters, complete
the historical global tasks, or claim M3-001's six-platform build condition.

A Linux-only result, stale hosted result, PARTIAL capability set, simulator
result, cross-compilation result or successful build without execution cannot
complete this task.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | M2-004, M2-006 and M3-030 are COMPLETE with evidence | task-contract dependency validation | reachable | All declared dependencies must be satisfied. |
| P002 | every desktop-applicable Core prerequisite maps to current source and tests | exact file, declaration and evidence checks | reachable | Covers the scoped projections of M3-001, M3-002, M3-006, M3-009 through M3-012, M3-016 and M3-018. |
| P003 | a required source, declaration or retained evidence input is missing | fail-closed Core audit | reachable error | The task cannot infer equivalence. |
| P004 | AWS-LC schema-v2 PoC executes on `windows-2025` x86_64 at the expected SHA | M0-016 result validator | reachable | Every required capability must be PASS. |
| P005 | AWS-LC schema-v2 PoC executes on `macos-15` arm64 at the expected SHA | M0-016 result validator | reachable | External signer and session resumption are mandatory. |
| P006 | result is stale, PARTIAL, SKIPPED, compile-only, wrong-platform or unknown-schema | stable validation code | reachable error | No incomplete result can be promoted to PASS. |
| P007 | desktop task dependencies use M3-031 and retain original acceptance text | exact backlog row audit | reachable | Only four desktop rows change dependencies. |
| P008 | mobile M4 dependencies and device requirements remain unchanged | exact backlog row audit | reachable | M3-031 does not unlock mobile work. |
| P009 | a report succeeds or fails while writing | same-directory atomic replacement | reachable | A reader sees one complete JSON document or the old file. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| Core prerequisite | present and mapped; missing file; missing declaration; stale evidence | All nine desktop projections are mandatory; excluded global conditions are listed separately and are never PASS. |
| Hosted platform | Windows x86_64; macOS arm64; Linux; simulator; cross-build | Only the two exact native desktop identities satisfy this task. |
| Provider result | PASS; PARTIAL; FAIL; BLOCKED; SKIPPED; unknown schema | PASS requires schema v2 and every capability PASS. |
| Revision | exact 40-hex SHA; stale SHA; absent SHA | Windows and macOS results must use one expected revision. |
| Provider | pinned AWS-LC 5.5.0; unknown; alternate; automatic fallback | Only the selected pinned provider can pass. |
| Task graph | exact desktop replacement; weakened criteria; mobile rewrite | Acceptance text and mobile dependencies must remain unchanged. |

## State and side effects

- Core audit reads source and retained evidence without changing them.
- Hosted runs download and build pinned provider source in runner-local output.
- Reports use atomic replacement and contain bounded diagnostics.
- A failed hosted job cannot update checked-in PASS evidence.
- This task does not update another task's status.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | current Core and retained Linux qualification | clean repository | P001,P002 | accept the desktop-scoped contract | all desktop projections are PASS, excluded global conditions are explicit and source digests are recorded | architecture | P0 |
| S002 | one missing Core declaration or evidence input | candidate PASS audit | P003 | reject | stable code identifies the missing requirement | fault-injection | P0 |
| S003 | current Windows AWS-LC result | native hosted runner | P004 | accept | schema v2, exact SHA, native identity and every capability PASS | platform | P0 |
| S004 | current macOS AWS-LC result | native hosted runner | P005 | accept | schema v2, exact SHA, arm64 identity, external signer and session PASS | platform | P0 |
| S005 | stale, PARTIAL, SKIPPED or wrong-platform result | otherwise valid result | P006 | reject | no substitute status becomes PASS | fault-injection | P0 |
| S006 | rewritten desktop dependency rows | current backlog | P007 | accept exact migration | four dependency fields match ADR-0007 and acceptance text is retained | architecture | P0 |
| S007 | current M4 rows | current backlog | P008 | remain unchanged | mobile prerequisites and native-device wording remain present | regression | P0 |
| S008 | report write interrupted before replacement | existing report | P009 | preserve complete old report | no temporary file remains after handled failure | lifecycle | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P002 | repository Core audit | PASS | nine inherited groups, source SHA-256 and retained evidence references | static,task |
| T002 | S002 | P003 | remove one required declaration in a temporary tree | FAIL | `CORE_REQUIREMENT` | fault-injection |
| T003 | S003 | P004 | AWS-LC on `windows-2025` | PASS | exact revision and fourteen capability values PASS | native-platform |
| T004 | S004 | P005 | AWS-LC on `macos-15` arm64 | PASS | exact revision, external signer calls and cleanup count | native-platform |
| T005 | S005 | P006 | schema, revision, status and platform mutations | FAIL | stable `RAW_RESULT`, `STALE_REVISION`, `INCOMPLETE_RESULT` or `PLATFORM` code | fault-injection |
| T006 | S006 | P007 | four M3 desktop backlog rows | PASS | exact dependencies and unchanged acceptance fragments | architecture |
| T007 | S007 | P008 | M4-001 through M4-014 rows | PASS | original Core dependencies and device language remain | regression |
| T008 | S008 | P009 | atomic JSON write with replacement failure injection | PASS | old JSON remains complete and temporary path is removed | unit,lifecycle |
| T009 | S001,S003,S004,S006,S007 | P001,P002,P004,P005,P007,P008 | task-level gate | PASS | zero failed commands, zero skipped acceptance commands | task |

## Excluded gates

M3-031 does not run the one-hour SSE profile, the 86,400-second soak, mobile
device gates, HTTP performance gates or release artifact qualification. Those
results cannot be inferred from the desktop provider PoCs.
