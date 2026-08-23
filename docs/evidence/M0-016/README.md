# M0-016 evidence: TLS provider PoC

## Current status

- Task: **BLOCKED**
- Linux glibc, Linux musl and macOS arm64: **PARTIAL — native results retained**
- Windows x86_64: **NOT_RUN — no native job exists yet**
- Android, iOS and HarmonyOS/OpenHarmony native execution: **BLOCKED — no device runner connected**
- External/non-exportable signer callback: **BLOCKED for every provider**
- Mbed TLS session resumption: **BLOCKED**
- Final provider selection: **out of scope; M0-020**

The fail-closed runner executed AWS-LC, Mbed TLS and vendored OpenSSL from pinned
source on native Linux glibc, native Alpine musl and native macOS arm64 runners.
All nine results are `PARTIAL`: the executed capabilities passed and the binaries
had no system TLS-library dependency, but required capability/platform cells remain
blocked. M0-016 is therefore not complete.

## Retained native results

The structured results below came from [GitHub Actions run 32638716777](https://github.com/lIlIIlIll/Wirestack/actions/runs/32638716777)
at PR head `4413e5bd84d6af5e8c468ec2e054a0a54646cd44`. Each committed JSON file is
checksum-pinned by `platform-matrix.json`; the larger build logs remain in the
named CI artifact.

| Platform | Provider | Result | CI artifact ID | Artifact SHA-256 |
|---|---|---|---:|---|
| Linux glibc x86_64 | AWS-LC | [`results/linux-glibc-x86_64/aws-lc.json`](results/linux-glibc-x86_64/aws-lc.json) | `9493029744` | `a33108e7f58f41a5eff4c5255d4e4d9799dc3770adbd66adfcc843f8d83185d3` |
| Linux glibc x86_64 | Mbed TLS | [`results/linux-glibc-x86_64/mbedtls.json`](results/linux-glibc-x86_64/mbedtls.json) | `9493019132` | `a30b2c367333bca91e2edc0db04094666a82afe2eb5f99f689de6b97e068b664` |
| Linux glibc x86_64 | OpenSSL | [`results/linux-glibc-x86_64/openssl.json`](results/linux-glibc-x86_64/openssl.json) | `9493035593` | `9017f62284f4192fec48a85debfec05e7071f84112771ce8c74e465dcd55a531` |
| Linux musl x86_64 | AWS-LC | [`results/linux-musl-x86_64/aws-lc.json`](results/linux-musl-x86_64/aws-lc.json) | `9493030804` | `9bd5c36e18decf296d364247d98fb3312330d12ac77d59dd70b2312f8cd78d8b` |
| Linux musl x86_64 | Mbed TLS | [`results/linux-musl-x86_64/mbedtls.json`](results/linux-musl-x86_64/mbedtls.json) | `9493019276` | `07207bb26190ae7a2514a92e59f7d1cdcf4deb99f217961a40578403475a0248` |
| Linux musl x86_64 | OpenSSL | [`results/linux-musl-x86_64/openssl.json`](results/linux-musl-x86_64/openssl.json) | `9493040735` | `9d522032e3467561e2b5de7fd0bb9952f7e98dff9e6f589357943b6194c1180f` |
| macOS arm64 | AWS-LC | [`results/macos-arm64/aws-lc.json`](results/macos-arm64/aws-lc.json) | `9493021992` | `64a34c167194de3e4437f0d9841ef53deb4942add30bc42e233fc0ca530016b8` |
| macOS arm64 | Mbed TLS | [`results/macos-arm64/mbedtls.json`](results/macos-arm64/mbedtls.json) | `9493016597` | `cbda50da907c30dbb30224c857e7e548c5dabc28bf922dd5657027e6252115a5` |
| macOS arm64 | OpenSSL | [`results/macos-arm64/openssl.json`](results/macos-arm64/openssl.json) | `9493025915` | `05b8b1aeddaaf3107fd2cb2d92bbcb50cb0fd254a778c54f281d44b17a578091` |

## Pinned sources

| Provider | Version | Source identity |
|---|---:|---|
| AWS-LC | 5.5.0 | exact commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a` |
| Mbed TLS | 4.2.0 | official archive SHA-256 plus commit `ece41aa84d7879d7e55c59e955a5884b541f7f3b` |
| OpenSSL control | 3.6.3 | official archive SHA-256; CI peels `openssl-3.6.3` to its exact commit |

The canonical machine-readable pins are in `tools/tls_provider_poc/providers.json`.

## Reproduction

```bash
python3 tools/tls_provider_poc/validate.py \
  --matrix docs/evidence/M0-016/platform-matrix.json

python3 tools/tls_provider_poc/run.py \
  --provider aws-lc \
  --output build/tls-provider-poc/aws-lc/result.json

python3 tools/tls_provider_poc/validate.py \
  --result build/tls-provider-poc/aws-lc/result.json
```

Use `aws-lc`, `mbedtls` or `openssl`. Network access, CMake/Ninja, a C/C++ toolchain, Perl, Git and a host `openssl` command for fixture generation are required.

## Evidence rules

- Every provider/platform cell stays `NOT_RUN` or `BLOCKED` until an actual run is retained.
- A retained incomplete native result is `PARTIAL`, never `PASS`.
- A missing external-signer or session test makes a result `PARTIAL`, never `PASS`.
- System TLS-library discovery or runtime fallback makes the result `FAIL`.
- Cross-compilation does not change a native platform cell to `PASS`.
- CI artifacts are supporting evidence; retained result JSON is checksum-pinned under this directory.
