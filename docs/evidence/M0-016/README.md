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
33435335010](https://github.com/lIlIIlIll/Wirestack/actions/runs/33435335010)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33435335035](https://github.com/lIlIIlIll/Wirestack/actions/runs/33435335035)
produced the Windows results. Both pull-request runs identify head
`3f2d225b5108441835c6f7e471bda8fbf9a8e046`. GitHub executed synthetic merge
revision `1c21f3bdb8176846d94450595c47c1bf4526efba`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 1c21f3bdb8176846d94450595c47c1bf4526efba

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | a4459f7fff75face93b14715a3a2e7ad9a4c7de1eda1b51306750227fd343058 | 9774270791 | 43b39b14d7ca73cbe717c309ab3bebe355a1481ca314b019383d28d002aa7c62 |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | e3ff929d25226aad3194ac928d573cab636879976ce509ed91eca484612a5aa2 | 9774235506 | 8b04f2fa3208710341e36458369df3b24a59049c18a26c1487ba0e2767dc1c40 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 7fcdb0250fca2eebfa6cd117e25585c50d54798a674c855debfef05f524fdc16 | 9774275102 | a20da15b96706f91cc9221a4f7dac8196e7b9643803e52fffc4d974259e1ad6e |
| Linux musl x86_64 | AWS-LC | PASS | f69665df7d68a41a0562ccc9e639a9b51d057bab825d31594365f1cf0633b5a1 | 9774220025 | 6554702cc5a5830a942728788caa90246bf2dfb444fcfedd15dd65deec74a055 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 2c6a5ed6183f08d879175b219145138c27d392b08b795fb897984e999789416f | 9774221991 | 371d493db72c85c6e6c18158f3759caaf85c76dfbf14df2e095915651c46bd88 |
| Linux musl x86_64 | OpenSSL | PARTIAL | f91345b0dc97d82b9e55f4de129ca0d48a407f79c16d7e9b72f01895f9570f6c | 9774256473 | 2b336feeb74cfdf059ec5b74f20eeba4044b15a66ced6dd77c3a0bc7a7585daf |
| macOS arm64 | AWS-LC | PASS | 50f2fef0594a9714be524a99abe5035dd124a97d93b08560c30ef2b7cae64d77 | 9774221858 | 9d2387f822d3bf8500d51e76f2fa83b5f327e7a39f61443045a9267b6b6549eb |
| macOS arm64 | Mbed TLS | PARTIAL | a72bd0a575b26c6203f69d204c5310f17fbddee39a2a6ca2a4c963ffb8049aa6 | 9774236669 | 77e95cb2a05f3e3b8365c6401305b8c679c4a93074cbc91cdc7fa6a7a1f77716 |
| macOS arm64 | OpenSSL | PARTIAL | fc5f9c745801df32859053103ea3256ac3c705125dbed3368b3ec77260a04929 | 9774293040 | d43b0fdb731dbfa1973b533a94fb58f212b7b07774014feb034048fdd38e2446 |
| Windows x86_64 | AWS-LC | PASS | a31ccd6ac97be363fba232913f63e28d3ae4ea809a7e4d851220c9ba9423fbda | 9774229187 | e8143efb0ca203bc6b06d2dda9c37b32273891e3d779c41b7485566ae25ab562 |
| Windows x86_64 | Mbed TLS | PARTIAL | 241b871b7dfed84b558254f8ed534aff26cb06bee59b353e29a4f0a3789bd0a4 | 9774285560 | 300846e10602dca7edd97ee6599efe7607fabb7fa60d82f5427f90cd551acbc4 |
| Windows x86_64 | OpenSSL | PARTIAL | f430ac64b043c95d8b9576b26eee596ec689e0b992528143bf3d866a0555b343 | 9774480229 | 11e249d4b0d25a69cbb10b919b9c62fd37ee3a50021ccfdf3ef93f0e4ad85bdd |

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
