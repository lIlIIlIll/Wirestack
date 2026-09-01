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
33453672369](https://github.com/lIlIIlIll/Wirestack/actions/runs/33453672369)
produced the Linux glibc, Linux musl, and macOS results. [M0-016 Windows
Provider PoC run
33453672416](https://github.com/lIlIIlIll/Wirestack/actions/runs/33453672416)
produced the Windows results. Both pull-request runs identify head
`8c845eea4c85aa88a22f24cf59f742a205cd1188`. GitHub executed synthetic merge
revision `72808d9948973a9562d15c41847b73db56aa7001`; every retained result binds
that exact execution revision.

All 12 artifacts were downloaded and independently validated with:

    python3 tools/tls_provider_poc/validate.py \
      --result <artifact>/result.json \
      --expected-revision 72808d9948973a9562d15c41847b73db56aa7001

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | f46e603800d3948b44fb3b4ef31639acc66f8060ab31292f3455da3b127a9f6a | 9780737160 | 86a8becdf1abdeb554ecf168e9cad665b88fcf5994f41cdd6ba0f4f5f93f33fc |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 65ef73ae157b883828acfaa79b47267d1e6dd1560d16b4e3b9056af95aab3064 | 9780710366 | ea8b881009fdd933e50d57ec64563ff3073b6e58c910f81c32f8e5ff4db34610 |
| Linux glibc x86_64 | OpenSSL | PARTIAL | a3752f753b70796bd2ff7ba09ef1bd6e09c52ccbd90ae24946ba21f1c8a3fac8 | 9780756040 | e3cc85a5b3a39d90172609602969f4f06c8321616946dfa7ca5b7aa1d2ea5ead |
| Linux musl x86_64 | AWS-LC | PASS | 4081d06c17b29d551808e4fb3346e2d22a3084361b0a1abfa1190b029a0a554a | 9780704790 | 20d396c0a2409cc0d8bc676cec352f24bce21faac8bc48495b20c7f3488cf7ae |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 51efe846877ebfc2ba3837227f24da7d40ae6addbc5695df1e12794072d33fb1 | 9780706698 | c915f158471d8c3144d55c716a450ce4571d7c80f9cb151bdd52650646f133e5 |
| Linux musl x86_64 | OpenSSL | PARTIAL | 343f6a82a40e0906211d9881d0558c4b55e9a93fe7dcc4ed583ad67e91fbaabf | 9780725875 | 646b2eec7696769c61e2b16778cbfcb79a559012158ace1490db76dc872b3c5f |
| macOS arm64 | AWS-LC | PASS | d34063834ba9704567c58cd6d8833b32110d82325de075f80c3e2b20aa77936c | 9780704192 | 24d7bf5f9f0c9b138da459643428f593738e20d919101c66cbfa6d4a36eb96e8 |
| macOS arm64 | Mbed TLS | PARTIAL | 769c0f4f843e7c58907b040cb039017fee54f4d39ffcded7a1f44373d5d68fbe | 9780701601 | d71cf61429dad3c02a71fdb7cb7513e90df4dc07b4e0034091d539cd9c8d8b17 |
| macOS arm64 | OpenSSL | PARTIAL | 71213dc9119448ceac8cfbc1097cfdb8f224b6975f3d1783e39fd20456f73716 | 9780741794 | 94955ff286ceaa7584e545751f29e9c4a1a53a3df20519f5f341f8c510ebd28a |
| Windows x86_64 | AWS-LC | PASS | b1e12bda3d067e12ccc5bd8b8d2d1adbd81fee8cc179b77dc8485c028306c163 | 9780706869 | ab65d14cc56fbae0fd91b251407392f07fe7af553bf9b8a67c72b2398a1bc2d7 |
| Windows x86_64 | Mbed TLS | PARTIAL | 37cfd90c441a8509be195ebcb9ac4b414b63e4e71dbb79e8d1da03e7b054a93f | 9780743660 | f52cefe87d76555b46b85d728ae2950ec208a0d0354134641e149cdf64265376 |
| Windows x86_64 | OpenSSL | PARTIAL | 10c5ed9184044493d0205cc66f7399d816ea9fa532927795585bb0016097ad47 | 9780885578 | fb774f9d8d24691d33390183885b33daa81f1dd6b3583b34df8f92644987ff96 |

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
