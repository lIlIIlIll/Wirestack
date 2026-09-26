# P1-016 — Keep the retired M7 Linux attestation workflow inert

The M7 release-attestation workflow remains as historical reference; M8-007 is the active signer. Its event configuration must be valid without enabling automatic runs or producing new attestations. Manual dispatch remains available only as a no-op, with both historical signing jobs disabled.

## Acceptance

- The workflow uses only `workflow_dispatch`; push and pull-request events do not start it.
- Both retained jobs are disabled, so the historical artifact is not re-attested.
- The frozen artifact, job bodies, permissions, and pinned actions remain unchanged.
- Task-manifest and acceptance-plan validation pass.
- Every workflow run associated with the exact latest candidate head succeeds. The retired workflow has no push-triggered run.
- No release, signature, or formal release qualification is created.

## Evidence

`verification.json` records local validator results and exact-head GitHub Actions run IDs and conclusions. `evidence.json` binds the required report to the source candidate using the repository evidence sealer.
