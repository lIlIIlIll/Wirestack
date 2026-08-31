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
33450663710](https://github.com/lIlIIlIll/Wirestack/actions/runs/33450663710)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33450663677](https://github.com/lIlIIlIll/Wirestack/actions/runs/33450663677)
produced the Windows results. Both pull-request runs identify head
`b42460c749840be6d45cb58a0703f2ca85e54219`. GitHub executed synthetic merge
revision `f329ccdac1130afad7ad5e5fd5665378bb392072`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision f329ccdac1130afad7ad5e5fd5665378bb392072

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | e1d5f618faece2839a8e33e7c1803d23b16084f14eb4e1092e17a248e2badca2 | 9779711884 | ec15fcd89de61d0803c33bc7161631c845bd3b7d26116030b9ed027efc01b46b |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | dc0cc4edb9ce349983b197dc44fa8aa5af7222ac7f3f9051d1e4a6b51a97ea90 | 9779698715 | 16b6f9485bd7a3eda3844b68986f252db9418a6f0c219461f0de07c07d6f158f |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 1ded329804b22b970d6136c9953a96bd1bf6e4e06df4fc45528742665f4af32f | 9779716483 | 5cebcc922e1951ccd2b703f3554b68d6e69c15c069fc632c5a4b0b6e16ad16c8 |
| Linux musl x86_64 | AWS-LC | PASS | 42ebb06cd91d054d1982a51ffc2cc384eef00e2aa21ca9fa34c64aa35f045f1b | 9779680098 | 378ca78a69eeb297e1ff1f28af974252dbbc25b6161bc49641250e9101274688 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | e56738dde0aeff2ba4af5f6bee3139dec13ebb0bef4eadcd29ad5b048df9bbb6 | 9779686143 | 5cef498c45d59cd2bf672bb87ef888d52aefec06cfd8afab0a2a8607129830b0 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 3c9e7c782ee245dc19a10671f9057298d03343c7120c7c26b58540be69f5bfce | 9779710004 | 4193b8b3e78bc220af1a418fb0fb8ad21833be5ee93b8c8d0b2c414f4fde7951 |
| macOS arm64 | AWS-LC | PASS | 815fd2f0eda0facaefceaa35713133b027dff9c025a4db4f1d0cfc50de7c5722 | 9779682314 | a89a1cdc243ecb2885c9b84ab99b683e036cf6205c93a7a6c6b2dca68319e502 |
| macOS arm64 | Mbed TLS | PARTIAL | 39ce714ba176b499608ddd23bcf82d427791ee284d1382c2570696aa397a6622 | 9779688645 | b351f3480c6b3e775fd8e5b563732810580ed306139ca4cc0eb4414778d15a31 |
| macOS arm64 | OpenSSL | PARTIAL | e44af9a9f859402c09a1d7494dd515aa9f7e8ff3c7a878560258e6137e9cdf4d | 9779727158 | c60971761beeb166aa45e63d0cd89b3afb5d54dc5215c248033e9b0372b0ed56 |
| Windows x86_64 | AWS-LC | PASS | 8a9026074dd61b56ec4517d7fcb3ab5cae07451e1509827c8148f20070ce3eb0 | 9779678094 | 705753b1e6e3282d7b0fdfe7a23903a51cd78094f0ae8e2a80cb3c60f8521fa4 |
| Windows x86_64 | Mbed TLS | PARTIAL | 045942570a624c2fd44df7a098e7d6bc3bea0d4f5271aaaf038891894f0b3881 | 9779729268 | d25b4d9a2ce508e37cdbc4856816fb20c546660f80f9679456cc41e8dc446250 |
| Windows x86_64 | OpenSSL | PARTIAL | cd47f90f6877d1526a05240cd871866735e3ec1c5ac12753684993459e629f7d | 9779886354 | bf311980d821c1dc2e8e68a699b2e815e56e92a410916a6388978654a08269c3 |

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
