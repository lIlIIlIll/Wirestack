# M0-016 evidence: TLS provider PoC

## Status

M0-016 remains **BLOCKED** because Android, iOS, and HarmonyOS or
OpenHarmony do not have native-device evidence. Cross-compilation does not
satisfy those cells.

The 12 retained schema-v6 desktop results are superseded by schema v7 and no
longer count as current PASS or PARTIAL evidence. Native reruns must retain the
bounded worker join, cleanup live-allocation baselines and validated
security-update intake before the desktop cells can be promoted again.

Schema v6 retains:

- required and optional client authentication;
- negative certificate, hostname, trust, and ALPN cases;
- exact repository, runner, toolchain, target, configure/build argv,
  environment, patch-set, source, and archive identity;
- complete bounded final-artifact symbol inventories;
- committed, digest-bound provider license bundles;
- 10,000-cycle resident-memory, provider allocation-call, cumulative-byte,
  and peak-live profiles;
- an explicit caller-owned wait, cancellation signal, wakeup, join, and
  latency bound; and
- provider-instrumented ASan and UBSan diagnostics on Linux glibc and macOS.

Linux glibc Mbed TLS also passes LeakSanitizer. AWS-LC and static OpenSSL
record leak detection as unsupported because their process-global allocations
cannot be separated from provider-cycle leaks by this harness. macOS records
LeakSanitizer as unsupported by the hosted toolchain. Linux musl and Windows
record the configured sanitizer diagnostic as unsupported; they do not report
a skipped diagnostic as PASS.

## Superseded schema-v6 desktop runs

[TLS Provider PoC run
33401994988](https://github.com/lIlIIlIll/Wirestack/actions/runs/33401994988)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33401994898](https://github.com/lIlIIlIll/Wirestack/actions/runs/33401994898)
produced the Windows results. Both run records identify pull-request head
0b8e3181a82f8eb062e24e63edf57fc05850d859. GitHub executed synthetic merge
revision 0970f3984eb523cc1571b864e72bfdddef10f3d8; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 0970f3984eb523cc1571b864e72bfdddef10f3d8

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 29bb981c4b426b622eaec843598df19ac4f0de309555774e0fc8ecacf4747be4 | 9761723304 | 51cd0a4f7be0e9c9b31fc90bc43590c0dcc6d20c0601bf45b7dd69e21bd55f9b |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 2f5560abd3e630fe766b44343c04b8c6dfcf3dd75f23f4fc3d43cd3cb1fbe96d | 9761673324 | ef1ac48afbd4c60665d6dc482c278ba01bac4b3c345fee64871545636c148916 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 8d3dd3d6efce896b664901dd27e9d8b19546b9008285bcc864bfb97b18337abf | 9761720732 | 93d5c6bbaa448bda66046fe4504ee6854123a547b4bfdafe06954cae049d731e |
| Linux musl x86_64 | AWS-LC | PASS | abddf4c0098695510315dd44ee25d3c94b71b010765233d9347ee09691203e9c | 9761644924 | 540842d5b5f751512a6e9e9850f86b5b3f5b171f5eb5a234b4968266ddba2fb3 |
| Linux musl x86_64 | Mbed TLS | PARTIAL | aa599c6fc526345e682033f9cbabf1f7779d02adbad6c5b23ceab4058365ab7a | 9761670487 | 4405bc979b7a505b3616cefd32900cce89de25e36000ea926ed82d11bc8a11ca |
| Linux musl x86_64 | OpenSSL | PARTIAL | f42a5c9994f8a20e5e3a65eb3e0c73200bc74c6d4ede468dbaea9c148fadbe65 | 9761660065 | f746eecb09ea61764764d977056756e09bcbb9420ea7e66b6e729270b6fd12ef |
| macOS arm64 | AWS-LC | PASS | 294f912a3508ca8ae72f31717b76d46ad7329d00851d0eb75ce106b47524c00d | 9761672812 | 759de851ea2e4c12ab5e2ad2db2f08198e2c81bc113f3920f33e5c369d27eb89 |
| macOS arm64 | Mbed TLS | PARTIAL | d86287be3d564188ebd8b4c804dc5a7b62b9ecf1d1502d5eea621391157151cc | 9761662174 | a8d8021f377d4bed2527443b3cd4efe0fd2dc2619f29b0bb375570250bbf71ab |
| macOS arm64 | OpenSSL | PARTIAL | d9fa0b4c8f78dbf6915c24e0fc3213844f1c6a8f6d00e2f57002ad943baeab59 | 9761733139 | 46795cbbf7ca2984c22cddcd8f962295698617ec3e90e679ed62bb07623474a2 |
| Windows x86_64 | AWS-LC | PASS | a91526d856a207538eed34c6a81844a8c09a36bc6a7b8ddf751bedbd25efb446 | 9761693290 | 060c8cd1c0f91615223cb8a5a21820265d34267a0aed0909a647561b05bc0e76 |
| Windows x86_64 | Mbed TLS | PARTIAL | 0b0f8f896a6851e0ba0e7c08785134e6711091ac68fa06858a1615837f110486 | 9761730074 | dee4e519d9d07fe3590d9a5161f90523b5af9de7ccfe86ae84b532c843c9fba3 |
| Windows x86_64 | OpenSSL | PARTIAL | e9a647f3be5d6d7dfb0aa9b78d2cacd350d2a219336b43a9afae31de564f702e | 9761930237 | cffd6b174bace07fbe7dc33aab1144ed12d4c073aafb3f55f0e15eaddb3833b2 |

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
  v6.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC qualifies candidates. It selects AWS-LC only for the Linux delivery
  profile and does not claim production provider support on other platforms.
