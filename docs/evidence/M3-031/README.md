# M3-031 desktop TLS adoption evidence

## Status

COMPLETE

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

## Required evidence

- `core-prerequisite-audit.json`
- `windows-x86_64/provider-result.json`
- `windows-x86_64/validation.json`
- `macos-arm64/provider-result.json`
- `macos-arm64/validation.json`
- `desktop-provider-matrix.json`
- `hosted-run.json`
- `task-check.json`
- `evidence.json`

## Acceptance result

GitHub Actions run
[`33346040908`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33346040908)
executed both jobs at repository revision
`787a6210a245e8cb65757ef2f639db20ca3e2025`:

- `windows-aws-lc` passed on Windows Server 2025 x86_64, image
  `win25-vs2026` version `20260824.214.3`.
- `macos-aws-lc` passed on macOS 15 arm64, image `macos15` version
  `20260727.0256.1`.
- Both native jobs built pinned AWS-LC 5.5.0 from commit
  `991e67ff4cf04df4dd89e407f8b920c6936cb56a`, executed the schema-v2 PoC,
  passed all 14 capabilities, completed two external-signing handshakes and
  completed 10,000 cleanup cycles.
- Both binaries used vendored static provider archives and reported no system
  TLS dependency or runtime TLS-loader string.

The local task gate passed all four commands. The Python suites passed 46 tests.
The focused Cangjie Core suites passed 71 tests with zero skipped, failed or
errored cases. The complete machine-readable command report is
[`task-check.json`](task-check.json).

The first hosted run, `33344864914`, failed before a provider build because the
independent M3-031 branch omitted the in-flight M0-016 PoC implementation. The
GitButler stack was corrected without changing M2 commit identities. That run
is retained as a superseded failure in [`hosted-run.json`](hosted-run.json), not
as acceptance evidence. The first successful run, `33345515063`, was then
superseded because the source and evidence commit changed the repository
revision. Run `33346040908` repeated both native jobs at the final source
revision and is the sole acceptance run.

## Boundaries and remaining work

- The audit passes only the desktop-applicable Core projection. It records the
  six-platform target-build condition and mobile conditions as `NOT_EVALUATED`.
- Historical M3 task statuses are unchanged.
- M3-014, M3-015, M3-019 and M3-020 still own the production Windows/macOS
  trust and non-exportable-key adapters.
- No iOS device, Android device, HarmonyOS device, one-hour profile or 86,400
  second soak was run. None is an M3-031 acceptance command.

## Repository-wide gate

The final `scripts/check` invocation returned exit code 1. Its first suite ran
227 Python tests and reported nine failures and four errors before the script
stopped. The M3-031 tests themselves passed. The failures show that the new
backlog/source state correctly invalidates the prior M7-019, M7-020, M7-021 and
M7-031 Linux audit/release snapshots; the M7-029 build-selection assertion also
still assumes Darwin is unsupported even though the applied M2-006 branch adds
the Apple resolver. `scripts/check` additionally reported
`SOAK_ALREADY_RUNNING` when it attempted to start another M7-022 invocation.

M3-031 does not refresh or relabel those earlier release tasks. A later release
candidate requalification must regenerate their evidence against the final
source tree. The running soak was not stopped or duplicated by this task.
