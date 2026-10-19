# M12-004 — dependency upgrade and rollback rehearsal

**Status: BLOCKED.** The isolated AWS-LC 5.11.0 candidate is not qualified for release. The accepted production pin remains 5.5.0. Only explicitly selected STS 1.1.3 is executed; historical alpha qualification metadata is read only when authenticating the original unchanged rollback archive.

## Exact artifacts and scope

| Role | SHA-256 | Meaning |
| --- | --- | --- |
| Final upgrade candidate | bb12abafb87ffe60b3e3adbdf4c1ac6ea7f8da47a7a5ad8a2df58b9e8981556d | Fresh 5.11.0 static provider build and installed consumer; non-production only |
| Performance baseline | e430f08ff8596b1c43c1d1090b5c42d721abac3c03505656b2aea107ee7a079f | Exact unchanged M12-001 development archive, not the original signed rollback release |
| Original rollback release | 5896572753484b3f64903b2b4ccc4f0f471ddab33ef034f5c3b1bb1c3d509669 | Retrieved unchanged public archive; original signatures and source acceptance authenticated |

Selected upstream commit: `fa9bc8d6f7cfb2cf849b247fb06bbbfc41ecc9d6`; tree: `e9d52ead35793426b465d4ec694e34d4ee9a6d5e`. Native build fingerprint: `853f00dafbe98960b18bf973f48037976e31e3811d3405b58bac393a1a91539c`. The source-content identity is `ece6d5e872aaf5210aaabc32b16788f6e31d6afe5ecc74b7d514827bf5c906bb`. It hashes commit/LF/tree/LF, not archive bytes. Official release metadata and public tag resolution were checked; cryptographic signed-tag verification is not established.

The candidate includes the same 164 production Cangjie source inputs and selected native archives. Compiler/runtime/import qualification is STS 1.1.3 only. Candidate runtime version and source identity now derive from the selected upstream build rather than hardcoded 5.5.0 constants; ABI-v1 signatures are unchanged. Static dependency upgrades still require archive rebuilding and consumer recompilation/relinking.

Publication note: the candidate archive `upgrade/candidate.tar.gz` and parent baseline archive are retained locally, not included in public source PRs, because provider debug data embeds private machine paths. Their original hashes and historical reports remain unchanged. Published source commits do not retroactively qualify those captures or grant production signing.
## Acceptance evidence

| Criterion | Observed result | Evidence |
| --- | --- | --- |
| Workspace safety and dependency readiness | Recorded before editing; M9-001 was COMPLETE; unrelated dirty work preserved | [Workspace](workspace.json) |
| Provider/resolver/filesystem/PSL/gzip inventory | PASS for bounded inventory and executed native probes, not security clearance | [Final candidate inventory](inventory/candidate/inventory.json), [pre-upgrade snapshot](inventory/current/inventory.json) |
| Trusted real upstream upgrade and native identity | Actual 5.11.0 rebuild PASS; failing-before old runtime identity retained; new version/fingerprint agree with manifest | [Upgrade](upgrade/report.json), [before](integration/native-identity-before.log), [after](integration/native-identity-after.log) |
| Installed HTTPS/HTTP2 public consumer | PASS with checkout hidden; std-net/cjnative diagnostics and 5.11.0 observed; no libssl/libcrypto dependency | [Consumer output](upgrade/consumer-https-http2.stdout.log) |
| Candidate license/NOTICE/SPDX regeneration | New archive notice identifies exact 5.11.0 source; initial stale-notice finding corrected; production notice unchanged | [Supply chain](upgrade/supply-chain/), [review follow-up](review/independent-review-followup.json) |
| Release verifier negative controls | 13 PASS, including actual selected native archive ABI execution; disposable offline signatures are TEST_ONLY | [Controls](verifier-controls/candidate-verification.json) |
| Regression coverage | 80 PASS, zero failed/skipped in the final combined integration invocation; includes six behavioral candidate guards. Advisory omission reproduced failing-before and then rejected | [Tests](integration/tests.json), [failing-before](integration/rollback-advisory-failing-before.log) |
| Candidate TLS/fuzz/paired performance | TLS 13/13 and all 10 unchanged fuzz campaigns PASS; 33 cases × two archives × eight rounds produced 528 samples, no sample failures. Performance FAIL: TLS full-handshake P95 ratio 1.205157275 exceeds 1.20; 31 NOISY / 2 PASS repeatability rows. No rerun to obtain green | [Final immutable capture](candidate-gates/final2/report.json) |
| Candidate installed-source/CA/native floor matrix | Fresh STS-only host 47 checks and six CA cases PASS; KVM Westmere/no AVX, kernel 5.15.0-198-generic and explicitly selected glibc 2.44 PASS 47 unchanged-binary plus 47 rebuilt checks. Stock guest glibc 2.35 is UNSUPPORTED; owned VM has zero live processes | [Installed matrix](matrix/installed/index.json), [native floor](matrix/native-floor/index.json) |
| Independent native TLS coexistence | PASS: 287 ELF/archive scans; four same-version STS build/runtime cells with 20 behavioral checks and six boundary tests. Independent OpenSSL is explicitly isolated TEST_FIXTURE_ONLY; default release has no implicit system TLS dependency | [Binary index](matrix/binary/index.json), [summary](matrix/binary/summary.json) |
| Exact original rollback archive authentication and STS consumer | Both initial and final-candidate private-store rehearsals authenticate all three original attestation subjects and build/run the exact old package under STS 1.1.3 | [Original retrieval](rollback/retrieval.json), [final refusal](rollback/final-candidate-refusal.json) |
| Current exact-artifact rollback security acceptance | BLOCKED: SECURITY_DISPOSITION_MISSING, CLI exit 1; exact upgraded archive and pointer bytes unchanged, restore NOT_RUN | [Final refusal](rollback/final-candidate-refusal.json), [rollback procedure](../../guides/nonproduction-rollback.md) |
| Complete independent security/release approval | BLOCKED: WebSocket eager declared-frame allocation remains OPEN; selected-hunk review is not exhaustive crypto/assembly review or human approval | [Initial review](review/independent-review.json), [follow-up](review/independent-review-followup.json) |
| Committed-source qualification, 86400-second formal soak and release signing | NOT_RUN / NOT_GRANTED; historical captures record an uncommitted candidate, and publication establishes no new acceptance seal or signing authorization | Upgrade scope and current review prerequisites |

