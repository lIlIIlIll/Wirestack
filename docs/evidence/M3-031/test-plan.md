# M3-031 test plan

## Semantics

M3-031 is a dependency-adoption gate. It proves that the current
provider-neutral TLS Core satisfies the desktop-applicable projection of the
inherited prerequisites and that pinned AWS-LC 5.5.0 passes every required
capability on native Windows x86_64 and macOS arm64 at one exact repository
revision. It does not implement system trust or system key adapters, complete
the historical global tasks, or claim M3-001's six-platform build condition.

The canonical `current-core/qualification.json` is required current-Core
evidence. It binds the frozen source revision, production and execution inputs,
the pinned STS SDK archive and installed tools, actual provider selection and
ABI, native archive, all executed command receipts and retained logs, and a
fresh installed M7-021 HTTPS consumer qualification. Historical M3-030
reports are fully checked for identity, inventory, digest integrity and
provenance, but any failure is recorded only as a HISTORICAL diagnostic. Their
semantic contents and integrity status cannot qualify or block today's Core.

Fresh M3-031 admission requires new current-desktop report and validation
pairs for M2-004 on Windows x86_64 and M2-006 on macOS arm64. Each pair is
validated at the frozen source revision and binds the pinned STS archive,
installed tool identity, complete source inventory, native test results and
retained logs. The legacy generic M2 indexes/reports are not current resolver
proof and remain untouched. M3-031 does not require global M2 task statuses
to be COMPLETE, consume M2-006 iOS evidence, or claim those broader tasks
complete. Until both authorized native workflow captures are available, the
adoption audit remains BLOCKED; synthetic tests are not native evidence.

A Linux-only hosted result, stale current-Core receipt, PARTIAL capability
set, simulator result, cross-compilation result or successful build without
execution cannot complete this task.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | M3-031 has no recursive task dependencies; current-desktop M2-004/M2-006 report pairs are directly required and M3-030 is historical diagnostic input | direct report/validation, source-inventory, SDK, log, and historical integrity checks | reachable | Legacy generic M2 indexes, global M2 statuses, and M2-006 iOS evidence are not inputs; M3-030 integrity failures are diagnostic only. |
| P002 | every desktop-applicable Core prerequisite maps to current source and tests | exact file, declaration and evidence checks | reachable | Covers the scoped projections of M3-001, M3-002, M3-006, M3-009 through M3-012, M3-016 and M3-018. |
| P003 | a required current source or declaration is missing | fail-closed Core audit | reachable error | The task cannot infer equivalence; missing historical files remain an explicit integrity diagnostic. |
| P004 | AWS-LC schema-v11 PoC executes on `windows-2025` x86_64 at the expected SHA | M0-016 result validator | reachable | Every required capability must be PASS. |
| P005 | AWS-LC schema-v11 PoC executes on `macos-15` arm64 at the expected SHA | M0-016 result validator | reachable | External signer and session resumption are mandatory. |
| P006 | result is stale, PARTIAL, SKIPPED, compile-only, wrong-platform or unknown-schema | stable validation code | reachable error | No incomplete result can be promoted to PASS. |
| P007 | desktop task dependencies use M3-031 and retain original acceptance text | exact backlog row audit | reachable | Only four desktop rows change dependencies. |
| P008 | mobile M4 dependencies and device requirements remain unchanged | exact backlog row audit | reachable | M3-031 does not unlock mobile work. |
| P009 | a report succeeds or fails while writing | same-directory atomic replacement | reachable | A reader sees one complete JSON document or the old file. |
| P010 | provider validation targets an alternate repository root | root-scoped manifest and provider-spec loading | reachable | Validation never mixes metadata from the tool's own checkout with the selected tree. |
| P011 | current resolver source, pinned SDK identity, report or retained log differs from a current-desktop report | typed current-tree, report/validation, SDK pin, source-inventory, and log digest comparison | reachable error | Native dependency drift fails closed regardless of unrelated historical inputs. |
| P012 | M2 global task status is BLOCKED while both direct current-desktop report pairs are valid | direct report-pair validation independent of task status | reachable | M3-031 consumes fresh desktop proof only and does not promote global M2 status. |
| P013 | a desktop backlog row keeps one phrase but drops another acceptance requirement | exact full acceptance-column comparison | reachable error | Dependency migration cannot weaken any pre-existing desktop criterion. |
| P014 | M3-030 status is no longer COMPLETE | historical integrity and provenance validation | reachable diagnostic | M3-030 status remains unchanged; its historical failure does not block current Core or replace direct M2 resolver proof. |
| P015 | a retained M3-030 report is missing, has the wrong identity, or differs from its indexed digest/inventory/source digest | historical integrity and provenance validation | reachable diagnostic | The direct verifier rejects the bundle; `audit-core` records HISTORICAL with STALE/FAIL, code and detail, without reusing it as qualification. |
| P016 | historical M3-030 report semantics change while identity and index digest are refreshed | historical provenance-only validation | reachable | Semantic changes do not produce or remove current-Core qualification. |
| P017 | native provider result refers to a missing, escaping or digest-mismatched license bundle | M0-016 bundle manifest and per-file validator | reachable error | Both hosted license inventories remain byte-exact. |
| P018 | current-Core receipt is fake, incomplete, skipped, failed, timed out or changes command order/argv | exact report schema and four-command receipt validation | reachable error | Exactly the provider build, architecture guard, substitution tests and installed consumer must execute and PASS. |
| P019 | revision, production source, execution input, SDK archive/tool or platform identity drifts | baseline binding recomputation | reachable error | The fixed SDK pin and installed SDK bytes are both checked. |
| P020 | one of nine retained logs is absent, duplicated, escaped, from another run or digest-mutated | typed-text digest and run-layout validation | reachable error | Eight command streams plus the installed qualification copy are required. |
| P021 | provider selection, native manifest/archive, header signature or ABI symbol set changes | live selection, header probe, archive symbol and artifact-byte checks | reachable error | No recorded PASS substitutes for current native checks. |
| P022 | installed consumer report, source inventory, HTTPS smoke or artifact changes | M7-021 report validator plus qualification/artifact digest checks | reachable error | The current installed consumer must execute; release remains NOT_QUALIFIED. |
| P023 | supplied Core audit is fabricated or stale | `audit-core` recomputation in aggregate | reachable error | Aggregate accepts only the exact current audit of the canonical receipt. |
| P024 | hosted source, artifact metadata, retained provider result or validation drifts | hosted receipt and four-file digest validation | reachable error | All four source files and both platform result/validation pairs remain bound. |

