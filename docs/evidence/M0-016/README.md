# M0-016 evidence: TLS provider PoC

## Current status

- Task: **BLOCKED**
- Native desktop results: **12 retained schema-v3 results**
- AWS-LC: **PASS** on Linux glibc x86_64, Linux musl x86_64, macOS arm64 and Windows x86_64
- Mbed TLS: **PARTIAL** on all four platforms because external signer and session resumption remain blocked
- OpenSSL control: **PARTIAL** on all four platforms because external signer remains blocked
- Android, iOS and HarmonyOS/OpenHarmony: **BLOCKED** because no native device runner is connected

The PoC exercises TLS 1.2, TLS 1.3, external transport, external trust,
external signer, ALPN/SNI, mTLS, cancellation, close notification, truncation,
session resumption and 10,000 cleanup cycles. AWS-LC passes the full contract on
the four executed platforms. M0-016 stays blocked because the task requires
native execution on the three mobile platforms as well.

The Linux and macOS results came from [GitHub Actions run 33373024032](https://github.com/lIlIIlIll/Wirestack/actions/runs/33373024032).
The Windows results came from [GitHub Actions run 33373024046](https://github.com/lIlIIlIll/Wirestack/actions/runs/33373024046).
Both pull-request runs report head revision
`80f3a7bca5380b3addb4fbcbe99df7d75f5dd955`; GitHub executed merge revision
`9611abb32c9e790fe893aa9ea4f25ec5ae0d8fba`. The musl runner executes inside
an isolated Alpine minirootfs, so its retained JSON does not repeat the
repository revision; its artifact remains bound to run 33373024032.

## Retained native results

`platform-matrix.json` binds each result path to its SHA-256. GitHub artifact
digests below identify the archived build log and result pair.

| Platform | Provider | Status | Result SHA-256 | Artifact ID | Artifact SHA-256 |
|---|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | PASS | `eb45863f412c8781b6fbdafb591605e35a2650e175d3c6ba9a125a3b78987ccf` | `9750831416` | `0910088e041c9154c1f25687e92c0275bbf0df0f6f6c63687635ab36d6af8ab1` |
| Linux glibc x86_64 | Mbed TLS | PARTIAL | `a885d150f3f97922e210c10abdce6f422aa95bf2e270377da451369d861a13d8` | `9750859361` | `891c6e06f69b2060af57b657843ac917d9d61a806d1e25e34f28548851d8f581` |
| Linux glibc x86_64 | OpenSSL | PARTIAL | `1867cfeceaa4f932189726bc0b75b8cff96789967598fc73ad5028172c951eec` | `9750849774` | `3687d0340b38847939d88f26f80508e0bc4ec54c59b59b02d9f855d92d2262df` |
| Linux musl x86_64 | AWS-LC | PASS | `5c38f9ac9ad47dfd24eebe336e90dcf54a502f667187e13bebab6dcb89215a13` | `9750828338` | `7dfc5bf5488c460336b99070c344936d7714469a79b41ca3b994b388935d4b92` |
| Linux musl x86_64 | Mbed TLS | PARTIAL | `c10c6139a5964b7543db4833bef753ec907e31b02f2d326aeb2abceeda71500d` | `9750859618` | `73334ad0f69191629d7a5176540e85d624aa29ac7be1b433ce2fb4b17780b7f3` |
| Linux musl x86_64 | OpenSSL | PARTIAL | `f49439d38d035a96b6d39d991c0dc87bd605718a6a08c4f02d0bd3dca0497e2d` | `9750877047` | `fe44bc5b77098eb60b990ad7d56bbc822ca0748b9485b07c0081232638e6c7ed` |
| macOS arm64 | AWS-LC | PASS | `3a6c0e45fdc853cccd403bb0e6c259b28af71b5080b0697055b957ee14418bec` | `9750834724` | `db8fce552c87a21fdb85ef60ba42ca31396f17fdd75a94502e07a771cee99b5d` |
| macOS arm64 | Mbed TLS | PARTIAL | `c690346f6be6e02d8973944e1b199ab6480dd6df4e99a0c7e64a97d7bf6a3cfa` | `9750871146` | `2519d3d1fd37520d71a7bcb213ea9eddb2391b7623175c2b311f5390a4bad2ce` |
| macOS arm64 | OpenSSL | PARTIAL | `5a962af1db9316ef615d9aad50ba287d4b9eea605705b10eb52d06a995ef9d43` | `9750860360` | `38953ef079fb58fdd09121a082a790ff0f409cec0e3be8fb086f032afd6f7430` |
| Windows x86_64 | AWS-LC | PASS | `84bb46f15c4271691203b3bf30f35ae8a4b9f0b126a535f97ba2d1323ba3b530` | `9750852232` | `f474ee013136f907d2567f5f62df6967bed1e741e16f94425d8e4e0a28dfef1d` |
| Windows x86_64 | Mbed TLS | PARTIAL | `5b64a8bec8080d38891be497c0aee0bfb5f5bc59bae62bbd717d6f2ded5f5cc6` | `9750895589` | `ebf6a9a378ea57017299e4ab1694765aed7554538d4bf6b8d664442fa050e739` |
| Windows x86_64 | OpenSSL | PARTIAL | `f3a0aaeba2d3f8ee1c17527cd98e60742d191f71ebe9314c4dc30574ad97a1d3` | `9751108355` | `35cfadb0053798f3bc764be6c487b1db9e1ab157bb87b6fbea9835128cf5053b` |

The Windows run metadata and build-log digests are retained in
[`windows-x86_64-run.json`](windows-x86_64-run.json). CI artifacts are
supporting evidence and may expire; the committed result JSON and matrix
digests are durable.

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` plus archive SHA-256 |
| OpenSSL control | 3.6.3 | official archive SHA-256 and peeled tag commit |

The canonical machine-readable pins are in
`tools/tls_provider_poc/providers.json`.

## Reproduction and validation

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 -m unittest tools.tests.test_tls_provider_poc
```

The PoC runner requires network access, CMake, Ninja, a C/C++ toolchain, Perl,
Git and a host `openssl` command for fixture generation. It links the test
binary against the pinned provider archives and rejects system TLS runtime
dependencies.

## Evidence rules

- A retained incomplete native result is `PARTIAL`, never `PASS`.
- A missing external-signer or session test makes a result `PARTIAL`.
- Runtime provider fallback or a system TLS dependency makes the result `FAIL`.
- Cross-compilation does not satisfy a native platform cell.
- This PoC does not select or claim a production provider outside Linux.
