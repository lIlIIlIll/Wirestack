# M8-007 release test plan

This plan covers the final Linux x86_64 glibc release qualification required by the implementation backlog. Execution results belong in the linked reports. A planned test is not a passing result.

## Semantics summary

The release tools consume the current source, pinned native archives, API baseline, and qualification metadata. They produce an installed package and evidence with explicit text or artifact digest domains. The final gate also consumes an independent review, a genuine 86,400-second installed-consumer soak, and authenticated GitHub attestations.

Failures reject qualification. Package extraction must not publish unsafe members. A changed artifact, source input, native archive, review target, or signing identity must not inherit an earlier passing result. The original development workspace is outside the publication workspace and must remain untouched.

## Control-flow paths

| Path ID | Conditions and values | Runtime/compiler checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Current native inputs and deterministic package payload | Native build, archive inventory, two byte comparisons | Reachable on Linux x86_64 glibc | Reused cache metadata alone is insufficient |
| P002 | Malformed archive or mismatched declared member | Path, type, duplicate, size, digest, and inventory checks | Reachable error paths | Extraction cannot escape its destination |
| P003 | Current declarations or changed packaged documentation | API inventory and qualification input digests | Reachable | Planning-only state is not packaged input |
| P004 | Complete schema-2 supply chain or altered native dependency | SPDX and archive provenance checks | Reachable | Includes HTTP files and Public Suffix List |
| P005 | Clean installed CJPM dependency | Build, HTTPS behavior, runtime metadata, readelf, and ldd | Native Linux path | No checkout package dependency |
| P006 | Short preflight, formal completion, timeout, or input drift | Duration, workload, resource trends, joins, and identities | Native Linux path | Short runs cannot become formal PASS |
| P007 | Current independent review or historical/stale review | Package digest, reviewer declaration, methods, scope, and findings | Reachable | Process isolation is not external human independence |
| P008 | Correct signatures or changed subject, source, or workflow | GitHub attestation verification and signed qualification inputs | Hosted signing path | Three authenticated subjects are required |
| P009 | Real committed candidate or uncommitted/changed input | Commit lookup and canonical blob comparison | Reachable | The exact formal command is checked against the commit |

## Input domains and state

Archive members include regular files, directories, duplicate names, traversal names, links, and missing or extra inventory entries. Native inputs include each required component, omitted provenance, and same-size archive mutation. API and documentation inputs include unchanged content, changed content, and planning-only changes.

The soak duration domain includes preflights below 86,400 seconds and the exact formal duration. Cancellation latency must stay within the existing 50,000,000-nanosecond bound. Resource trends require the maintained sample minimums. The process must finish, join admitted tasks, and release its application-owned resources.

The formal run owns its private candidate copies, installed consumer, native process group, logs, and resource sampler. Readiness is observed after a completed workload cycle. A second invocation cannot replace an active run. A failed or interrupted run retains diagnostic evidence and cannot be sealed as PASS.

## Semantics

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | Current native source and package inputs | Isolated publication checkout | P001,P005 | Build and install the exact candidate | Native bytes match build evidence; two archives are identical; installed HTTPS succeeds | normal,platform | P0 |
| S002 | Unsafe or inconsistent archive | Empty extraction destination | P002 | Reject the archive | Failure occurs without escaped files or accepted undeclared payload | boundary,error | P0 |
| S003 | Changed README, API declaration, or planning state | Existing qualification | P003 | Reject packaged input drift; allow unrelated planning state changes | API mismatch and packaged README drift fail; planning-only change does not invalidate package inputs | regression | P0 |
| S004 | Schema-2 artifact with PSL and native components | Fresh qualification | P004 | Produce a self-validating SBOM and license inventory | All component and license hashes match the artifact; resolver mutation fails | normal,regression | P0 |
| S005 | Current parser campaign | Qualified native cache | P002,P004 | Run all maintained mutation targets | Every target has a matching PASS marker, seed, and sufficient iterations; inputs remain unchanged | fuzz | P0 |
| S006 | Preflight or incomplete long run | Candidate not formally qualified | P006 | Retain incomplete or failed status | No short, interrupted, drifted, or failed run satisfies the formal validator | boundary,error | P0 |
| S007 | Exact 86,400-second installed candidate | Frozen committed inputs | P006,P009 | Complete the formal gate | Parent and child duration, workload assertions, cancellation latency, resource trends, and terminal ownership pass | normal,platform | P0 |
| S008 | Current or stale independent review | Validated current review package | P007 | Accept only the current declared review | Package target matches; required scope and methods exist; unresolved blocking findings reject acceptance | error,normal | P0 |
| S009 | Signed subjects or modified qualification | Completed local gates | P008 | Authenticate the artifact, SBOM, and qualified manifest | Exact repository, workflow, source digest, subject bytes, and signatures verify | normal,error | P0 |
| S010 | Missing candidate commit or changed committed input | Formal run admission | P009 | Reject false source provenance | Each execution input matches its committed blob; the formal command matches the committed task definition | error,regression | P0 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001,P005 | `prepare` and the fresh native rebuild driver | Qualified installed package | Exact archive digests, native inventory, HTTPS behavior, and no system OpenSSL dependency | minimal |
| T002 | S002 | P002 | Release archive regression suite | Reject malicious members and mismatches | No destination escape; malformed inventory fails | boundary |
| T003 | S003 | P003 | Qualification drift and API freeze regressions | Reject stale packaged inputs | README and declaration changes fail; planning-only mutation remains valid | boundary |
| T004 | S004 | P004 | Supply-chain regressions and `verify-core` | Self-validation succeeds; tampering fails | Schema-2 PSL representation, native digests, license bytes, and SPDX dependencies agree | minimal |
| T005 | S005 | P002,P004 | `fuzz` | Current campaign passes | Ten targets, validated markers, frozen source and native inputs | strengthened |
| T006 | S006 | P006 | Soak regression suite and retained preflights | No false formal PASS | Duration, drift, duplicate invocation, resource bounds, and cleanup decisions reject invalid evidence | boundary |
| T007 | S007,S010 | P006,P009 | `run-soak-gate --revision` with a real committed candidate | Actual 86,400-second completion | Observed readiness, complete command logs, parent and child duration, resource trends, and input identity checks | minimal,platform |
| T008 | S008 | P007 | Fresh process-isolated review and review validators | Current source review accepted | Actual reviewer-authored report, exact package binding, required methods and scope | strengthened |
| T009 | S009 | P008 | Hosted signing and local signature verification | Three authenticated subjects | Modified qualification invalidates the signed manifest; wrong workflow or source digest fails | minimal,boundary |
| T010 | S010 | P009 | Frozen-candidate verification | Reject missing or changed committed inputs | Candidate lookup, source blob digests, and formal command equality | boundary |

## Feedback and gaps

The baseline and fixed control reports retain the SBOM and resolver-archive regressions. The integrated release tooling log records the observed Python regression results. Current parser-campaign results are recorded in `linux_x86_64/fuzz-report.json`; the final wrapper binds the campaign to the final qualification.

The 600-second diagnostic is a preflight. It does not close T007. Hosted signatures and independent review require their own executed evidence. No line, branch, or mutation-adequacy percentage is claimed by this plan. Other platforms and compatibility with a previous binary release remain outside scope.
