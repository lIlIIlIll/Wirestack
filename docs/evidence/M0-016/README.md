# M0-016 evidence: TLS provider PoC

## Status

M0-016 is **BLOCKED** because Android, iOS, and HarmonyOS or OpenHarmony do
not have native-device evidence.

The schema-v5 desktop evidence is superseded. All 12 desktop cells are
`NOT_RUN` until native runners produce schema-v6 results. Schema v6 additionally
requires provider-instrumented diagnostics, provider allocation hooks, durable
normalized build provenance, committed matrix-validated license bundles, and a
real bounded cancellation wakeup. The old results remain audit history and are
not current PASS or PARTIAL evidence.

The next current native run must retain:

- expired certificate rejection;
- malformed certificate rejection;
- adapter rejection of an empty ALPN identifier and a 256-byte ALPN
  identifier;
- a complete final-artifact symbol inventory, capped at 16,384 symbols and
  256 bytes per symbol;
- mTLS with required client authentication and optional client authentication
  both with and without a certificate;
- a digest-bound provider license bundle;
- exact repository, hosted-runner, and immutable musl container identity;
- bounded resident-memory and harness-allocation measurements;
- ASan and UBSan diagnostics on Linux glibc and macOS, with an explicit
  unsupported result on the other current desktop targets; LeakSanitizer must
  pass for Linux glibc Mbed TLS; AWS-LC, static OpenSSL, and macOS record that
  sub-gate as unsupported with an explicit reason instead of using broad leak
  suppressions.

## Superseded schema-v5 desktop runs

