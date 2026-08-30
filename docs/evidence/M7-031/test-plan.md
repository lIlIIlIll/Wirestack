# M7-031 test plan

## Semantics

M7-031 evaluates the Linux x86_64 glibc release profile against all 22 items in
PRD section 26. The candidate report is an evidence index. It does not rebuild
the artifact or rerun a long profile.

Every Linux-applicable item must be `PASS`. A criterion that has no Linux cell
must be `NOT_APPLICABLE_TO_LINUX_PROFILE`. `SKIPPED`, a missing report, a stale
digest, an open High or Critical finding, or a mismatched artifact identity
blocks the candidate.

The report binds the M7-021 artifact, the M7-022 soak, the M7-025 supply-chain
documents, the M7-029 review, the M7-030 hosted attestations, and the M7-032
public API inventory. It also records the current production-source digest and
the repository commit that generated the report. Changes to release-critical
source or evidence make the prior report stale.

## Control-flow path matrix

| Path ID | Conditions and values | Check | Reachability | Required result |
|---|---|---|---|---|
| P001 | PRD section 26 contains exactly 22 numbered criteria | Inventory | Reachable | Continue |
| P002 | A criterion is missing, duplicated, reordered, or has an unknown status | Inventory | Reachable error | FAIL |
| P003 | M7-019 through M7-030 and M7-032 are COMPLETE and have their required reports | Dependency evidence | Reachable | Continue |
| P004 | A dependency report is absent, malformed, non-PASS, timed out, or records `skippedAsPass=true` | Dependency evidence | Reachable error | FAIL |
| P005 | M7-021, M7-022, M7-025, and M7-030 bind one artifact SHA-256 | Artifact identity | Reachable | Continue |
| P006 | Any artifact, payload, SBOM, provider-manifest, build-fingerprint, or attested subject digest differs | Artifact identity | Reachable error | FAIL |
| P007 | Current production-source digest matches M7-021 qualification | Source freshness | Reachable | Continue |
| P008 | A production source, manifest, lockfile, native input, or release build input changes | Source freshness | Reachable error | STALE and FAIL |
| P009 | M7-022 is a formal uninterrupted run of at least 86,400 seconds for the bound artifact | Long evidence reuse | Reachable | PASS without rerun |
| P010 | Soak is preflight-only, shorter than 86,400 seconds, interrupted, or bound to another artifact | Long evidence reuse | Reachable error | FAIL |
| P011 | M7-029 has no unresolved High or Critical finding | Security review | Reachable | Continue |
| P012 | A High or Critical finding is Open, AcceptedRisk, missing a status, or absent from validation | Security review | Reachable error | FAIL |
| P013 | M7-030 hosted report verifies artifact, SBOM, and release-manifest subjects | Signing | Reachable | Continue |
| P014 | Hosted report is missing a subject, uses another digest, or is only a local rehearsal | Signing | Reachable error | FAIL |
| P015 | M7-032 public inventory has zero internal aliases and uses the Linux pre-1.0 profile | Public API | Reachable | Continue |
| P016 | Public API report is historical M7-026 evidence, exposes an internal alias, or claims compatibility | Public API | Reachable error | FAIL |
| P017 | All 21 Linux-applicable criteria pass and REL-03 is not applicable to Linux | Decision | Reachable | `GO_FOR_LINUX_STABLE_RELEASE` |
| P018 | Any Linux criterion fails, lacks current evidence, or uses `SKIPPED` as PASS | Decision | Reachable error | `NO_GO` and nonzero exit |
| P019 | Candidate output replaces the prior file atomically | Persistence | Reachable | Complete canonical JSON |
| P020 | Atomic replacement fails after a valid prior report exists | Persistence | Reachable error | Prior bytes remain unchanged |

## Input and state domains

| Domain | Partitions | Required behavior |
|---|---|---|
| Criterion status | `PASS`; `FAIL`; `NOT_APPLICABLE_TO_LINUX_PROFILE`; `SKIPPED`; unknown | Only the first three values are valid. Linux completion requires 21 PASS and one not applicable result. |
| Dependency report | current PASS; missing; malformed; stale; timeout; skipped | Only a current executed PASS can support a release criterion. |
| Digest | exact lowercase SHA-256; short; uppercase; non-hex; mismatched | Only an exact 64-character lowercase digest passes. |
| Artifact | M7-021 artifact; M7-022 artifact; M7-025 bundle; M7-030 subject | All records must identify the same artifact and payload. |
| Security finding | Fixed; Open; AcceptedRisk; unknown | Any unresolved High or Critical finding blocks the release. |
| Platform | Linux x86_64 glibc; Linux musl; non-Linux | Only Linux x86_64 glibc is evaluated. Other platforms are not reported as PASS. |
| Output | absent; valid prior report; replace failure | Success writes one canonical file. Failure preserves prior bytes. |

