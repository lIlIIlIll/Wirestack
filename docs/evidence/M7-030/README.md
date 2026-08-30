# M7-030 Linux signing and update flow

Status: **INCOMPLETE**

M7-030 now has a fail-closed local signing and update rehearsal plus a pinned
GitHub OIDC/Sigstore workflow. The local gate signs the exact M7-021 artifact,
the M7-025 SBOM and a canonical release manifest with a temporary Ed25519 key;
verifies all three detached signatures; rejects subject and signature
tampering; safely extracts the artifact in a clean consumer; and rehearses a
signed provider upgrade and explicitly authorized rollback.

The local result is classified `REHEARSAL`. It is not a production release
signature. M7-030 remains incomplete until
`.github/workflows/linux-release-attestation.yml` runs on a GitHub-hosted runner
and `github-attestation.json` records three verified Sigstore subjects for the
exact repository, workflow and commit.

The hosted workflow does not rebuild the release artifact. It validates the
frozen M7-021 artifact and M7-025 supply-chain bundle before attestation, then
signs those exact reviewed bytes. Hosted run `33315568568` proved that a
compiler dependency can block signing before any attestation. Run
`33316074236` proved that rebuilding with another hosted toolchain produces an
artifact outside the frozen M7-025 digest. Both runs failed closed and produced
no attestation evidence.

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

- [`test-plan.md`](test-plan.md) defines 23 paths, 20 scenarios and 16 tests.
- `local-rehearsal.json` records local signing, clean-consumer, update and
  rollback results without private key material.
- `workflow-contract.json` records the pinned hosted workflow contract.
- `github-attestation.json` is intentionally absent until the hosted workflow
  succeeds.
- [`test-results.md`](test-results.md) records exact local commands and the
  remaining production gate.

No one-hour SSE profile, 86,400-second soak, SDK build or non-Linux gate is part
of M7-030. The completed M7-022 run remains the final artifact soak evidence.
