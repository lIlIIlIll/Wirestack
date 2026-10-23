# M3-031 desktop TLS adoption evidence

## Status

BLOCKED

## Scope

M3-031 maps the desktop-applicable portion of the already implemented
provider-neutral TLS Core contract and reruns pinned AWS-LC 5.5.0 on native
Windows x86_64 and macOS arm64 GitHub runners at one exact repository revision.

This scoped projection does not complete the historical global M3 tasks.
M3-001's six-platform target-build condition and all mobile conditions remain
unproven under their existing task IDs; the audit records them as excluded,
never as PASS.

This task does not implement Windows system trust, macOS system trust, Windows
key handles or Apple Keychain/SecKey. It does not change any mobile task or
claim mobile device support.

## Retained evidence

The historical acceptance records remain available:

- `historical-acceptance-evidence.json` preserves the former PASS index.
- `task-check.json`, `core-prerequisite-audit.json`, and
  `desktop-provider-matrix.json` describe the September 1, 2026 historical run
  at revision `6c683a51b782d6fd0a10b11c59cb75d9bc9a99d2`.
- `requalification-blocker-2026-10-22.json` records why that earlier hosted
  receipt was stale; it is not the current blocker.

The refreshed native run and current source-bound checks are recorded in:

- `hosted-run.json`
- `windows-x86_64/provider-result.json` and `validation.json`
- `windows-x86_64/license-bundle/manifest.json` and its 11 digest-bound files
- `macos-arm64/provider-result.json` and `validation.json`
- `macos-arm64/license-bundle/manifest.json` and its 11 digest-bound files
- `windows-validation-f5cb82.json`
- `macos-validation-f5cb82.json`
- `task-check-current-f5cb82.json`
- `core-prerequisite-audit-current-f5cb82.json`
- `current-verification-f5cb82.json`

`evidence.json` remains a schema-v2 `BLOCKED` index. The current native
provider receipts do not imply full task acceptance or a PASS seal.

## Current hosted and local status

GitHub Actions run
[`40005174235`](https://github.com/lIlIIlIll/Wirestack/actions/runs/40005174235)
passed both native provider jobs at revision
`f5cb82cdc780bef905f436435470952a1a1acbb5`. Windows x86_64 and macOS arm64
each report all 18 AWS-LC 5.5.0 capabilities PASS, 10,000 cleanup cycles, and
two external signer calls. The hosted-run validator and both retained provider
receipt validators pass for this exact revision.

The task is still blocked by repository-level acceptance:

- `scripts/check-m3-031-desktop-tls-adoption` exits 1 with
  `RETAINED_EVIDENCE`: `docs/evidence/M3-030/linux-aws-lc-results.json` has
  invalid report semantics. The current M3-031 Windows/macOS receipts validate,
  but the aggregate gate cannot pass its M3-030 prerequisite audit.
- `scripts/check-task M3-031 --json` exits 2 with `INVALID` before executing
  commands because M10-004 is recorded COMPLETE while M10-003 is BLOCKED.
- The exact Python acceptance suite runs 114 tests: 113 pass and
  `test_evolution_status_matches_readiness_classification` fails on that same
  M10-004/M10-003 status contradiction.
- The provider-neutral TLS/trust Cangjie suite passes 83/83; this does not
  override the failed Python suite or invalid task preflight.

Exact current results and source identities are in
[`current-verification-f5cb82.json`](current-verification-f5cb82.json). No full
M3-031 task acceptance or PASS seal is claimed.

## Boundaries and remaining work

- The audit covers only the desktop-applicable Core projection. Six-platform
  target-build and mobile conditions remain `NOT_EVALUATED`.
- M3-014, M3-015, M3-019 and M3-020 still own the production Windows/macOS
  trust and non-exportable-key adapters.
- No iOS, Android, or HarmonyOS device, one-hour profile, or 86,400-second soak
  was run; none is an M3-031 acceptance command.
- Restore full task acceptance only after the M3-030 retained evidence and the
  M10-004/M10-003 dependency-status blockers are corrected by their owners.

## Current verification

| Check | Result |
|---|---|
| Test-plan matrix | PASS: 17 paths, 16 scenarios, 17 tests |
| Desktop adoption/provider Python suite | FAIL: 113/114 |
| Hosted/provider receipt validators | PASS: Windows x86_64 and macOS arm64 at `f5cb82cdc780bef905f436435470952a1a1acbb5` |
| Stored desktop-provider aggregate | FAIL: invalid retained M3-030 report semantics |
| Task gate | INVALID before commands: M10-004 depends on BLOCKED M10-003 |
| Provider-neutral TLS/trust Cangjie tests | PASS: 83/83 |

`task-check.json` is historical. The current preflight result is
[`task-check-current-f5cb82.json`](task-check-current-f5cb82.json).
