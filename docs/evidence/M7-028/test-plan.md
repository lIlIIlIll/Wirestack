# M7-028 test plan

## Semantics

M7-028 packages the existing Linux security evidence for an independent
reviewer. It does not perform the independent review and does not refresh a
release artifact. Every document and evidence entry is digest-bound. Evidence
made stale by M7-032 remains visible as stale and cannot satisfy a current PASS
claim. The historical M7-026 API baseline is non-gating because Wirestack does
not promise pre-1.0 source, API, ABI, or semantic compatibility.

The package must contain no private keys, credentials, authorization values,
cookies, session secrets, traffic secrets, or captured request bodies. It may
name the prohibited data classes and point to synthetic test fixtures.

## Control-flow path matrix

| Path ID | Conditions and values | Check | Reachability | Required result |
|---|---|---|---|---|
| P001 | All required review topics and documents exist | Schema and inventory validation | Reachable | PASS |
| P002 | Referenced document or evidence digest matches | SHA-256 validation | Reachable | PASS |
| P003 | Referenced file is missing or digest changed | SHA-256 validation | Reachable error | FAIL |
| P004 | Relative path escapes the repository | Safe-path validation | Reachable error | FAIL |
| P005 | Schema version or field is unknown | Strict schema validation | Reachable error | FAIL |
| P006 | Current evidence has PASS acceptance state | Status validation | Reachable | PASS |
| P007 | Stale or skipped evidence is labelled PASS | Status validation | Reachable error | FAIL |
| P008 | Post-M7-032 evidence is honestly labelled stale | Status validation | Reachable | PASS with non-gating stale entry |
| P009 | Package contains secret-like material or sensitive request data | Content scan | Reachable error | FAIL |
| P010 | Report replacement succeeds | Atomic report writer | Reachable | Complete JSON replaces destination |
| P011 | Report replacement fails | Fault-injected atomic writer | Reachable error | Previous report remains intact |
| P012 | Compatibility baseline is used as a release gate | Policy validation | Reachable error | FAIL |

## Input and state domains

| Domain | Partitions | Required behavior |
|---|---|---|
| Evidence state | current PASS; historical; stale; SKIPPED; missing | Only current PASS satisfies a current claim; historical/stale remain explicit. |
| Path | repository file; missing file; absolute path; `..` escape | Only existing repository files are accepted. |
| Schema | version 1; unknown version; unknown key; missing key | Only the exact version 1 contract is accepted. |
| Sensitive content | ordinary prose; private-key block; credential header; cookie; request body capture | Sensitive values fail closed without printing their contents. |
| Compatibility | current inventory; historical M7-026 baseline | Current inventory is descriptive; M7-026 cannot gate pre-1.0 release. |
| Platform | Linux x86_64 glibc; musl; other OS/CPU | The package may qualify only Linux x86_64 glibc. |

## State and side effects

- Validation reads only repository files and emits bounded diagnostics.
- The report is written through a same-directory temporary file, `fsync`, and
  atomic replacement. A failed replacement removes the temporary file and
  preserves the prior report.
- No network, SDK build, one-hour profile, or 24-hour soak is run.
- The package records evidence limitations instead of converting unavailable,
  stale, or skipped work into PASS.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Complete review package | Required source evidence present | P001,P002,P006,P008,P012 | Package validates | All topics present; hashes match; compatibility is non-gating | normal | P0 |
| S002 | Missing or modified referenced file | Valid package copied to fixture | P003 | Validation fails | Stable missing/digest code without traceback control flow | negative | P0 |
| S003 | Escaping path | Valid package copied to fixture | P004 | Validation fails | Stable path-escape code | security | P0 |
| S004 | Unknown schema or key | Valid package copied to fixture | P005 | Validation fails | Strict schema rejection | negative | P0 |
| S005 | SKIPPED or stale evidence marked PASS | Valid package copied to fixture | P007 | Validation fails | No unavailable result satisfies a current claim | evidence | P0 |
| S006 | Honest stale release evidence | M7-032 source ownership change recorded | P008 | Validation succeeds | Stale items are visible and non-gating for M7-028 | evidence | P0 |
| S007 | Private key or credential value injected | Valid document copied to fixture | P009 | Validation fails | Diagnostic names only path and category | security | P0 |
| S008 | Successful report write | Destination absent or valid | P010 | Complete report appears | JSON parses and status is PASS | persistence | P1 |
| S009 | Injected atomic replace failure | Existing report present | P011 | Validation reports failure | Existing bytes unchanged; temporary file removed | fault-injection | P1 |
| S010 | Historical compatibility baseline marked gating | Valid package copied to fixture | P012 | Validation fails | M7-026 remains historical and non-gating | policy | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S006 | P001,P002,P006,P008,P012 | Checked-in package | PASS | Required topics, honest states, matching digests, no compatibility gate | static |
| T002 | S002 | P003 | Missing file and mutated bytes | FAIL | Stable missing and digest-mismatch codes | fault-injection |
| T003 | S003 | P004 | `../` and absolute paths | FAIL | Repository boundary enforced | fault-injection,security |
| T004 | S004 | P005 | Unknown schema and field | FAIL | Strict contract enforced | fault-injection |
| T005 | S005 | P007 | SKIPPED/stale entry labelled current PASS | FAIL | No false PASS | fault-injection,evidence |
| T006 | S007 | P009 | Synthetic private key, authorization and cookie values | FAIL | Sensitive category reported; value omitted | fault-injection,security |
| T007 | S008,S009 | P010,P011 | Normal and failing atomic replacement | PASS/FAIL | Complete write or preserved previous report | fault-injection,persistence |
| T008 | S010 | P012 | M7-026 entry changed to gating | FAIL | Compatibility remains non-gating | fault-injection,policy |

## Coverage and gap review

The tests cover the package contract and its failure modes, not the security of
the product itself. M7-029 owns independent review findings and closure. The
final artifact rebuild, refreshed performance/install/SBOM gates, one-hour SSE
profile, and 86,400-second release soak remain deliberately unrun.
