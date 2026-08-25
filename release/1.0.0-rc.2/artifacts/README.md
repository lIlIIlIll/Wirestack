# 1.0.0-rc.2 evidence artifacts

This directory binds qualification, package rehearsal and performance evidence to
candidate source commit `15d264c34123ff2624572d946c55c7395ccd7fe9`.

- `logs/local-fresh-checkout.log.gz` is the complete Linux release-gate transcript.
- `logs/package-rehearsal.log` records the six-package registry-style rehearsal.
- `packages/` contains the six unpublished rehearsal artifacts.
- `performance/summary.*`, `metadata.json` and `manifest.csv` are directly inspectable.
- `performance/full-result.tar.gz` contains all 11-round raw samples and command logs.

Verify the top-level files from this directory with `sha256sum -c checksums.txt`.
After extracting `performance/full-result.tar.gz`, run `sha256sum -c checksums.txt`
inside the extracted result directory to verify its portable internal manifest.
