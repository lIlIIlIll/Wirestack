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
33442933512](https://github.com/lIlIIlIll/Wirestack/actions/runs/33442933512)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33442933487](https://github.com/lIlIIlIll/Wirestack/actions/runs/33442933487)
produced the Windows results. Both pull-request runs identify head
`9eb9a2afd36a89f5a4ffd9b498782eccc2549a39`. GitHub executed synthetic merge
revision `427385f29e6ae64e003caf7a539a5343761c8318`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 427385f29e6ae64e003caf7a539a5343761c8318

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 33e7761416c63dbbf09f5b591be89167144cda15e9290722363dce6a82e3082c | 9777038448 | 703305c1fba3a7d179823cb6276c42dcce79b1382138ac7eff0f2a404d104248 |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 359a5b62b047bf5f7dbf43164f5926163671dac821293dbc8e1c29b6579d91d5 | 9777002352 | 2d57a276261c8dfda505255272fac4339779ff1080eb790b61f8f87b5f46e1ec |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 37eb7ecc39fabb02d00a1aeaa0494dd8f70783ccc5458b38ce76335ed7acf2e4 | 9777055663 | 5c3adea8ffd7754f9b4df1dd8bbf5fee7445a02f9dc285102d3b4b14a8249a8e |
| Linux musl x86_64 | AWS-LC | PASS | ef2d1568dc0198bf4211e75e95f39f846dc184da5cfca01d6dc4a073c7c762c0 | 9776991193 | 6accca0459f8a4c2d2f4c1af3db8ebfe36007dff01eacd984fbab5934f548463 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 336cdf98bf80c3fea4ce4328eb06b6162d0d771b9bc243703babefcef2e06d95 | 9776992991 | 9ddeea1c4c69567f2b1c9d4549df8531888d72f6f91ad7b5bfda32a218e32702 |
| Linux musl x86_64 | OpenSSL | PARTIAL | bc16cb678ecd13f2558f0d8c7e820d9370a56bebb0eb86d6c7d13e400e55e946 | 9777021474 | cc2e6eb0314b804b6d3fb86cb618130dd945bcf05bdfb7c14ef1ccc38d14a003 |
| macOS arm64 | AWS-LC | PASS | 17e8416c039a0292583eb3c26c1461b2b50799d85fc63a5de08c6748a3ef5ae3 | 9777015498 | 5c23ae2a2e35127f71ecf0f6942aa02ce242e2db2a1b545870dc41c023828bc6 |
| macOS arm64 | Mbed TLS | PARTIAL | bfc55b9bf18ae514f186aec0daf0f2dcf29bd2305dcb784d40977317a7054bfe | 9776993906 | 5e83e758f31380caa3f764afba1c96e998c4483e2cff2f0e32c1f79e5f9be567 |
| macOS arm64 | OpenSSL | PARTIAL | c1561b9851a687c3f803e363a12103e4b32aa4e734328cdcd1505e3753ae5f14 | 9777059336 | 3c7bafc47fc30e784290061208ecb2a150e92bfd6cb9a3f6c184eae0e740a86a |
| Windows x86_64 | AWS-LC | PASS | 2f7fed6cf26ea6f49525d511155e935c0491752510b818af415c52cfcc252add | 9776991275 | 500ca019db60ef598c68f329f03f7432ef03ea4fa752e789a502b39fdbb3a082 |
| Windows x86_64 | Mbed TLS | PARTIAL | dcda3f394614d74a851ab8e3517f798a77fa64be9db555aeedf5ce22aa87a0d0 | 9777041221 | 60fea7aea67cf4972f14608b4b4ad8a17006e16a8138ee5cd2cb3006237dfbba |
| Windows x86_64 | OpenSSL | PARTIAL | 3fad1f785f926fe1c181e803f93e11591f03d9d176eb78181517437cb94f2ae1 | 9777226022 | 4d0f60a351e476fe6360521f6397f4ba8dd19379cf21a9cce2a8e8e243bced34 |

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