## Input-domain partitioning

| Domain | Partitions and boundaries | Cross-constraints |
|---|---|---|
| Core prerequisite | present and mapped; missing file; missing declaration; stale evidence | All nine desktop projections are mandatory; excluded global conditions are listed separately and never PASS. |
| Hosted platform | Windows x86_64; macOS arm64; Linux; simulator; cross-build | Only the two exact native desktop identities satisfy this task. |
| Provider result | PASS; PARTIAL; FAIL; BLOCKED; SKIPPED; unknown schema | PASS requires schema v11, zero PoC exit, and every capability PASS. |
| Revision | exact 40-hex SHA; stale SHA; absent SHA | Windows/macOS and current Core use one frozen candidate revision. |
| Provider | pinned AWS-LC 5.5.0; unknown; alternate; automatic fallback | Only the selected pinned provider can pass. |
| Task graph | empty M3-031 dependency list; direct evidence checks; exact desktop replacement; weakened criteria; mobile rewrite | Direct source-bound evidence checks remain independent of recursive task closure; acceptance text and mobile dependencies remain unchanged. |
| Historical M3-030 evidence | complete identity/inventory/digests; missing file; bad index digest; changed source bytes; semantically changed payload with a refreshed digest | Integrity/provenance may be HISTORICAL; no historical payload is current Core proof. |
| Current-Core commands | exact ordered four-command inventory; missing, duplicate, altered, skipped, failed, timed-out receipt | All four exact argv vectors must have PASS, exit 0 and no timeout. |
| Current-Core bindings | exact revision/source/execution/SDK/platform; production or execution drift; wrong SDK bytes or installed tools | The candidate source and fixed STS archive/install identity must match at capture and verification. |
| Current-Core logs | exactly nine UTF-8/LF text logs; missing, duplicated, escaped, cross-run or same-path byte mutation | Each log is confined, typed-digest bound and associated with the same run ID. |
| Native provider | exact selected provider/adapter/fingerprint/capabilities/ABI; invalid build manifest; header mismatch; missing symbol; archive byte drift | Header signature and full current archive-symbol checks execute during verification. |
| Installed consumer | current qualification and artifact; missing artifact; changed report, source, HTTPS smoke or artifact bytes | M7-021 report and smoke behavior are validated; report and artifact digests match actual files. |
| Hosted artifacts | exact API metadata and four source files; changed artifact/result/validation; invalid digest or expiry | Both hosted platform receipts remain bound to the same source revision and retained files. |

## State and side effects

- Core audit reads and revalidates source-bound current evidence and historical
  provenance without changing them.
