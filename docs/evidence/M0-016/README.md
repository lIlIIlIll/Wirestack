# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** only at the full cross-platform task level. All 12
desktop schema-v11 cells are current: AWS-LC passes on Linux glibc, Linux musl,
Windows and macOS; Mbed TLS and OpenSSL retain explicit PARTIAL results for
unsupported capabilities. Android, iOS, and HarmonyOS or OpenHarmony still
lack native-device evidence; cross-compilation does not satisfy those cells.

Schema v11 retains all prior native evidence plus the exact successful NASM
identity for a Windows AWS-LC build. Its workflow fallback is pinned to
Chocolatey package `nasm` 2.16.3. The current hosted image supplied NASM
2.16.01; the retained result records its version output and SHA-256
`547d4edd4b1d6fea2504990e70263b5ce06cfe7ab894483f6c54e60c1bd93b60`.
Hosted runs use the read-only Actions token only for bounded GitHub API tag
resolution; it is excluded from logs, retained results, and build provenance.
Schema v11 also retains:

- monotonic cancellation and join deadlines that are unaffected by wall-clock
  changes;
- a fresh advisory review timestamp, exact pin commit, reviewed advisory IDs,
  affected subset, and an explicit affected/not-affected disposition; and
- the exact security-update object in every successful result.
- exact source-kind and source-identity agreement with the provider pin;
- bounded, sorted and digest-bound static-archive inventories for builds and
  supported native diagnostics;
- distinct TLS 1.2 and TLS 1.3 local-close execution; and
- fail-closed PARTIAL semantics that reject `NOT_RUN` and require at least one
  explicit `BLOCKED` capability.

The complete evidence set includes:

- required and optional client authentication;
- negative certificate, hostname, trust, and ALPN cases;
- exact repository, runner, toolchain, target, configure/build argv, bounded
  effective build environment, patch-set, source, and archive identity;
- complete bounded final-artifact symbol inventories;
- committed, digest-bound provider license bundles;
- 10,000-cycle resident-memory, provider allocation-call, cumulative-byte,
  peak-live and before/after-cleanup live-allocation profiles;
- an explicit caller-owned wait, cancellation signal, wakeup, join, and
  latency bound covering the complete join;
- source-pin ages, official advisory channels and the provider update
  workflow; and
- provider-instrumented ASan and UBSan diagnostics on Linux glibc and macOS.

Linux glibc Mbed TLS also passes LeakSanitizer. AWS-LC and static OpenSSL
record leak detection as unsupported because their process-global allocations
cannot be separated from provider-cycle leaks by this harness. macOS records
LeakSanitizer as unsupported by the hosted toolchain. Linux musl and Windows
record the configured sanitizer diagnostic as unsupported; they do not report
a skipped diagnostic as PASS.

## Current schema-v11 desktop runs

