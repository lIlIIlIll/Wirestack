# M0-016 evidence: TLS provider PoC

## Current status

- Task: **BLOCKED**
- AWS-LC on Linux glibc, Linux musl and Windows x86_64: **PASS; native results retained**
- Remaining retained Linux/macOS/Windows candidate cells: **PARTIAL**
- Windows x86_64: **VALIDATED; AWS-LC PASS, Mbed TLS and OpenSSL PARTIAL**
- Android, iOS and HarmonyOS/OpenHarmony native execution: **BLOCKED; no device runner connected**
- AWS-LC external/non-exportable signer callback on Linux: **PASS for TLS 1.2 and TLS 1.3**
- Mbed TLS session resumption: **BLOCKED**
- Linux provider selection: **READY for M0-020**
- Global provider selection: **out of scope; M0-020**

The fail-closed runner executed AWS-LC, Mbed TLS and vendored OpenSSL from pinned
source on native Linux glibc, native Alpine musl, native macOS arm64 and GitHub's
native Windows x86_64 runners. AWS-LC passes every required capability on Linux
glibc, Linux musl and Windows, including two executed external-signing
handshakes and 10,000 repeated handshake/close cycles per result. Nine retained
results remain `PARTIAL`. Global M0-016 is therefore still incomplete, but its
Linux AWS-LC selection prerequisite and Windows provider PoC are closed.

## Retained native results

The two superseding AWS-LC Linux results were executed locally on 2026-08-24
(UTC+8) from pinned commit `991e67ff4cf04df4dd89e407f8b920c6936cb56a`.
The glibc run used Linux x86_64 with glibc 2.44. The musl run used the verified
Alpine 3.22.5 x86_64 minirootfs
`4b4daa9fe2fc696c4919c4412a4c3d3e770d8fb70292a004a2c72f5096175282`
under `bwrap`; it executed a native musl binary rather than a cross-build.

| Platform | Result | Retained JSON SHA-256 | Build log SHA-256 |
|---|---|---|---|
| Linux glibc x86_64 | [`results/linux-glibc-x86_64/aws-lc.json`](results/linux-glibc-x86_64/aws-lc.json) | `20b6b11d4e8b8083ce0628e47c89eecf769ea44f0dfedc46202428db01cb9722` | `64935e3c19bbf9441232e854420513d342da8ffa03a4b1dd490a1c96b65349c7` |
| Linux musl x86_64 | [`results/linux-musl-x86_64/aws-lc.json`](results/linux-musl-x86_64/aws-lc.json) | `0099fad5a972be7461984331eddb1ef457cff04d9de35c3272e43127bd778878` | `bbceafb9a737975d05015ccb7c8ef4ced93d9961301de819195cebdeeb22b6c6` |

The remaining structured results came from [GitHub Actions run 32638716777](https://github.com/lIlIIlIll/Wirestack/actions/runs/32638716777)
at PR head `4413e5bd84d6af5e8c468ec2e054a0a54646cd44`. Their larger build logs remain in
the named CI artifacts. Every committed JSON is checksum-pinned by
`platform-matrix.json`.

| Platform | Provider | Result | CI artifact ID | Artifact SHA-256 |
|---|---|---|---:|---|
| Linux glibc x86_64 | Mbed TLS | [`results/linux-glibc-x86_64/mbedtls.json`](results/linux-glibc-x86_64/mbedtls.json) | `9493019132` | `a30b2c367333bca91e2edc0db04094666a82afe2eb5f99f689de6b97e068b664` |
| Linux glibc x86_64 | OpenSSL | [`results/linux-glibc-x86_64/openssl.json`](results/linux-glibc-x86_64/openssl.json) | `9493035593` | `9017f62284f4192fec48a85debfec05e7071f84112771ce8c74e465dcd55a531` |
| Linux musl x86_64 | Mbed TLS | [`results/linux-musl-x86_64/mbedtls.json`](results/linux-musl-x86_64/mbedtls.json) | `9493019276` | `07207bb26190ae7a2514a92e59f7d1cdcf4deb99f217961a40578403475a0248` |
| Linux musl x86_64 | OpenSSL | [`results/linux-musl-x86_64/openssl.json`](results/linux-musl-x86_64/openssl.json) | `9493040735` | `9d522032e3467561e2b5de7fd0bb9952f7e98dff9e6f589357943b6194c1180f` |
| macOS arm64 | AWS-LC | [`results/macos-arm64/aws-lc.json`](results/macos-arm64/aws-lc.json) | `9493021992` | `64a34c167194de3e4437f0d9841ef53deb4942add30bc42e233fc0ca530016b8` |
| macOS arm64 | Mbed TLS | [`results/macos-arm64/mbedtls.json`](results/macos-arm64/mbedtls.json) | `9493016597` | `cbda50da907c30dbb30224c857e7e548c5dabc28bf922dd5657027e6252115a5` |
| macOS arm64 | OpenSSL | [`results/macos-arm64/openssl.json`](results/macos-arm64/openssl.json) | `9493025915` | `05b8b1aeddaaf3107fd2cb2d92bbcb50cb0fd254a778c54f281d44b17a578091` |

The Windows results came from [GitHub Actions run 33327534815](https://github.com/lIlIIlIll/Wirestack/actions/runs/33327534815)
at exact repository revision `7eccd9042b38000601fd2263bfb0fe8f148333aa`.
All three jobs ran on `windows-2025`, image `win25-vs2026` version
`20260824.214.3`, with runner OS `Windows` and architecture `X64`. The retained
JSON records the runner identity and exact revision; the CI artifacts are
supporting evidence and expire on 2026-09-13. The durable run index is
[`windows-x86_64-run.json`](windows-x86_64-run.json).

| Platform | Provider | Result | CI artifact ID | Artifact SHA-256 |
|---|---|---|---:|---|
| Windows x86_64 | AWS-LC | [`results/windows-x86_64/aws-lc.json`](results/windows-x86_64/aws-lc.json) | `9736694258` | `f8315b79ec332a7f76c2b23dc18d2f38002eec9a67fe066d0f41d3b85c255c07` |
| Windows x86_64 | Mbed TLS | [`results/windows-x86_64/mbedtls.json`](results/windows-x86_64/mbedtls.json) | `9736705902` | `3ec03d92fa9ce34890822e70013f13c57a60439d4ed1ee7adc3727e0393a091d` |
| Windows x86_64 | OpenSSL | [`results/windows-x86_64/openssl.json`](results/windows-x86_64/openssl.json) | `9736798657` | `935fd8f593dc070713950c63d203ff46145997da31eaff1b1d7062719294620e` |

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
- This PoC does not select or claim a production Windows TLS provider.
