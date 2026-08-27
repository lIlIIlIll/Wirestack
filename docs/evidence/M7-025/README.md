# M7-025 Linux supply-chain metadata

Status: **COMPLETE**

Decision: **PASS**

M7-025 binds the Linux x86_64 glibc release artifact to a provider manifest,
an SPDX 2.3 SBOM, and a deterministic release build fingerprint. The generator
fails closed when the artifact, provider pin, embedded native manifests, or
committed sidecars disagree.

## Qualified artifact

| Field | Result |
|---|---|
| Name | `wirestack-0.1.0-linux-x86_64-glibc.tar.gz` |
| Size | 2,474,219 bytes |
| SHA-256 | `55aec28b201b3481e85b647eee0f180f3f0ca0677b098f866b385a8e6a9bba55` |
| Payload SHA-256 | `44a2127078e1f0c57c5406caff995b72892bf78e60ada57ded972df7b1d7bfbc` |
| Release build fingerprint | `28b90d6545ad0d91bdc387604c67d7337cbb9ca18c7ccec48debe281a3ddf618` |

The release fingerprint uses canonical JSON and SHA-256. Its inputs include
the artifact and payload digests, target and toolchain identity, feature and
capability inventories, trust policy, provider source and archive digests,
resolver archive and build fingerprints, and the generator digest. Unit tests
prove that identical inputs are stable and that changes to each native
dependency digest or fingerprint change the result.

## Release sidecars

| Document | SHA-256 | Purpose |
|---|---|---|
| [`provider-manifest.json`](linux_x86_64/provider-manifest.json) | `8d683aed9bbc52bd7d2b2e21afc21254f8d7b62fd81acce563add3647bb23834` | Provider, crypto, trust, capability, patch-level, target, feature, resolver, and runtime dependency inventory |
| [`sbom.spdx.json`](linux_x86_64/sbom.spdx.json) | `f793eb6466cf172629023e0b0eab5559a3d138e2a3d1c71ed5d72e90743d96d0` | SPDX 2.3 package inventory and containment/dependency relationships |
| [`build-fingerprint.json`](linux_x86_64/build-fingerprint.json) | `1ef0f6bba8ca5f9e544b591fb621f3df80747013d3e3b0f6af5392118a7e57ca` | Canonical fingerprint inputs and result |
| [`bundle.json`](linux_x86_64/bundle.json) | `6c85777c124675adc21ad4244a986979368d3c4930290250fe8a9c9eb37ea148` | PASS decision and sidecar digests |

The SBOM marks AWS-LC and the bounded native resolver bridge as contained in
the artifact. It records the Cangjie runtime, glibc, libstdc++, and libgcc as
runtime environment dependencies that are not bundled. Wirestack has no
repository license declaration, so Wirestack-owned packages use
`NOASSERTION`; the pinned AWS-LC package records `Apache-2.0 OR ISC`.

## Upstream boundary

The installed executable needs the released Cangjie runtime and system
libraries. This ordinary runtime dependency does not mean that Wirestack needs
changes to runtime, `std`, or `std.net` source. The Linux release uses only the
current public SDK surface and Wirestack-owned fallbacks.

Possible runtime or `std.net` improvements remain optional long-term upstream
requirements. They are tracked separately and do not block Wirestack build,
test, packaging, or release. M7-025 did not modify or build the Cangjie SDK,
runtime, or standard library.

## Repeat the gate

Generate and validate the sidecars against the local qualified artifact:

```shell
scripts/generate-m7-025-linux-supply-chain
```

Validate a clean checkout where the ignored release artifact is absent:

```shell
scripts/generate-m7-025-linux-supply-chain \
  --validate-only \
  --allow-missing-artifact
```

When the artifact exists, validation rebuilds all sidecars in memory and
requires byte-equivalent JSON. Without it, validation still verifies the
committed fingerprint, provider pin, SBOM inventory and relationships, bundle
digests, generator digest, and absence of host-local or sensitive values.

## Verification results

| Command | Result |
|---|---|
| `python3 -m py_compile tools/m7_025_linux_supply_chain.py tools/tests/test_m7_025_linux_supply_chain.py` | PASS |
| `scripts/generate-m7-025-linux-supply-chain` | PASS |
| `python3 -m unittest tools.tests.test_m7_025_linux_supply_chain -v` | 4 passed |
| `scripts/generate-m7-025-linux-supply-chain --validate-only` | PASS against the qualified artifact |
| `scripts/generate-m7-025-linux-supply-chain --validate-only --artifact /tmp/wirestack-m7-025-no-artifact.tar.gz --allow-missing-artifact` | PASS without the ignored artifact |
| Python repository tests invoked by `scripts/check` | 93 passed |
| Gate-runner tests invoked by `scripts/check` | 118 passed |
| Benchmark-tool tests invoked by `scripts/check` | 23 passed |
| Architecture guard, `cjpm check`, and `cjpm build` invoked by `scripts/check` | PASS |
| `cjpm test --exclude-tags Performance --no-progress` | 552 passed, 22 skipped, 0 failed |

One earlier combined `scripts/check` run hit a single timing failure in
`Http1ServerTest.expiredShutdownAbortsBlockedConnectionAndReturnsBoundedly`.
The exact case then passed 1/1 in isolation, and the complete formal
non-Performance set passed on the final run. No product code changed during
that triage. A raw `cjpm test` run is not a formal result because it includes
five Performance profiles that require their dedicated gate environments.

## Evidence boundary

This evidence applies only to Linux x86_64 glibc. The artifact and sidecars are
unsigned; M7-030 owns signing and update-flow evidence. This task does not
claim the M7-022 soak, non-Linux packaging, an upstream runtime/std change, or
a Wirestack license that the repository does not declare.
