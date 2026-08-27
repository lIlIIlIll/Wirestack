# 2.0.0 evidence artifacts

This directory binds qualification, package rehearsal, general performance and
Native acceleration evidence to candidate source commit
`2d02b82ceb96e4ce170c09913a279f0963f5a212`.

- `logs/local-fresh-checkout.log.gz` is the complete Linux release-gate transcript.
- `logs/core-coverage.log.gz` records the unoptimized 521-case core coverage gate.
- `logs/package-rehearsal.log.gz` records the nine-package registry-style rehearsal.
- `logs/fuzz-extended.log.gz`, `logs/yyjson-colink.log.gz` and
  `logs/pure-windows-build.log.gz` record the extra gates.
- `packages/` contains nine unpublished 2.0.0 rehearsal artifacts.
- `performance/general/` contains the final 36-workload rerun and raw archive.
- `performance/native/` contains the final Native acceleration rerun and raw archive.

Run `sha256sum -c checksums.txt` in this directory to verify all stored evidence.
The full-result archives each contain their own portable checksum manifest.
