# M7-029 process-isolated security review

## Decision

PASS for the exact M7-028 review package SHA-256 `9d4c4676cd52883aa002e20946b474ac2777d7fcee2bcfe9c232436c44aeaf82`.

The two preserved native-ABI High findings are Fixed:

- `WS-NATIVE-ABI-001`: the ABI contract now covers every production Cangjie TLS import, requires an equal signature inventory, and rejects a selected archive missing a required symbol.
- `WS-NATIVE-ABI-002`: the contract now fixes parameter types, return types, and the C calling convention; validation rejects drift at both the Cangjie declaration boundary and the native-header boundary.

All preserved Critical and High findings included in this review are Fixed. No new Critical or High issue was identified. `WS-EVID-002` remains Medium/Open because final-candidate release, SBOM, and long-profile evidence has not been regenerated; the M7-028 index explicitly marks that material stale or historical and non-gating.

## Independent ABI mutation results

| Mutation | Result | Stable rejection |
| --- | --- | --- |
| Cangjie parameter and return types | Rejected | `abi-signature-mismatch` |
| Native header parameter and return types | Rejected | `native-abi-signature-mismatch` |
| ABI contract schema | Rejected | `abi-version-mismatch` |
| ABI calling convention | Rejected | `abi-calling-convention-mismatch` |
| Signature inventory member | Rejected | `abi-signature-inventory-mismatch` |
| Required archive symbol | Rejected | `abi-function-missing` |

The positive header probe passed. The current ABI contract digest is `4f6756852e89203938ab964461993edde8dccc220bab7e5f8862e4f2b8bb3943`. The Linux provider build inputs bind that digest; changing only the ABI contract changes the provider build fingerprint. Release fingerprint inputs bind the provider archive digest, embedded provider manifest digest, and provider build fingerprint, so ABI contract drift propagates into release identity.

## Bounded execution

- `PYTHONDONTWRITEBYTECODE=1 python3 tools/architecture_guard.py --root . --format json` — exit 0, `ok=true`, zero violations.
- Corrected M7-028 package validation using an absolute snapshot root — exit 0, PASS, 11 documents, 12 evidence rows, states `CURRENT_PASS=4`, `STALE_AFTER_M7_032=7`, `HISTORICAL_NON_GATING=1`.
- Focused Python suite covering M3-030 ABI, provider build, M7-021 release, M7-025 supply chain, and M7-029 validator — exit 1, 50 tests, 49 passed, one isolation-layout failure. `test_provider_manifest_is_a_repository_input` expected `git check-ignore` to fail outside a repository, but this immutable snapshot is nested below the primary repository and Git discovered the parent worktree. All requested ABI mutation, release-fingerprint, SBOM, and validator tests passed. This run is not claimed as an overall PASS.
- Independent temporary-copy mutation harness — exit 0; all six requested negative mutation classes rejected and both provider/release fingerprint propagation checks passed.
- Independent temporary archive with `wirestack_tls_engine_enable_peer_verification` omitted — exit 0; validator rejected it with `abi-function-missing`.

No SDK build, provider rebuild, one-hour SSE profile, 24-hour soak, or non-Linux execution was performed. No snapshot or primary-workspace file was modified.
