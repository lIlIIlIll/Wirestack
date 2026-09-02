# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** only at the full cross-platform task level. All 12
desktop schema-v11 cells are current: AWS-LC passes on Linux glibc, Linux musl,
Windows and macOS; Mbed TLS and OpenSSL retain explicit PARTIAL results for
unsupported capabilities. Android, iOS, and HarmonyOS or OpenHarmony still
lack native-device evidence; cross-compilation does not satisfy those cells.

The local contract-gate record is [`mobile-runner-contract.json`](mobile-runner-contract.json).
It deliberately records the mobile cells as `NOT_RUN` until a hosted artifact
has been reviewed and copied into the canonical matrix.
The traceable mobile test plan is [`test-plan.md`](test-plan.md); its plan
validator currently reports 10 paths, 9 scenarios, and 9 tests.
The hosted mobile matrix runs AWS-LC and Mbed TLS; OpenSSL remains a desktop
control as allowed by the candidate matrix. Use the documented
`retain_mobile.py` helper to perform the review-bound, atomic copy after a
successful hosted run.

Schema v11 retains all prior native evidence plus the exact successful NASM
identity for a Windows AWS-LC build. Its workflow fallback is pinned to
Chocolatey package `nasm` 2.16.3. The current hosted image supplied NASM
2.16.01; the retained result records its version output and SHA-256
`547d4edd4b1d6fea2504990e70263b5ce06cfe7ab894483f6c54e60c1bd93b60`.
Hosted runs use the read-only Actions token only for bounded GitHub API tag
resolution; it is excluded from logs, retained results, and build provenance.

The `M0-016 Mobile Provider PoC` workflow adds GitHub-hosted native-VM gates
for Android arm64 (arm64 `macos-15` plus an API-33 arm64 emulator) and iOS arm64
(`macos-15` plus an Xcode iOS Simulator). These jobs are supplementary until
their result artifacts are reviewed and retained. They are emulator/Simulator
evidence, not physical-device evidence, and therefore do not close M0-012 or
the full six-platform M0-016 task. See [mobile-runner.md](mobile-runner.md)
for the runner contract and its fail-closed limits.
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
33455645644](https://github.com/lIlIIlIll/Wirestack/actions/runs/33455645644)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33455645656](https://github.com/lIlIIlIll/Wirestack/actions/runs/33455645656)
produced the Windows results. Both pull-request runs identify head
`fe1dc2cb35c57d6ae31ac9fadd0f8415e57835ab`. GitHub executed synthetic merge
revision `205c073c22aa283d84978522b70534fe5a16d808`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 205c073c22aa283d84978522b70534fe5a16d808

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 95b03d7f262b99823b78a583c6fcadf813d381026a04351965fae3c251a07a50 | 9781397892 | efb319660a58e8663015c4a6ea47d8634b87f59e2e3b6c0b07cfcb04edeca6b8 |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 77539b980497de916f4018c85fe96da82fb4c3ceb33e3c2cbaa08e7730aeffe1 | 9781376045 | 458ca71e238585b0ea9666f381d1fc677ad86e803ebd61bd35271b4b1de9bbcd |
| Linux glibc x86_64 | OpenSSL | PARTIAL | a5345f52cfc783abfdbe4ee017fe5ca70ef0b4f8e6177f9d5fe9dcf0734f6c52 | 9781404358 | 999c5d67d5b9dc20ec0a70ce05c44db2b0c677df787941264f71a491fe13bc3d |
| Linux musl x86_64 | AWS-LC | PASS | 1a9a1b4be8d8c4947eb1791837173b17617a96723580cf9c6afd458cbf46585e | 9781358505 | 9288e0f9e15a00524b66c24eef2b415f0abe5b6ebb843255b91ddc648eb1bc6d |
| Linux musl x86_64 | Mbed TLS | PARTIAL | a3e75b6eca32b7cdad928b1aed3edbfe566dbeeb1008ffd59ac373fe22c67fb8 | 9781373394 | 865e16cc527be1011262c8afc2c9bf0e4daabf1a694d18b1a34f884a510d1fd4 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 348f45e8d2cd6ed8d9563b81f30f78456bb580ea040fc53fdca312382797ca4f | 9781396890 | 2971eedab66f7ea2b55ec9be3e6b64c77e3bc2d6c5f7ce245a3b7327277253fd |
| macOS arm64 | AWS-LC | PASS | 0685a9b5977eff70f0fde6cf16a114f46903990233c357ec7cd7d59c07877d1d | 9781366960 | c934e4c3e9ab02b8ed2b478b6deeb5259f67ad82d1a0633932dd1b46982c57d8 |
| macOS arm64 | Mbed TLS | PARTIAL | fc16a9655910065a0f99be29fa805350563df21192a54c816632de4b1973161b | 9781359696 | 4e322c0ff0df31a5551d43f65c02edc4d50488cbbd9245d83c78cf29be2c9c9a |
| macOS arm64 | OpenSSL | PARTIAL | 7173f43c19a3ac6a3b99972e06634482ba314b3b600a9371a5ee88e2cc93429d | 9781409226 | 1c5483e3dd878befbd2fb2a93c4755ebc90dd32629f130a0b855e885b62dadf7 |
| Windows x86_64 | AWS-LC | PASS | bc1762a5af4f496aa96899b953c3a0ddc75c304bb583c76c76e1447762eac2fe | 9781369651 | 5685022e73b6d240bb2c7f76de07ed4776ee8116654f17ed752ae690059049b2 |
| Windows x86_64 | Mbed TLS | PARTIAL | 6bdf3f0085897eceea78d3293b2deae0fe65b2e259eafb250e83c85ea80778d6 | 9781415835 | acf387ae1ba8ee802406c4f2411d5273bcb289e198f805021107d4cd480e5453 |
| Windows x86_64 | OpenSSL | PARTIAL | c3a0a3308d1e37e93c47ecb131df06c8eb60b18a36c0f4ba32000acb3c5f6a32 | 9781555727 | 4f24ad6ca047c5389a4262ee19bdecfdd6f8cdd2018d2fb3887bd217703b1487 |

The Unix artifacts expire on 2026-11-30. The Windows artifacts expire on
2026-09-15. Artifact expiration does not remove the committed result JSON,
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

    python3 -m unittest \
      tools.tests.test_tls_provider_poc_mobile \
      tools.tests.test_tls_provider_poc_retention

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
