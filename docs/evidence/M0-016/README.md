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
33448976778](https://github.com/lIlIIlIll/Wirestack/actions/runs/33448976778)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33448976782](https://github.com/lIlIIlIll/Wirestack/actions/runs/33448976782)
produced the Windows results. Both pull-request runs identify head
`111307831293156fb7463c5a89bf23fa52490d1a`. GitHub executed synthetic merge
revision `9e2c4d10197720d7299f4ab1a7e0cbf6f38ac4ff`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 9e2c4d10197720d7299f4ab1a7e0cbf6f38ac4ff

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 98e44556098398754d59041eebac4b41c092e9b710c6e9c519213748bb81ba27 | 9779129816 | 6a113fdcd76bcc8e6940d8fb607373bfd76088fd4d88bd6b73a11cea9cf3df0e |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 87f9a9b1b8e665bd4ec6907cfa421397ece8e3a15b0ff75dbd3300ff8aba16ac | 9779107880 | a551ad3cc15508ac9a3491a95ae923ab0e6b5299966777165b76649ea33cd9f5 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 33f4e1a526082b382dd9f68d8214a6f2e4b2a6eb377970a1b6ef1833d0804ff3 | 9779149138 | 611b95ea1ca1ab414bec1594fb45bfb581dd0587e0ff07b899dbb412a8ab2244 |
| Linux musl x86_64 | AWS-LC | PASS | a8792e4dc106e0ae56f3ecf720e8c41896a76ccaec7ed9501b8cdd950feb5045 | 9779093340 | 6cec8569f48385c48fc199ced7c64e7d348ace4da4e3314023331caf3b7efe5f |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 596338a094290f7ae08fa856f78716224f0d6793a40cbeda10ee7832c7888d99 | 9779086963 | fb5411eb4131e603d809a6fdb6fa1848074f11f73a2984614c25a7b2d7e73f7b |
| Linux musl x86_64 | OpenSSL | PARTIAL | 545c39d8805d675fc4d03b285cbfb0ce3dd651ba10a7fe27c5652ac339d4e37c | 9779123767 | 2571174bfea5c85e75b28ccc5dda2846732ec73083a43efd8cd37948a0b6845f |
| macOS arm64 | AWS-LC | PASS | b0558e153558999a4e04c118b5fc0587b89238ec4e14bba29f967485f2ef4a99 | 9779108874 | a90bb4062a967480e2445ee9f7e63b7faa75e1a33c8640fb6140485ff4b23f7e |
| macOS arm64 | Mbed TLS | PARTIAL | a57111072c89facb640b7cc867956e93c978dc06ea64f144180db3059c889447 | 9779089418 | 195c6692e93c7b121aeaea402908ec03afb4b282095c914c96f40ee4dc36850e |
| macOS arm64 | OpenSSL | PARTIAL | f28dfc0c31b135534c614d65b224a59ba227b8d2a6c10cf07ec7a65edb202897 | 9779168695 | 93cf5b06b97afcc46a80c1e4f45659b00453af3bc9f6fe7c53880ee13b3bc0bf |
| Windows x86_64 | AWS-LC | PASS | f60e57266dc0e3046b653969ae412f3d610a68d965ff132f850dac099b44b696 | 9779100332 | bbef26ba1acffe3ac8d467867f82b12b9a977d9afab4078f251e6d194bc7d62e |
| Windows x86_64 | Mbed TLS | PARTIAL | 0e3ce6badab41d11f5c665958f1498c2652c9f3caebd79aa2d107b6dc8e8a765 | 9779146704 | ef3009479c26d75b4017550c45e8da2f3e7704a5fc3da8e5e88159c2f6fd71fe |
| Windows x86_64 | OpenSSL | PARTIAL | 0b2d34f86a814de31c1646dc032797ab86440aa408a1860a49422abd9b343238 | 9779307756 | 2ba9c4e99758b59ab7dcd3e2366ae78d92ce8b69722dbda07210432c88b649e6 |

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
