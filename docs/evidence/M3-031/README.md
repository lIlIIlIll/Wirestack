# M3-031 desktop TLS adoption evidence

## Status

IN_PROGRESS

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

## Current state

The test plan and hosted workflow are being prepared. No hosted result has been
recorded as PASS yet.
