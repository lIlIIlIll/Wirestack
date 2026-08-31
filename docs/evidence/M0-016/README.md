# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED**. The 12 desktop schema-v8 results are stale after
schema-v9 introduced monotonic cancellation waits and an exact, pin-bound
advisory disposition. OpenSSL 3.6.3 was also affected by upstream advisories
fixed in 3.6.4, so the control pin and all of its native results must be
rebuilt. Android, iOS, and HarmonyOS or OpenHarmony still lack native-device
evidence; cross-compilation does not satisfy those cells.

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

## Superseded schema-v8 desktop runs

[TLS Provider PoC run
33416731896](https://github.com/lIlIIlIll/Wirestack/actions/runs/33416731896)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33416731695](https://github.com/lIlIIlIll/Wirestack/actions/runs/33416731695)
produced the Windows results. These runs are retained as historical evidence
only and do not satisfy schema v9. Both run records identify pull-request head
47732d984d439bf7b4f700cf4f8d9ad8bc913da8. GitHub executed synthetic merge
revision 67c519b3d406912378a18bd15da28d5b1f0cdf6a; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 67c519b3d406912378a18bd15da28d5b1f0cdf6a

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | ee6ce99ddcbeeb07228d13846320176a9a4a4af6fbdde57dbc349dcb586732cf | 9767405790 | cfcad4608adc82d652a021eceac20c0c215f85e757b32cbc9243fab3688e3ffc |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | c42e9079468c0693f0d81d7864af439cd3c902540e33c942974cee6524550d33 | 9767383447 | 15b738a8b207e19692bdb4fd22bdc8b92177ba11416a85960f363557ee7c9a85 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 1cbc99507429d8dc6d1a2c39200da7d05fc2f55bffc092f3aec75e850b8bfd83 | 9767404839 | a087bdbc409da89ceb72ed49ca9b0ef3eaec57c3862d64727ee698517b6f20e9 |
| Linux musl x86_64 | AWS-LC | PASS | db122b915eafd538d993f29ccf92f975be4f9fb398b6ce0bf8e86630f7f916af | 9767389169 | 3cb8e1549d39b0a04148236ea2956cfeabe422459ddffc75f3882582724e77f9 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 7c9b78471064071a01f4a0fba9ecff02929e9d6ffb9e7bf538fb4111b5829a7f | 9767365408 | 47dd51859b256eeebd15b0e57bfd411e84043799246ff44690af7e825d2dd2f7 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 3cd9b1eee93d2270d39b1b80c30b001d5d0bb8df0ed7e40f2f5dd6e24c504a21 | 9767420774 | be8f00fa4c5ead785777bcaae661d9c9c19889de293e788affbe2d39c360d3fa |
| macOS arm64 | AWS-LC | PASS | 17623eb0d6343381a1b428db910e7b7c6346bebfd8bdef6b0e6befb244a8aba7 | 9767388741 | 154b4f9f3689801d5667100e7b4cefc4f7c5583e6a87ecabc23cfc45f075cdf4 |
| macOS arm64 | Mbed TLS | PARTIAL | dcefa39a5b9ceedfdf2ba515ff8cdab83a5fd90be6ca11c58dced6f019927747 | 9767372039 | a2065edd6a51065e97fa6640a98af6078acfa2daaa5af6b7c7616733176f7576 |
| macOS arm64 | OpenSSL | PARTIAL | f93009d83047900e20dec19e577b4658596d8479debe47b67e86643856bf92e0 | 9767430174 | 595706625a03783f7cfd268bef082b01aff8dcb2bfc946395d304d299441ce9a |
| Windows x86_64 | AWS-LC | PASS | 709f088325a7628f25be8be5646c9938bce4d9cee85b7fad2e6d42f294061e50 | 9767369565 | 2b4924c7323801dcd1976e36dae75603dd9b548538c41132bc366da0a3e0b5c5 |
| Windows x86_64 | Mbed TLS | PARTIAL | c9b1da45fc5a0e5dcfc6553159da6de365c17d8df454be7f11f8da22b69aa131 | 9767403800 | 76456f8c3943d990c3b080d78d157274511bc121dbd00ff1155a4cd3f7de9538 |
| Windows x86_64 | OpenSSL | PARTIAL | 1e5771522c9f995363348348370b3fcb932f0e3f78842a462bc2c70802c5ae1e | 9767648363 | 7217177061711879e5d859a3c8aabfe5b4db2ad67057cd7e1a556c676051ee7c |

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