## State and side effects

- The tool reads retained reports and current repository source. It does not
  build the Cangjie SDK, runtime, std, or stdx.
- The tool does not run the 86,400-second soak or the one-hour SSE profile.
- The tool writes only M7-031 evidence and uses atomic replacement.
- A failed validation never updates planning status.
- A PASS report records non-Linux and musl exclusions as limitations, not as
  completed platform cells.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Current M7-019 through M7-030 and M7-032 evidence | No report | P001,P003,P005,P007,P009,P011,P013,P015,P017,P019 | Generate candidate report | 22 criteria, 21 PASS, one Linux N/A, exact artifact identity and `GO_FOR_LINUX_STABLE_RELEASE` | normal,release | P0 |
| S002 | Missing or non-PASS dependency report | No report | P004,P018 | FAIL | Stable error identifies the task and no report is written | negative,evidence | P0 |
| S003 | Duplicate, missing, unknown, or `SKIPPED` criterion | No report | P002,P018 | FAIL | Inventory never promotes incomplete work | negative,parser | P0 |
| S004 | One-byte mutation of an artifact or supply-chain digest | Valid fixture set | P006,P018 | FAIL | Mismatched identity is named | fault-injection,supply-chain | P0 |
| S005 | Current production source differs from M7-021 qualification | Valid retained report | P008,P018 | STALE and FAIL | Old artifact evidence is not reused | fault-injection,evidence | P0 |
| S006 | Soak is short, preflight-only, interrupted, or bound to another artifact | Valid fixture set | P010,P018 | FAIL | Long evidence cannot be synthesized | fault-injection,reliability | P0 |
| S007 | Open High or Critical finding | Valid fixture set | P012,P018 | FAIL | Candidate is `NO_GO` | fault-injection,security | P0 |
| S008 | Hosted report omits or changes one subject | Valid local rehearsal | P014,P018 | FAIL | Local rehearsal does not replace hosted evidence | fault-injection,signing | P0 |
| S009 | Public API report exposes one internal alias | Valid fixture set | P016,P018 | FAIL | Historical M7-026 inventory is not accepted | fault-injection,API | P0 |
| S010 | Atomic replace raises an error | Valid prior report | P020 | FAIL | Prior bytes remain byte-identical | fault-injection,persistence | P1 |
| S011 | Linux musl or a non-Linux cell is presented as PASS | Valid Linux evidence | P002,P018 | FAIL | Report retains the Linux glibc boundary | negative,platform | P0 |
| S012 | Current report is regenerated with unchanged inputs | Existing valid report | P001,P019 | PASS | Canonical semantic content and evidence digests are stable | regression,determinism | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001,S003,S011 | P001,P002,P017,P018 | Current and malformed criterion inventories | PASS or FAIL | Exact IDs, statuses, counts, and Linux profile | unit,parser |
| T002 | S002 | P003,P004 | Missing, malformed, skipped, and non-PASS dependency reports | FAIL | Stable task-specific error | fault-injection,evidence |
| T003 | S004 | P005,P006 | Mutated artifact, payload, SBOM, provider, fingerprint, and hosted subject digests | FAIL | Every identity mismatch is rejected | fault-injection,supply-chain |
| T004 | S005 | P007,P008 | One production source and one qualification input mutation | STALE and FAIL | Changed path class is reported | fault-injection,evidence |
| T005 | S006 | P009,P010 | Full and shortened soak fixtures | PASS or FAIL | Formal duration, uninterrupted state, and exact artifact checked | fault-injection,reliability |
| T006 | S007 | P011,P012 | Fixed and open High or Critical findings | PASS or FAIL | No unresolved release blocker | fault-injection,security |
| T007 | S008 | P013,P014 | Three-subject hosted report and missing or changed subjects | PASS or FAIL | Exact subject names and digests | fault-injection,signing |
| T008 | S009 | P015,P016 | Current M7-032 and historical or leaking API inventories | PASS or FAIL | Zero internal aliases and pre-1.0 policy | fault-injection,API |
| T009 | S010 | P019,P020 | Injected atomic replace failure | FAIL | Prior bytes preserved | fault-injection,persistence |
| T010 | S001,S012 | P017,P019 | End-to-end repository evidence | PASS | 22-row report, exact release identity, known limitations, deterministic JSON | integration,release |

## Coverage and gap review

The suite validates the report generator and every fail-closed release
decision. It reuses the completed M7-022 and M6-023 long evidence by exact
digest. It does not rerun either profile.

M7-031 closes only the Linux x86_64 glibc candidate. The six-platform M7-001
through M7-017 tasks, Linux musl, and a public GitHub Release remain outside
this task.
