# Wirestack M7-029 independent security review

## Verdict

**FAIL.** The frozen review package is internally valid, and every previously reported Critical or High finding that existed before this snapshot has current remediation evidence. A fresh native-ABI review found one new unresolved High finding, `WS-NATIVE-ABI-001`. Under the M7-029 acceptance rule, that finding blocks PASS.

Target package:

- Path: `docs/security/review/linux-1.0/evidence-index.json`
- SHA-256: `912ac14704efbbd25353ff00bcbc69b0d788d87df3e733ec83d956b48eb95957`
- Frozen snapshot: `/tmp/wirestack-m3-030-review.sXgLa5/repo`
- Review mode: process-isolated agent; no product, test, evidence, or repository files were modified

## A. Workspace safety

- Reviewed the supplied frozen snapshot only.
- Wrote only under `/tmp/wirestack-m3-030-review.sXgLa5/output`.
- Did not commit, push, amend, switch branches, alter GitHub state, or modify either the frozen repository or the live repository.
- Did not run an SDK build, compiler build, non-Linux gate, 3,600-second SSE profile, or 86,400-second soak.
- The snapshot intentionally has no usable `.git` repository. One Python test that asserts Git index visibility therefore failed with Git exit 128; the remaining 36 tests in that command passed.

## B. Task ID and status

- Task: `M7-029`
- Status: **INCOMPLETE / security conclusion FAIL**
- Release blocker: one unresolved High finding

## C. Scope completed

All 14 required areas were reviewed from current source and frozen evidence.

| Area | Result | Current assessment |
|---|---|---|
| supply-chain | Reviewed with Medium limitation | Provider identity, version, commit, tree, manifest, clean-build gate, license, notice, and SBOM controls were inspected. Ancillary workflow references remain mutable. |
| certificate-identity | FAIL | Runtime implementation and tests are present, but the canonical ABI contract omits SAN, certificate-validation, reference-identity, peer-chain, trust-load, and pinning imports. |
| private-keys | FAIL | Key validation is implemented, but the ABI contract omits key-validation imports; path TOCTOU and caller-controlled key ownership remain Medium. |
| tls-protocol | FAIL | Current provider implements TLS 1.2/1.3 and ALPN policy, but the native gate can accept a provider without security-critical engine configuration functions. |
| lifecycle-cancellation | Reviewed | Prior High accept/listener, resolver-quarantine, H2 completion, and retryability defects are fixed. Callback registry hard bounding remains Medium. |
| dns-proxy-routing | Reviewed | Resolver quarantine and authenticated CONNECT isolation fixes were reconfirmed. Direct IPv6 literal routing remains Medium. |
| http1-smuggling | Reviewed | Parser limits, negative cases, deterministic fuzz, and replay evidence are current; no material new HTTP/1 request-smuggling finding was identified. |
| http2-hpack | Reviewed | Prior High flow-control, SETTINGS ownership, and completion defects are fixed. Inbound buffer byte accounting remains Medium. |
| resource-bounds | Reviewed | Native resolver work is globally bounded and quarantined. The open callback and H2 inbound byte-bound issues remain. |
| pool-isolation | Reviewed | Authenticated CONNECT tunnels are single-lease and not returned to a shared pool; no new High or Critical issue was identified. |
| sensitive-data | Reviewed | Package validation's sensitive-value checks passed. No literal private key, authorization value, cookie value, or captured request body was found in the reviewed report data. |
| native-c-abi | FAIL | The 55-versus-40 contract mismatch and validator false-negative are reproducible. |
| linux-platform | Reviewed with limitations | Frozen Linux unit, integration, native ABI, TLS, and resolver evidence was inspected; the long SSE and soak profiles were not rerun. |
| release-evidence | Incomplete | The index correctly marks several release rows stale. M3-030 release/SBOM validation reuses the older M7-021 artifact identity, and the referenced archive is absent from the frozen snapshot. |

## D. Files changed

Only review outputs were created:

- `/tmp/wirestack-m3-030-review.sXgLa5/output/independent-review.json`
- `/tmp/wirestack-m3-030-review.sXgLa5/output/review-summary.md`
- `/tmp/wirestack-m3-030-review.sXgLa5/output/review-validation.json`

No Wirestack source or evidence input changed.

## E. Findings and dispositions

### New release-blocking finding

#### WS-NATIVE-ABI-001 — High — Open

