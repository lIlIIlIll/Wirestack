# M7-029 independent security review summary

## A. Workspace safety

- Reviewed only `/tmp/wirestack-m3-030-final-review.1UwBFf/repo`.
- The snapshot has no `.git`, so branch, HEAD, merge base, and Git status are unavailable. Embedded M3-030 evidence identifies revision `38b58ec2fbaa0779011a70992e86ffc4bbd88e17`.
- Target package: `docs/security/review/linux-1.0/evidence-index.json`, SHA-256 `1c9e5a4d00fcba56bacbc0917bb2f7982e9dc7ca55ba80109aa81f7d805f88e9`, exactly matching `review-request.json`.
- Toolchain observed: Cangjie `1.1.0-alpha.20260817040003`, x86_64 Linux glibc; CJPM evidence records `1.1.3`.
- No product, documentation, task evidence, primary-workspace, SDK, runtime, std, or stdx file was changed. Python bytecode created by bounded imports was removed immediately, restoring the snapshot; the target digest remained unchanged. All retained outputs are under the assigned output directory.

## B. Task ID and status

- Review execution: **M7-029 COMPLETE**.
- Security verdict: **FAIL**.
- M3-030 remains **BLOCKED** as recorded in repository status.

The earlier High `WS-NATIVE-ABI-001` is Fixed, but new High `WS-NATIVE-ABI-002` is Open. The repository validator therefore rejects this review as non-PASS.

## C. Scope completed

- Read the PRD, all accepted ADRs, backlog and status, M7-028 review package and index, M7-029 request, validator, schema, and tests.
- Reviewed M3-030 manifest, provider contract, test plan, evidence index, task-check, native ABI report, selection and build tools, C header and provider implementation, Cangjie FFI declarations, provider-neutral TLS engine, HTTP integration, architecture guard, release packaging, SBOM, license, and supply-chain paths.
- Reassessed every prior Critical and High finding. All 14 prior M7-029 Critical/High findings remain Fixed. `WS-NATIVE-ABI-001` is now Fixed by complete 55-symbol coverage and fresh negative tests.
- Rechecked the known open Medium register and evidence staleness. These do not alter the High-based FAIL decision.

## D. Files changed

Only reviewer outputs were added:

- `independent-review.json`
- `review-summary.md`
- `review-validation.json`
- `abi-signature-negative.log`
- `bounded-tests.log`

## E. Acceptance criteria and evidence

| Criterion | Result | Evidence |
|---|---:|---|
| Review target matches request | PASS | Exact package path and SHA-256 match |
| Required scope and methods complete | PASS | Review JSON includes all 14 required scope entries and all required methods |
| Prior Critical/High reassessment | PASS | 2 Critical and 12 High findings remain Fixed with digest-bound regression paths |
| `WS-NATIVE-ABI-001` reassessment | Fixed | Fresh M3-030 task-check covers all 55 imports and missing-symbol negatives; SHA-256 `96ab08791dcd62d826e1bf6ae7f336d91fa1abdf0d8136e8f5a0156bfb4e8a2e` |
| Native ABI qualification fails closed | **FAIL** | `WS-NATIVE-ABI-002`: the contract and validators compare names only; an incompatible prototype preserves the symbol set and passes |
| M3 evidence integrity | PASS | 36 source bindings and 9 report bindings rehashed with zero mismatches |
| Review package integrity | PASS | 11 documents and 12 evidence rows validate; seven rows remain explicitly stale |
| Repository validator | **FAIL** | `REVIEW_NOT_PASS`, as required for the honest FAIL conclusion |

### Open High: WS-NATIVE-ABI-002

`abi-v1.json` records bare function names. `production_import_symbols` extracts names from Cangjie declarations, and `validate_symbol_set` compares those names with `nm` output. None of these checks encode parameter types, return types, pointer contracts, struct layout, or calling convention.

The bounded negative reproduction changed:

```text
foreign func wirestack_tls_provider_destroy(handle: UInt64): Unit
```

to:

```text
foreign func wirestack_tls_provider_destroy(handle: Int32): UInt64
```

The import set remained identical and symbol-set validation returned PASS. A provider with the matching symbol name but incompatible callable ABI can therefore pass qualification and be invoked through a mismatched FFI declaration. At a native TLS boundary, that can corrupt memory or provider state. The current AWS-LC shim includes the reviewed header and has current task evidence; the architectural gate remains incomplete for alternate or drifted provider archives.

## F. Commands and exact results

1. Combined bounded Python review suites: 70 tests, 69 passed, 1 failed, exit 1. The sole failure was environmental: `test_provider_manifest_is_a_repository_input` expected `git check-ignore` return 1, but the intentionally detached snapshot has no `.git` and returned 128.
2. M7-029 validator tests excluding only that `.git`-dependent case: 13 tests, 13 passed, exit 0.
3. Architecture guard: exit 0, `ok=true`, zero violations.
4. M3 evidence rehash: exit 0, 36/36 source bindings and 9/9 report bindings matched.
5. M7-028 package validation: exit 0, 11 documents and 12 evidence records valid.
6. ABI signature negative reproduction: exit 0, `false_negative_reproduced=true`.
7. Repository validator command:

```text
PYTHONDONTWRITEBYTECODE=1 python3 tools/m7_029_independent_security_review.py --root /tmp/wirestack-m3-030-final-review.1UwBFf/repo --request /tmp/wirestack-m3-030-final-review.1UwBFf/repo/docs/evidence/M7-029/review-request.json --review /tmp/wirestack-m3-030-final-review.1UwBFf/output/independent-review.json --report /tmp/wirestack-m3-030-final-review.1UwBFf/output/review-validation.json --json
```

Exact result: exit 1, `{"code":"REVIEW_NOT_PASS","detail":"FAIL","status":"FAIL","taskId":"M7-029"}`.

No SDK build, AWS-LC rebuild, Cangjie test rerun, one-hour SSE profile, 24-hour soak, or non-Linux platform run was performed. The current archive is absent from the frozen snapshot, and the included AWS-LC source reference lacks `.git`, which the canonical builder requires.

## G. Remaining risks and blockers

- High `WS-NATIVE-ABI-002` must be fixed before M7-029 can pass.
- The canonical ABI needs machine-validated callable signatures, not only names. A regression must mutate at least parameter width/type, return type, and calling convention and prove qualification fails before use.
- Seven final-candidate evidence rows remain stale after M7-032, including release, soak, performance, SBOM, provider-manifest, and fingerprint evidence.
- Existing Medium findings remain open: mutable ByteSpan backing storage, unbounded cancellation callback registry, ancillary CI mutability, HTTP/2 buffered-byte admission, IPv6 direct-factory inconsistency, private-key path TOCTOU, and caller-controlled context key lifetime.
- Remote GitHub state and the selected native archive were not independently observable in this frozen snapshot.

## H. Suggested next READY task IDs

No later READY task should start from this review. First create or select the backlog task that owns native ABI signature-contract hardening and its negative regression, then rerun M7-029 against a newly frozen candidate. M3-030 remains blocked until that review passes and its separately recorded M2-003 dependency is resolved.