- `capture-current-core` runs the four commands in fixed order and stores
  unique run-scoped logs, build output and installed consumer artifacts.
- Capture compares source, execution, SDK and platform inputs again during
  validation and refuses to publish on drift.
- A failed capture is stored separately; it cannot overwrite an existing
  canonical PASS receipt.
- Hosted runs download and build pinned provider source in runner-local output.
- This task does not update another task's status or confer release
  qualification.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | current Core receipt and direct current-desktop M2-004/M2-006 report pairs, with M3-030 historical integrity diagnostic | frozen source and pinned SDK | P001,P002,P019,P021,P022 | accept the desktop-scoped contract | audit requires current source/SDK/native/consumer proof and direct report pairs; stale M3-030 history is reported separately and never supplies qualification | architecture | P0 |
| S002 | one missing Core declaration or evidence input | candidate PASS audit | P003 | reject | stable code identifies the missing current requirement | fault-injection | P0 |
| S003 | current Windows AWS-LC result | native hosted runner | P004 | accept | schema v11, exact revision, native identity and every capability PASS | platform | P0 |
| S004 | current macOS AWS-LC result | native hosted runner | P005 | accept | exact revision, arm64 identity, external signer and session PASS | platform | P0 |
| S005 | stale, PARTIAL, SKIPPED or wrong-platform result | otherwise valid result | P006 | reject | no substitute status becomes PASS | fault-injection | P0 |
| S006 | rewritten desktop dependency rows | current backlog | P007 | accept exact migration | four dependency fields match ADR-0007 and acceptance text is retained | architecture | P0 |
| S007 | current M4 rows | current backlog | P008 | remain unchanged | mobile prerequisites and device language remain present | regression | P0 |
| S008 | report write interrupted before replacement | existing report | P009 | preserve complete old report | no partial output is published | lifecycle | P1 |
| S009 | valid result plus moved manifest under `--root` | otherwise valid provider result | P010 | reject | selected root controls manifest and provider-spec validation | fault-injection | P0 |
| S010 | current native resolver source, pinned SDK identity, report or retained log drifts from its source-bound desktop report | otherwise valid direct evidence | P011 | reject | `DEPENDENCY_EVIDENCE` identifies source, SDK pin, report or log drift | fault-injection | P0 |
| S011 | M2 global status changes from COMPLETE to BLOCKED while direct current-desktop evidence remains valid | current report pairs and retained evidence | P012 | accept direct M3 evidence without status promotion | M3 admission does not depend on global M2 status and leaves the status unchanged | regression | P0 |
| S012 | desktop acceptance row loses one frozen requirement | dependencies remain exact | P013 | reject | complete acceptance column must match the frozen contract | fault-injection | P0 |
| S013 | M3-030 status changes from COMPLETE to BLOCKED | historical evidence remains present | P014 | record historical diagnostic; continue current checks | status correction is visible and does not gate current Core | fault-injection | P0 |
| S014 | M3-030 indexed report is missing, stale or absent from inventory | task status remains COMPLETE | P015 | direct verifier rejects; audit records diagnostic | exact identity, full report inventory, index digest and source digest are checked; current proof remains independent | fault-injection | P0 |
| S015 | M3-030 semantic payload or command status changes with index digest refreshed | historical identity remains intact | P016 | return HISTORICAL only | payload is not semantically treated as current Core proof | regression | P0 |
| S016 | Windows/macOS result refers to absent, escaping or modified license bundle | result otherwise passes schema-v11 validation | P017 | reject | stable validation rejects the bundle before promotion | fault-injection | P0 |
| S017 | fake PASS object, missing command, skipped command or altered argv | otherwise valid current-Core fixture | P018 | reject | exact schema and command inventory are mandatory | fault-injection | P0 |
| S018 | production/execution source, SDK identity, or retained log bytes drift | otherwise valid current-Core fixture | P019,P020 | reject | precise source/SDK/log error; canonical receipt remains unchanged | fault-injection | P0 |
| S019 | current archive header, ABI symbol or artifact bytes change | provider build receipt otherwise valid | P021 | reject | current header and symbol checks run and archive digest is enforced | fault-injection | P0 |
| S020 | installed M7-021 source, HTTPS smoke, report or artifact drifts | current provider receipt otherwise valid | P022 | reject | actual installed report/smoke and artifact byte digest are validated | fault-injection | P0 |
| S021 | aggregate receives hand-authored Core PASS or stale audit | canonical receipt is current | P023 | reject | aggregate recomputes audit and compares the complete object | fault-injection | P0 |
| S022 | hosted source, artifact metadata, result or validation is changed | hosted receipt initially passes | P024 | reject | each of four source files, artifact, result and validation mutations are detected | fault-injection | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P002,P019,P021,P022 | current-Core fixture with source-bound direct M2 report pairs and stale M3-030 history | PASS | current receipt passes its verifier; historical diagnostic is classified; direct M2 proof is validated independently of global status | unit,task |
| T002 | S002 | P003 | remove one required declaration in a temporary tree | FAIL | `CORE_REQUIREMENT` | fault-injection |
| T003 | S003 | P004 | AWS-LC on `windows-2025` | PASS | exact revision and all required capability values PASS | native-platform |
| T004 | S004 | P005 | AWS-LC on `macos-15` arm64 | PASS | exact revision, external signer calls and cleanup count | native-platform |
| T005 | S005 | P006 | schema, revision, status and platform mutations | FAIL | stable `RAW_RESULT`, `STALE_REVISION`, `INCOMPLETE_RESULT` or `PLATFORM` code | fault-injection |
| T006 | S006 | P007 | four M3 desktop backlog rows | PASS | exact dependencies and unchanged acceptance fragments | architecture |
| T007 | S007 | P008 | M4-001 through M4-014 rows | PASS | original Core dependencies and device language remain | regression |
| T008 | S008 | P009 | atomic JSON write with replacement failure injection | PASS | old JSON remains complete and temporary path is removed | unit,lifecycle |
| T009 | S001,S003,S004,S006,S007 | P001,P002,P004,P005,P007,P008,P018,P019,P020,P021,P022,P023 | task-level gate | PASS | zero failed commands and zero skipped acceptance commands | task |
| T010 | S009 | P010 | valid result plus moved manifest under `--root` | FAIL | `PROVIDER` is derived from selected tree | fault-injection |
| T011 | S010 | P011 | mutate a current resolver source or retained native log after sealing | FAIL | `DEPENDENCY_EVIDENCE` identifies source/log digest drift | fault-injection |
| T012 | S011 | P012 | set an M2 global status row to BLOCKED while retaining valid current-desktop evidence | PASS | M3 admission accepts the independent direct proof and does not modify the M2 status | regression |
| T013 | S012 | P013 | retain only the first M3-014 acceptance phrase | FAIL | `TASK_GRAPH` rejects the weakened full column | fault-injection |
| T014 | S013 | P014 | mutate M3-030 status row to BLOCKED while retaining evidence | HISTORICAL diagnostic | `audit-core` records the historical integrity/status error and continues current proof checks | fault-injection |
| T015 | S014 | P015 | remove an indexed report or mutate report/index/source digests | direct verifier FAIL; audit HISTORICAL | complete historical identity, inventory and digest integrity are checked without blocking current qualification | fault-injection |
| T016 | S015 | P016 | change synthetic historical report semantics while refreshing its digest | HISTORICAL | synthetic fixture proves integrity-only classification; it contains no native qualification claim | regression |
| T017 | S016 | P017 | mutate license digest/path and omit retained manifest | FAIL | `LICENSE_BUNDLE` or raw-result path guard rejects the result | fault-injection |
| T018 | S017 | P018 | fake PASS object; remove command; alter argv or status to SKIPPED | FAIL | `CURRENT_CORE_SCHEMA` or `CURRENT_CORE_COMMANDS`; failed/timeout receipts cannot pass | fault-injection |
| T019 | S018 | P019,P020 | mutate production/execution digest, SDK identity, log bytes/path or run ID | FAIL | `STALE_SOURCE`, `SDK_IDENTITY` or `CURRENT_CORE_LOGS` | fault-injection |
| T020 | S019 | P021 | header failure, missing archive symbol and same-path archive byte mutation | FAIL | current header and ABI symbol checks execute; archive digest cannot be substituted | fault-injection |
| T021 | S020 | P022 | mutate installed smoke status, qualification or artifact bytes | FAIL | `CURRENT_CORE_CONSUMER` or `STALE_SOURCE` | fault-injection |
| T022 | S021 | P023 | forged PASS Core object and canonical source-bound audit | FAIL/PASS | aggregate rejects fake object and accepts only the exact recomputed audit | fault-injection |
| T023 | S022 | P024 | mutate each hosted source, artifact metadata, result and validation independently | FAIL | hosted receipt rejects all eight drift classes | fault-injection |

## Excluded gates

M3-031 does not run the one-hour SSE profile, the 86,400-second soak, mobile
device gates, HTTP performance gates or release artifact qualification. Those
results cannot be inferred from the desktop provider PoCs or the installed
development consumer.