[TLS Provider PoC run
33446915140](https://github.com/lIlIIlIll/Wirestack/actions/runs/33446915140)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33446915425](https://github.com/lIlIIlIll/Wirestack/actions/runs/33446915425)
produced the Windows results. Both pull-request runs identify head
`bcb58cd11ff2bf61bac7076cc3aaa66c3f46f021`. GitHub executed synthetic merge
revision `e53f79325617559514ff35e5be1f1ca979960e91`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision e53f79325617559514ff35e5be1f1ca979960e91

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | a18c67b6f85ab2129c74cdbb2cbcbc1dad278d8328c832c6df9736df53f2dd85 | 9778419268 | abbc4460ba309b35a0be1d3299b01c7051986944459bca3f1c77445859c1396f |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 10f42a036dd1cc43a59fd966070df7a0a5391d72f7277e0340ceabf31c928576 | 9778411973 | 9e38e820977fabdbb6c02861e772ee60023de694c3c25f94680199c9b394dbb7 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 558c42f79921865ebb47ac32e4fef4f3dc056c11ade51f37cf63813a98a587ae | 9778471334 | 3202a96f604df7f9fc19f51547506c0f63d0497a805709cbc66b7a62769b0216 |
| Linux musl x86_64 | AWS-LC | PASS | 422094ebf5dd399ea59bc92523d26c13b56457a55aadc85eaea3d1c5ff56fefa | 9778399492 | fae337d360c7953d6231fdf8d53e21e8436eb661e29b8632cf86ae632da6b71f |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 4a0036b7b71bd5f76d446fb30277f9c2e62c4bb10b975f8f6503c5508c201b5e | 9778409116 | 40019582dc6a43e394f63f954bee44fe0c043136069f288469b8d7f6069e6d10 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 8f3b31b1ac169f79ccaac46839c123bf55e08a33e05c063815f8afaa8f5d952a | 9778433427 | a89a77ff0ec2af9c4fb7cb4612dae645962c0c2e91ad4e7fc458512235316e89 |
| macOS arm64 | AWS-LC | PASS | 68d1bffe66e073a4d7c2ee8f351e7fc778d90fcff35243617d128fb7d85b0e64 | 9778411132 | 1231c723a7bb16b3a68f6a31846478d7147a57ec25881a6583b0df08a21c57d8 |
| macOS arm64 | Mbed TLS | PARTIAL | 8d1160246cb56ef3c9a02f8b9df2d4a77b0798c9f35a703c0283f36518e69243 | 9778397817 | 8307065589c5ea200eae2575d558d355f2d2d0e44b9150b6daf546c951242fba |
| macOS arm64 | OpenSSL | PARTIAL | 4b646f2ed928184a8c6b7c2182829dc7536d8a427aba98ddd951e0eb95357563 | 9778464533 | acb3e973ce49dc7634e21f97b9d9855a45711b0ebbca25d9a557e42923911185 |
| Windows x86_64 | AWS-LC | PASS | 1453c22999b24bebfbe84bc80394e095eaae5de95c0bfc8b6c5bff429350428b | 9778415733 | a740a910925c8eb0223450446deaded61887f74e2e391f98af7811b6efb1d8b0 |
| Windows x86_64 | Mbed TLS | PARTIAL | 7702f5b872ef13f7af28f80e27c5f06eabb5c46d1caa409dff7776df073d9b17 | 9778451590 | 4163ff52e3eadc2d9f60d5ca52e5f78532ebe4173fdea3ffebfeaedb6ddc7d9d |
| Windows x86_64 | OpenSSL | PARTIAL | cf69b1a3f2e2fe1585435a4d85d9620ab7439f8850cc00b2bda835890b0e0493 | 9778589009 | 1bf5981a5eac2c0fbab854d98385bfda97e74322151648a5d5aa57f0fb0a4a57 |

The Unix artifacts expire on 2026-11-29. The Windows artifacts expire on
2026-09-14. Artifact expiration does not remove the committed result JSON,
license payload, matrix digest, normalized build provenance, or source
identity.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a`, tree `ae54cd9455f9630451d505855afe808a9f028b25`, content SHA-256 `0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478` |
| Mbed TLS | 4.2.0 | commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b`, archive SHA-256 `2bed9d713b4668f76553b097e72b8aa30bc8f112a940d7ae228d524bbde6ffea` |
| OpenSSL control | 3.6.4 | peeled tag commit `d3c1b1169b3569ff3069e5b399f47b2b28e03d79`, archive SHA-256 `9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef` |

tools/tls_provider_poc/providers.json contains the machine-readable source
pins.

## Validate the current matrix

Run the fail-closed matrix validator and fault-injection tests from the
repository root:

    python3 tools/tls_provider_poc/validate.py \
      --matrix docs/evidence/M0-016/platform-matrix.json

    python3 -m unittest tools.tests.test_tls_provider_poc

Matrix validation rehashes every retained result, license manifest, and license
file. Missing files, path escape, digest drift, unsupported schema, stale
execution revision, skipped diagnostics presented as PASS, or incomplete
capabilities presented as PASS all fail validation.

## Evidence rules

- A retained incomplete native result is PARTIAL only when it satisfies schema
  v11, has no `NOT_RUN` or `FAIL` capability, and has at least one explicit
  `BLOCKED` capability.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC qualifies candidates. It selects AWS-LC only for the Linux delivery
  profile and does not claim production provider support on other platforms.
