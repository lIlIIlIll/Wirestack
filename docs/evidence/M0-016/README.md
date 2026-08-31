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
33445220117](https://github.com/lIlIIlIll/Wirestack/actions/runs/33445220117)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33445220153](https://github.com/lIlIIlIll/Wirestack/actions/runs/33445220153)
produced the Windows results. Both pull-request runs identify head
`0c128cd05341bf12f5e5aae8d4e58c0ff07198d9`. GitHub executed synthetic merge
revision `88584c91602b25e4c35cd4cf9a1431c220897cec`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 88584c91602b25e4c35cd4cf9a1431c220897cec

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 87571d74a489b6763d5b144ee4c9f5202a5ac823772a38c31c49913e611d6a62 | 9777844613 | 3e33d9f16f1de9f67f7f4d2c2ca9cab0881c7ffc517c979f175cd374d7cfd1be |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 1a020c43b0ab2755a56cdefd88ee0f197eae85668dfb0aa998316b0686b6004a | 9777818907 | f30bb753581b4760f8cba3eb709176414681598d2b2ea15f4ad60e1521296631 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | cc17f6ce64473a95e3773232228ea618567113f62309dce077dca853fde08547 | 9777876377 | b14b7deb9e0fbf1442d8f64db53b71a2f1c0cebd1d679ada511b95d25a3ce88d |
| Linux musl x86_64 | AWS-LC | PASS | 2ef9cc87e8af126030c957d655a531dfc3b02d82c84bcda764e5d1a56c445b59 | 9777805774 | 3b2b9e11a0f26c18fd343215491b2b74d1963ece98212aa55f267e48c94a10f9 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | f3e7f95ca57211ac7009689dd51b09e1ae10cac0c10b0c95015b2d0c9b356ec0 | 9777815912 | eb5e4251e4d3c652c43fe6d61dde4463f29cb7caf6b5aba568107bceddb2791c |
| Linux musl x86_64 | OpenSSL | PARTIAL | f9368484a8ed7c194075c5044bff383a309eabddf155a3f9f11f77095f89b644 | 9777837858 | 95786c6bafee903b8e2fdfbea739083e02689fccd2b8dafbf8207b10b2b4fd0b |
| macOS arm64 | AWS-LC | PASS | 4dea6c8921d64df11173a885e865931c2d03e72b9b8ce63d55bfcfebaaaea81a | 9777828888 | ead3f3a554e364dc04ac67d0f864ffa2e87e4730dfc17df6247662473fe8fb6f |
| macOS arm64 | Mbed TLS | PARTIAL | e4e5bf84ea3bef78d0f22e719861a442c7fb3fb750e9d7a5984e3f6fa67ca07f | 9777799573 | 3853ad69e07c022d2ae906e499f4c66cc9e86eac22eba5bdf97e0db7fb5d22a4 |
| macOS arm64 | OpenSSL | PARTIAL | 6379a24adc0f15a04da12fabca2365e8ea5bedcaf9b042e7caa3a315f536b989 | 9777865777 | 4f8fbc5b3e8db07258642100cc5cb36373178b83835970754a10713f53556179 |
| Windows x86_64 | AWS-LC | PASS | 3b5df224b11b427894063fc664c47d3c23fa3c8c774224f50d00027cb088fced | 9777816989 | 0fcbc0c1f9949936aa69a1019790bdffd560b4479588c5e50f199398deac0b10 |
| Windows x86_64 | Mbed TLS | PARTIAL | 95ef3cf7fe92ba979b9cf8643c7985c33b7b8cd571f512b48938fec2a10c0931 | 9777865376 | 95fc19c0d20f1fd92cd60922adc5ff7555e6e6cd4794dd649b0a9f0498f7a708 |
| Windows x86_64 | OpenSSL | PARTIAL | a0161908805db3c6944ca63c47bf50fe2794402e19107e869c97463ac9f27f40 | 9778009301 | aae8026a892b80ada1c13fe09638e662c9268d0e0e4c34ea1f7bea28a2c80d4d |

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
