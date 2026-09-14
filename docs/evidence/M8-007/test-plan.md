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
| P010 | Fixed request Content-Length at or above configured limit | Admission before body read or handler dispatch | Reachable | Exact boundary remains accepted |
| P011 | Completed nonreusable HTTPS response with silent TLS peer | Completion, cancellation unlink, and transport disposal | Reachable | Automatic disposal cannot start an unbounded peer-close wait |
| P012 | Pool closes after new H2 stream admission but before publication | Reservation, registration, stream and connection cleanup | Reachable race | No request executor owns the rejected stream |
| P013 | Bounded TLS close while background I/O holds a pump lock | Deadline/cancellation admission and terminal cleanup | Reachable race | Context checks must precede or interrupt waiting |
| P014 | Live versus released soak resource owners | Actual owner observations and terminal joins | Reachable | Literal zero values are not resource evidence |
| P015 | Already-cancelled close token invokes a throwing abort callback | Registration failure enters terminal cleanup | Reachable error path | Close admission must not retain the TLS engine |
| P016 | Oversized member, sparse expansion, metadata, or header count | Header and decoded-byte budgets precede materialization; logical sizes precede extraction | Reachable error paths | An accepted digest does not waive resource limits |
| P017 | Protected signing ref and explicit owner approval | Tag rules, environment reviewer, exact deployment policy, and approved SHA | Hosted release path | No non-administrator credential is available for a denial probe |
| P018 | Hosted source matches or differs from independently approved source | Approval record and exact signer/source digest comparison | Reachable error path | Hosted metadata cannot choose the trusted revision |
| P019 | Frozen, signing, and final task contracts differ | Complete committed task comparison permits added source paths only | Reachable error path | Commands and required reports cannot be weakened |
| P020 | Generated proof exists locally but is absent from the seal inventory | Nine raw formal/signing inputs must be declared | Reachable error path | Workflow retention is not repository evidence |
| P021 | Successful or failed compiler emits large or invalid-UTF-8 diagnostics | File-backed capture and encoded excerpt limit | Reachable | Complete decoded raw logs remain available |
| P022 | Cancellation registry fills between samples | Reclamation, bounded admission wait, and live-reference preservation | Reachable | Sampling cannot be the only capacity control |
| P023 | Transport observation table is full before or during connect | Admission check and cleanup of a rejected new transport | Reachable | Closed but strongly retained wrappers cannot be evicted |

## Input domains and state

Archive members include regular files, directories, duplicate names, traversal names, links, and missing or extra inventory entries. Native inputs include each required component, omitted provenance, and same-size archive mutation. API and documentation inputs include unchanged content, changed content, and planning-only changes.

Archive resource boundaries include an 8 MiB member and one extra byte, aggregate payload above 64 MiB, decoded headers and padding, oversized PAX metadata, and excessive member headers. Cumulative PAX fields cover 128 and 129. GNU sparse formats cover legacy, 0.0, 0.1, and 1.0 encodings.

Signing inputs include missing approval, alternative reviewers, unprotected refs, a different hosted source SHA, and the exact approved signing tag. Policy capture precedes the soak; actual source approval follows formal completion.

The soak duration domain includes preflights below 86,400 seconds and the exact formal duration. Cancellation latency must stay within the existing 50,000,000-nanosecond bound. Resource trends require the maintained sample minimums. The process must finish, join admitted tasks, and release its application-owned resources.

Weak-reference liveness depends on GC reclamation, so sampled weak transport and cancellation-sentinel counts use bounded-growth and monotonicity checks. Active leases, responses, and application tasks must be zero at idle checkpoints. All observed active and weak owners must be zero at terminal cleanup.