The canonical provider contract in `tools/tls_provider/abi-v1.json` describes 40 symbols: 23 unconditional functions plus the functions enabled by the selected capabilities. Production Cangjie code declares 55 distinct `wirestack_tls_*` foreign functions. The following 15 production imports are absent from the contract:

1. `wirestack_tls_certificate_subject_alt_names`
2. `wirestack_tls_certificate_validate_der`
3. `wirestack_tls_engine_add_spki_sha256_pin`
4. `wirestack_tls_engine_configure_client_authentication`
5. `wirestack_tls_engine_enable_peer_verification`
6. `wirestack_tls_engine_load_verify_bundle`
7. `wirestack_tls_engine_load_verify_directory`
8. `wirestack_tls_engine_peer_chain_der`
9. `wirestack_tls_engine_set_dns_reference_identity`
10. `wirestack_tls_engine_set_ip_reference_identity`
11. `wirestack_tls_engine_set_server_name`
12. `wirestack_tls_identity_validate_pkcs8`
13. `wirestack_tls_identity_validate_spki`
14. `wirestack_tls_private_key_validate_pkcs8`
15. `wirestack_tls_sha256`

`expected_symbols()` is derived only from that incomplete JSON contract, and `validate_symbol_set()` subtracts only that set. A candidate containing those 40 symbols but lacking `wirestack_tls_engine_enable_peer_verification` was accepted by the validator. The existing negative unit removes a symbol already present in the incomplete set, so it does not detect contract omissions.

Impact: a future or damaged provider archive can pass the architecture ABI report while lacking functions used for peer verification, identity selection, trust loading, SPKI pinning, certificate parsing, key validation, and security hashing. A later full link can catch some missing imports, but the M3-030 native-ABI qualification itself claims a completeness property it does not enforce. The frozen default AWS-LC archive is not shown to omit these functions.

Required remediation:

- Make the canonical contract cover every production native import, with each function classified as unconditional or tied to an explicit capability.
- Add a source-to-contract completeness check, or derive one side from a single canonical interface definition.
- Add negative tests for currently omitted security-critical functions, not only functions already known to the contract.
- Regenerate M3-030 ABI and release evidence and rerun M7-029 from a new frozen package.

### Reconfirmed prior Critical and High dispositions

The following prior blockers were reassessed against current source and remain **Fixed**: `WS-BUILD-001`, `WS-CI-001`, `WS-BUILD-002`, `WS-EVID-001`, `WS-GOV-001`, `WS-H2-SERVER-FLOW-001`, `WS-H2-SETTINGS-001`, `WS-H2-WRAP-001`, `WS-LIC-001`, `WS-PROXY-001`, `WS-RES-001`, `WS-RETRY-001`, `WS-STDNET-001`, and `WS-TLS-TRUST-001`.

The source and evidence now show a pinned canonical provider manifest; a clean Cangjie gate; both native archives in the CJPM hook; native/build freshness inputs; a recorded strict required-check ruleset; reserve-before-queue HTTP/2 flow accounting; split local and peer SETTINGS state; preserved declared-length completion; repository licensing; single-lease authenticated CONNECT; globally capped resolver quarantine; non-retryable ambiguous writes; cancellation-safe accept polling; and content-bound Linux trust/session partitioning.

No previously reported Critical or High finding was found to have regressed. The new High ABI-contract finding is independent of those remediations.

### Prior Medium dispositions

- Reconfirmed **Fixed**: `WS-H2-SETTINGS-002`, `WS-RES-002`, `WS-RES-003`.
- Reconfirmed **NotApplicable** after the accepted pre-1.0 public-surface decision: `WS-API-ALIAS-001`.
- Reconfirmed **Open Medium**: `WS-API-001`, `WS-CANCEL-001`, `WS-CI-SUPPLY-001`, `WS-H2-BUFFER-001`, `WS-IPV6-001`, `WS-TLS-KEY-001`, `WS-TLS-OWN-001`, `WS-EVID-002`.
- Reassessed but not retained as current M7-029 findings because the current tree bounds the relevant candidate sets, has later lifecycle cleanup, or the observation did not demonstrate material security impact at the current public boundary: `WS-CONN-001`, `WS-H2-BODY-001`, `WS-H2-DRAIN-001`, `WS-H2-WRITER-001`, `WS-POOL-001`, `WS-PR41-001`, `WS-TIME-001`, `WS-TLS-CLOSE-001`, `WS-TLS-LIFE-001`, `WS-TLS-PROFILE-001`, and `WS-TLS-SESSION-001`.

