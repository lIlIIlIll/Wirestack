# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** globally because Android, iOS, and HarmonyOS or
OpenHarmony still lack native-device evidence; cross-compilation does not
satisfy those cells. All 12 desktop cells now have current schema-v9 native
evidence. AWS-LC passes all required desktop capabilities. Mbed TLS and the
OpenSSL control remain explicit PARTIAL results for their documented missing
capabilities.

Schema v9 retains all prior native evidence plus:

- monotonic cancellation and join deadlines that are unaffected by wall-clock
  changes;
- a fresh advisory review timestamp, exact pin commit, reviewed advisory IDs,
  affected subset, and an explicit affected/not-affected disposition; and
- the exact security-update object in every successful result.

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

## Current schema-v9 desktop runs

[TLS Provider PoC run
33426302574](https://github.com/lIlIIlIll/Wirestack/actions/runs/33426302574)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33426302474](https://github.com/lIlIIlIll/Wirestack/actions/runs/33426302474)
produced the Windows results. Both pull-request runs identify head
`0620a1336cbdc98b6b1c37144e94a692f6e82cf7`. GitHub executed synthetic merge
revision `45e16233d373854243966b10bbef012a66566641`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 45e16233d373854243966b10bbef012a66566641

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 4e37926a97e6d618d31ed0b9066cec389c50157e055d889aeff640cad186e3a4 | 9770959534 | fda04b6d324cc46338616d23f6e626006e33d5c2baf1a0b781ee2f2ddb20e62a |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 5bc945688ac26273d1d7ad7e126e229f6650ac7bf2e1b947d16c05edc4f4945c | 9770916654 | 1b6085ddc4f2bfa805f5e5021a908f40ee3d9fb6b3d0cee409427ec897336b5b |
| Linux glibc x86_64 | OpenSSL | PARTIAL | f8f9e6a1d4046fb4adf808383502fa9f86119f11f94952d1ee3c38d5accb5165 | 9770980762 | 9c1e5107a49407ed4bf0358681d8aebdc662ed1ca2393a58b273d2a75be0a73e |
| Linux musl x86_64 | AWS-LC | PASS | 5cc13499b487afd66dbc7d021dfbf9c7eebcf36f209028319a6d2af25926ae79 | 9770908162 | e70c90c0855825d94645a27a42077b2c18999f21987a7a4e63465ca1c1fdef7c |
| Linux musl x86_64 | Mbed TLS | PARTIAL | b13182fed2f292b63342712cc05344a08c1d1dad902d2f1c550a2d8fd5ec5dd1 | 9770921236 | f096552401fa03eab29940e4dd36da56697fd1e8f8abeccba4c524e9f31fda28 |
| Linux musl x86_64 | OpenSSL | PARTIAL | e0d4a3925590a99e6116fe3ddb4c4bca1fb23c84f463f913fe78cb75976ff965 | 9770945567 | 96a12ae88b8489810117705e49bd26473d8c7669a638f8c1362b7f30b18689a6 |
| macOS arm64 | AWS-LC | PASS | 0a2b7679e8f496763403e4549ea89f18c738ba0fdc266fe9422b7540e817ed60 | 9770947715 | f4f64d941e39065d06dae8c1749d89b6b4c9ebc8e08bdb2134b679a0c1e3a4d5 |
| macOS arm64 | Mbed TLS | PARTIAL | d10f8ca099212c8aa4f97f1d90aa8c29c5e89dbfb0e1b03259314ffc79f4d3b7 | 9770911002 | 187eb647de0eb074320b5fd19463f2ae034f92d82bf43a764a2dd8dc6d06173d |
| macOS arm64 | OpenSSL | PARTIAL | c4b26fa1087e4a3907f58097e34a885f68a570309743cec80f563cd66f129bda | 9770982853 | faa4e73bd5bc9ca878571ca6884a1cc76b706acf1fb1974d19e67bb09dccf1db |
| Windows x86_64 | AWS-LC | PASS | 6abfb75e842dfb160f1abd89206f8d7efc9f829e388b9de5ea7af55e398096b4 | 9770925635 | 2d26135b4d98ed72ecdfdd41684e02fccae64b030a89607ee6f616d5d0eb40cf |
| Windows x86_64 | Mbed TLS | PARTIAL | 0aeca65da1dfa8af523830b0752482d5e3ea3b6dc664887abfe2f81761fb0416 | 9770973959 | 2bb60c13cac13e7035a2478c32aab676836cfcc441e0d28b91c60ecb1f88fe38 |
| Windows x86_64 | OpenSSL | PARTIAL | c0af77a2127e80f43e605df5eff8f77b9d9af7bc94273a86cf3f657c4d9d68c0 | 9771198860 | 7f87fb70ac4d62efd942509ef8ebe2a4d8c2f3374f8c9a2be9b96f01161eb008 |

The Unix artifacts expire on 2026-11-29. The Windows artifacts expire on
2026-09-14. Artifact expiration does not remove the committed result JSON,
license payload, matrix digest, normalized build provenance, or source
identity.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit 991e67ff4cf04df4dd89e407f8b920c6936cb56a |
| Mbed TLS | 4.2.0 | commit ece41aa84d7879d7e55c59e955a5884b541f7f3b plus archive SHA-256 |
| OpenSSL control | 3.6.4 | official archive SHA-256 and peeled tag commit |

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
  v9.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC qualifies candidates. It selects AWS-LC only for the Linux delivery
  profile and does not claim production provider support on other platforms.