Initial inventory `current/` is explicitly historical pre-upgrade evidence. Candidate inventory contains both 5.11.0 and additional 5.5.0 official release channels. All preserved public GHSA IDs, unresolved findings and review gaps are mandatory in a genuine signed rollback disposition; every current review/intake/response digest is bound. First-page, private and unpublished advisory limits remain unknown. A signature authenticates an assertion, not its truth.
The binary slice uses two independently located byte-identical STS 1.1.3 roots, not two SDK versions. Its read-only private adapter changes output/task metadata and the exact selected provider identity assertion only; original/adapted hashes and exact diffs are retained. Actual repository production comparison and runtime loading checks remain active. Unisolated OpenSSL and future STS compatibility are not claimed.

## Run and verify

Use the [dependency upgrade runbook](../../guides/dependency-upgrade-runbook.md), [inventory guide](../../guides/native-dependency-inventory.md), [rejection controls](../../guides/release-verifier-rejection-controls.md) and [non-production rollback procedure](../../guides/nonproduction-rollback.md). Each command records the exact selected archive, SDK and source inputs. Keep disk-backed private scratch outside the repository and explicitly select STS 1.1.3.

The canonical `tools/tasks/M12-004.json` runs behavioral regression contracts and existing source-bound evidence validation. The `dependency-upgrade-contracts` command also runs `tools.tests.test_m12_004_checker`, which requires the archived repaired-performance checker to resolve its inputs from the reconstructed durable repaired input bundle (`repaired-server-performance/input`), match its ten bound source digests to `input-manifest.json`, and report withheld archives as a truthful `BLOCKED` result (exit 2) instead of crashing; the module is bound in `allowed_paths` and `source_paths`. Formal validation must reject `acceptance_status=BLOCKED`; a successful isolated rehearsal cannot be sealed as COMPLETE. No commit, push, PR, issue mutation, production signature or deployment replacement is performed by this task.
The [acceptance report](acceptance.json) and [current verification receipt](verification.json) retain BLOCKED/NOT_QUALIFIED while artifact, SDK and measured source bindings pass. The [canonical task gate](../../gates/M12-004-task.json) returned 1: all 80 regression contracts passed, then `scripts/verify-evidence M12-004 --json` rejected `ACCEPTANCE_NOT_PASS`. That record predates binding the archived-checker regression into the command; the next gate invocation will run the extra module and is still expected to fail on `ACCEPTANCE_NOT_PASS`. This is the intended fail-closed release boundary, not a skipped test or a passing qualification. The [selected documentation/privacy smoke](integration/docs-privacy.json) passed after normalizing the CLI-help warning path; the warning itself remains visible. It is not a whole-repository or pre-push privacy clearance.

## Server performance follow-up

The user-authorized Server campaign uses the exact same two archives and byte-identical 164 Cangjie source inputs. Its [summary](server-performance/summary.json), [raw capture](server-performance/capture/report.json), [independent checker](server-performance/checker/verification.json) and [typed file index](server-performance/index.json) are supplemental evidence. The original local failure report remains unchanged.

