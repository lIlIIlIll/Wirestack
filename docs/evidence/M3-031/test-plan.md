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
| P004 | AWS-LC schema-v11 PoC executes on `windows-2025` x86_64 at the expected SHA | M0-016 result validator | reachable | Every required capability must be PASS. |
| P005 | AWS-LC schema-v11 PoC executes on `macos-15` arm64 at the expected SHA | M0-016 result validator | reachable | External signer and session resumption are mandatory. |
| P006 | result is stale, PARTIAL, SKIPPED, compile-only, wrong-platform or unknown-schema | stable validation code | reachable error | No incomplete result can be promoted to PASS. |
| P007 | desktop task dependencies use M3-031 and retain original acceptance text | exact backlog row audit | reachable | Only four desktop rows change dependencies. |
| P008 | mobile M4 dependencies and device requirements remain unchanged | exact backlog row audit | reachable | M3-031 does not unlock mobile work. |
| P009 | a report succeeds or fails while writing | same-directory atomic replacement | reachable | A reader sees one complete JSON document or the old file. |
| P010 | provider validation targets an alternate repository root | root-scoped manifest and provider-spec loading | reachable | Validation never mixes metadata from the tool's own checkout with the selected tree. |
| P011 | current resolver native source differs from the retained native report | current-tree, evidence-inventory and report-input digest comparison | reachable error | Native dependency drift fails even when unrelated historical inputs use sealed-inventory semantics. |
| P012 | M2-004 or M2-006 status is no longer COMPLETE | exact current status-row validation | reachable error | Retained PASS evidence cannot override a corrected dependency status. |
| P013 | a desktop backlog row keeps one phrase but drops another acceptance requirement | exact full acceptance-column comparison | reachable error | Dependency migration cannot weaken any pre-existing desktop criterion. |
| P014 | M3-030 status is no longer COMPLETE | exact current status-row validation before retained-evidence validation | reachable error | Retained PASS reports cannot override a corrected provider-architecture task status. |
| P015 | any required M3-030 report is missing, stale or not PASS | exact manifest, index, digest and payload validation | reachable error | A partial retained-report subset cannot qualify the provider architecture dependency. |
| P016 | an indexed M3-030 report keeps PASS but violates its report-specific contract | canonical expected-field and task-command validation | reachable error | Empty ABI failures, exact provider selection, release/SBOM identity and executed task commands are mandatory. |
| P017 | a native provider result refers to a missing, escaping or digest-mismatched license bundle | M0-016 bundle manifest and per-file validator | reachable error | Both hosted license inventories must remain complete and byte-exact. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| Core prerequisite | present and mapped; missing file; missing declaration; stale evidence | All nine desktop projections are mandatory; excluded global conditions are listed separately and are never PASS. |
| Hosted platform | Windows x86_64; macOS arm64; Linux; simulator; cross-build | Only the two exact native desktop identities satisfy this task. |
| Provider result | PASS; PARTIAL; FAIL; BLOCKED; SKIPPED; unknown schema | PASS requires schema v11, a zero PoC exit code and every capability PASS. |
| Revision | exact 40-hex SHA; stale SHA; absent SHA | Windows and macOS results must use one expected revision. |
| Provider | pinned AWS-LC 5.5.0; unknown; alternate; automatic fallback | Only the selected pinned provider can pass. |
| Task graph | exact desktop replacement; weakened criteria; mobile rewrite | Acceptance text and mobile dependencies must remain unchanged. |
| Retained M3-030 report | exact semantic payload; missing ABI function; changed provider identity; SKIPPED command presented as PASS | Every one of the nine required reports is checked against its report-specific contract. |
| Provider license bundle | complete bundle; missing manifest; path escape; changed manifest or file digest | The result path confines the bundle and its manifest binds all 11 files and total bytes. |

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
| S003 | current Windows AWS-LC result | native hosted runner | P004 | accept | schema v11, exact SHA, native identity and every capability PASS | platform | P0 |
| S004 | current macOS AWS-LC result | native hosted runner | P005 | accept | schema v11, exact SHA, arm64 identity, external signer and session PASS | platform | P0 |
| S005 | stale, PARTIAL, SKIPPED or wrong-platform result | otherwise valid result | P006 | reject | no substitute status becomes PASS | fault-injection | P0 |
| S006 | rewritten desktop dependency rows | current backlog | P007 | accept exact migration | four dependency fields match ADR-0007 and acceptance text is retained | architecture | P0 |
| S007 | current M4 rows | current backlog | P008 | remain unchanged | mobile prerequisites and native-device wording remain present | regression | P0 |
| S008 | report write interrupted before replacement | existing report | P009 | preserve complete old report | no temporary file remains after handled failure | lifecycle | P1 |
| S009 | alternate root has a moved AWS-LC manifest pin | otherwise valid provider result | P010 | reject | selected root controls both manifest and provider-spec validation | fault-injection | P0 |
| S010 | current native resolver source drifts after retained execution | otherwise valid dependency evidence | P011 | reject | stable `STALE_SOURCE` identifies the native input | fault-injection | P0 |
| S011 | M2 dependency status changes from COMPLETE to BLOCKED | retained evidence remains PASS | P012 | reject | stable dependency-evidence failure identifies non-COMPLETE status | fault-injection | P0 |
| S012 | M3-014 retains its first acceptance phrase but drops identity/chain or non-exposure requirements | dependencies remain exact | P013 | reject | complete acceptance column must match the frozen contract | fault-injection | P0 |
| S013 | M3-030 status changes from COMPLETE to BLOCKED | retained provider-architecture evidence remains PASS | P014 | reject | stable retained-evidence failure identifies non-COMPLETE status | fault-injection | P0 |
| S014 | M3-030 release validation changes to FAIL while its index digest is updated | other required reports remain PASS | P015 | reject | all nine manifest-required reports must remain indexed, digest-current and PASS | fault-injection | P0 |
| S015 | M3-030 native ABI records a missing required function, or a task command is changed to SKIPPED, while index digests are updated | top-level report status remains PASS | P016 | reject | report-specific invariants reject semantic corruption hidden behind a fresh digest | fault-injection | P0 |
| S016 | Windows/macOS result refers to an absent, escaping or modified license bundle | provider result otherwise passes schema-v11 validation | P017 | reject | stable validation rejects the bundle before the result is promoted | fault-injection | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P002 | repository Core audit | PASS | nine inherited groups, source SHA-256 and retained evidence references | static,task |
| T002 | S002 | P003 | remove one required declaration in a temporary tree | FAIL | `CORE_REQUIREMENT` | fault-injection |
| T003 | S003 | P004 | AWS-LC on `windows-2025` | PASS | exact revision and eighteen capability values PASS | native-platform |
| T004 | S004 | P005 | AWS-LC on `macos-15` arm64 | PASS | exact revision, external signer calls and cleanup count | native-platform |
| T005 | S005 | P006 | schema, revision, status and platform mutations | FAIL | stable `RAW_RESULT`, `STALE_REVISION`, `INCOMPLETE_RESULT` or `PLATFORM` code | fault-injection |
| T006 | S006 | P007 | four M3 desktop backlog rows | PASS | exact dependencies and unchanged acceptance fragments | architecture |
| T007 | S007 | P008 | M4-001 through M4-014 rows | PASS | original Core dependencies and device language remain | regression |
| T008 | S008 | P009 | atomic JSON write with replacement failure injection | PASS | old JSON remains complete and temporary path is removed | unit,lifecycle |
| T009 | S001,S003,S004,S006,S007 | P001,P002,P004,P005,P007,P008 | task-level gate | PASS | zero failed commands, zero skipped acceptance commands | task |
| T010 | S009 | P010 | valid result plus moved manifest under `--root` | FAIL | `PROVIDER` is derived from the selected tree | fault-injection |
| T011 | S010 | P011 | mutate the current Windows resolver source after sealing | FAIL | `STALE_SOURCE` applies even when broad historical-source verification is disabled | fault-injection |
| T012 | S011 | P012 | mutate the M2-004 status row to BLOCKED while retaining evidence | FAIL | dependency evidence cannot pass without current COMPLETE status | fault-injection |
| T013 | S012 | P013 | retain only the first M3-014 acceptance phrase | FAIL | `TASK_GRAPH` rejects the weakened full column | fault-injection |
| T014 | S013 | P014 | mutate the M3-030 status row to BLOCKED while retaining evidence | FAIL | `RETAINED_EVIDENCE` rejects the stale dependency qualification | fault-injection |
| T015 | S014 | P015 | mutate indexed M3-030 release validation from PASS to FAIL | FAIL | `RETAINED_EVIDENCE` rejects a failing required report even when its digest is current | fault-injection |
| T016 | S015 | P016 | mutate `missingFunctions` and a task-command status while updating their indexed digests | FAIL | `RETAINED_EVIDENCE` rejects both semantic mutations | fault-injection |
| T017 | S016 | P017 | mutate bundle digest/path and omit the retained manifest | FAIL | `LICENSE_BUNDLE` or the underlying raw-result path guard rejects the result | fault-injection |

## Excluded gates

M3-031 does not run the one-hour SSE profile, the 86,400-second soak, mobile
device gates, HTTP performance gates or release artifact qualification. Those
results cannot be inferred from the desktop provider PoCs.
