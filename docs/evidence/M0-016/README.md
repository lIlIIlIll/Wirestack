# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** only at the full cross-platform task level. All 12
desktop schema-v10 cells are current: AWS-LC passes on Linux glibc, Linux musl,
Windows and macOS; Mbed TLS and OpenSSL retain explicit PARTIAL results for
unsupported capabilities. Android, iOS, and HarmonyOS or OpenHarmony still
lack native-device evidence; cross-compilation does not satisfy those cells.

Schema v10 retains all prior native evidence plus:

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

## Current schema-v10 desktop runs

[TLS Provider PoC run
33430599975](https://github.com/lIlIIlIll/Wirestack/actions/runs/33430599975)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33430600118](https://github.com/lIlIIlIll/Wirestack/actions/runs/33430600118)
produced the Windows results. Both pull-request runs identify head
`74985fb2c506cea3e007258878a038e0dc6c0c34`. GitHub executed synthetic merge
revision `72ac887eb974b177b9af09529c09166ec8db6303`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 72ac887eb974b177b9af09529c09166ec8db6303

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 7bafa0492dd9c35e73e28e8ab45eaef776f7018ee77f46e4977512f5b540ee36 | 9772559435 | a6d3fd72380a9a898d1f1d8f5eeee573b2dc84e09ac555a88998eae6f4c5bf1d |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 1b0d6d00bd306c1edfe5943ad2fb2f388d5b6e4fed77fcd019d6192a6f9ba4c3 | 9772498718 | 67256511ce2112004f97e2ba667c9afd631d37d939d299ee8c49fe8859ae365b |
| Linux glibc x86_64 | OpenSSL | PARTIAL | ef6f7c0b00e6c68d4016d380e397e77c31f73a8260b3108eaa1f511ce5f05632 | 9772560574 | 4285d77caf0f22bc5f1097f6d3e31089f0c710eceddc3504c6d8278b0974ffcd |
| Linux musl x86_64 | AWS-LC | PASS | facf425c23c37f51cb3844854c3f00840b1c8c8a989268bf947084402c101505 | 9772484110 | da0935e72b17ec5f20db0912c6df32b4d08ccea9dca6bcc0f7e816eaa04e098c |
| Linux musl x86_64 | Mbed TLS | PARTIAL | ee87563571cc70a2bee394b459801c5347f43062f5ed5f02f6e4371ed261abd9 | 9772494557 | 8384f6cc2aa3925e7563a4279c3c76121083cf10b360463e0886453f3ec1e8e9 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 3c60cc2be776e7e17ef3aa9a6c320364c3f182534912adcd8dc36ed543a47b06 | 9772524002 | b34e2fff342e44b479011457c62d94d00cfbf68e8ae5165276db78663edac9da |
| macOS arm64 | AWS-LC | PASS | b5e72b6f7a26f11c3a918d7ea7472bd65dbcc119f7bd8f5a3c6e75386e85d5ae | 9772497390 | 5849721ffd22c788e178ddf4138d7cb646fa59998b254f0eb31e3f21441ebeca |
| macOS arm64 | Mbed TLS | PARTIAL | d3513ceb8c03f2a54e51bb0e105b4ba10e0b0ab30462d0d681c1078d813eff2c | 9772493167 | a43b12318bdc4ec1f25e181118014e509c3caa6ad1a83ed7a7b86b5f828b7108 |
| macOS arm64 | OpenSSL | PARTIAL | eae8d521ccc7a47663d03d044632bf7cb0bfc3edfa4d563ddc91803545ccc8d5 | 9772542908 | ed645897830a8701eb9a65dd61cee090da21ee1b1e8fe35aeedaaa84326c7d79 |
| Windows x86_64 | AWS-LC | PASS | 4e16402139f6a83ad9a8b6b8b85078fd1b20d9084f0fcf473b674d23dfcb5ac2 | 9772490370 | 7ff23efecf497c74ab855d39038085e382638216a32e7df3377c132ff0c75849 |
| Windows x86_64 | Mbed TLS | PARTIAL | 91b8aecde1b21e2783dce36f2e6147e7174c23601137d808a96aaec7114812cc | 9772550981 | 4823dc8a8ef88bd76d06dd59e321edf87fea3258795e49933badaec84c93074f |
| Windows x86_64 | OpenSSL | PARTIAL | 8bb711687683a30f26687b32310a8ab0b973f7846afbd5dc1d0a6add800b2afc | 9772780366 | ae3f48bb74cae5f3964ec7decea5ebf0c0fa5d505832b7046df04d5d422e0311 |

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
  v10, has no `NOT_RUN` or `FAIL` capability, and has at least one explicit
  `BLOCKED` capability.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC qualifies candidates. It selects AWS-LC only for the Linux delivery
  profile and does not claim production provider support on other platforms.
