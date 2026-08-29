# M7-029 final independent security review

## Decision

PASS for M7-029. The frozen candidate has no Open Critical or High finding. The strict repository validator accepts the exact final JSON with 26 recorded findings: 17 Fixed, 1 NotApplicable, and 8 Open Medium.

This verdict is limited to the Linux M7-029 independent-review acceptance contract. It is not a stable-release verdict. Seven release evidence entries remain stale after M7-032, M7-022 still requires the final 86,400-second soak, and non-Linux gates were not run.

I reviewed the process-isolated snapshot without implementation history and made no product, test, manifest, planning, or existing-evidence changes. The asserted candidate is `ea493f13fefa520e9c1f2e08b9b068dc26c28082`. The snapshot has no `.git` directory, so I could not independently prove that commit-to-byte binding.

## Critical and High closure

| Finding | Severity | Result | Evidence |
|---|---|---|---|
| WS-BUILD-001 | Critical | Fixed | Tracked AWS-LC manifest, build-contract tests, and hosted clean build. |
| WS-CI-001 | Critical | Fixed | Canonical hosted workflow plus strict required `clean-cangjie-build`; exact-candidate run is supplied in `remote-final-state.json`. |
| WS-BUILD-002 | High | Fixed | Combined native hook builds the missing resolver before CJPM lifecycle operations. |
| WS-EVID-001 | High | Fixed | Qualification binds provider and resolver manifests, native C/H, build tools, `build.cj`, lockfile, and manifest. |
| WS-GOV-001 | High | Fixed | Active strict main ruleset 21787899 has no bypass actors and blocks deletion/non-fast-forward updates. |
| WS-H2-SERVER-FLOW-001 | High | Fixed | Writer atomically claims or cancels reserved DATA permits; focused suite passed. |
| WS-H2-SETTINGS-001 | High | Fixed | RFC peer defaults and advertised local receive limits are separate; focused suite passed. |
| WS-H2-WRAP-001 | High | Fixed | Cancellation wrapper preserves protocol body-completion policy; focused suite passed. |
| WS-LIC-001 | High | Fixed | Apache-2.0 project grant and exact AWS-LC notices are payload and SBOM inputs. |
| WS-PROXY-001 | High | Fixed | Dynamic authenticated CONNECT tunnels are single lease when no stable credential identity exists. |
| WS-RES-001 | High | Fixed | Process-wide admission caps live pools at 8 and workers at 64. The ninth quarantined pool fails with `OVERLOADED` and a zero handle; releasing blocked calls lets reapers return capacity. |
| WS-RETRY-001 | High | Fixed | Ambiguous physical write timeout is `Never` retryable. |
| WS-STDNET-001 | High | Fixed | Cancelling one accept no longer closes the listener. |
| WS-TLS-TRUST-001 | High | Fixed | Session partition identity binds bounded trust-store content digests. |

The hosted build and ruleset statement uses committed evidence plus `/tmp/wirestack-m7029-final-review.fTgDXM/remote-final-state.json`. The latter is orchestrator-provided external evidence. I did not query GitHub myself. It reports candidate `ea493f13...`, successful hosted run 33237855698/job 99061886604, and the active strict main ruleset.

## Resolver decision

The second isolated review correctly kept WS-RES-001 Open because per-pool quarantine was unbounded across repeated public pool construction. The candidate closes that exact residual risk:

- `resolver_capacity_mutex` serializes process-wide reservations.
- `WIRESTACK_RESOLVER_MAXIMUM_LIVE_POOLS` is 8.
- `WIRESTACK_RESOLVER_MAXIMUM_LIVE_WORKERS` is 64.
- capacity is reserved before thread creation and released only from safe pool destruction after worker joins and caller-held job references reach zero.
- overload returns before starting threads and leaves the output handle at zero.
- the wrapped `getaddrinfo` probe blocks eight pools, observes rejection of the ninth, releases the calls, and observes later admission.

The residual behavior is explicit: libc/NSS calls themselves remain uninterruptible and may hold up to the fixed process-wide cap indefinitely. New resolver creation then fails closed. That is bounded degradation, not unbounded quarantine.

## Reassessment of every earlier finding

The final JSON contains every prior Critical/High finding, both findings added by the first isolated review, the material Medium fixes, and the Medium issues that affect the present verdict. The remaining original-audit dispositions were also rechecked:

| Finding | Result | Current assessment |
|---|---|---|
| WS-API-001 | Open Medium | Public mutable `Array<Byte>` backing remains. |
| WS-API-ALIAS-001 | NotApplicable | ADR-0006 replaced the experimental pre-1.0 contract; current M7-032 inventory has zero internal alias targets. |
| WS-CANCEL-001 | Open Medium | Public callback storage still lacks a hard admission bound. |
| WS-CI-SUPPLY-001 | Open Medium | The canonical clean workflow is pinned; several non-canonical workflows retain mutable major tags. |
| WS-CONN-001 | Open Medium | Candidate tasks are still created ahead of rolling admission. |
| WS-H2-BODY-001 | Open Medium | No new executed regression established corrected unknown-length byte accounting. |
| WS-H2-BUFFER-001 | Open Medium | Inbound body memory still lacks an independent byte cap. |
| WS-H2-DRAIN-001 | Open Medium | Standalone connection drain still lacks its own required context/deadline proof. |
| WS-H2-SETTINGS-002 | Fixed Medium | Endpoint-role regression passed. |
| WS-H2-WRITER-001 | Open Medium | No separate executed proof closed standalone writer/permit abort atomicity beyond the fixed server transfer path. |
| WS-IPV6-001 | Open Medium | Bracketed literal execution still crosses a `HostName` path. |
| WS-POOL-001 | Open Medium | No deterministic factory-completion/cancellation publication regression was supplied. |
| WS-PR41-001 | NotApplicable | The finding concerned an unmerged Windows PoC PR and is outside this frozen Linux candidate. |
| WS-RES-002 | Fixed Medium | Pending waits back off 1, 2, 4, 8, then 16 ms. |
| WS-RES-003 | Fixed Medium | Only explicit family 4 or 6 is accepted. |
| WS-TIME-001 | Open Medium | Cross-clock-domain deadline comparison remains unguarded. |
| WS-TLS-CLOSE-001 | Open Medium | No new race proof closed graceful close versus active read/write. |
| WS-TLS-KEY-001 | Open Medium | Key metadata and content still use separate path operations. |
| WS-TLS-LIFE-001 | Open Medium | Deterministic provider/context ownership remains unresolved. |
| WS-TLS-OWN-001 | Open Medium | Context key lifetime still depends on a caller-closeable reference. |
| WS-TLS-PROFILE-001 | Open Medium | `Compatible` and `Modern` still lack a proved distinct policy. |
| WS-TLS-SESSION-001 | Open Medium | Lifetime arithmetic and full policy digest concerns remain. |
| WS-EVID-002 | Open Medium | Seven release-package entries remain stale after M7-032. |
| WS-CONN-002 | Open Low | Attempt-delay multiplication ceiling remains unproved. |
| WS-HTTP1-PERF-001 | Open Low | Chunked read allocation concern remains; no performance claim was made. |
| WS-RES-004 | Open Low | Public service-string embedded-NUL rejection remains unproved. |
| WS-STDNET-002 | Open Low | Invalid staging-size construction cleanup remains unproved. |
| WS-STDNET-003 | Open Low | Accepted-socket conversion failure guard remains unproved. |
| WS-TLS-SOURCE-001 | Open Low | `content_sha256` naming still does not denote a canonical archive digest. |
| WS-H1-CONNECT-001 | Open Informational | Public server tunnel handoff remains a documented API boundary, not a release-security blocker. |

No new Critical or High issue was found in the reviewed build, TLS/trust, HTTP/1, HTTP/2, cancellation/lifecycle, retry/proxy, license/SBOM, or evidence-control paths. Static review also found no new HTTP/1 smuggling bypass, unbounded HPACK/frame/table escape, certificate identity fallback, runtime OpenSSL fallback, private `CJ_MRT_Sock*` use, or secret-bearing report content.

## Validation

| Command | Exit | Result |
|---|---:|---|
| `jq empty /tmp/wirestack-m7029-final-review.fTgDXM/output/independent-review.json` | 0 | JSON syntax valid. |
| `python3 tools/m7_029_independent_security_review.py --root . --request docs/evidence/M7-029/review-request.json --review /tmp/wirestack-m7029-final-review.fTgDXM/output/independent-review.json --report /tmp/wirestack-m7029-final-review.fTgDXM/output/review-validation.json --json` | 0 | PASS; 26 findings, 17 Fixed, 1 NotApplicable, 8 Open; zero unresolved Critical/High. |
| `python3 -m unittest tools.tests.test_m7_029_independent_security_review -v` | 1 | 13 tests passed and 1 failed because the snapshot has no `.git`; not counted as PASS. |
| `python3 tools/gates/m2_003_resolver_pool.py --repo-root . --output-dir /tmp/wirestack-m7029-final-review.fTgDXM/regressions/resolver-pool --delay-ms 250` | 1 | Combined gate FAIL because the pre-test hook could not resolve `github.com` to fetch AWS-LC. The independently compiled native global-bound subprobe returned `GLOBAL_POOL_BOUND PASS`; the overall command is not counted as PASS. |

Final artifact SHA-256 values:

- `independent-review.json`: `8b43d2359c37456bfeb17e311e6462b8b00be375a0ab62133d1e13baa4c3cc56`
- `review-validation.json`: `e60c466389a88ac2ca9832c4a8cecae348a7845de6acacf18cad2c3c7f67bd90`
- fresh non-PASS resolver report: `8513a7beb1bbd0b65741c50ae46765b20f74353b6ec623df59cb03c861b2cd58`

## Limitations

- The snapshot has no `.git`, so repository root, branch, HEAD, merge base, status, dirty paths, tracked-file visibility, and asserted commit binding could not be independently checked. The candidate SHA is an orchestrator assertion supported by the supplied remote JSON.
- Network access was unavailable. I did not independently query GitHub or fetch AWS-LC.
- The fresh combined resolver gate and full M7-029 unittest module are non-PASS for the exact environmental reasons above. Neither is used as closure evidence.
- Fixed dispositions use committed executed PASS logs with verified SHA-256 values. The strict validator rehashed every referenced file.
- The one-hour SSE profile, 86,400-second soak, SDK build, final artifact rebuild/signing, and non-Linux gates were deliberately not run.
- Open Medium and Low findings retain their residual risks. The M7-029 contract permits them because no Critical or High finding remains Open.

## Eligibility

M7-029 is eligible for COMPLETE. This does not make M7-022, M7-030, M7-031, or the Linux stable release complete.