The Linux glibc, Linux musl, and macOS results came from [GitHub Actions run
33391223747](https://github.com/lIlIIlIll/Wirestack/actions/runs/33391223747).
That pull-request run reports head revision
`22ae52c7b277c1d6c83afc0ac0dd73dc7e9c83a6`; GitHub executed merge revision
`4c7ddea51e9e73600b39be7938566ea6300ab5cd` and every retained result records
that exact execution revision. The Windows results came from [GitHub Actions
run 33391216138](https://github.com/lIlIIlIll/Wirestack/actions/runs/33391216138)
and executed the exact head revision
`22ae52c7b277c1d6c83afc0ac0dd73dc7e9c83a6`.

All 12 artifacts were downloaded and independently revalidated under schema v5 with
`validate.py --result ... --expected-revision ...`. Each artifact contains the
schema-v5 `result.json`, a bounded `build.log`, and the digest-bound provider
license bundle. They do not satisfy schema v6 and must not advance M0-020.

| Platform | Provider | Status | Symbols | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---:|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | 3,802 | `9524d15071e64663f522ddbd0220bf5b61bf36e783b7ea9328a78f0a76f217b7` | `9757564639` | `ce4ac7a71b548521629061553119d5d5c9cbc706376d9dc029f5de90b2a7a6f7` |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | 1,113 | `23af305e38bbc505eda3036526e33ff490e4004fb5d758b6c505b5d19098c88b` | `9757574141` | `eafc48e60e05097cac148c7d098f1ac0c06ba6c3dedc6469136535c3e79bb69a` |
| Linux glibc x86_64 | OpenSSL | PARTIAL | 9,576 | `6e5788f57b91f063849e658605b539ee40aa085dcd39f3cee772868a97ecc1ae` | `9757583727` | `ebd328b95fc5b5d3037054beef86b4deeb9652405752414199770c05ec52b34a` |
| Linux musl x86_64 | AWS-LC | PASS | 3,794 | `aecae7d56baaea20791970d93a7788be57381650f8a92111d81475f01db613de` | `9757576287` | `0960d3344bbba82620e2e7c010b5e0795c5d3e7782846ca86110f16823c2ab32` |
| Linux musl x86_64 | Mbed TLS | PARTIAL | 1,110 | `3862ee400034be101610fa7eb1c5431ff5ab89440f3625f183dca45a2370cf57` | `9757581463` | `c08edf102574d24cc8c2e42e07f6d66aa06d2921133752793958ae3734145732` |
| Linux musl x86_64 | OpenSSL | PARTIAL | 9,570 | `28d4e9c83e6f95370243e58543685934aaa38b91acfc71a57f430343be1f256a` | `9757611094` | `f06327d60e5a102cff5a37e374f28db744b3de2f7ff60631a2ef4cf7905a707d` |
| macOS arm64 | AWS-LC | PASS | 3,368 | `b28b9ec72f84882c6add3ab47c105ae4d5730b5f55211a3af660799980964a1e` | `9757555502` | `33f5e2073193729984785342fe608b5758e47606f7b76c33736718870ca1e3dd` |
| macOS arm64 | Mbed TLS | PARTIAL | 1,101 | `8d13de4eb0fe79003a4e7f076b55249963f80c93f5bc34b0e52e824e09340b01` | `9757573523` | `083b96921d8bbf29df562e6ea283063196097083a0769f884187a5d7ab4c62488` |
| macOS arm64 | OpenSSL | PARTIAL | 9,534 | `0a656043966adfb978289a818b6cccd1be1b91376d349553ff5f1eeb76f650a3` | `9757572359` | `b6972e02ed4165875074dd25b1aa3ecb12a253566128709328312441c84a30ff` |
| Windows x86_64 | AWS-LC | PASS | 9 | `bbd1770f2a55892b6ce8ffcaee65ce95f4651f1278294098f4c708e1dc344fbb` | `9757576438` | `1b9193bd502dbf539d698c08354d081abf5a38fa4e20620d9c6bb49641eb22ab` |
| Windows x86_64 | Mbed TLS | PARTIAL | 0 | `e887a8671d27ec08b75ac6ac8a4a467b13b8721ea6cc60394b85d4559bcfb2e1` | `9757636596` | `ab0a3c02553ee28e0e60b43c4ff613b062d2005af4070e631e6844479d3eb0fd` |
| Windows x86_64 | OpenSSL | PARTIAL | 0 | `c3aa77a6174880de0faf4bc52538532ad13729a7d641b1b239f16465882b59fa` | `9757835820` | `3a875853d8d4f9ce0f6c6cd397533e1a13ad2d5f5b3859388f390102b943cbac` |

Each result contains `build_log_sha256`, provider license-manifest metadata,
and the bounded memory profile. The platform matrix records the result path and
SHA-256. The Windows run metadata, artifact digests, and build log digests are in
[`windows-x86_64-run.json`](windows-x86_64-run.json). GitHub artifacts can
expire, so the committed result JSON files and matrix digests are the durable
evidence. Schema-v4 artifacts remain available through their historical runs,
but they are not referenced by the current matrix.

LeakSanitizer is a required PASS only for Linux glibc Mbed TLS. AWS-LC and
static OpenSSL retain process-global allocations that cannot be separated from
provider-cycle leaks by this harness, so leak detection is explicitly
`UNSUPPORTED` for those providers; broad suppressions are forbidden. macOS
records LeakSanitizer as unsupported by the hosted toolchain. All Linux glibc
and macOS cells still pass ASan and UBSan, and every desktop cell passes the
bounded 10,000-cycle resident-memory and allocation profile.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` plus archive SHA-256 |
| OpenSSL control | 3.6.3 | official archive SHA-256 and peeled tag commit |

`tools/tls_provider_poc/providers.json` contains the machine-readable source
pins.

## Validate the current matrix

Run the validator and the fault-injection tests from the repository root:

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 -m unittest tools.tests.test_tls_provider_poc
```

The PoC runner requires network access, CMake, Ninja, a C or C++ toolchain,
Perl, Git, and a host `openssl` command for fixture generation. The host
`openssl` command does not provide the TLS implementation under test. The
runner links the PoC binary against the pinned provider archives and rejects
system TLS runtime dependencies.

## Evidence rules

- A retained incomplete native result is PARTIAL only when it satisfies the
  current schema.
- A missing external-signer or session test prevents PASS.
- A runtime provider fallback or a system TLS dependency produces FAIL.
- Cross-compilation does not satisfy a native platform cell.
- This PoC does not select or claim a production provider outside Linux.
