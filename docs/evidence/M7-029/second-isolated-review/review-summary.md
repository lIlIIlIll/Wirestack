# M7-029 final independent security review

## Decision

**FAIL.** The frozen candidate retains one Open Critical finding and one Open High finding. The nine other High findings and one Medium finding have source fixes plus fresh executed PASS regressions.

This review was performed by an OpenAI Codex process-isolated reviewer commissioned by the same repository owner. It is process-independent from implementation discussion, not organizationally independent external assurance.

- Candidate commit represented by the archive: `8e4a0e82f040b1befba1ecaff443069af4b85825`
- Review target: `docs/security/review/linux-1.0/evidence-index.json`
- Target SHA-256: `19257a4f9d8571cdaea069beb571efa0e36e660563b25d90a83ce54345078b6c`
- Compatibility policy: `NO_BACKWARD_COMPATIBILITY_PRE_1_0`
- Findings: Critical 1 Open; High 9 Fixed / 1 Open; Medium 1 Fixed / 8 Open

## Critical and High dispositions

| Finding | Severity | Status | Basis |
|---|---|---|---|
| WS-CI-001 | Critical | Open | Clean workflow exists, but the repository evidence states there are no required checks or protected-main rules and no hosted execution. Static workflow tests cannot establish merge enforcement. |
| WS-BUILD-002 | High | Fixed | `cjpm check` passed from the original retained-provider-cache precondition with the resolver output absent; the hook built the resolver. |
| WS-H2-SERVER-FLOW-001 | High | Fixed | Reserved permit transfer/cancellation is atomic; 10 focused scheduler tests passed. |
| WS-H2-SETTINGS-001 | High | Fixed | RFC peer defaults and advertised local policy are separated; 9 focused settings tests passed. |
| WS-H2-WRAP-001 | High | Fixed | The public wrapper preserves `completesAtDeclaredLength`; 14 facade tests passed. |
| WS-PROXY-001 | High | Fixed | Authenticated CONNECT tunnels are no-reuse; 2 proxy tests passed. |
| WS-RES-001 | High | Open | Close is bounded by detaching a reaper, but indefinitely blocked `getaddrinfo` calls can retain each publicly constructible pool's workers and memory. No global cap exists. The 250 ms delay test does not cover indefinite or repeated accumulation. |
| WS-RETRY-001 | High | Fixed | Ambiguous write timeout is non-retryable; 19 StdNet tests passed. |
| WS-STDNET-001 | High | Fixed | Per-accept cancellation no longer closes the listener; 19 StdNet tests passed. |
| WS-TLS-TRUST-001 | High | Fixed | Trust identity binds bounded file/directory contents; 5 adapter tests passed. |
| WS-LIC-001 | High | Fixed | Apache-2.0 grant, notices, and release/SBOM metadata tests are present and passed. |

## Medium dispositions

WS-H2-SETTINGS-002 is Fixed with the executed settings regression. WS-API-001, WS-CANCEL-001, WS-CI-SUPPLY-001, WS-H2-BUFFER-001, WS-IPV6-001, WS-TLS-KEY-001, WS-TLS-OWN-001, and WS-EVID-002 remain Open. No new material finding was identified; the residual resolver risk is the unresolved impact of WS-RES-001 rather than a new identifier.

## Commands and exact results

Executed PASS evidence used for Fixed dispositions:

- `python3 -m unittest tools.tests.test_m7_029_independent_security_review.M7029IndependentSecurityReviewTests.test_cjpm_build_hook_builds_both_native_dependencies tools.tests.test_m7_029_independent_security_review.M7029IndependentSecurityReviewTests.test_clean_cangjie_workflow_covers_the_release_critical_gates tools.tests.test_m7_021_linux_release.M7021LinuxReleaseTest.test_qualification_inputs_bind_native_manifests_sources_and_build_logic tools.tests.test_m7_021_linux_release.M7021LinuxReleaseTest.test_release_metadata_inventory_is_complete tools.tests.test_m7_025_linux_supply_chain.M7025LinuxSupplyChainTest.test_fingerprint_is_stable_and_dependency_sensitive tools.tests.test_m7_025_linux_supply_chain.M7025LinuxSupplyChainTest.test_generation_is_byte_deterministic tools.tests.test_m7_025_linux_supply_chain.M7025LinuxSupplyChainTest.test_project_and_resolver_sbom_packages_use_apache_2_0 tools.tests.test_m7_025_linux_supply_chain.M7025LinuxSupplyChainTest.test_wrong_project_license_expression_fails_closed -v` — exit 0; 8 passed.
- `/home/elliot/.codex/scripts/codex_cangjie_env --cwd /tmp/wirestack-m7029-final-review.t9LCwO/repo cjpm check` — exit 0; `cjpm check success`; provider cache manifest-validated and resolver absent initially.
- Same environment wrapper with `cjpm test --filter Http2WriteSchedulerTest --parallel 1 --no-progress --no-color` — exit 0; 10 passed, 583 skipped.
- Same environment wrapper with `cjpm test --filter Http2SettingsTest --parallel 1 --no-progress --no-color` — exit 0; 9 passed, 584 skipped.
- Same environment wrapper with `cjpm test --filter HttpFacadeTest --parallel 1 --no-progress --no-color` — exit 0; 14 passed, 579 skipped.
- Same environment wrapper with `cjpm test --filter Http1ProxyClientPipelineTest --parallel 1 --no-progress --no-color` — exit 0; 2 passed, 591 skipped.
- Same environment wrapper with `cjpm test --filter StdNetTransportTest --parallel 1 --no-progress --no-color` — exit 0; 19 passed, 574 skipped.
- Same environment wrapper with `cjpm test --filter LinuxSystemTrustAdapterTest --parallel 1 --no-progress --no-color` — exit 0; 5 passed, 588 skipped.
- `python3 tools/gates/m2_003_resolver_pool.py --output-dir /tmp/wirestack-m7029-final-review.t9LCwO/resolver-gate --delay-ms 250` — exit 0 and gate decision PASS, but insufficient to close WS-RES-001.
- `scripts/architecture-guard --format json` — exit 0; zero violations.
- `scripts/check-m7-028-security-review --json` — exit 0; package contract PASS.

Non-PASS or non-closure evidence:

- `scripts/verify-evidence M7-028` — non-PASS freshness result: `evidence-freshness: STALE`.
- Combined Python security/release suite — exit 1: the archive lacks `.git`, and M7-021/M7-025 freshness checks failed. The focused eight-test subset above passed and is the only Python regression used for Fixed dispositions.
- Full non-performance Cangjie run in the restricted sandbox — exit 1 because local sockets returned `Operation not permitted`.
- Authorized full non-performance rerun emitted relevant passing cases but was externally terminated before a final test summary and exit code; it is not claimed as PASS.
- A fully clean provider rebuild was not established: network fetch was unavailable, and an offline source-cache attempt encountered system OpenSSL header contamination. WS-BUILD-002 was assessed only under its original retained-provider-cache reproduction precondition.

The review JSON is syntactically valid. The repository review validator was not run because its schema intentionally requires `conclusion == PASS`; this review's warranted `FAIL` would return `REVIEW_NOT_PASS` before validating release acceptance. Findings were not changed to satisfy that release-only condition.

## Scope and method coverage

All 14 request scopes were covered through source review, negative and boundary analysis, lifecycle/concurrency inspection, native C ABI review, and evidence audit. Static scans found no private `CJ_MRT_Sock*` use, dynamic OpenSSL fallback, or forbidden `std.net` import outside the adapter. HTTP/1 framing, HTTP/2/HPACK bounds, identity checks, secret handling, private-key lifecycle, resolver/proxy routing, release evidence, and supply-chain metadata were inspected.

## Limitations

- The archive has no `.git` directory. Current branch, merge base, status, tracked-file visibility, and independent verification that its bytes equal commit `8e4a0e82f040b1befba1ecaff443069af4b85825` were unavailable; the commit is the commissioning assertion.
- No remote GitHub branch-protection or hosted Actions state was available. This is substantive evidence for keeping WS-CI-001 Open.
- The one-hour SSE profile, 86,400-second soak, SDK builds, and non-Linux gates were deliberately not run.
- No real indefinite NSS/DNS block or repeated-pool exhaustion stress was run; the source lifecycle and the bounded 250 ms shim establish why the existing regression does not close WS-RES-001.
- No full green repository Cangjie gate was obtained; focused suites are reported separately and skipped tests are not treated as passes.