### Prior Low and advisory dispositions

`WS-CONN-002`, `WS-HTTP1-PERF-001`, `WS-RES-004`, `WS-STDNET-002`, `WS-STDNET-003`, and `WS-TLS-SOURCE-001` were reassessed as non-blocking Low observations. `WS-H1-CONNECT-001` remains advisory migration or API-completeness material rather than a release-blocking security defect.

## F. Commands and exact results

1. `sha256sum docs/security/review/linux-1.0/evidence-index.json`
   - Exit 0.
   - Exact digest: `912ac14704efbbd25353ff00bcbc69b0d788d87df3e733ec83d956b48eb95957`.

2. Read-only M7-028 package validation through `tools.m7_028_security_review_package.validate(...)`
   - Exit 0 on the corrected invocation.
   - `package_status=PASS`, `evidence_count=12`, `compatibility_gate=DISABLED_PRE_1_0`.
   - An earlier display-only invocation validated the package, then exited 1 because it attempted to print a nonexistent `packageSha256` report key. No input or output file was changed.

3. `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tools.tests.test_m3_030_tls_provider_architecture tools.tests.test_linux_tls_provider_build tools.tests.test_m7_029_independent_security_review tools.tests.test_m7_028_security_review_package -v`
   - Exit 1: 37 tests ran; 36 passed; one failed.
   - Failure: `test_provider_manifest_is_a_repository_input` expected Git exit 1 but received 128 because the process-isolated snapshot is not a Git repository. The manifest and selection tests themselves passed.

4. Production-import versus ABI-contract enumeration
   - Exit 0.
   - `production_foreign_symbols=55`, `abi_contract_symbols=40`, `missing_from_contract=15`.

5. Focused ABI-validator false-negative reproduction
   - Exit 0.
   - `validator_result=PASS`, `candidate_symbol_count=40`, `production_required_but_absent=wirestack_tls_engine_enable_peer_verification`, `false_negative_reproduced=true`.

6. `PYTHONDONTWRITEBYTECODE=1 python3 tools/architecture_guard.py --format json`
   - Exit 0.
   - `ok=true`, `violation_count=0`.
   - A preceding invocation used the unsupported `--json` spelling and exited 2 with argument-usage output; the corrected documented option passed.

7. `python3 tools/m7_029_independent_security_review.py --root ... --request ... --review ... --report ... --json`
   - Expected exit 1.
   - Validator result: `FAIL [REVIEW_NOT_PASS]` because the truthful review conclusion is `FAIL`.
   - The validator requires `conclusion == PASS` before it evaluates later review fields; this failure is the expected enforcement result for an unresolved High finding.

8. In-memory strict-schema probe using `validate_review(...)`
   - Exit 0 after changing only `conclusion` and the blocker severity in memory so the strict validator could traverse every remaining field.
   - `schema_probe=PASS`, `finding_count=9`, `open_count=9`.
   - The on-disk review was not changed; it remains truthful with `conclusion=FAIL` and `WS-NATIVE-ABI-001` at High severity.

No Cangjie command was rerun because builds and tests would write into the frozen repository. Existing Cangjie/native logs were inspected as evidence, not represented as newly executed results.

## G. Remaining risks and limitations

- The new High ABI-contract gap is unresolved and blocks M7-029.
- The one-hour SSE profile, 86,400-second soak, SDK builds, and non-Linux gates were prohibited and not run.
- The frozen evidence explicitly leaves the H2 producer-close race unresolved; no claim is made that it passed.
- M7-019, M7-020, M7-021, M7-024, and M7-025 remain stale after M7-032. M7-026 is historical evidence.
- The M3-030 release and SBOM validation records refer to an older M7-021 release identity; the referenced archive is not present in the snapshot.
- Remote GitHub protection and hosted-run state were not queried live; only the frozen evidence record was reviewed.
- The snapshot lacks Git metadata, preventing the Git-index-specific unit from exercising its intended repository state.
- This is a process-isolated agent review, not an organizationally independent external penetration test.
- The review did not fuzz native code anew, use sanitizers, inspect runtime memory with a debugger, or test hardware-backed key integrations.

## H. Suggested next READY task IDs

None should be advanced from this review. `M7-029` cannot complete while `WS-NATIVE-ABI-001` is open, and `M3-030` remains BLOCKED. Repair should remain within the approved M3-030 scope or a separately approved backlog task, then a new M7-029 frozen review package should be prepared and independently reviewed.