Real Xeon Gold 6248R hardware and Linux 5.15.0-191-generic execute explicitly selected STS 1.1.3. All 392 qualified SDK inputs match before and after. CPU affinity is 0-7 on NUMA node 0, without exclusive-core reservation. The unprivileged host user maps to namespace root; all 14 glibc 2.44 files are privately mounted read-only. Stock host glibc 2.35 support is not claimed. Host originals remain unchanged, fixture private keys are removed, and [owned process cleanup](server-performance/owned-cleanup.json) observes zero live task processes.

The full 33-case campaign returned 1: 528 native attempts yielded 464 healthy samples and 64 failed baseline commands across eight HTTP cases. The first retained baseline failure reports operation deadline exceeded, bounded native wait expired and produced=0. No case, failed command or round was discarded. The independent checker also returned 1 for full-campaign acceptance, while separately verifying archive/source/SDK/binary bindings, all 1080 raw log digests and exact execution order. The cause was unknown at capture time; the subsequent diagnosis and consumer repair are recorded below without changing this failed capture.

TLS-only diagnostics independently recompute 48 healthy samples for full handshake, resumption and bulk transfer, each leg with one warmup and seven measured rounds. These are DIAGNOSTIC_ONLY_NOT_FULL_GATE.

| Diagnostic check | Candidate/baseline ratio | Unchanged limit | Diagnostic result |
| --- | --- | --- | --- |
| Bulk throughput | 0.977250499 | >= 0.90 | PASS |
| Full-handshake P50 | 0.999547234 | <= 1.10 | PASS |
| Full-handshake P95 | 0.996724838 | <= 1.20 | PASS |

The full-handshake repeatability classifier is PASS; bulk and resumption remain NOISY. These diagnostics do not replace either the failed full Server campaign or the failed historical local gate. Formal M7-024 qualification and the 86400-second soak remain NOT_RUN.

The execution worker's model-transport certificate failure was recovered by waiting for the original Server launcher; no second campaign was started. The actual launch argv and exit 1 are in [launch.json](server-performance/capture/launch.json). Independent verification ran `python3 <task>/checker/check.py --report <task>/capture/report.json --output <task>/checker/verification.json`. The [Server workspace snapshot](server-performance/workspace.json) records concurrent HEAD 5c6f238d1824039150832ebbeaa624f96114e29d, without rewriting the original rehearsal snapshot below.

## HTTP round-release repair

The retained baseline binary passed false to the latch constructor for serial
work. GDB observed constructor argument, object payload and worker load all 0,
followed by the original Deadline failure. Changing only that argument to 1
completed all eight failed scenario paths in the unchanged binary. This
[diagnostic proof](http-round-release/before/diagnosis.json) is not performance
acceptance. Original compiler/cache origin remains unproven; retained CJPM
configuration caches do not include complete compiler argv or IR.

The shared consumer now starts every round closed. After any required concurrent
admission/ownership check, the coordinator stores true for every round before
joining futures. Workload counts, checksums, shared 60-second Deadline, TLS and
performance thresholds are unchanged. The repaired consumer source and both
exact provider archives are bound by the [summary](http-round-release/summary.json).

Two fresh -O2 consumers execute all 14 unchanged HTTP cases each on Server with
STS 1.1.3 and private read-only glibc 2.44. All 28 native commands exit 0, with no
controller timeout or terminal owners. Serial and 10/100-stream work, early
close, real cancellation, flow stall, overload and observer enabled/disabled pass
without debugger intervention or native retries. The 29 existing contracts pass.

The [capture](http-round-release/native/report.json),
[independent verification](http-round-release/checker/verification.json),
[preservation receipt](http-round-release/originals-after.json) and
[snapshot index](http-round-release/index.json) retain exact inputs and outcomes.
The checker reconstructs all 28 samples and rejects 11 tampering controls. Its
[initial contract correction](http-round-release/checker/contract-adjustment.json)
is preserved: the workload asserts server status 503, but the terminal server
rejection counter is 0 and is not evidence of that assertion.

Captured raw-byte digests remain distinct from published privacy-normalized text
digests. Exact binaries and raw manifests stay in private task caches; the
binary-bound checker executed on those originals, not normalized substitutes.
The 28-case correctness repair itself did not rerun the full paired performance
gate. The subsequent authorized full33 follow-up is recorded below. Neither
capture replaces a historical FAIL or grants release qualification.

## Repaired-source full33 Server performance follow-up

The [source-bound summary](repaired-server-performance/summary.json),
[full capture](repaired-server-performance/capture/report.json),
[independent verification](repaired-server-performance/checker/verification.json)
and [typed snapshot index](repaired-server-performance/index.json) retain one
actual paired campaign. The only source delta against the preceding Server
campaign is the repaired HTTP round release. Ten inputs are frozen; both
AWS-LC5.5.0 baseline and5.11.0 candidate archives retain their original bytes,
and their164 production Cangjie files are byte-identical.

