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

The following files preserve the historical acceptance run and its exact
artifacts:

- `core-prerequisite-audit.json`
- `windows-x86_64/provider-result.json`
- `windows-x86_64/validation.json`
- `windows-x86_64/license-bundle/manifest.json` and its 11 digest-bound files
- `macos-arm64/provider-result.json`
- `macos-arm64/validation.json`
- `macos-arm64/license-bundle/manifest.json` and its 11 digest-bound files
- `desktop-provider-matrix.json`
- `hosted-run.json`
- `task-check.json`
- `evidence.json`

`hosted-run.json`, `desktop-provider-matrix.json`, `task-check.json`, and
`evidence.json` record the historical PASS at revision
`6c683a51b782d6fd0a10b11c59cb75d9bc9a99d2`. Their PASS fields do not establish
current M3-031 acceptance.

`requalification-blocker-2026-10-22.json` records the current source-bound gate
failure.

## Current status and blocker

The historical GitHub Actions run
[`33461712135`](https://github.com/lIlIIlIll/Wirestack/actions/runs/33461712135)
passed both native jobs at revision
`6c683a51b782d6fd0a10b11c59cb75d9bc9a99d2`. Windows Server 2025 x86_64 and
macOS 15 arm64 each passed all 18 schema-v11 capabilities with AWS-LC 5.5.0.
Those results remain valid for the provider inputs they tested.

M0-016 advisory review PR #236 changes the current
`tools/tls_provider_poc/providers.json` input. The historical run binds SHA-256
`600c43738c311f0b7d31f08dbaf66e43ee04155f4b7fb550dd3ed7842429d429`; the
current file at the reviewed M0-016 commit binds
`bdd5bdc65132bdedd41ce2e0120cb12770963acea7144a3559b9f118511bdc1e`.
ADR-0007 requires both native provider jobs to be rerun when a provider source
input changes.

Current command `scripts/check-m3-031-desktop-tls-adoption` exits 1 with
`STALE_SOURCE: hosted provider inputs differ from retained run`. The complete
observed result is recorded in
[`requalification-blocker-2026-10-22.json`](requalification-blocker-2026-10-22.json).
No fresh Windows or macOS hosted job was launched; the retained PASS results
are not promoted to current acceptance.

## Boundaries and remaining work

- The audit passes only the desktop-applicable Core projection. It records the
  six-platform target-build condition and mobile conditions as `NOT_EVALUATED`.
- Historical M3 task statuses are unchanged.
- M3-014, M3-015, M3-019 and M3-020 still own the production Windows/macOS
  trust and non-exportable-key adapters.
- No iOS device, Android device, HarmonyOS device, one-hour profile or 86,400
  second soak was run. None is an M3-031 acceptance command.

## Current verification

The stored `task-check.json` describes the historical run only. The current
M3-031 task gate is blocked at hosted-input validation until both native
provider jobs are rerun against the reviewed source revision.