Compiler diagnostics cover success and failure above 2 MiB, plus invalid UTF-8 whose replacement characters expand the encoded excerpt. Cancellation controls cover 4,096 claims without sampling and 1,024 strongly retained sentinels. Transport controls hold 1,024 closed native wrappers strongly and attempt one extra connection. Capacity rejection must not discard live references; the real preflight uses 60-second application sampling.

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
| S011 | Content-Length equal to limit or one byte above it | Head received; body withheld | P010 | Accept boundary; reject oversized request before consumption | Assert exact body at boundary and structured rejection above it | boundary,regression | P0 |
| S012 | Complete Connection: close HTTPS response; peer withholds close_notify | Request owns body and pool lease | P011 | Complete or cancel without a new unbounded graceful wait | Assert consumer operation terminates and disposal ownership is released | regression | P0 |
| S013 | Pool close interleaved after new stream admission | Created connection not yet published | P012 | Reject acquisition and release all unpublished ownership | Assert bounded acquisition failure and zero retained stream owners/reservations | regression | P0 |
| S014 | Deadline expiry or cancellation during close behind active I/O | Another operation holds the pump admission resource | P013 | Honor the close context and perform terminal cleanup | Assert close terminates, old I/O wakes, and engine cleanup completes once | boundary,regression | P0 |
| S015 | Retained terminal owner, growing weak-owner series, or old literal sample schema | Soak sampling or terminal validation | P014 | Refuse unsupported ownership PASS | Assert live observations, bounded trends, and rejection of invalid terminal or schema evidence | regression | P0 |
| S016 | Already-cancelled token and throwing transport abort | TLS connection handshaken; close not yet registered | P015 | Propagate the failure and release the engine | Assert terminal connection, one transport disposal, and exactly one engine release | error,regression | P0 |
| S017 | Archive exceeds a resource budget | Empty extraction destination | P002,P016 | Reject before publishing an installation | Accept the exact member boundary; reject excess member bytes, sparse expansion, decoded bytes, metadata, and header count | boundary,error,regression | P0 |
| S018 | Missing or conflicting signing authority | Pre-soak policy with no approved SHA | P008,P017 | Require protected refs and sole owner approval | Reject alternative reviewers and stale policy inputs; bind the exact source and tag before signing | normal,error | P0 |
| S019 | Hosted report selects a different source | Independent approval names another SHA | P008,P018 | Reject the hosted source | Even a successful verification result for the wrong source cannot satisfy approval | error,regression | P0 |
| S020 | Missing archival files, removed inputs, or changed gate fields | A real frozen or signing task exists | P019,P020 | Reject incomplete publication | Require raw formal/signing inputs and preserve every prior task obligation while accepting added proof paths | error,regression | P0 |
| S021 | Large successful, failed, or invalid-UTF-8 compiler output | Build capture starts | P021 | Bound report memory without losing decoded raw diagnostics | Excerpt is at most 16 KiB; terminal marker and complete decoded capture remain; failure stays a failure | boundary,regression | P0 |
| S022 | More claims than registry capacity between samples | No sample-triggered collection | P022 | Keep at most 1,024 slots and reject excess live ownership | Observe peak slots during 4,096 claims; retain all 1,024 live sentinels when extra admission fails | boundary,regression | P0 |
| S023 | Full transport observation table | 1,024 closed wrappers remain strongly reachable | P023 | Reject an extra transport without evicting an existing reference | Observe rejection and all 1,024 retained wrappers; complete fixture shutdown | boundary,regression | P0 |

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
| T011 | S011 | P010 | HTTP1 server-reader boundary and oversized-head cases | Pre-fix rejection test fails; corrected reader passes | Assert exact accepted body and rejection before reading oversized body | boundary |
| T012 | S012 | P011 | HTTP1 completion regression with withheld graceful shutdown | Operation does not outlive its completion/cancellation budget | Assert bounded consumer completion and released ownership | strengthened |
| T013 | S013 | P012 | Gated H2 creation-versus-pool-close race | Unpublished connection and stream are disposed | Assert acquisition termination and empty active/owned stream state | strengthened |
| T014 | S014 | P013 | Active TLS I/O plus bounded or cancelled close | Both terminal cleanup and old I/O finish | Assert context outcome and safe teardown under controlled ordering | strengthened |
| T015 | S015 | P014 | Ownership-observation negative controls and real preflight | No literal schema, growing weak-owner series, or retained terminal owners pass | Assert observed owner state, terminal joins, and strict schema rejection | strengthened |
| T016 | S016 | P015 | `cancelledCloseReleasesEngineWhenImmediateAbortCallbackThrows` | Intermediate implementation fails; corrected TLS suite passes | Assert registration failure cannot abandon admitted cleanup; retain negative source and raw logs | strengthened |
| T017 | S017 | P002,P016 | `archive-review-controls.py.txt` against `14a9925` and corrected source | Seven baseline failures and seven corrected passes | Reparse exact raw test outcomes and bind driver, source, tests, commands, and digests | strengthened |
| T018 | S018 | P008,P017 | Policy capture, authorization regressions, and actual post-soak owner approval | Only the approved signing source proceeds | Active API-recorded policy, sole reviewer, immutable signing tags, and exact environment/source binding | strengthened,platform |
| T019 | S019 | P008,P018 | `hosted-source-controls.py.txt` with successful cryptographic verification stubbed | Baseline fails; corrected source rejects substitution | Bind the exact negative/positive unit outcome to source, test, driver, and raw logs; real signatures remain T009 | boundary |
| T020 | S019,S020 | P018,P019,P020 | Publication controls and additive-proof acceptance regression | Baseline accepts omissions or weakened contracts; corrected source rejects them | Bind six negative/positive control outcomes and preserve a valid additive transition | strengthened |
| T021 | S021 | P021 | `build-output-controls.py.txt` against `8a603905` and corrected source | Three baseline failures and three corrected passes | Bind exact test outcomes, full decoded logs, source, driver, and the encoded excerpt limit | strengthened |
| T022 | S022 | P022 | `owner-registry-probe.py.txt` in stale and live modes | Baseline exceeds capacity; correction bounds or rejects admission | Canonically derive the consumer; keep intended roots live; verify raw peak-slot and retained-owner observations | strengthened,platform |
| T023 | S023 | P023 | Native transport mode and 600-second preflight with 60-second application sampling | Full-table rejection without live-reference eviction; real workload meets unchanged gates | Bind native execution and raw observations; require terminal cleanup and existing trend and latency limits | strengthened,platform |

## Feedback and gaps

The baseline and fixed control reports retain the SBOM and resolver-archive regressions. The integrated release tooling log records the observed Python regression results. Current parser-campaign results are recorded in `linux_x86_64/fuzz-report.json`; the final wrapper binds the campaign to the final qualification.

The 600-second diagnostic is a preflight. It does not close T007. Hosted signatures and independent review require their own executed evidence. No line, branch, or mutation-adequacy percentage is claimed by this plan. Other platforms and compatibility with a previous binary release remain outside scope.

The interrupted formal run on `14a9925` remains `INCOMPLETE` and does not close T007. Its frozen inputs and partial workload output are retained under `reproductions/formal-soak-14a9925`.

The bounded-owner preflight passed with 60-second application sampling, 5,909 cycles, and zero terminal owners; T007 remains open. The transport control exercises full-table rejection before connection. The concurrent post-connect admission-abort branch has no controlled race reproduction.
