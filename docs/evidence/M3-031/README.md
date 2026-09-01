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
[`33459353992`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33459353992)
executed both jobs at repository revision
`88a0cd21216e4d0869fadd24bbd0c7f6185ddc73`:

- `windows-aws-lc` passed on Windows Server 2025 x86_64, image
  `win25-vs2026` version `20260824.214.3`.
- `macos-aws-lc` passed on macOS 15 arm64, image `macos15` version
  `20260727.0256.1`.
- Both native jobs built pinned AWS-LC 5.5.0 from commit
  `991e67ff4cf04df4dd89e407f8b920c6936cb56a`, executed the schema-v11 PoC,
  passed all 18 capabilities, completed two external-signing handshakes,
  proved TLS 1.2 and TLS 1.3 session resumption, and completed 10,000 cleanup
  cycles.
- Both binaries used vendored static provider archives and reported no system
  TLS dependency or runtime TLS-loader string.

The local task gate passed all four commands. The Python suites passed 105 tests.
The focused Cangjie Core suites passed 71 tests with zero skipped, failed or
errored cases. The complete machine-readable command report is
[`task-check.json`](task-check.json).

Run `33459353992` repeated both native jobs after the M0-016 schema-v11 review
remediation. The
committed hosted report binds that exact revision to the PoC source, provider
pins, validator digests, final binary digests, artifact digests and job
identities. Earlier schemas and pre-byte-preservation results remain listed
only as superseded history.

## Boundaries and remaining work

- The audit passes only the desktop-applicable Core projection. It records the
  six-platform target-build condition and mobile conditions as `NOT_EVALUATED`.
- Historical M3 task statuses are unchanged.
- M3-014, M3-015, M3-019 and M3-020 still own the production Windows/macOS
  trust and non-exportable-key adapters.
- No iOS device, Android device, HarmonyOS device, one-hour profile or 86,400
  second soak was run. None is an M3-031 acceptance command.

## Repository-wide gate

The final task report and repository check are regenerated only after all
review-remediation commits are present. Long-duration profiles are not part of
M3-031 and are not implicitly launched by the development gate.
