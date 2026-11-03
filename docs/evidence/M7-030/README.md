# M7-030 Linux signing and update flow

Status: **BLOCKED**

The latest recorded M7-030 task gate ran on candidate
`eb21fc4b29d31992a110487442df7bf1452a0792`, not this source snapshot. It
executed six commands: four passed, while `supply-chain-inputs` and
`github-hosted-attestations` failed. See [the recorded blockers](#current-blockers)
and [the candidate gate report](task-check-current-eb21fc4.json). No task gate
or test suite was run for this preparation; it removes two wiring-only
assertions, so the prior test result is not current acceptance. The seal in
`evidence.json` is stale and is not resealed here.

M7-030 has a fail-closed local signing and update rehearsal plus a pinned
GitHub OIDC/Sigstore workflow. The local gate signs the exact M7-021 artifact,
the M7-025 SBOM and a canonical release manifest with a temporary Ed25519 key;
verifies all three detached signatures; rejects subject and signature
tampering; safely extracts the artifact in a clean consumer; and rehearses a
signed provider upgrade and explicitly authorized rollback.

The local result remains classified `REHEARSAL`; it is not a production release
signature. GitHub-hosted run `33318194490` completed on merge commit
`8367a4eae8c4d46600dc1d20e571e9a3ddf5a493`. `github-attestation.json`
records three verified Sigstore subjects for the exact repository, workflow and
commit.

The hosted workflow does not rebuild the release artifact. It validates the
frozen M7-021 artifact and M7-025 supply-chain bundle before attestation, then
signs those exact reviewed bytes. Hosted run `33315568568` proved that a
compiler dependency can block signing before any attestation. Run
`33316074236` proved that rebuilding with another hosted toolchain produces an
artifact outside the frozen M7-025 digest. Both runs failed closed and produced
no attestation evidence. Run `33316521268` then proved that a clean source
checkout does not contain the intentionally ignored artifact, so validation
failed before attestation.

The frozen bytes now live in an unpublished, prerelease draft GitHub Release
under the exact staging tag `m7-030-frozen-artifact-c0988f62`. The workflow
downloads that one asset, checks SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`,
and only then validates the M7-025 supply-chain bundle. The tag is a transport
locator for hosted attestation, not a public or stable release.

Run `33317478966` showed that a `contents: read` Actions token cannot resolve
the draft tag. The final workflow isolates that privilege: a staging job has
`contents: write` but no OIDC or attestation permission; the signing job has
OIDC and `contents: read` but no contents write. Both jobs verify the same fixed
artifact digest around a one-day GitHub Actions artifact transfer.

Run `33317831996` then downloaded and transferred the frozen bytes, validated
M7-025, and created all three attestations. Its first verification failed
because `--signer-workflow` used a relative path. Offline verification of the
published artifact bundle passed after binding the full identity
`lIlIIlIll/Wirestack/.github/workflows/linux-release-attestation.yml`.

## Bound inputs

- artifact:
  `c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`;
- SPDX SBOM:
  `49df6442eaceb13f413c9b5b330b3855eee559c896532d30eb6de5d4e892bc6c`;
- provider manifest:
  `1576f659b5a95763b8827a3f5468ab8b08c910509877a44d9b1b2c90aed7c016`;
- build fingerprint:
  `67dcd09f0ab99a33cfb204fb5f2a133a911f8f706ccf85a7a3312b980ddac9d9`.

## Evidence

- [`test-plan.md`](test-plan.md) defines 27 paths, 24 scenarios and 20 tests.
- `draft-release.json` binds the unpublished staging release and frozen asset.
- `local-rehearsal.json` records local signing, clean-consumer, update and
  rollback results without private key material.
- `workflow-contract.json` records the pinned hosted workflow contract.
- `github-attestation.json` is the byte-identical bounded report downloaded from
  successful GitHub-hosted run `33318194490`.
- `hosted-validation.json` binds that report digest and its three subjects.
- [`test-results.md`](test-results.md) records exact local commands and the
  remaining production gate.

No one-hour SSE profile, 86,400-second soak, SDK build or non-Linux gate is part
of M7-030. The completed M7-022 run remains the final artifact soak evidence.

## Frozen artifact prerequisite

`tools/m7_030_linux_release.py` no longer trusts whatever happens to sit in the
Git-ignored `dist/m7-021` directory. `verify_frozen_artifact` requires the exact
asset name `wirestack-0.1.0-linux-x86_64-glibc.tar.gz`, 2,499,451 bytes and
SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`, and
`build_release_manifest` refuses to proceed without that prerequisite. When the
bytes are absent, `fetch-frozen-artifact` retrieves them from the single pinned
draft-Release tag `m7-030-frozen-artifact-c0988f62` — no `--latest` fallback —
verifies them, and only then publishes the file. A failed download or a digest
mismatch publishes nothing. `scripts/check-m7-030-release` stages its receipt
under the Git-ignored `build/m7-030/` work directory before rehearsing, so a
clean checkout either reproduces the exact reviewed bytes or fails closed with
`FROZEN_ASSET_NAME`, `FROZEN_ASSET_MISSING`, `FROZEN_ASSET_SIZE`,
`FROZEN_ASSET_DIGEST` or `FROZEN_ASSET_DOWNLOAD`. The canonical gate never
targets `docs/evidence/M7-030/frozen-artifact.json`; the fetch command writes a
receipt only after the asset passes its name, size and digest checks, so a
failed staging run cannot replace the committed PASS receipt. That receipt was
copied unchanged from PR #305 and records `"mode": "verified-existing-artifact"`
from an earlier verification of an already staged artifact. No `dist/m7-021`
asset was restored or qualified in that earlier preparation; the copied receipt is
historical, not current artifact qualification. It remains bound in the task
manifest's `source_paths`, so deleting or tampering with it invalidates a source
seal. It is an input receipt, not a required PASS-status report. Current fetch
maintenance evidence is recorded separately below.

`validate-hosted --output` follows the same success-only receipt rule. It writes
a PASS validation record only after all hosted subjects verify; on FAIL or
BLOCKED it emits the structured result without replacing the existing
`hosted-validation.json`.

## Recorded blockers and prerequisites

1. `supply-chain-inputs` — the recorded clean-checkout task gate failed first
   with `release artifact is absent`, because ignored `dist/m7-021` was absent.
   The recorded local rehearsal later downloaded and verified the pinned
   2,499,451-byte asset into ignored `build/m7-030/`. With that exact asset
   staged under `dist/m7-021`, `scripts/generate-m7-025-linux-supply-chain --validate-only`
   reports the stale M7-025 generator fingerprint (`42e064cf…` recorded,
   `b7a15290…` current). M11-002 commit `0a3161e5` changed the generator after
   the M7-025 evidence was frozen; regenerating that bundle is outside this
   task's `allowed_paths`.
2. `github-hosted-attestations` — the retained validation report records exit 1
   with `HOSTED_REPORT_SUBJECT` and
   `expected ['bundleSha256','name','sha256','signedPayloadSha256','verification'],
   got ['bundleSha256','name','sha256','verification']`. The committed report was
   produced on 2026-08-30 (commit `76ae46a5`) before commit `29ce6790`
   (2026-09-01) added the `signedPayloadSha256` subject field. Producing a
   conforming report requires a GitHub-hosted OIDC/Sigstore run.
   `.github/workflows/linux-release-attestation.yml` is intentionally retired —
   `on: workflow_dispatch` with an explicit no-op and M8-007 is the active
   signer — so this task must not reactivate it or mint new attestations.
3. `check-task` — candidate `eb21fc4b29d31992a110487442df7bf1452a0792`
   was tested from a clean archive export with `dist/` absent. The
   `scripts/check-task M7-030 --json --output
   build/m7-030/task-check-current-stacked.json` command exited 1 after all six
   acceptance commands: four passed and two failed, with `issues: []`. The
   path-redacted [task-gate report](task-check-current-eb21fc4.json) records
   the exact command statuses. The local rehearsal downloaded and verified
   the pinned asset and passed as `REHEARSAL`; `productionAttestation` remains
   `FAIL`. Repository-wide readiness additionally reports
   `DEPENDENCY_INCOMPLETE` on the unrelated `M10-004 → M10-003` edge;
   M7-030's own dependencies M7-022, M7-025 and M7-029 are COMPLETE.
4. Downstream, this row is the only dependency M7-031 has on a non-COMPLETE
   task, so the BLOCKED classification propagates. This task does not edit
   M7-031's row, tooling or evidence — that is M7-031's own scope — but the
   consequence is recorded here rather than left implicit:
   `scripts/check-m7-031-release` stops at
   `DEPENDENCY_INCOMPLETE: M7-030` because
   `tools/m7_031_linux_candidate.py::validate_dependency_status` requires
   `| M7-030 | COMPLETE |` in `docs/planning/status.md`. The unit-discovery
   failure was fixed separately in draft PR #239:
   `python3 -m unittest tools.tests.test_m7_031_linux_candidate -v` passes four
   dependency-readiness tests and skips the `M7031LinuxCandidateTests` class
   with `M7-031 prerequisites are not COMPLETE: M7-030`; its fifteen candidate
   methods do not run. The base gate already failed with
   `DIGEST_INVALID: M7-030 artifact signed payload`, so M7-031's COMPLETE claim
   was not supported by its own gate even before this reclassification.
   `scripts/verify-evidence --task M7-031` reports the same
   `DEPENDENCY_INCOMPLETE: M7-030`.

In the recorded candidate run, `local-signing-update-rehearsal` and
`hosted-workflow-contract` passed with the frozen-artifact prerequisite in
place, and the rehearsal recorded the hosted-attestation blocker as
`productionAttestation: {"decision": "FAIL", "detail": "HOSTED_REPORT_SUBJECT"}`
rather than inheriting the historical PASS.

The recorded task gate staged the frozen receipt under ignored `build/m7-030/`;
`validate-workflow` and the local rehearsal wrote their configured reports.
`validate-hosted --output` writes only after successful validation. In that
recorded run, the `HOSTED_REPORT_SUBJECT` failure left the existing
`hosted-validation.json` byte-identical; its 2026-08-30 PASS remains historical
and is not promoted to current acceptance.

## Current blocker maintenance

The hermetic suite ran 21 tests successfully with no skips, errors or failures.
It does not require a retained release archive or network access.
The explicit `fetch-frozen-artifact` CLI separately downloaded and verified
the exact pinned asset: 2,499,451 bytes with SHA-256
`c0988f62eb657c465a928825573e41e2eb2675241240312bc2228482cbafc9ee`.
The current receipt is retained separately as
[`blocker-maintenance/frozen-artifact-current.json`](blocker-maintenance/frozen-artifact-current.json).

[`blocker-maintenance/regression.json`](blocker-maintenance/regression.json)
binds the fixture source and initial/final regression logs. No signer was
enabled, no artifact was regenerated or re-signed, and this verification does
not establish current M7-030 release qualification. M7-030 remains BLOCKED.
