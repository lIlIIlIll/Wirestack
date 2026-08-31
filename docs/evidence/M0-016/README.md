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
33439283767](https://github.com/lIlIIlIll/Wirestack/actions/runs/33439283767)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33439283658](https://github.com/lIlIIlIll/Wirestack/actions/runs/33439283658)
produced the Windows results. Both pull-request runs identify head
`a98a4811dd86592b2ae7514a1d6267e72d8dd8f7`. GitHub executed synthetic merge
revision `91d82dbea7f2353445c7a495659cd425b9ae5c15`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 91d82dbea7f2353445c7a495659cd425b9ae5c15

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 546aaacfaea2af50547135843499e7ffdc689e4c33492a90f56e95ea7ee189de | 9775697418 | 28f0a8d68bdc2cecc3f97f5ecc7eeeea9f3877f7e7ea03055e7043828032eae0 |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 6fcf847bf97ccd87ad290ad1cafe29bdb9ef92aa7cdfb7276652734b21df5e3c | 9775674654 | 61ae19f59bade1ce071ee336aac4a3b8c8249fbdea73dc3e57c34b76f3d2ea4c |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 0111b5e2270679483b14500920db52a5232d63959f72f3a085bd4bdb8ca7312f | 9775734582 | bb9e96c6708f25368f50adb38c26973c1f86d1bed03eaec6067338243b97ed1f |
| Linux musl x86_64 | AWS-LC | PASS | 543dabc796b26e94d47c9f22759b03e574439f8e3c8c495504280b4ef02bb190 | 9775658961 | 19749c28d3fba9fa4fb4c37b872231af47d5c8127fcc5205499336db7d0f93c3 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 07dacf5d01d9657daf99bd0b6e7000f7157df7a92af2c60df1682f8f26c767d2 | 9775664699 | 5ebf8caec7fbbb35dfb746a4afb78ca851f0b4efc745cb8e82bb0fac5c7a6b1d |
| Linux musl x86_64 | OpenSSL | PARTIAL | 76e4eafe8cca40e6d23a1c6a1b27cbcf63621c3bb7e8add73494233c776f5e9b | 9775698483 | dc42569e703349c8fd2cce0651b845bfc813084e716ee13113169a866ad5d511 |
| macOS arm64 | AWS-LC | PASS | 3088ec5d51ac432de5f4541de601fc879daf0fed6f1740a950de443d9a62b762 | 9775693350 | e51de433edb3579039b07f546b7c875d89b57d641933683246a793f23c7e288e |
| macOS arm64 | Mbed TLS | PARTIAL | 91bf38fca72e93a48c0934df51f4cdbe8a70e7b7a0584b41b083aa8829c504b1 | 9775677246 | d4fe747b5f0e8e1686a06a40cd90f6fae55de62ef93ae623524e832a729529a8 |
| macOS arm64 | OpenSSL | PARTIAL | dbf769e342a2afa09c7b9d9713cd96081de4631cb187b3404b77dc6e83c6d351 | 9775749973 | 6d6319a6d389e0b4698a857cf1d6b618ef651b845ca85de4b7ecc8976b061f7b |
| Windows x86_64 | AWS-LC | PASS | 26b080246cec6fb9ec39344d0c7076df26e25f3f879ceca10813bf6eec1f27a6 | 9775667921 | fd1aca3a1b9e6df228f95ecc48b6ab4c300907a54ddcb53e474a6333a4be30c1 |
| Windows x86_64 | Mbed TLS | PARTIAL | 910c65cd7c0f8464e9e1be4539786699aa43dc3f7672dae35e1db2337a6cf5b8 | 9775721515 | db86a5fa559d70841a8cba11dea6a10119c586974068ea71e5ca06f4a4dfb6d7 |
| Windows x86_64 | OpenSSL | PARTIAL | 66b76182a05f028da414dd2345b6696b8da3b9eb566c1b9b617ef8c49f9388b0 | 9775922906 | 4963217adb116a333a7b99dec58fad0d80dade505b37b1dee510fa2644c6154b |

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