Only qualified STS1.1.3 is executed. Six fresh -O2 consumers run on native
Server Linux/x86_64 in the private readonly14-file glibc2.44 closure; host
glibc2.35 is unchanged. Every build masks the source checkout, and live native
observations bind the selected SDK and private closure. CPU0-7/NUMA0 affinity
is nonexclusive; this is not stock-host or formal M7-024 qualification.

All528 native commands exit0:66 warmups and462 measured samples across33
cases, two archive legs and seven measured rounds per case per leg. All93984
operation-latency records are retained. There are zero native failures,
controller timeouts and terminal-owner failures. No measurement is repeated
or discarded. The frozen measurement AST and thresholds are unchanged.

| Candidate / baseline metric | Actual ratio | Unchanged limit | Decision |
| --- | ---: | ---: | --- |
| TLS bulk throughput | 1.034900 | >=0.90 | PASS |
| Full handshake P50 | 0.996112 | <=1.10 | PASS |
| Full handshake P95 | 0.994301 | <=1.20 | PASS |

The full classifier returns9 PASS and24 NOISY: the overall performance decision
is NOISY, not PASS. Launcher/finish exit0 is not performance acceptance. The
independent checker reconstructs all528 samples, all33 classifiers and the
three ratios; its [negative controls](repaired-server-performance/checker/rejection-probes.json)
reject34/34 mutations. Technical evidence integrity is PASS, independently of
the non-passing performance decision.

The published checker resolves its manifest and source adapters from the
reconstructed durable repaired input bundle
`docs/evidence/M12-004/repaired-server-performance/input`; it does not read a
machine-specific cache directory. That bundle reuses the previously committed
pre-repair input copy with `repo/examples/linux/m12_001/http.cj` replaced by the
repaired repository source, so all ten bound `source_inputs` now match
`input-manifest.json`; `inputs.json`, `sdk-oracle.json` and
`glibc244/provenance.json` are copied from the committed inputs and verified.
The reconstruction method is recorded in [RECONSTRUCTION.md](repaired-server-performance/input/RECONSTRUCTION.md).
The two measurement archives (`baseline.tar.gz`, `candidate.tar.gz`) and the
private frozen glibc 2.44 runtime files under `input/glibc244/` are deliberately
withheld from the repository, so a clean-checkout invocation writes a truthful
`verification_status=BLOCKED` report with exit2 and does not attempt validation.
The committed [checker verification](repaired-server-performance/checker/verification.json)
remains the record of the full-input run; reproducing it requires supplying
those withheld archives and private glibc files at the documented paths. The
regression above keeps that blocked path from silently becoming a crash or from
validating the wrong source snapshot.

The [first bootstrap failure](repaired-server-performance/bootstrap-failure/launch.json)
is preserved with exit1, zero SDK/native executions and the PermissionError
stderr. Bundle creation had incorrectly removed the loader executable bit.
Recovery restores original bundle file metadata only; all bytes stay unchanged.
The [mode receipt](repaired-server-performance/capture/mode-after.json) separates
bundle loader0755 from private loader0700 under extraction umask077. Two
bootstrap launches do not represent two native measurement campaigns.

The [postflight receipt](repaired-server-performance/postflight.json) confirms
all392 SDK inputs, original host14 glibc files, six original binaries, old/new
archives and source inputs remain unchanged, with zero owned live processes
and no fixture private keys. All three historical report digests remain fixed.
The [current workspace](repaired-server-performance/workspace.json) records
HEAD5c6f238d1824039150832ebbeaa624f96114e29d and295 pre-existing dirty paths.
Published files separate captured artifact bytes from normalized text digests.
Only this supplement and the current M12-004 status are updated; no SDK/provider
build, commit, push, issue edit or signing occurs. M12-004 remains BLOCKED.

## Workspace and remaining prerequisites

Physical branch `gitbutler/workspace`; logical task branch `m12-004-dependency-rehearsal`; HEAD `e023996a847a863bc52be20983139ff6d28d9625`; main merge base `00d6864f8f5dee6a5c13a5a68144135e9e9601bc`. The initial safety record contains 272 dirty entries: 0 staged, 134 unstaged and 138 untracked. Paths use `<repo>`/`$HOME` placeholders.

Release remains blocked until performance acceptance and current security
finding/review gaps are resolved with source-bound proof, committed candidate
source and full candidate-specific qualification exist, the complete86400-second
soak passes, and signing is separately authorized. The noisy full33 follow-up
does not grant performance acceptance. The original rollback bytes need their
own truthful present security acceptance; a newer-source fix does not remediate
those old bytes. Do not automatically advance to another backlog task.
