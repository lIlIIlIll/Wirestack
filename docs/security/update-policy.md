# Wirestack security update and rollback policy

This policy applies to the Linux x86_64 glibc release profile. It does not
claim support for another platform or TLS provider.

## Release identity

Every release candidate has three separately attested subjects:

- the exact `wirestack-<version>-linux-x86_64-glibc.tar.gz` artifact;
- the SPDX 2.3 SBOM generated for that artifact;
- the M7-030 release manifest that binds the artifact, SBOM, provider source,
  provider archive, build fingerprint, platform and signing policy.

The production workflow uses a GitHub-hosted runner and GitHub OIDC to obtain a
short-lived Sigstore signing identity. It does not store a long-lived release
private key in the repository. Verification requires the repository
`lIlIIlIll/Wirestack`, the workflow
`.github/workflows/linux-release-attestation.yml`, and rejection of
self-hosted-runner attestations.

The local OpenSSH Ed25519 path is an offline process rehearsal. Its private key
must be supplied from outside the repository and release output. Temporary keys
used by tests are labelled `REHEARSAL` and cannot satisfy the production gate.

## Provider update

A provider update is accepted only after all these checks pass:

1. The candidate uses the same provider identity as the installed release.
2. Its integer update sequence is greater than the installed sequence.
3. The candidate provider manifest digest and provider archive digest are
   explicit.
4. The updated SBOM contains the same provider version and archive digest.
5. A signed, unexpired security advisory binds the installed manifest, the
   candidate manifest and the updated SBOM digest.
6. The candidate release subjects pass signature or attestation verification.
7. Clean-consumer verification and safe extraction finish before installed
   state changes.

Provider version strings are descriptive. They are never parsed or ordered as
control flow. The explicit integer sequence prevents lexical version mistakes.
An unknown provider, missing document, stale digest, invalid signature or
inconsistent SBOM fails closed. There is no automatic provider fallback.

## Rollback

A lower update sequence is rejected by default. An emergency rollback requires
a separate signed, unexpired authorization. The authorization binds:

- the exact current and target sequences;
- the current and target provider-manifest digests;
- the target SBOM digest;
- the security advisory digest;
- its expiry time.

An authorization cannot be reused for another transition. Verification happens
before installation, so a failed rollback leaves the installed state unchanged.

## Security advisory handling

Advisories use stable IDs and one of `LOW`, `MEDIUM`, `HIGH`, or `CRITICAL`.
They record issue and expiry times, the exact transition digests, the updated
SBOM digest, and a bounded summary. The advisory is signed as canonical JSON.

Release maintainers publish the advisory, updated SBOM, release manifest,
artifact and attestations together. A withdrawn release keeps its advisory and
digests available so consumers can distinguish a deliberate rollback from an
unsigned downgrade.

## Verification commands

Run the local process rehearsal without a long-duration profile:

```sh
scripts/check-m7-030-release
```

Verify downloaded production attestations against the exact identity:

```sh
gh attestation verify wirestack-0.1.0-linux-x86_64-glibc.tar.gz \
  --repo lIlIIlIll/Wirestack \
  --signer-workflow .github/workflows/linux-release-attestation.yml \
  --predicate-type https://spdx.dev/Document/v2.3 \
  --deny-self-hosted-runners

gh attestation verify sbom.spdx.json \
  --repo lIlIIlIll/Wirestack \
  --signer-workflow .github/workflows/linux-release-attestation.yml \
  --deny-self-hosted-runners

gh attestation verify release-manifest.json \
  --repo lIlIIlIll/Wirestack \
  --signer-workflow .github/workflows/linux-release-attestation.yml \
  --deny-self-hosted-runners
```

Run the complete M7-030 task gate after the hosted report has been imported:

```sh
scripts/check-task M7-030
scripts/verify-evidence M7-030
```

Missing, skipped, timed-out or local-only production-attestation evidence is
not a pass.
