# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** because Android, iOS, and HarmonyOS or
OpenHarmony do not have native-device evidence. Cross-compilation does not
satisfy those cells.

Schema v8 supersedes all 12 retained schema-v7 desktop results. Native reruns
must retain the bounded allowlisted snapshot of inherited and overridden build
environment values before any desktop cell can be promoted again.

Schema v8 retains:

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

## Superseded schema-v7 desktop runs

[TLS Provider PoC run
33411959747](https://github.com/lIlIIlIll/Wirestack/actions/runs/33411959747)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33411959615](https://github.com/lIlIIlIll/Wirestack/actions/runs/33411959615)
produced the Windows results. Both run records identify pull-request head
bdad23f7dbf86c91245f64dab029dd75bbad0d56. GitHub executed synthetic merge
revision bbd2b22404d47f674842c50eabe2debd12d79787; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision bbd2b22404d47f674842c50eabe2debd12d79787

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 5e51a933625633934dbc4abb1391d4ac9c4044a38a91b5d7fd59cda52930544e | 9765584693 | b46516fafc8f83aec6b21d60c8dc8a04eff878cd419ce12532a7b403ffbdebdd |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | a703d1d2379292fafd66c1cb0825de216bf0b2ccdd8818a525d17d4223a31f8d | 9765550769 | 43c0385dc78516cedf4c21b9f18ef84f6f83dbfdb4b65a8bd86749efd89351e0 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 136e5163a4d7b08e6f6d7e5e0e700231064fe054c0cfcf4656226493ad45f180 | 9765620613 | 108d03a9ab665c7c487ff37b2fc24ecdfca250dcdb52db241d3a8441487c2fef |
| Linux musl x86_64 | AWS-LC | PASS | 8dac563cf51edaac8063d583be96d6586c5c5212bb63853080b40983e1985e56 | 9765542198 | b920ed69d36e8d5c432b33c53604f9484904ac7619594d5f60fb797764e2ffb2 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | eef678d1f9a665dc8d13ede92c9fc85f2d2b8688e01700b691e79a3fa0576377 | 9765527984 | be10728c8fe14624f676581408013749536b275af582394bc50b549268793885 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 45942de74d714ba8fedbab5abef4149c9560dec12a9b20beb38899719b87f7da | 9765582678 | 0a480fd62a5ee906556d727004dee516d39d6232768054084d4545da7e52c4d9 |
| macOS arm64 | AWS-LC | PASS | d9a9dccecb1d410f05eb2d2cde62912adb7e55d03aa058415e8b134a6f830f43 | 9765565484 | 3a64bfef7e1c747e6a9f4cbfb4149993bad03ab45a98d0c86e15d226e08095d2 |
| macOS arm64 | Mbed TLS | PARTIAL | c5d02e3ffa058ba471fef6e3ce556b3d3f746e1f17e7281cf5e7fd5e695c0516 | 9765532480 | 76445ba37813a47d6c95929d5e77781636f471465f947d77845a67b980013770 |
| macOS arm64 | OpenSSL | PARTIAL | 5f26114b158b8c1f10582032ecffcf1f3cad817ae82c1873e7bdb9e36895c896 | 9765636374 | 0360532d6e2f7eda7895f5fe995328e14171dc9404d9ebbfbc4d3e5bdb043911 |
| Windows x86_64 | AWS-LC | PASS | f745321f8a84aedbabcedcb7955d17676b4c28a2d0d2c9fba940419c290afed7 | 9765545341 | 1452a68f52c2c083c0003ab28004717306a3d01cf025bd37bf81037793a75814 |
| Windows x86_64 | Mbed TLS | PARTIAL | cb204d6bcee3b70c84658acc1734ce0e0c3fcfed7456a3a0f82c12ce98dbb137 | 9765617555 | f15b904fe500ff0c7f3a3d23f404deaf4a01b4bf98f56de5a4aa2dc253a79eb4 |
| Windows x86_64 | OpenSSL | PARTIAL | 44e5d05923eccaf5705fcead83a4aacc81f14bf0fb398f5bb40e2ca934d328bc | 9765856296 | e7766523019ebd458f9c38579ac58ab6b94142d4372c58a1ad7e26a63c8012fa |

The Unix artifacts expire on 2026-11-29. The Windows artifacts expire on
2026-09-14. Artifact expiration does not remove the committed result JSON,
license payload, matrix digest, normalized build provenance, or source
identity.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit 991e67ff4cf04df4dd89e407f8b920c6936cb56a |
| Mbed TLS | 4.2.0 | commit ece41aa84d7879d7e55c59e955a5884b541f7f3b plus archive SHA-256 |
| OpenSSL control | 3.6.3 | official archive SHA-256 and peeled tag commit |

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
  v8.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC qualifies candidates. It selects AWS-LC only for the Linux delivery
  profile and does not claim production provider support on other platforms.
